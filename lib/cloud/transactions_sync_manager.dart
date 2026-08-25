import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path_provider/path_provider.dart';

import '../data/db.dart';
import '../data/encryption/ciphertext_format.dart';
import '../data/encryption/encrypted_cloud_provider.dart';
import '../data/repositories/base_repository.dart';
import '../domain/encryption/encryption_service.dart';
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';
import 'provider_factory.dart';
import 'sync_diff_service.dart';
import 'sync_fingerprint.dart';
import 'sync_restore_guard.dart';
import 'sync_service.dart';
import 'transactions_json.dart';

/// 账本交易的云同步管理器
///
/// 使用 flutter_cloud_sync 包实现云同步，保留 PiggyCount 特定的业务逻辑
class TransactionsSyncManager implements SyncService {
  final fcs.CloudServiceConfig config;
  final PiggyDatabase db;
  final BaseRepository repo;

  /// 可选的加密服务。若非 null 且加密已开启，会在 _initialize() 中
  /// 用 [EncryptedCloudProvider] 包装原 CloudProvider，使云端只见密文。
  final EncryptionService? encryptionService;

  fcs.CloudSyncManager<int>? _syncManager;
  fcs.CloudProvider? _provider;

  /// 未装饰的原始 storage（装饰前缓存），供 [rawStorage] getter 暴露
  ///
  /// 用途：[EncryptionService.enableFromCloud] 需要下载密文字符串本身
  /// （而非 EncryptedCloudStorageService 解密后的明文）来提取 salt，
  /// 因此必须传入未装饰的 raw storage。
  fcs.CloudStorageService? _rawStorage;

  bool _isInitializing = false;
  bool _isInitialized = false;

  /// 初始化并发控制：用 Completer 替代轮询，多个并发调用等待同一个
  /// Completer 完成，避免 50ms 轮询带来的延迟和 CPU 空转。
  Completer<void>? _initCompleter;

  /// m-03 修复：状态缓存 TTL，防止其他设备上传后本地仍显示过时的"已同步"状态
  static const _statusCacheTtl = Duration(seconds: 60);

  final Map<int, _CachedStatus> _statusCache = {};
  final Map<int, DateTime> _recentLocalChangeAt = {};
  final Map<int, _RecentUpload> _recentUpload = {};

  /// 待补齐的附件二进制下载队列(attachment_binary_sync)。
  /// 元组:云对象 sha256 + 落盘目标 fileName。恢复/导入事务提交后入队,
  /// drainAttachmentJobs 并发消费;失败回队等下次 drain。
  final List<({String sha256, String fileName})> _pendingAttachmentJobs = [];

  /// drain 重入守卫:恢复完成 / 初始化完成可能几乎同时触发 drain,
  /// 串行执行避免同一 .bin 被并发下载两次。
  bool _isDrainingAttachments = false;

  TransactionsSyncManager({
    required this.config,
    required this.db,
    required this.repo,
    this.encryptionService,
  });

  @override
  void clearStatusCache({int? ledgerId}) {
    if (ledgerId != null) {
      _statusCache.remove(ledgerId);
    } else {
      _statusCache.clear();
    }
  }

  /// 未装饰的原始 storage（用于 [EncryptionService.enableFromCloud] 探测云端密文）
  ///
  /// 返回值：
  /// - 非 null：raw storage 可用，可传给 `enableFromCloud`
  /// - null：provider 尚未初始化（需先调 [ensureInitialized]）或不可用
  ///         （如 iCloud 未登录），调用方应回退到 [EncryptionService.enable]
  ///
  /// 注意：返回的是**未装饰**的 storage，download 会返回原始密文字符串
  /// （BEECRYPT1:...），不会自动解密。这正是 enableFromCloud 所需。
  fcs.CloudStorageService? get rawStorage => _rawStorage;

  /// 装饰后的 storage（E2EE 开启时上传/下载自动加解密），供云端备份等
  /// 模块复用同一加密装配。provider 未初始化/不可用（如 iCloud 未登录）
  /// 时返回 null。
  Future<fcs.CloudStorageService?> decoratedStorage() async {
    await _ensureInitialized();
    return _provider?.storage;
  }

  /// 触发延迟初始化（公开入口，供 UI 层在调用 rawStorage 前预热）
  ///
  /// 幂等：已初始化时立即返回，正在初始化时等待完成。
  Future<void> ensureInitialized() => _ensureInitialized();

  /// 测试缝：直接注入 [fcs.CloudSyncManager] 与 [fcs.CloudProvider]，
  /// 跳过 [_ensureInitialized] 的真实云服务创建流程。
  ///
  /// 仅用于单元测试（验证 getStatus / download 等方法的错误处理与缓存策略），
  /// 生产代码不应调用。注入后等同已初始化状态。
  @visibleForTesting
  void setSyncManagerForTesting({
    required fcs.CloudSyncManager<int> syncManager,
    required fcs.CloudProvider provider,
  }) {
    _syncManager = syncManager;
    _provider = provider;
    _rawStorage = provider.storage;
    _isInitialized = true;
  }

  /// 强制重新初始化（用于加密开关变更后立即生效）
  ///
  /// 场景：用户在 [EncryptionSettingsPage] 开启/关闭/修改加密密码后，
  /// 装饰器必须用新的加密状态重建才能生效。本方法：
  /// 1. 标记 _isInitialized = false，使下次方法调用触发 _ensureInitialized
  /// 2. dispose 当前 _provider（释放网络连接/资源）
  /// 3. 清空缓存，避免读到旧的状态
  ///
  /// 重初始化是惰性的：本方法不立即重建，而是在下次 upload/download/getStatus
  /// 等方法被调用时按需重建。这样可避免在用户没立即触发同步时浪费资源。
  ///
  /// 注意：调用方应保证在调用此方法期间没有正在进行的同步操作。
  /// 若有，正在进行的操作仍会使用旧 provider 完成自身流程（不会中断），
  /// 但其结果可能反映旧的加密状态。
  Future<void> reinitializeForEncryption() async {
    _isInitialized = false;
    _isInitializing = false;
    _initCompleter = null;

    // 释放旧 provider（会触发 EncryptedCloudProvider.dispose → inner.dispose）
    // dispose 失败仅记录 warning，不阻塞重初始化流程
    try {
      await _provider?.dispose();
    } catch (e) {
      logger.warning('CloudSync', '旧 provider dispose 失败（忽略）: $e');
    }
    _provider = null;
    _syncManager = null;
    _rawStorage = null;

    // 清空所有缓存状态
    _statusCache.clear();
    _recentLocalChangeAt.clear();
    _recentUpload.clear();

    logger.info('CloudSync', '已标记需重新初始化（加密状态变更）');
  }

  /// 释放底层云服务资源（WebDAV dio client / S3 http.Client 连接池）。
  ///
  /// syncServiceProvider 在云配置/依赖变更时会重建本实例；旧实例若不
  /// 显式关闭，底层 HTTP 客户端会泄漏连接资源。dispose 后本实例不可再
  /// 使用（后续方法调用按「云服务不可用」处理），进行中的操作因已在
  /// 入口捕获局部引用（ATTACH-2 模式）可安全完成。
  Future<void> dispose() async {
    try {
      await _provider?.dispose();
    } catch (e) {
      logger.warning('CloudSync', '旧 provider dispose 失败（忽略）: $e');
    }
    _provider = null;
    _syncManager = null;
    _rawStorage = null;
    _statusCache.clear();
    _recentLocalChangeAt.clear();
    _recentUpload.clear();
    _pendingAttachmentJobs.clear();
  }

  /// 开启加密后的全量重加密 + 重新初始化（原子流程）
  ///
  /// 专为 [EncryptionService.enable] 之后的流程设计，组合两个步骤：
  /// 1. 用当前（未装饰的）_provider.storage 调用
  ///    [EncryptionService.reEncryptExistingCloudData]，把云端所有
  ///    ledger_*.json 重加密为 BEECRYPT1: 格式
  /// 2. 调用 [reinitializeForEncryption]，让下次同步使用新的加密装饰器
  ///
  /// 关键点：必须使用未装饰的 raw storage，否则会双重加密。
  /// 当前 _provider 是未装饰的（因为 enable 之前加密是关闭的，
  /// _initialize 不会包装 EncryptedCloudProvider）。
  ///
  /// 返回值：
  /// - 非 null：重加密完成，含 success/failed/skipped 计数
  /// - null：_provider 未初始化（如 iCloud 未登录），跳过重加密，
  ///   但仍执行了 reinitializeForEncryption
  ///
  /// 注意：此方法仅适用于 enable 流程。changePassword 流程需不同的
  /// 处理（需先用旧 key 解密，再切新 key 加密），不在此方法范畴。
  Future<ReEncryptResult?> reEncryptCloudAndReinit({
    required EncryptionService encryptionService,
  }) async {
    // BUG-4 修复：必须使用未装饰的 _rawStorage，而非 _provider?.storage。
    // 原代码取 _provider?.storage，在 _provider 已被 EncryptedCloudProvider
    // 包装的情况下（如二次重加密、后台 _ensureInitialized 被触发后），
    // 会返回已加密的 storage，导致 reEncryptExistingCloudData 内部
    // download 自动解密 + upload 自动加密后又被 encrypt() 再加密一次，
    // 产生双重加密。_rawStorage 在 _initialize 装饰前赋值，始终是原始 storage。
    final rawStorage = _rawStorage;

    ReEncryptResult? result;
    if (rawStorage != null) {
      try {
        result = await encryptionService.reEncryptExistingCloudData(
          cloudStorage: rawStorage,
        );
        logger.info(
          'CloudSync',
          '云端重加密完成: success=${result.success}, '
          'failed=${result.failed}, skipped=${result.skipped}',
        );
      } catch (e, stack) {
        logger.error('CloudSync', '云端重加密失败', e);
        logger.error('CloudSync', '堆栈', stack);
        // 重加密失败仍继续 reinit，保证下次同步用新的加密状态
      }
    } else {
      logger.warning('CloudSync', 'provider 未初始化，跳过云端重加密');
    }

    await reinitializeForEncryption();
    return result;
  }

  /// 确保服务已初始化（延迟初始化）
  ///
  /// 使用 Completer 实现并发控制：多个并发调用等待同一个 Completer，
  /// 避免旧实现的 50ms 轮询带来的延迟和 CPU 空转。
  /// 若等待期间 reinitializeForEncryption 被调用（_isInitialized 被置
  /// false 且 _initCompleter 被清空），会递归重试一次初始化。
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    // 正在初始化：等待现有 Completer 完成
    if (_isInitializing && _initCompleter != null) {
      await _initCompleter!.future;
      // 等待期间若 reinitializeForEncryption 被并发调用，
      // _isInitialized 仍为 false，需递归重试
      if (_isInitialized) return;
      return _ensureInitialized();
    }

