// 搜索页的多维筛选条件与命中判定（纯逻辑，便于单测）。
//
// 从 search_page 的零散 State 字段收敛而来：UI 只负责收集条件与渲染结果，
// 「条件是否为空」与「单条交易是否命中全部条件」放在这里，避免八个维度
// （关键字 / 分类 / 金额 / 日期 / 账户 / 标签 / 附件 / 币种）的判定散落在
// 页面里 —— 加一个维度要翻遍 build、且无法脱离 Widget 测试。

import '../data/db.dart';
import '../data/models/custom_field_values.dart';

/// 自定义字段值筛选条件（prd/custom_field_stats_fullchain F3）。
///
/// 形状即类型（延续 sealed 范式）：值等值与区间语义不同（eq vs between），
/// 穷尽匹配让消费方必须显式处理两种。匹配键走
/// [CustomFieldValueCodec.toLabels] —— 与值桶统计同源（「桶里有、筛得出」）。
sealed class CustomFieldCondition {
  const CustomFieldCondition({
    required this.fieldSyncId,
    required this.fieldName,
    required this.fieldType,
  });

  /// 目标字段定义 syncId（值 JSON 的键）。
  final String fieldSyncId;

  /// 字段名（chip 展示用，由发起方携带，避免查询时反查定义）。
  final String fieldName;

  /// 字段类型（值标签规范化依赖它：日期收敛 yyyy-MM-dd 仅对 date 生效）。
  final String fieldType;

  /// 值等值：该字段的值标签 = [value]（多选列表含该值即命中）。
  const factory CustomFieldCondition.eq({
    required String fieldSyncId,
    required String fieldName,
    required String fieldType,
    required String value,
  }) = CustomFieldConditionEq;

  /// 文本包含：忽略大小写与首尾空白（洞察筛选的文本字段）。
  const factory CustomFieldCondition.contains({
    required String fieldSyncId,
    required String fieldName,
    required String fieldType,
    required String value,
  }) = CustomFieldConditionContains;

  /// 多选任一命中：值标签与 [values] 有交集即命中（洞察多选筛选）。
  const factory CustomFieldCondition.anyOf({
    required String fieldSyncId,
    required String fieldName,
    required String fieldType,
    required Set<String> values,
  }) = CustomFieldConditionAnyOf;

  /// 数值区间：按 abs 值比较，半开 `[lower, upper)`（与分布分档同源）。
  /// [upper] 为 null = 开区间上界（最高档「≥lower」）。
  const factory CustomFieldCondition.between({
    required String fieldSyncId,
    required String fieldName,
    required String fieldType,
    required num lower,
    num? upper,
  }) = CustomFieldConditionBetween;

  /// 单笔交易的字段值是否命中本条件（值语义集中在 [CustomFieldValueCodec]）。
  bool matches(dynamic value);
}

final class CustomFieldConditionEq extends CustomFieldCondition {
  const CustomFieldConditionEq({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.value,
  });

  /// 目标标签（已规范化，与值桶键同源）。
  final String value;

  @override
  bool matches(dynamic v) {
    if (v == null) return false;
    // 列表值（多选）逐元素标签匹配；标量走 toLabel 单标签。
    // 空标签列表 = 未填/脏值 → 不命中。
    final labels = CustomFieldValueCodec.toLabels(v, fieldType);
    return labels.contains(value);
  }
}

final class CustomFieldConditionContains extends CustomFieldCondition {
  const CustomFieldConditionContains({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.value,
  });

  /// 已裁剪的查询文本；匹配时再统一小写。
  final String value;

  @override
  bool matches(dynamic v) {
    final wanted = value.trim().toLowerCase();
    if (wanted.isEmpty || v == null) return false;
    return CustomFieldValueCodec.toLabels(v, fieldType)
        .any((label) => label.toLowerCase().contains(wanted));
  }
}

final class CustomFieldConditionAnyOf extends CustomFieldCondition {
  const CustomFieldConditionAnyOf({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.values,
  });

  final Set<String> values;

  @override
  bool matches(dynamic v) {
    if (values.isEmpty || v == null) return false;
    return CustomFieldValueCodec.toLabels(v, fieldType).any(values.contains);
  }
}

final class CustomFieldConditionBetween extends CustomFieldCondition {
  const CustomFieldConditionBetween({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.lower,
    this.upper,
  });

  final num lower;
  final num? upper;

  @override
  bool matches(dynamic v) {
    if (v == null) return false;
    // 脏值（非数值/列表）不命中区间 —— 与聚合「数值统计只收 num」同口径。
    if (v is! num) return false;
    final a = v.abs();
    return a >= lower && (upper == null || a < upper!);
  }
}

