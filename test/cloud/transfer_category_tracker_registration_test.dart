// CT-1 守门：`LocalRepository.getTransferCategory()` 末尾的 ChangeTracker
// 登记块只在「注入了 tracker」时执行 —— 生产注入的 `LocalRepository(db)` 不带
// tracker（`lib/providers/database_providers.dart:35-39`，`local_changes`
// 生产恒空）。
//
// 本用例是**唯一**直连该方法的测试，把那块代码从「既不可达也无测试网」变成
// 「有测试网」：断言合并结果（keeper 保留 / dupe 消失 / 引用被改写）与三条登记
// （受影响交易 update、被改写周期规则 update、dupe 分类 delete）。
//
// 为什么值得单独守：合并是**被动**触发的（用户走转账流程才会跑到），一旦这里的
// keeper 选取或改写范围写错，表现是转账记录指向已被删除的分类 —— 静默的引用
// 断裂，比直接抛错更难发现。
//
// 注：`getTransferCategory` 的调用方全是生产路径
// （`database_providers.dart:161`、`category_manage_page.dart:465`、
// `config_export_service.dart:1614`），此前没有任何测试覆盖到这里。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('getTransferCategory 合并重复 transfer 分类并登记三条变更', () async {
    SharedPreferences.setMockInitialValues({});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = LocalRepository(db, changeTracker: ChangeTracker(db));

    final ledgerId = await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const Value('L-tc')));

    // 两条 kind='transfer'：keeper = id 最小的那条（先插的）
    final keeperId = await db.into(db.categories).insert(
        CategoriesCompanion.insert(
            name: '转账',
            kind: 'transfer',
            syncId: const Value('cat-transfer-keeper')));
    final dupeId = await db.into(db.categories).insert(
        CategoriesCompanion.insert(
            name: '测-转账',
            kind: 'transfer',
            syncId: const Value('cat-transfer-dupe')));
    expect(keeperId < dupeId, isTrue, reason: '前提：keeper 是 id 最小的那条');

    // 三类引用 dupe 的载体：交易 / 周期规则 / 预算
    final txId = await db.into(db.transactions).insert(
        TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 12.5,
            categoryId: Value(dupeId),
            syncId: const Value('tx-dup-ref')));
    final recurringId = await db.into(db.recurringTransactions).insert(
        RecurringTransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 30,
            categoryId: Value(dupeId),
            frequency: 'monthly',
            startDate: DateTime.parse('2026-01-01T00:00:00Z'),
            syncId: const Value('rec-dup-ref')));
    final budgetId = await db.into(db.budgets).insert(BudgetsCompanion.insert(
        ledgerId: ledgerId,
        amount: 500,
        categoryId: Value(dupeId),
        syncId: const Value('budget-dup-ref')));

    final keeper = await repo.getTransferCategory();

    expect(keeper.id, keeperId, reason: 'keeper 必须是 id 最小的那条');
    expect(
      await (db.select(db.categories)..where((c) => c.kind.equals('transfer')))
          .get(),
      hasLength(1),
      reason: 'dupe 分类应被删除',
    );

    // 引用被改写：不留指向已删除分类的悬空外键
    final tx = await (db.select(db.transactions)
          ..where((t) => t.id.equals(txId)))
        .getSingle();
    expect(tx.categoryId, keeperId, reason: '交易的分类引用必须搬到 keeper');
    final rec = await (db.select(db.recurringTransactions)
          ..where((r) => r.id.equals(recurringId)))
        .getSingle();
    expect(rec.categoryId, keeperId, reason: '周期规则的分类引用必须搬到 keeper');
    final budget = await (db.select(db.budgets)
          ..where((b) => b.id.equals(budgetId)))
        .getSingle();
    expect(budget.categoryId, keeperId, reason: '预算的分类引用必须搬到 keeper');

    // 登记（ChangeTracker.normalizeAction 把 update 归一成 upsert）
    final changes = await db.select(db.localChanges).get();
    expect(
      changes
          .map((c) =>
              '${c.entityType}|${c.entitySyncId}|${c.action}|${c.ledgerId}')
          .toSet(),
      {
        'transaction|tx-dup-ref|upsert|$ledgerId',
        'recurring|rec-dup-ref|upsert|$ledgerId',
        'category|cat-transfer-dupe|delete|0',
      },
      reason: '交易 / 周期规则 update + dupe 分类 delete 三条缺一不可；'
          'user-global 的分类 delete 必须挂 ledgerId=0',
    );
  });
}