    _isInitializing = true;
    _initCompleter = Completer<void>();
    try {
      await _initialize();
      _isInitialized = true;
      _initCompleter!.complete();
      // 初始化即触发一次 drain:覆盖"上次恢复失败的附件任务"在
      // 下次同步/启动检查时重试的场景(队列空时是空操作,零成本)。
      unawaited(drainAttachmentJobs());
    } catch (e, st) {
      _initCompleter!.completeError(e, st);
      rethrow;
    } finally {
      _isInitializing = false;
      // 保留 _initCompleter 直到 complete 后清理，避免 await 方拿不到结果
      _initCompleter = null;
    }
  }

  /// 初始化 CloudProvider 和 SyncManager
  Future<void> _initialize() async {
    final services = await createCloudServices(config);
    _provider = services.provider;

    if (_provider == null) {
      // Provider 创建失败（如 iCloud 未登录），标记为已初始化但无法使用
      logger.warning('CloudSync', 'Provider not available for ${config.type}');
      return;
    }

    // 装饰前缓存原始 storage 引用，供 [rawStorage] getter 暴露
    // 用途：enableFromCloud 需要未装饰的 storage 来下载密文字符串本身
    _rawStorage = _provider!.storage;

    // E2EE: 若加密服务已注入且加密已开启，用 EncryptedCloudProvider 包装一层。
    // 装饰器只重写 storage getter，其余方法透传，对 CloudSyncManager 完全透明。
    // 加密未开启时直接用原 provider，避免无谓的包装开销。
    if (encryptionService != null) {
      final enabled = await encryptionService!.isEnabled;
      if (enabled) {
        _provider = EncryptedCloudProvider(
          inner: _provider!,
          encryptionService: encryptionService!,
        );
        logger.info('CloudSync', 'E2EE enabled, provider wrapped');
      }
    }

    _syncManager = fcs.CloudSyncManager<int>(
      provider: _provider!,
      serializer: _TransactionSerializer(db),
      logger: fcs.CloudSyncLogger(onLog: (level, message) {
        switch (level) {
          case fcs.LogLevel.debug:
            logger.info('CloudSync', message);
            break;
          case fcs.LogLevel.info:
            logger.info('CloudSync', message);
            break;
          case fcs.LogLevel.warning:
            logger.warning('CloudSync', message);
            break;
          case fcs.LogLevel.error:
            logger.error('CloudSync', message);
            break;
        }
      }),
    );
  }

  /// 云端槽位路径：`ledger_<slotKey>.json`。
  ///
  /// slotKey 用账本 syncId（跨设备稳定身份）而非本地数字 id —— 两台设备
  /// 各自新建的第一个账本本地 id 都是 1，按数字 id 命名会互相覆盖对方的
  /// 云端快照（同槽互覆）。syncId 缺失时退回本地数字 id，与 v21 迁移
  /// 「旧数据 syncId = id.toString()」的存量云端文件名天然兼容：已同步
  /// 用户升级后槽位不变，无需迁移。公开供 UI 层（如远程账本下载入口）
  /// 复用同一命名规则，避免两处实现漂移。
  ///
  /// 键字符约束：返回值必须保持 URL 安全（ASCII、无空格/保留字）——
  /// S3 SigV4 签名实现以解码 path 参与规范化（见 s3_signature.dart
  /// F8 注释）。slotKey 来源为 UUID/纯数字，天然满足；若未来引入其他
  /// 字符形态的键需同步评估签名链路。
  Future<String> pathForLedger(int ledgerId) async {
    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final syncId = row?.syncId?.trim();
    final key =
        (syncId != null && syncId.isNotEmpty) ? syncId : ledgerId.toString();
    return 'ledger_$key.json';
  }

  /// 把下载到的原始内容规整为「可解析的明文」。
  ///
  /// 场景：reset/disable 加密后 provider 未被装饰，storage.download 返回原始内容。
  /// - 非密文（legacy 明文）：原样返回。
  /// - 密文且本地有可用密钥（加密开启，或 [EncryptionService.disable] 后仍保留
  ///   secure storage 密钥）：调用 [EncryptionService.decrypt] 解密后返回。
  ///   这保证了 disable 契约——关闭加密只停止新上传加密，存量密文仍可用原密钥
  ///   恢复，用户不会在关闭加密后丢失云端备份访问。
  /// - 密文但本地无可用密钥（reset 后密钥清空、从未开启加密、或未注入加密服务）：
  ///   抛 [CloudEncryptedLocallyDisabledException]，由调用方/UI 引导用户走
  ///   「开启加密 → enableFromCloud」流程恢复，而非静默跳过让用户误以为云端无数据
  ///   （BUG-2 残留修复）。
  /// - 密钥存在但解密失败（salt 错配/密文损坏等）：抛
  ///   [CloudCiphertextUndecryptableException]，由调用方向用户明确呈现
  ///   「密文损坏/密钥不匹配」，不再静默返回 null 让恢复流程表现为
  ///   "什么都没发生"（SYNC-10 后半修复）。
  ///
  /// 取代原 [_isUnreadableCiphertext]：原实现仅以 `isEnabled` 判断，会把
  /// 「disable 后密钥仍保留」的场景也判为不可读，导致关闭加密后无法再从云端
  /// 恢复存量密文备份（即 BUG-1 的残余阻塞点）。
  ///
  /// 返回非空明文；不可解密场景一律抛异常（SYNC-10 后半），不再返回 null。
  Future<String> _decryptIfNeeded(String raw) async {
    if (!CiphertextFormat.isEncrypted(raw)) return raw;
    // 内容是密文：若加密服务可用且已开启，_provider 应已被装饰，
    // download 返回的是解密后的明文，不会走到这里。
    // 走到这里说明 provider 未装饰（加密未开启），需手动判断本地是否仍有密钥。
    if (encryptionService == null || !await encryptionService!.hasActiveKey) {
      // BUG-2 残留修复：云端为密文但本地未开启加密（或 reset 后无密钥）。
      // 旧实现静默返回 null 会让用户误以为云端无数据；此处抛专属异常，
      // 由 [downloadAndRestoreToCurrentLedger] / UI 引导用户开启加密恢复。
      throw CloudEncryptedLocallyDisabledException(
        '云端备份为加密密文，但本设备未开启加密或密钥已清空，'
        '请开启加密（使用原密码）以恢复云端数据',
      );
    }
    try {
      return await encryptionService!.decrypt(raw);
    } on Exception catch (e) {
      // SYNC-10 后半：密钥存在但密文不可解密（salt 错配/被其他设备用
      // 不同密码重加密/密文损坏）。本地确实无法解密——抛专属异常向上
      // 呈现，而非静默跳过。
      logger.warning('CloudSync', '本地密钥存在但密文解密失败: $e');
      throw CloudCiphertextUndecryptableException(
        '云端备份密文无法用本机密钥解密（密码可能已变更或密文损坏）。\n'
        '若你记得原密码，请在加密设置中用它激活密钥后再试；'
        '或先上传本地数据覆盖云端备份。',
        cause: e,
      );
    }
  }

  /// BUG-2 残留修复：探测"云端为密文但本地未开启加密"的 split-brain 子场景，
  /// 返回引导用哨兵 [SyncStatus]；非此场景返回 null，调用方继续正常流程。
  ///
  /// 设备 B 从未开启加密（或 reset 清空密钥）时，provider 未被装饰，
  /// 云端 BEECRYPT1: 密文无法被 [fcs.CloudSyncManager.getStatus] 正常解析
  /// （JSON 解码报错），旧实现走通用 catch 显示原始异常文本，用户误以为云端无数据。
  /// 本方法主动探测此场景，返回哨兵 'cloud_encrypted_locally_disabled' 供 UI 识别，
  /// 弹密码对话框走 [EncryptionService.enableFromCloud] 恢复。
  Future<SyncStatus?> _cloudEncryptedLocallyDisabledStatus(int ledgerId) async {
    if (!await _isCloudCiphertextLocallyDisabled(ledgerId)) return null;
    logger.warning(
        'CloudSync', '云端为密文但本地未开启加密，需引导用户开启加密: $ledgerId');
    return SyncStatus(
      diff: SyncDiff.error,
      localCount: 0,
      localFingerprint: '',
      message: 'cloud_encrypted_locally_disabled',
    );
  }

  /// 判断是否处于"云端为密文但本地未开启加密"状态。
  ///
  /// 判定条件（全部满足才返回 true）：
  /// - 加密服务已注入；且
  /// - 加密未开启（provider 未装饰，密文不会被自动解密）；且
  /// - 本地无可用密钥（排除 disable 后密钥仍保留可手动解密的场景）；且
  /// - 云端内容确为 BEECRYPT1 密文
  Future<bool> _isCloudCiphertextLocallyDisabled(int ledgerId) async {
    if (encryptionService == null) return false;
    if (await encryptionService!.isEnabled) return false;
    if (await encryptionService!.hasActiveKey) return false;
    // 本地无可用密钥：探测云端内容是否为密文
    final raw = _rawStorage;
    if (raw == null) return false;
    try {
      final content =
          await raw.download(path: await pathForLedger(ledgerId));
      return content != null && CiphertextFormat.isEncrypted(content);
    } catch (e) {
      logger.warning('CloudSync', 'BUG-2 探测下载失败，跳过: $ledgerId', e);
      return false;
    }
  }

  /// 本地最近变更证据：墙钟时间戳 + 该时间戳是否可信。
  ///
  /// M1：之前取 `MAX(happened_at)`（业务时间）——补录历史账是记账 App 的
  /// 高频操作，MAX(happened_at) 停在过去，与云端 uploadedAt（上传墙钟）
  /// 比较必然误判方向（本地新数据被判「云端较新」，启动检查弹错误提示；
  /// 反向误判则触发无意义覆盖上传）。
  ///
  /// 现在三层来源，全部墙钟语义：
  /// 1. `_recentLocalChangeAt`：本 session 内存墙钟（写路径已登记）→ 可信；
  /// 2. `MAX(local_changes.created_at)`（本账本 + user-global ledger_id=0
  ///    —— 账户/分类/标签改动同样改变快照内容）：持久化墙钟。**仅当该
  ///    作用域存在未推送行时才可信** —— 未推送行证明最后一次记录的编辑
  ///    尚未上云，时间戳与内容新旧状态一致；
  /// 3. 全部已推送 / 无任何行：时间戳只能证明「上次同步前有过编辑」，
  ///    无法排除其后 recordChanges:false 导入（快照恢复 / fullPull /
  ///    云端账本导入都不写 local_changes）带来的内容变化 → 标记不可信。
  ///    仲裁方对不可信证据必须按「方向未知」处理：宁可多弹一次合并
  ///    确认，也不能凭失真时间戳自动放行覆盖（丢云端他机数据）或误报
  ///    「云端较新」（诱导用户放弃本地更新数据）。
  Future<({DateTime? at, bool trusted})> _localChangeEvidence(
      int ledgerId) async {
    DateTime? dbMax;
    var unpushed = 0;
    try {
      final maxQuery = db.selectOnly(db.localChanges)
        ..addColumns([db.localChanges.createdAt.max()])
        ..where(db.localChanges.ledgerId.isIn([ledgerId, 0]));
      final row = await maxQuery.getSingleOrNull();
      dbMax = row?.read(db.localChanges.createdAt.max());

      final countQuery = db.selectOnly(db.localChanges)
        ..addColumns([db.localChanges.id.count()])
        ..where(db.localChanges.pushedAt.isNull() &
            db.localChanges.ledgerId.isIn([ledgerId, 0]));
      final cntRow = await countQuery.getSingleOrNull();
      unpushed = cntRow?.read(db.localChanges.id.count()) ?? 0;
    } catch (e) {
      logger.warning('CloudSync', '读取本地 local_changes 变更证据失败: $e');
    }

    final recentChange = _recentLocalChangeAt[ledgerId];
    if (recentChange != null) {
      return (
        at: dbMax == null || recentChange.isAfter(dbMax) ? recentChange : dbMax,
        trusted: true,
      );
    }
    return (at: dbMax, trusted: unpushed > 0);
  }

  /// 方向判断用的本地墙钟（getStatus 透传给 flutter_cloud_sync 做展示级
  /// 方向判定）。只取时间值不做可信度裁决：包内 cloudNewer 仅用于路由到
  /// 「下载预览合并」入口（有 diff 预览兜底，不会静默覆盖），失真时间戳
  /// 在此的最坏后果是多弹一次可取消的合并提示；真正的覆盖放行决策走
  /// [_detectUploadConflict] 的可信度门禁。
  Future<DateTime?> _computeLocalUpdatedAt(int ledgerId) async {
    final evidence = await _localChangeEvidence(ledgerId);
    return evidence.at;
  }

  @override
  Future<void> uploadCurrentLedger(
      {required int ledgerId, bool force = false}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _syncManager 置 null 导致 NPE（ATTACH-2 竞态防护）
    final manager = _syncManager;
    final provider = _provider;
    if (manager == null || provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始上传账本 $ledgerId');

      // 上传前先计算本地指纹（用于记录上传快照）
      String? localFp;
      int? localCount;
      Map<String, dynamic>? exportMap;
      String? exportedJson;
      try {
        exportedJson = await exportTransactionsJson(db, ledgerId);
        exportMap = jsonDecode(exportedJson) as Map<String, dynamic>;
        localFp = _contentFingerprintFromMap(exportMap);
        localCount = (exportMap['count'] as num?)?.toInt();
      } catch (e) {
        logger.warning('CloudSync', '计算本地指纹失败: $e');
      }

      // M7：并发覆盖止血（last-writer-wins）。非 force 时先做冲突判定：
      // 云端快照更新 / 方向无法判定但内容不同 → 抛 CloudConflictException，
      // 由 UI 确认后 force:true 重试。内部流程（全量上传已有双重确认、
      // 合并后回传、Critical-07 换名）直接传 force:true 不受影响。
      if (!force) {
        final conflict = await _detectUploadConflict(
          provider: provider,
          ledgerId: ledgerId,
          localFp: localFp,
        );
        if (conflict != null) {
          logger.warning('CloudSync',
              '上传冲突拦截: ledger=$ledgerId direction=$conflict '
              '(等待用户确认覆盖)');
          throw CloudConflictException(direction: conflict);
        }
      }

      // m-02 修复：将账本摘要信息写入 metadata，
      // 供 getRemoteLedgers 直接读取，避免逐个下载文件解析 JSON
      final uploadMetadata = <String, String>{
        'version': '2',
        'uploadedAt': DateTime.now().toUtc().toIso8601String(),
        'ledgerId': ledgerId.toString(),
      };
      if (exportMap != null) {
        final name = exportMap['ledgerName'] as String? ?? exportMap['name'] as String?;
        final currency = exportMap['currency'] as String?;
        final balance = exportMap['balance'] as num?;
        final exportedAt = exportMap['exportedAt'] as String?;
        if (name != null) uploadMetadata['ledgerName'] = name;
        if (currency != null) uploadMetadata['currency'] = currency;
        if (localCount != null) uploadMetadata['count'] = localCount.toString();
        if (balance != null) uploadMetadata['balance'] = balance.toString();
        if (exportedAt != null) uploadMetadata['exportedAt'] = exportedAt;
        if (localFp != null) uploadMetadata['fingerprint'] = localFp;
      }

      // 附件对象必须先于 ledger JSON 上传(上传顺序协议):清单里引用的
      // attachments/<sha256>.bin 得先存在,恢复端才能补齐文件。单对象
      // 失败已在内部吞掉,不阻断 JSON 上传。
      try {
        await uploadAttachmentObjects(ledgerId: ledgerId);
      } catch (e) {
        logger.warning('CloudSync', '附件对象上传异常(不阻断账本上传): $e');
      }

      await manager.upload(
        data: ledgerId,
        path: await pathForLedger(ledgerId),
        metadata: uploadMetadata,
        // F6：复用刚导出的同一份 JSON 与指纹，避免 manager 内部二次全量
        // 导出（大账本代价高），并消除两次导出间 DB 变化导致的
        // 「本地缓存指纹 ≠ 云端 metadata 指纹」错位。
        serializedData: exportedJson,
        fingerprint: localFp,
      );

      // 记录近期上传，用于处理 CDN 缓存延迟
      if (localFp != null && localCount != null) {
        _recentUpload[ledgerId] = _RecentUpload(
          at: DateTime.now(),
          fp: localFp,
          count: localCount,
        );
        // 立即更新缓存为"已同步"状态
        _statusCache[ledgerId] = _CachedStatus(
          SyncStatus(
            diff: SyncDiff.inSync,
            localCount: localCount,
            localFingerprint: localFp,
            cloudCount: localCount,
            cloudFingerprint: localFp,
            cloudExportedAt: DateTime.now(),
          ),
        );
      } else {
        // 指纹计算失败，清除缓存等待下次查询
        _statusCache.remove(ledgerId);
      }

      // 清除本地变更标记
      _recentLocalChangeAt.remove(ledgerId);

      // F2：快照上传成功 = 本账本 + user-global 的未推送变更均已随快照
      // 上云，标记 pushedAt：
      // ① 阻止 local_changes 无限膨胀（Path A 此前永不 markPushed，
      //    cleanupPushedChanges 也因此无行可清）；
      // ② 让 _localChangeEvidence 的「未推送行存在才可信」门禁恢复设计
      //    语义（M1/M7）：上传后时间戳与内容新旧状态重新对齐。
      // 失败不阻断（下次上传会重新标记）。
      try {
        final tracker = repo.changeTracker;
        if (tracker != null) {
          await tracker.markSnapshotPushed(ledgerId: ledgerId);
          unawaited(tracker.cleanupPushedChanges());
        }
      } catch (e) {
        logger.warning('CloudSync', '标记本地变更已推送失败(不影响本次上传): $e');
      }

      logger.info('CloudSync', '上传完成: $ledgerId');
    } catch (e, stack) {
      logger.error('CloudSync', '上传失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  /// 批量上传所有本地账本到云端（串行逐个上传，单个失败不中断）。
  ///
  /// 串行而非并行：避免并发上传打满 WebDAV/S3 连接数限制，且
  /// uploadCurrentLedger 内部写 _recentUpload/_statusCache（Map），
  /// 串行天然无竞态。返回 (success, failed) 统计，语义对齐
  /// [restoreAllRemoteLedgers]。
  ///
  /// [onProgress] 每完成一个账本回调 (done, total)，供 UI 阻塞弹窗展示进度。
  Future<({int success, int failed})> uploadAllLedgers({
    void Function(int done, int total)? onProgress,
  }) async {
    await _ensureInitialized();

    final ledgers = await db.select(db.ledgers).get();
    var success = 0;
    var failed = 0;
    var done = 0;
    for (final ledger in ledgers) {
      try {
        // M7：批量上传是显式的「全量覆盖」动作（UI 侧已有双重危险确认），
        // force 跳过逐账本冲突拦截，避免整批被逐个弹窗打断。
        await uploadCurrentLedger(ledgerId: ledger.id, force: true);
        success++;
      } catch (e) {
        // 单个账本失败只计数并继续，避免一个账本故障拖垮整批备份
        logger.warning('CloudSync', '批量上传账本 ${ledger.id} 失败: $e');
        failed++;
      }
      done++;
      onProgress?.call(done, ledgers.length);
    }
    return (success: success, failed: failed);
  }

  // ============================================================
  // 附件二进制同步(attachment_binary_sync,快照链路 Path A)
  // ============================================================

  /// 附件对象的云端路径:与 ledger_<id>.json 同级的 attachments/ 目录,
  /// 按内容寻址命名 —— 相同内容(同 sha256)跨账本/跨交易只存一份。
  @visibleForTesting
  String pathForAttachmentBin(String sha256) => 'attachments/$sha256.bin';

  /// 上传某账本全部附件二进制对象到云端(内容寻址)。
  ///
  /// 上传顺序协议:必须先于 ledger_<id>.json 调用 —— 清单里引用的对象
  /// 得先存在,否则恢复端拿到"永远缺文件"的清单。单个对象失败不阻断
  /// 账本 JSON 上传(清单仍带 sha256,恢复端 drain 会持续尝试),仅计数
  /// 并 warning。exists() 探测已存在的对象直接跳过(去重 + 省流量)。
  ///
  /// 返回 (uploaded, skipped, failed) 统计供调用方汇总。
  Future<({int uploaded, int skipped, int failed})>
      uploadAttachmentObjects({required int ledgerId}) async {
    await _ensureInitialized();
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    // 收集该账本所有交易的附件行(localSha256 非空才可内容寻址),
    // 按 sha256 去重 —— 同一图片挂多笔交易只传一份。
    final txIds = await (db.selectOnly(db.transactions)
          ..addColumns([db.transactions.id])
          ..where(db.transactions.ledgerId.equals(ledgerId)))
        .map((row) => row.read(db.transactions.id)!)
        .get();
    if (txIds.isEmpty) return (uploaded: 0, skipped: 0, failed: 0);

    final atts = await (db.select(db.transactionAttachments)
          ..where((a) =>
              a.transactionId.isIn(txIds) & a.localSha256.isNotNull()))
        .get();

    // sha256 -> 候选本地文件名(内容相同,任一存在的物理文件即可作为源)
    final filesBySha = <String, List<String>>{};
    for (final a in atts) {
      final sha = a.localSha256;
      if (sha == null || sha.isEmpty) continue;
      filesBySha.putIfAbsent(sha, () => []).add(a.fileName);
    }
    if (filesBySha.isEmpty) return (uploaded: 0, skipped: 0, failed: 0);

    final appDir = await getApplicationDocumentsDirectory();
    final attDir = Directory('${appDir.path}/attachments');

    var uploaded = 0;
    var skipped = 0;
    var failed = 0;
    final pool = _Semaphore(4);
    await Future.wait(filesBySha.entries.map((entry) async {
      final sha = entry.key;
      await pool.acquire();
      try {
        // 源文件缺失(孤儿附件行)或云端已存在 → 跳过
        String? srcPath;
        for (final name in entry.value) {
          final f = File('${attDir.path}/$name');
          if (await f.exists()) {
            srcPath = f.path;
            break;
          }
        }
        if (srcPath == null) {
          skipped++;
          logger.warning('CloudSync',
              '附件本地文件缺失,跳过上传: sha256=$sha (${entry.value.first})');
          return;
        }
        if (await provider.storage.exists(path: pathForAttachmentBin(sha))) {
          skipped++;
          return;
        }
        // base64 编码为 String 走既有 encrypt(加密装饰器透明处理),
        // 与账本快照的加密语义一致(设计决策 2)
        final b64 = base64Encode(await File(srcPath).readAsBytes());
        await provider.storage
            .upload(path: pathForAttachmentBin(sha), data: b64);
        uploaded++;
      } catch (e) {
        failed++;
        logger.warning('CloudSync', '附件对象上传失败 sha256=$sha: $e');
      } finally {
        pool.release();
      }
    }));

    if (uploaded > 0 || failed > 0) {
      logger.info('CloudSync',
          '附件对象上传完成(账本 $ledgerId): 上传=$uploaded 跳过=$skipped 失败=$failed');
    }
    return (uploaded: uploaded, skipped: skipped, failed: failed);
  }

  /// 恢复/导入完成后,把"清单带 sha256 且本地文件缺失"的附件入下载队列。
  ///
  /// 元数据导入(importTransactionsJson)会落 localSha256 列;这里只做
  /// 文件存在性检查,不抛错(缺文件不该影响恢复主流程的结果)。
  Future<void> enqueueMissingAttachmentJobs(int ledgerId) async {
    try {
      final txIds = await (db.selectOnly(db.transactions)
            ..addColumns([db.transactions.id])
            ..where(db.transactions.ledgerId.equals(ledgerId)))
          .map((row) => row.read(db.transactions.id)!)
          .get();
      if (txIds.isEmpty) return;

      final atts = await (db.select(db.transactionAttachments)
            ..where((a) =>
                a.transactionId.isIn(txIds) & a.localSha256.isNotNull()))
          .get();
      if (atts.isEmpty) return;

      final appDir = await getApplicationDocumentsDirectory();
      final attDir = Directory('${appDir.path}/attachments');
      for (final a in atts) {
        final sha = a.localSha256!;
        if (sha.isEmpty) continue;
        // 同 sha 已在队列 → 跳过(内容寻址,一份对象补一个文件名即可;
        // 极端情况下同 sha 不同 ext 的行会复用队列里的第一个 fileName)
        if (_pendingAttachmentJobs.any((j) => j.sha256 == sha)) continue;
        if (await File('${attDir.path}/${a.fileName}').exists()) continue;
        _pendingAttachmentJobs.add((sha256: sha, fileName: a.fileName));
      }
    } catch (e) {
      logger.warning('CloudSync', '附件补齐任务入队失败(ledgerId=$ledgerId): $e');
    }
  }

  /// 消费附件下载队列:并发(semaphore 4)下载 → 解密 → base64 解码 →
  /// sha256 校验 → 落盘。失败(已重试 3 次)回队,下次 drain 再试,
  /// 对齐 drainCustomIconQueue 的回队模式。
  ///
  /// 恢复主流程不等待本方法(附件下载可能分钟级,交易数据必须先可用);
  /// 在恢复完成、云端账本导入、以及下次任何同步操作(_ensureInitialized)
  /// 时触发。返回成功补齐的文件数。
  Future<int> drainAttachmentJobs() async {
    if (_isDrainingAttachments || _pendingAttachmentJobs.isEmpty) return 0;
    _isDrainingAttachments = true;
    try {
      final provider = _provider;
      if (provider == null) return 0;

      final jobs = List<({String sha256, String fileName})>.from(
          _pendingAttachmentJobs);
      _pendingAttachmentJobs.clear();

      final failed = <({String sha256, String fileName})>[];
      final pool = _Semaphore(4);
      final results = await Future.wait(jobs.map((job) async {
        await pool.acquire();
        try {
          final ok = await _downloadAttachmentBinWithRetry(provider, job);
          if (!ok) failed.add(job);
          return ok;
        } finally {
          pool.release();
        }
      }));

      if (failed.isNotEmpty) {
        _pendingAttachmentJobs.addAll(failed);
        logger.warning('CloudSync',
            '附件补齐下载失败 ${failed.length}/${jobs.length},回队等下次 drain');
      }
      final ok = results.where((r) => r).length;
      if (ok > 0) {
        logger.info('CloudSync', '附件补齐完成: $ok/${jobs.length}');
      }
      return ok;
    } finally {
      _isDrainingAttachments = false;
    }
  }

  /// 单个附件对象下载 + 校验 + 落盘,3 次指数退避重试。
  ///
  /// sha256 校验必做:内容寻址的信任根基是"路径即哈希",不校验就把
  /// 损坏/错配的对象当成品落盘,且因文件名带 sha 永远不会再被修复。
  Future<bool> _downloadAttachmentBinWithRetry(
    fcs.CloudProvider provider,
    ({String sha256, String fileName}) job,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final raw =
            await provider.storage.download(path: pathForAttachmentBin(job.sha256));
        if (raw == null) {
          // 云端对象不存在(上传端失败的竞态):回队意义有限但成本低,
          // 保持与其他失败一致的处理。
          throw fcs.CloudStorageException('附件对象不存在: ${job.sha256}');
        }
        // 与账本 JSON 同一口径处理密文(加密开启时 storage 已自动解密,
        // isEncrypted=false 直接通过;disable 后残留密钥场景手动解密;
        // 密文不可解密时 _decryptIfNeeded 抛专属异常,由下方 catch 计入重试/失败)
        final plain = await _decryptIfNeeded(raw);
        final bytes = base64Decode(plain);
        // 校验内容哈希与路径声明一致,拒绝损坏/错配对象
        final actual = crypto.sha256.convert(bytes).toString();
        if (actual != job.sha256) {
          throw fcs.CloudStorageException(
              '附件 sha256 不匹配: expect=${job.sha256} actual=$actual');
        }
        final appDir = await getApplicationDocumentsDirectory();
        final dest = File('${appDir.path}/attachments/${job.fileName}');
        await dest.parent.create(recursive: true);
        await dest.writeAsBytes(bytes, flush: true);
        return true;
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    logger.warning('CloudSync',
        '附件下载失败 sha256=${job.sha256} after 3 attempts: $lastError');
    return false;
  }

  @override
  Future<({int inserted, int deletedDup})>
      downloadAndRestoreToCurrentLedger({required int ledgerId}) {
    // W6：整本下载恢复属破坏性全量替换（清空后导入），必须处于
    // SyncRestoreGuard 恢复临界区内 —— 定时备份（app.dart）每轮 tick 检查
    // isBusy 让位。否则恢复进行到一半时到点的备份会把半恢复态 DB 打包
    // 上传，覆盖当日好备份，恰好摧毁灾难恢复能力。
    return SyncRestoreGuard.run(
        () => _downloadAndRestoreToCurrentLedger(ledgerId: ledgerId));
  }

  Future<({int inserted, int deletedDup})>
      _downloadAndRestoreToCurrentLedger({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _provider 置 null 导致 NPE（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始下载账本 $ledgerId');

      // 槽位路径解析一次复用（下载 + 指纹自检两处引用，省一次账本行查询）
      final remotePath = await pathForLedger(ledgerId);

      // 直接使用 storage 下载原始 JSON 字符串
      final raw = await provider.storage.download(path: remotePath);

      if (raw == null) {
        logger.warning('CloudSync', '云端备份不存在');
        return (inserted: 0, deletedDup: 0);
      }

      // 规整为可解析明文：disable 后密钥仍保留 → 解密存量密文并恢复；
      // reset 后无密钥 / 密钥错配或密文损坏 → 抛专属异常（SYNC-10 后半），
      // 由 UI 明确提示，不再静默返回 inserted:0 让用户以为"什么都没发生"。
      final jsonStr = await _decryptIfNeeded(raw);

      // M4：内容 vs 元数据指纹交叉自检（软告警，不阻断）
      await _warnIfRemoteFingerprintMismatch(
        provider: provider,
        path: remotePath,
        plainJson: jsonStr,
      );

      // 复用公共恢复管线（P1-1 守卫 + 事务内清空导入），
      // 与云端备份恢复（CloudBackupService）同一语义单一事实源
      final restored = await restoreLedgerFromJson(
          db: db, repo: repo, ledgerId: ledgerId, jsonStr: jsonStr);
      if (restored == null) {
        return (inserted: 0, deletedDup: 0);
      }
      final result = restored.inserted;
      final deletedDupCount = restored.deletedDup;

      logger.info('CloudSync',
          '下载完成: inserted=$result, deletedDup=$deletedDupCount, skippedRecurring=${restored.skippedRecurring}');
      if (restored.skippedRecurring > 0) {
        logger.warning('CloudSync',
            '恢复时有 ${restored.skippedRecurring} 笔同日周期实例被判重跳过'
            '（同规则同日且syncId或金额+备注相同），请核对源端是否存在同日多笔合法交易');
      }

      // 附件二进制后台补齐(不阻塞恢复返回):元数据已入库,缺的文件
      // 从 attachments/<sha256>.bin 异步下载,失败回队下次 drain 重试。
      unawaited(enqueueMissingAttachmentJobs(ledgerId)
          .then((_) => drainAttachmentJobs()));

      // 清除缓存
      _statusCache.remove(ledgerId);
      _recentLocalChangeAt.remove(ledgerId);
      _recentUpload.remove(ledgerId);

      return (
        inserted: result,
        deletedDup: deletedDupCount,
      );
    } on CloudEncryptedLocallyDisabledException {
      // BUG-2 残留修复：云端为密文但本地未开启加密（已在 _decryptIfNeeded 抛出）。
      // 不视为下载失败（不打 error 堆栈），向上抛出由 UI 引导用户开启加密。
      logger.warning(
          'CloudSync', '云端为密文但本地未开启加密，需引导用户开启加密: $ledgerId');
      rethrow;
    } on CloudCiphertextUndecryptableException {
      // SYNC-10 后半：密钥存在但密文不可解密（损坏/salt 错配/密码已变更）。
      // 向上抛出由 UI 明确呈现，不再落入通用 catch 被当作普通失败吞掉。
      logger.warning('CloudSync', '云端密文无法用本机密钥解密，恢复中止: $ledgerId');
      rethrow;
    } catch (e, stack) {
      logger.error('CloudSync', '下载失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);

      // m-04 修复：优先用类型匹配判断 404，字符串匹配作为兜底
      if (e is fcs.CloudFileNotFoundException ||
          e.toString().contains('404') ||
          e.toString().contains('not found')) {
        return (inserted: 0, deletedDup: 0);
      }

      rethrow;
    }
  }

  /// 清空指定账本交易的操作已迁移为公共函数
  /// `clearLedgerTransactions`（data_import_service.dart），
  /// 与云端备份恢复共用同一实现，避免两条链路产生语义分叉。

  /// 下载云端数据并计算 diff 预览
  ///
  /// 返回 (preview, importData, jsonVersion) 或 null（云端无数据）
  /// - preview 为 null 表示无法计算 diff（旧格式），应走全量替换
  /// - preview 不为 null 表示可以预览
  Future<({SyncPreview? preview, ImportData importData, int version})?> downloadAndPreview({
    required int ledgerId,
  }) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    logger.info('CloudSync', '开始下载预览: $ledgerId');

    final raw = await provider.storage
        .download(path: await pathForLedger(ledgerId));

    if (raw == null) {
      logger.warning('CloudSync', '云端备份不存在');
      return null;
    }

    // 规整为可解析明文：disable 后密钥仍保留则解密；无密钥或密文不可
    // 解密（SYNC-10）抛专属异常，由调用方/UI 明确呈现错误，不再当作
    // 「云端无数据」静默返回 null。
    final jsonStr = await _decryptIfNeeded(raw);

    // 解析 JSON
    final jsonData = jsonDecode(jsonStr) as Map<String, dynamic>;
    final version = (jsonData['version'] as num?)?.toInt() ?? 1;
    final importData = parseJsonToImportData(jsonStr);

    // 检查是否含 syncId（v6+）
    if (version >= 6) {
      final preview = await syncDiffService.computeDiff(
        repo: repo,
        ledgerId: ledgerId,
        cloudTransactions: importData.transactions,
      );

      if (preview != null) {
        return (preview: preview, importData: importData, version: version);
      }
    }

    // 旧格式或无法计算 diff
    return (preview: null, importData: importData, version: version);
  }

  /// 应用预览中选中的变更
  Future<SyncApplyResult> applyPreviewChanges({
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) async {
    final result = await syncDiffService.applySyncChanges(
      repo: repo,
      ledgerId: ledgerId,
      selectedChanges: selectedChanges,
      importData: importData,
    );

    // 清除缓存
    _statusCache.remove(ledgerId);
    _recentLocalChangeAt.remove(ledgerId);
    _recentUpload.remove(ledgerId);

    // 附件差异贯通：modified 合并可能带入带 sha256 的附件清单，本地缺的
    // 文件从 attachments/<sha256>.bin 后台补齐（与下载恢复路径同口径，
    // 不阻塞 apply 返回）。
    if (result.totalCount > 0) {
      unawaited(enqueueMissingAttachmentJobs(ledgerId)
          .then((_) => drainAttachmentJobs()));
    }

    return result;
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _syncManager/_provider 置 null 导致 NPE（ATTACH-2 竞态防护）
    final manager = _syncManager;
    // 如果 provider 不可用，返回未登录状态
    if (manager == null || _provider == null) {
      return SyncStatus(
        diff: SyncDiff.notLoggedIn,
        localCount: 0,
        localFingerprint: '',
        message: '云服务不可用，请检查配置或登录状态',
      );
    }

    // 检查缓存（m-03 修复：TTL 过期则视为未命中）
    final cached = _statusCache[ledgerId];
    if (cached != null && !cached.isExpired) {
      logger.debug('CloudSync', '缓存命中: ledgerId=$ledgerId, diff=${cached.status.diff}');
      return cached.status;
    }
    if (cached != null && cached.isExpired) {
      logger.debug('CloudSync', '缓存过期，重新计算: ledgerId=$ledgerId');
      _statusCache.remove(ledgerId);
    }

    logger.debug('CloudSync', '缓存未命中，开始计算: ledgerId=$ledgerId');

    try {
      // 计算本地指纹
      final jsonStr = await exportTransactionsJson(db, ledgerId);
      final localMap = jsonDecode(jsonStr) as Map<String, dynamic>;
      final localFp = _contentFingerprintFromMap(localMap);
      final localCount = (localMap['count'] as num?)?.toInt() ?? 0;

      // 若刚刚上传成功且在短时间窗口内（15秒），且本地指纹与上传时一致，直接认定已同步
      final ru = _recentUpload[ledgerId];
      if (ru != null) {
        final age = DateTime.now().difference(ru.at);
        if (age < const Duration(seconds: 15) && ru.fp == localFp) {
          final st = SyncStatus(
            diff: SyncDiff.inSync,
            localCount: localCount,
            localFingerprint: localFp,
            cloudCount: ru.count,
            cloudFingerprint: ru.fp,
            cloudExportedAt: ru.at,
          );
          _statusCache[ledgerId] = _CachedStatus(st);
          logger.info('CloudSync', '使用近期上传缓存: $ledgerId -> 已同步');
          return st;
        }
      }

      // BUG-2 残留修复：本地未开启加密且无密钥时，先探测云端是否为密文。
      // 若是，直接返回哨兵 'cloud_encrypted_locally_disabled' 引导用户开启加密，
      // 避免 manager.getStatus 把密文当 JSON 解析报错（用户误以为云端无数据/看到原始异常）。
      // 探测仅在「加密未开启 + 无密钥」这一 inherently broken 状态下触发，正常状态立即返回 null。
      final disabledStatus = await _cloudEncryptedLocallyDisabledStatus(ledgerId);
      if (disabledStatus != null) return disabledStatus;

      logger.info('CloudSync', '获取同步状态: $ledgerId');

      // 调用包的 getStatus，传入时间戳用于方向判断
      final fcsStatus = await manager.getStatus(
          data: ledgerId,
          path: await pathForLedger(ledgerId),
          localUpdatedAt: await _computeLocalUpdatedAt(ledgerId),
          forceRefresh: true,
          // F6：复用上方已导出的 JSON，省去 manager 内部对同一账本的
          // 第二次全量导出
          localSerializedData: jsonStr);

      // 转换包的 SyncStatus 为 PiggyCount 的 SyncStatus
      final status = _convertSyncStatus(fcsStatus);

      // 缺口 1: fcs.CloudSyncManager 内部捕获 SaltMismatchException 后返回 error 状态，
      // message 含原始异常文本（如 "Failed to get sync status: SaltMismatchException: ..."）。
      // 检测并转为哨兵 message 'salt_mismatch_need_password' 供 UI 识别并弹密码对话框。
      if (status.diff == SyncDiff.error &&
          status.message != null &&
          status.message!.contains('SaltMismatchException')) {
        logger.warning('CloudSync',
            'salt 不匹配，需引导用户重新输入密码: $ledgerId');
        return SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        );
      }

      // 错误状态不写入 _statusCache：
      // fcs.CloudSyncManager 内部捕获 storage 异常后返回 error 状态（不抛出），
      // 若缓存该状态，瞬时错误（网络抖动、临时 401、salt 错配）会持续阻挡，
      // 下次调用应重新走完整流程。salt_mismatch_need_password 同样不缓存。
      if (status.diff != SyncDiff.error) {
        _statusCache[ledgerId] = _CachedStatus(status);
      }
      logger.info('CloudSync', '同步状态: $ledgerId -> ${status.diff}');
      if (status.diff != SyncDiff.inSync &&
          status.localFingerprint.length >= 8) {
        // 指纹不一致时提升为 INFO：sync_convergence 排查依赖本地/云端
        // 指纹对比（前 8 位足够定位），debug 级默认不可见
        logger.info('CloudSync',
            '指纹不一致 本地: ${status.localFingerprint.substring(0, 8)} '
            '云端: ${status.cloudFingerprint != null && status.cloudFingerprint!.length >= 8 ? status.cloudFingerprint!.substring(0, 8) : "无"} '
            '数量 本地${status.localCount}/云端${status.cloudCount ?? "无"}');
      }
      logger.debug('CloudSync', '本地指纹: ${status.localFingerprint}');
      logger.debug('CloudSync', '云端指纹: ${status.cloudFingerprint ?? "无"}');
      logger.debug('CloudSync', '本地数量: ${status.localCount}, 云端数量: ${status.cloudCount ?? "无"}');

      return status;
    } on SaltMismatchException catch (e) {
      // 缺口 1: SaltMismatchException 转为哨兵 message，供 UI 层识别
      // 并弹出"重新输入密码"对话框（而非显示原始异常文本）。
      // 不缓存（已由 US-6 原则保证：error 状态一律不缓存），
      // 用户重输密码后应立即生效而非读到旧错误。
      logger.warning('CloudSync', 'salt 不匹配，需引导用户重新输入密码: $ledgerId', e);
      return SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: 'salt_mismatch_need_password',
      );
    } catch (e, stack) {
      logger.error('CloudSync', '获取状态失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈: $stack', null);

      // 错误状态不写入 _statusCache：
      // 瞬时错误（网络抖动、临时 401、salt 错配）不应持续阻挡，
      // 下次调用应重新走完整流程。salt_mismatch_need_password 同样不缓存，
      // 用户重输密码后应立即生效而非读到旧错误。
      return SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: e.toString(),
      );
    }
  }

  /// 转换包的 SyncStatus 为 PiggyCount 的 SyncStatus
  SyncStatus _convertSyncStatus(fcs.SyncStatus fcsStatus) {
    SyncDiff diff;

    switch (fcsStatus.state) {
      case fcs.SyncState.notConfigured:
        diff = SyncDiff.notConfigured;
        break;
      case fcs.SyncState.notAuthenticated:
        diff = SyncDiff.notLoggedIn;
        break;
      case fcs.SyncState.localOnly:
        diff = SyncDiff.noRemote;
        break;
      case fcs.SyncState.synced:
        diff = SyncDiff.inSync;
        break;
      case fcs.SyncState.outOfSync:
        // 根据方向确定
        if (fcsStatus.direction == fcs.SyncDirection.localNewer) {
          diff = SyncDiff.localNewer;
        } else if (fcsStatus.direction == fcs.SyncDirection.cloudNewer) {
          diff = SyncDiff.cloudNewer;
        } else {
          diff = SyncDiff.different;
        }
        break;
      case fcs.SyncState.error:
        diff = SyncDiff.error;
        break;
      default:
        diff = SyncDiff.different;
    }

    return SyncStatus(
      diff: diff,
      localCount: fcsStatus.localCount ?? 0,
      cloudCount: fcsStatus.cloudCount,
      localFingerprint: fcsStatus.localFingerprint ?? '',
      cloudFingerprint: fcsStatus.cloudFingerprint,
      cloudExportedAt: fcsStatus.cloudUpdatedAt,
      message: fcsStatus.message,
    );
  }

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final manager = _syncManager;
    if (manager == null) {
      return (fingerprint: null, count: null, exportedAt: null);
    }

    try {
      logger.info('CloudSync', '刷新云端指纹: $ledgerId');

      // 强制刷新状态
      final status = await manager.getStatus(
        data: ledgerId,
        path: await pathForLedger(ledgerId),
        localUpdatedAt: await _computeLocalUpdatedAt(ledgerId),
        forceRefresh: true,
      );

      // 清除缓存以便下次 getStatus 重新获取
      _statusCache.remove(ledgerId);

      logger.info('CloudSync',
          '云端指纹: 指纹=${status.cloudFingerprint} 条数=${status.cloudCount} 时间=${status.cloudUpdatedAt}');

      return (
        fingerprint: status.cloudFingerprint,
        count: status.cloudCount,
        exportedAt: status.cloudUpdatedAt,
      );
    } catch (e) {
      logger.warning('CloudSync', '刷新云端指纹失败: $ledgerId - $e');
      return (fingerprint: null, count: null, exportedAt: null);
    }
  }

  @override
  void markLocalChanged({required int ledgerId}) {
    _statusCache.remove(ledgerId);
    _recentLocalChangeAt[ledgerId] = DateTime.now();
    logger.info('CloudSync', '标记本地变更: $ledgerId');
  }

  /// M7：上传前冲突判定。返回冲突方向（'cloudNewer'/'unknown'），
  /// null = 可安全上传。
  ///
  /// 判定链：
  /// 1. 云端无快照 → 直接传（localOnly 语义）；
  /// 2. 指纹相等 → 内容一致，直接传（最常见快路径）；
  /// 3. 指纹不等/缺失 → 方向仲裁，但**只信有未推送行佐证的本地墙钟**
  ///    （[_localChangeEvidence]）：
  ///    - 可信且本地较新 = 正常覆盖语义放行；
  ///    - 可信且云端较新 = 覆盖会丢另一台设备的同步 → 冲突 'cloudNewer'；
  ///    - 时间相同 / 本地无证据 / **证据不可信**（全已推送或无行 ——
  ///      recordChanges:false 导入会让纯 local_changes 时间戳失真，
  ///      既可能把新数据判旧放行覆盖、也可能把旧数据判新误报云端较新）
  ///      → 'unknown' 冲突，由上层给出「对比合并」入口而非二选一；
  /// 4. 探测自身失败（网络等）→ 放行：可用性优先，行为等同旧版。
  ///
  /// 注意 M2 指纹算法升级的迁移窗口：旧元数据指纹与新算法必有一轮错位，
  /// 此时会落到 unknown 冲突——用户走一次对比合并（或确认覆盖）即写入
  /// 新算法元数据，永久收敛。
  Future<String?> _detectUploadConflict({
    required fcs.CloudProvider provider,
    required int ledgerId,
    required String? localFp,
  }) async {
    try {
      final meta = await provider.storage
          .getMetadata(path: await pathForLedger(ledgerId));
      if (meta == null) return null; // 云端无备份

      final remoteFp = _metaValue(meta.metadata, 'fingerprint');
      if (localFp != null &&
          remoteFp != null &&
          localFp == remoteFp) {
        return null; // 内容一致
      }

      // 指纹不同（或一侧缺失）→ 方向仲裁（只信可信证据）
      final remoteAt =
          DateTime.tryParse(_metaValue(meta.metadata, 'uploadedAt') ?? '') ??
              meta.lastModified;
      if (remoteAt == null) return 'unknown';
      final evidence = await _localChangeEvidence(ledgerId);
      final localAt = evidence.at;
      if (!evidence.trusted || localAt == null) return 'unknown';
      if (localAt.isAfter(remoteAt)) return null; // 本地较新：正常覆盖
      if (remoteAt.isAfter(localAt)) return 'cloudNewer';
      return 'unknown'; // 同秒且内容不同：无法判定
    } catch (e) {
      // F5：认证失败不是「探测不到」而是「确定读不到云端状态」——此时
      // 放行上传会静默盖掉其他设备的数据，且用户得不到任何修复指引。
      // 向上抛出由调用方按凭据错误引导（启动检查器/UI 均已区分
      // CloudAuthException）。其余瞬态故障（网络抖动等）维持原取舍：
      // 可用性优先，行为等同旧版。
      if (e is fcs.CloudAuthException) rethrow;
      logger.warning('CloudSync', '上传冲突检测失败（放行上传）: $e');
      return null;
    }
  }

  /// 从 JSON payload 计算内容指纹
  ///
  /// 委托给共享函数 [contentFingerprintFromMap]（US-5 抽取），
  /// 规范化规则与序列化器侧保持一致，避免双份实现漂移。
  String _contentFingerprintFromMap(Map<String, dynamic> payload) =>
      contentFingerprintFromMap(payload);

  /// M4：下载内容与元数据指纹交叉自检（软告警版，不阻断恢复）。
  ///
  /// 包内 CloudSyncManager.download 自带完整性校验，但 App 层全部直连
  /// provider.storage.download，该防线是死代码 —— CDN 陈旧副本/网关截断
  /// 只能靠 jsonDecode 抛异常兜底。此处在「已解密明文」上对齐同等检查：
  ///
  /// - 元数据无指纹（旧快照）→ 静默跳过；
  /// - 指纹不一致 → **warning 不抛异常**。M2 指纹算法升级（纳入
  ///   ledgerName/currency）后，旧算法写入的云端元数据必有一轮错位，
  ///   硬失败会把「一次性 outOfSync」恶化成「恢复被阻断」，本末倒置。
  Future<void> _warnIfRemoteFingerprintMismatch({
    required fcs.CloudProvider provider,
    required String path,
    required String plainJson,
  }) async {
    try {
      final meta = await provider.storage.getMetadata(path: path);
      final raw = _metaValue(meta?.metadata, 'fingerprint');
      if (raw == null || raw.isEmpty) return;
      final remoteFp = _normalizeFingerprintMeta(raw);
      Map<String, dynamic> map;
      try {
        map = jsonDecode(plainJson) as Map<String, dynamic>;
      } catch (_) {
        logger.warning('CloudSync',
            '完整性自检：下载内容不是 JSON 对象(path=$path)，请留意数据完整性');
        return;
      }
      final contentFp = _contentFingerprintFromMap(map);
      if (contentFp != remoteFp) {
        logger.warning('CloudSync',
            '完整性自检：云端快照指纹不一致(path=$path) '
            'metadata=$remoteFp content=$contentFp。'
            '可能为 CDN 陈旧副本或旧算法元数据；恢复继续执行');
      }
    } catch (e) {
      // 自检是尽力而为的旁路，任何失败都不影响主恢复流程
      logger.debug('CloudSync', '完整性自检跳过: $e');
    }
  }

  /// 归一化 metadata 指纹值：剥离 'b64:' 包装（S3 客户端通常已解码，
  /// 这里对 WebDAV sidecar 原文/历史残留兜底），补齐被网关剥掉的 padding。
  static String _normalizeFingerprintMeta(String v) {
    if (!v.startsWith('b64:')) return v;
    final payload = v.substring(4);
    try {
      return utf8.decode(base64.decode(payload));
    } on FormatException {
      try {
        return utf8.decode(base64.decode(base64.normalize(payload)));
      } on FormatException {
        return v;
      }
    }
  }

  /// 大小写无关读取云端 metadata 并做 b64 归一化。
  ///
  /// HTTP 头名大小写不敏感：S3 链路 x-amz-meta-* 的键经传输层统一转
  /// 小写，写入端的 'uploadedAt' 在读取端实际是 'uploadedat'。直接
  /// [] 读取恒 miss → uploadedAt 解析失败、方向仲裁退化到 lastModified。
  /// 按小写匹配对 S3 与 WebDAV sidecar（保留原始键名）都兼容。
  static String? _metaValue(Map<String, dynamic>? metadata, String key) {
    if (metadata == null) return null;
    final target = key.toLowerCase();
    for (final entry in metadata.entries) {
      if (entry.key.toLowerCase() == target) {
        final v = entry.value;
        return v == null ? null : _normalizeFingerprintMeta(v.toString());
      }
    }
    return null;
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final manager = _syncManager;
    if (manager == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '删除云端备份: $ledgerId');

      await manager.deleteRemote(path: await pathForLedger(ledgerId));

      // 清除缓存
      _statusCache.remove(ledgerId);
      _recentLocalChangeAt.remove(ledgerId);
      _recentUpload.remove(ledgerId);

      logger.info('CloudSync', '删除完成: $ledgerId');
    } catch (e) {
      // m-04 修复：优先用类型匹配判断 404，字符串匹配作为兜底
      if (e is fcs.CloudFileNotFoundException ||
          e.toString().contains('404') ||
          e.toString().contains('not found')) {
        logger.warning('CloudSync', '云端备份不存在（忽略）: $ledgerId');
        return;
      }

      logger.error('CloudSync', '删除失败: $ledgerId', e);
      rethrow;
    }
  }

  // L4 死代码清理：getLocalLedgers / getRemoteLedgers / getAllLedgers 已无
  // 任何调用方（UI 远端账本入口统一走 discoverRemoteLedgers / importRemoteLedger，
  // 本地账本列表走 repositoryProvider.getAllLedgers），整组删除 —— 其中
  // getRemoteLedgers 的 metadata/下载解析逻辑与 discoverRemoteLedgers 重复，
  // 留着只会多一份需要同步修 bug 的副本。

  /// 刷新所有账本的同步状态（后台预热缓存）
  Future<void> refreshAllLedgersStatus() async {
    await _ensureInitialized();

    try {
      final ledgers = await db.select(db.ledgers).get();

      for (final ledger in ledgers) {
        try {
          await getStatus(ledgerId: ledger.id);
        } catch (e) {
          logger.warning('CloudSync', '刷新账本 ${ledger.id} 状态失败: $e');
        }
      }

      logger.info('CloudSync', '已刷新 ${ledgers.length} 个账本的同步状态');
    } catch (e) {
      logger.error('CloudSync', '刷新所有账本状态失败', e);
    }
  }

  /// 审计 S12：为与本地现有账本撞名的导入生成不冲突的名字
  /// （"账本" → "账本（2）" → "账本（3）"…）。
  static String _dedupeLedgerName(Iterable<Ledger> existing, String base) {
    final taken = existing.map((l) => l.name).toSet();
    if (!taken.contains(base)) return base;
    var i = 2;
    while (taken.contains('$base（$i）')) {
      i++;
    }
    return '$base（$i）';
  }

  /// 下载远程账本（创建新的本地账本或复用同源账本）
  ///
  /// 本地账本复用优先级：
  /// 1. 存在同名账本 → 复用该行（H2 既定语义：用户主动下载即以云端为准覆盖）
  /// 2. 槽位 key 对应的 syncId 已存在本地行 → 复用（同源账本认领）
  /// 3. 否则新建本地账本行，**syncId = 槽位 key**（本地 id 自动分配）
  ///
  /// 云端文件收尾（Critical-07 修复）：先上传新槽位再删旧文件；目标槽位
  /// 与远程路径一致时不做任何换名操作。
  Future<int?> downloadRemoteLedger({
    required String name,
    required String currency,
    required String remotePath,
  }) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '下载远程账本: $remotePath');

      // 从远程路径提取槽位 key（= 源端账本 syncId；legacy 文件为数字 id 串）
      final slotKey = _slotKeyFromPath(remotePath);

      // 审计 S12：同名复用是 H2 既定语义（用户主动下载该账本 → 以云端
      // 为准覆盖），保留。但 getSingleOrNull 在本地已有多个同名账本时抛
      // "Too many elements" 直接崩——改为取第一行（take-first）。
      final sameNameRows = await (db.select(db.ledgers)
            ..where((t) => t.name.equals(name)))
          .get();
      final existingByName =
          sameNameRows.isEmpty ? null : sameNameRows.first;

      final int ledgerId;
      bool reusedExistingRow = false;

      if (existingByName != null) {
        // 复用同名账本的行（不创建新账本）
        ledgerId = existingByName.id;
        reusedExistingRow = true;
        logger.info('CloudSync',
            '本地已存在同名账本，复用账本ID: $ledgerId (名称: $name)');
      } else if (slotKey != null) {
        final sameIdentity = await _localLedgerForSlotKey(slotKey);
        if (sameIdentity != null) {
          ledgerId = sameIdentity.id;
          reusedExistingRow = true;
          logger.info('CloudSync',
              '本地已有同源账本(syncId=$slotKey)，复用账本ID: $ledgerId');
        } else {
          // 新建：id 自动分配、身份锚定槽位 key。不再沿用远端数字 id ——
          // 两台设备各自的自增序列独立，按 id 撞号正是同槽互覆的根源。
          ledgerId = await db.into(db.ledgers).insert(
                LedgersCompanion.insert(
                  name: name,
                  currency: drift.Value(currency),
                  syncId: drift.Value(slotKey),
                ),
              );
          logger.info('CloudSync',
              '创建新账本: id=$ledgerId, syncId=$slotKey');
        }
      } else {
        // 无法解析槽位 key 的异常路径：退回旧行为新建匿名账本
        ledgerId = await db.into(db.ledgers).insert(
              LedgersCompanion.insert(
                name: name,
                currency: drift.Value(currency),
              ),
            );
        logger.info('CloudSync', '远程路径无槽位 key，创建新账本 id=$ledgerId');
      }

      // 下载数据
      final raw = await provider.storage.download(path: remotePath);

      if (raw == null) {
        logger.warning('CloudSync', '云端账本不存在: $remotePath');
        // 只有本次新建的账本才需要删除
        if (!reusedExistingRow) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId))).go();
        }
        return null;
      }

      // 规整为可解析明文：disable 后密钥仍保留则解密后导入；
      // 无密钥 / 密文不可解密（SYNC-10 后半）→ 清理本次新建的账本行
      // 后向上抛专属异常，由 UI 明确呈现，不再静默跳过导入。
      final String jsonStr;
      try {
        jsonStr = await _decryptIfNeeded(raw);
      } on CloudEncryptedLocallyDisabledException catch (e) {
        logger.warning(
            'CloudSync', '云端账本 $remotePath 为密文且本地无可用密钥: $e');
        if (!reusedExistingRow) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId))).go();
        }
        rethrow;
      } on CloudCiphertextUndecryptableException catch (e) {
        logger.warning('CloudSync', '云端账本 $remotePath 密文不可解密: $e');
        if (!reusedExistingRow) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId))).go();
        }
        rethrow;
      }

      // M4：内容 vs 元数据指纹交叉自检（软告警，不阻断）
      await _warnIfRemoteFingerprintMismatch(
        provider: provider,
        path: remotePath,
        plainJson: jsonStr,
      );

      // H2：同名/既有账本的云端下载统一走「先清空再导入」的覆盖语义
      // （restoreLedgerFromJson：含 P1-1 空快照守卫 + 事务原子 +
      // recordChanges:false + v9 sync_id 回填），与
      // downloadAndRestoreToCurrentLedger / 全量覆盖恢复对齐，
      // 消除旧实现「同名账本追加合并 → 交易翻倍」。
      final restored = await restoreLedgerFromJson(
          db: db, repo: repo, ledgerId: ledgerId, jsonStr: jsonStr);
      if (restored == null) {
        // P1-1 拒绝空覆盖：本地未接受云端状态，云端文件原样保留，
        // 也不做下方的「上传新槽位/删旧文件」换名操作。
        logger.warning('CloudSync',
            '云端快照为空且本地非空，拒绝覆盖，保留本地与云端现状: $remotePath');
        return null;
      }
      logger.info('CloudSync',
          '下载完成(覆盖语义): ledgerId=$ledgerId, inserted=${restored.inserted}, 清空=${restored.deletedDup}, skippedRecurring=${restored.skippedRecurring}');
      if (restored.skippedRecurring > 0) {
        logger.warning('CloudSync',
            '恢复时有 ${restored.skippedRecurring} 笔同日周期实例被判重跳过，请核对源端明细');
      }

      // 云端文件收尾：目标槽位与远程文件名不一致时才需要换名
      // （Critical-07：先上传后删除，防删除成功但上传失败丢数据）。
      final targetPath = await pathForLedger(ledgerId);
      if (_baseName(targetPath) != _baseName(remotePath)) {
        // M7：刚以云端为准恢复完本地（内容一致），force 跳过冲突拦截
        try {
          await uploadCurrentLedger(ledgerId: ledgerId, force: true);
          logger.info('CloudSync', '账本已上传到云端: $targetPath');
          // 上传成功后再删除旧文件
          try {
            await provider.storage.delete(path: remotePath);
            logger.info('CloudSync', '旧远程文件已删除: $remotePath');
          } catch (e) {
            logger.warning('CloudSync', '删除旧远程文件失败（忽略，新文件已上传）: $e');
          }
        } catch (e) {
          logger.warning('CloudSync', '上传账本失败（旧文件保留）: $e');
        }
      } else {
        logger.info('CloudSync', '槽位一致，无需更新云端文件: $targetPath');
      }

      return ledgerId;
    } catch (e, stack) {
      logger.error('CloudSync', '下载远程账本失败: $remotePath', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  /// 删除远程账本（仅云端）
  Future<void> deleteRemoteLedger({required String remotePath}) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '删除远程账本: $remotePath');

      await provider.storage.delete(path: remotePath);

      logger.info('CloudSync', '删除完成: $remotePath');
    } catch (e) {
      // m-04 修复：优先用类型匹配判断 404，字符串匹配作为兜底
      if (e is fcs.CloudFileNotFoundException ||
          e.toString().contains('404') ||
          e.toString().contains('not found')) {
        logger.warning('CloudSync', '远程账本不存在（忽略）: $remotePath');
        return;
      }

      logger.error('CloudSync', '删除远程账本失败: $remotePath', e);
      rethrow;
    }
  }

  /// 恢复所有远程账本到本地（并行执行）
  ///
  /// W6/S6 补口：本入口内部的 [downloadRemoteLedger] 对同名/同身份账本
  /// 执行「清空+导入」的破坏性替换，与 [fullRestoreAllRemoteLedgers] /
  /// [downloadAndRestoreToCurrentLedger] 同属恢复临界区操作 —— 必须让
  /// 定时备份（app.dart BackupScheduler tick 检查 isBusy）让位，否则
  /// 批量恢复进行到一半时到点的备份会把半恢复态 DB 打包上传，覆盖当日
  /// 好备份。此前仅全量覆盖下载有守卫，本入口遗漏。
  Future<({int success, int failed})> restoreAllRemoteLedgers() {
    return SyncRestoreGuard.run(() => _restoreAllRemoteLedgers());
  }

  Future<({int success, int failed})> _restoreAllRemoteLedgers() async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始恢复所有远程账本');

      // 列出所有远程账本文件
      final files = await provider.storage.list(path: '');

      // 过滤出账本文件，并排除本地已有对应身份的（按槽位 key 解析，
      // 不再比较数字 id 集合 —— 两台设备 id 序列独立，数字对比不可靠）
      final ledgerFiles = <fcs.CloudFile>[];
      for (final file in files) {
        final match = _ledgerFileNamePattern.firstMatch(file.name);
        if (match == null) continue;
        if (await _localLedgerForSlotKey(match.group(1)!) != null) {
          logger.info('CloudSync', '跳过已有对应账本的远程文件: ${file.name}');
          continue;
        }
        ledgerFiles.add(file);
      }

      logger.info('CloudSync', '找到 ${ledgerFiles.length} 个需要恢复的远程账本文件');

      // 并行恢复所有账本
      final results = await Future.wait(
        ledgerFiles.map((file) async {
          try {
            // 下载文件内容以获取账本信息（使用 file.name 而非 file.path）
            final raw = await provider.storage.download(path: file.name);
            if (raw == null) {
              logger.warning('CloudSync', '下载失败: ${file.name}');
              return false;
            }

            // H3 补漏：密文快照先解密再解析；无密钥/密文损坏计为该文件
            // 恢复失败，不再让 jsonDecode 报格式错误误导排查。
            final String jsonStr;
            try {
              jsonStr = await _decryptIfNeeded(raw);
            } on CloudEncryptedLocallyDisabledException {
              logger.warning('CloudSync', '远程账本 ${file.name} 为密文且本地无可用密钥');
              return false;
            } on CloudCiphertextUndecryptableException {
              logger.warning('CloudSync', '远程账本 ${file.name} 密文无法用本机密钥解密');
              return false;
            }

            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final name = json['ledgerName'] as String? ??
                json['name'] as String? ??
                'Unknown';
            final currency = json['currency'] as String? ?? 'CNY';

            // 下载远程账本
            final ledgerId = await downloadRemoteLedger(
              name: name,
              currency: currency,
              remotePath: file.name,
            );

            if (ledgerId != null) {
              logger.info('CloudSync', '恢复成功: ${file.name} -> ledgerId=$ledgerId');
              return true;
            } else {
              logger.warning('CloudSync', '恢复失败: ${file.name}');
              return false;
            }
          } catch (e) {
            logger.warning('CloudSync', '恢复账本失败: ${file.name} - $e');
            return false;
          }
        }),
      );

      // 统计结果
      final success = results.where((r) => r).length;
      final failed = results.where((r) => !r).length;

      logger.info('CloudSync', '恢复完成: 成功=$success, 失败=$failed');
      return (success: success, failed: failed);
    } catch (e, stack) {
      logger.error('CloudSync', '恢复所有远程账本失败', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  /// 全量覆盖下载：把云端所有账本快照无条件刷到本地
  /// （调用方已通过双重危险确认，见 cloud_sync_page 全量覆盖卡片）
  ///
  /// 与 [restoreAllRemoteLedgers] 的区别：
  /// - 本地已有同身份账本的文件不跳过，而是用 [downloadAndRestoreToCurrentLedger]
  ///   整体覆盖本地数据（清空后导入，含账户 syncId 去重，流程同现有恢复）
  /// - 云端独有的账本仍走 [downloadRemoteLedger] 导入新建
  /// - 本地独有的账本不做任何处理（保留）
  ///
  /// 串行执行：恢复会批量写库，并行易触发数据库锁竞争；
  /// 单个账本失败只计数不中断整批（语义对齐 uploadAllLedgers）。
  Future<({int success, int failed})> fullRestoreAllRemoteLedgers({
    void Function(int done, int total)? onProgress,
  }) {
    // W6：全量覆盖下载是最大粒度的破坏性恢复，整个批次都处于
    // SyncRestoreGuard 恢复临界区内（守卫为计数器，内部嵌套调用
    // downloadAndRestoreToCurrentLedger 的二次 begin/end 安全）。
    return SyncRestoreGuard.run(() => _fullRestoreAllRemoteLedgers(
        onProgress: onProgress));
  }

  Future<({int success, int failed})> _fullRestoreAllRemoteLedgers({
    void Function(int done, int total)? onProgress,
  }) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始全量覆盖下载所有远程账本');

      final files = await provider.storage.list(path: '');
      final ledgerFiles =
          files.where((f) => _ledgerFileNamePattern.hasMatch(f.name)).toList();
      final localCount = (await db.select(db.ledgers).get()).length;
      logger.info(
          'CloudSync', '云端共 ${ledgerFiles.length} 个账本文件，本地已有 $localCount 个账本');

      var success = 0;
      var failed = 0;
      for (final file in ledgerFiles) {
        final slotKey =
            _ledgerFileNamePattern.firstMatch(file.name)!.group(1)!;
        try {
          // 按槽位 key 解析本地同身份账本（syncId 匹配，数字 key 兜底 id 匹配）
          final local = await _localLedgerForSlotKey(slotKey);
          if (local != null) {
            // 本地已有该账本：云端快照整体覆盖本地数据
            await downloadAndRestoreToCurrentLedger(ledgerId: local.id);
          } else {
            // 云端独有账本：下载元信息后导入为新建本地账本
            final raw = await provider.storage.download(path: file.name);
            if (raw == null) {
              throw fcs.CloudSyncException('云端文件下载为空: ${file.name}');
            }
            // H3 补漏：密文快照先解密再解析（与 downloadRemoteLedger 同口径）
            final jsonStr = await _decryptIfNeeded(raw);
            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            final name = json['ledgerName'] as String? ??
                json['name'] as String? ??
                'Unknown';
            final currency = json['currency'] as String? ?? 'CNY';
            final ledgerId = await downloadRemoteLedger(
              name: name,
              currency: currency,
              remotePath: file.name,
            );
            if (ledgerId == null) {
              throw fcs.CloudSyncException('云端账本导入失败: ${file.name}');
            }
          }
          success++;
        } catch (e) {
          failed++;
          logger.warning('CloudSync', '全量恢复账本失败: ${file.name} - $e');
        }
        onProgress?.call(success + failed, ledgerFiles.length);
      }

      logger.info('CloudSync', '全量覆盖下载完成: 成功=$success, 失败=$failed');
      return (success: success, failed: failed);
    } catch (e, stack) {
      logger.error('CloudSync', '全量覆盖下载所有远程账本失败', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  // ============ 云端账本发现（跨设备新建账本同步） ============

  /// 发现阶段缓存的远端 payload（槽位 key → 解密后的 JSON 明文）
  ///
  /// [discoverRemoteLedgers] 下载文件提取元信息时顺手缓存，
  /// [importRemoteLedger] 优先用缓存避免同一文件二次下载。
  final Map<String, String> _discoveredPayloads = {};

  /// 云端账本文件名模式：ledger_<slotKey>.json
  ///
  /// slotKey 是账本 syncId（新建账本为 UUID；v21 迁移把 legacy 账本回填成
  /// 数字 id 字符串）。历史快照（槽位改版前）直接用本地数字 id 当 key，
  /// 纯数字形态与 syncId 回填值天然重合，一个宽松正则同时覆盖两种形态。
  static final RegExp _ledgerFileNamePattern = RegExp(r'^ledger_(.+)\.json$');

  /// 从远程路径提取槽位 key（取末段文件名做匹配，容忍目录前缀）
  static String? _slotKeyFromPath(String remotePath) {
    final base = remotePath.split('/').last;
    return _ledgerFileNamePattern.firstMatch(base)?.group(1);
  }

  /// 取路径末段文件名（list 返回 name、调用方可能传带前缀的 path）
  static String _baseName(String path) => path.split('/').last;

  /// 槽位 key → 本地账本行的身份解析：
  /// 1. syncId 精确匹配（正路径：syncId 命名的槽位）；
  /// 2. 纯数字 key 兜底按本地 id 匹配 —— 兼容 syncId 尚未回填的 legacy 行。
  ///    数字 id 撞名互覆正是槽位改用 syncId 要消除的隐患，但存量数字
  ///    文件仍须能被既有账本认领，否则升级后各设备会把对方的账本
  ///    当「新账本」重复导入。
  Future<Ledger?> _localLedgerForSlotKey(String key) async {
    final bySyncId = await (db.select(db.ledgers)
          ..where((l) => l.syncId.equals(key)))
        .get();
    if (bySyncId.isNotEmpty) return bySyncId.first;
    final numericId = int.tryParse(key);
    if (numericId == null) return null;
    return await (db.select(db.ledgers)..where((l) => l.id.equals(numericId)))
        .getSingleOrNull();
  }

  /// 列出云端存在、但本机没有对应账本身份的账本文件，提取元信息
  ///
  /// 设计见 /prd/remote_ledger_discovery/design.md（v2 槽位语义）：
  /// - 槽位 key 即账本 syncId；本地没有对应 syncId（纯数字 key 也撞不上
  ///   本地 id）时，说明该账本是在其他设备新建后上传的
  /// - 单个文件下载/解密/解析失败只跳过该账本（记日志），不影响其他
  /// - 返回的 meta 供确认弹窗展示；payload 已缓存供后续导入复用
  Future<List<RemoteLedgerMeta>> discoverRemoteLedgers() async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    _discoveredPayloads.clear();

    final files = await provider.storage.list(path: '');
    final metas = <RemoteLedgerMeta>[];
    for (final file in files) {
      final match = _ledgerFileNamePattern.firstMatch(file.name);
      if (match == null) continue;
      final slotKey = match.group(1)!;
      // 本地已有同身份账本行：该文件由既有逐账本检查流程负责，
      // 不属于"发现"范畴
      if (await _localLedgerForSlotKey(slotKey) != null) continue;

      try {
        final raw = await provider.storage.download(path: file.name);
        if (raw == null) {
          logger.warning('CloudSync', '发现账本 $slotKey 下载返回空，跳过');
          continue;
        }
        // 密文场景：provider 已装饰时 download 即明文；未装饰（本地未开
        // 加密）或密文不可解密（SYNC-10）时 _decryptIfNeeded 抛专属异常
        final jsonStr = await _decryptIfNeeded(raw);
        final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
        _discoveredPayloads[slotKey] = jsonStr;
        metas.add(RemoteLedgerMeta(
          slotKey: slotKey,
          name: (payload['ledgerName'] as String?) ?? '云端账本 $slotKey',
          currency: (payload['currency'] as String?) ?? 'CNY',
          monthStartDay:
              ((payload['monthStartDay'] as num?)?.toInt() ?? 1).clamp(1, 28),
          txCount: (payload['count'] as num?)?.toInt() ?? 0,
        ));
      } on CloudEncryptedLocallyDisabledException {
        // 无可用密钥：跳过该账本（加密恢复走既有的哨兵引导流程）
        logger.warning('CloudSync', '发现账本 $slotKey 为密文且本地无密钥，跳过');
      } on CloudCiphertextUndecryptableException {
        // 密钥存在但不可解密（损坏/错配）：发现阶段仅列举，跳过该账本，
        // 用户点导入时会在 importRemoteLedger 中得到明确报错。
        logger.warning('CloudSync', '发现账本 $slotKey 密文无法用本机密钥解密，跳过');
      } catch (e) {
        logger.warning('CloudSync', '发现账本 $slotKey 失败，跳过: $e');
      }
    }

    logger.info('CloudSync', '云端账本发现完成: ${metas.length} 个本机没有的账本');
    return metas;
  }

  /// 导入一个发现阶段的云端账本：以槽位 key 作为 syncId 创建本地账本行
  /// 并导入数据。
  ///
  /// 返回**导入的交易条数**；返回 null 表示同 syncId 账本已被本地占用
  /// （发现与导入之间的竞态），该账本被跳过。
  ///
  /// 关键语义：**不再保留远端数字 id**——两台设备各自的自增序列独立，
  /// 按 id 撞号正是同槽互覆的根源。本地 id 自动分配，syncId = 槽位 key，
  /// 身份跨设备稳定后本地指纹与云端一致，后续启动检查自然 inSync。
  /// legacy 数字槽位沿用 key 作 syncId，与 v21 迁移「id 回填 syncId」
  /// 口径一致。
  Future<int?> importRemoteLedger(RemoteLedgerMeta meta) async {
    await _ensureInitialized();

    // payload 优先取发现阶段缓存，未命中（如进程内首次直接导入）重新下载
    var jsonStr = _discoveredPayloads[meta.slotKey];
    if (jsonStr == null) {
      final provider = _provider;
      if (provider == null) {
        throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
      }
      final path = 'ledger_${meta.slotKey}.json';
      final raw = await provider.storage.download(path: path);
      if (raw == null) {
        throw fcs.CloudSyncException('云端账本文件不存在: $path');
      }
      // 密文不可解密（SYNC-10）时 _decryptIfNeeded 抛专属异常，直接向上
      // 呈现比笼统的 CloudSyncException 更明确
      jsonStr = await _decryptIfNeeded(raw);
    }

    var importSkippedRecurring = 0;
    var inserted = 0;
    // 缓存命中/重新下载两条路径到这里都已提升为非空
    final payload = jsonStr;
    final newLedgerId = await db.transaction(() async {
      // 竞态守卫：发现与导入之间本地可能已导入同身份账本
      final existing = await _localLedgerForSlotKey(meta.slotKey);
      if (existing != null) {
        logger.warning(
            'CloudSync', '账本 syncId=${meta.slotKey} 已被本地占用，跳过导入');
        return null;
      }

      // 审计 S12：能走到这里的同名行必然身份不同（同身份已在上方守卫
      // 返回），一律改名导入（"账本（2）"），避免两个完全同名账本干扰
      // 用户与后续按名匹配逻辑。
      final importNameRows = await (db.select(db.ledgers)
            ..where((l) => l.name.equals(meta.name)))
          .get();
      final importName = importNameRows.isEmpty
          ? meta.name
          : _dedupeLedgerName(importNameRows, meta.name);

      final newId = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(
              name: importName,
              currency: drift.Value(meta.currency),
              monthStartDay: drift.Value(meta.monthStartDay),
              syncId: drift.Value(meta.slotKey),
            ),
          );

      // 从云端导入不写本地变更历史（P2-3），与下载恢复路径语义一致
      final result =
          await importTransactionsJson(repo, newId, payload,
              recordChanges: false);
      importSkippedRecurring = result.skippedRecurring;
      inserted = result.inserted;
      return newId;
    });

    _discoveredPayloads.remove(meta.slotKey);
    if (newLedgerId == null) return null;

    logger.info('CloudSync',
        '云端账本导入完成: localId=$newLedgerId, slotKey=${meta.slotKey}, name=${meta.name}, inserted=$inserted, skippedRecurring=$importSkippedRecurring');
    if (importSkippedRecurring > 0) {
      logger.warning('CloudSync',
          '导入时有 $importSkippedRecurring 笔同日周期实例被判重跳过，请核对源端明细');
    }

    // 附件二进制后台补齐(与下载恢复路径同款:不阻塞导入返回)
    unawaited(enqueueMissingAttachmentJobs(newLedgerId)
        .then((_) => drainAttachmentJobs()));
    return inserted;
  }
}

