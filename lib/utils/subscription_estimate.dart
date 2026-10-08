import '../data/db.dart';
import '../services/data/recurring_transaction_service.dart';

/// 订阅视图的展示模型 —— 由「周期账单模板」派生，不落库、不进快照。
///
/// 见 prd/subscription_and_overspend_alerts/requirements.md §4.1：订阅 = 当前账本
/// 下**启用中的支出型**周期账单，零识别算法（不扫历史流水）。
class SubscriptionItem {
  /// 源周期账单模板。点击条目直接进它的编辑页。
  final RecurringTransaction recurring;

  /// 关联分类。null = 未选分类 / 分类已被删（名称与图标都走兜底）。
  final Category? category;

  /// 下次扣款日（严格晚于「现在」；null = 不会再有下一次，如已过 endDate）。
  final DateTime? nextDueDate;

  /// 年化金额（**模板币种口径**，未做汇率折算）。
  final double annualAmount;

  /// 是否外币订阅（模板币种 ≠ 账本本位币）。
  ///
  /// 不做折算：模板币种要到「生成那一天」才按当日有效汇率折成本位币（见
  /// `RecurringTransactionService.generatePendingTransactions` 的币种注释），
  /// 视图期没有可靠汇率可用，硬折会给出错误数字。故本外币订阅**不计入合计**，
  /// 由 UI 单独提示条数。
  final bool isForeign;

  const SubscriptionItem({
    required this.recurring,
    this.category,
    this.nextDueDate,
    required this.annualAmount,
    required this.isForeign,
  });

  /// 展示名：备注优先，其次分类名，都没有时由 UI 兜底文案。
  String? get displayName {
    final note = recurring.note;
    if (note != null && note.trim().isNotEmpty) return note.trim();
    return null;
  }
}

/// 订阅视图总览（列表 + 汇总）。
class SubscriptionOverview {
  final List<SubscriptionItem> items;
  final SubscriptionSummary summary;

  const SubscriptionOverview({required this.items, required this.summary});
}

/// 订阅汇总。
class SubscriptionSummary {
  /// 订阅总数（含未计入合计的外币订阅）。
  final int count;

  /// 未计入合计的外币订阅数。
  final int foreignCount;

  /// 年支出（仅本位币订阅）。
  final double annualAmount;

  /// 月均支出 = 年支出 / 12。
  final double monthlyAmount;

  /// 账本本位币（ISO 大写）。
  final String currencyCode;

  const SubscriptionSummary({
    required this.count,
    required this.foreignCount,
    required this.annualAmount,
    required this.monthlyAmount,
    required this.currencyCode,
  });

  bool get hasForeign => foreignCount > 0;
}

/// 每年发生次数（纯函数）。
///
/// daily=365 / weekly=52 / monthly=12 / yearly=1，再除以间隔；
/// `interval < 1` 按 1 处理（脏数据兜底，避免除零与放大）。
double occurrencesPerYear(RecurringFrequency frequency, int interval) {
  final n = interval < 1 ? 1 : interval;
  switch (frequency) {
    case RecurringFrequency.daily:
      return 365 / n;
    case RecurringFrequency.weekly:
      return 52 / n;
    case RecurringFrequency.monthly:
      return 12 / n;
    case RecurringFrequency.yearly:
      return 1 / n;
  }
}

/// 年化金额 = 单次金额 × 每年次数（纯函数）。
double annualizedAmount(
  double amount,
  RecurringFrequency frequency,
  int interval,
) =>
    amount * occurrencesPerYear(frequency, interval);

/// 汇总订阅（纯函数）：外币项只计数、不计金额。
SubscriptionSummary summarizeSubscriptions({
  required List<SubscriptionItem> items,
  required String baseCurrency,
}) {
  var annual = 0.0;
  var foreign = 0;
  for (final item in items) {
    if (item.isForeign) {
      foreign++;
      continue;
    }
    annual += item.annualAmount;
  }
  return SubscriptionSummary(
    count: items.length,
    foreignCount: foreign,
    annualAmount: annual,
    monthlyAmount: annual / 12,
    currencyCode: baseCurrency,
  );
}
