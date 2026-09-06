import 'dart:async';

import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../cloud/provider_factory.dart';
import '../cloud/sync_service.dart';
import '../cloud/transactions_sync_manager.dart';
import '../models/ledger_display_item.dart';
import '../services/system/logger_service.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';
import 'encryption_providers.dart';

/// 共享资源(分类/账户/标签)变更刷新信号。
///
/// 历史上由 PiggyCount Cloud 的 WS shared_resource_change 推送时 bump;
/// 云端协同下线后无生产者,但 picker / 洞察等 15+ 处 widget 仍 watch 它,
/// 保留定义以维持「无推送 = 不刷新」的现状语义。
final sharedResourceRefreshProvider = StateProvider<int>((ref) => 0);

// 同步状态（根据 ledgerId 与刷新 tick 缓存），避免因 UI 重建重复拉取
final syncStatusProvider =
    FutureProvider.family<SyncStatus, int>((ref, ledgerId) async {
  final sync = ref.watch(syncServiceProvider);
  // 依赖 tick，使得手动刷新时重新获取；否则保持缓存
  ref.watch(syncStatusRefreshProvider);
  ref.watch(syncStatusRefreshByLedgerProvider(ledgerId));

  final status = await sync.getStatus(ledgerId: ledgerId);

  // 写入最近一次成功值，供 UI 在刷新期间显示旧值，避免闪烁
  ref.read(lastSyncStatusProvider(ledgerId).notifier).state = status;
  return status;
});

// 最近一次同步状态缓存（按 ledgerId）
final lastSyncStatusProvider =
    StateProvider.family<SyncStatus?, int>((ref, ledgerId) => null);

/// 同步代数计数器：每次 pull 把远端变更写入本地 Drift 之后 +1。
/// 派生 Provider（首页交易列表/统计/账户等）watch 这个值，即可在增量同步
/// 完成后重新运行，UI 不再读到旧缓存。
///
/// 为什么不直接 `ref.invalidate(watchTransactionsProvider)`：stream provider
/// 重建有额外开销，且派生链上的其他 watcher 也会被连带打断；用一个独立
/// bump 计数器是最便宜的信号。
final syncGenerationProvider = StateProvider<int>((ref) => 0);

/// 最近一次同步错误信息（供 UI 状态栏展示）。
/// PostProcessor / SyncEngine 的 catch 分支把错误写到这里，避免 silent swallow。
final lastSyncErrorProvider = StateProvider<String?>((ref) => null);

// 自动同步开关：值与设置
final autoSyncValueProvider = FutureProvider.autoDispose<bool>((ref) async {
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('auto_sync') ?? false;
});

class AutoSyncSetter {
  AutoSyncSetter(this._ref);
  final Ref _ref;
  Future<void> set(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('auto_sync', v);
    // 使缓存失效，触发读取最新值
    _ref.invalidate(autoSyncValueProvider);
  }
}

final autoSyncSetterProvider = Provider<AutoSyncSetter>((ref) {
  return AutoSyncSetter(ref);
});

// ====== 云服务配置 ======

final cloudServiceStoreProvider =
    Provider<CloudServiceStore>((_) => CloudServiceStore());

/// M11：激活配置解析失败的呈现状态（null = 正常）。
/// 配置损坏时 loadActive 静默回退 LocalOnly，这里把包侧记录的
/// 结构化错误转成 UI 可监听的状态，由云同步页 banner 提示用户重新配置。
final cloudConfigCorruptionProvider =
    StateProvider<({String backend, String message})?>((_) => null);

// 当前激活配置（Future，因需读 SharedPreferences）
//
// 审计 M16：loadActive 因安全存储读失败显式上抛时，这里先复用损坏
// banner 把失败呈现给用户，再原样上抛——同步链路（syncServiceProvider /
// authServiceProvider 对 !hasValue 降级 LocalOnly）与 .future 消费点必须
// 感知失败，不允许伪装成「用户切回了本地模式」无声停摆。
final activeCloudConfigProvider =
    FutureProvider<CloudServiceConfig>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  final CloudServiceConfig cfg;
  try {
    cfg = await store.loadActive();
  } catch (e) {
    ref.read(cloudConfigCorruptionProvider.notifier).state = (
      backend: CloudServiceStore.lastLoadErrorBackend ?? 'secure_storage',
      message: CloudServiceStore.lastLoadErrorMessage ?? e.toString(),
    );
    rethrow;
  }
  final errBackend = CloudServiceStore.lastLoadErrorBackend;
  ref.read(cloudConfigCorruptionProvider.notifier).state =
      errBackend == null
          ? null
          : (
              backend: errBackend,
              message: CloudServiceStore.lastLoadErrorMessage ?? ''
            );
  return cfg;
});

