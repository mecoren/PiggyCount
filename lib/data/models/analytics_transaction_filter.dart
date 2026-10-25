import '../../utils/transaction_search_filter.dart';

/// 洞察页的附加筛选（与顶部「支出 / 收入 / 结余」视角正交）。
///
/// - [types] 为空 = 不限交易类型；非空时按 `type IN (...)` 与视角取交集。
/// - [customFieldConditions] 之间为 AND，单条多选条件内部为 ANY。
///
/// 值对象实现相等性（基于 [cacheKey]），这样每次 build 新建的等价筛选仍能
/// 命中 Provider 家族缓存与页面 `_resultCache`，不会每次重建都重查数据库。
class AnalyticsTransactionFilter {
  const AnalyticsTransactionFilter({
    this.types = const <String>{},
    this.customFieldConditions = const <CustomFieldCondition>[],
  });

  /// 交易类型：`expense` / `income` / `transfer`。
  final Set<String> types;

  final List<CustomFieldCondition> customFieldConditions;

  bool get isEmpty => types.isEmpty && customFieldConditions.isEmpty;

  bool get isNotEmpty => !isEmpty;

  String get cacheKey {
    final sortedTypes = types.toList()..sort();
    final conditions = [
      for (final c in customFieldConditions) _conditionKey(c),
    ]..sort();
    return '${sortedTypes.join(',')}|${conditions.join('||')}';
  }

  AnalyticsTransactionFilter copyWith({
    Set<String>? types,
    List<CustomFieldCondition>? customFieldConditions,
  }) =>
      AnalyticsTransactionFilter(
        types: types ?? this.types,
        customFieldConditions:
            customFieldConditions ?? this.customFieldConditions,
      );

  @override
  bool operator ==(Object other) =>
      other is AnalyticsTransactionFilter && other.cacheKey == cacheKey;

  @override
  int get hashCode => cacheKey.hashCode;
}

String _conditionKey(CustomFieldCondition c) => switch (c) {
      CustomFieldConditionEq(:final fieldSyncId, :final value) =>
        'eq:$fieldSyncId:$value',
      CustomFieldConditionContains(:final fieldSyncId, :final value) =>
        'contains:$fieldSyncId:$value',
      CustomFieldConditionAnyOf(:final fieldSyncId, :final values) =>
        'any:$fieldSyncId:${(values.toList()..sort()).join('\u0001')}',
      CustomFieldConditionBetween(
        :final fieldSyncId,
        :final lower,
        :final upper
      ) =>
        'between:$fieldSyncId:$lower:$upper',
    };
