// E5 性能基准：搜索 SQL 化 / 统计 GROUP BY / v58 查询索引落地后的宿主基线。
//
// 目的：在 SQL 形状稳定后留一份**可重复的数字**。这里只断言两类东西：
//   1. EXPLAIN QUERY PLAN 命中预期索引（环境无关，硬断言）；
//   2. 单次查询 < 5s 的兜底上限（只抓「退化成全表 / 全量内存」的灾难性回归，
//      不做毫秒级硬门，避免 CI 抖动误报）。
// 打印出来的耗时是**宿主 VM + 内存库**参考值，不是设备帧率 / 冷启动基线；
// 设备侧冷启动 / FPS 见 `docs/evidence/perf-baseline-2026-10-05.md` 的采集口径。
import 'package:drift/drift.dart' show OrderingTerm, Value, Variable;
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
  late int ledgerId;
  late List<int> accountIds;
  late List<int> categoryIds;
  late List<int> tagIds;

  const int txCount = 10000;
  const int months = 24;
  // 基准窗口固定为 2026-10：数据均匀铺在 24 个月里，本月约 417 笔。
  final monthStart = DateTime(2026, 10, 1);
  final monthEndExclusive = DateTime(2026, 11, 1);
  final monthEndInclusive = DateTime(2026, 10, 31);

  setUpAll(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);

    ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: 'Benchmark',
        ));

    accountIds = <int>[];
    for (var i = 0; i < 3; i++) {
      accountIds.add(await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              ledgerId: ledgerId,
              name: '账户$i',
            ),
          ));
    }

    categoryIds = <int>[];
    for (var i = 0; i < 10; i++) {
      categoryIds.add(await db.into(db.categories).insert(
            CategoriesCompanion.insert(name: '分类$i', kind: 'expense'),
          ));
    }

    tagIds = <int>[];
    for (var i = 0; i < 5; i++) {
      tagIds.add(await db.into(db.tags).insert(
            TagsCompanion.insert(name: '标签$i'),
          ));
    }

    final start = DateTime(2024, 11, 1);
    final end = DateTime(2026, 11, 1);
    final spanMinutes = end.difference(start).inMinutes;
    await db.batch((batch) {
      for (var i = 0; i < txCount; i++) {
        batch.insert(
          db.transactions,
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: i % 20 == 0 ? 'income' : 'expense',
            amount: (i % 500) + 1.0,
            categoryId: Value(categoryIds[i % categoryIds.length]),
            accountId: Value(accountIds[i % accountIds.length]),
            // 均匀铺满 24 个月（2024-11 ~ 2026-10），保留具体时分秒。
            happenedAt: Value(
                start.add(Duration(minutes: (i * spanMinutes) ~/ txCount))),
            note: Value(i % 5 == 0 ? '咖啡 $i' : '午餐 $i'),
            syncId: Value('bench-$i'),
          ),
        );
      }
    });

    // 20% 的交易挂标签（每 5 笔一笔），用于测标签 EXISTS 子查询。
    // 用真实落库 id 而不是 `i + 1` 推算，避免任何前置行/触发器改变自增起点。
    final txIds = await (db.select(db.transactions)
          ..orderBy([(t) => OrderingTerm(expression: t.id)]))
        .map((t) => t.id)
        .get();
    await db.batch((batch) {
      for (var i = 0; i < txIds.length; i += 5) {
        batch.insert(
          db.transactionTags,
          TransactionTagsCompanion.insert(
            transactionId: txIds[i],
            tagId: tagIds[(i ~/ 5) % tagIds.length],
          ),
        );
      }
    });
  });

  tearDownAll(() async => db.close());

  test('查询索引命中（v58 + 既有复合索引）', () async {
    Future<String> explain(String sql, List<Variable> variables) async {
      final plan = await db
          .customSelect('EXPLAIN QUERY PLAN $sql', variables: variables)
          .get();
      return plan.map((r) => r.data['detail'] as String).join('\n');
    }

    final byType = await explain(
      'SELECT * FROM transactions '
      'WHERE ledger_id = ? AND type = ? AND happened_at >= ? AND happened_at < ?',
      <Variable>[
        Variable<int>(ledgerId),
        const Variable<String>('expense'),
        Variable<DateTime>(monthStart),
        Variable<DateTime>(monthEndExclusive),
      ],
    );
    expect(byType, contains('idx_transactions_ledger_type_happened'),
        reason: '统计/预算共同谓词应命中 v58 复合索引。实际计划:\n$byType');

    final byAccount = await explain(
      'SELECT * FROM transactions WHERE account_id = ?',
      <Variable>[Variable<int>(accountIds.first)],
    );
    expect(byAccount, contains('idx_transactions_account'),
        reason: '账户余额查询应命中 v58 account 索引。实际计划:\n$byAccount');

    final byCategory = await explain(
      'SELECT * FROM transactions WHERE ledger_id = ? AND category_id = ?',
      <Variable>[Variable<int>(ledgerId), Variable<int>(categoryIds.first)],
    );
    expect(byCategory, contains('idx_transactions_ledger_category'),
        reason: '分类聚合应命中 v58 ledger+category 索引。实际计划:\n$byCategory');
  });

  test('SQL 查询耗时基线（宿主 VM 参考，打印 Markdown 表）', () async {
    final rows = <String>[];
    var failures = 0;

    Future<void> bench(String label, Future<void> Function() body) async {
      await body(); // 预热：排除首次 prepare / 页缓存冷启动
      final sw = Stopwatch()..start();
      await body();
      sw.stop();
      rows.add('| $label | ${sw.elapsedMilliseconds} ms |');
      if (sw.elapsedMilliseconds > 5000) {
        failures++;
        // ignore: avoid_print
        print('::warning::$label 超过 5s（${sw.elapsedMilliseconds}ms）');
      }
    }

    await bench('本月收支 SUM（totalsInRange）', () async {
      await repo.totalsInRange(
        ledgerId: ledgerId,
        start: monthStart,
        end: monthEndExclusive,
      );
    });

    await bench('本月分类 GROUP BY（totalsByCategory）', () async {
      await repo.totalsByCategory(
        ledgerId: ledgerId,
        type: 'expense',
        start: monthStart,
        end: monthEndExclusive,
      );
    });

    await bench('本月按天 GROUP BY（getDailyTotalsInRange）', () async {
      await repo.getDailyTotalsInRange(
        ledgerId: ledgerId,
        start: monthStart,
        end: monthEndExclusive,
      );
    });

    await bench('全账户余额单条 GROUP BY（getAllAccountBalances）', () async {
      await repo.getAllAccountBalances(ledgerId);
    });

    await bench('搜索 SQL 下推（关键字 + 日期）', () async {
      await repo
          .watchTransactionsByQuery(
            ledgerId: ledgerId,
            query: TransactionSearchQuery(
              keyword: '咖啡',
              startDate: monthStart,
              endDate: monthEndInclusive,
            ),
          )
          .first;
    });

    await bench('搜索 SQL 下推（标签 EXISTS）', () async {
      await repo
          .watchTransactionsByQuery(
            ledgerId: ledgerId,
            query: TransactionSearchQuery(tagIds: <int>{tagIds.first}),
          )
          .first;
    });

    await bench('月度区间明细（getTransactionsByLedgerInRange）', () async {
      await repo.getTransactionsByLedgerInRange(
        ledgerId: ledgerId,
        start: monthStart,
        end: monthEndExclusive,
      );
    });

    // ignore: avoid_print
    print('\n'
        '### SQL 基线（$txCount 笔 / $months 个月 / 3 账户 / 10 分类 / 5 标签）\n'
        '\n'
        '| 查询 | 宿主耗时 |\n'
        '|---|---|\n'
        '${rows.join('\n')}\n');

    expect(failures, 0, reason: '存在超过 5s 的查询，疑似退化为全表扫描 / 全量内存');
  });
}