// Supabase配置(不管是否激活)
final supabaseConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadSupabase();
});

// WebDAV配置(不管是否激活)
final webdavConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadWebdav();
});

// S3配置(不管是否激活)
final s3ConfigProvider = FutureProvider<CloudServiceConfig?>((ref) async {
  final store = ref.watch(cloudServiceStoreProvider);
  return store.loadS3();
});

final authServiceProvider = FutureProvider<CloudAuthService>((ref) async {
  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) {
    return NoopAuthService();
  }

  final config = activeAsync.value!;
  if (!config.valid || config.type == CloudBackendType.local) {
    return NoopAuthService();
  }

  try {
    final services = await createCloudServices(config);
    if (services.auth != null) {
      return services.auth!;
    }
  } catch (e, st) {
    logger.warning('CloudSync', 'Cloud services initialization failed: $e', st);
  }

  return NoopAuthService();
});

// 按 config.id 跟踪正在执行的 bootstrap，避免全局锁跨 Provider 重建互相阻塞。
// 不同 config 的 bootstrap 互不影响；同 config 重建时跳过重复触发。
final _bootstrappingConfigs = <String>{};

final syncServiceProvider = Provider<SyncService>((ref) {
  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) return LocalOnlySyncService();

  final config = activeAsync.value!;
  if (!config.valid || config.type == CloudBackendType.local) {
    return LocalOnlySyncService();
  }

  // 所有云后端 → TransactionsSyncManager（快照同步）
  // 注入 EncryptionService 用于 E2EE（_initialize 内会按需包装 CloudProvider）
  final db = ref.watch(databaseProvider);
  final repo = ref.watch(repositoryProvider);
  final encryptionService = ref.watch(encryptionServiceProvider);

  // §X 兜底:Drift table-watch。快照同步的
  // 下载/恢复/导入都走 dataImportService.importTransactions 批量写表,不在
  // 任何交易 CRUD 钩子覆盖范围内;且此分支没有 PullCompleted 事件 → 同步
  // 完成后明细(TransactionList 的 stream 自动推送)是新的,但依赖
  // statsRefreshProvider 的月合计 / 日合计卡片 / 洞察统计不刷新,表现为
  // 「明细新、合计旧」。这里监听 transactions 表变更,任何来源的写入都
  // 主动 bump statsRefreshProvider。
  StreamSubscription<void>? txTableSub2;
  try {
    txTableSub2 = db
        .tableUpdates(d.TableUpdateQuery.onTable(db.transactions))
        .listen((_) {
      ref.read(statsRefreshProvider.notifier).state++;
    });
  } catch (e, st) {
    // db 在极少数时序下可能未就绪;不影响主流程,记日志即可。
    logger.warning(
      'SyncProvider',
      'transactions table-watch 启动失败: $e',
      st,
    );
  }
  ref.onDispose(() => txTableSub2?.cancel());

  final manager = TransactionsSyncManager(
    config: config,
    db: db,
    repo: repo,
    encryptionService: encryptionService,
  );
  // F5：provider 重建（切云配置/依赖变更）时释放旧实例的 HTTP 连接池，
  // 否则 WebDAV dio / S3 http.Client 随每次重建泄漏
  ref.onDispose(() => unawaited(manager.dispose()));
  return manager;
});

// 用于触发设置页同步状态的刷新（每次 +1 即可触发 FutureBuilder 重新获取）
final syncStatusRefreshProvider = StateProvider<int>((ref) => 0);

/// 按账本触发同步状态刷新（用于远端增量拉取后的局部刷新）
final syncStatusRefreshByLedgerProvider =
    StateProvider.family<int, int>((ref, _) => 0);

/// 按账本触发页面数据刷新（减少全局刷新带来的闪烁）
final ledgerDataRefreshByLedgerProvider =
    StateProvider.family<int, int>((ref, _) => 0);

/// 按账本记录"远端变更应用中"状态，用于页面局部防闪渲染
final remoteApplyInProgressByLedgerProvider =
    StateProvider.family<bool, int>((ref, _) => false);

// ====== 账本同步相关 ======

/// 刷新账本列表的触发器
final ledgerListRefreshProvider = StateProvider<int>((ref) => 0);

/// 当前正在上传的账本ID集合
final uploadingLedgerIdsProvider = StateProvider<Set<int>>((ref) => {});

/// 快照同步（TransactionsSyncManager）上传完成信号。
///
/// 每次 [TransactionsSyncManager.uploadCurrentLedger] 成功 +1，供 UI
/// `ref.listen` 弹出「已同步」toast。
final snapshotSyncCompletedProvider = StateProvider<int>((ref) => 0);

