// F2 报表增强的可测核心：标签维度 SQL 聚合 + 环比/同比窗口纯函数。
//
// 钉三件事：
// 1. `totalsByTag` 与单标签的 `getTagStats` **逐值相等** —— 标签维度进了报表，
//    就必须和标签详情页同一个数，否则用户会看到两处不一致的标签统计；
// 2. 口径与既有统计一致：`exclude_from_stats = 0`、`COALESCE(native_amount,
//    amount)`、半开区间 `[start, end)`、多标签分别计入；
// 3. 共享账本 Editor 侧走 `transaction_tag_overrides` 的标签链接不能漏
//    （漏了就是同一笔记账在两个人的报表里数不一样）。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/pages/report/range_report_page.dart';

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

  Future<void> seedLedger({int id = 1, int startDay = 1}) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: d.Value(id),
            name: '账本$id',
            syncId: d.Value('ledger-$id'),
            monthStartDay: d.Value(startDay),
          ));

  /// tags.sync_id 有唯一索引 → syncId 必须逐标签唯一，默认用名字派生。
  Future<int> seedTag(String name, {String? syncId}) =>
      db.into(db.tags).insert(TagsCompanion.insert(
            name: name,
            color: const d.Value('#FF5722'),
            syncId: d.Value(syncId ?? 'tag-$name'),
          ));

  Future<int> seedTx(int ledgerId, double amount,
      {String type = 'expense',
      DateTime? at,
      bool exclude = false,
      double? nativeAmount,
      String? syncId}) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          nativeAmount:
              nativeAmount == null ? const d.Value.absent() : d.Value(nativeAmount),
          excludeFromStats: d.Value(exclude),
          happenedAt: d.Value(at ?? DateTime(2026, 9, 10, 12)),
          syncId: d.Value(syncId ?? 'tx-$amount-${at?.millisecond ?? 0}'),
        ));
  }

  Future<void> tag(int txId, int tagId) =>
      db.into(db.transactionTags).insert(
          TransactionTagsCompanion.insert(
              transactionId: txId, tagId: tagId));

  ({DateTime start, DateTime end}) month(int from, int to) =>
      (start: DateTime(2026, 9, from), end: DateTime(2026, 9, to));

  group('totalsByTag', () {
    test('与 getTagStats 逐值相等（金额 + 笔数）', () async {
      await seedLedger();
      final work = await seedTag('工作');
      final trip = await seedTag('出差');
      final a = await seedTx(1, 120, at: DateTime(2026, 9, 5, 9));
      final b = await seedTx(1, 80, at: DateTime(2026, 9, 20, 9));
      await tag(a, work);
      await tag(b, work);
      await tag(b, trip);

      final rows = await repo.totalsByTag(
          ledgerId: 1, type: 'expense', start: month(1, 30).start, end: month(1, 30).end);
      expect(rows.map((e) => e.name), ['工作', '出差']);
      expect(rows.first.total, 200);
      expect(rows.first.count, 2);

      for (final row in rows) {
        final single = await repo.getTagStats(row.id,
            ledgerId: 1, start: month(1, 30).start, end: month(1, 30).end);
        expect(row.total, single.expense, reason: '标签「${row.name}」两处口径必须一致');
        expect(row.count, single.count);
      }
    });

    test('口径：排除不计入统计、区间半开、按类型过滤、优先 native_amount', () async {
      await seedLedger();
      final t = await seedTag('只此一家', syncId: 'tag-only');
      final excluded = await seedTx(1, 999, exclude: true);
      final beforeRange = await seedTx(1, 500, at: DateTime(2026, 8, 31, 23, 59));
      final firstSecond = await seedTx(1, 10, at: DateTime(2026, 9, 1));
      final lastSecond = await seedTx(1, 20, at: DateTime(2026, 9, 30, 23, 59, 59));
      final income = await seedTx(1, 400, type: 'income', at: DateTime(2026, 9, 15));
      final foreign = await seedTx(1, 100,
          nativeAmount: 700, at: DateTime(2026, 9, 16));
      for (final id in [excluded, beforeRange, firstSecond, lastSecond, income, foreign]) {
        await tag(id, t);
      }

      final rows = await repo.totalsByTag(
          ledgerId: 1,
          type: 'expense',
          start: DateTime(2026, 9, 1),
          end: DateTime(2026, 10, 1));
      // 10 + 20 + 700（native 优先）= 730；不计 exclude / 8.31 / 收入
      expect(rows.single.total, 730);
      expect(rows.single.count, 3);

      final incomeRows = await repo.totalsByTag(
          ledgerId: 1,
          type: 'income',
          start: DateTime(2026, 9, 1),
          end: DateTime(2026, 10, 1));
      expect(incomeRows.single.total, 400);
      expect(incomeRows.single.count, 1);
    });

    test('一笔多标签分别计入，各行之和大于区间总额是口径而非 bug', () async {
      await seedLedger();
      final x = await seedTag('X');
      final y = await seedTag('Y');
      final tx = await seedTx(1, 300);
      await tag(tx, x);
      await tag(tx, y);

      final rows = await repo.totalsByTag(
          ledgerId: 1, type: 'expense', start: month(1, 30).start, end: month(1, 30).end);
      expect(rows.length, 2);
      expect(rows.every((e) => e.total == 300), isTrue);
    });

    test('共享账本 override 标签（Editor 侧）合进同一张报表', () async {
      await seedLedger(id: 7);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(8),
            name: '共享账本',
            syncId: const d.Value('ledger-shared'),
          ));
      await seedTx(8, 66, syncId: 'tx-shared-1');
      await db.into(db.sharedLedgerTags).insert(
            SharedLedgerTagsCompanion.insert(
              ledgerSyncId: 'ledger-shared',
              syncId: 'owner-tag-1',
              name: '房东的标签',
              color: const d.Value('#123456'),
              updatedAt: DateTime(2026, 9, 1),
            ),
          );
      await db.into(db.transactionTagOverrides).insert(
            TransactionTagOverridesCompanion.insert(
              transactionSyncId: 'tx-shared-1',
              tagSyncId: 'owner-tag-1',
              createdAt: DateTime(2026, 9, 2),
            ),
          );

      final rows = await repo.totalsByTag(
          ledgerId: 8, type: 'expense', start: month(1, 30).start, end: month(1, 30).end);
      expect(rows.single.name, '房东的标签');
      expect(rows.single.total, 66);
      // 负 synthetic id：与标签详情页共用同一派生，才能点进详情
      expect(rows.single.id, lessThan(0));
    });

    test('回收站里的交易不带标签行进报表（v44 归档语义）', () async {
      await seedLedger();
      final t = await seedTag('将被归档');
      final tx = await seedTx(1, 55);
      await tag(tx, t);
      expect(
          (await repo.totalsByTag(
                  ledgerId: 1,
                  type: 'expense',
                  start: month(1, 30).start,
                  end: month(1, 30).end))
              .single
              .total,
          55);

      await repo.softDeleteTransaction(tx);
      final after = await repo.totalsByTag(
          ledgerId: 1, type: 'expense', start: month(1, 30).start, end: month(1, 30).end);
      expect(after, isEmpty, reason: '标签行原地保留，但交易本体已不在 transactions 表');
    });
  });

  group('窗口纯函数', () {
    test('环比窗紧邻且等长', () {
      final (s, e) = RangeReportPage.momWindow(
          DateTime(2026, 9, 1), DateTime(2026, 9, 20));
      expect(s, DateTime(2026, 8, 13)); // 19 天窗回退 19 天
      expect(e, DateTime(2026, 9, 1));
      // 变长月份也成立：3 天窗回退 3 天
      expect(
          RangeReportPage.momWindow(DateTime(2026, 3, 1), DateTime(2026, 3, 4)).$1,
          DateTime(2026, 2, 26));
    });

    test('同比窗整窗回退一年，闰日不抛异常', () {
      final (s, e) = RangeReportPage.yoyWindow(
          DateTime(2024, 2, 29), DateTime(2024, 3, 2));
      expect(s, DateTime(2023, 3, 1)); // DateTime 自动进位，不抛
      expect(e, DateTime(2023, 3, 2));
    });

    test('变化率：无上期基准返回 null，负向前值取绝对值', () {
      expect(RangeReportPage.changeRate(120, 100), 0.2);
      expect(RangeReportPage.changeRate(80, 100), closeTo(-0.2, 1e-9));
      expect(RangeReportPage.changeRate(100, 0), isNull);
      expect(RangeReportPage.changeRate(100, 100), 0);
    });

    test('日序列超阈值才按自然月并桶，桶按时间升序', () {
      final days = [
        (day: DateTime(2026, 9, 15), total: 1.0),
        (day: DateTime(2026, 8, 31), total: 2.0),
        (day: DateTime(2026, 9, 2), total: 3.0),
      ];
      final months = RangeReportPage.rollToMonths(days);
      expect(months.length, 2);
      expect(months.first.day, DateTime(2026, 8, 1));
      expect(months.first.total, 2.0);
      expect(months.last.total, 4.0);
      expect(RangeReportPage.dayChartLimit, 31);
    });
  });
}
