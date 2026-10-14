/// 自定义字段统计导出 CSV（prd/custom_field_stats_fullchain F4，阶段 4 RED）。
///
/// 两份导出的「列 ↔ 内容」契约锁在这里：
/// 1. **聚合 CSV**：一行 = (字段 × 统计项)。字段级列（名称/类型/填写笔数/
///    总笔数/填写率）逐行重复；金额型出 求和/均值/最小/最大 + 5 档分布行，
///    日期型出按月行，文本系出值排行行（含占比）。列序稳定；无明细的字段
///    也出一行（填写率 0 也要可见）。
/// 2. **明细 CSV**：时间/类型/金额/备注 + 每字段一列（定义顺序）；值经
///    [CustomFieldValueCodec.toLabels] 规范化（与值桶/筛选键同源），多选
///    逗号连接、未填/野值留空。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';
import 'package:piggycount/services/export/custom_field_stats_csv.dart';

final AppLocalizations zh = lookupAppLocalizations(const Locale('zh'));

CustomFieldDefinition field({
  required int id,
  required String name,
  required String syncId,
  required String fieldType,
}) =>
    CustomFieldDefinition(
      id: id,
      ledgerId: 1,
      name: name,
      fieldType: fieldType,
      sortOrder: id,
      createdAt: DateTime(2026, 1, 1),
      syncId: syncId,
      isRequired: false,
    );

Transaction tx({
  required DateTime happenedAt,
  String type = 'expense',
  double amount = 12.5,
  double? nativeAmount,
  String? note = '备注',
  String? customValuesJson,
}) =>
    Transaction(
      id: 1,
      ledgerId: 1,
      type: type,
      amount: amount,
      nativeAmount: nativeAmount,
      happenedAt: happenedAt,
      note: note,
      customValuesJson: customValuesJson,
      excludeFromStats: false,
      excludeFromBudget: false,
      reimburseStatus: 'none',
    );

