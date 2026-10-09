import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database_health_service.dart';
import '../data/db.dart';
import '../data/repositories/local/local_repository.dart';
import '../data/repositories/base_repository.dart';
import '../services/system/logger_service.dart';
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

/// 账本态解析（纯函数）：返回应当生效的 `current_ledger_id`。
///
/// **启动采纳**与**响应式校正**共用这一个判据 —— 两条路径各写一套回落规则
/// 迟早在边界上分叉（谁先写完谁定），这里只允许有一种语义：
/// - [candidate] 是本机确实存在的账本 id → 原样返回（用户当前的选择优先）；
/// - 悬空（0 / 已被删 / 对端删除后合并下来 / 恢复后 id 变化）→ 回落
///   到**最小真实 id**（与冷启动自愈同口径，用户至少有个可用的账本）；
/// - 本机一个账本都没有 → 归零。
int resolveCurrentLedgerId({
  required int candidate,
  required List<Ledger> ledgers,
}) {
  if (ledgers.any((l) => l.id == candidate)) return candidate;
  if (ledgers.isEmpty) return 0;
  return ledgers.map((l) => l.id).reduce((a, b) => a < b ? a : b);
}

/// 写入解析结果 —— 只在真的变化时写，避免下游 watch(currentLedgerIdProvider)
/// 无谓重建（首页/统计/同步状态都是它的下游）。
///
/// 自带 try/catch：调用点都在异步回调里（启动采纳 / 微任务校正），容器可能
/// 已被销毁（页面或测试收尾）—— 那时的写入既无意义也不该冒泡成未捕获异常。
void _applyCurrentLedgerId(Ref ref, int target) {
  try {
    if (ref.read(currentLedgerIdProvider) == target) return;
    ref.read(currentLedgerIdProvider.notifier).state = target;
  } catch (e) {
    logger.warning('LedgerState', '写入当前账本 ID 失败（忽略）: $target - $e');
  }
}

/// 启动期采纳：prefs 里上次选中的账本优先于 provider 默认值。
///
/// 只在 [appInitProvider] 里 await 一次，**不**并入响应式校正：那个 provider
/// 会随每次账本列表变化重建，而 prefs 的写回本身是异步的（持久化监听）——
/// 重建瞬间可能读到尚未更新的旧值，把用户刚切到的账本又改回去。
///
/// `current_ledger_id` 是纯 prefs 状态，账本行却可能早已消失：账本被其它设备
/// 删除后同步下来、本机恢复到他人的备份、清库后重建（自增 id 继续增长，新账本
/// 不再叫 1/7）。原实现原样采纳 —— currentLedgerProvider 因此永远解析不出账本，
/// 首页退化成「新建账本」空态、我的页同步状态行显示「状态获取失败」、云同步页
/// 在状态查询里长时间不可交互（2026-10-02 真机双后端测试实测）。这里回落到本机
/// 最小的真实账本 id 自愈，且只写回 `current_ledger_id` 这一个值（键集合不变）。
Future<void> _adoptSavedLedgerId(Ref ref) async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getInt('current_ledger_id');
    if (saved == null || saved <= 0) return;
    final current = ref.read(currentLedgerIdProvider);
    if (current == saved) return;
    // 单次查询同时回答「saved 是否还存在」与「回落候选是谁」两件事
    // （旧实现是 getLedgerById + getAllLedgers 两次往返）。
    final ledgers = await ref.read(repositoryProvider).getAllLedgers();
    final target = resolveCurrentLedgerId(candidate: saved, ledgers: ledgers);
    if (target == current) return;
    // target == saved 是正常采纳（prefs 里的账本还在），不打日志以免每次冷启动
    // 都刷一行；其余都是「saved 已消失」的回落，必须留痕迹。
    if (target != saved) {
      if (ledgers.isEmpty) {
        // 本机一个账本都没有：欢迎页流程重建前，或唯一账本被对端删除后
        // 合并下来。**必须**把悬空 id 归零 —— UI 侧的「无账本」守卫一律
        // 判 `currentLedgerId == 0`（cloud_sync_page.dart:667、
        // share_poster_service.dart 四处、analytics_page.dart:576、
        // transactions_sync_manager.dart:2558）。留着悬空值会绕过全部守卫：
        // 实测云同步页会直接抛出裸的 `Exception: 账本 9 不存在`
        // （20261004 S3/WebDAV 双后端回归，见 docs/test/ 报告 6.5）。
        logger.warning('LedgerState',
            'current_ledger_id=$saved 已不存在且本机暂无账本，归零为无账本态');
      } else {
        logger.warning('LedgerState',
            'current_ledger_id=$saved 指向的账本已不存在，回落到账本 $target');
      }
    }
    _applyCurrentLedgerId(ref, target);
  } catch (e) {
    logger.warning('LedgerState', '恢复上次选中账本失败，回退默认账本', e);
  }
}

