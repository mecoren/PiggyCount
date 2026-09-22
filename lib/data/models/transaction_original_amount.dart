import '../db.dart';

/// v45 偏差计算的「金额口径」。
enum OriginalAmountMetric {
  /// 原币金额：直接用 `amount` / `original_amount` 原值。
  currency,

  /// 账本本位币折算：记账侧用 `COALESCE(native_amount, amount)`
  /// （与账本总览统计同口径），原始侧按该笔隐含汇率缩放。
  /// 单币种账本下与 [currency] 完全等价，不产生任何差异。
  native,
}

/// v45 偏差计算的「差异基准」。
///
/// 只是同一对金额的两种看法，符号与分母不同：
/// - [recorded]：差异 = 原始 − 记账，偏差率分母 = 记账金额
///   （「我记的这笔相对票面差多少」）；
/// - [original]：差异 = 记账 − 原始，偏差率分母 = 原始金额
///   （「票面对不上时，我记的偏离了多少」）。
enum OriginalAmountBasis {
  /// 以记账金额（即默认金额）为基准。
  recorded,

  /// 以原始金额为基准。
  original,
}

/// v45 原始金额的「有效值 / 指定口径值」口径 —— 单一事实源。
///
/// 物理列 `original_amount` 为 NULL 表示「用户未填写」，语义等价于
/// 「默认金额 = 记账金额」。SQL 侧对应 `COALESCE(original_amount, amount)`，
/// Dart 侧统一走此扩展 —— 两处口径必须逐字一致，避免散落兜底导致
/// 「列表显示已回落、统计却没回落」这类分裂。
extension TransactionOriginalAmountX on Transaction {
  /// 原始金额有效值（原币口径）。
  ///
  /// v45 起写入路径与迁移都做兜底（未填即落记账金额），正常业务下
  /// `original_amount` 恒非空；此处的 `?? amount` 只作**防御** ——
  /// 兼容旧快照导入、手工插库等仍可能为 NULL 的行。
  double get effectiveOriginalAmount => originalAmount ?? amount;

  /// 原币口径下原始金额相对记账金额的差值：正 = 原始高于记账。
  double get originalAmountDiff => effectiveOriginalAmount - amount;

  /// 所选口径下的记账金额（即「默认金额」）。
  double recordedAmountOf(OriginalAmountMetric metric) =>
      metric == OriginalAmountMetric.native ? (nativeAmount ?? amount) : amount;

  /// 所选口径下的原始金额有效值。
  ///
  /// - 未填写 → 回落[同口径]记账金额（保证未填写行差异恒为 0）；
  /// - [OriginalAmountMetric.native] → 按该笔隐含汇率缩放
  ///   （`original × native / amount`）。`amount == 0` 时汇率无从推断，
  ///   原样保留原币值（不会放大成除零/无穷）。
  double originalAmountOf(OriginalAmountMetric metric) {
    final o = originalAmount;
    if (o == null) return recordedAmountOf(metric);
    if (metric == OriginalAmountMetric.currency) return o;
    if (amount == 0) return o;
    return o * recordedAmountOf(metric) / amount;
  }

  /// 所选口径与基准下的差异。正负含义随 [basis] 翻转（见枚举注释）。
  double diffOf(OriginalAmountMetric metric, OriginalAmountBasis basis) {
    final recorded = recordedAmountOf(metric);
    final original = originalAmountOf(metric);
    return basis == OriginalAmountBasis.recorded
        ? original - recorded
        : recorded - original;
  }

  /// 偏差率分母：基准为记账金额时用记账金额，否则用原始金额。
  /// 分母为 0 时返回 0（调用方据此把偏差率记 0）。
  double diffBaseOf(OriginalAmountMetric metric, OriginalAmountBasis basis) =>
      basis == OriginalAmountBasis.recorded
          ? recordedAmountOf(metric)
          : originalAmountOf(metric);
}
