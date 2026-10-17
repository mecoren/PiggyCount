/// 设备真实引擎上的搜索 SQL 下推回归（E2）。
///
/// 与 `test/data/transaction_search_query_test.dart`（宿主 VM）分工：
/// 宿主测试守条件拼装逻辑，这里守**设备实际加载的 SQLite 引擎**
/// （Android 下是 jniLibs 里的 `libsqlcipher.so`）上同样把条件下推、
/// LIKE 转义与日期半开区间按预期工作。
///
/// 运行：
/// ```
/// flutter test integration_test/search_sql_device_test.dart -d <device>
/// ```
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/transaction_search_query.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  Future<int> seedTx({
    required String note,
    required double amount,
    required DateTime happenedAt,
    int? categoryId,
  }) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: amount,
          note: d.Value(note),
          happenedAt: d.Value(happenedAt),
          categoryId: d.Value(categoryId),
        ));
  }

  testWidgets('搜索条件在设备引擎上真的下推（关键字 / 分类 / 日期 / 金额 / 标签）',
      (tester) async {
    final food = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    final coffee = await seedTx(
      note: '下午咖啡',
      amount: 28,
      happenedAt: DateTime(2026, 10, 1, 15),
      categoryId: food,
    );
    await seedTx(
      note: '地铁',
      amount: 6,
      happenedAt: DateTime(2026, 10, 2, 8),
    );
    await seedTx(
      note: '超市',
      amount: 120,
      happenedAt: DateTime(2026, 9, 30, 20),
    );

    // 1) 关键字命中的是备注。
    var rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: const TransactionSearchQuery(keyword: '咖啡'),
        )
        .first;
    expect(rows.map((r) => r.t.id), <int>[coffee]);

    // 2) 关键字也能命中分类名（JOIN 下推，不是 Dart 二次过滤）。
    rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: const TransactionSearchQuery(keyword: '餐饮'),
        )
        .first;
    expect(rows.map((r) => r.t.id), <int>[coffee]);

    // 3) 日期是半开区间：10/1 00:00 ≤ t < 10/3 00:00。
    rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: TransactionSearchQuery(
            startDate: DateTime(2026, 10, 1),
            endDate: DateTime(2026, 10, 2),
          ),
        )
        .first;
    expect(rows.length, 2, reason: '10/1 与 10/2 两笔，9/30 那笔必须被剪掉');

    // 4) 分类：自身及其直接子分类。
    rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: TransactionSearchQuery(categoryId: food),
        )
        .first;
    expect(rows.map((r) => r.t.id), <int>[coffee]);

    // 5) 金额按绝对值闭区间。
    rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: const TransactionSearchQuery(minAmount: 100),
        )
        .first;
    expect(rows.single.t.note, '超市');

    // 6) 标签：EXISTS 子查询命中 transaction_tags 索引。
    final tagId = await db
        .into(db.tags)
        .insert(TagsCompanion.insert(name: '测试标签'));
    await db.into(db.transactionTags).insert(
        TransactionTagsCompanion.insert(transactionId: coffee, tagId: tagId));
    rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: TransactionSearchQuery(tagIds: <int>{tagId}),
        )
        .first;
    expect(rows.map((r) => r.t.id), <int>[coffee]);
  });

  testWidgets('LIKE 通配符按字面量转义（`%` 不放大匹配面）', (tester) async {
    final percent = await seedTx(
      note: '折扣 50%',
      amount: 10,
      happenedAt: DateTime(2026, 10, 1),
    );
    await seedTx(
      note: '普通消费',
      amount: 10,
      happenedAt: DateTime(2026, 10, 1),
    );

    final rows = await repo
        .watchTransactionsByQuery(
          ledgerId: 1,
          query: const TransactionSearchQuery(keyword: '%'),
        )
        .first;
    expect(rows.map((r) => r.t.id), <int>[percent],
        reason: '% 必须当普通字符，而不是匹配所有行');
  });
}
