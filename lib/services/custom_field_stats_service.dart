import '../data/db.dart';
import '../data/models/custom_field_values.dart';

/// 分类型字段统计结果（prd/custom_field_stats_fullchain F1）。
///
/// 形状即类型（延续 InsightsData 范式）：金额/日期/文本三形状字段语义不同，
/// sealed 穷尽匹配把「跨形状误读」变成编译错误。text/singleSelect/
/// multiSelect 共用 [TextLikeFieldStats]——三者数据形状相同（值桶），区别仅在
/// 值来源，不强造三类。
sealed class FieldStats {
  const FieldStats({
    required this.fieldSyncId,
    required this.name,
    required this.fieldType,
    required this.filledCount,
    required this.totalCount,
  });

  /// 字段定义 syncId（值 JSON 的键）。
  final String fieldSyncId;

  /// 字段名（定义上的展示名）。
  final String name;

  /// amount / text / date / singleSelect / multiSelect。
  final String fieldType;

  /// 填写笔数（口径随类型：金额=非空值、日期=可解析、文本系=能出标签）。
  final int filledCount;

  /// 区间交易总笔数（含未填任何字段的交易，由调用方给出）。
  final int totalCount;

  /// 填写率（totalCount 为 0 时返回 0）。
  double get fillRate => totalCount == 0 ? 0 : filledCount / totalCount;
}

/// 金额型字段：字段值（非交易额）四指标 + 绝对值数量级分布。
final class AmountFieldStats extends FieldStats {
  const AmountFieldStats({
    required super.fieldSyncId,
    required super.name,
    required super.fieldType,
    required super.filledCount,
    required super.totalCount,
    required this.valueSum,
    required this.valueAvg,
    required this.valueMin,
    required this.valueMax,
    required this.dist,
  });

  /// 数值型值之和（脏数据值跳过；全脏时四指标都是 0）。
  final double valueSum;

  /// 数值型值均值（只除以有效数值个数，不是 filledCount）。
  final double valueAvg;
  final double valueMin;
  final double valueMax;

  /// 绝对值数量级分布（5 档恒定）：[0,10) [10,100) [100,1k) [1k,10k) [10k,∞)。
  /// 分档按 abs 值——负值（如调整项）与正值同档比较数量级。
  final List<({num lower, num? upper, int count})> dist;

  /// 分布档展示标签（UI 分布行与导出 CSV「统计项」列共用同一格式，
  /// 避免两处各拼一套导致「界面写 ≥10000、导出写 10000+」的分叉）。
  /// 末档上界为 null →「≥lower」。
  static String distLabel(num lower, num? upper) =>
      upper == null ? '≥$lower' : '$lower~$upper';
}

/// 日期型字段：按月序列（笔数 + 收支两维，沿用旧值桶「单桶记收支两维」范式）。
final class DateFieldStats extends FieldStats {
  const DateFieldStats({
    required super.fieldSyncId,
    required super.name,
    required super.fieldType,
    required super.filledCount,
    required super.totalCount,
    required this.monthly,
  });

  /// 'yyyy-MM' 升序。
  final List<({String month, int count, double income, double expense})> monthly;
}

/// 文本/单选/多选共用：值桶 + 占比。
final class TextLikeFieldStats extends FieldStats {
  const TextLikeFieldStats({
    required super.fieldSyncId,
    required super.name,
    required super.fieldType,
    required super.filledCount,
    required super.totalCount,
    required this.values,
  });

