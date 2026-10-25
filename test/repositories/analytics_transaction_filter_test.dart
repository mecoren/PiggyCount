import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_transaction_filter.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/utils/transaction_search_filter.dart';

void main() {
  late PiggyDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            name: '筛选测试',
            monthStartDay: const Value(1),
          ),
        );

    Future<void> add(String type, double amount, Map<String, dynamic>? cf) =>
        repo.addTransaction(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          happenedAt: DateTime(2026, 6, 18),
          customValues: cf,
        );

    await add('expense', 10, {'sid_text': '咖啡', 'sid_single': '日常'});
    await add('expense', 20, {'sid_text': '超市', 'sid_single': '日常'});
    await add('income', 30, {'sid_text': '咖啡', 'sid_single': '工资'});
    await add('expense', 40, {'sid_single': '工资'});
    await add('transfer', 50, {'sid_text': '咖啡'});
  });

  tearDown(() async => db.close());

  final filter = AnalyticsTransactionFilter(
    types: {'expense'},
    customFieldConditions: const [
      CustomFieldConditionContains(
        fieldSyncId: 'sid_text',
        fieldName: '商户',
        fieldType: 'text',
        value: '咖',
      ),
    ],
  );

  test('洞察附加筛选在汇总/笔数/日聚合上一致生效', () async {
    final (income, expense) = await repo.totalsInRange(
      ledgerId: ledgerId,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
      filter: filter,
    );
    expect(income, 0);
    expect(expense, 10);

    final count = await repo.countByTypeInRange(
      ledgerId: ledgerId,
      type: 'expense',
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
      filter: filter,
    );
    expect(count, 1);

    final days = await repo.totalsByDay(
      ledgerId: ledgerId,
      type: 'expense',
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
      filter: filter,
    );
    expect(days.fold<double>(0, (sum, d) => sum + d.total), 10);

    final statsRows = await repo.customFieldStatsRows(
      ledgerId: ledgerId,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
      filter: filter,
    );
    expect(statsRows.length, 1);
    expect(
      await repo.customFieldStatsTotalCount(
        ledgerId: ledgerId,
        start: DateTime(2026, 6, 1),
        end: DateTime(2026, 7, 1),
        filter: filter,
      ),
      1,
    );
  });

  test('多选 ANY + 单选条件；月/年聚合占位符不错位', () async {
    const any = AnalyticsTransactionFilter(
      customFieldConditions: [
        CustomFieldConditionAnyOf(
          fieldSyncId: 'sid_single',
          fieldName: '场景',
          fieldType: 'multiSelect',
          values: {'日常'},
        ),
      ],
    );
    final months = await repo.totalsByMonth(
      ledgerId: ledgerId,
      type: 'expense',
      year: 2026,
      filter: any,
    );
    expect(months.fold<double>(0, (sum, m) => sum + m.total), 30);

    final years = await repo.totalsByYearSeries(
      ledgerId: ledgerId,
      type: 'expense',
      filter: any,
    );
    expect(years.fold<double>(0, (sum, y) => sum + y.total), 30);
  });

  test('无筛选与旧调用等价；非法类型不会误命中', () async {
    final (_, allExpense) = await repo.totalsInRange(
      ledgerId: ledgerId,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
    );
    expect(allExpense, 70);

    final (_, none) = await repo.totalsInRange(
      ledgerId: ledgerId,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
      filter: const AnalyticsTransactionFilter(types: {'bogus'}),
    );
    expect(none, 0);
  });
}
