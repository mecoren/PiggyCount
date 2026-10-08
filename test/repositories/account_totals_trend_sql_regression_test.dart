/// M14（B9）SQL 聚合改写回归：两处「全表拉进 Dart」改成了 SQLite 聚合，
/// 本文件用**旧实现的逐字移植**当参照，逐值对拍新结果。
///
/// 覆盖口径：
/// - `getAllAccountsTotalStats`：只算 income/expense；排除 transfer/adjustment；
///   排除 `excludeFromStats`；跨账本聚合；account_id 必须指向仍存在的账户行
///   （孤儿 account_id 不计）。
/// - `getAccountDailyBalances`：initial + income − expense − 转出 + 转入 + adjustment；
///   **不排除** `excludeFromStats`；startDate 之前的历史只进基线，不进逐日序列。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

typedef Tx = ({
  int? accountId,
  int? toAccountId,
  String type,
  double amount,
  DateTime happenedAt,
  int ledgerId,
  bool excludeFromStats,
});

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

  Future<int> personalLedger() =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: '个人账本'));

  Future<int> otherLedger() =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: '另一个账本'));

  /// 旧实现的逐字移植：把全部交易拉进内存再累加
  Future<({double totalIncome, double totalExpense})> oldTotals() async {
    final accounts = await db.select(db.accounts).get();
    final accountIds = accounts.map((a) => a.id).toSet();
    final allTxs = await (db.select(db.transactions)
          ..where((t) =>
              t.accountId.isNotNull() & t.excludeFromStats.equals(false)))
        .get();
    double income = 0, expense = 0;
    for (final t in allTxs) {
      if (t.accountId != null && accountIds.contains(t.accountId)) {
        if (t.type == 'income') {
          income += t.amount;
        } else if (t.type == 'expense') {
          expense += t.amount;
        }
      }
    }
    return (totalIncome: income, totalExpense: expense);
  }

  double delta(Tx tx, int accountId) {
    double d = 0;
    if (tx.accountId == accountId) {
      if (tx.type == 'income') d += tx.amount;
      if (tx.type == 'expense') d -= tx.amount;
      if (tx.type == 'transfer') d -= tx.amount;
      if (tx.type == 'adjustment') d += tx.amount;
    }
    if (tx.toAccountId == accountId && tx.type == 'transfer') d += tx.amount;
    return d;
  }

  /// 旧实现的逐字移植：全部历史进内存，先累加基线再逐日填充
  Future<List<({DateTime date, double balance})>> oldDailyBalances(
    int accountId,
    DateTime startDate,
    DateTime endDate,
  ) async {
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingle();
    final endExclusive = DateTime(endDate.year, endDate.month, endDate.day)
        .add(const Duration(days: 1));
    final allTxs = await (db.select(db.transactions)
          ..where((t) =>
              t.accountId.equals(accountId) | t.toAccountId.equals(accountId))
          ..where((t) => t.happenedAt.isSmallerThanValue(endExclusive))
          ..orderBy([(t) => d.OrderingTerm(expression: t.happenedAt)]))
        .get();
    final view = [
      for (final t in allTxs)
        (
          accountId: t.accountId,
          toAccountId: t.toAccountId,
          type: t.type,
          amount: t.amount,
          happenedAt: t.happenedAt,
          ledgerId: t.ledgerId,
          excludeFromStats: t.excludeFromStats,
        )
    ];

    double running = account.initialBalance;
    int i = 0;
    while (i < view.length && view[i].happenedAt.isBefore(startDate)) {
      running += delta(view[i], accountId);
      i++;
    }
    final out = <({DateTime date, double balance})>[];
    var cur = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    while (!cur.isAfter(end)) {
      final next = cur.add(const Duration(days: 1));
      while (i < view.length && view[i].happenedAt.isBefore(next)) {
        running += delta(view[i], accountId);
        i++;
      }
      out.add((date: cur, balance: running));
      cur = next;
    }
    return out;
  }

  /// 灌一份够刁的语料，返回 [普通账本, 另一个账本, 账户 id]
  Future<({int personal, int other, int accountId})> seed() async {
    final personal = await personalLedger();
    final other = await otherLedger();
    final accountId = await repo.createAccount(
        ledgerId: personal, name: '现金', initialBalance: 100);
    final otherAccountId = await repo.createAccount(
        ledgerId: personal, name: '银行卡', initialBalance: 0);

    // 窗口前 / 窗口内 / 窗口后 三个时间段 × 各 type
    Future<void> tx(
      String type,
      double amount,
      DateTime at, {
      int? toAccountId,
      int? ledgerId,
      bool exclude = false,
      int? onAccount,
    }) =>
        repo.addTransaction(
          ledgerId: ledgerId ?? personal,
          type: type,
          amount: amount,
          accountId: onAccount ?? accountId,
          toAccountId: toAccountId,
          happenedAt: at,
          excludeFromStats: exclude,
        );

    // —— 普通账本 ——
    await tx('income', 500, DateTime(2025, 1, 5)); // 窗口前
    await tx('expense', 120, DateTime(2025, 3, 20)); // 窗口前
    await tx('income', 300, DateTime(2025, 4, 2)); // 窗口内
    await tx('expense', 80, DateTime(2025, 4, 3, 10));
    await tx('adjustment', 55.5, DateTime(2025, 4, 4));
    await tx('transfer', 200, DateTime(2025, 4, 5),
        toAccountId: otherAccountId);
    await tx('income', 999, DateTime(2025, 6, 1)); // 窗口后
    await tx('income', 70, DateTime(2025, 4, 6), exclude: true); // 不计收支，计余额
    // —— 另一个账本：跨账本聚合必须计入 ——
    await tx('income', 600, DateTime(2025, 4, 2), ledgerId: other);
    // —— 孤儿 account_id：账户行不存在，两边都不计 ——
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: personal,
          type: 'income',
          amount: 8888,
          accountId: const d.Value(999999),
          happenedAt: d.Value(DateTime(2025, 4, 2)),
        ));
    return (personal: personal, other: other, accountId: accountId);
  }

  test('getAllAccountsTotalStats 与旧 Dart 全量累加逐值相等', () async {
    await seed();

    final fresh = await repo.getAllAccountsTotalStats();
    final old = await oldTotals();

    expect(fresh.totalIncome, closeTo(old.totalIncome, 1e-9), reason: '收入口径漂移');
    expect(fresh.totalExpense, closeTo(old.totalExpense, 1e-9),
        reason: '支出口径漂移');
    // 语料自证：必须真的排掉了 transfer / excludeFromStats / 孤儿账户
    expect(fresh.totalIncome, closeTo(500 + 300 + 999 + 600, 1e-9));
    expect(fresh.totalExpense, closeTo(120 + 80, 1e-9));
  });

  test('getAccountDailyBalances 与旧 Dart 全量累加逐值相等（含跨窗口基线）', () async {
    final s = await seed();
    final start = DateTime(2025, 4, 1);
    final end = DateTime(2025, 4, 7);

    final fresh = await repo.getAccountDailyBalances(s.accountId,
        startDate: start, endDate: end);
    final old = await oldDailyBalances(s.accountId, start, end);

    expect(fresh.map((e) => e.date), old.map((e) => e.date),
        reason: '日期序列必须逐日连续一致');
    for (var i = 0; i < old.length; i++) {
      expect(fresh[i].balance, closeTo(old[i].balance, 1e-9),
          reason:
              '${old[i].date} 余额漂移：新 ${fresh[i].balance} vs 旧 ${old[i].balance}');
    }
    // 语料自证：100 + 500 - 120 = 480 起点，4/2 进 300 与另一个账本的 600、
    // 4/3 减 80、4/4 调整 +55.5、4/5 转出 -200、4/6 不计收支但仍计余额 +70。
    expect(fresh.first.balance, closeTo(480, 1e-9));
    expect(fresh.last.balance,
        closeTo(480 + 300 + 600 - 80 + 55.5 - 200 + 70, 1e-9));
  });
}
