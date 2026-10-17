/// P1 搜索 SQL 化守门：条件必须真的下推到 SQL，且语义与旧 Dart 过滤一致。
///
/// 覆盖：关键字（备注 / 金额文本 / 子分类）、分类含子分类、标签、附件、
/// 币种兜底、金额与日期区间、排序。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/transaction_search_query.dart';
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

  Future<int> seedLedger({String currency = 'CNY'}) {
    return db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          currency: Value(currency),
          monthStartDay: const Value(1),
        ));
  }

  Future<int> seedCategory(String name, {int? parentId}) {
    return db.into(db.categories).insert(CategoriesCompanion.insert(
          name: name,
          kind: 'expense',
          parentId: Value(parentId),
          level: Value(parentId == null ? 1 : 2),
        ));
  }

  Future<List<int>> ids(TransactionSearchQuery query) async {
    final rows = await repo.watchTransactionsByQuery(ledgerId: 1, query: query)
        .first;
    return [for (final r in rows) r.t.id];
  }

  test('关键字命中备注 / 金额 / 子分类名', () async {
    final lid = await seedLedger();
    final food = await seedCategory('餐饮');
    final coffee = await seedCategory('咖啡', parentId: food);
    final other = await seedCategory('交通');

    final byNote = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 35,
      categoryId: other,
      happenedAt: DateTime(2026, 5, 1),
      note: '楼下买了杯拿铁',
    );
    final byAmount = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 88.5,
      categoryId: other,
      happenedAt: DateTime(2026, 5, 2),
      note: '打车',
    );
    final byCategory = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 20,
      categoryId: food,
      happenedAt: DateTime(2026, 5, 3),
      note: '早餐',
    );
    // 子分类交易不应被「餐饮」关键字命中（旧 Dart 判定按交易自身分类的显示名）。
    final coffeeTx = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 21,
      categoryId: coffee,
      happenedAt: DateTime(2026, 5, 4),
      note: '拿铁',
    );

    // 关键字：备注
    expect(await ids(const TransactionSearchQuery(keyword: '拿铁')),
        contains(byNote));
    // 关键字：金额文本（旧 Dart 逻辑是 amount.toString().contains）
    expect(await ids(const TransactionSearchQuery(keyword: '88.5')),
        contains(byAmount));
    // 关键字：分类显示名命中（只命中交易自身分类，不含子分类）
    final byCategoryIds = await ids(TransactionSearchQuery(
      keyword: '餐饮',
      keywordCategoryIds: [food],
    ));
    expect(byCategoryIds, contains(byCategory));
    expect(byCategoryIds, isNot(contains(coffeeTx)));
  });

  test('分类筛选包含直接子分类', () async {
    final lid = await seedLedger();
    final food = await seedCategory('餐饮');
    final coffee = await seedCategory('咖啡', parentId: food);
    final transport = await seedCategory('交通');

    final child = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 20,
      categoryId: coffee,
      happenedAt: DateTime(2026, 5, 1),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 30,
      categoryId: transport,
      happenedAt: DateTime(2026, 5, 2),
    );

    expect(await ids(TransactionSearchQuery(categoryId: food)), [child]);
  });

  test('标签筛选：命中任意一个', () async {
    final lid = await seedLedger();
    final tagA = await repo.createTag(name: '出差');
    final tagB = await repo.createTag(name: '报销');

    final tagged = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      happenedAt: DateTime(2026, 5, 1),
      note: '高铁',
    );
    await repo.addTagsToTransaction(transactionId: tagged, tagIds: [tagB]);
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 11,
      happenedAt: DateTime(2026, 5, 2),
      note: '地铁',
    );

    expect(await ids(TransactionSearchQuery(tagIds: {tagA, tagB})), [tagged]);
  });

  test('附件筛选：有 / 无', () async {
    final lid = await seedLedger();
    final withAttachment = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      happenedAt: DateTime(2026, 5, 1),
    );
    final without = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 11,
      happenedAt: DateTime(2026, 5, 2),
    );
    await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
            transactionId: withAttachment,
            fileName: 'receipt.jpg',
          ),
        );

    expect(await ids(const TransactionSearchQuery(hasAttachment: true)),
        [withAttachment]);
    expect(await ids(const TransactionSearchQuery(hasAttachment: false)),
        [without]);
  });

  test('币种：未记币种按账本本位币兜底', () async {
    final lid = await seedLedger(currency: 'CNY');
    final fallback = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      happenedAt: DateTime(2026, 5, 1),
    );
    final usd = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      happenedAt: DateTime(2026, 5, 2),
      currencyCode: 'USD',
    );

    expect(
      await ids(const TransactionSearchQuery(
          currencyCode: 'cny', ledgerCurrency: 'CNY')),
      [fallback],
    );
    expect(
      await ids(const TransactionSearchQuery(
          currencyCode: 'USD', ledgerCurrency: 'CNY')),
      [usd],
    );
  });

  test('金额 / 日期区间 + 倒序', () async {
    final lid = await seedLedger();
    final a = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 10,
      happenedAt: DateTime(2026, 5, 1, 9),
    );
    final b = await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: -50,
      happenedAt: DateTime(2026, 5, 2, 23, 59),
    );
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 100,
      happenedAt: DateTime(2026, 5, 3),
    );

    final rows = await repo.watchTransactionsByQuery(
      ledgerId: lid,
      query: TransactionSearchQuery(
        minAmount: 9,
        maxAmount: 60,
        startDate: DateTime(2026, 5, 1),
        endDate: DateTime(2026, 5, 2),
      ),
    ).first;

    expect([for (final r in rows) r.t.id], [b, a], reason: '金额取绝对值 + 日期含结束日全天');
  });

  test('v58：新装库 onCreate 建齐查询索引', () async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type = 'index'")
        .get();
    final names = {for (final r in rows) r.read<String>('name')};

    expect(names, contains('idx_transactions_ledger_type_happened'));
    expect(names, contains('idx_transactions_account'));
    expect(names, contains('idx_transactions_to_account'));
    expect(names, contains('idx_transactions_ledger_category'));
    expect(names, contains('idx_budgets_ledger_type_enabled_category'));
    expect(names, contains('idx_deleted_transactions_ledger_deleted'));
  });
}