  /// count 降序、同 count 按 label 字典序（确定性输出）。
  /// ratio = count / filledCount（多选拆桶后同一笔可入多桶，ratio 之和可 >1）。
  final List<
      ({
        String label,
        int count,
        double income,
        double expense,
        double ratio
      })> values;
}

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
        // v54 多选：同一笔按每个被选中的值**分别归桶**（接受同一笔在多桶
        // 重复计金额，与单选口径一致）。
        for (final label in _displayLabels(v, d.fieldType)) {
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

  /// 分类型字段聚合（prd/custom_field_stats_fullchain F1）。
  ///
  /// 与 [aggregate]（旧值桶，冻结面）同输入行、同分桶语义，但按字段类型产出
  /// 分类型指标。**旧输出不经过这里**，两者并行、互不影响。
  ///
  /// [totalCount] 是区间交易总笔数（含未填任何字段的交易）——行集里只有
  /// custom_values_json 非空的交易，未填笔数必须由调用方补进来才能算填写率。
  /// 无人填写的字段也出现在输出（管理页「已填写 0 笔」需要）。
  static List<FieldStats> aggregateDetail({
    required List<CustomFieldDefinition> defs,
    required int totalCount,
    required List<({String type, double nativeAmount, String? customValuesJson})>
        rows,
  }) {
    final usableDefs = <CustomFieldDefinition>[
      for (final d in defs)
        if (d.syncId != null && d.syncId!.isNotEmpty) d,
    ];
    if (usableDefs.isEmpty) return const [];

    // 一趟循环内的中间态（按字段累积，最后再物化成 sealed 结果）。
    final filled = {for (final d in usableDefs) d.syncId!: 0};
    // 金额型：有效数值值列表（脏值跳过统计但已在 filled 计数）。
    final amounts = {for (final d in usableDefs) d.syncId!: <double>[]};
    // 日期型：'yyyy-MM' → (count, income, expense)。
    final months = {
      for (final d in usableDefs)
        d.syncId!:
            <String, ({int count, double income, double expense})>{},
    };
    // 文本系：label → (count, income, expense)。
    final valueBuckets = {
      for (final d in usableDefs)
        d.syncId!:
            <String, ({int count, double income, double expense})>{},
    };

    for (final row in rows) {
      final values = CustomFieldValueCodec.decode(row.customValuesJson);
      if (values.isEmpty) continue;
      final isIncome = row.type == 'income';
      for (final d in usableDefs) {
        final v = values[d.syncId!];
        if (v == null) continue;
        switch (d.fieldType) {
          case CustomFieldType.amount:
            // 非空即填写（脏值也算，与编辑器可存字符串的历史兼容）；
            // 但数值统计只收 num —— 脏值跳过四指标与分布，不污染均值分母。
            filled[d.syncId!] = filled[d.syncId]! + 1;
            if (v is num) amounts[d.syncId]!.add(v.toDouble());
          case CustomFieldType.date:
            // 只有可解析日期才计填写（与旧值桶「坏日期不出桶」语义一致）。
            final month = _monthBucket(v);
            if (month != null) {
              filled[d.syncId!] = filled[d.syncId]! + 1;
              final acc = months[d.syncId]!.putIfAbsent(
                month,
                // 为什么单独建月桶：分析页折线直接消费「月份 + 收支」序列，
                // 从逐日值桶反推月份会让 UI 层重复解析日期。
                () => (count: 0, income: 0.0, expense: 0.0),
              );
              months[d.syncId]![month] = (
                count: acc.count + 1,
                income: acc.income + (isIncome ? row.nativeAmount : 0),
                expense: acc.expense + (isIncome ? 0 : row.nativeAmount),
              );
            }
          case CustomFieldType.text:
          case CustomFieldType.singleSelect:
          case CustomFieldType.multiSelect:
            // 文本系：能出标签就算填写（多选拆桶沿用旧语义，一笔可入多桶）。
            final labels = _displayLabels(v, d.fieldType);
            if (labels.isNotEmpty) {
              filled[d.syncId!] = filled[d.syncId]! + 1;
              for (final label in labels) {
                final acc = valueBuckets[d.syncId]!.update(
                  label,
                  (b) => (
                    count: b.count + 1,
                    income: b.income + (isIncome ? row.nativeAmount : 0),
                    expense: b.expense + (isIncome ? 0 : row.nativeAmount),
                  ),
                  ifAbsent: () => (
                    count: 1,
                    income: isIncome ? row.nativeAmount : 0.0,
                    expense: isIncome ? 0.0 : row.nativeAmount,
                  ),
                );
                valueBuckets[d.syncId]![label] = acc;
              }
            }
        }
      }
    }

    return [
      for (final d in usableDefs)
        switch (d.fieldType) {
          CustomFieldType.amount => _buildAmount(
              d, filled[d.syncId]!, totalCount, amounts[d.syncId]!),
          CustomFieldType.date => _buildDate(
              d, filled[d.syncId]!, totalCount, months[d.syncId]!),
          _ => _buildTextLike(
              d, filled[d.syncId]!, totalCount, valueBuckets[d.syncId]!),
        },
    ];
  }

  /// 金额型结果物化：四指标 + 5 档恒定分布。
  static AmountFieldStats _buildAmount(
    CustomFieldDefinition d,
    int filledCount,
    int totalCount,
    List<double> values,
  ) {
    final buckets = [0, 0, 0, 0, 0];
    var sum = 0.0;
    var min = 0.0;
    var max = 0.0;
    for (var i = 0; i < values.length; i++) {
      final v = values[i];
      sum += v;
      if (i == 0 || v < min) min = v;
      if (i == 0 || v > max) max = v;
      final a = v.abs();
      buckets[a < 10
          ? 0
          : a < 100
              ? 1
              : a < 1000
                  ? 2
                  : a < 10000
                      ? 3
                      : 4]++;
    }
    const lowers = [0, 10, 100, 1000, 10000];
    const uppers = [10, 100, 1000, 10000, null];
    return AmountFieldStats(
      fieldSyncId: d.syncId!,
      name: d.name,
      fieldType: d.fieldType,
      filledCount: filledCount,
      totalCount: totalCount,
      valueSum: sum,
      valueAvg: values.isEmpty ? 0 : sum / values.length,
      valueMin: values.isEmpty ? 0 : min,
      valueMax: values.isEmpty ? 0 : max,
      dist: [
        for (var i = 0; i < 5; i++)
          (lower: lowers[i], upper: uppers[i], count: buckets[i]),
      ],
    );
  }

  /// 日期型结果物化：月序列按 'yyyy-MM' 升序。
  static DateFieldStats _buildDate(
    CustomFieldDefinition d,
    int filledCount,
    int totalCount,
    Map<String, ({int count, double income, double expense})> months,
  ) {
    final keys = months.keys.toList()..sort();
    return DateFieldStats(
      fieldSyncId: d.syncId!,
      name: d.name,
      fieldType: d.fieldType,
      filledCount: filledCount,
      totalCount: totalCount,
      monthly: [
        for (final k in keys)
          (
            month: k,
            count: months[k]!.count,
            income: months[k]!.income,
            expense: months[k]!.expense,
          ),
      ],
    );
  }

  /// 文本系结果物化：count 降序、同 count 按 label 字典序（确定性输出）。
  static TextLikeFieldStats _buildTextLike(
    CustomFieldDefinition d,
    int filledCount,
    int totalCount,
    Map<String, ({int count, double income, double expense})> buckets,
  ) {
    final entries = buckets.entries.toList()
      ..sort((a, b) {
        final byCount = b.value.count.compareTo(a.value.count);
        return byCount != 0 ? byCount : a.key.compareTo(b.key);
      });
    return TextLikeFieldStats(
      fieldSyncId: d.syncId!,
      name: d.name,
      fieldType: d.fieldType,
      filledCount: filledCount,
      totalCount: totalCount,
      values: [
        for (final e in entries)
          (
            label: e.key,
            count: e.value.count,
            income: e.value.income,
            expense: e.value.expense,
            ratio: filledCount == 0 ? 0.0 : e.value.count / filledCount,
          ),
      ],
    );
  }

  /// 值 → 'yyyy-MM'（不可解析返回 null）。与 [CustomFieldValueCodec.toLabel]
  /// 的日期收敛同源：仅对 date 类型调用（由 switch 分支保证）。
  static String? _monthBucket(dynamic value) {
    if (value == null) return null;
    final s = value.toString().trim();
    if (s.isEmpty) return null;
    final parsed = DateTime.tryParse(s);
    if (parsed == null) return null;
    return '${parsed.year.toString().padLeft(4, '0')}-'
        '${parsed.month.toString().padLeft(2, '0')}';
  }

  /// 值 → 稳定展示标签列表：委托 [CustomFieldValueCodec.toLabels]——值桶键与
  /// 筛选匹配键必须同源（值语义单一入口），避免「桶里有、筛不出」的分叉。
  static List<String> _displayLabels(dynamic value, String fieldType) =>
      CustomFieldValueCodec.toLabels(value, fieldType);
}
