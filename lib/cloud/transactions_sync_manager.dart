import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;

import '../data/db.dart';
import '../data/encryption/ciphertext_format.dart';
import '../data/encryption/encrypted_cloud_provider.dart';
import '../data/repositories/base_repository.dart';
import '../domain/encryption/encryption_service.dart';
import '../models/ledger_display_item.dart';
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';
import 'sync_diff_service.dart';
import 'sync_fingerprint.dart';
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
    final services = await fcs.createCloudServices(config);
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

  String _pathForLedger(int ledgerId) {
    return 'ledger_$ledgerId.json';
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
  /// - 密钥存在但解密失败（salt 错配等）：返回 null，由调用方跳过，避免 jsonDecode 崩溃。
  ///
  /// 取代原 [_isUnreadableCiphertext]：原实现仅以 `isEnabled` 判断，会把
  /// 「disable 后密钥仍保留」的场景也判为不可读，导致关闭加密后无法再从云端
  /// 恢复存量密文备份（即 BUG-1 的残余阻塞点）。
  Future<String?> _decryptIfNeeded(String raw) async {
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
      // 密钥存在但与密文不匹配（salt 错配/被其他设备用不同密码重加密等）：
      // 本地确实无法解密，视为不可读，避免崩溃。
      logger.warning('CloudSync', '本地密钥存在但密文解密失败，跳过: $e');
      return null;
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
      final content = await raw.download(path: _pathForLedger(ledgerId));
      return content != null && CiphertextFormat.isEncrypted(content);
    } catch (e) {
      logger.warning('CloudSync', 'BUG-2 探测下载失败，跳过: $ledgerId', e);
      return false;
    }
  }

  /// 本地最大发生时间（用于 flutter_cloud_sync 的方向判断）。
  /// 取 `max(最近本地写入时间, SELECT MAX(happened_at) WHERE ledger=...)`。
  /// 之前只返回 `_recentLocalChangeAt`，冷启动时为 null，方向判断只能靠 count。
  /// 两台设备交易条数相同、但内容不同的时候，count 判断会误判方向。
  Future<DateTime?> _computeLocalUpdatedAt(int ledgerId) async {
    final recentChange = _recentLocalChangeAt[ledgerId];
    DateTime? dbMax;
    try {
      final query = db.selectOnly(db.transactions)
        ..addColumns([db.transactions.happenedAt.max()])
        ..where(db.transactions.ledgerId.equals(ledgerId));
      final row = await query.getSingleOrNull();
      dbMax = row?.read(db.transactions.happenedAt.max());
    } catch (e) {
      logger.warning('CloudSync', '读取本地 MAX(happenedAt) 失败: $e');
    }
    if (recentChange == null) return dbMax;
    if (dbMax == null) return recentChange;
    return recentChange.isAfter(dbMax) ? recentChange : dbMax;
  }

  @override
  Future<void> uploadCurrentLedger({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _syncManager 置 null 导致 NPE（ATTACH-2 竞态防护）
    final manager = _syncManager;
    if (manager == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始上传账本 $ledgerId');

      // 上传前先计算本地指纹（用于记录上传快照）
      String? localFp;
      int? localCount;
      Map<String, dynamic>? exportMap;
      try {
        final jsonStr = await exportTransactionsJson(db, ledgerId);
        exportMap = jsonDecode(jsonStr) as Map<String, dynamic>;
        localFp = _contentFingerprintFromMap(exportMap);
        localCount = (exportMap['count'] as num?)?.toInt();
      } catch (e) {
        logger.warning('CloudSync', '计算本地指纹失败: $e');
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

      await manager.upload(
        data: ledgerId,
        path: _pathForLedger(ledgerId),
        metadata: uploadMetadata,
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

      logger.info('CloudSync', '上传完成: $ledgerId');
    } catch (e, stack) {
      logger.error('CloudSync', '上传失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);
      rethrow;
    }
  }

  @override
  Future<({int inserted, int deletedDup})>
      downloadAndRestoreToCurrentLedger({required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _provider 置 null 导致 NPE（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始下载账本 $ledgerId');

      // 直接使用 storage 下载原始 JSON 字符串
      final raw =
          await provider.storage.download(path: _pathForLedger(ledgerId));

      if (raw == null) {
        logger.warning('CloudSync', '云端备份不存在');
        return (inserted: 0, deletedDup: 0);
      }

      // 规整为可解析明文：disable 后密钥仍保留 → 解密存量密文并恢复；
      // reset 后无密钥 → 跳过恢复（避免崩溃），提示用户重新开启加密或上传覆盖。
      final jsonStr = await _decryptIfNeeded(raw);
      if (jsonStr == null) {
        logger.warning(
          'CloudSync',
          '云端存在加密密文但本地无可解密密钥，跳过恢复以避免崩溃。'
          '请重新开启加密（使用原密码）或先上传本地数据覆盖云端。',
        );
        return (inserted: 0, deletedDup: 0);
      }

      // 恢复前清空本地账本交易，避免追加式导入产生重复行（US-1）。
      // 清空 + 导入包裹在同一事务内：若导入失败，清空操作一并回滚，
      // 保证本地数据不会被部分清空。importTransactionsJson 内部的
      // db.transaction 会作为 savepoint 嵌套在本事务内。
      final deletedDup = await db.transaction(() async {
        final deleted = await _clearLedgerTransactions(ledgerId);
        return (deleted, await importTransactionsJson(repo, ledgerId, jsonStr));
      });

      final result = deletedDup.$2;

      logger.info('CloudSync',
          '下载完成: inserted=${result.inserted}, deletedDup=${deletedDup.$1}');

      // 清除缓存
      _statusCache.remove(ledgerId);
      _recentLocalChangeAt.remove(ledgerId);
      _recentUpload.remove(ledgerId);

      return (
        inserted: result.inserted,
        deletedDup: deletedDup.$1,
      );
    } on CloudEncryptedLocallyDisabledException {
      // BUG-2 残留修复：云端为密文但本地未开启加密（已在 _decryptIfNeeded 抛出）。
      // 不视为下载失败（不打 error 堆栈），向上抛出由 UI 引导用户开启加密。
      logger.warning(
          'CloudSync', '云端为密文但本地未开启加密，需引导用户开启加密: $ledgerId');
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

  /// 清空指定账本的全部交易及其关联行（transactionTags /
  /// transactionAttachments）。
  ///
  /// 用途：[downloadAndRestoreToCurrentLedger] 恢复云端数据前清空本地，
  /// 避免追加式导入产生重复行。不记录 local_changes（这是为云端数据
  /// 腾位置的本地操作，不应反向回流到云端）。
  ///
  /// 返回被删除的交易行数，供调用方填充 `deletedDup`（AC-1.3）。
  ///
  /// 注意：调用方应将其与导入操作包裹在同一事务内，保证原子性。
  Future<int> _clearLedgerTransactions(int ledgerId) async {
    // 先查出本账本所有交易 id，用于级联删 transactionTags / attachments
    final txIds = await (db.selectOnly(db.transactions)
          ..addColumns([db.transactions.id])
          ..where(db.transactions.ledgerId.equals(ledgerId)))
        .map((row) => row.read(db.transactions.id)!)
        .get();

    if (txIds.isEmpty) return 0;

    await (db.delete(db.transactionTags)
          ..where((t) => t.transactionId.isIn(txIds)))
        .go();
    await (db.delete(db.transactionAttachments)
          ..where((t) => t.transactionId.isIn(txIds)))
        .go();
    final deleted = await (db.delete(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .go();
    logger.info('CloudSync', '恢复前清空账本 $ledgerId: 删除 $deleted 笔交易');
    return deleted;
  }

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

    final raw =
        await provider.storage.download(path: _pathForLedger(ledgerId));

    if (raw == null) {
      logger.warning('CloudSync', '云端备份不存在');
      return null;
    }

    // 规整为可解析明文：disable 后密钥仍保留则解密；无密钥返回 null
    final jsonStr = await _decryptIfNeeded(raw);
    if (jsonStr == null) return null;

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
      final localCount = (localMap['count'] as num).toInt();

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
          path: _pathForLedger(ledgerId),
          localUpdatedAt: await _computeLocalUpdatedAt(ledgerId),
          forceRefresh: true);

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
        path: _pathForLedger(ledgerId),
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

  /// 从 JSON payload 计算内容指纹
  ///
  /// 委托给共享函数 [contentFingerprintFromMap]（US-5 抽取），
  /// 规范化规则与序列化器侧保持一致，避免双份实现漂移。
  String _contentFingerprintFromMap(Map<String, dynamic> payload) =>
      contentFingerprintFromMap(payload);

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

      await manager.deleteRemote(path: _pathForLedger(ledgerId));

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

  /// 获取本地账本列表
  Future<List<LedgerDisplayItem>> getLocalLedgers({bool accountFeatureEnabled = true}) async {
    await _ensureInitialized();

    final localLedgers = await db.select(db.ledgers).get();
    final result = <LedgerDisplayItem>[];

    for (final ledger in localLedgers) {
      // 使用 getLedgerStats 一次性获取余额和交易数，内部会自动查询 transactions
      final stats = await repo.getLedgerStats(
        ledgerId: ledger.id,
        accountFeatureEnabled: accountFeatureEnabled,
      );

      result.add(LedgerDisplayItem.fromLocal(
        id: ledger.id,
        name: ledger.name,
        currency: ledger.currency,
        createdAt: ledger.createdAt,
        transactionCount: stats.transactionCount,
        balance: stats.balance,
      ));
    }

    logger.info('CloudSync', '已加载本地账本: ${result.length} 个');
    return result;
  }

  /// 获取远程账本列表（仅云端，不在本地）
  Future<List<LedgerDisplayItem>> getRemoteLedgers() async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      logger.warning('CloudSync', 'Provider 不可用，无法获取远程账本列表');
      return [];
    }

    // 获取本地账本ID列表（用于过滤）
    final localLedgers = await db.select(db.ledgers).get();
    final localLedgerIds = localLedgers.map((l) => l.id).toSet();

    final result = <LedgerDisplayItem>[];

    // 直接从云端文件列表获取远程账本
    try {
      final files = await provider.storage.list(path: '');
      logger.info('CloudSync', '云端文件列表: ${files.map((f) => f.name).toList()}');
      int remoteCount = 0;

      for (final file in files) {
        try {
          // 只处理 ledger_*.json 文件
          final fileName = file.name;
          if (!fileName.startsWith('ledger_') || !fileName.endsWith('.json')) {
            continue;
          }

          // 从文件名提取账本ID
          final idStr =
              fileName.replaceAll('ledger_', '').replaceAll('.json', '');
          final remoteId = int.tryParse(idStr);
          if (remoteId == null) continue;

          // 如果本地已存在，跳过
          if (localLedgerIds.contains(remoteId)) continue;

          // m-02 修复：优先从 metadata 获取账本摘要信息，避免全量下载 JSON。
          // upload 时已将 ledgerName/currency/count/balance/exportedAt 写入 metadata，
          // 对于支持自定义元数据的 Provider（S3 HEAD / Supabase metadata 表），
          // 仅需 1 次轻量请求即可获取摘要，无需下载完整 JSON 文件。
          String? name;
          String? currency;
          int? transactionCount;
          double? balance;
          String? updatedAtStr;

          // 尝试从 list() 返回的 metadata 或 getMetadata() 获取
          var fileMeta = file.metadata;
          if (fileMeta == null || fileMeta.isEmpty || fileMeta['ledgerName'] == null) {
            try {
              final meta = await provider.storage.getMetadata(path: file.name);
              fileMeta = meta?.metadata;
            } catch (e) {
              logger.warning('CloudSync', 'getMetadata 失败: ${file.name} - $e');
            }
          }

          if (fileMeta != null && fileMeta['ledgerName'] != null) {
            // metadata 命中，直接构造（无需下载）
            name = fileMeta['ledgerName'];
            currency = fileMeta['currency'] ?? 'CNY';
            transactionCount = int.tryParse(fileMeta['count'] ?? '');
            balance = double.tryParse(fileMeta['balance'] ?? '');
            updatedAtStr = fileMeta['exportedAt'] ?? fileMeta['uploadedAt'];
            logger.info('CloudSync', '从 metadata 获取账本信息: $name (跳过下载)');
          }

          // metadata 未命中，回退到全量下载解析 JSON
          if (name == null) {
            logger.info('CloudSync', 'metadata 未命中，下载远程账本: ${file.name}');
            final jsonStr = await provider.storage.download(path: file.name);
            if (jsonStr == null) {
              logger.warning('CloudSync', '下载结果为空: ${file.name}');
              continue;
            }

            final json = jsonDecode(jsonStr) as Map<String, dynamic>;
            name = json['ledgerName'] as String? ?? json['name'] as String? ?? 'Unknown';
            currency = json['currency'] as String? ?? 'CNY';
            updatedAtStr = json['exportedAt'] as String?;
            transactionCount = json['count'] as int? ?? 0;

            if (json.containsKey('balance')) {
              balance = (json['balance'] as num?)?.toDouble() ?? 0.0;
            } else {
              var computed = 0.0;
              final items = (json['items'] as List?)?.cast<Map<String, dynamic>>() ?? [];
              for (final item in items) {
                final type = item['type'] as String?;
                final amount = (item['amount'] as num?)?.toDouble() ?? 0.0;
                if (type == 'income') {
                  computed += amount;
                } else if (type == 'expense') {
                  computed -= amount;
                }
              }
              balance = computed;
            }
          }

          DateTime updatedAt;
          try {
            updatedAt = DateTime.parse(updatedAtStr ?? '');
          } catch (_) {
            updatedAt = DateTime.now();
          }

          result.add(LedgerDisplayItem.fromRemote(
            remoteSyncId: remoteId.toString(),
            name: name,
            currency: currency ?? 'CNY',
            updatedAt: updatedAt,
            transactionCount: transactionCount ?? 0,
            balance: balance ?? 0.0,
          ));

          remoteCount++;
        } catch (e) {
          logger.warning('CloudSync', '解析远程账本文件失败: ${file.name} - $e');
          continue;
        }
      }

      logger.info('CloudSync', '已加载远程账本: $remoteCount 个');
    } catch (e) {
      logger.warning('CloudSync', '获取远程账本失败: $e');
      // 失败不影响，返回空列表
    }

    return result;
  }

  /// 获取所有账本（本地 + 云端）
  Future<List<LedgerDisplayItem>> getAllLedgers() async {
    await _ensureInitialized();

    // 并行获取本地和远程账本
    final results = await Future.wait([
      getLocalLedgers(),
      getRemoteLedgers(),
    ]);

    final localLedgers = results[0];
    final remoteLedgers = results[1];

    // 组合结果
    final allLedgers = [...localLedgers, ...remoteLedgers];

    logger.info('CloudSync', '已加载所有账本: 本地=${localLedgers.length}, 远程=${remoteLedgers.length}, 总计=${allLedgers.length}');

    return allLedgers;
  }

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

  /// 下载远程账本（创建新的本地账本或复用同名账本）
  ///
  /// 优先级：
  /// 1. 如果本地存在同名账本，复用该账本（不创建新账本）
  /// 2. 如果本地不存在同名账本但不存在远程 ID，复用远程 ID
  /// 3. 否则创建新 ID
  ///
  /// 云端文件迁移策略（Critical-07 修复）：
  /// 采用「先上传后删除」顺序，确保上传成功后再删除旧文件。
  /// 旧实现「先删除后上传」在删除成功但上传失败时会导致云端数据丢失。
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

      // 从远程路径提取账本ID
      final remoteIdStr =
          remotePath.replaceAll('ledger_', '').replaceAll('.json', '');
      final remoteId = int.tryParse(remoteIdStr);

      // 优先检查本地是否已存在同名账本
      final existingByName = await (db.select(db.ledgers)
            ..where((t) => t.name.equals(name)))
          .getSingleOrNull();

      final int ledgerId;
      final bool reuseExistingByName = existingByName != null;
      bool reuseRemoteId = false;

      if (reuseExistingByName) {
        // 复用同名账本的 ID（不创建新账本）
        ledgerId = existingByName.id;
        logger.info('CloudSync', '本地已存在同名账本，复用账本ID: $ledgerId (名称: $name)');
      } else {
        // 检查本地是否已存在该远程 ID
        final existingById = remoteId != null
            ? await (db.select(db.ledgers)..where((t) => t.id.equals(remoteId)))
                .getSingleOrNull()
            : null;

        reuseRemoteId = remoteId != null && existingById == null;

        if (reuseRemoteId) {
          // 复用远程 ID
          logger.info('CloudSync', '复用远程ID: $remoteId');
          await db.into(db.ledgers).insert(
                LedgersCompanion.insert(
                  id: drift.Value(remoteId),
                  name: name,
                  currency: drift.Value(currency),
                ),
              );
          ledgerId = remoteId;
        } else {
          // 创建新 ID（自动递增）
          logger.info('CloudSync', '本地ID冲突或无效，创建新ID');
          ledgerId = await db.into(db.ledgers).insert(
                LedgersCompanion.insert(
                  name: name,
                  currency: drift.Value(currency),
                ),
              );
        }
      }

      // 下载数据
      final raw = await provider.storage.download(path: remotePath);

      if (raw == null) {
        logger.warning('CloudSync', '云端账本不存在: $remotePath');
        // 只有新创建的账本才需要删除
        if (!reuseExistingByName) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId))).go();
        }
        return null;
      }

      // 规整为可解析明文：disable 后密钥仍保留则解密后导入；
      // 无密钥（reset 等）跳过导入，避免崩溃
      final jsonStr = await _decryptIfNeeded(raw);
      if (jsonStr == null) {
        logger.warning(
          'CloudSync',
          '云端账本 $remotePath 存在加密密文但本地无可解密密钥，跳过导入',
        );
        if (!reuseExistingByName) {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId))).go();
        }
        return null;
      }

      // 导入数据
      final result = await importTransactionsJson(repo, ledgerId, jsonStr);

      logger.info('CloudSync',
          '下载完成: ledgerId=$ledgerId, inserted=${result.inserted}');

      // 处理云端文件更新
      // Critical-07 修复：采用「先上传后删除」顺序，避免删除成功但上传
      // 失败时云端数据丢失。旧文件在新文件上传成功后才删除。
      if (reuseExistingByName) {
        // 复用了同名账本，本地 ID 可能和云端不同
        // 需要上传新的（使用本地 ID），再删除旧的云端文件
        if (remoteId != null && remoteId != ledgerId) {
          // 先上传到新路径
          try {
            await uploadCurrentLedger(ledgerId: ledgerId);
            logger.info('CloudSync', '账本已上传到云端: ledger_$ledgerId.json');
            // 上传成功后再删除旧文件
            try {
              await provider.storage.delete(path: remotePath);
              logger.info('CloudSync', '旧远程文件已删除: $remotePath (远程ID: $remoteId != 本地ID: $ledgerId)');
            } catch (e) {
              logger.warning('CloudSync', '删除旧远程文件失败（忽略，新文件已上传）: $e');
            }
          } catch (e) {
            logger.warning('CloudSync', '上传账本失败（旧文件保留）: $e');
          }
        } else {
          logger.info('CloudSync', '复用同名账本，ID相同无需更新云端文件');
        }
      } else if (reuseRemoteId) {
        // 复用了远程ID，无需删除和重新上传
        logger.info('CloudSync', '复用远程ID，无需更新云端文件');
      } else {
        // 创建了新 ID，需要上传新文件，再删除旧文件
        try {
          await uploadCurrentLedger(ledgerId: ledgerId);
          logger.info('CloudSync', '新账本已上传到云端: ledger_$ledgerId.json');
          // 上传成功后再删除旧文件
          try {
            await provider.storage.delete(path: remotePath);
            logger.info('CloudSync', '旧远程文件已删除: $remotePath');
          } catch (e) {
            logger.warning('CloudSync', '删除旧远程文件失败（忽略，新文件已上传）: $e');
          }
        } catch (e) {
          logger.warning('CloudSync', '上传新账本失败（旧文件保留）: $e');
        }
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
  Future<({int success, int failed})> restoreAllRemoteLedgers() async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    try {
      logger.info('CloudSync', '开始恢复所有远程账本');

      // 获取本地已存在的账本ID
      final localLedgers = await db.select(db.ledgers).get();
      final localLedgerIds = localLedgers.map((l) => l.id).toSet();
      logger.info('CloudSync', '本地已存在账本: $localLedgerIds');

      // 列出所有远程账本文件
      final files = await provider.storage.list(path: '');

      // 过滤出账本文件，并排除本地已存在的
      final ledgerFiles = files.where((file) {
        final fileName = file.name;
        if (!fileName.startsWith('ledger_') || !fileName.endsWith('.json')) {
          return false;
        }

        // 从文件名提取账本ID
        final idStr =
            fileName.replaceAll('ledger_', '').replaceAll('.json', '');
        final remoteId = int.tryParse(idStr);

        // 跳过本地已存在的账本
        if (remoteId != null && localLedgerIds.contains(remoteId)) {
          logger.info('CloudSync', '跳过已存在的账本: $fileName (ID=$remoteId)');
          return false;
        }

        return true;
      }).toList();

      logger.info('CloudSync', '找到 ${ledgerFiles.length} 个需要恢复的远程账本文件');

      // 并行恢复所有账本
      final results = await Future.wait(
        ledgerFiles.map((file) async {
          try {
            // 下载文件内容以获取账本信息（使用 file.name 而非 file.path）
            final jsonStr = await provider.storage.download(path: file.name);
            if (jsonStr == null) {
              logger.warning('CloudSync', '下载失败: ${file.name}');
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
    final json = jsonDecode(data) as Map<String, dynamic>;
    return json['ledgerId'] as int;
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
