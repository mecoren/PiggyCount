// #461 标签详情页按 月/年/全部 时间维度筛选:
// getTagStats / watchTransactionsByTag 增加可选 [start, end) 半开区间过滤。
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';

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

  Future<int> seedLedger() {
    return db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          monthStartDay: const Value(1),
        ));
  }

  /// 造一笔带标签的交易,返回交易 id。
  Future<int> seedTaggedTx({
    required int ledgerId,
    required int tagId,
    required DateTime happenedAt,
    String type = 'expense',
    double amount = 100,
    bool excludeFromStats = false,
    String? currencyCode,
    double? nativeAmount,
  }) async {
    final txId = await repo.addTransaction(
      ledgerId: ledgerId,
      type: type,
      amount: amount,
      happenedAt: happenedAt,
      excludeFromStats: excludeFromStats,
      currencyCode: currencyCode,
      nativeAmount: nativeAmount,
    );
    await repo.addTagToTransaction(transactionId: txId, tagId: tagId);
    return txId;
  }

  test('getTagStats 带 [start,end) 只统计范围内交易,边界半开', () async {
    final lid = await seedLedger();
    final tagId = await repo.createTag(name: '旅行');

    // 范围外(5 月末)
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 5, 31), amount: 1);
    // == start,应计入
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 6, 1), amount: 10);
    // 范围内收入
    await seedTaggedTx(
        ledgerId: lid,
        tagId: tagId,
        happenedAt: DateTime(2026, 6, 15),
        type: 'income',
        amount: 200);
    // == end,不计入
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 7, 1), amount: 1000);

    final stats = await repo.getTagStats(
      tagId,
      ledgerId: lid,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
    );

    expect(stats.count, 2);
    expect(stats.expense, 10.0);
    expect(stats.income, 200.0);
  });

  test('getTagStats 不带范围仍返回全量(回归)', () async {
    final lid = await seedLedger();
    final tagId = await repo.createTag(name: '旅行');
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2006, 1, 1), amount: 7);
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 6, 1), amount: 3);

    final stats = await repo.getTagStats(tagId, ledgerId: lid);

    expect(stats.count, 2);
    expect(stats.expense, 10.0);
  });

  test('getTagStats 范围内 excludeFromStats 金额仍被排除,笔数照常', () async {
    final lid = await seedLedger();
    final tagId = await repo.createTag(name: '旅行');
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 6, 2), amount: 100);
    await seedTaggedTx(
        ledgerId: lid,
        tagId: tagId,
        happenedAt: DateTime(2026, 6, 3),
        amount: 500,
        excludeFromStats: true);

    final stats = await repo.getTagStats(
      tagId,
      ledgerId: lid,
      start: DateTime(2026, 6, 1),
      end: DateTime(2026, 7, 1),
    );

    expect(stats.count, 2);
    expect(stats.expense, 100.0);
  });

  test('watchTransactionsByTag 带 [start,end) 只返回范围内交易', () async {
    final lid = await seedLedger();
    final tagId = await repo.createTag(name: '旅行');
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 5, 31));
    final inRangeId = await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 6, 15));
    await seedTaggedTx(
        ledgerId: lid, tagId: tagId, happenedAt: DateTime(2026, 7, 1));

    final list = await repo
        .watchTransactionsByTag(
          tagId,
          ledgerId: lid,
          start: DateTime(2026, 6, 1),
          end: DateTime(2026, 7, 1),
        )
        .first;

    expect(list.map((t) => t.id).toList(), [inRangeId]);
  });

  test('watchTransactionsByTag 返回完整字段(currencyCode/nativeAmount)', () async {
    final lid = await seedLedger();
    final tagId = await repo.createTag(name: '旅行');
    await seedTaggedTx(
      ledgerId: lid,
      tagId: tagId,
      happenedAt: DateTime(2026, 6, 15),
      amount: 100,
      currencyCode: 'USD',
      nativeAmount: 720,
    );

    final list = await repo.watchTransactionsByTag(tagId, ledgerId: lid).first;

    expect(list, hasLength(1));
    expect(list.single.currencyCode, 'USD');
    expect(list.single.nativeAmount, 720.0);
  });

}