/// 简单计数信号量:限制附件对象上传/下载的并发数(4),避免打满
/// WebDAV/S3 的连接数限制。acquire 挂起等待,release 唤醒一个等待者。
class _Semaphore {
  final int _max;
  int _count = 0;
  final _waiters = <Completer<void>>[];

  _Semaphore(this._max);

  Future<void> acquire() {
    if (_count < _max) {
      _count++;
      return Future.value();
    }
    final c = Completer<void>();
    _waiters.add(c);
    return c.future;
  }

  void release() {
    if (_waiters.isNotEmpty) {
      _waiters.removeAt(0).complete();
    } else {
      _count--;
      if (_count < 0) _count = 0;
    }
  }
}

/// 云端账本元信息（发现阶段从 `ledger_<slotKey>.json` payload 提取）
class RemoteLedgerMeta {
  /// 云端槽位 key（= 源端账本 syncId；legacy 数字命名文件为 id 字符串）。
  /// 导入侧以它作为新账本行的 syncId，保证跨设备身份稳定。
  final String slotKey;
  final String name;
  final String currency;
  final int monthStartDay;
  final int txCount;

  const RemoteLedgerMeta({
    required this.slotKey,
    required this.name,
    required this.currency,
    required this.monthStartDay,
    required this.txCount,
  });
}