/// 账本列表变化 → 校正当前账本（同会话收敛，订阅见 [_ledgerChangeListener]）。
///
/// 为什么不能只在启动跑一次（原实现）：`current_ledger_id` 是纯 prefs 状态，
/// 账本行却可能在**同一次会话内**变化 —— 启动检查的「发现云端账本 → 下载」会
/// 新建账本行、删账本会让 id 悬空、对端删除后合并下来亦然。旧实现在 App 初始化
/// （splash → [appInitProvider]）校正一次就再也不管，这些新状态要等下次冷启动
/// 才收敛：实测新装设备（库内零账本）走完「发现云端账本 → 下载」后
/// `currentLedgerId` 仍是 0，云同步页继续显示「未找到账本」，而启动检查的提示
/// 偏偏让人去那里手动同步 —— 死路。
///
/// 为什么盯账本列表、而不是在导入/删除处逐个补写：写账本行的入口太多（启动检查
/// 导入云端账本、账本页「远程账本」卡片下载、全量下载、备份恢复、配置导入、对端
/// 删除后合并落库、删账本……），逐个补写必漏；账本表是唯一真相源。
///
/// [ledgers] 为 null（流未就绪/出错）时不猜 —— 拿不到账本列表就什么都不做。
void _correctCurrentLedger(Ref ref, List<Ledger>? ledgers) {
  if (ledgers == null) return;
  final current = ref.read(currentLedgerIdProvider);
  final target = resolveCurrentLedgerId(candidate: current, ledgers: ledgers);
  if (target == current) return;
  if (ledgers.isEmpty) {
    logger.warning('LedgerState',
        '本机已无账本，current_ledger_id=$current 归零为无账本态（同会话，无需重启）');
  } else {
    logger.warning('LedgerState',
        '账本列表变化：current_ledger_id=$current 已不存在，回落到账本 $target（同会话，无需重启）');
  }
  // 订阅回调可能正好落在别的 provider 的 build 帧里（container.listen 首次
  // flush 会同步回调），而 riverpod 禁止在初始化期改写另一个 provider →
  // 落到微任务执行，语义不变（容器已销毁时 _applyCurrentLedgerId 吞掉异常）。
  scheduleMicrotask(() => _applyCurrentLedgerId(ref, target));
}

/// 当前账本的 prefs 持久化：`current_ledger_id` 是**唯一**读写的键
/// （云配置完整性回归要求键集合零增删）。
///
/// 自愈解析的三段分工：
/// - 启动采纳 → [_adoptSavedLedgerId]（[appInitProvider] 里 await 一次）；
/// - 响应式校正 → [_correctCurrentLedger]（[_ledgerChangeListener] 的订阅）；
/// - 结果落盘 → 本 provider。
/// 三段共用 [resolveCurrentLedgerId] 一个判据，所以谁先跑都不会写出悬空值。
final _currentLedgerPersist = Provider<void>((ref) {
  ref.listen<int>(currentLedgerIdProvider, (prev, next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('current_ledger_id', next);
    } catch (e) {
      logger.warning('LedgerState', '持久化当前账本 ID 失败，下次启动将回退默认', e);
    }
  });
});

/// 账本态三件事的激活点（由 [appInitProvider] 在 splash 阶段读取一次）：
/// 1. [currentLedgerIdProvider] 变化 → 触发一次设置页状态刷新（确保"我的"页及时反映）；
/// 2. [ledgersStreamProvider] 变化 → [_correctCurrentLedger] 校正当前账本（同会话）；
/// 3. 拉起 [_currentLedgerPersist]（`current_ledger_id` 落盘）。
final _ledgerChangeListener = Provider<void>((ref) {
  // 激活持久化监听
  ref.read(_currentLedgerPersist);
  ref.listen<int>(currentLedgerIdProvider, (prev, next) {
    ref.read(syncStatusRefreshProvider.notifier).state++;
  });

  // 账本列表的**容器级**订阅 → 响应式校正（[_correctCurrentLedger]）。
  //
  // 为什么必须走 container.listen，而不是本 provider 里 ref.watch/ref.listen：
  // riverpod 3 的暂停语义看的是 element.isActive =「有非暂停的依赖订阅」。
  // 这一串 provider 都只被 read 一次、没有任何 widget 监听，整条链处于 paused，
  // 挂在它下面的 StreamProvider 会**永久停在 AsyncLoading**、一个事件都不派发
  // （2026-10-10 实测：只有 provider 级 listen/watch 时 hasValue 恒 false；
  // 换 container.listen 立刻出值）。容器级订阅不受上游 paused 影响。
  final ledgerSub = ref.container.listen<AsyncValue<List<Ledger>>>(
    ledgersStreamProvider,
    (prev, next) => _correctCurrentLedger(ref, next.value),
  );
  ref.onDispose(ledgerSub.close);
});

// 确保监听器被激活
final appInitProvider = FutureProvider<void>((ref) async {
  // 读取以激活监听（账本态持久化 + 响应式校正）
  ref.read(_ledgerChangeListener);
  // 启动期采纳上次选中的账本。await 掉而不是 fire-and-forget：首帧就该落在
  // 正确的账本上，否则首页会先闪一下「+ 新建账本」空态（旧实现把它扔在
  // provider 体里并发跑，靠时序掩盖了这个窗口）。
  await _adoptSavedLedgerId(ref);
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
  // 管理页直接读主 Categories（Owner 资源镜像表已随共享账本下线删除），
  // 自然只看到用户自己的 user-global 行，无需过滤。
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

// 获取单个账户信息
final accountByIdProvider = FutureProvider.family<Account?, int>((ref, accountId) async {
  ref.watch(syncGenerationProvider);
  final repo = ref.watch(repositoryProvider);
  return await repo.getAccount(accountId);
});