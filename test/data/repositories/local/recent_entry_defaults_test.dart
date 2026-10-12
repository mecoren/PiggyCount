/// `TransactionRepository.getRecentEntryDefaults` 契约测试。
///
/// 语义：记账页要支持「5 分钟内再次记账，默认继承上一笔的分类与账户」。
/// 窗口按 `transactions.created_at`（**本设备录入时刻**）判定，而不是
/// `happened_at` —— 用户可以把发生日期改成昨天（补记历史账单），按发生时间
/// 判会让整批补记都不继承。按**类型**分别取最近一笔：支出找支出、收入找收入，
/// 转账不参与。
///
/// 继承源的边界（本文件逐条钉住）：
/// - 批量导入 / 云恢复 / 周期模板生成的行 `created_at` 为 NULL，不参与；
/// - 周期模板生成的行即便有 created_at（理论上不会）也由 `recurring_id` 兜住；
/// - 上一笔的分类 / 账户为空时**不继续前溯**（返回空值记录，由调用方回退默认）。
///
/// 索引断言用仓库导出的同一份 SQL（`recentEntryDefaultsSql`），而不是在测试里
/// 另抄字面量 —— 否则改仓库 SQL（比如退回全表扫）就能骗过测试。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/data/repositories/local/local_transaction_repository.dart';
import 'package:piggycount/data/repositories/transaction_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  /// 固定的「现在」，避免测试依赖真实墙钟。
  final now = DateTime(2026, 10, 12, 12, 0, 0);

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (2, 'L2', 'CNY')");
  });

  tearDown(() async => db.close());

  /// 直接落一行交易，可显式指定录入时刻 / 周期来源 / 空值。
  Future<int> seedTx({
    int ledgerId = 1,
    required String type,
    required DateTime? createdAt,
    int? categoryId,
    int? accountId,
    int? recurringId,
  }) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: 10,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          recurringId: d.Value(recurringId),
          createdAt: d.Value(createdAt),
          happenedAt: d.Value(createdAt ?? now),
          originalAmount: const d.Value(10),
        ));
  }

  Future<Object?> readCreatedAt(int id) async {
    final row = await db
        .customSelect('SELECT created_at FROM transactions WHERE id = ?',
            variables: [d.Variable<int>(id)])
        .getSingle();
    return row.data['created_at'];
  }

  group('窗口命中与类型隔离', () {
    test('窗口内的同类型交易：分类与账户一并返回', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
        accountId: cash,
      );

      final defaults = await repo.getRecentEntryDefaults(
          ledgerId: 1, kind: 'expense', now: now);

      expect(defaults, isNotNull);
      expect(defaults!.categoryId, food);
      expect(defaults.accountId, cash);
    });

    test('恰好 5 分钟（边界含）仍命中', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 5)),
        categoryId: food,
      );

      expect(
        (await repo.getRecentEntryDefaults(
                ledgerId: 1, kind: 'expense', now: now))
            ?.categoryId,
        food,
      );
    });

    test('超过 5 分钟不参与（返回 null）', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 5, seconds: 1)),
        categoryId: food,
      );

      expect(
        await repo.getRecentEntryDefaults(
            ledgerId: 1, kind: 'expense', now: now),
        isNull,
      );
    });

    test('按类型隔离：收入只看收入，支出只看支出', () async {
      final salary = await repo.createCategory(name: '工资', kind: 'income');
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final acctA = await repo.createAccount(ledgerId: 1, name: 'A');
      final acctB = await repo.createAccount(ledgerId: 1, name: 'B');
      // 更新的一笔是收入。
      await seedTx(
        type: 'income',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: salary,
        accountId: acctA,
      );
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 2)),
        categoryId: food,
        accountId: acctB,
      );

      final expense = await repo.getRecentEntryDefaults(
          ledgerId: 1, kind: 'expense', now: now);
      expect(expense!.categoryId, food);
      expect(expense.accountId, acctB);

      final income = await repo.getRecentEntryDefaults(
          ledgerId: 1, kind: 'income', now: now);
      expect(income!.categoryId, salary);
      expect(income.accountId, acctA);
    });

    test('同类型取录入时刻最新的一笔', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 3)),
        categoryId: food,
      );
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: traffic,
      );

      expect(
        (await repo.getRecentEntryDefaults(
                ledgerId: 1, kind: 'expense', now: now))
            ?.categoryId,
        traffic,
      );
    });

    test('账本隔离：别的账本的最近一笔不参与', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        ledgerId: 2,
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
      );

      expect(
        await repo.getRecentEntryDefaults(
            ledgerId: 1, kind: 'expense', now: now),
        isNull,
      );
    });
  });

  group('继承源边界', () {
    test('created_at 为 NULL（批量导入 / 云恢复）不参与', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(type: 'expense', createdAt: null, categoryId: food);

      expect(
        await repo.getRecentEntryDefaults(
            ledgerId: 1, kind: 'expense', now: now),
        isNull,
      );
    });

    test('周期模板生成的行不作继承源，但会继续前溯到普通录入', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final rent = await repo.createCategory(name: '房租', kind: 'expense');
      // 更新的一笔是周期模板生成（recurringId 非空）。
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: rent,
        recurringId: 7,
      );
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 2)),
        categoryId: food,
      );

      expect(
        (await repo.getRecentEntryDefaults(
                ledgerId: 1, kind: 'expense', now: now))
            ?.categoryId,
        food,
      );
    });

    test('上一笔分类与账户都为空：返回空值记录，不继续前溯', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 2)),
        categoryId: food,
      );
      // 更新的一笔没选分类 / 账户。
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
      );

      final defaults = await repo.getRecentEntryDefaults(
          ledgerId: 1, kind: 'expense', now: now);

      expect(defaults, isNotNull, reason: '命中窗口，只是值为空');
      expect(defaults!.categoryId, isNull);
      expect(defaults.accountId, isNull);
    });

    test('窗口内只有转账：不参与（返回 null）', () async {
      final acctA = await repo.createAccount(ledgerId: 1, name: 'A');
      final acctB = await repo.createAccount(ledgerId: 1, name: 'B');
      await seedTx(
        type: 'transfer',
        createdAt: now.subtract(const Duration(minutes: 1)),
        accountId: acctA,
      );
      await seedTx(
        type: 'transfer',
        createdAt: now.subtract(const Duration(minutes: 2)),
        accountId: acctB,
      );

      expect(
        await repo.getRecentEntryDefaults(
            ledgerId: 1, kind: 'expense', now: now),
        isNull,
      );
    });
  });

  group('录入时刻的写入点', () {
    test('addTransaction（用户交互式单笔录入）写入 created_at', () async {
      final before = DateTime.now().subtract(const Duration(seconds: 5));
      final id = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 12,
        happenedAt: DateTime(2020, 1, 1), // 发生时间可以是过去
      );

      final raw = await readCreatedAt(id);
      expect(raw, isNotNull, reason: '单笔录入必须写入本设备录入时刻');
      final createdAt = DateTime.fromMillisecondsSinceEpoch((raw! as int) * 1000);
      expect(createdAt.isAfter(before), isTrue,
          reason: '录入时刻应接近当前时间，与 happenedAt 无关');
    });

    test('insertTransactionsBatch（导入 / 恢复）不写 created_at', () async {
      final id = await repo.insertTransactionsBatch([
        TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 12,
          originalAmount: const d.Value(12),
        ),
      ]);

      expect(await readCreatedAt(id), isNull);
    });
  });

  group('索引', () {
    test('查询命中 idx_transactions_ledger_created，且不是全表扫', () async {
      final plan = await db.customSelect(
        'EXPLAIN QUERY PLAN $recentEntryDefaultsSql',
        variables: [
          d.Variable<int>(1),
          d.Variable<DateTime>(now.subtract(const Duration(minutes: 5))),
          d.Variable<int>(100),
        ],
      ).get();
      final planText = plan.map((r) => r.data['detail'] as String).join('\n');

      expect(
        planText,
        contains('idx_transactions_ledger_created'),
        reason: '窗口查询必须命中复合索引。实际计划:\n$planText',
      );
      expect(
        planText,
        isNot(contains('SCAN transactions')),
        reason: '不得退化成全表扫描。实际计划:\n$planText',
      );
    });

    test('窗口常量是 5 分钟（唯一来源）', () {
      expect(kRecentEntryInheritWindow, const Duration(minutes: 5));
    });
  });
}
