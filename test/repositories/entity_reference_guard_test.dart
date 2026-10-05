/// 实体引用守卫 —— 引用画像 API（`getCategoryRefCounts` / `getAccountRefCounts`）
/// 与账户删除 / 迁移的引用清理。
///
/// **根因**：`db.dart` 里 `categoryId` / `accountId` / `toAccountId` / `ledgerId`
/// 全是裸 `integer()`、没有 `references()`，SQLite 默认不开外键约束
/// ⇒ 悬空引用**不报错、静默丢引用**。所以每个「删除守卫」与「合并清理」点都必须
/// 自己把引用表列全，而既有实现普遍只列了 `transactions`：
///
/// - `getTransactionCountByCategory` 只数交易 ⇒「只被预算引用」或「只被周期规则
///   引用」的分类被判成"无引用"直接删掉。
/// - `getTransactionCountByAccount` 只数交易 ⇒ 周期规则（**活的**引用：账户删掉后
///   规则到期仍会生成新记录）完全不参与守卫，删除时也不清引用。
///
/// 本文件覆盖 4 件事：
/// 1. 分类画像把**四类载体**（交易 / 预算 / 周期规则 / 子分类）都数到，
///    口径与 `LocalRepository.getSyncEntityReferences` 的同名条目一致。
/// 2. 账户画像把**两侧**（`account_id` / `to_account_id`）都数到，且同一行两列
///    同时命中时**只算一次**（旧 API 把两侧 COUNT 相加会算两次）。
/// 3. `deleteAccount` 断开周期规则引用，**但刻意保留**交易的悬空 `account_id`。
/// 4. `migrateAccount` 连周期规则一起搬，且带 tracker 时规则也登记 update
///    （口径：**改写范围 = 登记范围**）。
/// 5. `migrateCategory` / `migrateCategoryTransactions` 同样连预算与周期规则一起搬。
///    其中 5 最凶的是**一级分类迁移**：重名子分类会被合并**删除**，挂在它上面的
///    预算 / 规则当场变悬空 —— 不需要用户再做任何操作就会发生。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

/// 读一条周期规则，断言其两列账户引用
Future<RecurringTransaction> _recurring(PiggyDatabase db, int id) =>
    (db.select(db.recurringTransactions)..where((r) => r.id.equals(id)))
        .getSingle();

/// 读一条预算，断言其分类引用
Future<Budget> _budget(PiggyDatabase db, int id) =>
    (db.select(db.budgets)..where((b) => b.id.equals(id))).getSingle();

