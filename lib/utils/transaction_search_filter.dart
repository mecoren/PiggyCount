// 搜索页的多维筛选条件与命中判定（纯逻辑，便于单测）。
//
// 从 search_page 的零散 State 字段收敛而来：UI 只负责收集条件与渲染结果，
// 「条件是否为空」与「单条交易是否命中全部条件」放在这里，避免八个维度
// （关键字 / 分类 / 金额 / 日期 / 账户 / 标签 / 附件 / 币种）的判定散落在
// 页面里 —— 加一个维度要翻遍 build、且无法脱离 Widget 测试。

import '../data/db.dart';

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
      (currencyCode == null || currencyCode!.trim().isEmpty);

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

    return true;
  }
}