/// 账本交易数据序列化器
class _TransactionSerializer implements fcs.DataSerializer<int> {
  final PiggyDatabase db;

  _TransactionSerializer(this.db);

  @override
  Future<String> serialize(int ledgerId) async {
    return await exportTransactionsJson(db, ledgerId);
  }

  @override
  Future<int> deserialize(String data) async {
    final json = jsonDecode(data);
    // H1：老 JSON 无 ledgerId 或类型异常时返回 0 而非 CastError，
    // 由上层按「未知账本」分支处理
    return json is Map && json['ledgerId'] is num
        ? (json['ledgerId'] as num).toInt()
        : 0;
  }

  @override
  String fingerprint(String data) {
    final json = jsonDecode(data) as Map<String, dynamic>;
    return contentFingerprintFromMap(json);
  }
}

/// 近期上传记录（用于处理 CDN 缓存延迟）
class _RecentUpload {
  final DateTime at;
  final String fp;
  final int count;

  _RecentUpload({
    required this.at,
    required this.fp,
    required this.count,
  });
}

/// 带时间戳的同步状态缓存条目（m-03 修复）
///
/// 在 TTL 内有效，过期后视为未命中，防止其他设备上传后本地仍显示过时的"已同步"状态。
class _CachedStatus {
  final SyncStatus status;
  final DateTime cachedAt;

  _CachedStatus(this.status) : cachedAt = DateTime.now();

  bool get isExpired =>
      DateTime.now().difference(cachedAt) > TransactionsSyncManager._statusCacheTtl;
}