void main() {
  // repo.createXxx 内部会 logger.debug(...)（首次使用会建 MethodChannel +
  // 读 SharedPreferences），需要 binding 先初始化并 mock 掉 prefs。
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late int lid;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    lid = await repo.createLedger(name: 'L');
  });

  tearDown(() async => db.close());

  // ===================================================================
  // 1. 分类引用画像
  // ===================================================================

  group('getCategoryRefCounts', () {
    test('四类载体（交易/预算/周期规则/子分类）都数到，且不串台', () async {
      final cat = await repo.createCategory(name: '餐饮', kind: 'expense');
      final other = await repo.createCategory(name: '交通', kind: 'expense');
      final acc = await repo.createAccount(ledgerId: lid, name: 'A');

      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        categoryId: cat,
        accountId: acc,
        happenedAt: DateTime(2026, 1, 1),
      );
      await repo.createBudget(
          ledgerId: lid, type: 'expense', categoryId: cat, amount: 500);
      await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 20,
        categoryId: cat,
        accountId: acc,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );
      await repo.createCategory(
          name: '外卖', kind: 'expense', level: 2, parentId: cat);

      // 对照组：另一个分类也挂上交易 / 预算，验证不串台
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 30,
        categoryId: other,
        accountId: acc,
        happenedAt: DateTime(2026, 1, 2),
      );
      await repo.createBudget(
          ledgerId: lid, type: 'expense', categoryId: other, amount: 800);

      final refs = await repo.getCategoryRefCounts(cat);
      expect(refs.transactions, 1);
      expect(refs.budgets, 1, reason: '旧口径只数 transactions ⇒ 预算引用被漏掉，删分类后预算悬空');
      expect(refs.recurring, 1, reason: '周期规则同样是"删之前必须看一眼"的引用');
      expect(refs.subCategories, 1,
          reason: 'deleteCategory 会连带删直接子分类，子分类数也属于引用画像');

      final otherRefs = await repo.getCategoryRefCounts(other);
      expect(otherRefs.transactions, 1);
      expect(otherRefs.budgets, 1);
      expect(otherRefs.recurring, 0);
      expect(otherRefs.subCategories, 0);
    });

    test('无任何引用的分类返回全 0（守卫据此放行删除）', () async {
      final cat = await repo.createCategory(name: '空分类', kind: 'expense');
      final refs = await repo.getCategoryRefCounts(cat);
      expect(refs.transactions, 0);
      expect(refs.budgets, 0);
      expect(refs.recurring, 0);
      expect(refs.subCategories, 0);
    });
  });

  // ===================================================================
  // 2. 账户引用画像
  // ===================================================================

  group('getAccountRefCounts', () {
    test('两侧引用都数到；同一行两列命中（自转账）只算一次', () async {
      final a = await repo.createAccount(ledgerId: lid, name: 'A');
      final b = await repo.createAccount(ledgerId: lid, name: 'B');

      // A 作为主账户
      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        accountId: a,
        happenedAt: DateTime(2026, 1, 1),
      );
      // A 作为转入账户
      await repo.addTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 20,
        accountId: b,
        toAccountId: a,
        happenedAt: DateTime(2026, 1, 2),
      );
      // 自转账：A 同时是转出与转入（同一行两列命中）
      await repo.addTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 30,
        accountId: a,
        toAccountId: a,
        happenedAt: DateTime(2026, 1, 3),
      );
      // 周期规则：A 作为主账户
      await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 5,
        accountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );

      final refs = await repo.getAccountRefCounts(a);
      expect(refs.transactions, 3,
          reason: '共 3 行交易引用 A。用 OR 一次数清；若按旧 API 那样把两侧 '
              'COUNT 相加，自转账这一行会被算两次（得 4）');
      expect(refs.recurring, 1, reason: '周期规则是独立于交易的引用，旧口径完全不数它');

      final bRefs = await repo.getAccountRefCounts(b);
      expect(bRefs.transactions, 1, reason: 'B 只出现在那笔转账的转出侧');
      expect(bRefs.recurring, 0);
    });
  });

  // ===================================================================
  // 3. deleteAccount 的引用清理
  // ===================================================================

  group('deleteAccount', () {
    test('断开周期规则引用（两列），但保留交易的悬空 account_id', () async {
      final a = await repo.createAccount(ledgerId: lid, name: 'A');
      final b = await repo.createAccount(ledgerId: lid, name: 'B');

      await repo.addTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 10,
        accountId: a,
        happenedAt: DateTime(2026, 1, 1),
      );
      final rMain = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 5,
        accountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );
      final rTo = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 6,
        accountId: b,
        toAccountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );
      final rOther = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 7,
        accountId: b,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );

      await repo.deleteAccount(a);

      final main = await _recurring(db, rMain);
      final to = await _recurring(db, rTo);
      final other = await _recurring(db, rOther);

      expect(main.accountId, isNull,
          reason: '规则是活的：账户删掉后它到期仍会生成新交易，留着悬空 '
              'account_id 会持续产出新的悬空记录');
      expect(to.toAccountId, isNull, reason: '转入侧同样要断');
      expect(to.accountId, b, reason: '只断指向被删账户的那一列');
      expect(other.accountId, b, reason: '不得误伤其他账户的规则');

      final tx = await (db.select(db.transactions)
            ..where((t) => t.accountId.equals(a)))
          .get();
      expect(tx, hasLength(1),
          reason: '交易侧悬空**刻意保留**：确认文案只承诺"交易记录中的账户信息'
              '将被清空"，读取侧按查不到账户兜底渲染；回写 NULL 只会让成千上万'
              '行交易产生无意义的同步噪声，视觉结果完全相同');
      expect(await repo.getAccount(a), isNull, reason: '账户行本身要真删掉');
    });
  });

  // ===================================================================
  // 4. migrateAccount 的引用迁移与登记
  // ===================================================================

  group('migrateAccount', () {
    test('连周期规则一起搬（两列都搬）', () async {
      final a = await repo.createAccount(ledgerId: lid, name: 'A');
      final b = await repo.createAccount(ledgerId: lid, name: 'B');

      final rMain = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 5,
        accountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );
      final rTo = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'transfer',
        amount: 6,
        accountId: b,
        toAccountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );

      await repo.migrateAccount(fromAccountId: a, toAccountId: b);

      expect((await _recurring(db, rMain)).accountId, b,
          reason: '此前只搬交易，规则仍指向旧账户 ⇒ 旧账户一被删就是活的悬空引用');
      expect((await _recurring(db, rTo)).toAccountId, b);
      expect((await _recurring(db, rTo)).accountId, b, reason: '另一列不该被动');
    });

    test('带 tracker：被改写的周期规则也登记 update（改写范围 = 登记范围）', () async {
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);
      final a = await tracked.createAccount(
          ledgerId: lid, name: 'A', syncId: 'acc-mig-a');
      final b = await tracked.createAccount(
          ledgerId: lid, name: 'B', syncId: 'acc-mig-b');
      await tracked.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 5,
        accountId: a,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
        syncId: 'rec-mig-1',
      );

      await tracked.migrateAccount(fromAccountId: a, toAccountId: b);

      final changes = await (db.select(db.localChanges)
            ..where((c) => c.entityType.equals('recurring'))
            ..where((c) => c.entitySyncId.equals('rec-mig-1')))
          .get();
      expect(changes, isNotEmpty, reason: '规则被改写了却没登记 ⇒ 对端仍把规则指向已被合并掉的账户');
      // 审计 T5：写入时 action 统一归一化为 upsert
      expect(changes.every((c) => c.action == 'upsert'), isTrue);
    });
  });

  // ===================================================================
  // 5. 分类迁移的引用迁移与登记
  // ===================================================================

  group('migrateCategory / migrateCategoryTransactions', () {
    test('migrateCategory 连预算与周期规则一起搬', () async {
      final from = await repo.createCategory(name: '餐饮', kind: 'expense');
      final to = await repo.createCategory(name: '吃饭', kind: 'expense');
      final acc = await repo.createAccount(ledgerId: lid, name: 'A');
      final budgetId = await repo.createBudget(
          ledgerId: lid, type: 'expense', categoryId: from, amount: 500);
      final recId = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 20,
        categoryId: from,
        accountId: acc,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );

      await repo.migrateCategory(fromCategoryId: from, toCategoryId: to);

      expect((await _budget(db, budgetId)).categoryId, to,
          reason: '预算与交易引用同一个 category_id，只搬交易就是留下悬空引用');
      expect((await _recurring(db, recId)).categoryId, to);
    });

    test('一级分类迁移：重名子分类被合并删除，其预算/规则当场改指已有子分类', () async {
      final fromParent = await repo.createCategory(name: '餐饮', kind: 'expense');
      final fromSub = await repo.createCategory(
          name: '午餐', kind: 'expense', level: 2, parentId: fromParent);
      final toParent = await repo.createCategory(name: '吃饭', kind: 'expense');
      final toSub = await repo.createCategory(
          name: '午餐', kind: 'expense', level: 2, parentId: toParent);
      final budgetId = await repo.createBudget(
          ledgerId: lid, type: 'expense', categoryId: fromSub, amount: 300);
      final recId = await repo.addRecurringTransaction(
        ledgerId: lid,
        type: 'expense',
        amount: 15,
        categoryId: fromSub,
        frequency: 'monthly',
        interval: 1,
        startDate: DateTime(2026, 1, 1),
      );

      final result = await repo.migrateCategoryTransactions(
          fromCategoryId: fromParent, toCategoryId: toParent);
      expect(result.migratedSubCategories, 0, reason: '前提：走的是"合并"分支');

      expect(await repo.getCategoryById(fromSub), isNull,
          reason: '前提：源子分类已被删除');
      expect((await _budget(db, budgetId)).categoryId, toSub,
          reason: '子分类下一行就被删，不搬就是**当场**产生悬空引用，'
              '不需要用户再做任何操作');
      expect((await _recurring(db, recId)).categoryId, toSub);
    });

    test('一级分类迁移：非重名子分类只换 parentId，其预算/规则 categoryId 不变', () async {
      final fromParent = await repo.createCategory(name: '交通', kind: 'expense');
      final fromSub = await repo.createCategory(
          name: '打车', kind: 'expense', level: 2, parentId: fromParent);
      final toParent = await repo.createCategory(name: '出行', kind: 'expense');
      final budgetId = await repo.createBudget(
          ledgerId: lid, type: 'expense', categoryId: fromSub, amount: 200);

      final result = await repo.migrateCategoryTransactions(
          fromCategoryId: fromParent, toCategoryId: toParent);
      expect(result.migratedSubCategories, 1, reason: '前提：走的是"移位"分支');

      final moved = await repo.getCategoryById(fromSub);
      expect(moved, isNotNull, reason: '移位分支不删子分类');
      expect(moved!.parentId, toParent);
      expect((await _budget(db, budgetId)).categoryId, fromSub,
          reason: '子分类还在、categoryId 没变 ⇒ 不该被改写');
    });

    test('带 tracker：只登记 categoryId 真变了的预算/规则', () async {
      final tracker = ChangeTracker(db);
      final tracked = LocalRepository(db, changeTracker: tracker);

      final fromParent = await tracked.createCategory(
          name: '餐饮', kind: 'expense', syncId: 'cat-from');
      // 重名子分类 → 会被合并删除，其预算是"真被改写"的
      final mergedSub = await tracked.createCategory(
          name: '午餐',
          kind: 'expense',
          level: 2,
          parentId: fromParent,
          syncId: 'cat-sub-merged');
      final toParent = await tracked.createCategory(
          name: '吃饭', kind: 'expense', syncId: 'cat-to');
      // 非重名子分类 → 只换 parentId，其预算不该被登记
      final movedSub = await tracked.createCategory(
          name: '晚餐',
          kind: 'expense',
          level: 2,
          parentId: fromParent,
          syncId: 'cat-sub-moved');

      final mergedBudget = await tracked.createBudget(
          ledgerId: lid,
          type: 'expense',
          categoryId: mergedSub,
          amount: 300,
          syncId: 'budget-merged');
      final movedBudget = await tracked.createBudget(
          ledgerId: lid,
          type: 'expense',
          categoryId: movedSub,
          amount: 200,
          syncId: 'budget-moved');

      final idsBefore =
          (await db.select(db.localChanges).get()).map((c) => c.id).toSet();

      await tracked.migrateCategoryTransactions(
          fromCategoryId: fromParent, toCategoryId: toParent);

      final fresh = (await db.select(db.localChanges).get())
          .where((c) => !idsBefore.contains(c.id))
          .toList();

      expect(fresh.where((c) => c.entityId == mergedBudget), isNotEmpty,
          reason: '被合并删除的子分类其预算 categoryId 改了 ⇒ 必须登记，'
              '否则对端的预算仍挂在已删除的分类上');
      expect(fresh.where((c) => c.entityId == movedBudget), isEmpty,
          reason: '移位子分类的 categoryId 没变 ⇒ 不登记，'
              '否则就是"没改也登记"，与「改写范围 = 登记范围」的口径不符');
    });
  });
}
