/// M2-a 首页窗口化回归（keyset 游标 + 日合计下沉 SQL）。
///
/// 守两条命门：
/// 1. **窗口/分页与全量查询逐值等价** —— 首页从「整本账本」换成窗口后，
///    行集、顺序、（同秒多笔的）边界都不能变；这是把首页切过去的前提，
///    也是唯一能在无真机环境下证明"没切坏"的证据。
/// 2. **日合计口径不漂移** —— 窗口化后最旧一天可能只加载了部分行，日合计
///    改由 SQL 出；SQL 口径必须与列表原本的 Dart 循环 `_computeDayTotals`
///    逐字一致：`nativeAmount ?? amount`、只计 income/expense、**不过滤**
///    `excludeFromStats`（与日历口径 `getDailyTotalsByMonth` 故意不同）。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger(String name) => db.into(db.ledgers).insert(
      LedgersCompanion.insert(name: name));

  test('窗口 == 全量查询的前 N 行（行集与顺序逐值对拍）', () async {
    final lid = await seedLedger('窗口账本');
    for (var i = 0; i < 10; i++) {
      await repo.addTransaction(
        ledgerId: lid,
        type: i.isEven ? 'expense' : 'income',
        amount: 10.0 + i,
        happenedAt: DateTime(2026, 6, 1 + i, 12),
      );
    }

    final full =
        await repo.watchTransactionsWithCategoryAll(ledgerId: lid).first;
    final win =
        await repo.watchTransactionWindow(ledgerId: lid, limit: 4).first;

    expect(win.map((e) => e.t.id).toList(),
        full.take(4).map((e) => e.t.id).toList(),
        reason: '窗口必须是全量查询（同序）的前 4 行');
    expect(win.map((e) => e.t.amount).toList(),
        full.take(4).map((e) => e.t.amount).toList());
    expect(full.length, 10);
  });

  test('keyset 游标分页：逐页拼接与全量查询逐值同序、不重不漏（含同秒多笔）',
      () async {
    final lid = await seedLedger('分页账本');
    // 同秒 7 笔：专门压 id tiebreaker（只按 happened_at 排会丢/重）
    for (var i = 0; i < 7; i++) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 1.0 + i,
        happenedAt: DateTime(2026, 6, 2, 9),
      );
    }
    // 另一秒 5 笔
    for (var i = 0; i < 5; i++) {
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 100.0 + i,
        happenedAt: DateTime(2026, 6, 3, 9),
      );
    }

    final full =
        await repo.watchTransactionsWithCategoryAll(ledgerId: lid).first;
    final fullIds = full.map((e) => e.t.id).toList();

    final paged = <int>[];
    ({DateTime happenedAt, int id})? cursor;
    var guard = 0;
    while (true) {
      final page = await repo
          .watchTransactionWindow(ledgerId: lid, before: cursor, limit: 3)
          .first;
      if (page.isEmpty) break;
      paged.addAll(page.map((e) => e.t.id));
      cursor = (happenedAt: page.last.t.happenedAt, id: page.last.t.id);
      if (++guard > 50) fail('分页未收敛（可能游标条件写反了）');
    }

    expect(paged, fullIds, reason: '按页拼接必须与全量查询逐值同序');
    expect(paged.toSet().length, paged.length, reason: '不得重复');
    expect(paged.length, 12, reason: '不得漏行');
  });

  test('窗口只取本账本', () async {
    final a = await seedLedger('A');
    final b = await seedLedger('B');
    await repo.addTransaction(
        ledgerId: a,
        type: 'expense',
        amount: 1,
        happenedAt: DateTime(2026, 6, 1));
    await repo.addTransaction(
        ledgerId: b,
        type: 'expense',
        amount: 2,
        happenedAt: DateTime(2026, 6, 2));

    final winA =
        await repo.watchTransactionWindow(ledgerId: a, limit: 10).first;
    expect(winA.map((e) => e.t.ledgerId).toSet(), {a});
    expect(winA.length, 1);
  });

  test('getDailyTotalsInRange 口径与列表 Dart 循环一致（transfer 不计 / excludeFromStats 仍计 / 半开区间 / nativeAmount 优先）',
      () async {
    final lid = await seedLedger('日合计账本');
    // 2026-06-02：收入 100、支出 30、转账 999(不计)、
    //   excludeFromStats 支出 20（**仍计** —— 这是展示口径不是统计口径）
    await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 100,
        happenedAt: DateTime(2026, 6, 2, 9));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 30,
        happenedAt: DateTime(2026, 6, 2, 10));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 999,
        happenedAt: DateTime(2026, 6, 2, 11));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 20,
        happenedAt: DateTime(2026, 6, 2, 12),
        excludeFromStats: true);
    // nativeAmount 优先：记账 10 USD / 折本位币 70
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 6, 2, 13),
        currencyCode: 'USD',
        nativeAmount: 70);
    // 区间外（半开 [6/2, 6/3) 必须排除）
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 7,
        happenedAt: DateTime(2026, 6, 3));

    final totals = await repo.getDailyTotalsInRange(
        ledgerId: lid,
        start: DateTime(2026, 6, 2),
        end: DateTime(2026, 6, 3));

    // 支出 = 30 + 20 + 70 = 120（transfer 不计、excludeFromStats 计入、nativeAmount 优先）
    expect(totals['2026-06-02'], (100.0, 120.0));
    expect(totals.keys.toList(), ['2026-06-02'],
        reason: '半开区间不得把 6/3 的行并进来');
  });

  test('日合计与「同日各笔 Dart 累加」逐值对拍', () async {
    final lid = await seedLedger('对拍账本');
    final day = DateTime(2026, 6, 5);
    for (final e in [
      ('income', 12.5, null),
      ('income', 7.5, null),
      ('expense', 3.25, null),
      ('transfer', 100.0, null),
    ]) {
      await repo.addTransaction(
        ledgerId: lid,
        type: e.$1,
        amount: e.$2,
        happenedAt: day.add(Duration(hours: 1)),
      );
    }

    // 旧口径（列表里的 Dart 循环）：只计 income/expense，transfer 不计
    final rows = await repo.watchTransactionsWithCategoryAll(ledgerId: lid).first;
    double income = 0, expense = 0;
    for (final it in rows) {
      if (it.t.type == 'income') income += it.t.nativeAmount ?? it.t.amount;
      if (it.t.type == 'expense') expense += it.t.nativeAmount ?? it.t.amount;
    }

    final totals = await repo.getDailyTotalsInRange(
        ledgerId: lid,
        start: DateTime(2026, 6, 5),
        end: DateTime(2026, 6, 6));

    expect(totals['2026-06-05'], (income, expense));
    expect(totals['2026-06-05'], (20.0, 3.25));
  });
}
