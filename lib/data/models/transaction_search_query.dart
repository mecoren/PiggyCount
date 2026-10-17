/// 交易搜索的 SQL 查询参数（数据层）。
///
/// 与 `lib/utils/transaction_search_filter.dart` 的区别：那个是**纯判定逻辑**
/// （UI 与单测共用，逐行 `matches`），本类是**可下推的查询描述** —— 只有能
/// 直接用 WHERE 表达的条件才会出现在这里。搜索页据此让 Drift 只返回命中行，
/// 不再把整本账本的交易读进 Dart 过滤（P1 搜索 SQL 化）。
///
/// 不能下推的两类仍留在 UI 侧做二次精判：
/// - **分类显示名**：名称依赖当前语言（`CategoryUtils.getDisplayName`），
///   数据层只认原始 key。调用方把「显示名命中的分类 id」经
///   [keywordCategoryIds] 传进来，SQL 用 `category_id IN (...)` 参与匹配。
/// - **自定义字段条件**：值标签规范化（日期收敛、多选列表、数值标签）在
///   `CustomFieldValueCodec`，SQL 只做 `custom_values_json IS NOT NULL` 粗筛
///   （[requiresCustomValues]），最终逐条判定交给页面。
class TransactionSearchQuery {
  const TransactionSearchQuery({
    this.keyword = '',
    this.keywordCategoryIds = const <int>[],
    this.categoryId,
    this.minAmount,
    this.maxAmount,
    this.startDate,
    this.endDate,
    this.accountId,
    this.tagIds = const <int>{},
    this.hasAttachment,
    this.currencyCode,
    this.ledgerCurrency = '',
    this.requiresCustomValues = false,
  });

  /// 关键字（已含首尾空白也安全，比较前统一 trim + lowercase）。
  final String keyword;

  /// 关键字命中的分类 id（由 UI 按当前语言显示名解析后传入）。
  final List<int> keywordCategoryIds;

  /// 分类 id：命中该分类本身或其直接子分类。
  final int? categoryId;

  /// 金额区间（按 `abs(amount)`，闭区间）。
  final double? minAmount;
  final double? maxAmount;

  /// 日期区间：开始日 00:00 起、结束日次日 00:00 止（含结束日全天）。
  final DateTime? startDate;
  final DateTime? endDate;

  /// 账户 id：转出或转入账户命中。
  final int? accountId;

  /// 标签 id：带其中任意一个（OR 语义）。
  final Set<int> tagIds;

  /// 附件：null = 不限；true = 仅有；false = 仅无。
  final bool? hasAttachment;

  /// 交易币种（ISO code）；未显式记币种的交易按 [ledgerCurrency] 兜底。
  final String? currencyCode;
  final String ledgerCurrency;

  /// 是否要求 `custom_values_json` 非空（存在自定义字段值条件时由 UI 置位）。
  final bool requiresCustomValues;

  String get normalizedKeyword => keyword.trim().toLowerCase();

  /// 是否没有任何条件 —— 此时页面不展示结果（与既有空态口径一致）。
  bool get isEmpty =>
      normalizedKeyword.isEmpty &&
      categoryId == null &&
      minAmount == null &&
      maxAmount == null &&
      startDate == null &&
      endDate == null &&
      accountId == null &&
      tagIds.isEmpty &&
      hasAttachment == null &&
      (currencyCode == null || currencyCode!.trim().isEmpty) &&
      !requiresCustomValues;

  bool get isNotEmpty => !isEmpty;
}
