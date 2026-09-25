import '../data/db.dart';
import '../data/models/custom_field_values.dart';

/// B2(v47) 自定义字段汇总 —— 纯函数聚合，零 UI / 存储依赖（与
/// original_amount_insight_service 同哲学：可解释、离线、可单测）。
///
/// 口径：
/// - 交易行由仓储层给出：`COALESCE(native_amount, amount)`（本位币折算）、
///   已排除「不计收支」；行仅含 custom_values_json 非空的交易。
/// - 按字段定义顺序输出；值桶标签经 [CustomFieldValueCodec] 规范化展示
///   （金额去尾 0、日期 yyyy-MM-dd、文本原文），同一语义值不会裂成两桶。
/// - 单桶同时记收入/支出两维，渲染层按当前维度排序取数。
class CustomFieldFieldStats {
  /// 字段定义 syncId（值 JSON 的键）。
  final String fieldSyncId;

  /// 字段名（定义上的展示名）。
  final String name;

  /// amount / text / date。
  final String fieldType;

  /// 值桶：label → (income, expense, count)。
  final Map<String, ({double income, double expense, int count})> buckets;

  const CustomFieldFieldStats({
    required this.fieldSyncId,
    required this.name,
    required this.fieldType,
    required this.buckets,
  });

  /// 是否有任何一笔交易填了该字段。
  bool get isEmpty => buckets.isEmpty;

  /// 按维度金额降序的值桶列表。
  List<({String label, double income, double expense, int count})> sorted(
      String dim) {
    double amount(
            ({String label, double income, double expense, int count}) b) =>
        dim == 'income' ? b.income : b.expense;
    final list = buckets.entries
        .map((e) => (label: e.key, income: e.value.income,
            expense: e.value.expense, count: e.value.count))
        .toList();
    list.sort((a, b) => amount(b).compareTo(amount(a)));
    return list;
  }
}

class CustomFieldStatsService {
  CustomFieldStatsService._();

  /// 聚合区间内的自定义字段值。
  ///
  /// [rows] 由仓储层 [StatisticsRepository.customFieldStatsRows] 给出；
  /// [topN] 仅是渲染层建议值，聚合本身不截断（「其他」桶在 UI 侧合并）。
  static List<CustomFieldFieldStats> aggregate({
    required List<CustomFieldDefinition> defs,
    required List<({String type, double nativeAmount, String? customValuesJson})>
        rows,
  }) {
    if (defs.isEmpty || rows.isEmpty) return const [];
    final usableDefs = <CustomFieldDefinition>[
      for (final d in defs)
        if (d.syncId != null && d.syncId!.isNotEmpty) d,
    ];
    if (usableDefs.isEmpty) return const [];

    final acc = {
      for (final d in usableDefs)
        d.syncId!: <String, ({double income, double expense, int count})>{},
    };

    for (final row in rows) {
      final values = CustomFieldValueCodec.decode(row.customValuesJson);
      if (values.isEmpty) continue;
      final isIncome = row.type == 'income';
      for (final d in usableDefs) {
        final v = values[d.syncId!];
        if (v == null) continue;
        final label = _displayLabel(v, d.fieldType);
        if (label == null) continue;
        final bucket = acc[d.syncId!]!.update(
              label,
              (b) => (
                income: b.income + (isIncome ? row.nativeAmount : 0),
                expense: b.expense + (isIncome ? 0 : row.nativeAmount),
                count: b.count + 1,
              ),
              ifAbsent: () => (
                income: isIncome ? row.nativeAmount : 0,
                expense: isIncome ? 0 : row.nativeAmount,
                count: 1,
              ),
            );
        acc[d.syncId!]![label] = bucket;
      }
    }

    return [
      for (final d in usableDefs)
        if (acc[d.syncId!]!.isNotEmpty)
          CustomFieldFieldStats(
            fieldSyncId: d.syncId!,
            name: d.name,
            fieldType: d.fieldType,
            buckets: acc[d.syncId!]!,
          ),
    ];
  }

  /// 值 → 稳定展示标签（桶键）：同一语义值必须落同一桶。
  ///
  /// 日期收敛到 yyyy-MM-dd **仅对 [fieldType] == date 生效**：文本字段的
  /// 值可能碰巧可被 DateTime.tryParse 解析（如 "2026"），按类型判断才不会
  /// 把文本值错误改写成日期。
  static String? _displayLabel(dynamic value, String fieldType) {
    if (value == null) return null;
    if (value is num) return CustomFieldValueCodec.canonicalValue(value);
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    if (fieldType == CustomFieldType.date) {
      final parsed = DateTime.tryParse(s);
      if (parsed != null) {
        return '${parsed.year.toString().padLeft(4, '0')}-'
            '${parsed.month.toString().padLeft(2, '0')}-'
            '${parsed.day.toString().padLeft(2, '0')}';
      }
    }
    return s;
  }
}
