/// v45 原始金额偏差统计口径回归。
///
/// 统一口径：差异 = 原始侧 − 记账侧（记账基准）或反向（原始基准）；
/// 未填写的原始金额在**保存时兜底为记账金额** → 差异 0，与「默认金额」一致。
/// 「是否手填」这一状态自本口径起不再保留，统计侧用 deviated（有偏差明细数）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/transaction_original_amount.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger() => db.into(db.ledgers).insert(
      LedgersCompanion.insert(name: 'L', monthStartDay: const Value(1)));

  Future<void> add(
    int lid,
    double amount, {
    double? original,
    DateTime? at,
    int? categoryId,
    bool excludeFromStats = false,
  }) =>
      repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: amount,
        originalAmount: original,
        categoryId: categoryId,
        happenedAt: at ?? DateTime(2026, 6, 18),
        excludeFromStats: excludeFromStats,
        excludeFromBudget: false,
      );

  final start = DateTime(2026, 6, 1);
  final end = DateTime(2026, 7, 1);

  /// 默认口径（原币 + 记账基准）的汇总，供多数用例复用。
  Future<
      ({
        int total,
        int deviated,
        double diffSum,
        double absDiffSum,
        double maxAbsDiff,
      })> summary(
    int lid, {
    OriginalAmountMetric metric = OriginalAmountMetric.currency,
    OriginalAmountBasis basis = OriginalAmountBasis.recorded,
  }) =>
      repo.originalAmountDiffSummary(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        metric: metric,
        basis: basis,
      );

  test('addTransaction：填了就写填的值，未填兜底写记账金额（不留 NULL）', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 120);
    await add(lid, 50);

    final rows = await db.select(db.transactions).get();
    final filled = rows.firstWhere((r) => r.amount == 100);
    final bottomFilled = rows.firstWhere((r) => r.amount == 50);

    expect(filled.originalAmount, 120);
    // 未填写 → 保存时落库为记账金额，差异 0。
    expect(bottomFilled.originalAmount, 50);
    expect(bottomFilled.originalAmountDiff, 0);
  });

  test('updateTransaction：清空原始金额 → 重新兜底为记账金额', () async {
    final lid = await seedLedger();
    final id = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 100,
      originalAmount: 130,
      happenedAt: DateTime(2026, 6, 18),
      excludeFromStats: false,
      excludeFromBudget: false,
    );

    // editor 里把原始金额删空 → 传 Value<double?>(null)（显式清空）
    await repo.updateTransaction(
      id: id,
      type: 'expense',
      amount: 100,
      originalAmount: const Value<double?>(null),
    );

    final row = (await db.select(db.transactions).get()).single;
    expect(row.originalAmount, 100);
    expect(row.originalAmountDiff, 0);
  });

  test('summary：兜底行计入 total、不计入 deviated', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 120); // 偏差 +20
    await add(lid, 50); // 兜底 = 50 → 无偏差
    await add(lid, 200, original: 150); // 偏差 −50

    final s = await summary(lid);

    expect(s.total, 3);
    expect(s.deviated, 2);
    expect(s.diffSum, closeTo(-30, 1e-9));
    expect(s.absDiffSum, closeTo(70, 1e-9));
    expect(s.maxAbsDiff, closeTo(50, 1e-9));
  });

  test('summary：手填了与记账金额相同的值 → 有值但零偏差', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 100);

    final s = await summary(lid);

    expect(s.deviated, 0);
    expect(s.diffSum, 0);
    expect(s.absDiffSum, 0);
  });

  test('excludeFromStats=true 的明细不进偏差统计（与收支口径一致）', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 300, excludeFromStats: true);

    final s = await summary(lid);

    expect(s.total, 0);
    expect(s.diffSum, 0);
  });

  test('trend：按天分桶，区间内缺失的桶补零', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 120, at: DateTime(2026, 6, 2));
    await add(lid, 100, original: 80, at: DateTime(2026, 6, 4));

    final trend = await repo.originalAmountDiffTrend(
      ledgerId: lid,
      type: 'expense',
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 6, 5),
      granularity: 'day',
      metric: OriginalAmountMetric.currency,
      basis: OriginalAmountBasis.recorded,
    );

    expect(trend.length, 4); // 6/1 ~ 6/4，半开区间
    expect(trend[0].bucket, DateTime(2026, 6, 1));
    expect(trend[0].diffSum, 0); // 补零桶
    expect(trend[1].bucket, DateTime(2026, 6, 2));
    expect(trend[1].diffSum, closeTo(20, 1e-9));
    expect(trend[3].bucket, DateTime(2026, 6, 4));
    expect(trend[3].diffSum, closeTo(-20, 1e-9));
  });

  test('byCategory：带出分类名，零偏差的分类不返回', () async {
    final lid = await seedLedger();
    final cid = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));

    await add(lid, 100, original: 130, categoryId: cid);
    await add(lid, 60, original: 60, categoryId: cid); // 手填相同 → 零偏差

    final cats = await repo.originalAmountDiffByCategory(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        metric: OriginalAmountMetric.currency,
        basis: OriginalAmountBasis.recorded);

    expect(cats.length, 1);
    expect(cats.single.categoryName, '餐饮');
    // 两笔有值，但只有一笔真的产生偏差（另一笔手填值 == 记账金额）。
    expect(cats.single.deviated, 1);
    expect(cats.single.diffSum, closeTo(30, 1e-9));
  });

  test('byLedger：跨账本聚合按 ledgerId 分组', () async {
    final a = await seedLedger();
    final b = await seedLedger();
    await add(a, 100, original: 130);
    await add(b, 100, original: 60);

    final rows = await repo.originalAmountDiffByLedger(
        type: 'expense',
        start: start,
        end: end,
        metric: OriginalAmountMetric.currency,
        basis: OriginalAmountBasis.recorded);

    expect(rows.length, 2);
    final byId = {for (final r in rows) r.ledgerId: r};
    expect(byId[a]!.diffSum, closeTo(30, 1e-9));
    expect(byId[b]!.diffSum, closeTo(-40, 1e-9));
  });

  test('金额口径：本位币折算下原始金额按该笔隐含汇率缩放', () async {
    final lid = await seedLedger();
    // 外币：原币 100 USD，记账时折本位币 700（隐含汇率 7）；票面 120 USD。
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 100,
      originalAmount: 120,
      currencyCode: 'USD',
      nativeAmount: 700,
      happenedAt: DateTime(2026, 6, 18),
      excludeFromStats: false,
      excludeFromBudget: false,
    );

    final byCurrency = await summary(lid);
    expect(byCurrency.diffSum, closeTo(20, 1e-9)); // 原币：120 − 100

    final byNative = await summary(lid, metric: OriginalAmountMetric.native);
    // 折算原始金额 = 120 × 700 / 100 = 840；840 − 700 = 140
    expect(byNative.diffSum, closeTo(140, 1e-9));
    expect(byNative.maxAbsDiff, closeTo(140, 1e-9));
  });

  test('差异基准：以原始金额为基准时差异取反', () async {
    final lid = await seedLedger();
    await add(lid, 100, original: 130);

    final recorded = await summary(lid);
    expect(recorded.diffSum, closeTo(30, 1e-9));

    final original = await summary(lid, basis: OriginalAmountBasis.original);
    expect(original.diffSum, closeTo(-30, 1e-9));
    // 绝对值口径与基准无关。
    expect(original.absDiffSum, closeTo(30, 1e-9));
  });
}
