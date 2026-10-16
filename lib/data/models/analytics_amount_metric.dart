import '../db.dart';
import 'transaction_original_amount.dart';

/// 洞察 / 报表的「金额口径」二级选项 —— **单一真相源**。
///
/// 统计 SQL、Dart 侧聚合、海报、PDF、年度账单全部经这里取金额表达式 /
/// 取值函数。口径只定义一次的理由：`COALESCE(native_amount, amount)` 此前
/// 散落在统计仓 / 交易仓 / 预算仓 / 账本仓 / 分类仓 / 报表页 / 导出服务里
/// 共约 30 处，任何一处漏改都会造成「界面按 A 口径、导出按 B 口径」的静默
/// 分裂（报销 / 对账场景直接对不上）。
///
/// 与 [OriginalAmountMetric] 的区别：那是「原币 / 本位币折算」这一轴，
/// 本枚举是「拿记账金额还是原始金额统计」这一轴，两者正交。
enum AnalyticsAmountMetric {
  /// 记账金额（默认）：`COALESCE(native_amount, amount)`，与账本本位币总览同源。
  recorded,

  /// 原始金额：按票面 / 原始金额统计。
  ///
  /// 未填写的明细回落**同口径记账金额**（v45 语义，见
  /// [TransactionOriginalAmountX.originalAmountOf]）——所以未填写的明细在
  /// 两个口径下数值相同，口径切换只在「填过原始金额」的明细上产生差异，
  /// 无需另加兜底，也不会把「没填」误算成 0。
  original;

  /// 持久化键（SharedPreferences）。
  static const String prefsKey = 'analytics_amount_metric';

  /// 存储值 → 枚举。无法识别（旧版本 / 脏值）时回落 [recorded]。
  static AnalyticsAmountMetric fromStorage(Object? raw) {
    if (raw is String) {
      for (final v in values) {
        if (v.name == raw) return v;
      }
    }
    return recorded;
  }

  /// 枚举 → 存储值。
  String get storageValue => name;

  /// SQL 侧金额表达式（本位币折算），[alias] 为表别名（无别名传空串）。
  ///
  /// - [recorded] → `COALESCE(native_amount, amount)`；
  /// - [original] → 未填回落记账侧；`amount = 0` 时汇率无从推断，原样保留
  ///   原币值（不产生除零）；否则按该笔隐含汇率缩放
  ///   （`original × native / amount`）。
  ///
  /// 与 Dart 侧 [amountOf] 逐字同义，改任一侧必须同步另一侧。
  String sqlExpr({String alias = ''}) {
    final p = alias.isEmpty ? '' : '$alias.';
    final rec = 'COALESCE(${p}native_amount, ${p}amount)';
    switch (this) {
      case AnalyticsAmountMetric.recorded:
        return rec;
      case AnalyticsAmountMetric.original:
        return 'CASE WHEN ${p}original_amount IS NULL THEN $rec '
            'WHEN ${p}amount = 0 THEN ${p}original_amount '
            'ELSE ${p}original_amount * $rec / ${p}amount END';
    }
  }

  /// Dart 侧取值：对**已取出的交易行**做聚合时使用（与 [sqlExpr] 同义）。
  double amountOf(Transaction t) {
    switch (this) {
      case AnalyticsAmountMetric.recorded:
        return t.nativeAmount ?? t.amount;
      case AnalyticsAmountMetric.original:
        return t.originalAmountOf(OriginalAmountMetric.native);
    }
  }
}
