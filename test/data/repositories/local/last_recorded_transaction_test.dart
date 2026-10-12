/// `TransactionRepository.getLastRecordedTransaction` 契约测试。
///
/// 语义：记账抽屉右上角「带出上一笔」要按**本机录入时刻**（`transactions.
/// created_at`）取同账本、**同类型**最近录入的一笔整行，供 UI 装填除金额外的
/// 全部字段。与 `getRecentEntryDefaults`（5 分钟窗口继承分类＋账户）同源，唯一
/// 差别是**没有时间窗**（上一笔是十天前的也能带出）。
///
/// 边界（本文件逐条钉住）：
/// - 按 `created_at` 排序，**不是** `happened_at`：补记历史账单（发生时间设为
///   过去）后，「上一笔」仍是刚录入的那笔；
/// - 同账本、同类型隔离：支出不带出收入，别的账本不参与；
/// - `created_at` 为 NULL 的行（批量导入 / 云恢复）不参与；
/// - 周期模板自动生成的行（`recurring_id` 非空）不作来源，会继续前溯；
/// - 无匹配返回 `null`（调用方据此不渲染按钮）。
///
/// 索引断言用仓库导出的同一份 SQL（`lastRecordedTransactionSql`），而不是在测试
/// 里另抄字面量 —— 否则改仓库 SQL（比如退回全表扫）就能骗过测试。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/data/repositories/local/local_transaction_repository.dart';

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

  /// 直接落一行交易：录入时刻与发生时间**分别**可控（这是本组用例的核心变量）。
  Future<int> seedTx({
    int ledgerId = 1,
    required String type,
    required DateTime? createdAt,
    DateTime? happenedAt,
    double amount = 10,
    int? categoryId,
    int? accountId,
    int? recurringId,
    String? note,
    String? currencyCode,
    String? customValuesJson,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
  }) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          recurringId: d.Value(recurringId),
          createdAt: d.Value(createdAt),
          happenedAt: d.Value(happenedAt ?? createdAt ?? now),
          note: d.Value(note),
          currencyCode: d.Value(currencyCode),
          customValuesJson: d.Value(customValuesJson),
          excludeFromStats: d.Value(excludeFromStats),
          excludeFromBudget: d.Value(excludeFromBudget),
        ));
  }

  group('取数命中与隔离', () {
    test('返回整行：分类 / 账户 / 备注 / 开关 / 币种 / 自定义字段都在', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      await seedTx(
        type: 'expense',
        createdAt: now,
        categoryId: food,
        accountId: cash,
        amount: 38.5,
        note: '午饭',
        currencyCode: 'USD',
        customValuesJson: jsonEncode({'f-1': 'A店'}),
        excludeFromStats: true,
        excludeFromBudget: true,
      );

      final row =
          await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense');

      expect(row, isNotNull);
      expect(row!.categoryId, food);
      expect(row.accountId, cash);
      expect(row.note, '午饭');
      expect(row.currencyCode, 'USD');
      expect(row.customValuesJson, jsonEncode({'f-1': 'A店'}));
      expect(row.excludeFromStats, isTrue);
      expect(row.excludeFromBudget, isTrue);
    });

    test('同类型取录入时刻最新的一笔', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(days: 3)),
        categoryId: food,
      );
      await seedTx(
        type: 'expense',
        createdAt: now,
        categoryId: traffic,
      );

      final row =
          await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense');

      expect(row!.categoryId, traffic);
    });

    test('按 created_at 而非 happened_at：补记的旧账单仍然是「上一笔」', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final backfill = await repo.createCategory(name: '房租', kind: 'expense');
      // 先录的一笔（发生时间就是录入时刻）。
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 30)),
        happenedAt: now.subtract(const Duration(minutes: 30)),
        categoryId: food,
      );
      // 后录的一笔，但发生时间被用户改成去年（补记）。
      await seedTx(
        type: 'expense',
        createdAt: now,
        happenedAt: DateTime(2025, 3, 1),
        categoryId: backfill,
      );

      final row =
          await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense');

      expect(row!.categoryId, backfill,
          reason: '排序按本机录入时刻，补记历史账单不得被排除在外');
    });

    test('无时间窗：十天前录入的一笔仍可作为「上一笔」', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(days: 10)),
        categoryId: food,
      );

      final row =
          await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense');

      expect(row!.categoryId, food,
          reason: '与 5 分钟窗口的 getRecentEntryDefaults 语义不同');
    });

    test('类型隔离：收入不影响支出，支出不影响收入', () async {
      final salary = await repo.createCategory(name: '工资', kind: 'income');
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 2)),
        categoryId: food,
      );
      await seedTx(
        type: 'income',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: salary,
      );

      expect(
        (await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense'))!
            .categoryId,
        food,
      );
      expect(
        (await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'income'))!
            .categoryId,
        salary,
      );
    });

    test('账本隔离：别的账本的最近一笔不参与', () async {
      await seedTx(
        ledgerId: 2,
        type: 'expense',
        createdAt: now,
      );

      expect(
        await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense'),
        isNull,
      );
    });

    test('该类型没有任何录入：返回 null（按钮不渲染）', () async {
      await seedTx(type: 'transfer', createdAt: now);

      expect(
        await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense'),
        isNull,
      );
    });
  });

  group('来源边界', () {
    test('created_at 为 NULL（批量导入 / 云恢复）不作来源', () async {
      await seedTx(type: 'expense', createdAt: null);

      expect(
        await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense'),
        isNull,
      );
    });

    test('周期模板生成的行不作来源，继续前溯到普通录入', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final rent = await repo.createCategory(name: '房租', kind: 'expense');
      // 更新的一笔是周期模板生成（recurringId 非空）。
      await seedTx(
        type: 'expense',
        createdAt: now,
        categoryId: rent,
        recurringId: 7,
      );
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 5)),
        categoryId: food,
      );

      final row =
          await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense');

      expect(row!.categoryId, food);
    });

    test('录入时刻相同时按 id 倒序：后写入的优先', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');
      await seedTx(type: 'expense', createdAt: now, categoryId: food);
      await seedTx(type: 'expense', createdAt: now, categoryId: traffic);

      expect(
        (await repo.getLastRecordedTransaction(ledgerId: 1, kind: 'expense'))!
            .categoryId,
        traffic,
      );
    });
  });

  group('索引', () {
    test('查询命中 idx_transactions_ledger_created，且不是全表扫', () async {
      final plan = await db.customSelect(
        'EXPLAIN QUERY PLAN $lastRecordedTransactionSql',
        variables: [
          d.Variable<int>(1),
          d.Variable<String>('expense'),
        ],
      ).get();
      final planText = plan.map((r) => r.data['detail'] as String).join('\n');

      expect(
        planText,
        contains('idx_transactions_ledger_created'),
        reason: '取上一笔必须命中复合索引。实际计划:\n$planText',
      );
      expect(
        planText,
        isNot(contains('SCAN transactions')),
        reason: '不得退化成全表扫描。实际计划:\n$planText',
      );
      expect(
        planText,
        isNot(contains('TEMP B-TREE')),
        reason: 'ORDER BY 应由索引直接满足，不得建临时排序树。实际计划:\n$planText',
      );
    });
  });
}
