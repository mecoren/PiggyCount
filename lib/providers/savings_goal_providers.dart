import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../utils/savings_goal_progress.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';

/// 储蓄目标相关 Provider（v53）。
///
/// 分层：UI → Provider → Repository。**进度解算在这里做一次**（账户模式取账户
/// 余额、手动模式取 `saved_amount`），UI 只渲染 [SavingsGoalWithProgress] ——
/// 页面不再二次计算，避免「列表卡」与「汇总卡」漂成两套口径。纯算术在
/// `lib/utils/savings_goal_progress.dart`（可单测）。

/// 目标行 + 解算后的进度。
class SavingsGoalWithProgress {
  const SavingsGoalWithProgress({
    required this.goal,
    required this.progress,
    this.accountName,
  });

  final SavingsGoal goal;
  final SavingsGoalProgress progress;

  /// 账户模式下的账户名；账户已被删除（悬空引用）时为 null。
  final String? accountName;

  /// 是否按账户余额跟踪进度（false = 手动累计）。
  bool get tracksAccount => goal.accountId != null && accountName != null;
}

/// 当前账本的储蓄目标列表（Stream：写库后自动刷新）。
final savingsGoalsProvider = StreamProvider<List<SavingsGoal>>((ref) {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.watchSavingsGoalsByLedger(ledgerId);
});

/// 目标 + 进度（列表页与汇总卡的数据源）。
final savingsGoalProgressProvider =
    FutureProvider<List<SavingsGoalWithProgress>>((ref) async {
  final goals = await ref.watch(savingsGoalsProvider.future);
  // 账户余额变化信号（记账 / 转账 / 账户编辑都会 bump）：账户模式的目标进度
  // 挂在余额上，不跟这个信号就会「明细是新的、进度条还是旧的」。
  ref.watch(statsRefreshProvider);

  final repo = ref.watch(repositoryProvider);
  final out = <SavingsGoalWithProgress>[];
  for (final goal in goals) {
    var saved = goal.savedAmount;
    String? accountName;
    final accountId = goal.accountId;
    if (accountId != null) {
      final account = await repo.getAccount(accountId);
      if (account != null) {
        accountName = account.name;
        saved = await repo.getAccountBalance(accountId);
      }
      // 账户已不存在（账户删除后的置空逻辑尚未跑到 / 同步回来的悬空引用）：
      // 回退手动口径（saved_amount），绝不把它当成 0 之外的语义放宽。
    }
    out.add(SavingsGoalWithProgress(
      goal: goal,
      progress: computeSavingsGoalProgress(
        saved: saved,
        targetAmount: goal.targetAmount,
        startDate: goal.startDate,
      ),
      accountName: accountName,
    ));
  }
  return out;
});

/// 列表页顶部汇总（**仅账本本位币口径**，外币目标只计数不计金额）。
///
/// 总已存按账户去重：只有 [SavingsGoalWithProgress.tracksAccount] 为真（确实按
/// 账户余额跟踪）的目标才带上账户锚点 —— 账户被删后的悬空引用已回退手动口径
/// （`saved = saved_amount`），那份累计额是独立的，不该被当成同一笔余额。
final savingsGoalSummaryProvider = FutureProvider<SavingsGoalSummary>((ref) async {
  final items = await ref.watch(savingsGoalProgressProvider.future);
  final ledger = await ref.watch(currentLedgerProvider.future);
  return summarizeSavingsGoals(
    [
      for (final item in items)
        (
          target: item.goal.targetAmount,
          saved: item.progress.saved,
          currency: item.goal.currency,
          accountId: item.tracksAccount ? item.goal.accountId : null,
        ),
    ],
    ledgerCurrency: ledger?.currency ?? 'CNY',
  );
});
