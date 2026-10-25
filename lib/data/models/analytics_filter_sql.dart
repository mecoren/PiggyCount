import '../../utils/transaction_search_filter.dart';
import 'analytics_transaction_filter.dart';
import 'custom_field_values.dart';

/// 洞察附加筛选拼出的 SQL 片段与绑定值。
class AnalyticsFilterSql {
  const AnalyticsFilterSql({this.suffix = '', this.values = const []});

  /// 含前导 `AND`；空串 = 无附加条件。
  final String suffix;

  /// 顺序与 [suffix] 中的 `?N` 一致。
  final List<Object> values;
}

const _allowedTypes = {'expense', 'income', 'transfer'};

/// 生成洞察筛选 SQL，[firstIndex] 为下一个可用占位符序号。
///
/// 自定义字段值通过 `json_each` 统一处理标量与数组，单选/文本/多选共用一条
/// 路径；字段 syncId 仍走 [sqliteJsonPathForField] 白名单，非法路径恒假。
AnalyticsFilterSql buildAnalyticsFilterSql(
  AnalyticsTransactionFilter filter, {
  required int firstIndex,
  String alias = '',
}) {
  final p = alias.isEmpty ? '' : '$alias.';
  final clauses = <String>[];
  final binds = <Object>[];
  var index = firstIndex;

  if (filter.types.isNotEmpty) {
    final valid = filter.types.where(_allowedTypes.contains).toList()..sort();
    if (valid.isEmpty) {
      clauses.add('0');
    } else {
      final marks = [
        for (var i = 0; i < valid.length; i++) '?${index + i}',
      ];
      clauses.add('${p}type IN (${marks.join(', ')})');
      binds.addAll(valid);
      index += valid.length;
    }
  }

  for (final condition in filter.customFieldConditions) {
    final path = sqliteJsonPathForField(condition.fieldSyncId);
    if (path == null) {
      clauses.add('0');
      continue;
    }
    final each = 'json_each(${p}custom_values_json, \'$path\')';
    switch (condition) {
      case CustomFieldConditionEq(:final value):
        clauses.add(
          'EXISTS (SELECT 1 FROM $each j '
          'WHERE CAST(j.value AS TEXT) = ?$index)',
        );
        binds.add(value);
        index++;
      case CustomFieldConditionContains(:final value):
        final wanted = value.trim().toLowerCase();
        if (wanted.isEmpty) {
          clauses.add('0');
        } else {
          clauses.add(
            'EXISTS (SELECT 1 FROM $each j '
            'WHERE instr(lower(CAST(j.value AS TEXT)), ?$index) > 0)',
          );
          binds.add(wanted);
          index++;
        }
      case CustomFieldConditionAnyOf(:final values):
        final sorted = values.toList()..sort();
        if (sorted.isEmpty) {
          clauses.add('0');
        } else {
          final marks = [
            for (var i = 0; i < sorted.length; i++) '?${index + i}',
          ];
          clauses.add(
            'EXISTS (SELECT 1 FROM $each j '
            'WHERE CAST(j.value AS TEXT) IN (${marks.join(', ')}))',
          );
          binds.addAll(sorted);
          index += sorted.length;
        }
      case CustomFieldConditionBetween():
        // 区间条件不在洞察筛选 UI 中提供；保留恒假避免静默忽略。
        clauses.add('0');
    }
  }

  if (clauses.isEmpty) return const AnalyticsFilterSql();
  return AnalyticsFilterSql(
    suffix: ' AND ${clauses.join(' AND ')}',
    values: binds,
  );
}
