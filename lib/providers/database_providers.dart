import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_health_service.dart';
import '../data/db.dart';
import '../data/repositories/local/local_repository.dart';
import '../data/repositories/base_repository.dart';
import '../services/system/logger_service.dart';
import '../utils/shared_ledger_picker_filter.dart';
import 'sync_providers.dart';

// 数据库Provider
final databaseProvider = Provider<PiggyDatabase>((ref) {
  final db = PiggyDatabase();
  ref.onDispose(() => db.close());
  return db;
});

/// 本地库健康状态（审计 P1-6）。
///
/// 刻意**不**挂进 main() 的启动并行链：探测器要扫页，挂进 Future.wait 会把
/// 它变成 runApp 前的关键路径、拖慢每一次冷启动。改为由 UI 首帧惰性订阅触发，
/// 全程在 runApp 之后，对正常启动零成本。
final dbHealthProvider = FutureProvider<DbHealthResult>((ref) {
  return DatabaseHealthService.check();
});

/// 「忽略损坏提示」的会话态开关：用户点「稍后处理」后本次运行不再弹，
/// 但不持久化——下次启动仍会提示，避免损坏被永久静默。
final dbHealthDismissedProvider = StateProvider<bool>((ref) => false);

// 仓储Provider — 一律 LocalRepository(本地优先)。ChangeTracker(增量变更
// 推送)随 PiggyCount Cloud 云端协同下线移除;快照备份路径(iCloud / WebDAV /
// S3 / Supabase)不注入 tracker。
//
// ⚠️ 推论(CT-1,2026-09-21 已处置):本行「不注入 tracker」意味着 local_changes
// 生产恒空 —— 凡读该表的下游都会静默失效。TransactionsSyncManager 的两处读端
// 已分别改造:① 指纹缓存校验位改用业务表代际(_contentGenerationGuard);
// ② 方向仲裁证据改用 v40 updated_at 触碰列 + 同机上传锚点(_localChangeEvidence)。
// 新增读 local_changes 的代码前请先确认该表在生产是否仍有写入方。
final repositoryProvider = Provider<BaseRepository>((ref) {
  final db = ref.watch(databaseProvider);
  logger.info('RepositoryProvider', '✅ LocalRepository');
  return LocalRepository(db);
});

// 记住当前账本：启动时加载，切换时持久化
final currentLedgerIdProvider = StateProvider<int>((ref) => 1);

// 获取当前账本的详细信息。
// StreamProvider:sync pull / 本地编辑改了 ledger 行(如 monthStartDay)会自动
// 重建 watcher,B 端改设置 A 端自动刷新,无需手动 invalidate。
final currentLedgerProvider = StreamProvider<Ledger?>((ref) {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.watchLedger(ledgerId);
});

/// 当前账本的每月起始日(1-28);未加载完成时按 1(自然月)兜底。
final currentMonthStartDayProvider = Provider<int>((ref) {
  final ledger = ref.watch(currentLedgerProvider).value;
  return (ledger?.monthStartDay ?? 1).clamp(1, 28);
});

// 获取指定账本的详细信息
final ledgerByIdProvider = FutureProvider.family<Ledger?, int>((ref, ledgerId) async {
  final repo = ref.watch(repositoryProvider);

  return await repo.getLedgerById(ledgerId);
});

// 获取所有账本列表（Stream版本）
final ledgersStreamProvider = StreamProvider<List<Ledger>>((ref) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchLedgers();
});

final _currentLedgerPersist = Provider<void>((ref) {
  // load on first read
  () async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getInt('current_ledger_id');
      final st = ref.read(currentLedgerIdProvider);
      var target = saved ?? st;
      // 采纳前校验该账本仍存在。
      //
      // `current_ledger_id` 是纯 prefs 状态，账本行却可能早已消失：账本被
      // 其它设备删除后同步下来、本机恢复到他人的备份、清库后重建（自增 id
      // 继续增长，新账本不再叫 1/7）。原实现原样采纳 —— currentLedgerProvider
      // 因此永远解析不出账本，首页退化成「新建账本」空态、我的页同步状态行
      // 显示「状态获取失败」、云同步页在状态查询里长时间不可交互
      // （2026-10-02 真机双后端测试实测）。这里回落到本机最小的真实账本 id
      // 自愈，且只写回 `current_ledger_id` 这一个值（键集合不变）。
      final repo = ref.read(repositoryProvider);
      if (await repo.getLedgerById(target) == null) {
        final ledgers = await repo.getAllLedgers();
        if (ledgers.isEmpty) {
          // 本机一个账本都没有：欢迎页流程重建前，或唯一账本被对端删除后
          // 合并下来。**必须**把悬空 id 归零 —— UI 侧的「无账本」守卫一律
          // 判 `currentLedgerId == 0`（cloud_sync_page.dart:635、
          // share_poster_service.dart 四处、analytics_page.dart:576、
          // transactions_sync_manager.dart:2558）。留着悬空值会绕过全部守卫：
          // 实测云同步页会直接抛出裸的 `Exception: 账本 9 不存在`
          // （20261004 S3/WebDAV 双后端回归，见 docs/test/ 报告 6.5）。
          logger.warning('LedgerState',
              'current_ledger_id=$target 已不存在且本机暂无账本，归零为无账本态，等待欢迎页流程重建');
          target = 0;
        } else {
          final fallback =
              ledgers.map((l) => l.id).reduce((a, b) => a < b ? a : b);
          logger.warning('LedgerState',
              'current_ledger_id=$target 指向的账本已不存在，回落到账本 $fallback');
          target = fallback;
        }
      }
      if (st != target) {
        ref.read(currentLedgerIdProvider.notifier).state = target;
      }
    } catch (e) {
      logger.warning('LedgerState', '恢复上次选中账本失败，回退默认账本', e);
    }
  }();
  // persist on change
  ref.listen<int>(currentLedgerIdProvider, (prev, next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('current_ledger_id', next);
    } catch (e) {
      logger.warning('LedgerState', '持久化当前账本 ID 失败，下次启动将回退默认', e);
    }
  });
});