void main() {
  group('聚合 CSV', () {
    AmountFieldStats amountField() => const AmountFieldStats(
          fieldSyncId: 'f-amt',
          name: '押金',
          fieldType: CustomFieldType.amount,
          filledCount: 2,
          totalCount: 4,
          valueSum: 300,
          valueAvg: 150,
          valueMin: 100,
          valueMax: 200,
          dist: [
            (lower: 0, upper: 10, count: 0),
            (lower: 10, upper: 100, count: 1),
            (lower: 100, upper: 1000, count: 1),
            (lower: 1000, upper: 10000, count: 0),
            (lower: 10000, upper: null, count: 0),
          ],
        );

    DateFieldStats dateField() => const DateFieldStats(
          fieldSyncId: 'f-date',
          name: '入住日',
          fieldType: CustomFieldType.date,
          filledCount: 1,
          totalCount: 4,
          monthly: [
            (month: '2026-01', count: 1, income: 0, expense: 100),
          ],
        );

    TextLikeFieldStats textField() => const TextLikeFieldStats(
          fieldSyncId: 'f-sel',
          name: '渠道',
          fieldType: CustomFieldType.singleSelect,
          filledCount: 2,
          totalCount: 4,
          values: [
            (label: '微信', count: 2, income: 0, expense: 200, ratio: 1.0),
            (label: '支付宝', count: 1, income: 50, expense: 0, ratio: 0.5),
          ],
        );

    test('表头 11 列固定列序', () {
      final rows = buildCustomFieldAggregateCsvRows(l10n: zh, stats: const []);
      expect(rows, hasLength(1));
      expect(rows.first, [
        zh.customFieldNameLabel,
        zh.customFieldTypeLabel,
        zh.customFieldCsvHeaderFilledCount,
        zh.categoryDetailTotalCount,
        zh.customFieldAnalysisFillRate,
        zh.customFieldCsvHeaderStatItem,
        zh.customFieldCsvHeaderValue,
        zh.pdfReportColCount,
        zh.searchSummaryIncome,
        zh.searchSummaryExpense,
        zh.pdfReportColPercent,
      ]);
    });

    test('金额型：四指标行 + 5 档分布行，字段级列逐行重复', () {
      final rows =
          buildCustomFieldAggregateCsvRows(l10n: zh, stats: [amountField()]);
      // 1 表头 + 4 指标 + 5 档
      expect(rows, hasLength(10));
      // 金额列（数值/收入/支出）统一两位小数文本，与明细 CSV 金额列同口径
      expect(rows[1], ['押金', '金额', 2, 4, '50.0%', '求和', '300.00', '', '', '', '']);
      expect(rows[2], ['押金', '金额', 2, 4, '50.0%', '均值', '150.00', '', '', '', '']);
      expect(rows[3], ['押金', '金额', 2, 4, '50.0%', '最小', '100.00', '', '', '', '']);
      expect(rows[4], ['押金', '金额', 2, 4, '50.0%', '最大', '200.00', '', '', '', '']);
      // 分布行：统计项=档标签、笔数入列；数值/收支/占比列留空（分布只记笔数）
      expect(rows[5], ['押金', '金额', 2, 4, '50.0%', '0~10', '', 0, '', '', '']);
      expect(rows[6], ['押金', '金额', 2, 4, '50.0%', '10~100', '', 1, '', '', '']);
      expect(rows[9], ['押金', '金额', 2, 4, '50.0%', '≥10000', '', 0, '', '', '']);
    });

    test('金额列消浮点尾差：34.3333…→34.33、144.76999…→144.77', () {
      final f = const AmountFieldStats(
        fieldSyncId: 'f-amt',
        name: '押金',
        fieldType: CustomFieldType.amount,
        filledCount: 3,
        totalCount: 21,
        valueSum: 103,
        valueAvg: 34.333333333333336,
        valueMin: 1,
        valueMax: 99,
        dist: [],
      );
      final rows = buildCustomFieldAggregateCsvRows(l10n: zh, stats: [f]);
      expect(rows[1][6], '103.00');
      expect(rows[2][6], '34.33');
      final t = TextLikeFieldStats(
        fieldSyncId: 'f-sel',
        name: '渠道',
        fieldType: CustomFieldType.singleSelect,
        filledCount: 5,
        totalCount: 21,
        values: const [
          (label: 'x', count: 5, income: 0, expense: 144.76999999999998, ratio: 1),
        ],
      );
      final rows2 = buildCustomFieldAggregateCsvRows(l10n: zh, stats: [t]);
      expect(rows2[1][8], '0.00');
      expect(rows2[1][9], '144.77');
    });

    test('日期型：按月行带收支', () {
      final rows =
          buildCustomFieldAggregateCsvRows(l10n: zh, stats: [dateField()]);
      expect(rows, hasLength(2));
      expect(rows[1],
          ['入住日', '日期', 1, 4, '25.0%', '2026-01', '', 1, '0.00', '100.00', '']);
    });

    test('文本系：值排行行带占比（一位小数百分比）', () {
      final rows =
          buildCustomFieldAggregateCsvRows(l10n: zh, stats: [textField()]);
      expect(rows, hasLength(3));
      expect(rows[1],
          ['渠道', '单选', 2, 4, '50.0%', '微信', '', 2, '0.00', '200.00', '100.0%']);
      expect(rows[2],
          ['渠道', '单选', 2, 4, '50.0%', '支付宝', '', 1, '50.00', '0.00', '50.0%']);
    });

    test('多字段按传入顺序；无明细字段也出一行（填写率 0 可见）', () {
      final emptyText = TextLikeFieldStats(
        fieldSyncId: 'f-empty',
        name: '备注标签',
        fieldType: CustomFieldType.text,
        filledCount: 0,
        totalCount: 4,
        values: const [],
      );
      final rows = buildCustomFieldAggregateCsvRows(
          l10n: zh, stats: [textField(), emptyText]);
      expect(rows, hasLength(4));
      expect(rows[1].first, '渠道');
      expect(rows[2].first, '渠道');
      expect(rows[3], ['备注标签', '文本', 0, 4, '0.0%', '', '', '', '', '', '']);
    });
  });

  group('明细 CSV', () {
    final defs = [
      field(id: 1, name: '押金', syncId: 'f-amt', fieldType: 'amount'),
      field(id: 2, name: '入住日', syncId: 'f-date', fieldType: 'date'),
      field(id: 3, name: '渠道', syncId: 'f-sel', fieldType: 'multiSelect'),
    ];

    test('表头 = 时间/类型/金额/备注 + 每字段一列（定义顺序）', () {
      final rows =
          buildCustomFieldDetailCsvRows(l10n: zh, defs: defs, txs: const []);
      expect(rows, [
        ['时间', '类型', '金额', '备注', '押金', '入住日', '渠道'],
      ]);
    });

    test('值列规范化：金额去尾 0、日期收敛、多选逗号连接', () {
      final rows = buildCustomFieldDetailCsvRows(
        l10n: zh,
        defs: defs,
        txs: [
          tx(
            happenedAt: DateTime(2026, 6, 18, 9, 5, 3),
            nativeAmount: 12.5,
            customValuesJson:
                '{"f-amt":100,"f-date":"2026-06-18T00:00:00.000","f-sel":["微信","现金"]}',
          ),
        ],
      );
      expect(rows[1], [
        '2026-06-18 09:05:03',
        '支出',
        '12.50',
        '备注',
        '100',
        '2026-06-18',
        '微信,现金',
      ]);
    });

    test('金额列按本位币口径（nativeAmount 优先）；未填/野值留空', () {
      final rows = buildCustomFieldDetailCsvRows(
        l10n: zh,
        defs: defs,
        txs: [
          tx(
            happenedAt: DateTime(2026, 6, 17, 8),
            amount: 100,
            nativeAmount: 70,
            customValuesJson: '{"f-amt":1}',
          ),
          tx(
            happenedAt: DateTime(2026, 6, 18, 8),
            amount: 5,
            nativeAmount: null,
            note: null,
            customValuesJson: '{"ghost":"x"}',
          ),
        ],
      );
      expect(rows, hasLength(3));
      // nativeAmount 优先，缺省回落 amount
      expect(rows[1][2], '70.00');
      expect(rows[2][2], '5.00');
      expect(rows[1].sublist(4), ['1', '', '']);
      expect(rows[2].sublist(3), ['', '', '', '']);
    });
  });
}
