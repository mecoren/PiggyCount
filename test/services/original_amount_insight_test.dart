/// v45 原始金额偏差洞察规则引擎（纯函数）回归。
///
/// 触发：`|diff| >= max(absoluteFloor, ratioFloor * |amount|)`；
/// 分级：`[r, 2r)` 轻微 / `[2r, 1.0)` 明显 / `>= 1.0` 严重（默认 r = 0.2）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/transaction_original_amount.dart';
import 'package:piggycount/services/original_amount_insight_service.dart';

Transaction tx({
  int id = 1,
  double amount = 100,
  double? original,
  double? nativeAmount,
  String? currencyCode,
  int? categoryId,
  String type = 'expense',
}) =>
    Transaction(
      id: id,
      ledgerId: 1,
      type: type,
      amount: amount,
      categoryId: categoryId,
      happenedAt: DateTime(2026, 6, 18),
      currencyCode: currencyCode,
      nativeAmount: nativeAmount,
      excludeFromStats: false,
      excludeFromBudget: false,
      originalAmount: original,
    );

void main() {
  test('未填写原始金额不产生洞察（未填是常态，不是偏差）', () {
    expect(OriginalAmountInsightService.analyze([tx(original: null)]), isEmpty);
  });

  test('转账不参与洞察', () {
    expect(
      OriginalAmountInsightService.analyze(
          [tx(type: 'transfer', amount: 100, original: 200)]),
      isEmpty,
    );
  });

  test('低于阈值不触发：偏差率 <20% 或绝对差 <1', () {
    // 10% 且绝对差 10（≥1，但率不足）
    expect(OriginalAmountInsightService.analyze([tx(amount: 100, original: 110)]),
        isEmpty);
    // 12.5% 且绝对差 0.5（<1，绝对下限滤噪）
    expect(
        OriginalAmountInsightService.analyze([tx(amount: 4, original: 4.5)]),
        isEmpty);
  });

  test('分级：20%~40% 轻微 / 40%~100% 明显 / ≥100% 严重（含负偏差）', () {
    expect(OriginalAmountInsightService.classify(0.25),
        OriginalAmountSeverity.slight);
    expect(OriginalAmountInsightService.classify(0.39),
        OriginalAmountSeverity.slight);
    // 明显档下界 = 2 × ratioFloor（默认 0.4），随 ratioFloor 联动。
    expect(OriginalAmountInsightService.classify(0.4),
        OriginalAmountSeverity.notable);
    expect(OriginalAmountInsightService.classify(0.99),
        OriginalAmountSeverity.notable);
    expect(OriginalAmountInsightService.classify(1.0),
        OriginalAmountSeverity.severe);
    expect(OriginalAmountInsightService.classify(-1.2),
        OriginalAmountSeverity.severe);
  });

  test('原因码：高于 / 低于 / 整数倍（换算误差特征优先）', () {
    final above =
        OriginalAmountInsightService.analyze([tx(amount: 100, original: 130)])
            .single;
    expect(above.reasonCode, OriginalAmountReasonCode.aboveRecorded);
    expect(above.diff, closeTo(30, 1e-9));
    expect(above.diffRate, closeTo(0.3, 1e-9));

    final below =
        OriginalAmountInsightService.analyze([tx(amount: 100, original: 70)])
            .single;
    expect(below.reasonCode, OriginalAmountReasonCode.belowRecorded);

    // 100 → 200：偏差率 1.0 是整数倍 → 归为换算误差而非「高于」
    final mult =
        OriginalAmountInsightService.analyze([tx(amount: 100, original: 200)])
            .single;
    expect(mult.reasonCode, OriginalAmountReasonCode.multipleOfRecorded);
  });

  test('同分类达到 3 笔触发 categoryHabit；未分类(null)不归因', () {
    final habit = OriginalAmountInsightService.analyze([
      tx(id: 1, amount: 100, original: 130, categoryId: 7),
      tx(id: 2, amount: 100, original: 140, categoryId: 7),
      tx(id: 3, amount: 100, original: 120, categoryId: 7),
    ]);
    expect(habit.length, 3);
    expect(
      habit.every(
          (e) => e.reasonCode == OriginalAmountReasonCode.categoryHabit),
      isTrue,
    );

    // 不足 3 笔 → 保持方向性归因
    final notEnough = OriginalAmountInsightService.analyze([
      tx(id: 4, amount: 100, original: 130, categoryId: 7),
      tx(id: 5, amount: 100, original: 140, categoryId: 7),
    ]);
    expect(
      notEnough.every(
          (e) => e.reasonCode == OriginalAmountReasonCode.aboveRecorded),
      isTrue,
    );

    // 未分类（categoryId == null）不参与系统性归因
    final uncategorized = OriginalAmountInsightService.analyze([
      tx(id: 6, amount: 100, original: 130),
      tx(id: 7, amount: 100, original: 140),
      tx(id: 8, amount: 100, original: 120),
    ]);
    expect(
      uncategorized.any(
          (e) => e.reasonCode == OriginalAmountReasonCode.categoryHabit),
      isFalse,
    );
  });

  test('结果按 |diff| 倒序（最该看的排最前）', () {
    final out = OriginalAmountInsightService.analyze([
      tx(id: 1, amount: 100, original: 130), // 30
      tx(id: 2, amount: 100, original: 190), // 90
      tx(id: 3, amount: 100, original: 70), // −30
    ]);
    expect(out.map((e) => e.transactionId).toList(), [2, 1, 3]);
  });

  test('金额口径：本位币折算下原始金额按隐含汇率缩放', () {
    // 原币 100 USD 记 700 CNY（隐含汇率 7），票面 120 USD。
    final t = tx(
      amount: 100,
      original: 120,
      nativeAmount: 700,
      currencyCode: 'USD',
    );

    final byCurrency = OriginalAmountInsightService.analyze([t]).single;
    expect(byCurrency.diff, closeTo(20, 1e-9));
    expect(byCurrency.diffRate, closeTo(0.2, 1e-9));

    final byNative = OriginalAmountInsightService.analyze(
      [t],
      metric: OriginalAmountMetric.native,
    ).single;
    // 折算原始 = 120 × 700 / 100 = 840；840 − 700 = 140 = 20% of 700
    expect(byNative.recordedAmount, closeTo(700, 1e-9));
    expect(byNative.originalAmount, closeTo(840, 1e-9));
    expect(byNative.diff, closeTo(140, 1e-9));
    expect(byNative.diffRate, closeTo(0.2, 1e-9));
  });

  test('差异基准：以原始金额为基准时差异取反、分母换成原始金额', () {
    final out = OriginalAmountInsightService.analyze(
      [tx(amount: 100, original: 130)],
      basis: OriginalAmountBasis.original,
    ).single;

    expect(out.diff, closeTo(-30, 1e-9));
    // 分母 = 原始金额 130，而非记账金额 100
    expect(out.diffRate, closeTo(-30 / 130, 1e-9));
    // 整数倍判定仍按偏差率；0.23 不是整数倍 → 归为方向性原因
    expect(out.reasonCode, OriginalAmountReasonCode.belowRecorded);
  });

  test('未填写在本位币口径下同样不产生差异（不因折算凭空造出偏差）', () {
    final t = tx(amount: 100, nativeAmount: 700, currencyCode: 'USD');
    expect(
      OriginalAmountInsightService.analyze(
        [t],
        metric: OriginalAmountMetric.native,
      ),
      isEmpty,
    );
  });
}
