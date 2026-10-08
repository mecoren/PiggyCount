import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../providers.dart';
import '../services/data/recurring_transaction_service.dart';
import '../utils/subscription_estimate.dart';

/// 订阅视图总览（列表 + 汇总）。
///
/// 只读派生：数据源是**当前账本启用中的支出型周期账单**，零识别算法、不落库、
/// 不进快照（见 prd/subscription_and_overspend_alerts/requirements.md §4.1）。
///
/// `ref.watch(allRecurringTransactionsProvider)` 只是失效锚点：周期账单行发生
/// 任何变化（新增 / 编辑 / 启停 / 删除，含云端拉取）都会让本 provider 重算。
/// 源数据本身仍走 Repository 直读，避免 `StreamProvider.future` 在无主动监听者
/// 时被暂停而永不完成（Riverpod 3 语义，见 AGENTS.md）。
final subscriptionOverviewProvider =
    FutureProvider<SubscriptionOverview>((ref) async {
  ref.watch(allRecurringTransactionsProvider);

  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);

  final ledger = await repo.getLedgerById(ledgerId);
  final baseCurrency = (ledger?.currency ?? 'CNY').toUpperCase();

  final templates = await repo.getEnabledRecurringTransactions(ledgerId);
  final categories = await repo.getAllCategories();
  final categoryById = <int, Category>{
    for (final c in categories) c.id: c,
  };

  final service = RecurringTransactionService(repo);
  final now = DateTime.now();

  final items = <SubscriptionItem>[];
  for (final t in templates) {
    // 只收支出型：收入 / 转账不是「订阅」。
    if (t.type != 'expense') continue;
    final code = (t.currencyCode ?? '').trim().toUpperCase();
    items.add(SubscriptionItem(
      recurring: t,
      category: t.categoryId == null ? null : categoryById[t.categoryId],
      nextDueDate: service.nextDueDateAfter(t, now: now),
      annualAmount: annualizedAmount(
        t.amount,
        RecurringFrequency.fromString(t.frequency),
        t.interval,
      ),
      isForeign: code.isNotEmpty && code != baseCurrency,
    ));
  }

  // 排序：下次扣款日近的靠前；无下次（已过 endDate）排最后；同日期按年化金额降序。
  items.sort((a, b) {
    final ad = a.nextDueDate;
    final bd = b.nextDueDate;
    if (ad == null && bd == null) {
      return b.annualAmount.compareTo(a.annualAmount);
    }
    if (ad == null) return 1;
    if (bd == null) return -1;
    final byDate = ad.compareTo(bd);
    return byDate != 0 ? byDate : b.annualAmount.compareTo(a.annualAmount);
  });

  return SubscriptionOverview(
    items: items,
    summary: summarizeSubscriptions(items: items, baseCurrency: baseCurrency),
  );
});
