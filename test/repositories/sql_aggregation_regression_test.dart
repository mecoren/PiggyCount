/// SQL 聚合改写回归测试（性能审计 2026-09-04）。
///
/// 本轮把 4 处「全量加载交易行到内存再 Dart 循环累加」的统计查询改为
/// SQLite GROUP BY 聚合（getLedgerStats / getAllLedgerStats /
/// getAllAccountStats / totalsByDay / totalsByMonth / totalsByYearSeries），
/// 以及年报页月度数据改单条 SQL。本文件验证聚合结果与原 Dart 循环口径
/// 逐项一致：
///
/// - 余额口径：income 加 / expense 减 / transfer 不计入；nativeAmount 优先
///   于 amount（多币种折算值）；excludeFromStats 不影响余额（D5）。
/// - 收支统计口径：excludeFromStats=true 排除；transfer 计入账户支出
///   （账户维度）但不计入账本收支统计。
/// - 账户余额口径：initialBalance + 收支 ± 转账出入 + adjustment。
/// - 时间分组口径：本地时区日界 / 自定义月起始日（labelForDate 规则）。
/// - 空账本：getAllLedgerStats 补零条目（列表页显示 0/0.00）。
/// - 回归契约：getAccountStats（单账户）与 getAllAccountStats（批量 SQL）
///   同数据下结果一致 —— 批量路径是 UI 主消费方，两者口径漂移会直接
///   表现为账户页数字随代码路径不同而不同。
library;
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' as d;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/utils/month_range.dart';