// 当账本切换时，顺便触发一次设置页状态刷新（确保"我的"页及时反映）
final _ledgerChangeListener = Provider<void>((ref) {
  // 激活持久化监听
  ref.read(_currentLedgerPersist);
  ref.listen<int>(currentLedgerIdProvider, (prev, next) {
    ref.read(syncStatusRefreshProvider.notifier).state++;
  });
});

// 确保监听器被激活
final appInitProvider = FutureProvider<void>((ref) async {
  // 读取以激活监听
  ref.read(_ledgerChangeListener);
});

// 分类Provider
final categoriesProvider = FutureProvider<List<Category>>((ref) async {
  // 同步代数 bump 后重算，让 web 改分类能立即反映到 mobile。
  ref.watch(syncGenerationProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getAllCategories();
});

// 分类与交易笔数组合Provider（响应式版本）
// 使用 autoDispose 在页面关闭时自动取消订阅
final categoriesWithCountProvider = StreamProvider.autoDispose<List<({Category category, int transactionCount})>>((ref) {
  final repo = ref.watch(repositoryProvider);
  // §7 决策 v25:Owner 资源不再 mirror 主表,管理页直接读主 Categories
  // 自然只看到用户自己 user-global 行,无需过滤。
  return repo.watchCategoriesWithCount();
});

// 虚拟转账分类Provider（全局缓存，用于获取转账图标）
final transferCategoryProvider = FutureProvider<Category>((ref) async {
  final repo = ref.watch(repositoryProvider);
  return await repo.getTransferCategory();
});

// 重复交易Provider（按账本过滤）
// 注意：此 provider 已废弃，请使用 allRecurringTransactionsProvider 并在业务层过滤
final recurringTransactionsProvider = FutureProvider.family<List<RecurringTransaction>, int>((ref, ledgerId) async {
  final repo = ref.watch(repositoryProvider);
  final all = await repo.watchRecurringTransactionsByLedger(ledgerId).first;
  return all;
});

// 所有重复交易Provider（不限账本）
final allRecurringTransactionsProvider = StreamProvider.autoDispose<List<RecurringTransaction>>((ref) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchAllRecurringTransactions();
});

// 账户Provider（按账本过滤）
final accountsStreamProvider = StreamProvider.family<List<Account>, int>((ref, ledgerId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchAccountsForLedger(ledgerId);
});

// v1.15.0: 所有账户Provider（不限账本）
final allAccountsStreamProvider = StreamProvider<List<Account>>((ref) {
  final repo = ref.watch(repositoryProvider);
  logger.info('AllAccountsStream', '使用的 Repository 类型: ${repo.runtimeType}');
  final stream = repo.watchAllAccounts();
  return stream;
});

// §7 v25:tx 反查账户 — 综合考虑 accountId int + accountSyncIdOverride。
// Editor 在共享账本下记的 tx,accountId 是 null,override 是 Owner's syncId,
// 走 SharedLedgerAccounts 表反查 → 转 synthetic Account 返回。
final accountForTxProvider =
    FutureProvider.family<Account?, ({int? accountId, String? syncIdOverride})>(
        (ref, key) async {
  ref.watch(syncGenerationProvider);
  // §7 共享账本:WS shared_resource_change 推送时也强制重算,跟 picker /
  // 洞察 等其它 widget 监听同一个 tick 一致;否则共享账户改名 tx 列表
  // 不刷新。
  ref.watch(sharedResourceRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  if (key.accountId != null && key.accountId! >= 0) {
    return await repo.getAccount(key.accountId!);
  }
  final ov = key.syncIdOverride;
  if (ov == null || ov.isEmpty) return null;
  final shared = await repo.getSharedAccountBySyncId(ov);
  if (shared == null) return null;
  return Account(
    // 用 syntheticIdForSyncId 而不是 -1 — 跟 picker / 详情页路径统一,
    // 避免不同 syncId 全部撞到同一个 id。
    id: syntheticIdForSyncId(shared.syncId),
    ledgerId: 0,
    name: shared.name,
    type: shared.accountType,
    currency: shared.currency,
    initialBalance: shared.initialBalance ?? 0.0,
    createdAt: null,
    updatedAt: null,
    sortOrder: 0,
    creditLimit: shared.creditLimit,
    billingDay: shared.billingDay,
    paymentDueDay: shared.paymentDueDay,
    bankName: shared.bankName,
    cardLastFour: shared.cardLastFour,
    note: shared.note,
    syncId: shared.syncId,
    // SharedLedgerAccounts 镜像表没有 hidden 概念(隐藏是 Owner 侧个人状态,
    // 不随共享账本镜像同步),synthetic 账户固定按「未隐藏」处理。
    hidden: false,
  );
});

// 获取单个账户信息
final accountByIdProvider = FutureProvider.family<Account?, int>((ref, accountId) async {
  ref.watch(syncGenerationProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getAccount(accountId);
});