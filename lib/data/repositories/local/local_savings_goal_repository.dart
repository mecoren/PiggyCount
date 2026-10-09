import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../savings_goal_repository.dart';

const _uuid = Uuid();

/// 本地储蓄目标 Repository 实现（裸 Drift 读写）。
///
/// 与 `LocalBudgetRepository` 同款：这里 **NOT** 直接调 changeTracker ——
/// 注入与 recordChange 统一由 `LocalRepository` 包装层在 CRUD 前后完成
/// （ledger-scoped 实体走 `recordLedgerChange`，ledgerId 必须 > 0）。
class LocalSavingsGoalRepository implements SavingsGoalRepository {
  final PiggyDatabase db;

  LocalSavingsGoalRepository(this.db);

  // ============================================
  // 基础 CRUD
  // ============================================

  @override
  Future<int> createSavingsGoal({
    required int ledgerId,
    required String name,
    required double targetAmount,
    String currency = 'CNY',
    int? accountId,
    double savedAmount = 0,
    DateTime? startDate,
    DateTime? targetDate,
    String? note,
    int sortOrder = 0,
    String? syncId,
  }) async {
    return await db.into(db.savingsGoals).insert(
          SavingsGoalsCompanion.insert(
            ledgerId: ledgerId,
            name: name,
            targetAmount: targetAmount,
            currency: d.Value(currency),
            accountId: d.Value(accountId),
            savedAmount: d.Value(savedAmount),
            startDate: d.Value(startDate ?? DateTime.now()),
            targetDate: d.Value(targetDate),
            note: d.Value(note),
            sortOrder: d.Value(sortOrder),
            syncId: d.Value(syncId ?? _uuid.v4()),
          ),
        );
  }

  @override
  Future<void> updateSavingsGoal(
    int id, {
    String? name,
    double? targetAmount,
    String? currency,
    int? accountId,
    bool clearAccount = false,
    double? savedAmount,
    DateTime? startDate,
    DateTime? targetDate,
    bool clearTargetDate = false,
    String? note,
    bool clearNote = false,
    int? sortOrder,
    String? syncId,
  }) async {
    await (db.update(db.savingsGoals)..where((g) => g.id.equals(id))).write(
      SavingsGoalsCompanion(
        name: name != null ? d.Value(name) : const d.Value.absent(),
        targetAmount:
            targetAmount != null ? d.Value(targetAmount) : const d.Value.absent(),
        currency:
            currency != null ? d.Value(currency) : const d.Value.absent(),
        // 账户模式与手动模式互斥：clearAccount 显式置 NULL（降级为手动模式）
        accountId: clearAccount
            ? const d.Value<int?>(null)
            : (accountId != null ? d.Value(accountId) : const d.Value.absent()),
        savedAmount: savedAmount != null
            ? d.Value(savedAmount)
            : const d.Value.absent(),
        startDate:
            startDate != null ? d.Value(startDate) : const d.Value.absent(),
        targetDate: clearTargetDate
            ? const d.Value<DateTime?>(null)
            : (targetDate != null
                ? d.Value(targetDate)
                : const d.Value.absent()),
        note: clearNote
            ? const d.Value<String?>(null)
            : (note != null ? d.Value(note) : const d.Value.absent()),
        sortOrder:
            sortOrder != null ? d.Value(sortOrder) : const d.Value.absent(),
        // 仅显式传入时回填（导入按业务键命中后补身份锚点），
        // null → absent 避免清掉已有 syncId。
        syncId: syncId != null ? d.Value(syncId) : const d.Value.absent(),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> deleteSavingsGoal(int id) async {
    await (db.delete(db.savingsGoals)..where((g) => g.id.equals(id))).go();
  }

  @override
  Future<void> updateSavingsGoalSavedAmount(int id, double savedAmount) async {
    await (db.update(db.savingsGoals)..where((g) => g.id.equals(id))).write(
      SavingsGoalsCompanion(
        savedAmount: d.Value(savedAmount),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  // ============================================
  // 查询
  // ============================================

  @override
  Future<SavingsGoal?> getSavingsGoal(int id) async {
    return await (db.select(db.savingsGoals)..where((g) => g.id.equals(id)))
        .getSingleOrNull();
  }

  @override
  Future<List<SavingsGoal>> getSavingsGoalsByLedger(int ledgerId) async {
    return await _byLedgerQuery(ledgerId).get();
  }

  @override
  Future<List<SavingsGoal>> getAllSavingsGoals() async {
    return await db.select(db.savingsGoals).get();
  }

  @override
  Stream<List<SavingsGoal>> watchSavingsGoalsByLedger(int ledgerId) {
    return _byLedgerQuery(ledgerId).watch();
  }

  @override
  Future<void> updateSavingsGoalSortOrders(List<SavingsGoal> goals) async {
    await db.transaction(() async {
      for (final goal in goals) {
        await (db.update(db.savingsGoals)..where((g) => g.id.equals(goal.id)))
            .write(SavingsGoalsCompanion(sortOrder: d.Value(goal.sortOrder)));
      }
    });
  }

  @override
  Future<int> clearSavingsGoalAccountRefs(int accountId) async {
    return await (db.update(db.savingsGoals)
          ..where((g) => g.accountId.equals(accountId)))
        .write(const SavingsGoalsCompanion(accountId: d.Value<int?>(null)));
  }

  /// 按账本的统一查询（排序 `sortOrder, id` 保证稳定）。
  d.SimpleSelectStatement<$SavingsGoalsTable, SavingsGoal> _byLedgerQuery(
    int ledgerId,
  ) {
    return db.select(db.savingsGoals)
      ..where((g) => g.ledgerId.equals(ledgerId))
      ..orderBy([
        (g) => d.OrderingTerm(expression: g.sortOrder),
        (g) => d.OrderingTerm(expression: g.id),
      ]);
  }
}