/// 本地账本列表（快速，仅本地）
final localLedgersProvider =
    FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器（账本列表和统计信息）
  ref.watch(ledgerListRefreshProvider);
  ref.watch(statsRefreshProvider); // 监听统计刷新，确保自动记账后刷新

  try {
    final repo = ref.watch(repositoryProvider);

    final localLedgers = await repo.getAllLedgers();
    // 一条 GROUP BY 聚合取全部账本统计。此前逐账本 getLedgerStats 是
    // N+1（N 个账本 N 次查询，且旧实现每次全量加载该账本交易行）。
    final statsMap = await repo.getAllLedgerStats();

    final result = <LedgerDisplayItem>[];
    for (final ledger in localLedgers) {
      final stats = statsMap[ledger.id] ??
          (balance: 0.0, transactionCount: 0);

      result.add(LedgerDisplayItem.fromLocal(
        id: ledger.id,
        name: ledger.name,
        currency: ledger.currency,
        createdAt: ledger.createdAt,
        transactionCount: stats.transactionCount,
        balance: stats.balance,
        isShared: ledger.isShared,
        memberCount: ledger.memberCount,
        myRole: ledger.myRole,
      ));
    }

    return result;
  } catch (e, stackTrace) {
    logger.error('LocalLedgers', '获取本地账本列表失败', e, stackTrace);
    return [];
  }
});

/// 远程账本列表（快照同步类后端：S3/WebDAV/Supabase/iCloud）。
///
/// 列云端根目录下的 ledger_*.json 文件,过滤掉本地已有对应身份(syncId)
/// 的账本,只把「纯远程」的账本展示在账本页的远程区,供用户手动恢复。
/// 基于通用 CloudStorageService 接口,覆盖全部快照后端。
final remoteLedgersProvider =
    FutureProvider<List<LedgerDisplayItem>>((ref) async {
  ref.watch(ledgerListRefreshProvider);

  final activeAsync = ref.watch(activeCloudConfigProvider);
  if (!activeAsync.hasValue) return const [];
  final config = activeAsync.value!;
  if (!config.valid || config.type == CloudBackendType.local) {
    return const [];
  }

  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) return const [];

  try {
    final remote = await sync.listRemoteLedgerFiles();
    if (remote.isEmpty) return const [];

    // 本地已有的 syncId 集合,过滤掉"已下载过"的账本
    final repo = ref.read(repositoryProvider);
    final localLedgers = await repo.getAllLedgers();
    final localSyncIds = <String>{
      for (final l in localLedgers)
        if (l.syncId != null && l.syncId!.isNotEmpty) l.syncId!,
    };

    final out = <LedgerDisplayItem>[];
    for (final item in remote) {
      final slotKey = item.slotKey;
      if (localSyncIds.contains(slotKey)) continue;
      out.add(LedgerDisplayItem.fromRemote(
        remoteSyncId: item.slotKey,
        name: item.name.isEmpty ? '(unnamed)' : item.name,
        currency: item.currency,
        updatedAt: item.updatedAt ?? DateTime.now(),
        transactionCount: item.transactionCount,
        balance: item.incomeTotal - item.expenseTotal,
      ));
    }
    return out;
  } catch (e, st) {
    logger.warning('SyncProvider', 'remoteLedgersProvider: 列远程账本失败: $e', st);
    return const [];
  }
});

/// 账本列表（带刷新支持）- 兼容旧代码
final allLedgersProvider = FutureProvider<List<LedgerDisplayItem>>((ref) async {
  // 监听刷新触发器
  ref.watch(ledgerListRefreshProvider);

  try {
    final repo = ref.watch(repositoryProvider);
    final localLedgers = await repo.getAllLedgers();
    // 同 localLedgersProvider：单条聚合 SQL 代替逐账本 N+1 查询
    final statsMap = await repo.getAllLedgerStats();

    final result = <LedgerDisplayItem>[];
    for (final ledger in localLedgers) {
      final stats = statsMap[ledger.id] ??
          (balance: 0.0, transactionCount: 0);

      result.add(LedgerDisplayItem.fromLocal(
        id: ledger.id,
        name: ledger.name,
        currency: ledger.currency,
        createdAt: ledger.createdAt,
        transactionCount: stats.transactionCount,
        balance: stats.balance,
        isShared: ledger.isShared,
        memberCount: ledger.memberCount,
        myRole: ledger.myRole,
      ));
    }

    return result;
  } catch (e, stackTrace) {
    logger.error('AllLedgers', '获取账本列表失败', e, stackTrace);
    return [];
  }
});
