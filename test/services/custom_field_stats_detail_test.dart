/// 分类型字段统计（FieldStats / aggregateDetail）特征测试 —— 阶段 1 RED。
///
/// 锁死口径（prd/custom_field_stats_fullchain F1）：
/// - 金额型：字段值（非交易额）求和/均值/极值 + 绝对值数量级分布桶（5 档恒定）；
///   均值只除以数值型值个数（脏数据字符串值跳过统计但计填写）。
/// - 日期型：按月序列（'yyyy-MM' 升序），笔数 + 收支两维金额（沿用旧值桶
///   「单桶记收支两维」范式）；不可解析日期不进序列但计填写。
/// - 文本/单选/多选（TextLike）：值桶 count + 收支两维 + ratio=count/填写数；
///   多选逐选项拆桶（沿用旧拆桶语义）。
/// - 填写率 = filledCount/totalCount（totalCount 含未填任何字段的交易，
///   由调用方显式给出）；无任何人填的字段也出现在输出（管理页计数用）。
/// - 旧 CustomFieldFieldStats 值桶输出是冻结面，本文件不测也不许改它。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';

CustomFieldDefinition _def(int id, String syncId, String name, String type) =>
    CustomFieldDefinition(
      id: id,
      ledgerId: 1,
      name: name,
      fieldType: type,
      sortOrder: 0,
      createdAt: DateTime(2026, 1, 1),
      syncId: syncId,
      updatedAt: null,
      isRequired: false,
    );

typedef Row = ({String type, double nativeAmount, String? customValuesJson});

Row _row(String type, double amount, Map<String, dynamic>? values) => (
      type: type,
      nativeAmount: amount,
      customValuesJson: values == null ? null : _jsonOf(values),
    );

/// 与 CustomFieldValueCodec.encode 同口径的最小序列化（键序排序）。
/// 多选（字符串列表）值直接写 JSON 数组字面量。
String _jsonOf(Map<String, dynamic> values) {
  final keys = values.keys.toList()..sort();
  final parts = [
    for (final k in keys)
      () {
        final v = values[k];
        if (v is num) return '"$k":$v';
        if (v is List) {
          return '"$k":[${v.map((e) => '"$e"').join(',')}]';
        }
        return '"$k":"$v"';
      }()
  ];
  return '{${parts.join(',')}}';
}

