import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:flutter/foundation.dart' show compute, visibleForTesting;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

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
import 'sync_metrics_service.dart';
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

  /// 同步成功率本地监控（审计 P0-1）。null 时上传/附件/恢复埋点退化为
  /// no-op —— 由调用方（provider 装配/测试）注入；TSM 不自行持有全局
  /// 单例，保持可测性。
  final SyncMetricsService? metrics;

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

  /// P2-2：附件目录列举缓存 TTL。60s 与状态缓存同档 —— auto_sync 连续
  /// 记账（防抖 2s 窗口）在 60s 内的重复上传共享一次列举；窗口过后
  /// 重新列举一次，把他设备的并发上传吸收进来（多判无谓但不漏判）。
  static const _attachmentListCacheTtl = Duration(seconds: 60);

  /// 审计修复（附件原子落盘）：下载写盘临时文件名的进程内自增序号，
  /// 与时间戳组合保证并发下载（semaphore 4）各自独占 tmp 文件。
  static int _attachWriteSeq = 0;

  final Map<int, _CachedStatus> _statusCache = {};
  final Map<int, DateTime> _recentLocalChangeAt = {};
  final Map<int, _RecentUpload> _recentUpload = {};

  /// P2-1：本地快照指纹的内存缓存（ledgerId → (导出指纹, 变更校验位)）。
  ///
  /// 冷启动首轮 getStatus 曾对每个账本全量导出算指纹（大账本 CPU 重）；
  /// 60s 状态缓存失效后每次重新导出。现在缓存「上次导出时的指纹 +
  /// local_changes 轻量校验位（MAX(id) + 未推送行数）」：
  /// - 命中（校验位不变）→ 跳过全量导出，直接复用指纹；
  /// - 校验位变了（有新写操作，含 recordChanges:false 导入插入行后的
  ///   MAX(id) 变化）→ 失效重算。
  /// 校验位兜底的意义：recordChanges:false 的导入路径不写 local_changes，
  /// 但其触发的 UI 后处理（PostProcessor.markLocalChanged）与导入
  /// 恢复后 recompute 快照等场景中，tracker 回调 + 校验位双保险覆盖。
  final Map<int, ({String fingerprint, String changeGuard})> _localFpCache =
      {};

  /// P2-1：清理过的指纹缓存条目集合（ledgerId 删除后防复活）。
  /// 与 [_localFpCache] 分开存：删除账本后 MAX(id) 校验位可能恒定不变，
  /// 若不记住「曾删除」状态，该 ledgerId 的指纹会在下次 getStatus 复活。
  /// 上传成功后重新登记即恢复正常缓存语义。
  final Set<int> _localFpCacheInvalidated = {};

  /// 待补齐的附件二进制下载队列(attachment_binary_sync)。
  /// 元组:云对象 sha256 + 落盘目标 fileName。恢复/导入事务提交后入队,
  /// drainAttachmentJobs 并发消费;失败回队等下次 drain。
  final List<({String sha256, String fileName})> _pendingAttachmentJobs = [];

  /// 换名收尾删除失败的旧远程槽位（M3 + 审计 P1-6）：downloadRemoteLedger
  /// 「先传新槽位再删旧文件」两步之间若删除失败（网络抖动等），旧 slot 文件
  /// 残留且其 slotKey 不再匹配任何本地账本，下次启动会被发现流程当新账本
  /// 提示导入（2026-09-07 双端实测踩中：B 端多出 6 个重复账本）。
  ///
  /// P1-6：登记持久化到 `stale_remote_slots` 表（v43），跨进程重启存活——
  /// 此前仅内存 Set，重启即丢，旧 slot 永久残留。本 Set 是该表的会话内
  /// 读写缓存：登记/补删同时写两侧（DB 是事实源，Set 是加速层），
  /// 初始化时从表装载。补删成功即从两侧移除。
  final Set<String> _staleRemoteSlots = <String>{};

  /// L2：split-brain 探测缓存。加密未开启且无密钥时每次 getStatus 都会
  /// 全量下载云端内容探测是否为密文；该状态在用户主动开启加密前是稳定的，
  /// 按 ledgerId 缓存命中结果（60s TTL），避免 broken 态下反复全量下载。
  final Map<int, ({DateTime at, bool encrypted})> _cipherProbeCache = {};

  /// P2-2：云端附件目录名的会话级缓存（名字集合 + 列举时刻）。
  ///
  /// 附件对象是内容寻址且 upsert 语义 —— 云端集合在一个会话内只会
  /// 增（本设备/他设备上传）不会「改名删除」（删除只有换名收尾与
  /// deleteRemoteLedger 两条路径，均不触碰 attachments/ 前缀）。他设备
  /// 并发上传只会让缓存「少判已有」→ 多一次无谓探测/上传，不会错判
  /// 已有 → 漏传（upsert 幂等），故短 TTL 缓存安全。reinit/dispose 清
  /// 空（换后端/加密态后旧集合无意义）。
  ({DateTime at, Set<String> names})? _attachmentNameCache;

  /// drain 重入守卫:恢复完成 / 初始化完成可能几乎同时触发 drain,
  /// 串行执行避免同一 .bin 被并发下载两次。
  bool _isDrainingAttachments = false;

  /// 审计 TSM-P11：初始化代次令牌。reinitializeForEncryption / dispose
  /// 会使其自增；在途的旧代次初始化完成后发现代次已变，必须整体丢弃
  /// 本轮装配成果（含 dispose 新建的 provider），不得赋回字段 —— 否则会把
  /// 已被 dispose 的旧加密装配「复活」，后续同步全部用错加密状态。
  int _initGeneration = 0;

  /// 审计 TSM-P8：按 ledgerId 的异步互斥锁（future 链实现，FIFO 排队）。
  /// 串行化同账本的「上传 ↔ 破坏性恢复」—— 此前两者无任何互斥：
  /// 恢复进行中触发的上传会把「清空到一半」的半恢复态账本推上云端
  /// 覆盖好快照；恢复事务提交前后到达的上传也会把恢复前旧内容回传。
  /// 不同账本各持各的锁，互不阻塞。
  final Map<int, Future<void>> _ledgerOpsLocks = {};

  /// 快照同步的自动上传防抖（对齐旧增量引擎时代的 _scheduleAutoSync 治理）。
  ///
  /// 背景：PostProcessor 在**每笔**交易保存后立即触发
  /// uploadCurrentLedger —— 全量导出 JSON + 附件对象探测 + 整快照 PUT。
  /// 连续记账（批量补录/导入几十笔）时每次编辑都完整跑一遍：慢网络下
  /// 前一次上传尚未返回，后续每次编辑仍在 TSM-P8 锁上排队，DB 侧每笔
  /// 都全量导出，网络侧串行打满。防抖把「窗口内的多次触发」收敛为
  /// 最后一次：窗口内再有编辑只重置计时；已有防抖上传在跑时新到的触发
  /// 记为 pending，跑完后自动补一轮（保证最后状态必然上云）。
  ///
  /// 相同的 2s 窗口；手动上传/合并回传不受影响（仍走
  /// uploadCurrentLedger 直传，不经过防抖）。
  static const Duration _autoSyncDebounce = Duration(seconds: 2);

  /// 每账本的自动同步防抖计时器（仅 [uploadCurrentLedgerDebounced] 使用）
  final Map<int, Timer> _autoSyncTimers = {};

  /// 每账本「防抖上传进行中」标志：进行中的上传结束后若期间又有触发，
  /// 由本标志触发补跑，保证「最后一次编辑必然上云」。
  final Map<int, bool> _autoSyncPending = {};

  /// 防抖版自动上传入口（auto_sync 后台路径专用）。
  ///
  /// 语义保证：最终一致 —— 调用后只要不再有新触发，账本最终必然以
  /// 「最后一次调用时刻的 DB 状态」完成一次上传（补跑机制兜底）。
  /// 立即上传语义请直接用 [uploadCurrentLedger]（手动按钮/合并回传）。
  @override
  Future<void> uploadCurrentLedgerDebounced({
    required int ledgerId,
    bool force = false,
    bool bypassRestoreGuard = false,
  }) async {
    final timer = _autoSyncTimers[ledgerId];
    if (timer != null) {
      // 窗口内已有待执行的防抖上传：重置计时即可（force/bypass 标志
      // 取最后一次触发的值，与「最后状态上云」语义一致）。
      timer.cancel();
      _autoSyncTimers.remove(ledgerId);
    } else if (_autoSyncPending[ledgerId] == true) {
      // 上传进行中：本轮触发已记录为 pending，无需再排计时。
      // 保留语义：pending 轮用本轮 force/bypass 参数。
      _pendingForce[ledgerId] = force;
      _pendingBypass[ledgerId] = bypassRestoreGuard;
      return;
    }
    _autoSyncTimers[ledgerId] = Timer(_autoSyncDebounce, () {
      _autoSyncTimers.remove(ledgerId);
      unawaited(_runAutoSyncUpload(
        ledgerId: ledgerId,
        force: force,
        bypassRestoreGuard: bypassRestoreGuard,
      ));
    });
  }

  /// pending 轮上传的参数快照（见 [uploadCurrentLedgerDebounced]）
  final Map<int, bool> _pendingForce = {};
  final Map<int, bool> _pendingBypass = {};

  Future<void> _runAutoSyncUpload({
    required int ledgerId,
    required bool force,
    required bool bypassRestoreGuard,
  }) async {
    _autoSyncPending[ledgerId] = true;
    try {
      try {
        await uploadCurrentLedger(
          ledgerId: ledgerId,
          force: force,
          bypassRestoreGuard: bypassRestoreGuard,
        );
      } finally {
        _autoSyncPending[ledgerId] = false;
        // 上传执行期间又有防抖触发到达（当时因「进行中」被记 pending）：
        // 立即补跑一轮（参数取 pending 期间最后一次触发的值）。
        if (_pendingForce.containsKey(ledgerId)) {
          final f = _pendingForce.remove(ledgerId)!;
          final b = _pendingBypass.remove(ledgerId) ?? false;
          unawaited(_runAutoSyncUpload(
              ledgerId: ledgerId, force: f, bypassRestoreGuard: b));
        }
      }
    } catch (e) {
      logger.warning('CloudSync', '自动同步上传失败(等下次数据变更重试): ledgerId=$ledgerId: $e');
    }
  }

  /// 释放防抖资源（dispose 路径调用，取消全部计时器）
  @visibleForTesting
  void cancelAutoSyncTimers() {
    for (final t in _autoSyncTimers.values) {
      t.cancel();
    }
    _autoSyncTimers.clear();
    _autoSyncPending.clear();
    _pendingForce.clear();
    _pendingBypass.clear();
  }

  // ============ 同步成功率埋点（审计 P0-1/P1-3） ============
  //
  // 埋点是纯旁路：metrics 为 null（未注入）或落库失败时全部 no-op，
  // 绝不影响同步主流程。conflict（条件写 412/M7 拦截）计入 outcome
  // 但不算失败 —— 它是并发保护正确工作的证据。

  /// 当前后端标识（指标分组键）。config.type.name 与 CloudBackendType
  /// 枚举名一一对应（s3/webdav/supabase/icloud/local）。
  String get _metricsBackend => config.type.name;

  void _recordMetrics(
    SyncOpScenario scenario,
    SyncOpOutcome outcome, {
    int? ledgerId,
    Object? error,
    int attempts = 1,
    Duration? duration,
  }) {
    final m = metrics;
    if (m == null) return;
    m.recordUnawaited(SyncOpRecord(
      backend: _metricsBackend,
      scenario: scenario,
      outcome: outcome,
      errorClass: error == null && outcome == SyncOpOutcome.success
          ? null
          : SyncMetricsService.classifyError(error),
      ledgerId: ledgerId,
      attempts: attempts,
      duration: duration,
    ));
  }

  /// 测试观测：发现阶段 payload 缓存的当前条目数（验证导入收尾释放语义）
  @visibleForTesting
  int get discoveredPayloadCountForTest => _discoveredPayloads.length;

  /// 在 [ledgerId] 的操作锁内执行 [body]。同账本操作严格排队，异常原样透传。
  Future<T> _withLedgerLock<T>(int ledgerId, Future<T> Function() body) {
    final prev = _ledgerOpsLocks[ledgerId] ?? Future<void>.value();
    final completer = Completer<void>();
    _ledgerOpsLocks[ledgerId] = completer.future;
    // prev 恒正常完成（completer 只在 whenComplete 中 complete）
    return prev.then((_) => body()).whenComplete(() {
      completer.complete();
      if (identical(_ledgerOpsLocks[ledgerId], completer.future)) {
        _ledgerOpsLocks.remove(ledgerId);
      }
    });
  }

  TransactionsSyncManager({
    required this.config,
    required this.db,
    required this.repo,
    this.encryptionService,
    this.metrics,
  });

  @override
  void clearStatusCache({int? ledgerId}) {
    if (ledgerId != null) {
      _statusCache.remove(ledgerId);
      // P2-1：状态缓存与指纹缓存同口径失效——备份恢复等外部导入路径
      // （recordChanges:false）经 UI 刷新触发本方法，两条缓存必须一起
      // 过期，否则 getStatus 拿旧指纹把新导入内容误判为「本地未变」
      invalidateLocalFingerprintCache(ledgerId: ledgerId);
    } else {
      _statusCache.clear();
      invalidateLocalFingerprintCache();
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
  ///
  /// R1 接线（审计 S24）：每次调用都尝试恢复滞留的改密检查点
  ///（[_tryRecoverPendingRekey]，内部单飞 + 无检查点早退，近零成本）。
  /// 挂在这里而非 [_ensureInitialized] 的原因：真实初始化每 session 只跑
  /// 一次即可，但测试缝注入（setSyncManagerForTesting）与加密重初始化
  /// 后的直连调用也构成「同步即将开始」的时机，都应尝试恢复。
  Future<void> ensureInitialized() {
    unawaited(_tryRecoverPendingRekey());
    return _ensureInitialized();
  }

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
  ///
  /// 审计 TSM-P11：与在途 _ensureInitialized 的并发此前是崩溃源 ——
  /// 直接清空 _initCompleter/_isInitializing 后，在途初始化恢复执行会对
  /// 已置空的 completer 调 complete!（空崩溃），或提前 complete 新代次的
  /// completer（重复 complete 抛 StateError），并把已 dispose 的旧装配
  /// 赋回字段复活。现通过 [_initGeneration] 代次令牌让旧代次成果整体
  /// 作废，本方法不再需要在途初始化「恰好没发生」的运气。
  Future<void> reinitializeForEncryption() async {
    // 作废所有在途/后续旧代次初始化的提交资格
    _initGeneration++;
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

    // 清空所有缓存状态。
    // E9 补全：_pendingAttachmentJobs（旧加密态的附件补齐任务）与
    // _discoveredPayloads（发现阶段缓存的明文 payload）此前漏清，
    // 会把旧加密态的任务/明文缓存泄漏到新会话。
    // M5 补全：_cipherProbeCache（旧加密态的 split-brain 探测缓存）——
    // 残留 true 命中会让新会话的前 60s 沿用「云端密文不可解」判定。
    // _ledgerOpsLocks 不清：future 链承载在途操作的互斥语义，清空会让
    // 并发上传/恢复失去排队（详见 _withLedgerLock 注释）；链节点随完成
    // 自动出表，不构成泄漏。
    _statusCache.clear();
    _recentLocalChangeAt.clear();
    _recentUpload.clear();
    _pendingAttachmentJobs.clear();
    _discoveredPayloads.clear();
    _staleRemoteSlots.clear();
    _cipherProbeCache.clear();
    _attachmentNameCache = null; // P2-2：换后端/加密态后旧集合无意义
    _localFpCache.clear(); // P2-1
    _localFpCacheInvalidated.clear(); // P2-1

    logger.info('CloudSync', '已标记需重新初始化（加密状态变更）');
  }

  /// 释放底层云服务资源（WebDAV dio client / S3 http.Client 连接池）。
  ///
  /// syncServiceProvider 在云配置/依赖变更时会重建本实例；旧实例若不
  /// 显式关闭，底层 HTTP 客户端会泄漏连接资源。dispose 后本实例不可再
  /// 使用（后续方法调用按「云服务不可用」处理），进行中的操作因已在
  /// 入口捕获局部引用（ATTACH-2 模式）可安全完成。
  Future<void> dispose() async {
    // 审计 TSM-P11：作废在途初始化的提交资格，防止 dispose 后旧代次
    // 初始化把新建（但按旧加密态装配）的 provider 赋回字段复活。
    _initGeneration++;
    try {
      await _provider?.dispose();
    } catch (e) {
      logger.warning('CloudSync', '旧 provider dispose 失败（忽略）: $e');
    }
    _provider = null;
    _syncManager = null;
    _rawStorage = null;
    // M5：与 reinitializeForEncryption 同口径清 _cipherProbeCache。
    // _ledgerOpsLocks 保持（见 reinitializeForEncryption 处注释）。
    _statusCache.clear();
    _recentLocalChangeAt.clear();
    _recentUpload.clear();
    _pendingAttachmentJobs.clear();
    _discoveredPayloads.clear();
    _staleRemoteSlots.clear();
    _cipherProbeCache.clear();
    _attachmentNameCache = null; // P2-2：换后端/加密态后旧集合无意义
    _localFpCache.clear(); // P2-1
    _localFpCacheInvalidated.clear(); // P2-1
    // 自动上传防抖收尾：取消全部待执行计时器。进行中的一轮（如有）
    // 会自然结束（provider 已置 null，其内部会按「云服务不可用」失败并
    // 记 warning，不再补跑）。
    cancelAutoSyncTimers();
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
  /// 若等待期间 reinitializeForEncryption 被调用（代次变更），刚完成的
  /// 初始化成果已作废，会递归重试一次初始化。
  Future<void> _ensureInitialized() async {
    if (_isInitialized) return;

    // 正在初始化：等待现有 Completer 完成
    if (_isInitializing && _initCompleter != null) {
      final observedGen = _initGeneration;
      try {
        await _initCompleter!.future;
      } catch (e) {
        // 初始化失败：若等待期间发生过 reinit/dispose（代次已变），
        // 该失败属于被作废的旧代次，递归重试；否则原样上抛
        if (_initGeneration != observedGen) return _ensureInitialized();
        rethrow;
      }
      // 审计 TSM-P11：醒来后代次一致且已提交才算成功。代次变更意味着
      // 刚完成的初始化成果已被丢弃（provider 可能已被 dispose），必须
      // 递归重试，绝不能带着旧装配继续。
      if (_isInitialized && _initGeneration == observedGen) return;
      return _ensureInitialized();
    }

    final gen = _initGeneration;
    _isInitializing = true;
    final completer = Completer<void>();
    _initCompleter = completer;
    try {
      await _initialize(gen);
      // 审计 TSM-P11：只提交当前代次的成果；初始化期间发生 reinit 时，
      // _initialize 内部已丢弃本轮装配，这里不得置 _isInitialized
      if (_initGeneration == gen) {
        _isInitialized = true;
      }
      completer.complete();
      // P2-1：接线 ChangeTracker 写路径回调——任何登记的本地写操作
      // 主动失效指纹缓存（ledgerId=0 的 user-global 变更影响全部快照，
      // 按全部失效处理）。幂等挂载（重复初始化不叠加回调）。
      _wireChangeTrackerGeneration();
      // 初始化即触发一次补齐：先全量重扫 DB 里「有 sha256 但本地文件缺失」
      // 的附件并入队（审计 A2：_pendingAttachmentJobs 是内存队列，进程重启
      // 即丢失；此前 enqueue 只发生在恢复/导入/合并时机，重启后缺文件永久
      // 无人再发现），再 drain 消费（覆盖"上次恢复失败的附件任务"重试场景；
      // 队列空时是空操作，零成本）。
      unawaited(enqueueAllMissingAttachmentJobs()
          .whenComplete(() => drainAttachmentJobs()));
      // P1-6：先装载持久化的补删登记（reinit/dispose 只清了内存缓存），
      // 再补删（网络恢复后重试）。装载失败退化为空集，下次初始化重试。
      unawaited(_loadStaleSlotRecords()
          .then((_) => _retryStaleSlotDeletes()));
      // R1 接线（审计 S24）：provider 就绪后再试一次改密检查点恢复 ——
      // ensureInitialized 入口的首次调用发生在 provider 装配前
      //（_rawStorage 为 null 时恢复早退），这里补上首个 session 内的恢复。
      unawaited(_tryRecoverPendingRekey());
    } catch (e, st) {
      completer.completeError(e, st);
      rethrow;
    } finally {
      _isInitializing = false;
      // 审计 TSM-P11：仅当字段仍指向自己的 completer 时才清理 —— 若期间
      // 发生过 reinit（字段被置空或被新代次替换），绝不能动别人的状态，
      // 更不能对空引用调 complete!（原实现的崩溃点）。
      if (identical(_initCompleter, completer)) {
        _initCompleter = null;
      }
    }
  }

  /// 初始化 CloudProvider 和 SyncManager
  ///
  /// [gen] 为调用方捕获的初始化代次。审计 TSM-P11：全部装配先在局部变量
  /// 完成，最后一次性提交 —— 提交前发现代次已变（reinit/dispose 已发生）
  /// 则整体丢弃并释放新建资源，绝不把按**旧加密状态**装配的 provider
  /// 赋回字段复活。
  Future<void> _initialize(int gen) async {
    fcs.CloudProvider? newProvider;
    fcs.CloudSyncManager<int>? newSyncManager;
    fcs.CloudStorageService? newRawStorage;

    try {
      final services = await createCloudServices(config);
      newProvider = services.provider;

      if (newProvider == null) {
        // Provider 创建失败（如 iCloud 未登录），标记为已初始化但无法使用
        logger.warning(
            'CloudSync', 'Provider not available for ${config.type}');
        return;
      }

      // 装饰前缓存原始 storage 引用，供 [rawStorage] getter 暴露
      // 用途：enableFromCloud 需要未装饰的 storage 来下载密文字符串本身
      newRawStorage = newProvider.storage;

      // E2EE: 若加密服务已注入且加密已开启，用 EncryptedCloudProvider 包装一层。
      // 装饰器只重写 storage getter，其余方法透传，对 CloudSyncManager 完全透明。
      // 加密未开启时直接用原 provider，避免无谓的包装开销。
      if (encryptionService != null) {
        final enabled = await encryptionService!.isEnabled;
        if (enabled) {
          newProvider = EncryptedCloudProvider(
            inner: newProvider,
            encryptionService: encryptionService!,
          );
          logger.info('CloudSync', 'E2EE enabled, provider wrapped');
        }
      }

      newSyncManager = fcs.CloudSyncManager<int>(
        provider: newProvider,
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

      // 代次终检：装配期间发生过 reinit/dispose → 整体丢弃本轮成果
      //（EncryptedCloudProvider.dispose 会级联释放 inner provider）
      if (_initGeneration != gen) {
        logger.info(
            'CloudSync', '初始化期间加密状态已变更（代次 $_initGeneration != $gen），丢弃本轮装配');
        await _discardInitArtifacts(newProvider);
        return;
      }

      _provider = newProvider;
      _rawStorage = newRawStorage;
      _syncManager = newSyncManager;
    } catch (e) {
      // 装配中途抛错：清理半成品后原样上抛（外层 completer 记录失败）
      await _discardInitArtifacts(newProvider);
      rethrow;
    }
  }

  /// 丢弃一轮初始化装配的资源（dispose provider）。供代次失效与异常路径复用。
  Future<void> _discardInitArtifacts(fcs.CloudProvider? provider) async {
    if (provider == null) return;
    try {
      await provider.dispose();
    } catch (e) {
      logger.warning('CloudSync', '丢弃初始化装配时 dispose 失败（忽略）: $e');
    }
  }

  /// 云端槽位路径：`ledger_<slotKey>.json`。
  ///
  /// slotKey 用账本 syncId（跨设备稳定身份）而非本地数字 id —— 两台设备
  /// 各自新建的第一个账本本地 id 都是 1，按数字 id 命名会互相覆盖对方的
  /// 云端快照（同槽互覆）。
  ///
  /// 审计 TSM-P18/P19 根治（开发版无历史数据，无需兼容 legacy 数字槽位）：
  /// 此前 syncId 缺失时回退 `ledger.id.toString()` —— 数字槽位在 syncId
  /// 回填后漂移、旧文件孤儿化；两台各自有 legacy 数据的设备还会撞号互覆。
  /// 现改为缺失时**就地生成并持久化** UUID 身份后再返回路径：账本首次上传
  /// 前即获得稳定身份，槽位从此不再变化。公开供 UI 层复用同一命名规则。
  ///
  /// 键字符约束：slotKey 为 UUID（32 位 hex + 连字符），URL 安全且全部为
  /// unreserved 字符 —— S3 SigV4 的严格 RFC 3986 编码链路（审计 S3-1）
  /// 对其恒等透传。
  Future<String> pathForLedger(int ledgerId) async {
    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    if (row == null) {
      // 账本行不存在（如恢复流程对尚未落库的账本 id 做下载探测）：无从
      // 锚定身份，退回数字路径仅供读取；上传路径不会走到这里（上传前
      // 账本行必已存在，身份已在下方就地生成）。
      return 'ledger_$ledgerId.json';
    }
    final existing = row.syncId?.trim();
    if (existing != null && existing.isNotEmpty) {
      return 'ledger_$existing.json';
    }
    final generated = const Uuid().v4();
    // 审计 T3（TOCTOU）：并发调用可能都读到 syncId=null、各自生成 UUID
    // 互相覆盖，先返回者的路径成为孤儿云端槽位。带 `syncId IS NULL`
    // 条件的更新保证只有一个写入者生效；affected=0 说明并发方已写入，
    // 重读行取**实际落库值**，双方拿到同一身份。
    final updated = await (db.update(db.ledgers)
          ..where((l) => l.id.equals(row.id) & l.syncId.isNull()))
        .write(LedgersCompanion(syncId: drift.Value(generated)));
    String effectiveId = generated;
    if (updated == 0) {
      final reread = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(row.id)))
          .getSingleOrNull();
      final rereadSyncId = reread?.syncId?.trim();
      if (rereadSyncId == null || rereadSyncId.isEmpty) {
        // 理论不可达（条件更新失败但值仍空）：保守沿用本次生成值
        logger.warning('CloudSync', 'pathForLedger syncId 并发回读为空（保留生成值）');
      } else {
        effectiveId = rereadSyncId;
      }
    }
    logger.info(
        'CloudSync', 'pathForLedger 就地生成账本 syncId: ${row.id} → $effectiveId');
    return 'ledger_$effectiveId.json';
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
    logger.warning('CloudSync', '云端为密文但本地未开启加密，需引导用户开启加密: $ledgerId');
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
  ///
  /// L2：探测需要全量下载云端内容，broken 态在用户开启加密前是稳定的，
  /// 命中结果按 ledgerId 缓存 60s，避免 getStatus 反复全量下载。
  /// 仅缓存 true（进入 broken 态）；false 不缓存——网络瞬断/内容变化后
  /// 下次调用应重新探测，语义与无缓存时一致。
  Future<bool> _isCloudCiphertextLocallyDisabled(int ledgerId) async {
    if (encryptionService == null) return false;
    if (await encryptionService!.isEnabled) return false;
    if (await encryptionService!.hasActiveKey) return false;

    final cached = _cipherProbeCache[ledgerId];
    if (cached != null &&
        DateTime.now().difference(cached.at) < const Duration(seconds: 60)) {
      return cached.encrypted;
    }

    // 本地无可用密钥：探测云端内容是否为密文
    final raw = _rawStorage;
    if (raw == null) return false;
    try {
      final content = await raw.download(path: await pathForLedger(ledgerId));
      final encrypted =
          content != null && CiphertextFormat.isEncrypted(content);
      if (encrypted) {
        _cipherProbeCache[ledgerId] = (
          at: DateTime.now(),
          encrypted: true,
        );
      }
      return encrypted;
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
      {required int ledgerId,
      bool force = false,
      bool bypassRestoreGuard = false}) async {
    await _ensureInitialized();

    // 审计 TSM-P8：恢复临界区进行中绝不允许上传 —— 半恢复态 DB 会被打包
    // 推上云端覆盖好快照（与 W6 防的灾难同构）。定时备份已检查 isBusy，
    // 这里补上所有手动/自动上传入口。
    //
    // P0-1 修复：[bypassRestoreGuard] 供「恢复已提交、仅剩收尾回传」的
    // 内部流程豁免（启动检查 merge-then-publish 阶段 2 —— 其临界区由
    // app.dart 包裹整个 runIfNeeded，阶段 2 执行时合并事务早已提交，
    // 上传的是完整一致态数据，不构成半恢复态上传）。此前该流程的回传
    // 在此被无条件拒绝 → 每个账本回传必失败 → 指纹永不收敛 → 每次启动
    // 重复弹「云端有更新」死循环。
    if (SyncRestoreGuard.isBusy && !bypassRestoreGuard) {
      throw fcs.CloudSyncException('正在从云端恢复数据，本次上传已取消，请在恢复完成后再试');
    }

    // 审计 TSM-P8：同账本「上传 ↔ 恢复」经 _ledgerOpsLocks 串行化
    await _withLedgerLock(ledgerId,
        () => _uploadCurrentLedgerCore(ledgerId: ledgerId, force: force));
  }

  /// 上传核心流程（调用方必须已持有 [ledgerId] 的账本锁）。
  ///
  /// 内部路径（downloadRemoteLedger 换名收尾）在锁内直接调用本方法，
  /// 避免重入死锁；公开入口一律走 [uploadCurrentLedger]。
  Future<void> _uploadCurrentLedgerCore(
      {required int ledgerId, required bool force}) async {
    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _syncManager 置 null 导致 NPE（ATTACH-2 竞态防护）
    final manager = _syncManager;
    final provider = _provider;
    if (manager == null || provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }
    // P0-1：快照上传计时（指标 duration 字段）
    final metricsWatch = Stopwatch()..start();

    // 审计 TSM-P14：本机无法解读云端密文（未开启加密且无可用密钥）时，
    // 禁止一切上传 —— force 也不例外。否则明文快照会静默覆盖云端
    // BEECRYPT1 密文备份：一台读不了密文的设备摧毁自己无法理解的数据，
    // 并把全链路 E2EE at-rest 承诺降级为明文。UI 的加密引导流程不受影响
    // （走 enableFromCloud 恢复后再传）；此处拦的是程序化调用方与误操作。
    if (await _isCloudCiphertextLocallyDisabled(ledgerId)) {
      throw CloudEncryptedLocallyDisabledException(
        '云端备份已启用端到端加密，但本设备无法解密（未开启加密且无可用密钥）。'
        '为避免明文覆盖云端加密备份，本次上传已阻止；请先开启加密后重试',
      );
    }

    try {
      logger.info('CloudSync', '开始上传账本 $ledgerId');

      // 上传前先计算本地指纹（用于记录上传快照）。
      // 审计 TSM-P3：导出现在自带内嵌指纹（'contentFingerprint' 键），优先
      // 采用 —— 与上传元数据、云端内容三方恒等，杜绝任何一侧口径漂移。
      String? localFp;
      int? localCount;
      Map<String, dynamic>? exportMap;
      String? exportedJson;
      try {
        exportedJson = await exportTransactionsJson(db, ledgerId);
        exportMap = jsonDecode(exportedJson) as Map<String, dynamic>;
        localFp = (exportMap['contentFingerprint'] as String?) ??
            _contentFingerprintFromMap(exportMap);
        localCount = (exportMap['count'] as num?)?.toInt();
      } catch (e) {
        logger.warning('CloudSync', '计算本地指纹失败: $e');
      }

      // M7：并发覆盖止血（last-writer-wins）。非 force 时先做冲突判定：
      // 云端快照更新 / 方向无法判定但内容不同 → 抛 CloudConflictException，
      // 由 UI 确认后 force:true 重试。内部流程（全量上传已有双重确认、
      // 合并后回传、Critical-07 换名）直接传 force:true 不受影响。
      //
      // 方案C：探测同时捕获云端 ETag 作为乐观并发锚点 —— 后端支持条件写
      // 时，「探测通过 → 上传落盘」之间云端被并发修改会显式失败而非覆盖。
      String? cloudETag;
      if (!force) {
        final probe = await _detectUploadConflict(
          provider: provider,
          ledgerId: ledgerId,
          localFp: localFp,
        );
        if (probe.hasConflict) {
          logger.warning(
              'CloudSync',
              '上传冲突拦截: ledger=$ledgerId direction=${probe.direction} '
                  '(等待用户确认覆盖)');
          _recordMetrics(SyncOpScenario.snapshotUpload, SyncOpOutcome.conflict,
              ledgerId: ledgerId,
              error: CloudConflictException(direction: probe.direction!),
              duration: metricsWatch.elapsed);
          throw CloudConflictException(direction: probe.direction!);
        }
        cloudETag = probe.cloudETag;
      }

      // m-02 修复：将账本摘要信息写入 metadata，
      // 供 getRemoteLedgers 直接读取，避免逐个下载文件解析 JSON
      final uploadMetadata = <String, String>{
        'version': '2',
        'uploadedAt': DateTime.now().toUtc().toIso8601String(),
        'ledgerId': ledgerId.toString(),
      };
      if (exportMap != null) {
        final name =
            exportMap['ledgerName'] as String? ?? exportMap['name'] as String?;
        final currency = exportMap['currency'] as String?;
        final exportedAt = exportMap['exportedAt'] as String?;
        if (name != null) uploadMetadata['ledgerName'] = name;
        if (currency != null) uploadMetadata['currency'] = currency;
        if (localCount != null) uploadMetadata['count'] = localCount.toString();
        // 月起始日（m-02 延伸）：发现阶段快路径读它构造 RemoteLedgerMeta，
        // 免得导入前展示/建行默认 1；老快照无该键时导入阶段 payload
        // 回写兜底。
        final monthStartDay = exportMap['monthStartDay'] as num?;
        if (monthStartDay != null) {
          uploadMetadata['monthStartDay'] = monthStartDay.toInt().toString();
        }
        // 余额合计（m-02 延伸）：口径与 getLedgerStats 的 SQL 聚合一致 ——
        // income 加 / expense 减 / transfer 不计、nativeAmount ?? amount 兜底。
        // 供账本页「远程账本」卡片展示，发现阶段零下载即可读到。items 已在
        // 内存（exportMap 已解析），内存累加零额外查询。
        final items = exportMap['items'];
        if (items is List && items.isNotEmpty) {
          double balance = 0;
          for (final it in items) {
            if (it is! Map) continue;
            final type = it['type'];
            final amount = ((it['nativeAmount'] as num?) ?? (it['amount'] as num?))?.toDouble();
            if (amount == null) continue;
            if (type == 'income') {
              balance += amount;
            } else if (type == 'expense') {
              balance -= amount;
            }
          }
          uploadMetadata['balance'] = balance.toString();
        }
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

      final fcs.CloudUploadResult outcome;
      try {
        outcome = await manager.upload(
          data: ledgerId,
          path: await pathForLedger(ledgerId),
          metadata: uploadMetadata,
          // F6：复用刚导出的同一份 JSON 与指纹，避免 manager 内部二次全量
          // 导出（大账本代价高），并消除两次导出间 DB 变化导致的
          // 「本地缓存指纹 ≠ 云端 metadata 指纹」错位。
          serializedData: exportedJson,
          fingerprint: localFp,
          // F6 延伸：exportMap 是上面已 jsonDecode 的同一份 payload，
          // count 直接透传，manager 跳过对大快照的第二次 jsonDecode。
          preParsedCount: localCount,
          // 方案C：乐观并发锚点。S3 走 If-Match 原子条件写；WebDAV 走
          // eTag 预检；不支持的后端由 manager 内部降级为盲上传+写后校验。
          ifMatchEtag: cloudETag,
        );
      } on fcs.CloudPreconditionFailedException {
        // 探测到写入之间云端已被其他设备修改，本次未落盘。翻译为冲突
        // 异常走既有的用户确认/合并流程，绝不静默重试（重试=覆盖他机数据）。
        logger.warning(
            'CloudSync', '条件写失败（云端已被并发修改）: ledger=$ledgerId → 转入冲突流程');
        _recordMetrics(SyncOpScenario.snapshotUpload, SyncOpOutcome.conflict,
            ledgerId: ledgerId,
            error: fcs.CloudPreconditionFailedException(
                await pathForLedger(ledgerId)),
            duration: metricsWatch.elapsed);
        throw CloudConflictException(direction: 'cloudNewer');
      }

      // 审计 C3：盲上传路径的写后校验结论上浮。verified=false 说明云端
      // 指纹与本次写入不一致 —— 内容可能已被并发覆盖。数据已在云端、
      // 不算失败，但**不得**标记「已同步」/清除脏标记/markSnapshotPushed：
      // 保持脏状态让下次 getStatus 探测真实差异走冲突/合并流程，
      // 否则本地修改被静默掩盖（旧代码此场景完全无感知）。
      final uploadVerified = outcome.verified;
      if (!uploadVerified) {
        logger.warning(
            'CloudSync',
            '写后校验不一致（云端可能已被并发覆盖）: ledger=$ledgerId '
                '→ 本次不标记已同步');
        // P1-3：verified=false 是「数据已在云端但未确认收敛」的软失败
        // —— 不算 failed（硬抛会诱发盲目重传覆盖），也不算 success，
        // 单独计数正是 99.9% 与 99% 之间的差距来源。
        _recordMetrics(SyncOpScenario.snapshotUpload, SyncOpOutcome.softFail,
            ledgerId: ledgerId, duration: metricsWatch.elapsed);
      } else {
        _recordMetrics(SyncOpScenario.snapshotUpload, SyncOpOutcome.success,
            ledgerId: ledgerId, duration: metricsWatch.elapsed);
      }

      // 记录近期上传，用于处理 CDN 缓存延迟
      if (uploadVerified && localFp != null && localCount != null) {
        _recentUpload[ledgerId] = _RecentUpload(
          at: DateTime.now(),
          fp: localFp,
          count: localCount,
        );
        // P2-1：上传刚导出的指纹登记进本地缓存——上传后紧随的
        // getStatus（UI 刷新同步状态）命中缓存，零导出
        await rememberLocalFingerprint(ledgerId, localFp);
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
        // 指纹计算失败或写后校验不一致：清除缓存等待下次探测真实状态
        _statusCache.remove(ledgerId);
      }

      // 清除本地变更标记（仅在确认写入未被并发覆盖时）
      if (uploadVerified) {
        _recentLocalChangeAt.remove(ledgerId);
      }

      // F2：快照上传成功 = 本账本 + user-global 的未推送变更均已随快照
      // 上云，标记 pushedAt：
      // ① 阻止 local_changes 无限膨胀（快照同步此前永不 markPushed，
      //    cleanupPushedChanges 也因此无行可清）；
      // ② 让 _localChangeEvidence 的「未推送行存在才可信」门禁恢复设计
      //    语义（M1/M7）：上传后时间戳与内容新旧状态重新对齐。
      // 失败不阻断（下次上传会重新标记）。
      // 审计 C3：写后校验不一致时同样跳过 —— 内容是否真正落盘存疑，
      // 标记 pushed 会把未收敛的变更当成已同步。
      if (uploadVerified) {
        try {
          final tracker = repo.changeTracker;
          if (tracker != null) {
            await tracker.markSnapshotPushed(ledgerId: ledgerId);
            unawaited(tracker.cleanupPushedChanges());
          }
          // P0-1：指标滚动清理与 local_changes 清理同批（30 天窗口外的
          // 行删除，近零成本；失败由服务内部吞掉）
          metrics?.cleanupExpired();
        } catch (e) {
          logger.warning('CloudSync', '标记本地变更已推送失败(不影响本次上传): $e');
        }
      }

      logger.info('CloudSync', '上传完成: $ledgerId');
    } catch (e, stack) {
      logger.error('CloudSync', '上传失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);
      // P0-1：上传失败计入指标（CloudConflictException 已在上方出口
      // 以 conflict 单独记录，不会流到这里 —— 冲突是在 try 块内翻译
      // 抛出的，会被本 catch 再接住一次，需排除）。
      if (e is! CloudConflictException) {
        _recordMetrics(SyncOpScenario.snapshotUpload, SyncOpOutcome.failed,
            ledgerId: ledgerId, error: e, duration: metricsWatch.elapsed);
      }
      rethrow;
    }
  }

  /// 批量上传所有本地账本到云端（串行逐个上传，单个失败不中断）。
  ///
  /// 串行而非并行：避免并发上传打满 WebDAV/S3 连接数限制，且
  /// uploadCurrentLedger 内部写 _recentUpload/_statusCache（Map），
  /// 串行天然无竞态。返回 (success, failed, conflicts) 统计，语义对齐
  /// [restoreAllRemoteLedgers]。
  ///
  /// 审计 A4 修复：移除强制 `force:true`。此前整批绕过 M7 冲突闸门，
  /// 与页面级批量上传（保留拦截并单独计数 conflicts）安全语义相反 ——
  /// 同一动作两个入口行为不同，误用即覆盖他机更新。现在统一走逐账本
  /// 冲突检测；被云端较新/方向不明拦下的账本计入 [conflicts]，UI 据此
  /// 引导用户对个别账本走「对比合并」或显式确认覆盖。
  ///
  /// [onProgress] 每完成一个账本回调 (done, total)，供 UI 阻塞弹窗展示进度。
  Future<({int success, int failed, int conflicts})> uploadAllLedgers({
    void Function(int done, int total)? onProgress,
  }) async {
    await _ensureInitialized();

    final ledgers = await db.select(db.ledgers).get();
    var success = 0;
    var failed = 0;
    var conflicts = 0;
    var done = 0;
    for (final ledger in ledgers) {
      try {
        await uploadCurrentLedger(ledgerId: ledger.id);
        success++;
      } on CloudConflictException {
        // 云端较新/方向无法判定：跳过该账本（不静默覆盖），单独计数
        logger.warning('CloudSync', '批量上传：账本 ${ledger.id} 存在云端更新，已跳过待用户处理');
        conflicts++;
      } catch (e) {
        // 单个账本失败只计数并继续，避免一个账本故障拖垮整批备份
        logger.warning('CloudSync', '批量上传账本 ${ledger.id} 失败: $e');
        failed++;
      }
      done++;
      onProgress?.call(done, ledgers.length);
    }
    return (success: success, failed: failed, conflicts: conflicts);
  }

  // ============================================================
  // 附件二进制同步(attachment_binary_sync,快照同步链路)
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
  /// 并 warning。云端已存在的对象直接跳过(去重 + 省流量):批量上传前
  /// 单次 list('attachments') 建立存在集合,替代逐对象 exists() 探测
  /// (WebDAV exists 是父目录全量 PROPFIND,N 个附件 = N 次整目录拉取);
  /// list 失败时退回逐对象 exists(),语义不变。
  ///
  /// 审计 T9:构建清单前先对 localSha256 为空的附件行**按需计算并回填**
  /// —— 此前只靠启动后台任务,任务完成前的上传会把 NULL 锚点行整体排除
  /// 在清单外,这些附件要等"回填完成 + 下次上传"两个条件才上云。现在
  /// 上传即自愈,窗口归零(文件缺失的孤儿行保持 NULL,交由启动任务再试)。
  ///
  /// 返回 (uploaded, skipped, failed) 统计供调用方汇总。
  /// P2-2：云端附件目录名集合（带会话级缓存）。
  ///
  /// 返回 null = 列举失败（调用方退回逐对象 exists()，与旧行为一致，
  /// 且不污染缓存）。命中缓存直接复用；过期或首次则列举并刷新缓存。
  Future<Set<String>?> _remoteAttachmentNames(
      fcs.CloudProvider provider) async {
    final cached = _attachmentNameCache;
    if (cached != null) {
      final age = DateTime.now().difference(cached.at);
      if (age < _attachmentListCacheTtl) {
        logger.debug('CloudSync', '附件目录列举走会话缓存(${cached.names.length} 项, ${age.inSeconds}s)');
        return cached.names;
      }
    }
    try {
      final remoteFiles = await provider.storage.list(path: 'attachments');
      final names = remoteFiles.map((f) => f.name).toSet();
      _attachmentNameCache = (at: DateTime.now(), names: names);
      return names;
    } catch (e) {
      logger.warning('CloudSync', '附件目录列举失败，退回逐对象探测: $e');
      return null; // 不刷新缓存：失败态不能覆盖上次成功集合
    }
  }

  /// P2-2：本会话上传成功的附件对象登记进缓存（upsert 语义下自己
  /// 刚写的对象必然存在）。文件级私有小方法，调用点唯一。
  void _markAttachmentUploaded(String sha) {
    _attachmentNameCache?.names.add('$sha.bin');
  }

  Future<({int uploaded, int skipped, int failed})> uploadAttachmentObjects(
      {required int ledgerId}) async {
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

    // 审计 T9：NULL 锚点行先按需回填，失败不阻断（清单仍按现有列值构建）
    try {
      await backfillAttachmentSha256(
        db: db,
        onResolved: repo.updateAttachmentLocalSha256,
        txIds: txIds,
        attachmentsDir: Directory(
            '${(await getApplicationDocumentsDirectory()).path}/attachments'),
      );
    } catch (e) {
      logger.warning('CloudSync', '附件 sha256 上传前回填失败(不阻断): $e');
    }

    final atts = await (db.select(db.transactionAttachments)
          ..where(
              (a) => a.transactionId.isIn(txIds) & a.localSha256.isNotNull()))
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

    // 上传前一次性列举云端附件目录，替代逐对象 exists() 探测。
    //
    // WebDAV 的 exists() 是「父目录 PROPFIND 全量列举」，N 个附件 = N 次
    // 同一目录的整目录拉取（目录大时每次都是全量 XML），auto_sync 场景下
    // 每笔记账都重复整套；S3 是 N 次 HEAD。单次 list 后用名字集合判存在，
    // 次数从 N 降到 1。列举失败不阻断 —— 退回逐对象 exists()（多一次网络
    // 往返但语义与旧行为完全一致），上传流程永不因探测故障而中止。
    //
    // P2-2（2026-09-09）：会话级缓存 —— auto_sync 防抖后每笔记账仍要
    // 重新全量列举附件目录，大附件库（千级对象）下 WebDAV 每轮整目录
    // XML / S3 全前缀翻页，成本随目录规模线性放大。改为：
    // - 会话内首次列举后按 TTL（_attachmentListCacheTtl）缓存名字集合；
    // - 本会话上传成功的对象直接加入缓存（内容寻址 + upsert 语义，
    //   自己刚写的对象必然存在，无需回读确认）；
    // - 列举失败不污染缓存（保持回退路径的旧语义）。
    final remoteNames = await _remoteAttachmentNames(provider);
    String attachmentBinName(String sha) => '$sha.bin';
    bool remoteHas(String sha) =>
        remoteNames?.contains(attachmentBinName(sha)) ?? false;

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
          logger.warning(
              'CloudSync', '附件本地文件缺失,跳过上传: sha256=$sha (${entry.value.first})');
          return;
        }
        if (remoteNames != null
            ? remoteHas(sha)
            : await provider.storage.exists(path: pathForAttachmentBin(sha))) {
          skipped++;
          return;
        }
        // L4：真字节路径优先（S3/WebDAV 实现 BinaryCapableStorage，云端
        // 对象可直接以二进制读取）；其余后端 base64 兜底（行为同旧版）。
        // E2EE 装饰器实现 BinaryCapableStorage：encrypt(base64(bytes)) 后
        // 仍走字符串信封，密文格式与既有同步文件一致。此前恒 base64 文本
        // 上传，比备份 ZIP 多 ~33% 流量。
        final bytes = await File(srcPath).readAsBytes();
        await provider.storage.uploadBinaryOrFallback(
            path: pathForAttachmentBin(sha), bytes: bytes);
        uploaded++;
        // P2-2：登记进会话缓存，同会话后续上传（含其他账本同 sha
        // 去重判断）零网络探测
        _markAttachmentUploaded(sha);
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

  /// 审计 A2：启动/初始化时全量重扫「有 sha256 但本地文件缺失」的附件并入队。
  ///
  /// _pendingAttachmentJobs 是内存队列，进程重启即丢失；此前 enqueue 只发生在
  /// 恢复/导入/合并三个时机，重启后缺文件永久无人再发现。本方法以 DB 行为
  /// 事实源做全量补扫，保证缺失附件最终收敛：
  /// - 云端对象存在的 → drain 正常补齐；
  /// - 云端确认无此对象的 → TSM-P2 三态判 objectMissing 直接丢弃，不空转；
  /// - 瞬态失败的 → 仅当次会话内回队，下次启动重新扫描（天然有界）。
  ///
  /// 返回本次新入队的任务数（供测试与诊断）。
  Future<int> enqueueAllMissingAttachmentJobs() async {
    try {
      final atts = await (db.select(db.transactionAttachments)
            ..where((a) => a.localSha256.isNotNull()))
          .get();
      if (atts.isEmpty) return 0;

      final appDir = await getApplicationDocumentsDirectory();
      final attDir = Directory('${appDir.path}/attachments');
      var added = 0;
      for (final a in atts) {
        final sha = a.localSha256!;
        if (sha.isEmpty) continue;
        // L3 同款：(sha256, fileName) 整对去重
        if (_pendingAttachmentJobs
            .any((j) => j.sha256 == sha && j.fileName == a.fileName)) {
          continue;
        }
        if (await File('${attDir.path}/${a.fileName}').exists()) continue;
        _pendingAttachmentJobs.add((sha256: sha, fileName: a.fileName));
        added++;
      }
      if (added > 0) {
        logger.info('CloudSync', '启动附件补扫: 发现 $added 个缺失文件已入队');
      }
      return added;
    } catch (e) {
      logger.warning('CloudSync', '启动附件补扫失败(忽略): $e');
      return 0;
    }
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
            ..where(
                (a) => a.transactionId.isIn(txIds) & a.localSha256.isNotNull()))
          .get();
      if (atts.isEmpty) return;

      final appDir = await getApplicationDocumentsDirectory();
      final attDir = Directory('${appDir.path}/attachments');
      for (final a in atts) {
        final sha = a.localSha256!;
        if (sha.isEmpty) continue;
        // L3：按 (sha256, fileName) 整对去重。此前仅按 sha 去重，同 sha
        // 不同扩展名的行（fileName = 'sha_<sha><ext>'，ext 随源文件）只有
        // 第一个物理文件会被补齐，第二个永不恢复。
        if (_pendingAttachmentJobs
            .any((j) => j.sha256 == sha && j.fileName == a.fileName)) {
          continue;
        }
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
  ///
  /// 审计修复（WebDAV 报告 §6.1）：此前每轮只消费快照时刻的任务,drain
  /// 执行期间新入队的任务（连续导入的并发 enqueue,其 drain 调用被
  /// _isDrainingAttachments 守卫吞掉）无人再触发,滞留内存队列直至进程
  /// 重启。现在改为循环消费:每轮队尾若队列非空（此时只可能是新任务,
  /// 见下）则续消费。关键约束:失败任务在循环期间滞留在 heldFailed,
  /// 循环退出后才回插队列 —— 若直接回插,「失败回队 → 队尾发现非空 →
  /// 立即重试 → 又失败回队」会把「回队等下次外部 drain」的天然退避
  /// 语义变成无限即时重试循环,持续轰击服务器。
  Future<int> drainAttachmentJobs() async {
    if (_isDrainingAttachments || _pendingAttachmentJobs.isEmpty) return 0;
    _isDrainingAttachments = true;
    try {
      final provider = _provider;
      if (provider == null) return 0;

      var totalOk = 0;
      // 循环期间「回队等下次外部 drain」的失败任务都暂存于此,退出循环
      // 后统一回插 —— 保证续消费轮的快照里只有新入队的任务。
      final heldFailed = <({String sha256, String fileName})>[];
      var continueDrain = true;
      while (continueDrain) {
        final jobs = List<
                ({String sha256, String fileName})>.from(
            _pendingAttachmentJobs);
        _pendingAttachmentJobs.clear();
        final failed = <({String sha256, String fileName})>[];
        var missing = 0;
        final pool = _Semaphore(4);
        final results = await Future.wait(jobs.map((job) async {
          await pool.acquire();
          try {
            final outcome =
                await _downloadAttachmentBinWithRetry(provider, job);
            switch (outcome) {
              case _AttachmentDownloadOutcome.ok:
                break;
              case _AttachmentDownloadOutcome.objectMissing:
                // 审计 TSM-P2：云端确认无此对象（上传端源文件缺失/上传失败），
                // 回队也永远拉不到 —— 不回队，否则每次初始化都 3×N 次网络
                // 重试空转，队列永不收敛。下次该账本快照上传时附件对象会
                // 重新尝试上传，届时自然恢复。
                missing++;
              case _AttachmentDownloadOutcome.transientFailure:
                failed.add(job);
            }
            // P0-1/P1-3：附件补齐逐任务埋点。objectMissing 计 soft_fail
            //（本机附件未收敛但非本次故障）；transientFailure 计 failed
            //（已带 3 次内部重试仍失败）。ledgerId 缺席（内存队列任务不
            // 携带账本号），按 0 号账本归组即可诊断。
            switch (outcome) {
              case _AttachmentDownloadOutcome.ok:
                _recordMetrics(SyncOpScenario.attachmentFill,
                    SyncOpOutcome.success,
                    attempts: 3);
              case _AttachmentDownloadOutcome.objectMissing:
                _recordMetrics(SyncOpScenario.attachmentFill,
                    SyncOpOutcome.softFail,
                    error: fcs.CloudStorageException(
                        '附件对象云端不存在: sha256=${job.sha256}'));
              case _AttachmentDownloadOutcome.transientFailure:
                _recordMetrics(SyncOpScenario.attachmentFill,
                    SyncOpOutcome.failed,
                    error: fcs.CloudStorageException(
                        '附件下载 3 次重试后仍失败: sha256=${job.sha256}'),
                    attempts: 3);
            }
            return outcome == _AttachmentDownloadOutcome.ok;
          } finally {
            pool.release();
          }
        }));

        if (missing > 0) {
          logger.warning(
              'CloudSync',
              '附件补齐：$missing/${jobs.length} 个对象云端不存在，放弃重试'
                  '（下次上传账本时会重新尝试上传附件）');
        }
        if (failed.isNotEmpty) {
          heldFailed.addAll(failed);
          logger.warning('CloudSync',
              '附件补齐下载失败 ${failed.length}/${jobs.length},回队等下次 drain');
        }
        final ok = results.where((r) => r).length;
        if (ok > 0) {
          logger.info('CloudSync', '附件补齐完成: $ok/${jobs.length}');
        }
        totalOk += ok;
        // 队尾:队列此刻只含 drain 执行期间新入队的任务(failed 已被
        // 暂存),非空即续消费一轮
        continueDrain = _pendingAttachmentJobs.isNotEmpty;
      }
      if (heldFailed.isNotEmpty) {
        _pendingAttachmentJobs.addAll(heldFailed);
      }
      return totalOk;
    } finally {
      _isDrainingAttachments = false;
    }
  }

  /// L4：拉取附件对象原始字节。
  ///
  /// BinaryCapableStorage（S3/WebDAV/E2EE 装饰器）走真字节路径；
  /// 其余后端文本下载转字节（历史 base64 文本/加密信封均为文本形态）。
  Future<List<int>?> _fetchAttachmentObjectBytes(
      fcs.CloudProvider provider, String path) async {
    final storage = provider.storage;
    if (storage is fcs.BinaryCapableStorage) {
      final bin = storage as fcs.BinaryCapableStorage;
      try {
        final bytes = await bin.downloadBinary(path: path);
        if (bytes != null) return bytes;
        return null; // 对象不存在
      } on fcs.CloudSyncException {
        rethrow;
      } catch (_) {
        // 二进制路径意外失败：回退文本路径再试（旧对象兼容）
      }
    }
    final text = await storage.download(path: path);
    if (text == null) return null;
    return utf8.encode(text);
  }

  /// L4：从拉取到的原始字节解析出附件内容，多候选嗅探 + sha256 终审。
  ///
  /// 云端对象存在三种形态（按上传时期/加密状态组合）：
  /// 1. 原生二进制（L4 后、无 E2EE、BinaryCapable 后端）；
  /// 2. base64 文本（L4 前的历史对象 / 非 BinaryCapable 后端兜底）；
  /// 3. BEECRYPT1 密文（E2EE 开启期写入；provider 未装饰时需手动解密，
  ///    解密产物为形态 2 的 base64 文本）。
  /// 首选候选恒为原始字节本身；仅当其未通过 sha256 校验时才进入嗅探。
  /// 最终以哈希匹配定案 —— 任何误判候选都会被校验拒绝，不会落脏数据。
  Future<List<int>?> _resolveAttachmentPayload(
      List<int> raw, String expectedSha) async {
    bool shaOk(List<int> c) =>
        crypto.sha256.convert(c).toString() == expectedSha;
    if (shaOk(raw)) return raw;

    final candidates = <List<int>>[raw];
    String? asText(List<int> c) {
      try {
        final t = utf8.decode(c);
        // 出现 NUL 等非法控制字符的不是文本形态
        for (final cu in t.codeUnits) {
          if (cu < 9 || (cu > 13 && cu < 32)) return null;
        }
        return t;
      } catch (_) {
        return null;
      }
    }

    // 下标遍历：嗅探期间追加的派生候选也参与后续嗅探/校验
    for (var i = 0; i < candidates.length; i++) {
      final text = asText(candidates[i]);
      if (text == null) continue;
      if (CiphertextFormat.isEncrypted(text)) {
        try {
          final plain = await _decryptIfNeeded(text);
          candidates.add(utf8.encode(plain));
        } catch (_) {
          // 解密失败（密钥缺失/损坏）：该候选不产生派生形态
        }
        continue;
      }
      final compact = text.replaceAll(RegExp(r'\s'), '');
      if (compact.length % 4 == 0 &&
          RegExp(r'^[A-Za-z0-9+/=]+$').hasMatch(compact)) {
        try {
          candidates.add(base64Decode(compact));
        } catch (_) {
          // 非法 base64：非 base64 形态候选
        }
      }
    }

    for (final c in candidates) {
      if (shaOk(c)) return c;
    }
    return null;
  }

  /// 单个附件对象下载 + 校验 + 落盘,3 次指数退避重试。
  ///
  /// sha256 校验必做:内容寻址的信任根基是"路径即哈希",不校验就把
  /// 损坏/错配的对象当成品落盘,且因文件名带 sha 永远不会再被修复。
  ///
  /// 审计 TSM-P2：返回三态 —— 云端确认无此对象时立即短路（不空转 3 次
  /// 重试），由 drain 侧区分「永缺」与「瞬态故障」，只有后者回队。
  Future<_AttachmentDownloadOutcome> _downloadAttachmentBinWithRetry(
    fcs.CloudProvider provider,
    ({String sha256, String fileName}) job,
  ) async {
    Object? lastError;
    for (var attempt = 0; attempt < 3; attempt++) {
      try {
        final raw = await _fetchAttachmentObjectBytes(
            provider, pathForAttachmentBin(job.sha256));
        if (raw == null) {
          // 云端对象不存在(上传端失败的竞态):回队意义有限但成本低,
          // 保持与其他失败一致的处理。
          return _AttachmentDownloadOutcome.objectMissing;
        }
        // L4：多形态嗅探 + sha256 终审（原生二进制 / base64 文本 / 密文，
        // 见 _resolveAttachmentPayload 文档）。与账本 JSON 同口径：
        // E2EE 开启时装饰器已自动解密；disable 后残留密钥场景由嗅探内
        // _decryptIfNeeded 手动处理；不可解密计入重试/失败。
        final bytes = await _resolveAttachmentPayload(raw, job.sha256);
        if (bytes == null) {
          throw fcs.CloudStorageException(
              '附件 sha256 不匹配: expect=${job.sha256}（所有候选形态均未通过校验）');
        }
        final appDir = await getApplicationDocumentsDirectory();
        final dest = File('${appDir.path}/attachments/${job.fileName}');
        await dest.parent.create(recursive: true);
        // 审计修复（原子落盘）：先写临时文件再 rename。此前直接 writeAsBytes
        // 写目标文件，进程中途被杀会留下截断的半截文件 —— 而入队侧
        // （enqueueMissingAttachmentJobs）按 File.exists() 判重，半截文件
        // 会被当作「已存在」永不重下，且文件名含 sha256 无从察觉损坏。
        // 时间戳 + 进程内序号保证并发下载（semaphore 4）各自独占 tmp。
        final tempPath =
            '${dest.path}.tmp.${DateTime.now().microsecondsSinceEpoch}_${_attachWriteSeq++}';
        final tempFile = File(tempPath);
        try {
          await tempFile.writeAsBytes(bytes, flush: true);
          await tempFile.rename(dest.path);
        } catch (_) {
          // rename 失败尽力清理本次 tmp，避免残留垃圾文件
          try {
            if (await tempFile.exists()) await tempFile.delete();
          } catch (_) {}
          rethrow;
        }
        return _AttachmentDownloadOutcome.ok;
      } catch (e) {
        lastError = e;
        if (attempt < 2) {
          await Future.delayed(Duration(seconds: 1 << attempt));
        }
      }
    }
    logger.warning('CloudSync',
        '附件下载失败 sha256=${job.sha256} after 3 attempts: $lastError');
    return _AttachmentDownloadOutcome.transientFailure;
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) {
    // W6：整本下载恢复属破坏性全量替换（清空后导入），必须处于
    // SyncRestoreGuard 恢复临界区内 —— 定时备份（app.dart）每轮 tick 检查
    // isBusy 让位。否则恢复进行到一半时到点的备份会把半恢复态 DB 打包
    // 上传，覆盖当日好备份，恰好摧毁灾难恢复能力。
    //
    // 审计 TSM-P8：守卫只挡住了「定时备份」，挡不住同实例的并发上传 ——
    // 恢复事务提交前后到达的上传会把恢复前旧内容回传云端，两端立即再次
    // outOfSync。同账本操作再经 _ledgerOpsLocks 串行化。
    return SyncRestoreGuard.run(() => _withLedgerLock(ledgerId,
        () => _downloadAndRestoreToCurrentLedger(ledgerId: ledgerId)));
  }

  Future<({int inserted, int deletedDup})> _downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) async {
    await _ensureInitialized();

    // 捕获到局部变量：防止执行期间 reinitializeForEncryption 把
    // _provider 置 null 导致 NPE（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    // P0-1：快照恢复计时（置于 try 外，供成功/各失败出口统一读取）
    final restoreWatch = Stopwatch()..start();

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
      var jsonStr = await _decryptIfNeeded(raw);

      // M4 + P1-5：内嵌指纹终审（含单次重下自愈）；返回值可能为重下的
      // 新内容（陈旧副本窗口自愈后采用新内容恢复）。
      jsonStr = await _verifyDownloadedSnapshotIntegrity(
        provider: provider,
        path: remotePath,
        plainJson: jsonStr,
        redownload: () => provider.storage.download(path: remotePath),
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
        logger.warning(
            'CloudSync',
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
      // P2-1：恢复导入（recordChanges:false）不写 local_changes、guard
      // 校验位不变，必须显式失效指纹缓存——否则后续 getStatus 命中
      // 恢复前的旧指纹，把刚导入的内容误判为「本地未变」
      invalidateLocalFingerprintCache(ledgerId: ledgerId);

      // P0-1：恢复成功计入指标
      _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.success,
          ledgerId: ledgerId, duration: restoreWatch.elapsed);

      return (
        inserted: result,
        deletedDup: deletedDupCount,
      );
    } on CloudEncryptedLocallyDisabledException {
      // BUG-2 残留修复：云端为密文但本地未开启加密（已在 _decryptIfNeeded 抛出）。
      // 不视为下载失败（不打 error 堆栈），向上抛出由 UI 引导用户开启加密。
      logger.warning('CloudSync', '云端为密文但本地未开启加密，需引导用户开启加密: $ledgerId');
      // P0-1：加密配置问题属环境态而非网络故障，计 failed + auth 类别
      //（密钥缺失时 classifyError 对该异常归 unknown，手动指定 auth）
      _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.failed,
          ledgerId: ledgerId,
          error: fcs.CloudAuthException('cloud encrypted locally disabled'),
          duration: restoreWatch.elapsed);
      rethrow;
    } on CloudCiphertextUndecryptableException {
      // SYNC-10 后半：密钥存在但密文不可解密（损坏/salt 错配/密码已变更）。
      // 向上抛出由 UI 明确呈现，不再落入通用 catch 被当作普通失败吞掉。
      logger.warning('CloudSync', '云端密文无法用本机密钥解密，恢复中止: $ledgerId');
      // P0-1：密文不可解密属数据损坏态
      _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.failed,
          ledgerId: ledgerId,
          error: fcs.CloudStorageException('密文损坏/密钥不匹配'),
          duration: restoreWatch.elapsed);
      rethrow;
    } catch (e, stack) {
      logger.error('CloudSync', '下载失败: $ledgerId', e);
      logger.error('CloudSync', '堆栈', stack);

      // m-04 契约澄清：S3/WebDAV 的 download/getMetadata 在 404 时返回
      // null（见 core exceptions.dart 契约注释），正常路径根本不会以异常
      // 形式到达这里 —— 此处的字符串匹配只是对「网关把 404 包成存储故障
      // 上抛」的防御性兜底。CloudFileNotFoundException 类型分支已删：
      // 当前两个适配器均不抛该类型，保留只会误导读者以为它会命中。
      if (e.toString().contains('404') || e.toString().contains('not found')) {
        // P0-1：网关把 404 包成存储故障的兜底路径 —— 恢复结果为
        //「云端无备份」，不算失败也不算成功（无数据可恢复）。
        return (inserted: 0, deletedDup: 0);
      }

      // P0-1：真实失败（网络/解析/存储）计入指标后原样上抛
      _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.failed,
          ledgerId: ledgerId, error: e, duration: restoreWatch.elapsed);
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
  Future<
      ({
        SyncPreview? preview,
        ImportData importData,
        int version,
        String? cloudFingerprint
      })?> downloadAndPreview({
    required int ledgerId,
  }) async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }

    logger.info('CloudSync', '开始下载预览: $ledgerId');

    final remotePreviewPath = await pathForLedger(ledgerId);
    final raw = await provider.storage.download(path: remotePreviewPath);

    if (raw == null) {
      logger.warning('CloudSync', '云端备份不存在');
      return null;
    }

    // 规整为可解析明文：disable 后密钥仍保留则解密；无密钥或密文不可
    // 解密（SYNC-10）抛专属异常，由调用方/UI 明确呈现错误，不再当作
    // 「云端无数据」静默返回 null。
    var jsonStr = await _decryptIfNeeded(raw);
    // M4 + P1-5：合并预览也是破坏性入口的依据数据（applyPreviewChanges
    // 按此合并落库），内嵌指纹终审防脏快照进入合并决策；重下自愈后的
    // 新内容作为预览/合并基准。
    jsonStr = await _verifyDownloadedSnapshotIntegrity(
      provider: provider,
      path: remotePreviewPath,
      plainJson: jsonStr,
      redownload: () => provider.storage.download(path: remotePreviewPath),
    );

    // 一次 isolate 解析取回全部所需产物（ImportData + version + 内嵌指纹）。
    // 此前是主线程 jsonDecode 取元数据 + parseJsonToImportData 再解一遍
    // —— 大快照（万笔交易）下双份 jsonDecode 都发生在 UI 线程；合并为
    // 单次后台解析后，主线程只剩 isolate 结果的直接引用。
    final parsed = await compute(parseSnapshotIsolate, jsonStr);
    final version = parsed.version;
    final importData = parsed.importData;
    // 审计 H6：快照自描述的内嵌指纹（与内容同生共死）。启动检查的
    // merge-then-publish 用它做「回传前新鲜度校验」的基线 —— 合并决策
    // 所依据的云端内容若在回传前被其他设备更新，回传即中止而非覆盖。
    final cloudFingerprint = parsed.contentFingerprint;

    // 检查是否含 syncId（v6+）
    if (version >= 6) {
      final preview = await syncDiffService.computeDiff(
        repo: repo,
        ledgerId: ledgerId,
        cloudTransactions: importData.transactions,
      );

      if (preview != null) {
        return (
          preview: preview,
          importData: importData,
          version: version,
          cloudFingerprint: cloudFingerprint,
        );
      }
    }

    // 旧格式或无法计算 diff
    return (
      preview: null,
      importData: importData,
      version: version,
      cloudFingerprint: cloudFingerprint,
    );
  }

  /// 应用预览中选中的变更
  ///
  /// 审计 A3：合并写入是破坏性批量操作（可达万级行），必须与同账本的
  /// 「上传 ↔ 恢复」互斥并让定时备份让位 —— 此前本方法不持账本锁、也不进
  /// SyncRestoreGuard 临界区，启动检查合并期间到点的备份 tick 会把半合并态
  /// 账本推上云端覆盖好快照（与 W6/TSM-P8 在另两条路径修掉的灾难同构）。
  /// 守卫与锁的获取顺序对齐 downloadAndRestoreToCurrentLedger
  /// （先守卫后锁），守卫为计数器、嵌套安全。
  Future<SyncApplyResult> applyPreviewChanges({
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) {
    return SyncRestoreGuard.run(() => _withLedgerLock(ledgerId, () async {
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
          // P2-1：合并写入与恢复同理（不写 local_changes / guard 不变），
          // 显式失效指纹缓存
          invalidateLocalFingerprintCache(ledgerId: ledgerId);

          // 附件差异贯通：modified 合并可能带入带 sha256 的附件清单，本地缺的
          // 文件从 attachments/<sha256>.bin 后台补齐（与下载恢复路径同口径，
          // 不阻塞 apply 返回）。
          if (result.totalCount > 0) {
            unawaited(enqueueMissingAttachmentJobs(ledgerId)
                .then((_) => drainAttachmentJobs()));
          }

          return result;
        }));
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
      logger.debug(
          'CloudSync', '缓存命中: ledgerId=$ledgerId, diff=${cached.status.diff}');
      return cached.status;
    }
    if (cached != null && cached.isExpired) {
      logger.debug('CloudSync', '缓存过期，重新计算: ledgerId=$ledgerId');
      _statusCache.remove(ledgerId);
    }

    logger.debug('CloudSync', '缓存未命中，开始计算: ledgerId=$ledgerId');

    try {
      // 计算本地指纹（P2-1：优先走指纹缓存——冷启动首轮 getStatus 曾对
      // 每个账本全量导出算指纹，大账本 CPU 重；缓存 + 变更校验位命中时
      // 直接复用，跳过导出。jsonStr 为 null 表示走缓存路径，下方按需
      // 传给 manager 的 F6 复用参数随之省略——manager 内部会自行导出，
      // 退化为旧行为一次，不影响正确性）
      final local =
          await _localFingerprintWithCache(ledgerId);
      final localFp = local.fingerprint;
      final localCount = local.count;
      final jsonStr = local.jsonStr;

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
      final disabledStatus =
          await _cloudEncryptedLocallyDisabledStatus(ledgerId);
      if (disabledStatus != null) return disabledStatus;

      logger.info('CloudSync', '获取同步状态: $ledgerId');

      // 调用包的 getStatus，传入时间戳用于方向判断
      final fcsStatus = await manager.getStatus(
          data: ledgerId,
          path: await pathForLedger(ledgerId),
          localUpdatedAt: await _computeLocalUpdatedAt(ledgerId),
          forceRefresh: true,
          // F6：复用上方已导出的 JSON，省去 manager 内部对同一账本的
          // 第二次全量导出（P2-1 缓存命中路径 jsonStr 为 null，包内
          // 按需自行导出——该场景云端指纹必然要全量下载比对，导出
          // 无法避免，不构成退化）
          localSerializedData: jsonStr,
          // F6 延伸：localMap 是同一份 payload 的已解析形态，count
          // 直接透传，manager 跳过第二次 jsonDecode（缓存命中路径
          // count=0 时省略——包内自行重算，避免拿 0 当真实 count）
          localParsedCount: jsonStr != null ? localCount : null);

      // 转换包的 SyncStatus 为 PiggyCount 的 SyncStatus
      final status = _convertSyncStatus(fcsStatus);

      // 缺口 1: fcs.CloudSyncManager 内部捕获 SaltMismatchException 后返回 error 状态，
      // message 含原始异常文本（如 "Failed to get sync status: SaltMismatchException: ..."）。
      // 检测并转为哨兵 message 'salt_mismatch_need_password' 供 UI 识别并弹密码对话框。
      if (status.diff == SyncDiff.error &&
          status.message != null &&
          status.message!.contains('SaltMismatchException')) {
        logger.warning('CloudSync', 'salt 不匹配，需引导用户重新输入密码: $ledgerId');
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
        logger.info(
            'CloudSync',
            '指纹不一致 本地: ${status.localFingerprint.substring(0, 8)} '
                '云端: ${status.cloudFingerprint != null && status.cloudFingerprint!.length >= 8 ? status.cloudFingerprint!.substring(0, 8) : "无"} '
                '数量 本地${status.localCount}/云端${status.cloudCount ?? "无"}');
      }
      logger.debug('CloudSync', '本地指纹: ${status.localFingerprint}');
      logger.debug('CloudSync', '云端指纹: ${status.cloudFingerprint ?? "无"}');
      logger.debug('CloudSync',
          '本地数量: ${status.localCount}, 云端数量: ${status.cloudCount ?? "无"}');

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
    // P2-1：UI 后处理显式标记本地变更 → 指纹缓存一并失效
    invalidateLocalFingerprintCache(ledgerId: ledgerId);
    logger.info('CloudSync', '标记本地变更: $ledgerId');
  }

  // ============ P2-1：本地快照指纹缓存 ============

  /// 挂载 ChangeTracker 写路径回调（幂等）。user-global（ledgerId=0）
  /// 变更影响所有快照 → 全部失效。
  void _wireChangeTrackerGeneration() {
    final tracker = repo.changeTracker;
    if (tracker == null) return;
    tracker.onLocalContentGeneration ??= (ledgerId) {
      if (ledgerId == null || ledgerId == 0) {
        invalidateLocalFingerprintCache();
      } else {
        invalidateLocalFingerprintCache(ledgerId: ledgerId);
      }
    };
  }

  /// 失效本地指纹缓存。不带 [ledgerId] = 全部失效（user-global 变更/
  /// 批量导入/未知作用域）。
  void invalidateLocalFingerprintCache({int? ledgerId}) {
    if (ledgerId == null) {
      if (_localFpCache.isNotEmpty) {
        _localFpCacheInvalidated.addAll(_localFpCache.keys);
        _localFpCache.clear();
      }
      return;
    }
    if (_localFpCache.remove(ledgerId) != null) {
      _localFpCacheInvalidated.add(ledgerId);
    }
  }

  /// local_changes 轻量校验位：MAX(id) + 未推送行数。
  ///
  /// 指纹缓存命中前的兜底校验——两次调用间该值不变，则期间无任何
  /// 新登记的写操作（recordChanges:false 导入不插行，但 MAX(id) 在
  /// 其他写后单调增会反映出来；纯 suppressed 导入后 UI 刷新通常伴
  /// 随 markLocalChanged 主动失效）。两条防线（tracker 回调 + 校验位）
  /// 任一发现变化都会失效。
  Future<String> _localChangeGuard() async {
    try {
      final maxQuery = db.selectOnly(db.localChanges)
        ..addColumns([
          db.localChanges.id.max(),
          db.localChanges.id.count(),
        ]);
      final row = await maxQuery.getSingleOrNull();
      final maxId = row?.read(db.localChanges.id.max()) ?? -1;
      final total = row?.read(db.localChanges.id.count()) ?? 0;
      return '$maxId/$total';
    } catch (_) {
      // 查询失败：返回随机值强制失效（宁可多算不可漏算）
      return 'err/${DateTime.now().millisecondsSinceEpoch}';
    }
  }

  /// 取本地指纹（P2-1 缓存路径）。
  ///
  /// 命中且校验位不变 → 复用上次导出的指纹，跳过全量导出（冷启动/
  /// 缓存过期后的 getStatus 主要 CPU 成本归零）；否则全量导出并刷新
  /// 缓存。上传成功路径调用 [rememberLocalFingerprint] 登记后同样受益。
  Future<({String fingerprint, int count, String? jsonStr})>
      _localFingerprintWithCache(int ledgerId) async {
    final guard = await _localChangeGuard();
    final cached = _localFpCache[ledgerId];
    if (cached != null &&
        !_localFpCacheInvalidated.contains(ledgerId) &&
        cached.changeGuard == guard) {
      logger.debug('CloudSync',
          '本地指纹走缓存: ledgerId=$ledgerId (guard=$guard)');
      return (
        fingerprint: cached.fingerprint,
        count: 0, // count 缓存未存——复用方需 count 时另行查询或全量导出
        jsonStr: null,
      );
    }
    // 全量导出（同时刷新缓存）
    final jsonStr = await exportTransactionsJson(db, ledgerId);
    final localMap = jsonDecode(jsonStr) as Map<String, dynamic>;
    final fp = _contentFingerprintFromMap(localMap);
    final count = (localMap['count'] as num?)?.toInt() ?? 0;
    _localFpCache[ledgerId] = (fingerprint: fp, changeGuard: guard);
    _localFpCacheInvalidated.remove(ledgerId);
    return (fingerprint: fp, count: count, jsonStr: jsonStr);
  }

  /// 上传/导出路径已有全量导出结果时登记进缓存（省去 getStatus 侧
  /// 重复导出）。guard 以登记时刻现算——登记前的写操作已包含在
  /// 导出的内容里，无漏判。
  Future<void> rememberLocalFingerprint(
      int ledgerId, String fingerprint) async {
    _localFpCache[ledgerId] = (
      fingerprint: fingerprint,
      changeGuard: await _localChangeGuard(),
    );
    _localFpCacheInvalidated.remove(ledgerId);
  }

  /// 测试钩子（@visibleForTesting）：手动执行 tracker 回调接线
  /// （生产在 _ensureInitialized 提交后自动挂；测试不走初始化）。
  @visibleForTesting
  void wireChangeTrackerGenerationForTesting() => _wireChangeTrackerGeneration();

  /// 测试钩子（@visibleForTesting）：取本地指纹（走 P2-1 缓存路径）。
  /// 生产代码禁止使用——getStatus 才是正式消费方。
  @visibleForTesting
  Future<String> localFingerprintForTesting(int ledgerId) async {
    final r = await _localFingerprintWithCache(ledgerId);
    return r.fingerprint;
  }

  /// M7：上传前冲突判定。返回探测结果：
  /// - [UploadProbe.direction] 非 null = 冲突（'cloudNewer'/'unknown'），禁止盲传；
  /// - null = 可安全上传；
  /// - [UploadProbe.cloudETag] 为探测时读到的云端 ETag（可能为 null），
  ///   方案C：作为乐观并发锚点传给 manager.upload，后端支持条件写时
  ///   「探测 → 写入」之间的并发修改会以 412 显式暴露而非静默覆盖。
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
  /// 4. 探测自身失败（网络等）→ **中止上传**（审计 A5 策略变更）：
  ///    旧取舍「可用性优先、行为等同旧版」意味着网络抖动时可能盖掉他机
  ///    刚写入的数据且用户毫不知情；改为抛出带指引的错误，重试即可恢复
  ///    可用性，而数据安全不再取决于网络运气。
  ///
  /// 注意 M2 指纹算法升级的迁移窗口：旧元数据指纹与新算法必有一轮错位，
  /// 此时会落到 unknown 冲突——用户走一次对比合并（或确认覆盖）即写入
  /// 新算法元数据，永久收敛。
  Future<UploadProbe> _detectUploadConflict({
    required fcs.CloudProvider provider,
    required int ledgerId,
    required String? localFp,
  }) async {
    try {
      final meta = await provider.storage
          .getMetadata(path: await pathForLedger(ledgerId));
      if (meta == null) return const UploadProbe(); // 云端无备份

      final remoteFp = _metaValue(meta.metadata, 'fingerprint');
      if (localFp != null && remoteFp != null && localFp == remoteFp) {
        return UploadProbe(cloudETag: meta.eTag); // 内容一致
      }

      // 审计 TSM-P3：元数据指纹缺失（WebDAV sidecar 丢失/写失败、S3 头被
      // 剥）或与本地不符时，下载内容一次读取**内嵌指纹**做终审。指纹随
      // 快照自描述（exportTransactionsJson 写入 'contentFingerprint' 键，
      // 白名单式指纹函数天然忽略它），不依赖外部元数据存活：
      // - 内嵌 == 本地 → 内容一致，直接放行（消除「sidecar 丢失 + 本地
      //   证据不可信 → 恒 unknown 冲突」死循环的最常见分支）；
      // - 内嵌 != 本地 → 内容确实不同，落入下方方向仲裁；
      // - 无内嵌键（旧快照）→ 维持原仲裁路径。
      if (localFp != null) {
        final embeddedFp = await _embeddedRemoteFingerprint(provider, ledgerId);
        if (embeddedFp != null) {
          if (embeddedFp == localFp) {
            logger.info('CloudSync', '冲突检测：元数据指纹缺失/错位，内嵌指纹一致 → 放行上传');
            return UploadProbe(cloudETag: meta.eTag);
          }
          // 内容确实不同：跳过下面基于「指纹可能只是丢失」的乐观假设，
          // 直接按内容不同走时间仲裁
        }
      }

      // 指纹不同（或一侧缺失）→ 方向仲裁（只信可信证据）
      final remoteAt =
          DateTime.tryParse(_metaValue(meta.metadata, 'uploadedAt') ?? '') ??
              meta.lastModified;
      if (remoteAt == null) return UploadProbe(direction: 'unknown');
      final evidence = await _localChangeEvidence(ledgerId);
      final localAt = evidence.at;
      if (!evidence.trusted || localAt == null) {
        return UploadProbe(direction: 'unknown');
      }
      if (localAt.isAfter(remoteAt)) {
        return UploadProbe(cloudETag: meta.eTag); // 本地较新：正常覆盖
      }
      if (remoteAt.isAfter(localAt)) {
        return UploadProbe(direction: 'cloudNewer');
      }
      return UploadProbe(direction: 'unknown'); // 同秒且内容不同：无法判定
    } catch (e) {
      // F5：认证失败不是「探测不到」而是「确定读不到云端状态」——此时
      // 放行上传会静默盖掉其他设备的数据，且用户得不到任何修复指引。
      // 向上抛出由调用方按凭据错误引导（启动检查器/UI 均已区分
      // CloudAuthException）。
      if (e is fcs.CloudAuthException) rethrow;
      // 审计 A5 策略变更：其余瞬态故障（网络抖动等）从「放行上传」改为
      // 「中止上传」。可用性损失仅是一次可重试的失败提示；数据安全收益
      // 是不再有「探测不到就盲传」的覆盖窗口。
      logger.warning('CloudSync', '上传冲突检测失败（已中止上传）: $e');
      throw fcs.CloudSyncException(
        '无法确认云端当前状态（$e）。为避免覆盖其他设备的更新已中止本次上传，请稍后重试',
        e,
      );
    }
  }

  /// 从 JSON payload 计算内容指纹
  ///
  /// 委托给共享函数 [contentFingerprintFromMap]（US-5 抽取），
  /// 规范化规则与序列化器侧保持一致，避免双份实现漂移。
  String _contentFingerprintFromMap(Map<String, dynamic> payload) =>
      contentFingerprintFromMap(payload);

  /// 审计 TSM-P3：读取云端快照**内嵌**的内容指纹（'contentFingerprint' 键）。
  ///
  /// 指纹随快照自描述后，这是比外部元数据（x-amz-meta / WebDAV sidecar）
  /// 更权威的来源 —— 元数据可能丢失、被网关剥离或残留陈旧值，内嵌值永远
  /// 与内容同生共死。下载经装饰器自动解密；解析失败/旧快照无键返回 null。
  Future<String?> _embeddedRemoteFingerprint(
      fcs.CloudProvider provider, int ledgerId) async {
    try {
      final raw =
          await provider.storage.download(path: await pathForLedger(ledgerId));
      if (raw == null) return null;
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        final v = decoded['contentFingerprint'];
        if (v is String && v.isNotEmpty) return v;
      }
    } catch (e) {
      logger.warning('CloudSync', '读取内嵌指纹失败（忽略）: $e');
    }
    return null;
  }

  /// M4 + 审计 P1-5：下载内容的完整性终审（破坏性恢复前的硬闸门）。
  ///
  /// 包内 CloudSyncManager.download 自带完整性校验，但 App 层全部直连
  /// provider.storage.download，该防线是死代码；此前的对位物是只记
  /// warning 的软告警 —— CDN 陈旧副本/网关截断的脏数据可以无声流入
  /// 破坏性恢复。现收口为与 manager 层（M14）同语义的硬校验：
  ///
  /// 基准取**快照内嵌指纹**（'contentFingerprint'，与内容同生共死，
  /// 比 metadata 指纹更权威）而非 metadata —— 软告警时代的错位误报
  /// （M2 指纹算法升级后 metadata 残留旧值）在换基准后不复存在：
  /// 内嵌值不存在「算法迁移错位」问题，只有「内容确实变了」一种解释。
  ///
  /// - 内容非 JSON / 无内嵌指纹（v6 前旧快照）→ 退回 metadata 交叉
  ///   软告警（旧算法迁移窗口兼容，维持 M4 的既有取舍）；
  /// - 内嵌指纹 ≠ 内容重算指纹 → **重下重试一次**（并发竞态自愈：
  ///   「下载内容」与「内容本身」都是同一请求的产物，此处重验的是
  ///   内容自洽性而非跨请求比对，重下应对 CDN/网关陈旧副本窗口）；
  ///   仍不一致 → 硬失败抛 [fcs.CloudStorageException]（完整性校验
  ///   失败，恢复中止）—— 破坏性恢复吃进坏数据比阻断更危险。
  Future<String> _verifyDownloadedSnapshotIntegrity({
    required fcs.CloudProvider provider,
    required String path,
    required String plainJson,
    required Future<String?> Function() redownload,
  }) async {
    Map<String, dynamic> map;
    try {
      map = jsonDecode(plainJson) as Map<String, dynamic>;
    } catch (_) {
      throw fcs.CloudStorageException(
          '云端数据完整性校验失败（内容不是合法 JSON 快照）: $path');
    }
    final embeddedFp = map['contentFingerprint'];
    if (embeddedFp is String && embeddedFp.isNotEmpty) {
      final contentFp = _contentFingerprintFromMap(map);
      if (contentFp == embeddedFp) {
        logger.debug('CloudSync', '完整性终审通过(内嵌指纹): $path');
        return plainJson;
      }
      // 陈旧副本窗口：重下一次再验（对齐 core manager M14 的竞态重试）
      logger.warning('CloudSync',
          '完整性终审不一致，重下再验: $path (embedded=$embeddedFp content=$contentFp)');
      final retried = await redownload();
      if (retried != null) {
        try {
          final retriedMap = jsonDecode(retried) as Map<String, dynamic>;
          final retriedEmbedded = retriedMap['contentFingerprint'];
          final retriedContent = _contentFingerprintFromMap(retriedMap);
          if (retriedEmbedded is String &&
              retriedEmbedded.isNotEmpty &&
              retriedContent == retriedEmbedded) {
            logger.info('CloudSync', '重下后完整性终审通过: $path');
            return retried;
          }
        } catch (_) {
          // 重下内容不可解析 → 下方统一硬失败
        }
      }
      throw fcs.CloudStorageException(
          '云端数据完整性校验失败（内嵌指纹与内容不匹配，重下后仍不一致）: $path');
    }

    // ---- 旧快照（无内嵌指纹）：保留 metadata 交叉软告警（M4 既有取舍）----
    await _warnIfRemoteFingerprintMismatch(
      provider: provider,
      path: path,
      plainJson: plainJson,
    );
    return plainJson;
  }

  /// M4：下载内容与元数据指纹交叉自检（软告警版，不阻断恢复）。
  ///
  /// P1-5 后本方法只服务「无内嵌指纹的旧快照」—— 新快照走
  /// [_verifyDownloadedSnapshotIntegrity] 的硬闸门。旧算法元数据错位
  /// 硬失败会把「一次性 outOfSync」恶化成「恢复被阻断」，维持软告警。
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
        logger.warning(
            'CloudSync', '完整性自检：下载内容不是 JSON 对象(path=$path)，请留意数据完整性');
        return;
      }
      final contentFp = _contentFingerprintFromMap(map);
      if (contentFp != remoteFp) {
        logger.warning(
            'CloudSync',
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
      // m-04 契约澄清（同 downloadAndRestoreToCurrentLedger 处注释）：
      // delete 幂等吞 404 由适配器完成；此处仅防御网关包装上抛的场景
      if (e.toString().contains('404') || e.toString().contains('not found')) {
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

  /// R1 接线（审计 S24）：尝试恢复一次被中断的改密。
  ///
  /// 改密流程在「云端重加密完成 → 本地持久化新密钥」之间崩溃时，新钥
  /// 只存在于 secure storage 检查点中；此前 recoverPendingRekey 无任何
  /// 生产调用方，检查点永久滞留 → 云端停留在部分新密钥状态，下次改密
  /// /解密全部失败。本方法在每次 [ensureInitialized] 时异步尝试：
  ///
  /// - 无检查点（常态）：一次 secure-storage 读即返回，近零成本；
  /// - 有检查点且恢复成功：云端补齐 + 本地切换新钥后重建装饰器，
  ///   使后续同步立即用新密钥加解密；
  /// - 恢复失败：记录日志、检查点保留，下次调用自动再试，绝不阻断
  ///   同步主流程（恢复是后台修复语义，同步可用性优先）。
  ///
  /// 单飞锁 [_rekeyRecoveryInFlight]：并发调用（ensureInitialized 是热点
  /// 入口，几乎每个同步操作都经过）只跑一次恢复，其余直接返回 —— 无
  /// 检查点场景的成本被压到「并发窗口内一次 secure-storage 读」。
  Future<void>? _rekeyRecoveryInFlight;

  Future<void> _tryRecoverPendingRekey() async {
    final inFlight = _rekeyRecoveryInFlight;
    if (inFlight != null) return inFlight;
    final future = _doRecoverPendingRekey();
    _rekeyRecoveryInFlight = future;
    try {
      await future;
    } finally {
      if (identical(_rekeyRecoveryInFlight, future)) {
        _rekeyRecoveryInFlight = null;
      }
    }
  }

  Future<void> _doRecoverPendingRekey() async {
    final svc = encryptionService;
    final rawStorage = _rawStorage;
    if (svc == null || rawStorage == null) return;
    try {
      final recovered = await svc.recoverPendingRekey(cloudStorage: rawStorage);
      if (recovered) {
        logger.info('CloudSync', '检测到未完成的改密检查点并已恢复，重建加密装饰器以启用新密钥');
        await reinitializeForEncryption();
      }
    } catch (e, st) {
      logger.warning('CloudSync', '改密检查点恢复失败（下次调用重试）: $e', st);
    }
  }

  /// M3：补删换名收尾失败的旧远程槽位。
  ///
  /// 单个失败保留在列表中等下次重试；全部尝试完毕后未成功项继续留存。
  /// 删除语义幂等（404 视为不存在），重复调用安全。
  Future<void> _retryStaleSlotDeletes() async {
    final provider = _provider;
    if (provider == null || _staleRemoteSlots.isEmpty) return;
    for (final path in List<String>.from(_staleRemoteSlots)) {
      try {
        await provider.storage.delete(path: path);
        _staleRemoteSlots.remove(path);
        await _removeStaleSlotRecord(path);
        logger.info('CloudSync', '旧远程文件补删成功: $path');
      } catch (e) {
        logger.warning('CloudSync', '旧远程文件补删失败（下次初始化重试）: $path - $e');
      }
    }
  }

  /// P1-6：stale_remote_slots 表的登记/移除/装载（DB 事实源 + 内存加速）。
  ///
  /// 写库失败只 warning 不阻断主流程 —— 补删本身是自愈型后台动作，DB 暂时
  /// 不可写时退化为旧行为（内存登记、本会话内补删），下次成功写入恢复持久化。
  Future<void> _recordStaleSlot(String path) async {
    if (_staleRemoteSlots.contains(path)) return;
    _staleRemoteSlots.add(path);
    try {
      await db.into(db.staleRemoteSlots).insert(
            StaleRemoteSlotsCompanion.insert(path: path),
            mode: drift.InsertMode.insertOrIgnore,
          );
    } catch (e) {
      logger.warning('CloudSync', 'stale_remote_slots 登记落库失败(降级内存): $e');
    }
  }

  Future<void> _removeStaleSlotRecord(String path) async {
    try {
      await (db.delete(db.staleRemoteSlots)
            ..where((s) => s.path.equals(path)))
          .go();
    } catch (e) {
      logger.warning('CloudSync', 'stale_remote_slots 移除落库失败(忽略): $e');
    }
  }

  /// P1-6：初始化时装载持久化的补删登记（跨重启恢复），装载失败不阻断
  /// 初始化 —— 空集退化为旧行为，下次初始化重试装载。
  Future<void> _loadStaleSlotRecords() async {
    try {
      final rows = await db.select(db.staleRemoteSlots).get();
      _staleRemoteSlots.addAll(rows.map((r) => r.path));
      if (rows.isNotEmpty) {
        logger.info('CloudSync', '装载持久化补删登记 ${rows.length} 条');
      }
    } catch (e) {
      logger.warning('CloudSync', 'stale_remote_slots 装载失败(忽略): $e');
    }
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

    // 审计 TSM-P10：本次调用新建的账本行 id。恢复成功即清空；任何异常
    // 退出时由外层 catch 回收，避免数据库残留空壳账本（此前只清理两类
    // 加密异常，解析/网络等失败路径会漏）。
    int? createdLedgerThisCall;

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
      final existingByName = sameNameRows.isEmpty ? null : sameNameRows.first;

      final int ledgerId;
      bool reusedExistingRow = false;

      // 审计 TSM-P1：跨身份接管标记。同名复用但本地账本身份（syncId）
      // 与云端槽位 key 不同 —— 用户确认的是「下载该云端账本覆盖同名本地
      // 账本」，但收尾绝不能把被覆盖后的内容回传到本地账本**自己的**云端
      // 槽位并删除远程原文件：那会把 Y 的数据写进 X 的槽位，静默污染/
      // 摧毁其他设备上真 X 的备份（超出用户授权范围）。
      var crossIdentityTakeover = false;

      if (existingByName != null) {
        // 复用同名账本的行（不创建新账本）
        ledgerId = existingByName.id;
        reusedExistingRow = true;
        final existingSyncId = existingByName.syncId?.trim() ?? '';
        crossIdentityTakeover = slotKey != null &&
            existingSyncId.isNotEmpty &&
            existingSyncId != slotKey;
        logger.info(
            'CloudSync',
            '本地已存在同名账本，复用账本ID: $ledgerId (名称: $name)'
                '${crossIdentityTakeover ? '，注意：与云端槽位身份不同（跨身份接管）' : ''}');
      } else if (slotKey != null) {
        final sameIdentity = await _localLedgerForSlotKey(slotKey);
        if (sameIdentity != null) {
          ledgerId = sameIdentity.id;
          reusedExistingRow = true;
          logger.info(
              'CloudSync', '本地已有同源账本(syncId=$slotKey)，复用账本ID: $ledgerId');
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
          logger.info('CloudSync', '创建新账本: id=$ledgerId, syncId=$slotKey');
          createdLedgerThisCall = ledgerId;
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
        createdLedgerThisCall = ledgerId;
      }

      // 审计 TSM-P8：破坏性阶段（清空+导入+换名收尾）在账本锁内执行，
      // 与同账本的并发上传互斥（否则恢复事务提交前后到达的上传会把恢复前
      // 旧内容回传云端）。锁在 ledgerId 解析后获取：新建行的 id 在此之前
      // 对其他调用方不可见，不存在锁窗口外的竞态。
      return _withLedgerLock<int?>(ledgerId, () async {
        // 下载数据
        final raw = await provider.storage.download(path: remotePath);

        if (raw == null) {
          logger.warning('CloudSync', '云端账本不存在: $remotePath');
          // 只有本次新建的账本才需要删除
          if (!reusedExistingRow) {
            await (db.delete(db.ledgers)..where((t) => t.id.equals(ledgerId)))
                .go();
            createdLedgerThisCall = null;
          }
          return null;
        }

        // 规整为可解析明文：disable 后密钥仍保留则解密后导入；
        // 无密钥 / 密文不可解密（SYNC-10 后半）→ 抛专属异常由 UI 明确呈现，
        // 新建的空壳账本行由外层 catch 统一回收（审计 TSM-P10）。
        final String jsonStr;
        try {
          jsonStr = await _decryptIfNeeded(raw);
        } on CloudEncryptedLocallyDisabledException catch (e) {
          logger.warning('CloudSync', '云端账本 $remotePath 为密文且本地无可用密钥: $e');
          rethrow;
        } on CloudCiphertextUndecryptableException catch (e) {
          logger.warning('CloudSync', '云端账本 $remotePath 密文不可解密: $e');
          rethrow;
        }
        // M4 + P1-5：内嵌指纹终审（含单次重下自愈）；返回值可能为
        // 重下的新内容（陈旧副本窗口自愈后采用新内容导入）。
        final verifiedJson = await _verifyDownloadedSnapshotIntegrity(
          provider: provider,
          path: remotePath,
          plainJson: jsonStr,
          redownload: () => provider.storage.download(path: remotePath),
        );

        // H2：同名/既有账本的云端下载统一走「先清空再导入」的覆盖语义
        // （restoreLedgerFromJson：含 P1-1 空快照守卫 + 事务原子 +
        // recordChanges:false + v9 sync_id 回填），与
        // downloadAndRestoreToCurrentLedger / 全量覆盖恢复对齐，
        // 消除旧实现「同名账本追加合并 → 交易翻倍」。
        final restored = await restoreLedgerFromJson(
            db: db, repo: repo, ledgerId: ledgerId, jsonStr: verifiedJson);
        if (restored == null) {
          // P1-1 拒绝空覆盖：本地未接受云端状态，云端文件原样保留，
          // 也不做下方的「上传新槽位/删旧文件」换名操作。
          logger.warning(
              'CloudSync', '云端快照为空且本地非空，拒绝覆盖，保留本地与云端现状: $remotePath');
          return null;
        }
        logger.info('CloudSync',
            '下载完成(覆盖语义): ledgerId=$ledgerId, inserted=${restored.inserted}, 清空=${restored.deletedDup}, skippedRecurring=${restored.skippedRecurring}');
        // 审计 TSM-P10：恢复已成功提交，此后失败不再回收账本行（数据是完整的）
        createdLedgerThisCall = null;
        // P2-1：覆盖恢复（recordChanges:false）显式失效指纹缓存；
        // 下方换名收尾若走 _uploadCurrentLedgerCore 会重新登记新值
        invalidateLocalFingerprintCache(ledgerId: ledgerId);
        if (restored.skippedRecurring > 0) {
          logger.warning('CloudSync',
              '恢复时有 ${restored.skippedRecurring} 笔同日周期实例被判重跳过，请核对源端明细');
        }

        // 云端文件收尾：目标槽位与远程文件名不一致时才需要换名
        // （Critical-07：先上传后删除，防删除成功但上传失败丢数据）。
        //
        // 审计 TSM-P1：跨身份接管（同名但不同源）时**跳过整个换名收尾** ——
        // 此前会把 Y 的内容上传到 X 自己的云端槽位（覆盖其他设备上真 X 的
        // 备份）并删除远程 Y 原文件，静默摧毁超出用户授权范围的数据。
        // 现在只完成本地覆盖，云端两侧文件原样保留，由用户手动核对后续。
        if (crossIdentityTakeover) {
          logger.warning(
              'CloudSync',
              '跨身份接管：本地账本 $ledgerId 已被云端快照覆盖，但其原云端槽位与'
                  '远程文件均保持原样，请自行核对其他设备的同步状态 ($remotePath)');
          return ledgerId;
        }
        final targetPath = await pathForLedger(ledgerId);
        if (_baseName(targetPath) != _baseName(remotePath)) {
          // M7：刚以云端为准恢复完本地（内容一致），force 跳过冲突拦截。
          // 审计 TSM-P8：已在账本锁内，直接调内部核心避免重入死锁。
          //
          // H3（审计备案，有意绕过 SyncRestoreGuard）：这里刻意不走公开的
          // uploadCurrentLedger（其 TSM-P8 守卫会在恢复临界区内拒绝），
          // 直调 _uploadCurrentLedgerCore。安全性论证：上传发生在
          // restoreLedgerFromJson 事务**已提交**之后，快照取自完整一致的
          // 账本数据，不存在「半恢复态上云」；guard 挡的是定时备份打包
          // 半恢复态 DB，与这里的单账本收尾语义不同。与启动检查
          // merge-then-publish 的 bypassRestoreGuard 豁免（P0-1）同理。
          try {
            await _uploadCurrentLedgerCore(ledgerId: ledgerId, force: true);
            logger.info('CloudSync', '账本已上传到云端: $targetPath');
            // 上传成功后再删除旧文件
            try {
              await provider.storage.delete(path: remotePath);
              logger.info('CloudSync', '旧远程文件已删除: $remotePath');
            } catch (e) {
              // M3 + P1-6：删除失败登记补删列表（持久化到 stale_remote_slots
              // 表,跨重启存活）—— 否则旧 slot 残留且其 slotKey 不匹配任何
              // 本地账本，下次启动会被发现流程再次提示导入（重复账本窗口）。
              await _recordStaleSlot(remotePath);
              logger.warning('CloudSync', '删除旧远程文件失败（已登记补删）: $remotePath - $e');
            }
          } catch (e) {
            logger.warning('CloudSync', '上传账本失败（旧文件保留）: $e');
          }
        } else {
          logger.info('CloudSync', '槽位一致，无需更新云端文件: $targetPath');
        }

        return ledgerId;
      });
    } catch (e, stack) {
      logger.error('CloudSync', '下载远程账本失败: $remotePath', e);
      logger.error('CloudSync', '堆栈', stack);

      // 审计 TSM-P10：本次新建且恢复未成功的账本行统一回收，
      // 避免解析/网络等任意失败路径残留空壳账本
      final orphanId = createdLedgerThisCall;
      if (orphanId != null) {
        try {
          await (db.delete(db.ledgers)..where((t) => t.id.equals(orphanId)))
              .go();
          logger.info('CloudSync', '已回收本次新建且恢复失败的空账本行: $orphanId');
        } catch (cleanupError) {
          logger.warning('CloudSync', '回收空账本行失败: $orphanId - $cleanupError');
        }
      }
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
      // m-04 契约澄清（同上）：适配器幂等吞 404，这里只防网关包装上抛
      if (e.toString().contains('404') || e.toString().contains('not found')) {
        logger.warning('CloudSync', '远程账本不存在（忽略）: $remotePath');
        return;
      }

      logger.error('CloudSync', '删除远程账本失败: $remotePath', e);
      rethrow;
    }
  }

  /// 恢复所有远程账本到本地
  ///
  /// W6/S6 补口：本入口内部的 [downloadRemoteLedger] 对同名/同身份账本
  /// 执行「清空+导入」的破坏性替换，与 [fullRestoreAllRemoteLedgers] /
  /// [downloadAndRestoreToCurrentLedger] 同属恢复临界区操作 —— 必须让
  /// 定时备份（app.dart BackupScheduler tick 检查 isBusy）让位，否则
  /// 批量恢复进行到一半时到点的备份会把半恢复态 DB 打包上传，覆盖当日
  /// 好备份。此前仅全量覆盖下载有守卫，本入口遗漏。
  ///
  /// 审计 L9：改为**串行**执行，与 [fullRestoreAllRemoteLedgers] 的注释
  /// 口径一致（"恢复会批量写库，并行易触发数据库锁竞争"）—— 此前两条
  /// 批量恢复路径一条并行一条串行，策略互相矛盾。
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

      // 审计 L9：串行恢复（对齐 fullRestoreAllRemoteLedgers 的锁竞争结论）
      var success = 0;
      var failed = 0;
      for (final file in ledgerFiles) {
        try {
          // 下载文件内容以获取账本信息（使用 file.name 而非 file.path）
          final raw = await provider.storage.download(path: file.name);
          if (raw == null) {
            logger.warning('CloudSync', '下载失败: ${file.name}');
            failed++;
            continue;
          }

          // H3 补漏：密文快照先解密再解析；无密钥/密文损坏计为该文件
          // 恢复失败，不再让 jsonDecode 报格式错误误导排查。
          final String jsonStr;
          try {
            jsonStr = await _decryptIfNeeded(raw);
          } on CloudEncryptedLocallyDisabledException {
            logger.warning('CloudSync', '远程账本 ${file.name} 为密文且本地无可用密钥');
            failed++;
            continue;
          } on CloudCiphertextUndecryptableException {
            logger.warning('CloudSync', '远程账本 ${file.name} 密文无法用本机密钥解密');
            failed++;
            continue;
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
            logger.info(
                'CloudSync', '恢复成功: ${file.name} -> ledgerId=$ledgerId');
            success++;
          } else {
            logger.warning('CloudSync', '恢复失败: ${file.name}');
            failed++;
          }
        } catch (e) {
          logger.warning('CloudSync', '恢复账本失败: ${file.name} - $e');
          failed++;
        }
      }

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
    return SyncRestoreGuard.run(
        () => _fullRestoreAllRemoteLedgers(onProgress: onProgress));
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
        final slotKey = _ledgerFileNamePattern.firstMatch(file.name)!.group(1)!;
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
    final bySyncId =
        await (db.select(db.ledgers)..where((l) => l.syncId.equals(key))).get();
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
  /// - 元信息两级来源，**先轻后重**：
  ///   1. 上传时随文件写入的 metadata（m-02：ledgerName / currency / count
  ///      等，[uploadCurrentLedger] 的 uploadMetadata）——一次 HEAD 请求
  ///      即可读取，不下载快照本体。账本页「远程账本」列表与启动检查
  ///      的发现阶段走这条快路径，多账本场景零全量下载。
  ///   2. metadata 缺失（槽位改版前的老文件 / 网关剥头）才回退下载快照
  ///      JSON 解析，并顺带缓存 payload 供 [importRemoteLedger] 复用。
  /// - 单个文件失败只跳过该账本（记日志），不影响其他
  /// - 返回的 meta 供确认弹窗展示
  Future<List<RemoteLedgerMeta>> discoverRemoteLedgers() async {
    await _ensureInitialized();

    // 捕获到局部变量（ATTACH-2 竞态防护）
    final provider = _provider;
    if (provider == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }
    // P0-1：发现轮计时
    final watch = Stopwatch()..start();

    _discoveredPayloads.clear();

    try {
      return await _discoverRemoteLedgersInner(provider);
    } catch (e) {
      _recordMetrics(SyncOpScenario.remoteDiscovery, SyncOpOutcome.failed,
          error: e, duration: watch.elapsed);
      rethrow;
    } finally {
      // 成功由 inner 出口记录；此处只兜异常路径（inner 正常 return
      // 不会经过这里 —— finally 无返回值,不吞 return）。
    }
  }

  Future<List<RemoteLedgerMeta>> _discoverRemoteLedgersInner(
      fcs.CloudProvider provider) async {
    final watch = Stopwatch()..start();
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

      // ---- 快路径：读上传时写入的 metadata（一次轻量请求，零下载）----
      // 单文件总预算 10s（M4 收口）：快路径超时/失败即跳过该文件本轮，
      // 不再落入慢路径下载。否则快路径 10s + 慢路径 10s = 单文件最多
      // 20s+，恰好击穿启动检查器对 discover 的整体 _statusTimeout(20s)，
      // 后续待发现的账本会被整体超时静默丢弃——复活 M4 修掉的
      // 「整体必超时 → 发现环节静默降级」老问题。慢路径只服务
      // 「metadata 确认缺失（老文件/网关剥头）」这一确定性场景。
      final mdDeadline = DateTime.now().add(const Duration(seconds: 10));
      Map<String, dynamic>? fastMeta;
      var fastPathFailed = false;
      try {
        final meta = await provider.storage
            .getMetadata(path: file.name)
            .timeout(const Duration(seconds: 10));
        fastMeta = meta?.metadata;
      } catch (e) {
        // metadata 读取失败（网络/权限/超时）：本轮跳过该文件，等下次
        // 发现重试（启动检查器/App 生命周期内会周期重跑）。不落入慢
        // 路径下载——快路径失败说明网络/权限状态不确定，再叠加 10s
        // 下载预算会让单文件最坏 20s+，击穿启动检查器整体预算。
        fastPathFailed = true;
        logger.warning('CloudSync', '发现账本 $slotKey 元数据读取失败，本轮跳过: $e');
      }
      if (fastPathFailed) continue;
      if (fastMeta != null) {
        final name = _metaValue(fastMeta, 'ledgerName');
        final currency = _metaValue(fastMeta, 'currency');
        final countStr = _metaValue(fastMeta, 'count');
        final balanceStr = _metaValue(fastMeta, 'balance');
        final uploadedAtStr = _metaValue(fastMeta, 'uploadedAt');
        if (name != null && name.isNotEmpty) {
          metas.add(RemoteLedgerMeta(
            slotKey: slotKey,
            name: name,
            currency: currency ?? 'CNY',
            // monthStartDay 在 metadata 里（与上传侧同批写入）；老文件
            // 未写该键时回退 1，导入阶段 payload 回写兜底真实值
            monthStartDay: (int.tryParse(
                        _metaValue(fastMeta, 'monthStartDay') ?? '') ??
                    1)
                .clamp(1, 28),
            txCount: int.tryParse(countStr ?? '') ?? 0,
            balance: double.tryParse(balanceStr ?? '') ?? 0,
            uploadedAt: DateTime.tryParse(uploadedAtStr ?? ''),
          ));
          continue;
        }
      }

      // ---- 慢路径：下载快照 JSON 提取元信息（老文件无 metadata）----
      // 只在快路径**确定性缺失**（读到 metadata 但无 ledgerName）时走，
      // 且受单文件总预算约束（剩余时间不足 2s 直接跳过，避免叠加超时）。
      final remaining = mdDeadline.difference(DateTime.now());
      if (remaining < const Duration(seconds: 2)) {
        logger.warning('CloudSync', '发现账本 $slotKey 剩余预算不足，跳过本轮');
        continue;
      }
      try {
        // M4：逐文件 10s 超时。此前依赖启动检查器的整体 _statusTimeout(20s)
        // 罩住「list + N 个文件全量下载」，云端有多个新账本（或单个大账本）
        // 时整体必超时 → 发现环节静默降级跳过。改为单文件限时后，慢文件
        // 只牺牲自己，其余账本仍可被发现。
        final raw = await provider.storage
            .download(path: file.name)
            .timeout(remaining);
        if (raw == null) {
          logger.warning('CloudSync', '发现账本 $slotKey 下载返回空，跳过');
          continue;
        }
        // 密文场景：provider 已装饰时 download 即明文；未装饰（本地未开
        // 加密）或密文不可解密（SYNC-10）时 _decryptIfNeeded 抛专属异常
        final jsonStr = await _decryptIfNeeded(raw);
        final payload = jsonDecode(jsonStr) as Map<String, dynamic>;
        _discoveredPayloads[slotKey] = jsonStr;
        // 余额合计从 items 内存累加（与上传 metadata 写入口径一致）
        double balance = 0;
        final items = payload['items'];
        if (items is List) {
          for (final it in items) {
            if (it is! Map) continue;
            final type = it['type'];
            final amount = ((it['nativeAmount'] as num?) ?? (it['amount'] as num?))?.toDouble();
            if (amount == null) continue;
            if (type == 'income') {
              balance += amount;
            } else if (type == 'expense') {
              balance -= amount;
            }
          }
        }
        metas.add(RemoteLedgerMeta(
          slotKey: slotKey,
          name: (payload['ledgerName'] as String?) ?? '云端账本 $slotKey',
          currency: (payload['currency'] as String?) ?? 'CNY',
          monthStartDay:
              ((payload['monthStartDay'] as num?)?.toInt() ?? 1).clamp(1, 28),
          txCount: (payload['count'] as num?)?.toInt() ?? 0,
          balance: balance,
          uploadedAt:
              DateTime.tryParse((payload['exportedAt'] as String?) ?? ''),
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
    _recordMetrics(SyncOpScenario.remoteDiscovery, SyncOpOutcome.success,
        duration: watch.elapsed);
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
    try {
      return await _importRemoteLedgerInner(meta);
    } catch (e) {
      // P0-1：导入失败计入指标（成功/竞态守卫跳过在 inner 出口记录）
      _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.failed,
          error: e);
      rethrow;
    }
  }

  Future<int?> _importRemoteLedgerInner(RemoteLedgerMeta meta) async {
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
    final int? newLedgerId;
    try {
      newLedgerId = await db.transaction(() async {
        // 竞态守卫：发现与导入之间本地可能已导入同身份账本
        final existing = await _localLedgerForSlotKey(meta.slotKey);
        if (existing != null) {
          logger.warning('CloudSync', '账本 syncId=${meta.slotKey} 已被本地占用，跳过导入');
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
        final result = await importTransactionsJson(repo, newId, payload,
            recordChanges: false);
        importSkippedRecurring = result.skippedRecurring;
        inserted = result.inserted;
        return newId;
      });
    } finally {
      // 无论导入成功、竞态守卫命中还是事务异常，都释放发现阶段的
      // payload 缓存——事务回滚后残留的缓存对应的是一份导入失败的
      // 快照，下次导入必须重新拉云端（保证拿到最新内容）。
      _discoveredPayloads.remove(meta.slotKey);
    }

    if (newLedgerId == null) return null;

    // P2-1：云端账本导入（recordChanges:false）不写 local_changes、
    // guard 校验位不变，显式失效新账本的指纹缓存
    invalidateLocalFingerprintCache(ledgerId: newLedgerId);

    logger.info('CloudSync',
        '云端账本导入完成: localId=$newLedgerId, slotKey=${meta.slotKey}, name=${meta.name}, inserted=$inserted, skippedRecurring=$importSkippedRecurring');
    // P0-1：云端账本导入按恢复场景计数（属启动检查链路的破坏性单元）
    _recordMetrics(SyncOpScenario.snapshotRestore, SyncOpOutcome.success,
        ledgerId: newLedgerId);
    if (importSkippedRecurring > 0) {
      logger.warning(
          'CloudSync', '导入时有 $importSkippedRecurring 笔同日周期实例被判重跳过，请核对源端明细');
    }

    // 附件二进制后台补齐(与下载恢复路径同款:不阻塞导入返回)
    unawaited(enqueueMissingAttachmentJobs(newLedgerId)
        .then((_) => drainAttachmentJobs()));
    return inserted;
  }
}

/// 单个附件对象下载结果（审计 TSM-P2 三态）。
enum _AttachmentDownloadOutcome {
  /// 下载并校验成功，已落盘
  ok,

  /// 云端确认无此对象（上传端源文件缺失/上传失败）——回队也永远拉不到，
  /// 不再重试
  objectMissing,

  /// 瞬态故障（网络/校验失败等），回队等下次 drain
  transientFailure,
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

/// 云端账本元信息（发现阶段从 `ledger_<slotKey>.json` metadata 或 payload 提取）
class RemoteLedgerMeta {
  /// 云端槽位 key（= 源端账本 syncId；legacy 数字命名文件为 id 字符串）。
  /// 导入侧以它作为新账本行的 syncId，保证跨设备身份稳定。
  final String slotKey;
  final String name;
  final String currency;
  final int monthStartDay;
  final int txCount;

  /// 余额合计（income 加 / expense 减 / transfer 不计）。来自上传 metadata
  /// 或快照 items 内存累加，仅供「远程账本」卡片展示，不参与导入。
  final double balance;

  /// 云端快照的上传时间（快路径读 metadata uploadedAt / 慢路径读 payload
  /// exportedAt；缺键为 null）。展示层用它替代本地时钟当"最近更新"。
  final DateTime? uploadedAt;

  const RemoteLedgerMeta({
    required this.slotKey,
    required this.name,
    required this.currency,
    required this.monthStartDay,
    required this.txCount,
    this.balance = 0,
    this.uploadedAt,
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
      DateTime.now().difference(cachedAt) >
      TransactionsSyncManager._statusCacheTtl;
}

/// 审计 T9：附件 localSha256 按需回填（attachment_binary_sync）。
///
/// v34 只加列不回填，存量行靠启动后台任务（AttachmentService.backfillLocalSha256）
/// 补齐 —— 任务完成前的快照上传会把 NULL 锚点行整体排除在内容寻址清单外。
/// 本函数在构建清单前对 NULL 行就地补算：文件可读 → 算 sha256 并经
/// [onResolved] 落库；文件缺失的孤儿行保持 NULL（本就不可上传），留给
/// 启动任务下次再试。失败逐行容忍，绝不阻断上传主流程。
///
/// 顶层函数便于单元测试直接注入内存库与临时目录。
@visibleForTesting
Future<int> backfillAttachmentSha256({
  required PiggyDatabase db,
  required Future<void> Function(int attachmentId, String sha256) onResolved,
  required List<int> txIds,
  required Directory attachmentsDir,
}) async {
  if (txIds.isEmpty) return 0;
  final pending = await (db.select(db.transactionAttachments)
        ..where((a) => a.transactionId.isIn(txIds) & a.localSha256.isNull()))
      .get();
  if (pending.isEmpty) return 0;

  var filled = 0;
  for (final a in pending) {
    try {
      final f = File('${attachmentsDir.path}/${a.fileName}');
      if (!await f.exists()) continue;
      final digest = crypto.sha256.convert(await f.readAsBytes()).toString();
      await onResolved(a.id, digest);
      filled++;
    } catch (e) {
      // 单行失败不阻断其余行，也不阻断上传
      continue;
    }
  }
  return filled;
}
