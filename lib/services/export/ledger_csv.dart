/// 账本明细 CSV 导出：表头与数据行的**唯一构造处**。
///
/// 为什么单独抽出来：CSV 的列数/列序/单元格格式此前散在 `export_page` 的
/// UI 状态类里（`_export` 方法内联），既没法单测，也容易在增删列时只改
/// 表头或只改行（13 列含 v46 自定义字段列，纯靠人工核对）。这里收敛成
/// 纯函数：输入全是领域对象与 l10n，输出就是 CSV 的行/单元格，
/// 列的「表头 ↔ 行」对齐由 `test/services/ledger_csv_export_test.dart` 锁住。
///
/// 回导侧（`import_confirm_page` 的列匹配 + `data_import_service`）依赖
/// 这些列的语义，改动前先确认往返一致。
library;

import 'dart:convert';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/category_utils.dart';

/// 表头行的 13 列，顺序即列序。
///
/// 与 [buildLedgerCsvRow] 产出的行**必须同序同数**：两处分别增删列会让
/// 回导按位置/表头匹配时整列错位。
List<String> ledgerCsvHeaders(AppLocalizations l10n) => [
      l10n.exportCsvHeaderType,
      l10n.exportCsvHeaderCategory,
      l10n.exportCsvHeaderSubCategory, // 二级分类名称
      l10n.exportCsvHeaderAmount,
      l10n.exportCsvHeaderCurrency, // v30 多币种:交易原币种(反馈10)
      l10n.exportCsvHeaderAccount,
      l10n.exportCsvHeaderFromAccount, // 转出账户
      l10n.exportCsvHeaderToAccount, // 转入账户
      l10n.exportCsvHeaderNote,
      l10n.exportCsvHeaderTime,
      l10n.exportCsvHeaderTags,
      l10n.exportCsvHeaderAttachments, // 附件文件名（逗号分隔）
      l10n.exportCsvHeaderCustomFields, // v46 {字段名: 值} JSON（可回导）
    ];

/// 交易类型列的展示名；未知类型原样返回（兜底不吞掉脏数据）。
String ledgerCsvTypeLabel(AppLocalizations l10n, String type) {
  switch (type) {
    case 'income':
      return l10n.exportTypeIncome;
    case 'expense':
      return l10n.exportTypeExpense;
    case 'transfer':
      return l10n.exportTypeTransfer;
    default:
      return type;
  }
}

/// 一笔交易 → 一行 CSV（列序与 [ledgerCsvHeaders] 一一对应）。
///
/// - [account]：`tx.accountId` 对应的账户（转账时即**转出**账户）。账户名与
///   币种兜底都取它；缺失时账户列留空、币种退回账本本位币。
/// - [toAccount]：`tx.toAccountId` 对应的账户（仅转账用）。
/// - [allCategories]：id → 分类，含一级与二级（二级行要回查父分类名）。
/// - [customValues]：`{fieldSyncId: value}`，null = 该笔没有自定义字段值。
/// - [ledgerBaseCurrency]：账本本位币，`tx.currencyCode` / 账户币种都缺时的兜底。
List<dynamic> buildLedgerCsvRow({
  required AppLocalizations l10n,
  required Transaction tx,
  required Category? category,
  required Account? account,
  required Account? toAccount,
  required Map<int, Category> allCategories,
  required List<String> tagNames,
  required List<String> attachmentFileNames,
  required List<CustomFieldDefinition> customFieldDefinitions,
  required Map<String, dynamic>? customValues,
  required String ledgerBaseCurrency,
}) {
  // 时间列：完整格式含年份与秒，前后各留两个空格增加 Excel 列宽。
  final String timeStr = () {
    try {
      final localTime = tx.happenedAt.toLocal();
      return '  ${localTime.year}-${localTime.month.toString().padLeft(2, '0')}-${localTime.day.toString().padLeft(2, '0')} ${localTime.hour.toString().padLeft(2, '0')}:${localTime.minute.toString().padLeft(2, '0')}:${localTime.second.toString().padLeft(2, '0')}  ';
    } catch (e) {
      return '';
    }
  }();

  // 账户列：转账把两侧账户分列填，普通交易只填账户列。
  final String accountName;
  final String fromAccountName;
  final String toAccountName;
  final String categoryName;
  final String subCategoryName;

  if (tx.type == 'transfer') {
    accountName = '';
    fromAccountName = account?.name ?? '';
    toAccountName = toAccount?.name ?? '';
    categoryName = ''; // 转账没有分类
    subCategoryName = '';
  } else {
    accountName = account?.name ?? '';
    fromAccountName = '';
    toAccountName = '';

    if (category != null) {
      if (category.level == 2 && category.parentId != null) {
        // 二级分类：分类列填一级分类名称，二级分类列填当前分类名称
        final parentCategory = allCategories[category.parentId];
        categoryName = CategoryUtils.getDisplayNameWith(l10n, parentCategory?.name);
        subCategoryName = CategoryUtils.getDisplayNameWith(l10n, category.name);
      } else {
        // 一级分类：分类列填当前分类，二级分类列留空
        categoryName = CategoryUtils.getDisplayNameWith(l10n, category.name);
        subCategoryName = '';
      }
    } else {
      categoryName = '';
      subCategoryName = '';
    }
  }

  // v30 多币种：交易币种为 NULL 的历史行按账户/本位币兜底，与统计读取端
  // 同语义 —— 导出自包含，回导不丢币种。
  final currencyStr = (tx.currencyCode ??
          ((account?.currency.isNotEmpty ?? false) ? account!.currency : null) ??
          ledgerBaseCurrency)
      .toUpperCase();

  return [
    ledgerCsvTypeLabel(l10n, tx.type),
    categoryName,
    subCategoryName,
    tx.amount.toStringAsFixed(2),
    currencyStr,
    accountName,
    fromAccountName,
    toAccountName,
    tx.note ?? '',
    timeStr,
    tagNames.join(','),
    attachmentFileNames.join(','),
    _customFieldsJson(customFieldDefinitions, customValues),
  ];
}

/// v46 自定义字段列：以「字段名」为键、按定义顺序输出 JSON 对象。
///
/// 用 JSON 而不是 `名称=值;…` 拼接：字段名与值里都可能出现分隔符，JSON 无
/// 歧义；同时保留数值类型（金额回导后仍是数字）。定义已被删除的"野值"
/// （键找不到定义）不导出 —— 它们在 UI 上本来就不可见，导出来只会让 CSV
/// 出现无从解释的列。
String _customFieldsJson(
  List<CustomFieldDefinition> definitions,
  Map<String, dynamic>? values,
) {
  if (values == null || values.isEmpty) return '';
  final mapped = <String, dynamic>{
    for (final f in definitions)
      if (f.syncId != null &&
          f.syncId!.isNotEmpty &&
          values.containsKey(f.syncId))
        f.name: values[f.syncId],
  };
  // 一个键都没映射上（值全是"野值"）→ 空串，与「该笔没有值」同一表示。
  // 否则会写出 `{}`：列里出现一个无从解释的对象，且与「无值 = 空串」的口径
  // 分裂（回导侧两者等价，但人看 CSV 时会以为是有效数据）。
  return mapped.isEmpty ? '' : jsonEncode(mapped);
}