void main() {
  group('AmountFieldStats：字段值四指标与分布', () {
    test('sum/avg/min/max 按字段值计算；数量级分布桶（abs 五档）', () {
      final defs = [_def(1, 'fee', '小费', 'amount')];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 7,
        rows: [
          _row('expense', 100, {'fee': 5}),
          _row('expense', 200, {'fee': 50}),
          _row('income', 30, {'fee': 500}),
          _row('expense', 40, {'fee': 5000}),
          _row('income', 10, {'fee': 50000}),
          _row('expense', 5, {'fee': -25}),
          // 未填 fee（只填了别的字段）→ 不进分子
          _row('expense', 7, {'other': 'x'}),
        ],
      );

      expect(stats, hasLength(1));
      final f = stats.single as AmountFieldStats;
      expect(f.filledCount, 6);
      expect(f.totalCount, 7);
      expect(f.fillRate, closeTo(6 / 7, 1e-9));

      // 字段值口径（与交易额无关）
      expect(f.valueSum, 5 + 50 + 500 + 5000 + 50000 - 25);
      expect(f.valueAvg, closeTo((5 + 50 + 500 + 5000 + 50000 - 25) / 6, 1e-9));
      expect(f.valueMin, -25);
      expect(f.valueMax, 50000);

      // 5 档恒定分布桶：[0,10) [10,100) [100,1k) [1k,10k) [10k,∞)
      expect(f.dist, hasLength(5));
      expect(f.dist[0].lower, 0);
      expect(f.dist[0].upper, 10);
      expect(f.dist[0].count, 1); // 5
      expect(f.dist[1].count, 2); // 50 与 |-25|
      expect(f.dist[2].count, 1); // 500
      expect(f.dist[3].count, 1); // 5000
      expect(f.dist[4].upper, null);
      expect(f.dist[4].count, 1); // 50000
    });

    test('脏值（非数值）计填写但跳过数值统计；全脏 → 四指标全 0', () {
      final defs = [_def(1, 'fee', '小费', 'amount')];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 1,
        rows: [_row('expense', 10, {'fee': 'abc'})],
      );
      final f = stats.single as AmountFieldStats;
      expect(f.filledCount, 1);
      expect(f.valueSum, 0);
      expect(f.valueAvg, 0);
      expect(f.valueMin, 0);
      expect(f.valueMax, 0);
      expect(f.dist.every((b) => b.count == 0), isTrue);
    });
  });

  group('DateFieldStats：按月序列', () {
    test('yyyy-MM 升序、笔数与收支两维；坏日期不进序列但计填写', () {
      final defs = [_def(1, 'd', '截止日', 'date')];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 5,
        rows: [
          _row('expense', 100, {'d': '2026-01-15T08:00:00.000'}),
          _row('expense', 50, {'d': '2026-01-20'}),
          _row('income', 30, {'d': '2026-02-03T10:00:00.000'}),
          _row('expense', 20, {'d': 'bad-date'}),
          _row('expense', 5, {'d': null}),
        ],
      );

      final f = stats.single as DateFieldStats;
      expect(f.filledCount, 3); // bad-date 与 null 不计填写
      expect(f.monthly, hasLength(2));
      expect(f.monthly[0].month, '2026-01');
      expect(f.monthly[0].count, 2);
      expect(f.monthly[0].expense, 150);
      expect(f.monthly[0].income, 0);
      expect(f.monthly[1].month, '2026-02');
      expect(f.monthly[1].count, 1);
      expect(f.monthly[1].income, 30);
      expect(f.monthly[1].expense, 0);
    });
  });

  group('TextLikeFieldStats：值桶 + ratio', () {
    test('文本/单选/多选共用；多选逐选项拆桶；ratio=count/填写数', () {
      final defs = [
        _def(1, 'tag', '标签', 'multiSelect'),
        _def(2, 'proj', '项目', 'singleSelect'),
        _def(3, 'note', '备注', 'text'),
      ];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 3,
        rows: [
          _row('expense', 100, {
            'tag': ['a', 'b'],
            'proj': 'X',
            'note': 'hello',
          }),
          _row('expense', 50, {
            'tag': ['a'],
            'proj': 'Y',
          }),
          _row('income', 30, {'note': 'hello'}),
        ],
      );

      expect(stats, hasLength(3));

      final tag = stats[0] as TextLikeFieldStats;
      expect(tag.filledCount, 2);
      final tagA = tag.values.singleWhere((v) => v.label == 'a');
      expect(tagA.count, 2);
      expect(tagA.expense, 150);
      expect(tagA.ratio, closeTo(1.0, 1e-9));
      final tagB = tag.values.singleWhere((v) => v.label == 'b');
      expect(tagB.count, 1);
      expect(tagB.expense, 100);
      expect(tagB.ratio, closeTo(0.5, 1e-9));

      final proj = stats[1] as TextLikeFieldStats;
      expect(proj.values.map((v) => v.label), ['X', 'Y']);
      expect(proj.values[0].ratio, closeTo(0.5, 1e-9));

      final note = stats[2] as TextLikeFieldStats;
      final hello = note.values.single;
      expect(hello.label, 'hello');
      expect(hello.count, 2);
      expect(hello.expense, 100);
      expect(hello.income, 30);
      expect(hello.ratio, closeTo(1.0, 1e-9));
    });
  });

  group('aggregateDetail：输入防御与空态', () {
    test('无人填写的字段也输出（filledCount 0、fillRate 0）', () {
      final defs = [
        _def(1, 'a', '甲', 'text'),
        _def(2, 'b', '乙', 'text'),
      ];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 10,
        rows: [_row('expense', 1, {'a': 'x'})],
      );

      expect(stats, hasLength(2));
      expect(stats[0].fieldSyncId, 'a');
      expect(stats[0].filledCount, 1);
      expect(stats[0].fillRate, closeTo(0.1, 1e-9));
      expect(stats[1].fieldSyncId, 'b');
      expect(stats[1].filledCount, 0);
      expect(stats[1].fillRate, 0);
      expect((stats[1] as TextLikeFieldStats).values, isEmpty);
    });

    test('空定义 → 空输出；空行 → 全字段零填写输出', () {
      expect(
        CustomFieldStatsService.aggregateDetail(
            defs: [], totalCount: 0, rows: []),
        isEmpty,
      );

      final defs = [_def(1, 'a', '甲', 'text')];
      final stats = CustomFieldStatsService.aggregateDetail(
          defs: defs, totalCount: 3, rows: []);
      expect(stats, hasLength(1));
      expect(stats.single.filledCount, 0);
      expect(stats.single.totalCount, 3);
    });

    test('无 syncId 的定义跳过；幽灵键忽略', () {
      final orphan = CustomFieldDefinition(
        id: 9,
        ledgerId: 1,
        name: '无锚点',
        fieldType: 'text',
        sortOrder: 1,
        createdAt: DateTime(2026, 1, 1),
        syncId: null,
        updatedAt: null,
        isRequired: false,
      );
      final defs = [
        _def(1, 'live', '有效', 'text'),
        orphan,
      ];
      final stats = CustomFieldStatsService.aggregateDetail(
        defs: defs,
        totalCount: 1,
        rows: [_row('expense', 10, {'live': 'A', 'ghost': 'X'})],
      );
      expect(stats, hasLength(1));
      expect(stats.single.fieldSyncId, 'live');
      expect((stats.single as TextLikeFieldStats).values.single.label, 'A');
    });
  });
}
