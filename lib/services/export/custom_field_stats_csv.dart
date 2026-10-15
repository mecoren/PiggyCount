/// 自定义字段统计导出 CSV 的**行构造**（prd/custom_field_stats_fullchain F4）。
///
/// 两份导出共用「统计项」长表口径：
/// - **聚合 CSV**：一行 = (字段 × 统计项)。字段级列逐行重复，金额型出四指标 +
///   5 档分布行、日期型出按月行、文本系出值排行行；无明细的字段也出一行
///   （填写率 0 也要在导出里可见）。
/// - **明细 CSV**：时间/类型/金额/备注 + 每字段一列（定义顺序），值经
///   [CustomFieldValueCodec.toLabels] 规范化（与值桶键/筛选键同源）。
///
/// 编码（BOM/公式转义）统一走 `csv_builder`；本文件只负责单元格内容，
/// 列序由测试 `custom_field_stats_csv_test.dart` 锁死。
library;

import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../custom_field_stats_service.dart';
import 'ledger_csv.dart';

/// 导出种类：聚合汇总表 / 交易明细。
enum CustomFieldCsvKind { aggregate, detail }

/// 分析页导出回调：产出「表头 + 数据行」后交给调用方（分享/落盘/测试捕获）。
typedef CustomFieldCsvExport = void Function(
    CustomFieldCsvKind kind, List<List<dynamic>> rows);

/// 聚合 CSV：表头 11 列 + (字段 × 统计项) 行。
List<List<dynamic>> buildCustomFieldAggregateCsvRows({
  required AppLocalizations l10n,
  required List<FieldStats> stats,
}) {
  final rows = <List<dynamic>>[
    [
      l10n.customFieldNameLabel,
      l10n.customFieldTypeLabel,
      l10n.customFieldCsvHeaderFilledCount,
      l10n.categoryDetailTotalCount,
      l10n.customFieldAnalysisFillRate,
      l10n.customFieldCsvHeaderStatItem,
      l10n.customFieldCsvHeaderValue,
      l10n.pdfReportColCount,
      l10n.searchSummaryIncome,
      l10n.searchSummaryExpense,
      l10n.pdfReportColPercent,
    ],
  ];
  for (final f in stats) {
    final head = [
      f.name,
      _typeLabel(l10n, f.fieldType),
      f.filledCount,
      f.totalCount,
      '${(f.fillRate * 100).toStringAsFixed(1)}%',
    ];
    switch (f) {
      case AmountFieldStats(:final valueSum, :final valueAvg, :final valueMin,
        :final valueMax, :final dist):
        for (final (label, value) in [
          (l10n.customFieldStatSum, valueSum),
          (l10n.customFieldStatAvg, valueAvg),
          (l10n.customFieldStatMin, valueMin),
          (l10n.customFieldStatMax, valueMax),
        ]) {
          rows.add([...head, label, _money(value), '', '', '', '']);
        }
        for (final b in dist) {
          rows.add([
            ...head,
            AmountFieldStats.distLabel(b.lower, b.upper),
            '',
            b.count,
            '',
            '',
            '',
          ]);
        }
      case DateFieldStats(:final monthly):
        for (final m in monthly) {
          rows.add([
            ...head,
            m.month,
            '',
            m.count,
            _money(m.income),
            _money(m.expense),
            '',
          ]);
        }
      case TextLikeFieldStats(:final values):
        for (final v in values) {
          rows.add([
            ...head,
            v.label,
            '',
            v.count,
            _money(v.income),
            _money(v.expense),
            '${(v.ratio * 100).toStringAsFixed(1)}%',
          ]);
        }
    }
    // 无明细（金额四指标已有行）之外的空字段：仍出一行「空统计项」，
    // 否则导出里完全看不到「这个字段 0 笔填写」。
    final hasRows = switch (f) {
      AmountFieldStats() => true, // 四指标恒有行
      DateFieldStats(:final monthly) => monthly.isNotEmpty,
      TextLikeFieldStats(:final values) => values.isNotEmpty,
    };
    if (!hasRows) {
      rows.add([...head, '', '', '', '', '', '']);
    }
  }
  return rows;
}

/// 明细 CSV：表头 = 时间/类型/金额/备注 + 每字段一列；行序 = [txs] 输入顺序。
List<List<dynamic>> buildCustomFieldDetailCsvRows({
  required AppLocalizations l10n,
  required List<CustomFieldDefinition> defs,
  required List<Transaction> txs,
}) {
  final usableDefs = [
    for (final d in defs)
      if (d.syncId != null && d.syncId!.isNotEmpty) d,
  ];
  final rows = <List<dynamic>>[
    [
      l10n.exportCsvHeaderTime,
      l10n.exportCsvHeaderType,
      l10n.exportCsvHeaderAmount,
      l10n.exportCsvHeaderNote,
      for (final d in usableDefs) d.name,
    ],
  ];
  for (final t in txs) {
    final values = CustomFieldValueCodec.decode(t.customValuesJson);
    rows.add([
      _timeLabel(t.happenedAt),
      ledgerCsvTypeLabel(l10n, t.type),
      (t.nativeAmount ?? t.amount).toStringAsFixed(2),
      t.note ?? '',
      for (final d in usableDefs)
        CustomFieldValueCodec.toLabels(values[d.syncId], d.fieldType)
            .join(','),
    ]);
  }
  return rows;
}

/// 金额列统一两位小数文本（与明细 CSV 金额列 `toStringAsFixed(2)` 同口径）。
/// 直接落 num 会让 Excel 显示浮点尾差（如 144.76999999999998），且与
/// 明细导出的 '144.77' 不一致；计数列保持 int 原样（笔数不该有小数）。
String _money(num v) => v.toStringAsFixed(2);

String _timeLabel(DateTime t) {
  final local = t.toLocal();
  String pad2(int v) => v.toString().padLeft(2, '0');
  return '${local.year}-${pad2(local.month)}-${pad2(local.day)} '
      '${pad2(local.hour)}:${pad2(local.minute)}:${pad2(local.second)}';
}

String _typeLabel(AppLocalizations l10n, String type) {
  switch (type) {
    case CustomFieldType.amount:
      return l10n.customFieldTypeAmount;
    case CustomFieldType.date:
      return l10n.customFieldTypeDate;
    case CustomFieldType.singleSelect:
      return l10n.customFieldTypeSingleSelect;
    case CustomFieldType.multiSelect:
      return l10n.customFieldTypeMultiSelect;
    case CustomFieldType.text:
    default:
      return l10n.customFieldTypeText;
  }
}