/// 交易搜索筛选条件。全部字段可选，未设 = 该维度不参与过滤。
class TransactionSearchFilter {
  const TransactionSearchFilter({
    this.keyword = '',
    this.categoryId,
    this.minAmount,
    this.maxAmount,
    this.startDate,
    this.endDate,
    this.accountId,
    this.tagIds = const <int>{},
    this.hasAttachment,
    this.currencyCode,
    this.customFieldConditions = const <CustomFieldCondition>[],
  });

  /// 关键字：匹配备注 / 分类显示名 / 金额文本，大小写不敏感、忽略首尾空白。
  final String keyword;

  /// 分类 id：命中该分类本身**或其直接子分类**的交易（与原行为一致）。
  final int? categoryId;

  /// 金额区间，按 `amount.abs()` 比较，闭区间。
  final double? minAmount;
  final double? maxAmount;

  /// 日期区间：开始日 00:00:00 起、结束日 23:59:59 止（含当天）。
  final DateTime? startDate;
  final DateTime? endDate;

  /// 账户 id：命中 from 账户或 to 账户（转账）为该账户的交易。
  final int? accountId;

  /// 标签 id 集合：命中「带其中任意一个标签」的交易（OR 语义）。
  final Set<int> tagIds;

  /// 附件：null = 不限；true = 仅有附件；false = 仅无附件。
  final bool? hasAttachment;

  /// 交易币种（ISO code，大小写不敏感）。
  final String? currencyCode;

  /// 自定义字段值条件：**全部命中**才过（AND 语义，与其余维度正交）。
  final List<CustomFieldCondition> customFieldConditions;

  /// 是否一个条件都没设 —— 此时页面不展示结果（与既有空态口径一致）。
  bool get isEmpty =>
      keyword.trim().isEmpty &&
      categoryId == null &&
      minAmount == null &&
      maxAmount == null &&
      startDate == null &&
      endDate == null &&
      accountId == null &&
      tagIds.isEmpty &&
      hasAttachment == null &&
      (currencyCode == null || currencyCode!.trim().isEmpty) &&
      customFieldConditions.isEmpty;

  bool get isNotEmpty => !isEmpty;

  /// 单条交易是否命中全部已设条件。
  ///
  /// [category] / [categoryDisplayName]：交易分类行与其当前语言显示名
  /// （关键字要能搜分类名，名字依赖 i18n 故由调用方解析后传入）。
  /// [transactionTagIds]：该笔交易已关联的标签 id。
  /// [hasTransactionAttachment]：该笔交易是否有附件。
  /// [ledgerCurrency]：账本本位币 —— 交易未显式记币种（历史行 currencyCode
  /// 为 NULL）时按本位币参与币种匹配，避免它们被币种筛选全部漏掉。
  bool matches({
    required Transaction t,
    Category? category,
    String? categoryDisplayName,
    Set<int> transactionTagIds = const <int>{},
    bool hasTransactionAttachment = false,
    String ledgerCurrency = '',
  }) {
    final kw = keyword.trim().toLowerCase();
    if (kw.isNotEmpty) {
      final note = t.note?.toLowerCase() ?? '';
      final categoryName = (categoryDisplayName ?? '').toLowerCase();
      final amount = t.amount.toString();
      if (!note.contains(kw) &&
          !categoryName.contains(kw) &&
          !amount.contains(kw)) {
        return false;
      }
    }

    if (categoryId != null &&
        category?.id != categoryId &&
        category?.parentId != categoryId) {
      return false;
    }

    if (minAmount != null || maxAmount != null) {
      final amount = t.amount.abs();
      if (minAmount != null && amount < minAmount!) return false;
      if (maxAmount != null && amount > maxAmount!) return false;
    }

    if (startDate != null) {
      final start = DateTime(startDate!.year, startDate!.month, startDate!.day);
      if (t.happenedAt.isBefore(start)) return false;
    }
    if (endDate != null) {
      final end =
          DateTime(endDate!.year, endDate!.month, endDate!.day, 23, 59, 59);
      if (t.happenedAt.isAfter(end)) return false;
    }

    if (accountId != null &&
        t.accountId != accountId &&
        t.toAccountId != accountId) {
      return false;
    }

    if (tagIds.isNotEmpty && !tagIds.any(transactionTagIds.contains)) {
      return false;
    }

    if (hasAttachment != null && hasAttachment != hasTransactionAttachment) {
      return false;
    }

    final wantedCurrency = currencyCode?.trim().toUpperCase() ?? '';
    if (wantedCurrency.isNotEmpty) {
      final own = t.currencyCode?.trim().toUpperCase() ?? '';
      final effective = own.isEmpty ? ledgerCurrency.trim().toUpperCase() : own;
      if (effective != wantedCurrency) return false;
    }

    // 字段值条件：全部命中才过（AND 语义）。未填字段天然不命中。
    if (customFieldConditions.isNotEmpty) {
      final values = CustomFieldValueCodec.decode(t.customValuesJson);
      for (final cond in customFieldConditions) {
        if (!cond.matches(values[cond.fieldSyncId])) return false;
      }
    }

    return true;
  }
}
