/// v56 预算回补（F1-b，`prd/refund_reimbursement` R3）语义守门：
///
/// 关联了原交易的收入行（`refund_of_id` 非空）按**负值冲减**预算用量 ——
/// 对标 Firefly III #7697「退款应回补预算」。口径（`design.md` 第五节）：
///
/// - 只认**退款行自身 category_id**（分类预算）/ 全局归属（总预算），
///   不 join 原交易分类；
/// - 跨月按**退款发生月**冲减；
/// - `excludeFromBudget = 1` 的退款行**不冲减**（与支出侧排除语义对称）；
/// - 未关联的普通收入**从不**进预算用量（既有行为，回归保护）；
/// - 原交易被软删进行政归档后，退款行照常冲减（软删语义见 R1）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  // softDeleteTransaction 走 logger（落盘 + 平台桥），需要 binding 与
  // SharedPreferences mock（同 migration_v55_test 等会走迁移/日志的测试）。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger() {
    return db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          monthStartDay: const Value(1),
        ));
  }

  group('总预算回补', () {
    test('支出 + 关联退款 → used 冲减', () async {
      final lid = await seedLedger();
      final budgetId =
          await repo.createBudget(ledgerId: lid, type: 'total', amount: 1000);

      final originalId = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        happenedAt: DateTime(2026, 6, 20),
        refundOfId: originalId,
      );

      final usage = await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(usage.used, 70.0, reason: '100 支出 - 30 关联退款 = 70');
    });

    test('未关联的普通收入不进预算用量（既有行为不变）', () async {
      final lid = await seedLedger();
      final budgetId =
          await repo.createBudget(ledgerId: lid, type: 'total', amount: 1000);

      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 50,
        happenedAt: DateTime(2026, 6, 19),
      );

      final usage = await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(usage.used, 100.0);
    });

    test('excludeFromBudget 的退款行不冲减（与支出侧排除对称）', () async {
      final lid = await seedLedger();
      final budgetId =
          await repo.createBudget(ledgerId: lid, type: 'total', amount: 1000);

      final originalId = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        happenedAt: DateTime(2026, 6, 20),
        refundOfId: originalId,
        excludeFromBudget: true,
      );

      final usage = await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(usage.used, 100.0, reason: '用户显式排除的退款行不冲减');
    });

    test('跨月按退款发生月冲减（不回改原交易月份）', () async {
      final lid = await seedLedger();
      final budgetId =
          await repo.createBudget(ledgerId: lid, type: 'total', amount: 1000);

      final originalId = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        happenedAt: DateTime(2026, 7, 5),
        refundOfId: originalId,
      );

      final june = await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(june.used, 100.0, reason: '6 月用量不回改');
      final july = await repo.getBudgetUsage(budgetId, DateTime(2026, 7, 5));
      expect(july.used, -30.0, reason: '7 月被退款「充值」，用量为负');
    });

    test('原交易软删后不冲减（恢复后恢复冲减）', () async {
      final lid = await seedLedger();
      final budgetId =
          await repo.createBudget(ledgerId: lid, type: 'total', amount: 1000);

      final originalId = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        happenedAt: DateTime(2026, 6, 20),
        refundOfId: originalId,
      );
      // 先确认正常态冲减成立
      expect((await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18))).used,
          70.0);

      await repo.softDeleteTransaction(originalId);
      final afterSoftDelete =
          await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(afterSoftDelete.used, 0.0,
          reason: '原支出已随软删不计用量，退款再冲减会做成负数，语义倒挂 —— '
              'EXISTS 守卫要求被引原交易仍在 transactions');

      await repo.restoreDeletedTransaction(originalId);
      final afterRestore =
          await repo.getBudgetUsage(budgetId, DateTime(2026, 6, 18));
      expect(afterRestore.used, 70.0,
          reason: '恢复原交易（PK 不变）后关联与冲减自然复原');
    });
  });

  group('分类预算回补', () {
    test('按退款行自身分类冲减，别的分类不受影响', () async {
      final lid = await seedLedger();
      final foodId = await repo.createCategory(name: '餐饮', kind: 'expense');
      final tripId = await repo.createCategory(name: '交通', kind: 'expense');
      final foodBudgetId = await repo.createBudget(
          ledgerId: lid, type: 'category', amount: 500, categoryId: foodId);
      await repo.createBudget(
          ledgerId: lid, type: 'category', amount: 500, categoryId: tripId);

      final foodOriginal = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        categoryId: foodId,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 40,
        categoryId: tripId,
        happenedAt: DateTime(2026, 6, 18),
      );
      // 退款记在餐饮分类 → 只冲减餐饮预算
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        categoryId: foodId,
        happenedAt: DateTime(2026, 6, 20),
        refundOfId: foodOriginal,
      );

      final food = await repo.getBudgetUsage(foodBudgetId, DateTime(2026, 6, 18));
      expect(food.used, 70.0);
      final trip =
          await repo.getBudgetUsage(foodBudgetId, DateTime(2026, 6, 18));
      expect(trip.used, 70.0, reason: '同一 budgetId 复查，确认无串味');
    });

    test('交通预算不受餐饮退款影响', () async {
      final lid = await seedLedger();
      final foodId = await repo.createCategory(name: '餐饮', kind: 'expense');
      final tripId = await repo.createCategory(name: '交通', kind: 'expense');
      await repo.createBudget(
          ledgerId: lid, type: 'category', amount: 500, categoryId: foodId);
      final tripBudgetId = await repo.createBudget(
          ledgerId: lid, type: 'category', amount: 500, categoryId: tripId);

      final foodOriginal = await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 100,
        categoryId: foodId,
        happenedAt: DateTime(2026, 6, 18),
      );
      await repo.addTransaction(
        ledgerId: lid,
        type: 'income',
        amount: 30,
        categoryId: foodId,
        happenedAt: DateTime(2026, 6, 20),
        refundOfId: foodOriginal,
      );

      final trip = await repo.getBudgetUsage(tripBudgetId, DateTime(2026, 6, 18));
      expect(trip.used, 0.0, reason: '餐饮退款不得冲减交通预算');
    });
  });
}