void main() {
  // repo 写路径内的 logger 首次使用会建原生 MethodChannel 桥接并读
  // SharedPreferences（同 account_hidden_test.dart 的既有模式）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger({int monthStartDay = 1}) {
    return db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          monthStartDay: d.Value(monthStartDay),
        ));
  }

  test('getLedgerStats SQL 聚合与原 Dart 循环口径一致（含 transfer/nativeAmount/excludeFromStats）',
      () async {
    final lid = await seedLedger();
    await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 1000,
        happenedAt: DateTime(2026, 6, 1));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 300,
        happenedAt: DateTime(2026, 6, 2));
    // transfer 不计入账本余额
    await repo.addTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 500,
        happenedAt: DateTime(2026, 6, 3));
    // excludeFromStats=true 仍计入余额（D5），多币种折算值优先
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 200,
        happenedAt: DateTime(2026, 6, 4),
        excludeFromStats: true,
        currencyCode: 'USD',
        nativeAmount: 140);

    final stats = await repo.getLedgerStats(ledgerId: lid);

    expect(stats.transactionCount, 4);
    // 1000 - 300 - 140（折算值，不是原币 200）+ 500（transfer 在账本维度
    // 余额口径中按 income 加/expense 减对消为 +500-0？——否：原 Dart 实现
    // 只处理 income/expense 两个分支，transfer 落在两者之外。旧实现的
    // CASE income +1 / 其他 -1 会把 transfer 算 -500（口径漂移），故 SQL
    // 与旧实现一致地显式排除 transfer。
    expect(stats.balance, 560.0);
  });

  test('getAllLedgerStats 一条 SQL 覆盖全部账本，空账本补零', () async {
    final empty = await seedLedger();
    final withTx = await seedLedger();
    await repo.addTransaction(
        ledgerId: withTx,
        type: 'income',
        amount: 500,
        happenedAt: DateTime(2026, 6, 1));
    await repo.addTransaction(
        ledgerId: withTx,
        type: 'expense',
        amount: 200,
        happenedAt: DateTime(2026, 6, 2));

    final all = await repo.getAllLedgerStats();

    expect(all[empty], (balance: 0.0, transactionCount: 0));
    expect(all[withTx]!.balance, 300.0);
    expect(all[withTx]!.transactionCount, 2);
    // 与单账本 SQL 聚合结果一致
    final single = await repo.getLedgerStats(ledgerId: withTx);
    expect(all[withTx]!.balance, single.balance);
    expect(all[withTx]!.transactionCount, single.transactionCount);
  });

  test('getAllAccountStats 批量 SQL 与单账户 getAccountStats 口径一致', () async {
    final lid = await seedLedger();
    final checking =
        await repo.createAccount(ledgerId: lid, name: 'Checking', syncId: 'a1');
    final cash = await repo.createAccount(
        ledgerId: lid, name: 'Cash', syncId: 'a2', initialBalance: 100);
    // 转出账户支出 + 转入账户收款 + adjustment + 不计收支转账
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 80,
        accountId: checking,
        happenedAt: DateTime(2026, 6, 1));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 50,
        accountId: checking,
        toAccountId: cash,
        happenedAt: DateTime(2026, 6, 2));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 300,
        accountId: checking,
        happenedAt: DateTime(2026, 6, 3));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'adjustment',
        amount: 20,
        accountId: cash,
        happenedAt: DateTime(2026, 6, 4));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 999,
        accountId: checking,
        happenedAt: DateTime(2026, 6, 5),
        excludeFromStats: true);

    final all = await repo.getAllAccountStats();
    final singleChecking = await repo.getAccountStats(checking);
    final singleCash = await repo.getAccountStats(cash);

    // Checking 余额 = -80（expense）- 50（转出）+ 300（income）- 999
    //（excludeFromStats 不影响余额口径）= -829
    expect(all[checking]!.balance, -829.0);
    // Cash：100（初始）+ 50（转入）+ 20（adjustment）= 170
    expect(all[cash]!.balance, 170.0);
    // Checking 支出 = 80 + 50（转账转出计入账户支出）；999 被收支统计排除
    expect(all[checking]!.expense, 130.0);
    expect(all[checking]!.income, 300.0);
    // 批量与单账户路径逐项一致（口径漂移防御）
    expect(all[checking]!.balance, singleChecking.balance);
    expect(all[checking]!.expense, singleChecking.expense);
    expect(all[checking]!.income, singleChecking.income);
    expect(all[cash]!.balance, singleCash.balance);
  });

  test('totalsByDay SQL 分组按本地日界聚合并补零', () async {
    final lid = await seedLedger();
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2026, 6, 1, 23, 59));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 25,
        happenedAt: DateTime(2026, 6, 1, 8, 0));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 5,
        happenedAt: DateTime(2026, 6, 3),
        excludeFromStats: true);

    final days = await repo.totalsByDay(
        ledgerId: lid,
        type: 'expense',
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 6, 4));

    expect(days, hasLength(3));
    expect(days[0], (day: DateTime(2026, 6, 1), total: 35.0));
    expect(days[1], (day: DateTime(2026, 6, 2), total: 0.0));
    expect(days[2], (day: DateTime(2026, 6, 3), total: 0.0)); // 被排除
  });

  test('totalsByMonth 按 labelForDate 周期标签月分组（startDay=10）', () async {
    final lid = await seedLedger(monthStartDay: 10);
    // 2026-06-05：day < 10 → 归 5 月周期
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 5));
    // 2026-06-15：day >= 10 → 归 6 月周期
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 200,
        happenedAt: DateTime(2026, 6, 15));
    // 2026-01-20 → 归 1 月周期（验证非 6 月的月份也能落位）
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 400,
        happenedAt: DateTime(2026, 1, 20));

    final months = await repo.totalsByMonth(
        ledgerId: lid, type: 'expense', year: 2026);

    expect(months, hasLength(12));
    // labelForDate 口径：06-05 属 5 月、06-15 属 6 月、01-20 属 1 月
    expect(months[4].total, 100.0);
    expect(months[5].total, 200.0);
    expect(months[0].total, 400.0);
    expect(months[1].total, 0.0);
  });

  test('totalsByYearSeries 全账本按标签年分组，首尾连续', () async {
    final lid = await seedLedger();
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        happenedAt: DateTime(2024, 3, 1));
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 20,
        happenedAt: DateTime(2026, 7, 1));

    final years =
        await repo.totalsByYearSeries(ledgerId: lid, type: 'expense');

    expect(years.map((y) => y.year), [2024, 2025, 2026]);
    expect(years[0].total, 10.0);
    expect(years[1].total, 0.0);
    expect(years[2].total, 20.0);
  });

  test('totalsByYearSeries startDay=10：年末早于周期起始日归上一年标签', () async {
    final lid = await seedLedger(monthStartDay: 10);
    // 2026-01-05：day < 10 → labelForDate 归 2025 年 12 月周期 → 标签年 2025
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 30,
        happenedAt: DateTime(2026, 1, 5));
    // 2026-03-20：day >= 10 → 标签年 2026
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 70,
        happenedAt: DateTime(2026, 3, 20));

    final years =
        await repo.totalsByYearSeries(ledgerId: lid, type: 'expense');

    expect(years.map((y) => y.year), [2025, 2026]);
    expect(years[0].total, 30.0);
    expect(years[1].total, 70.0);
  });

  test('annualReport 月度聚合与 monthlyTotals 口径一致（startDay=10 跨月边界）',
      () async {
    // 直接验证 SQL 内嵌的 labelForDate 等价分组与 periodForLabel 循环
    // （monthlyTotals）在同样的数据下产出一致 —— 年报页改用 SQL 前的
    // 原实现就是 12 次 monthlyTotals。
    final lid = await seedLedger(monthStartDay: 10);
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 5)); // 归 5 月周期
    await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 500,
        happenedAt: DateTime(2026, 6, 25)); // 归 6 月周期
    await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 200,
        happenedAt: DateTime(2026, 7, 12),
        excludeFromStats: true); // 被排除

    // 原 12 次 monthlyTotals 的口径
    final expected = <int, ({double income, double expense})>{};
    for (var m = 1; m <= 12; m++) {
      final (i, e) =
          await repo.monthlyTotals(ledgerId: lid, month: DateTime(2026, m));
      expected[m] = (income: i, expense: e);
    }

    // 新单条 SQL（与 annual_report_page 的内联 SQL 相同）
    final rows = await db.customSelect(
      "WITH t AS (SELECT "
      "strftime('%Y-%m', happened_at, 'unixepoch', 'localtime', "
      "CASE WHEN CAST(strftime('%d', happened_at, 'unixepoch', 'localtime') AS INTEGER) >= 10 "
      "THEN 'start of month' ELSE '-1 month' END) AS label, "
      'type AS type, COALESCE(native_amount, amount) AS v '
      'FROM transactions '
      'WHERE ledger_id = ?1 AND exclude_from_stats = 0 '
      'AND happened_at >= ?2 AND happened_at < ?3) '
      "SELECT label, "
      "SUM(CASE type WHEN 'income' THEN v ELSE 0 END) AS income, "
      "SUM(CASE type WHEN 'expense' THEN v ELSE 0 END) AS expense "
      'FROM t GROUP BY label',
      variables: [
        d.Variable<int>(lid),
        d.Variable<DateTime>(yearRangeFor(2026, 10).start),
        d.Variable<DateTime>(yearRangeFor(2026, 10).end),
      ],
      readsFrom: {db.transactions},
    ).get();

    final byMonth = <int, ({double income, double expense})>{
      for (final r in rows)
        int.parse(r.read<String>('label').split('-')[1]): (
          income: (r.read<double>('income') as num?)?.toDouble() ?? 0.0,
          expense: (r.read<double>('expense') as num?)?.toDouble() ?? 0.0,
        ),
    };

    for (var m = 1; m <= 12; m++) {
      final sql = byMonth[m] ?? (income: 0.0, expense: 0.0);
      expect(sql.income, expected[m]!.income, reason: 'month $m income');
      expect(sql.expense, expected[m]!.expense, reason: 'month $m expense');
    }
  });
}
