/// 洞察 / 报表「金额口径」（记账金额 / 原始金额）回归。
///
/// 口径的唯一真相源是 [AnalyticsAmountMetric]：SQL 走 `sqlExpr()`、Dart 侧聚合走
/// `amountOf()`。本测试**直接打真库**（内存 Drift）守两件事：
/// ① 每个统计入口都真的吃到了口径参数（漏传一处就是「总额按原始金额、分类构成
/// 按记账金额」的对不上账）；
/// ② 原始金额的兜底语义与 v45 一致 —— 未填写（NULL 或落库兜底值）即按记账金额，
/// 外币按该笔隐含汇率折算，`amount = 0` 不除零。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_amount_metric.dart';
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

  final start = DateTime(2026, 6, 1);
  final end = DateTime(2026, 7, 1);
  final at = DateTime(2026, 6, 18);

  Future<int> add(
    int lid, {
    String type = 'expense',
    required double amount,
    double? original,
    double? native,
    String? currency,
    int? categoryId,
    DateTime? happenedAt,
    bool excludeFromStats = false,
    Map<String, dynamic>? customValues,
  }) =>
      repo.addTransaction(
        ledgerId: lid,
        type: type,
        amount: amount,
        originalAmount: original,
        nativeAmount: native,
        currencyCode: currency,
        categoryId: categoryId,
        customValues: customValues,
        happenedAt: happenedAt ?? at,
        excludeFromStats: excludeFromStats,
        excludeFromBudget: false,
      );

  /// 标准夹具（默认账本 id 由 seedLedger 返回）：
  ///
  /// | 明细 | 记账(本位币) | 原始(本位币) | 说明 |
  /// | --- | --- | --- | --- |
  /// | A 支出 100 / 原始 120 | 100 | 120 | 手填高于记账 |
  /// | B 支出 100 / 原始 80  | 100 | 80  | 手填低于记账 |
  /// | E 外币 100USD→700 / 原始 120USD | 700 | 840 | 按隐含汇率 7 折算 |
  /// | F 支出 30（原始金额落库 NULL） | 30 | 30 | legacy / 导入行的兜底 |
  /// | D 支出 999（不计收支） | 0 | 0 | 两个口径都排除 |
  /// | C 收入 50 / 原始 60 | 50 | 60 | 收入侧同口径 |
  ///
  /// → 支出合计：记账 930 / 原始 1070；收入合计：记账 50 / 原始 60。
  Future<int> seedFixture() async {
    final lid = await seedLedger();
    await add(lid, amount: 100, original: 120);
    await add(lid, amount: 100, original: 80);
    await add(lid,
        amount: 100, original: 120, native: 700, currency: 'USD');
    // 原始金额列留 NULL：老数据 / 导入路径的兜底分支
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: lid,
          type: 'expense',
          amount: 30,
          happenedAt: Value(at),
        ));
    await add(lid, amount: 999, original: 999, excludeFromStats: true);
    await add(lid, type: 'income', amount: 50, original: 60);
    return lid;
  }

  const recorded = AnalyticsAmountMetric.recorded;
  const original = AnalyticsAmountMetric.original;

  test('totalsInRange：两个口径的收支合计各自成立，且排除不计收支', () async {
    final lid = await seedFixture();

    final rec = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: recorded);
    final org = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: original);

    expect(rec.$1, closeTo(50, 1e-9));
    expect(rec.$2, closeTo(930, 1e-9));
    expect(org.$1, closeTo(60, 1e-9));
    expect(org.$2, closeTo(1070, 1e-9));
  });

  test('totalsByDay：日桶金额随口径切换，桶数不变', () async {
    final lid = await seedFixture();

    final rec = await repo.totalsByDay(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: recorded);
    final org = await repo.totalsByDay(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: original);

    expect(rec.length, org.length);
    expect(rec.fold<double>(0, (s, e) => s + e.total), closeTo(930, 1e-9));
    expect(org.fold<double>(0, (s, e) => s + e.total), closeTo(1070, 1e-9));
  });

  test('totalsByCategory / totalsByCategoryWithHierarchy：分类金额随口径，笔数不变',
      () async {
    final lid = await seedLedger();
    final cid = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    await add(lid, amount: 100, original: 120, categoryId: cid);
    await add(lid, amount: 100, original: 80, categoryId: cid);

    final recCats = await repo.totalsByCategory(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: recorded);
    final orgCats = await repo.totalsByCategory(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: original);
    expect(recCats.single.total, closeTo(200, 1e-9));
    expect(orgCats.single.total, closeTo(200, 1e-9)); // 120 + 80 = 200

    final recHier = await repo.totalsByCategoryWithHierarchy(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: recorded);
    final orgHier = await repo.totalsByCategoryWithHierarchy(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: original);
    expect(recHier.single.total, closeTo(200, 1e-9));
    expect(orgHier.single.total, closeTo(200, 1e-9));
    // 笔数与口径无关：只换金额，不换计数
    expect(recHier.single.count, 2);
    expect(orgHier.single.count, 2);
  });

  test('totalsByCategory：原始金额口径下合计与逐笔原始金额一致（含外币折算）',
      () async {
    final lid = await seedLedger();
    final cid = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    await add(lid, amount: 100, original: 120, categoryId: cid);
    await add(lid,
        amount: 100,
        original: 120,
        native: 700,
        currency: 'USD',
        categoryId: cid);

    final org = await repo.totalsByCategory(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: original);

    // 120 + 120 × 700 / 100 = 120 + 840
    expect(org.single.total, closeTo(960, 1e-9));
  });

  test('totalsByMonth / monthlyTotals / totalsByYearSeries / yearlyTotals：月度与年度均吃口径',
      () async {
    final lid = await seedFixture();

    Future<double> monthSum(AnalyticsAmountMetric m) async {
      final rows = await repo.totalsByMonth(
          ledgerId: lid, type: 'expense', year: 2026, amountMetric: m);
      return rows.fold<double>(0, (s, e) => s + e.total);
    }

    expect(await monthSum(recorded), closeTo(930, 1e-9));
    expect(await monthSum(original), closeTo(1070, 1e-9));

    final recMonth = await repo.monthlyTotals(
        ledgerId: lid, month: at, amountMetric: recorded);
    final orgMonth = await repo.monthlyTotals(
        ledgerId: lid, month: at, amountMetric: original);
    expect(recMonth.$1, closeTo(50, 1e-9));
    expect(recMonth.$2, closeTo(930, 1e-9));
    expect(orgMonth.$1, closeTo(60, 1e-9));
    expect(orgMonth.$2, closeTo(1070, 1e-9));

    final recYear = await repo.yearlyTotals(
        ledgerId: lid, year: 2026, amountMetric: recorded);
    final orgYear = await repo.yearlyTotals(
        ledgerId: lid, year: 2026, amountMetric: original);
    expect(recYear.$1, closeTo(50, 1e-9));
    expect(recYear.$2, closeTo(930, 1e-9));
    expect(orgYear.$1, closeTo(60, 1e-9));
    expect(orgYear.$2, closeTo(1070, 1e-9));

    final recSeries = await repo.totalsByYearSeries(
        ledgerId: lid, type: 'expense', amountMetric: recorded);
    final orgSeries = await repo.totalsByYearSeries(
        ledgerId: lid, type: 'expense', amountMetric: original);
    expect(recSeries.single.total, closeTo(930, 1e-9));
    expect(orgSeries.single.total, closeTo(1070, 1e-9));
  });

  test('totalsByTag：标签聚合走同一口径（含别名 t. 的表达式）', () async {
    final lid = await seedLedger();
    final tagId = await db.into(db.tags).insert(TagsCompanion.insert(name: '超市'));
    final a = await add(lid, amount: 100, original: 120);
    final b = await add(lid, amount: 100, original: 80);
    await repo.updateTransactionTags(transactionId: a, tagIds: [tagId]);
    await repo.updateTransactionTags(transactionId: b, tagIds: [tagId]);

    final rec = await repo.totalsByTag(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: recorded);
    final org = await repo.totalsByTag(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: original);

    expect(rec.single.total, closeTo(200, 1e-9));
    expect(org.single.total, closeTo(200, 1e-9));
    expect(rec.single.count, 2);
    expect(org.single.count, 2);
  });

  test('customFieldStatsRows：金额列随口径（字段值桶的金额同源）', () async {
    final lid = await seedLedger();
    // 本取数只返回「填过自定义字段值」的明细（卡片口径），故单独造夹具。
    await add(lid, amount: 100, original: 120, customValues: const {'f1': 'A'});
    await add(lid,
        type: 'income',
        amount: 50,
        original: 80,
        customValues: const {'f1': 'B'});
    // 未填值的明细不进这张表
    await add(lid, amount: 999, original: 999);

    final org = await repo.customFieldStatsRows(
        ledgerId: lid, start: start, end: end, amountMetric: original);
    final rec = await repo.customFieldStatsRows(
        ledgerId: lid, start: start, end: end, amountMetric: recorded);

    double sumOf(
            List<({String type, double nativeAmount, String? customValuesJson})>
                rows,
            String type) =>
        rows
            .where((r) => r.type == type)
            .fold<double>(0, (s, r) => s + r.nativeAmount);

    expect(rec.length, 2);
    expect(sumOf(rec, 'expense'), closeTo(100, 1e-9));
    expect(sumOf(org, 'expense'), closeTo(120, 1e-9));
    expect(sumOf(rec, 'income'), closeTo(50, 1e-9));
    expect(sumOf(org, 'income'), closeTo(80, 1e-9));
  });

  test('原始金额为 NULL（legacy / 导入行）时两个口径同值：兜底不落 0', () async {
    final lid = await seedLedger();
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: lid,
          type: 'expense',
          amount: 66,
          happenedAt: Value(at),
        ));

    final rec = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: recorded);
    final org = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: original);

    expect(rec.$2, closeTo(66, 1e-9));
    expect(org.$2, closeTo(66, 1e-9));
  });

  test('amount = 0 的明细不除零（原样保留原币值）', () async {
    final lid = await seedLedger();
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: lid,
          type: 'expense',
          amount: 0,
          originalAmount: const Value(88),
          happenedAt: Value(at),
        ));

    final org = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: original);

    expect(org.$2, closeTo(88, 1e-9));
  });

  test('Dart 侧 amountOf 与 SQL 侧 sqlExpr 同义（本位币折算 + 兜底）', () async {
    final lid = await seedLedger();
    await add(lid, amount: 100, original: 120);
    await add(lid, amount: 100, original: 120, native: 700, currency: 'USD');

    final rows = await db.select(db.transactions).get();
    double dartOriginal = 0;
    double dartRecorded = 0;
    for (final t in rows) {
      dartOriginal += original.amountOf(t);
      dartRecorded += recorded.amountOf(t);
    }

    expect(dartRecorded, closeTo(800, 1e-9));
    expect(dartOriginal, closeTo(960, 1e-9));

    final sqlOrg = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: original);
    final sqlRec = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: recorded);
    expect(sqlOrg.$2, closeTo(dartOriginal, 1e-9));
    expect(sqlRec.$2, closeTo(dartRecorded, 1e-9));
  });

  test('持久化：storageValue ↔ fromStorage 往返，脏值回落记账金额', () {
    expect(AnalyticsAmountMetric.fromStorage(original.storageValue), original);
    expect(
        AnalyticsAmountMetric.fromStorage(recorded.storageValue), recorded);
    // 旧版本 / 脏值 / 类型不符 → 默认口径，不抛
    expect(AnalyticsAmountMetric.fromStorage('legacy_basis'), recorded);
    expect(AnalyticsAmountMetric.fromStorage(null), recorded);
    expect(AnalyticsAmountMetric.fromStorage(7), recorded);
  });

  test('isSame 语义：未传参的入口默认记账金额（老调用方行为不变）', () async {
    final lid = await seedFixture();

    final defaulted = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end);
    final explicit = await repo.totalsInRange(
        ledgerId: lid,
        start: start,
        end: end,
        amountMetric: recorded);

    expect(defaulted, explicit);
  });

  test('口径与 OriginalAmountMetric 正交，不互相覆盖', () async {
    final lid = await seedLedger();
    await add(lid, amount: 100, original: 120, native: 700, currency: 'USD');

    // 原始金额口径下本位币折算值 = 840（不是原币 120）
    final org = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, amountMetric: original);
    expect(org.$2, closeTo(840, 1e-9));

    // 偏差轴（另一枚举）本位币口径仍独立成立：840 − 700 = 140
    final diff = await repo.originalAmountDiffSummary(
      ledgerId: lid,
      type: 'expense',
      start: start,
      end: end,
      metric: OriginalAmountMetric.native,
      basis: OriginalAmountBasis.recorded,
    );
    expect(diff.diffSum, closeTo(140, 1e-9));
  });
}
