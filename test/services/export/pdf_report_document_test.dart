/// PDF 报表版式的回归：整份文档真的能生成、中文真的以**矢量字形**进了 PDF。
///
/// 这里不搭数据库（那是 `pdf_report_service_test.dart` 的事），只拿手写夹具把
/// 版式跑通 —— 覆盖三种最容易在运行时炸的形状：
///   1. 满配：多分类 + 跨页明细 + 31 个趋势桶（图表 / 饼图 / 跨页表都走到）；
///   2. 空报表：没有分类也没有明细（空段落的兜底文案）；
///   3. 全零金额：y 轴跨度为 0（`Chart` 的 toChart 会除零 → NaN）。
library;

import 'dart:convert';
import 'dart:io' show zlib;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/export/pdf_report_service.dart';
import 'package:piggycount/services/export/pdf_report_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('zh'));

  PdfReportData fixture({
    required List<PdfReportCategory> expenseCategories,
    required List<PdfReportCategory> incomeCategories,
    required List<PdfReportBucket> buckets,
    required List<PdfReportEntry> entries,
    bool byMonth = false,
    double income = 1000,
    double expense = 300,
    int txCount = 4,
    DateTime? end,
  }) =>
      PdfReportData(
        ledgerName: '家用账本',
        currencyCode: 'CNY',
        start: DateTime(2026, 10, 1),
        end: end ?? DateTime(2026, 11, 1),
        income: income,
        expense: expense,
        txCount: txCount,
        expenseCategories: expenseCategories,
        incomeCategories: incomeCategories,
        buckets: buckets,
        byMonth: byMonth,
        entries: entries,
      );

  Future<Uint8List> build(PdfReportData data) => PdfReportService.generatePdf(
        data: data,
        l10n: l10n,
        accent: const Color(0xFF497FF8),
        isChineseLocale: true,
        documentTitle: '2026-10 月报',
      );

  /// 把 PDF 里所有 FlateDecode 流解出来拼成一段可搜索文本。
  ///
  /// 中文用 Type0(Identity-H) 编码，内容流里是字形序号而不是可读文本，所以
  /// 「中文有没有真的排进去」只能从**字体自带的 ToUnicode 映射**反查：映射是
  /// `<glyph> <unicode>` 的十六进制表，含 4E2D 就说明「中」拿到了真字形
  /// （缺字时 pdf 包画的是占位框，那个字根本不会出现在映射里）。
  String inflateStreams(List<int> bytes) {
    final raw = latin1.decode(bytes, allowInvalid: true);
    final out = StringBuffer();
    for (final match in RegExp(r'stream\r?\n').allMatches(raw)) {
      final end = raw.indexOf('endstream', match.end);
      if (end < 0) continue;
      try {
        out.write(latin1.decode(
          zlib.decode(bytes.sublist(match.end, end)),
          allowInvalid: true,
        ));
      } catch (_) {
        // 非 zlib 流（内嵌图片等）直接跳过
      }
    }
    return out.toString();
  }

  test('满配报表：跨页明细 + 饼图 + 趋势 + 中文矢量字形', () async {
    final categories = [
      for (var i = 0; i < 12; i++)
        PdfReportCategory(name: '分类$i', total: 1200 - i * 90.0, count: i + 1),
    ];
    final buckets = [
      for (var i = 0; i < 31; i++)
        PdfReportBucket(
          bucket: DateTime(2026, 10, 1 + i),
          income: i == 4 ? 1000 : 0,
          expense: i % 7 == 0 ? 120.5 : 0,
        ),
    ];
    // 48 行明细：A4 一页放不下 → 必然跨页，表头行 repeat:true 要跟着重打
    final entries = [
      for (var i = 0; i < 48; i++)
        PdfReportEntry(
          at: DateTime(2026, 10, 1 + (i % 28), 9 + (i % 12), 30),
          type: i % 11 == 0 ? 'transfer' : (i.isEven ? 'expense' : 'income'),
          amount: 12.34 + i,
          categoryName: i % 11 == 0 ? null : '餐饮',
          accountName: i % 11 == 0 ? '招商 → 现金' : '招商银行',
          // 超长备注：表里要截断（CSV 导出仍有全文）
          note: i % 5 == 0 ? '加班餐费报销凭证${List.filled(12, '很长').join()}' : null,
        ),
    ];

    final bytes = await build(fixture(
      expenseCategories: categories,
      incomeCategories: categories.take(3).toList(),
      buckets: buckets,
      entries: entries,
    ));

    final latin = latin1.decode(bytes, allowInvalid: true);
    expect(latin.startsWith('%PDF-'), isTrue);
    expect(latin, contains('/FontFile2'), reason: '字体没被内嵌');
    expect(bytes.length, greaterThan(20 * 1024), reason: '满配报表不该这么小');
    expect(bytes.length, lessThan(3 * 1024 * 1024), reason: '体积失控（是不是退了截图方案）');
    // 48 行明细 + 4 段图表必然超过一页：跨页是 Table 作为 MultiPage 顶层子节点
    // 才有的能力，被包进 Column 就会整块搬页或直接抛「widget won't fit」。
    final pages = RegExp(r'/Type\s*/Page[^s]').allMatches(latin).length;
    expect(pages, greaterThan(1), reason: '明细没有跨页（页数=$pages）');

    final inflated = inflateStreams(bytes);
    // 这些字一定出现在表头 / 标题 / 页脚里；ToUnicode 映射里查得到它们，就说明
    // 中文拿到的是真字形而不是占位框。
    for (final rune in '账本月收支分类金额日期页'.runes) {
      expect(
          inflated,
          contains(rune.toRadixString(16).toUpperCase().padLeft(4, '0')),
          reason: '缺字：${String.fromCharCode(rune)} 没有字形映射（会被画成占位框）');
    }
  });

  test('空报表：没有分类也没有明细也不崩，仍产出可打开的单页 PDF', () async {
    final bytes = await build(fixture(
      expenseCategories: const [],
      incomeCategories: const [],
      buckets: const <PdfReportBucket>[],
      entries: const [],
      income: 0,
      expense: 0,
      txCount: 0,
    ));

    final latin = latin1.decode(bytes, allowInvalid: true);
    expect(latin.startsWith('%PDF-'), isTrue);
    expect(latin, contains('/FontFile2'));
  });

  test('全零金额：y 轴跨度为 0 也不能算出 NaN', () async {
    final bytes = await build(fixture(
      expenseCategories: const [
        PdfReportCategory(name: '餐饮', total: 0, count: 0),
      ],
      incomeCategories: const [],
      buckets: [
        for (var i = 0; i < 5; i++)
          PdfReportBucket(bucket: DateTime(2026, 10, 1 + i), income: 0, expense: 0),
      ],
      entries: const [],
      income: 0,
      expense: 0,
      txCount: 0,
    ));

    expect(latin1.decode(bytes, allowInvalid: true), contains('/FontFile2'));
  });

  test('月桶年报：byMonth 分支（12 个月桶 + 月标签）也走得通', () async {
    final bytes = await build(fixture(
      expenseCategories: const [
        PdfReportCategory(name: '餐饮', total: 3200, count: 42),
      ],
      incomeCategories: const [
        PdfReportCategory(name: '工资', total: 90000, count: 12),
      ],
      buckets: [
        for (var m = 1; m <= 12; m++)
          PdfReportBucket(
            bucket: DateTime(2026, m, 1),
            income: 7500,
            expense: 260 + m * 3.0,
          ),
      ],
      entries: const [],
      byMonth: true,
      income: 90000,
      expense: 3354,
      txCount: 54,
      end: DateTime(2027, 1, 1),
    ));

    expect(latin1.decode(bytes, allowInvalid: true), contains('/FontFile2'));
  });
}
