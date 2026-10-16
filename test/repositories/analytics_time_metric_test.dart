/// 洞察页「统计时间口径」（记账时间 / 日期型自定义字段）回归。
///
/// 口径的唯一真相源是 [AnalyticsTimeMetric]：SQL 走 `sqlDayExpr()` / `rangeSql()`，
/// Dart 侧逐行判定走 `inRange()`。本测试**直接打真库**（内存 Drift）守三件事：
/// ① 每个统计入口都真的吃到了时间口径（漏传一处就会出现「总额按字段日期、
/// 分类构成按记账时间」的对不上账）；
/// ② 日期型自定义字段口径的**排除**语义 —— 没填该字段（或值不可解析）的明细
/// 整行不参与统计，不是按 0 计；
/// ③ 区间判定按**日粒度**（与 SQL `date()` 同义）：字段值带时分秒时按其
/// 本地日历日归桶，不因时刻落在边界外而漏掉。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:drift/drift.dart' show Value;

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_amount_metric.dart';
import 'package:piggycount/data/models/analytics_time_metric.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  /// UUID 形态的字段 syncId（与云同步生成的一致，含 '-'）。
  const dateField = '3f2a1b4c-5d6e-4f70-8a9b-0c1d2e3f4a5b';
  final timeMetric = AnalyticsTimeMetric.customField(dateField);

  final start = DateTime(2026, 6, 1);
  final end = DateTime(2026, 7, 1);

  Future<int> seedLedger({int monthStartDay = 1}) => db.into(db.ledgers).insert(
      LedgersCompanion.insert(name: 'L', monthStartDay: Value(monthStartDay)));

  Future<int> add(
    int lid, {
    String type = 'expense',
    required double amount,
    DateTime? happenedAt,
    DateTime? fieldDate,
    Object? rawFieldValue,
    int? categoryId,
  }) =>
      repo.addTransaction(
        ledgerId: lid,
        type: type,
        amount: amount,
        categoryId: categoryId,
        customValues: rawFieldValue != null
            ? {dateField: rawFieldValue}
            : (fieldDate == null ? null : {dateField: fieldDate.toIso8601String()}),
        happenedAt: happenedAt ?? DateTime(2026, 6, 15),
        excludeFromStats: false,
        excludeFromBudget: false,
      );

  /// 夹具（区间 2026-06-01 ~ 2026-07-01）：
  ///
  /// | 明细 | 记账时间 | 金额 | 字段日期 | 记账时间口径 | 字段日期口径 |
  /// | --- | --- | --- | --- | --- | --- |
  /// | T1 | 06-10 | 100 | 05-20 | 计入 | 不计入（在区间外） |
  /// | T2 | 05-05 | 200 | 06-15 | 不计入 | 计入 |
  /// | T3 | 06-20 | 400 | 未填 | 计入 | **不计入**（无值） |
  /// | T4 | 06-21 | 800 | 'nope' | 计入 | **不计入**（不可解析） |
  /// | T5 | 07-02 | 1600 | 06-30 23:59 | 不计入 | 计入（日粒度） |
  ///
  /// → 记账时间口径支出 = 1300；字段日期口径支出 = 1800。
  Future<int> seedFixture() async {
    final lid = await seedLedger();
    await add(lid,
        amount: 100, happenedAt: DateTime(2026, 6, 10), fieldDate: DateTime(2026, 5, 20));
    await add(lid,
        amount: 200, happenedAt: DateTime(2026, 5, 5), fieldDate: DateTime(2026, 6, 15));
    await add(lid, amount: 400, happenedAt: DateTime(2026, 6, 20));
    await add(lid,
        amount: 800, happenedAt: DateTime(2026, 6, 21), rawFieldValue: 'nope');
    await add(lid,
        amount: 1600,
        happenedAt: DateTime(2026, 7, 2),
        rawFieldValue: '2026-06-30T23:59:00.000');
    return lid;
  }

  // --- 模型（纯函数） -------------------------------------------------------

  test('持久化：storageValue ↔ fromStorage 往返，脏值回落记账时间', () {
    expect(AnalyticsTimeMetric.fromStorage(timeMetric.storageValue), timeMetric);
    expect(AnalyticsTimeMetric.fromStorage('happenedAt'),
        AnalyticsTimeMetric.happenedAt);
    // 旧版本 / 脏值 / 类型不符 → 默认口径，不抛
    expect(AnalyticsTimeMetric.fromStorage('legacy_time'), AnalyticsTimeMetric.happenedAt);
    expect(AnalyticsTimeMetric.fromStorage(null), AnalyticsTimeMetric.happenedAt);
    expect(AnalyticsTimeMetric.fromStorage(7), AnalyticsTimeMetric.happenedAt);
    expect(AnalyticsTimeMetric.fromStorage('custom:'), AnalyticsTimeMetric.happenedAt);
    expect(AnalyticsTimeMetric.fromStorage('custom:  '), AnalyticsTimeMetric.happenedAt);
    // 相同 syncId 的两个实例判等（provider 键 / 缓存键依赖它）
    expect(AnalyticsTimeMetric.customField(dateField), timeMetric);
    expect(timeMetric.hashCode, AnalyticsTimeMetric.customField(dateField).hashCode);
    expect(timeMetric.fieldSyncId, dateField);
    expect(timeMetric.isDefault, isFalse);
    expect(AnalyticsTimeMetric.happenedAt.isDefault, isTrue);
    expect(AnalyticsTimeMetric.happenedAt.fieldSyncId, isNull);
  });

  test('SQL 片段：记账时间口径走 happened_at，自定义字段口径走 json_extract', () {
    // 默认口径：与既有 SQL 逐字同源（unix 秒 + 本地时区修饰符）
    expect(AnalyticsTimeMetric.happenedAt.sqlSource(), 'happened_at');
    expect(AnalyticsTimeMetric.happenedAt.sqlModifier, ", 'unixepoch', 'localtime'");
    expect(AnalyticsTimeMetric.happenedAt.sqlDayExpr(),
        "date(happened_at, 'unixepoch', 'localtime')");
    expect(AnalyticsTimeMetric.happenedAt.sqlRowFilter(), '');
    expect(
      AnalyticsTimeMetric.happenedAt.rangeSql(
          start: start, end: end, startVar: '?3', endVar: '?4'),
      'happened_at >= ?3 AND happened_at < ?4',
    );
    expect(AnalyticsTimeMetric.happenedAt.rangeBinds(start, end), [start, end]);
    // 字面量形态与绑定形态同值（drift 把 DateTime 绑成 unix 秒）
    expect(
      AnalyticsTimeMetric.happenedAt.rangeSqlInlined(start: start, end: end),
      'happened_at >= ${start.millisecondsSinceEpoch ~/ 1000} '
      'AND happened_at < ${end.millisecondsSinceEpoch ~/ 1000}',
    );

    // 自定义字段口径：日期文本（无 unix 修饰符），区间按日粒度
    expect(timeMetric.sqlSource(),
        'json_extract(custom_values_json, \'\$."$dateField"\')');
    expect(timeMetric.sqlModifier, '');
    expect(timeMetric.sqlRowFilter(), contains('IS NOT NULL'));
    expect(
      timeMetric.rangeSql(start: start, end: end, startVar: '?3', endVar: '?4'),
      "date(json_extract(custom_values_json, '\$.\"$dateField\"')) >= ?3 "
      "AND date(json_extract(custom_values_json, '\$.\"$dateField\"')) < ?4",
    );
    // 绑定值恒为两个（调用方 variables: 长度不随口径变化）
    expect(timeMetric.rangeBinds(start, end), ['2026-06-01', '2026-07-01']);
    expect(
      timeMetric.rangeSqlInlined(start: start, end: end),
      "date(json_extract(custom_values_json, '\$.\"$dateField\"')) >= '2026-06-01' "
      "AND date(json_extract(custom_values_json, '\$.\"$dateField\"')) < '2026-07-01'",
    );
  });

  test('syncId 含引号 / 点 → 路径不可用：行过滤恒假（读数 0，不拼坏 SQL）', () async {
    final evil = AnalyticsTimeMetric.customField('a"b.c');
    expect(evil.sqlRowFilter(), '0');
    expect(evil.rangeSql(start: start, end: end, startVar: '?1', endVar: '?2'),
        contains('null'));

    final lid = await seedLedger();
    await add(lid, amount: 100, rawFieldValue: 50);
    final totals = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, timeMetric: evil);
    expect(totals.$2, closeTo(0, 1e-9));
  });

  // --- 区间过滤：真库 -------------------------------------------------------

  test('totalsInRange：区间按字段日期判定，未填 / 不可解析的明细整行排除', () async {
    final lid = await seedFixture();

    final recorded = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end);
    final byField = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, timeMetric: timeMetric);

    expect(recorded.$2, closeTo(1300, 1e-9)); // 100 + 400 + 800
    expect(byField.$2, closeTo(1800, 1e-9)); // 200 + 1600
  });

  test('区间为日粒度：起点当日计入、终点当日排除、带时分秒按本地日归桶', () async {
    final lid = await seedLedger();
    await add(lid,
        amount: 1, rawFieldValue: '2026-06-01T00:00:00.000'); // 起点当日 → 计入
    await add(lid,
        amount: 2, rawFieldValue: '2026-06-30T23:59:59.999'); // 末日 → 计入
    await add(lid, amount: 4, rawFieldValue: '2026-07-01'); // 终点当日 → 排除
    await add(lid, amount: 8, rawFieldValue: '2026-05-31T23:59:00.000'); // 起点前 → 排除

    final byField = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, timeMetric: timeMetric);
    expect(byField.$2, closeTo(3, 1e-9));
  });

  test('date-only 值（导入 / 旧数据格式）同样可解析', () async {
    final lid = await seedLedger();
    await add(lid, amount: 42, rawFieldValue: '2026-06-15');

    final byField = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, timeMetric: timeMetric);
    expect(byField.$2, closeTo(42, 1e-9));
  });

  test('countByTypeInRange / customFieldStatsRows：笔数与行集合同口径', () async {
    final lid = await seedFixture();

    expect(
        await repo.countByTypeInRange(
            ledgerId: lid, type: 'expense', start: start, end: end),
        3);
    expect(
        await repo.countByTypeInRange(
            ledgerId: lid,
            type: 'expense',
            start: start,
            end: end,
            timeMetric: timeMetric),
        2);

    final rows = await repo.customFieldStatsRows(
        ledgerId: lid, start: start, end: end, timeMetric: timeMetric);
    expect(rows.length, 2);
    expect(rows.fold<double>(0, (s, r) => s + r.nativeAmount), closeTo(1800, 1e-9));
  });

  test('totalsByDay：日桶取字段日期（不是记账时间），无值行不出桶', () async {
    final lid = await seedFixture();

    final byField = await repo.totalsByDay(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        timeMetric: timeMetric);
    final map = {
      for (final e in byField)
        '${e.day.year}-${e.day.month}-${e.day.day}': e.total
    };
    expect(map['2026-6-15'], closeTo(200, 1e-9));
    expect(map['2026-6-30'], closeTo(1600, 1e-9));
    // 逐日补零：T1/T3/T4 的**记账时间**落在这两天，但字段日期口径下它们不参与
    expect(map['2026-6-10'], closeTo(0, 1e-9));
    expect(map['2026-6-20'], closeTo(0, 1e-9));
    expect(map['2026-6-21'], closeTo(0, 1e-9));
    expect(byField.length, 30); // 6 月逐日补零

    final recorded = await repo.totalsByDay(
        ledgerId: lid, type: 'expense', start: start, end: end);
    final recMap = {
      for (final e in recorded)
        '${e.day.year}-${e.day.month}-${e.day.day}': e.total
    };
    expect(recMap['2026-6-10'], closeTo(100, 1e-9));
    expect(recMap['2026-6-20'], closeTo(400, 1e-9));
    expect(recMap['2026-6-21'], closeTo(800, 1e-9));
    expect(recMap['2026-6-15'], closeTo(0, 1e-9));
  });

  test('totalsByCategory / totalsByCategoryWithHierarchy（Drift 构造器路径）：同口径',
      () async {
    final lid = await seedFixture();
    final cid = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    // 把「记账时间在区间外、字段日期在区间内」的两笔挂到分类上
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: lid,
          type: 'expense',
          amount: 200,
          categoryId: Value(cid),
          customValuesJson: Value('{"$dateField":"2026-06-15T00:00:00.000"}'),
          happenedAt: Value(DateTime(2026, 5, 5)),
        ));

    final byField = await repo.totalsByCategory(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        timeMetric: timeMetric);
    // 夹具里 T2/T5 无分类 → 另有「未分类」桶，这里只看餐饮
    expect(byField.firstWhere((r) => r.name == '餐饮').total, closeTo(200, 1e-9));
    expect(byField.fold<double>(0, (s, r) => s + r.total), closeTo(2000, 1e-9));

    final hier = await repo.totalsByCategoryWithHierarchy(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        timeMetric: timeMetric);
    final row = hier.firstWhere((r) => r.name == '餐饮');
    expect(row.total, closeTo(200, 1e-9));
    expect(row.count, 1);

    // 记账时间口径下这笔（5 月）不在区间内
    final recorded = await repo.totalsByCategoryWithHierarchy(
        ledgerId: lid, type: 'expense', start: start, end: end);
    expect(recorded.where((r) => r.name == '餐饮'), isEmpty);
  });

  test('totalsByTag：标签聚合走同一时间口径（含别名 t.）', () async {
    final lid = await seedLedger();
    final tagId = await db.into(db.tags).insert(TagsCompanion.insert(name: '超市'));
    final a = await add(lid,
        amount: 200, happenedAt: DateTime(2026, 5, 5), fieldDate: DateTime(2026, 6, 15));
    final b = await add(lid,
        amount: 400, happenedAt: DateTime(2026, 6, 20));
    await repo.updateTransactionTags(transactionId: a, tagIds: [tagId]);
    await repo.updateTransactionTags(transactionId: b, tagIds: [tagId]);

    final byField = await repo.totalsByTag(
        ledgerId: lid,
        type: 'expense',
        start: start,
        end: end,
        timeMetric: timeMetric);
    expect(byField.single.total, closeTo(200, 1e-9));
    expect(byField.single.count, 1);

    final recorded = await repo.totalsByTag(
        ledgerId: lid, type: 'expense', start: start, end: end);
    expect(recorded.single.total, closeTo(400, 1e-9));
    expect(recorded.single.count, 1);
  });

  test('totalsByMonth：月份桶按字段日期的周期标签月归桶', () async {
    final lid = await seedFixture();

    final byField = await repo.totalsByMonth(
        ledgerId: lid, type: 'expense', year: 2026, timeMetric: timeMetric);
    final map = {for (final e in byField) e.month.month: e.total};
    expect(map[5], closeTo(100, 1e-9)); // T1 的字段日期在 5 月
    expect(map[6], closeTo(1800, 1e-9)); // T2 + T5
    expect(map.values.fold<double>(0, (s, v) => s + v), closeTo(1900, 1e-9));

    final recorded = await repo.totalsByMonth(
        ledgerId: lid, type: 'expense', year: 2026);
    final recMap = {for (final e in recorded) e.month.month: e.total};
    expect(recMap[6], closeTo(1300, 1e-9)); // T1 + T3 + T4
    expect(recMap[7], closeTo(1600, 1e-9)); // T5
  });

  test('totalsByYearSeries：年序列按字段日期，无值行不得产出空标签桶', () async {
    final lid = await seedFixture();

    final byField = await repo.totalsByYearSeries(
        ledgerId: lid, type: 'expense', timeMetric: timeMetric);
    expect(byField.single.year, 2026);
    expect(byField.single.total, closeTo(1900, 1e-9)); // 排除无值 / 坏值行

    final recorded = await repo.totalsByYearSeries(
        ledgerId: lid, type: 'expense');
    expect(recorded.single.total, closeTo(3100, 1e-9));
  });

  test('totalsByMonth：monthStartDay>1 时按字段日期的「周期标签月」归桶', () async {
    final lid = await seedLedger(monthStartDay: 15);
    // 周期月从每月 15 日起算：字段日期 07-10（<15）归 6 月标签，07-20 归 7 月。
    // 记账时间一律钉在 1 月初（<15 → 归上一年的 12 月标签，被 HAVING 剪掉），
    // 这样两个口径的桶对不上时测试会红。
    await add(lid,
        amount: 10,
        happenedAt: DateTime(2026, 1, 5),
        rawFieldValue: '2026-07-10T09:00:00.000');
    await add(lid,
        amount: 20,
        happenedAt: DateTime(2026, 1, 5),
        rawFieldValue: '2026-07-20T09:00:00.000');

    final byField = await repo.totalsByMonth(
        ledgerId: lid, type: 'expense', year: 2026, timeMetric: timeMetric);
    final map = {for (final e in byField) e.month.month: e.total};
    expect(map[6], closeTo(10, 1e-9));
    expect(map[7], closeTo(20, 1e-9));

    // 记账时间口径：两笔都在 1 月初（<15）→ 归上一年的 12 月标签，被 HAVING
    // substr(label,1,4)='2026' 剪掉（12 个月仍是补零的 0，证明两套口径各自取源）
    final recorded = await repo.totalsByMonth(
        ledgerId: lid, type: 'expense', year: 2026);
    expect(recorded.length, 12);
    expect(recorded.fold<double>(0, (s, e) => s + e.total), closeTo(0, 1e-9));
  });

  test('getTransactionsByDateRange：自定义字段时间口径按字段日期取行', () async {
    final lid = await seedFixture();

    // 默认口径是历史闭区间 [start, end]：T5 的记账时间 07-02 在区间外
    final recorded = await repo.getTransactionsByDateRange(
        ledgerId: lid, startDate: start, endDate: end);
    expect(recorded.map((r) => r.t.amount).toSet(), {100.0, 400.0, 800.0});

    // 字段日期口径：T2(06-15) + T5(06-30 23:59)；无值 / 坏值行整行排除
    final byField = await repo.getTransactionsByDateRange(
        ledgerId: lid, startDate: start, endDate: end, timeMetric: timeMetric);
    expect(byField.map((r) => r.t.amount).toSet(), {200.0, 1600.0});

    // 明细导出用同一个 inRange 收口：与取数 SQL 同义，不漏行也不多行
    final closed = [
      for (final r in byField)
        if (timeMetric.inRange(r.t, start: start, end: end)) r.t,
    ];
    expect(closed.length, byField.length);
  });

  test('amountMetric 与 timeMetric 正交：两者可同时生效', () async {
    final lid = await seedLedger();
    // 金额取自定义字段（金额型），时间取另一个日期字段 —— 行集合由时间口径
    // 决定，金额由金额口径决定。
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 999,
      happenedAt: DateTime(2026, 6, 15),
      customValues: {
        dateField: '2026-06-15T00:00:00.000',
        'f-water': 30,
      },
      excludeFromStats: false,
      excludeFromBudget: false,
    );

    final custom = AnalyticsAmountMetric.customField('f-water');
    final both = await repo.totalsInRange(
        ledgerId: lid,
        start: start,
        end: end,
        amountMetric: custom,
        timeMetric: timeMetric);
    expect(both.$2, closeTo(30, 1e-9));

    // 时间口径不落在区间内 → 金额口径再对也读数为 0
    final outOfRange = await repo.totalsInRange(
        ledgerId: lid,
        start: DateTime(2026, 8, 1),
        end: DateTime(2026, 9, 1),
        amountMetric: custom,
        timeMetric: timeMetric);
    expect(outOfRange.$2, closeTo(0, 1e-9));
  });

  test('Dart 侧 inRange 与 SQL 侧区间过滤同义（逐行累加对账）', () async {
    final lid = await seedFixture();

    final rows = await db.select(db.transactions).get();
    final dartSum = rows
        .where((t) => timeMetric.inRange(t, start: start, end: end))
        .fold<double>(0, (s, t) => s + t.amount);

    final sqlTotals = await repo.totalsInRange(
        ledgerId: lid, start: start, end: end, timeMetric: timeMetric);
    expect(dartSum, closeTo(1800, 1e-9));
    expect(sqlTotals.$2, closeTo(dartSum, 1e-9));
  });

  test('Dart 侧 dayOf：按本地日历日归一（与 SQL date() 同义）', () async {
    final lid = await seedLedger();
    await add(lid, amount: 1, rawFieldValue: '2026-06-30T23:59:59.999');
    await add(lid, amount: 2, fieldDate: DateTime(2026, 6, 15, 8));

    final rows = await db.select(db.transactions).get();
    expect(timeMetric.dayOf(rows[0])!.hour, 0);
    expect(timeMetric.dayOf(rows[0])!.day, 30);
    expect(timeMetric.dayOf(rows[1])!.day, 15);
    expect(timeMetric.timeOf(rows[1])!.hour, 8); // timeOf 保留时刻
    // 默认口径：直接取记账时间
    final t = rows[1];
    expect(AnalyticsTimeMetric.happenedAt.dayOf(t), isNotNull);
    expect(AnalyticsTimeMetric.happenedAt.inRange(t, start: start, end: end), isTrue);
  });
}
