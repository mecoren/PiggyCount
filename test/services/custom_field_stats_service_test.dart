/// B2(v47) 自定义字段汇总聚合（CustomFieldStatsService）回归。
///
/// 锁死聚合口径：
/// - 行金额取仓储层折好的 nativeAmount，「不计收支」上游已排除（服务不重复过滤）；
/// - 分桶键经 canonical 展示：同一语义值不裂桶（1 / 1.0 同桶）；
/// - 日期桶键收敛 yyyy-MM-dd **仅对 date 类型**生效（文本 "2026" 不许被误改写）；
/// - 单桶同时记收支两维，sorted(dim) 按所选维度金额降序；
/// - 无 syncId 的定义、无值行、空输入都不产出。
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
    );

typedef Row = ({String type, double nativeAmount, String? customValuesJson});

Row _row(String type, double amount, Map<String, dynamic>? values) => (
      type: type,
      nativeAmount: amount,
      customValuesJson: values == null ? null : _jsonOf(values),
    );

/// 与 CustomFieldValueCodec.encode 同口径的最小序列化（键序排序、
/// num 直写、字符串带引号）。
String _jsonOf(Map<String, dynamic> values) {
  final keys = values.keys.toList()..sort();
  final parts = [
    for (final k in keys)
      '"$k":${values[k] is num ? values[k] : '"${values[k]}"'}'
  ];
  return '{${parts.join(',')}}';
}

void main() {
  group('aggregate：分桶与口径', () {
    test('按字段分桶；收支两维分开记；同一语义值不裂桶', () {
      final defs = [
        _def(1, 'proj', '项目', 'text'),
      ];
      final stats = CustomFieldStatsService.aggregate(defs: defs, rows: [
        _row('expense', 100, {'proj': 'A'}),
        _row('expense', 50, {'proj': 'A'}),
        _row('income', 30, {'proj': 'A'}),
        _row('income', 20, {'proj': 'B'}),
      ]);

      expect(stats, hasLength(1));
      final f = stats.single;
      expect(f.name, '项目');
      expect(f.buckets['A'], (income: 30.0, expense: 150.0, count: 3));
      expect(f.buckets['B'], (income: 20.0, expense: 0.0, count: 1));

      final byExpense = f.sorted('expense');
      expect(byExpense.first.label, 'A');
      expect(byExpense.last.label, 'B');
      final byIncome = f.sorted('income');
      expect(byIncome.first.label, 'A');
      expect(byIncome.last.label, 'B');
    });

    test('金额字段：1 与 1.0 归一展示，同桶', () {
      final defs = [_def(1, 'fee', '税费', 'amount')];
      final stats = CustomFieldStatsService.aggregate(defs: defs, rows: [
        _row('expense', 10, {'fee': 1}),
        _row('expense', 20, {'fee': 1.0}),
      ]);
      expect(stats.single.buckets.keys, ['1']);
      expect(stats.single.buckets['1']!.expense, 30.0);
    });

    test('date 字段：ISO 时刻收敛到 yyyy-MM-dd 同桶；text 字段 "2026" 不改写', () {
      final dateDef = _def(1, 'd', '截止', 'date');
      final textDef = _def(2, 't', '备注2', 'text');
      final stats = CustomFieldStatsService.aggregate(
          defs: [dateDef, textDef],
          rows: [
            _row('expense', 10, {
              'd': '2026-09-01T08:00:00.000',
              't': '2026',
            }),
            _row('expense', 20, {
              'd': '2026-09-01T23:59:59.000',
              't': '2026-09-02',
            }),
          ]);

      final dateField = stats.firstWhere((f) => f.fieldSyncId == 'd');
      expect(dateField.buckets.keys, ['2026-09-01']);
      expect(dateField.buckets['2026-09-01']!.count, 2);

      final textField = stats.firstWhere((f) => f.fieldSyncId == 't');
      expect(textField.buckets.keys.toSet(), {'2026', '2026-09-02'});
    });
  });

  group('aggregate：输入防御', () {
    test('无 syncId 的定义不产出；定义被删的幽灵键被忽略', () {
      final orphan = CustomFieldDefinition(
        id: 2,
        ledgerId: 1,
        name: '无锚点',
        fieldType: 'text',
        sortOrder: 1,
        createdAt: DateTime(2026, 1, 1),
        syncId: null,
        updatedAt: null,
      );
      final defs = [
        _def(1, 'live', '有效', 'text'),
        orphan,
      ];
      final stats = CustomFieldStatsService.aggregate(defs: defs, rows: [
        _row('expense', 10, {'live': 'A', 'ghost': 'X'}),
      ]);

      expect(stats, hasLength(1));
      expect(stats.single.fieldSyncId, 'live');
      expect(stats.single.buckets.keys, ['A']);
    });

    test('空定义 / 空行 / 全空值 → 空结果', () {
      final defs = [_def(1, 'a', '甲', 'text')];
      expect(CustomFieldStatsService.aggregate(defs: [], rows: []), isEmpty);
      expect(
          CustomFieldStatsService.aggregate(
              defs: defs,
              rows: [_row('expense', 10, null), _row('income', 5, {})]),
          isEmpty);
    });
  });
}
