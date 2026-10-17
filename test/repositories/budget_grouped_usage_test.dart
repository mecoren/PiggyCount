/// P3 预算去 N+1 的语义守门：批量聚合口径必须与旧的「每预算一条 SQL」一致。
///
/// 关键点：分类预算的用量 = 直接记在该分类的金额 + 直接子分类的金额
/// （分类最多两级，与原 `category_id = ? OR c.parent_id = ?` 同义）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedCategory(String name, {int? parentId}) {
    return db.into(db.categories).insert(CategoriesCompanion.insert(
          name: name,
          kind: 'expense',
          parentId: Value(parentId),
          level: Value(parentId == null ? 1 : 2),
        ));
  }

  test('父分类预算包含子分类，子分类预算只算自己', () async {
    final lid = await db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          monthStartDay: const Value(1),
        ));
    final food = await seedCategory('餐饮');
    final coffee = await seedCategory('咖啡', parentId: food);
    final lunch = await seedCategory('午餐', parentId: food);

    // 直接落两行分类预算（父 / 子），覆盖「一个预算一条 SQL」的旧路径。
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: lid,
          type: const Value('category'),
          categoryId: Value(food),
          amount: 500,
          syncId: Value('b-parent'),
        ));
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: lid,
          type: const Value('category'),
          categoryId: Value(coffee),
          amount: 200,
          syncId: Value('b-child'),
        ));

    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 100,
      categoryId: coffee,
      happenedAt: DateTime(2026, 6, 3),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 50,
      categoryId: lunch,
      happenedAt: DateTime(2026, 6, 4),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 30,
      categoryId: food,
      happenedAt: DateTime(2026, 6, 5),
    );

    final usages = await repo.getCategoryBudgetUsages(lid, DateTime(2026, 6, 10));
    final byCategory = {for (final u in usages) u.categoryId: u.usage.used};

    expect(byCategory[food], 180.0, reason: '父分类 = 自身 30 + 子分类 150');
    expect(byCategory[coffee], 100.0, reason: '子分类预算只算直接记在咖啡的 100');
  });
}
