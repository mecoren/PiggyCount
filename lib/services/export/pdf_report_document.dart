/// PDF 报表版式：把 [PdfReportData] 排成 A4 多页 PDF。
///
/// 这一层是**纯排版**：只吃 [PdfReportData] + 已加载的字体 + [AppLocalizations]，
/// 不碰数据库、不碰 BuildContext（所以没有暗黑模式分支：报表永远是白底黑字，
/// 打印 / 报销附件都要求这样）。
///
/// 配色一律取 Design Token 的无 context 常量（`PiggyPosterTokens` /
/// `PiggyChartTokens` / `PiggyTokens.*Static`），与分享海报同一套底子，主色由
/// 调用方传入（用户自定义主题色）。字号是 pt（A4 版心），不吃
/// `PiggyTextTokens.fs*`（那是逻辑像素刻度，14pt 打在 A4 上会大得离谱）。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

import '../../data/models/analytics_amount_metric.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../utils/format_utils.dart';
import 'ledger_csv.dart' show ledgerCsvTypeLabel;
import 'pdf_report_types.dart';

/// 已加载的字重对。中文必须内嵌字体，产物见
/// `scripts/fetch_pdf_report_font.py`（Noto Sans SC 子集）。
class PdfReportFonts {
  const PdfReportFonts({required this.regular, required this.bold});

  final pw.Font regular;
  final pw.Font bold;
}

/// 报表配色（PDF 无法读 `context`，只能吃 Token 里的 static 常量）。
///
/// `accent` 由调用方给（用户自定义主题色），其余全部锚到 Token：收入绿 / 支出红
/// 与海报一致，分类色环取 [PiggyChartTokens.seriesColors]，保证「报表里的饼图
/// 配色 = App 里饼图的配色」。
class PdfReportPalette {
  PdfReportPalette({required this.accent})
      : income = of(PiggyPosterTokens.income),
        expense = of(PiggyPosterTokens.expense),
        textPrimary = of(PiggyPosterTokens.textPrimary),
        textSecondary = of(PiggyPosterTokens.textSecondary),
        textTertiary = of(PiggyPosterTokens.textTertiary),
        cardBackground = of(PiggyTokens.cardBackgroundLightStatic),
        divider = of(PiggyTokens.dividerStatic),
        series = [
          for (final c in PiggyChartTokens.seriesColors) of(c),
        ];

  /// Flutter `Color` → `PdfColor`（`PdfColor.fromInt` 吃 0xAARRGGBB）。
  static PdfColor of(Color color) => PdfColor.fromInt(color.toARGB32());

  final PdfColor accent;
  final PdfColor income;
  final PdfColor expense;
  final PdfColor textPrimary;
  final PdfColor textSecondary;
  final PdfColor textTertiary;
  final PdfColor cardBackground;
  final PdfColor divider;
  final List<PdfColor> series;

  /// 第 [index] 个分类的颜色（超出色环长度时回卷）。
  PdfColor seriesAt(int index) => series[index % series.length];
}

/// 版式常量（pt）。
class _D {
  static const double pageMarginH = 32;
  static const double pageMarginTop = 34;
  static const double pageMarginBottom = 30;
  static const double docTitle = 18;
  static const double sectionTitle = 12;
  static const double kpiValue = 15;
  static const double kpiLabel = 8.5;
  static const double table = 8.5;
  static const double caption = 8;
  static const double pieSize = 160;
  static const double trendHeight = 168;
}

/// 分类排行最多列出的条数（超出并「其他」）。
const int _categoryTopN = 8;

/// 生成报表 PDF 字节。
///
/// [accent] 为界面主色（用户可自定义），[isChineseLocale] 决定金额用「万」还是
/// 「k / M」（与 `formatBalance` 同一开关），[documentTitle] 缺省用
/// `l10n.pdfReportTitle`（月报 / 年报由调用方传更具体的标题）。
Future<Uint8List> buildPdfReportDocument({
  required PdfReportData data,
  required AppLocalizations l10n,
  required PdfReportFonts fonts,
  required PdfColor accent,
  required bool isChineseLocale,
  String? documentTitle,
}) async {
  final layout = _PdfReportLayout(
    data: data,
    l10n: l10n,
    palette: PdfReportPalette(accent: accent),
    isChinese: isChineseLocale,
    title: documentTitle ?? l10n.pdfReportTitle,
  );

  final doc = pw.Document(
    title: layout.title,
    author: 'PiggyCount',
    creator: 'PiggyCount',
    producer: 'PiggyCount',
  );

  doc.addPage(
    pw.MultiPage(
      pageFormat: PdfPageFormat.a4,
      margin: const pw.EdgeInsets.fromLTRB(
          _D.pageMarginH, _D.pageMarginTop, _D.pageMarginH, _D.pageMarginBottom),
      theme: pw.ThemeData.withFont(
        base: fonts.regular,
        bold: fonts.bold,
        // 子集外的生僻字回落同族字体（pdf 找不到字形时才不会画成占位框，
        // 见脚本头部说明：user 自填的罕见字仍可能落在子集外）。
        fontFallback: [fonts.regular],
      ),
      // 明细表一页约 24 行：一年的账单轻易超过默认 20 页上限（debug 下会抛
      // 异常）。按行数给一个宽裕的上限，避免「账多的人导不出年报」。
      maxPages: 40 + data.entries.length ~/ 16,
      header: (ctx) => ctx.pageNumber == 1
          ? pw.SizedBox()
          : layout.runningHeader(),
      footer: layout.footer,
      build: (ctx) => layout.body(),
    ),
  );

  return doc.save();
}

/// 版式的全部上下文（把 data / l10n / palette 收在一处，避免每个小组件都传 5 个参数）。
class _PdfReportLayout {
  _PdfReportLayout({
    required this.data,
    required this.l10n,
    required this.palette,
    required this.isChinese,
    required this.title,
  });

  final PdfReportData data;
  final AppLocalizations l10n;
  final PdfReportPalette palette;
  final bool isChinese;
  final String title;

  static final DateFormat _day = DateFormat('yyyy-MM-dd');
  static final DateFormat _stamp = DateFormat('yyyy-MM-dd HH:mm');
  static final DateFormat _axisDay = DateFormat('d');
  static final DateFormat _axisMonth = DateFormat('MM');

  pw.TextStyle get _titleStyle => pw.TextStyle(
      fontSize: _D.docTitle,
      fontWeight: pw.FontWeight.bold,
      color: palette.textPrimary);
  pw.TextStyle get _sectionStyle => pw.TextStyle(
      fontSize: _D.sectionTitle,
      fontWeight: pw.FontWeight.bold,
      color: palette.textPrimary);
  pw.TextStyle get _captionStyle =>
      pw.TextStyle(fontSize: _D.caption, color: palette.textSecondary);
  pw.TextStyle get _tableStyle =>
      pw.TextStyle(fontSize: _D.table, color: palette.textPrimary);
  pw.TextStyle get _tableHeadStyle => pw.TextStyle(
      fontSize: _D.table,
      fontWeight: pw.FontWeight.bold,
      color: palette.textSecondary);

  String _range() =>
      '${_day.format(data.start)} ~ ${_day.format(data.end.subtract(const Duration(days: 1)))}';

  /// 每页都有的紧凑页眉（首页不放，首页是标题块）。
  pw.Widget runningHeader() => pw.Column(children: [
        pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(
                '$title · ${data.ledgerName}',
                style: pw.TextStyle(
                    fontSize: _D.caption,
                    fontWeight: pw.FontWeight.bold,
                    color: palette.textSecondary),
                maxLines: 1,
              ),
            ),
            pw.Text(_range(), style: _captionStyle),
          ],
        ),
        pw.SizedBox(height: 3),
        pw.Divider(color: palette.divider, height: 1, thickness: 0.6),
        pw.SizedBox(height: 8),
      ]);

  pw.Widget footer(pw.Context ctx) => pw.Column(children: [
        pw.SizedBox(height: 6),
        pw.Divider(color: palette.divider, height: 1, thickness: 0.6),
        pw.SizedBox(height: 3),
        pw.Row(children: [
          pw.Expanded(
              child: pw.Text(
            // 非默认金额口径时补一句口径说明：报表数字与界面一致，
            // 但没有这行的话「比记账金额小」会被当成导出算错。
            data.amountMetric == AnalyticsAmountMetric.recorded
                ? l10n.pdfReportFooterNote
                : '${l10n.pdfReportFooterNote} · '
                    '${l10n.analyticsAmountMetricNote}',
            style: _captionStyle,
          )),
          pw.Text(
            l10n.pdfReportPageOf(ctx.pageNumber, ctx.pagesCount),
            style: _captionStyle,
          ),
        ]),
      ]);

  List<pw.Widget> body() => [
        _titleBlock(),
        pw.SizedBox(height: 14),
        ..._summarySection(),
        pw.SizedBox(height: 16),
        ..._trendSection(),
        ..._categorySection('expense', data.expenseCategories),
        ..._categorySection('income', data.incomeCategories),
        ..._detailSection(),
      ];

  // ── 首页标题块 ───────────────────────────────────────────────────────────

  pw.Widget _titleBlock() => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Text(title, style: _titleStyle),
          pw.SizedBox(height: 6),
          pw.Row(children: [
            pw.Expanded(
                child: pw.Text(
                    l10n.pdfReportLedgerLine(data.ledgerName),
                    style: _captionStyle,
                    maxLines: 1)),
            pw.Text(l10n.pdfReportPeriodLine(_range()), style: _captionStyle),
          ]),
          pw.SizedBox(height: 2),
          pw.Text(
            l10n.pdfReportGeneratedAt(_stamp.format(DateTime.now())),
            style: _captionStyle,
          ),
          pw.SizedBox(height: 8),
          pw.Divider(color: palette.divider, height: 1, thickness: 0.8),
        ],
      );

  // ── 收支总览 ─────────────────────────────────────────────────────────────

  List<pw.Widget> _summarySection() => [
        _block([
          _sectionTitle(l10n.pdfReportSummaryTitle),
          pw.SizedBox(height: 8),
          pw.Row(children: [
            _kpi(l10n.homeIncome,
                formatBalance(data.income, data.currencyCode,
                    isChineseLocale: isChinese),
                palette.income),
            pw.SizedBox(width: 8),
            _kpi(l10n.homeExpense,
                formatBalance(data.expense, data.currencyCode,
                    isChineseLocale: isChinese),
                palette.expense),
            pw.SizedBox(width: 8),
            _kpi(l10n.homeBalance,
                formatBalance(data.balance, data.currencyCode,
                    isChineseLocale: isChinese),
                palette.accent),
            pw.SizedBox(width: 8),
            _kpi(l10n.sharePosterAvgDailyExpense,
                formatBalance(data.dailyAvgExpense, data.currencyCode,
                    isChineseLocale: isChinese),
                palette.textPrimary),
          ]),
          pw.SizedBox(height: 6),
          pw.Text(
            l10n.analyticsTxCountShort(data.txCount),
            style: _captionStyle,
          ),
        ]),
      ];

  pw.Widget _kpi(String label, String value, PdfColor color) => pw.Expanded(
        child: pw.Container(
          padding: const pw.EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: pw.BoxDecoration(
            color: palette.cardBackground,
            borderRadius: pw.BorderRadius.circular(6),
          ),
          child: pw.Column(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Text(label,
                  style: pw.TextStyle(
                      fontSize: _D.kpiLabel, color: palette.textSecondary),
                  maxLines: 1),
              pw.SizedBox(height: 3),
              pw.Text(
                value,
                style: pw.TextStyle(
                    fontSize: _D.kpiValue,
                    fontWeight: pw.FontWeight.bold,
                    color: color),
                maxLines: 1,
              ),
            ],
          ),
        ),
      );

  // ── 趋势 ────────────────────────────────────────────────────────────────

  List<pw.Widget> _trendSection() {
    final buckets = data.buckets;
    if (buckets.length < 2) return const [];
    final fmt = data.byMonth ? _axisMonth : _axisDay;

    // 标签抽稀：31 天的日桶全打标签会糊成一片，按「最多 7~8 个」的步长取。
    // 末位单独特判之外还要「离末尾太近就跳过」：12 个月桶下末位前一个刚好落在
    // 步长上，会打出「11 12」两个贴在一起的标签。
    final step = (buckets.length / 7).ceil();
    final last = buckets.length - 1;
    final labels = <String>[
      for (var i = 0; i <= last; i++)
        (i == 0 || i == last || (i % step == 0 && last - i >= step))
            ? fmt.format(buckets[i].bucket)
            : '',
    ];

    var maxValue = 0.0;
    for (final b in buckets) {
      maxValue = math.max(maxValue, math.max(b.income, b.expense));
    }
    // y 轴顶端取「整齐刻度」；全零时给 1，否则 toChart 会因跨度 0 变成 NaN。
    final top = _niceCeil(maxValue <= 0 ? 1 : maxValue);
    final ticks = <double>[0, top / 4, top / 2, top * 3 / 4, top];

    pw.Widget legendDot(PdfColor color, String label) => pw.Row(
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            pw.Container(width: 7, height: 7, color: color),
            pw.SizedBox(width: 4),
            pw.Text(label, style: _captionStyle),
          ],
        );


    return [
      _block([
        _sectionTitle(l10n.pdfReportTrendTitle),
        pw.SizedBox(height: 8),
        pw.Row(children: [
          legendDot(palette.expense, l10n.homeExpense),
          pw.SizedBox(width: 14),
          legendDot(palette.income, l10n.homeIncome),
        ]),
        pw.SizedBox(height: 6),
        pw.SizedBox(
          height: _D.trendHeight,
          child: pw.Chart(
            grid: pw.CartesianGrid(
              xAxis: pw.FixedAxis<double>(
                [for (var i = 0; i < buckets.length; i++) i.toDouble()],
                format: (v) => labels[v.toInt()],
                textStyle: pw.TextStyle(
                    fontSize: _D.caption, color: palette.textTertiary),
                color: palette.divider,
                margin: 4,
              ),
              yAxis: pw.FixedAxis<double>(
                ticks,
                format: (v) =>
                    formatCompactAxis(v.toDouble(), isChinese: isChinese),
                textStyle: pw.TextStyle(
                    fontSize: _D.caption, color: palette.textTertiary),
                color: palette.divider,
                divisions: true,
                divisionsColor: palette.divider,
                ticks: true,
              ),
            ),
            datasets: [
              _line(buckets.map((b) => b.expense).toList(), palette.expense),
              _line(buckets.map((b) => b.income).toList(), palette.income),
            ],
          ),
        ),
      ]),
    ];
  }

  pw.LineDataSet<pw.PointChartValue> _line(List<double> values, PdfColor color) =>
      pw.LineDataSet<pw.PointChartValue>(
        data: [
          for (var i = 0; i < values.length; i++)
            pw.PointChartValue(i.toDouble(), values[i]),
        ],
        color: color,
        lineWidth: 1.4,
        drawPoints: false,
        drawSurface: true,
        surfaceColor: color,
        surfaceOpacity: 0.12,
      );

  // ── 分类构成（饼图 + 排行） ──────────────────────────────────────────────

  List<pw.Widget> _categorySection(String type, List<PdfReportCategory> raw) {
    final word = type == 'expense' ? l10n.homeExpense : l10n.homeIncome;
    // 长尾并「其他」：60 个二级分类的账本全列出来会把饼图切成碎片、表格翻页。
    final cats = _mergeTopN(raw, l10n.commonOther);
    final total = cats.fold<double>(0, (a, b) => a + b.total);
    // 标题 + 饼图 + 排行表整块不可分割：分开挂进 MultiPage 时，标题会被留在
    // 上一页页脚、内容翻到下一页（实测就是这个样子）。
    return [
      _block([
        _sectionTitle(l10n.pdfReportCategoryTitle(word)),
        pw.SizedBox(height: 8),
        if (cats.isEmpty || total <= 0)
          pw.Text(l10n.commonEmpty, style: _captionStyle)
        else
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.SizedBox(
                width: _D.pieSize,
                height: _D.pieSize,
                child: pw.Chart(
                  grid: pw.PieGrid(startAngle: -math.pi / 2),
                  datasets: [
                    for (var i = 0; i < cats.length; i++)
                      pw.PieDataSet(
                        value: cats[i].total,
                        color: palette.seriesAt(i),
                        borderColor: PdfColors.white,
                        borderWidth: 1,
                      ),
                  ],
                ),
              ),
              pw.SizedBox(width: 16),
              pw.Expanded(child: _categoryTable(cats, total)),
            ],
          ),
      ]),
      pw.SizedBox(height: 16),
    ];
  }

  pw.Widget _categoryTable(List<PdfReportCategory> cats, double total) => pw.Table(
        border: null,
        columnWidths: const {
          // 28 是「排名」两个 8.5pt 汉字 + 左右各 3pt 内边距的下限：20 会让表头
          // 折成「排 / 名」两行，整个表头行被撑高。
          0: pw.FixedColumnWidth(28),
          1: pw.FlexColumnWidth(),
          2: pw.FixedColumnWidth(32),
          3: pw.FixedColumnWidth(64),
          4: pw.FixedColumnWidth(38),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(
              border: pw.Border(
                  bottom: pw.BorderSide(color: palette.divider, width: 0.6)),
            ),
            children: [
              _cell(l10n.pdfReportColRank, style: _tableHeadStyle),
              _cell(l10n.pdfReportColCategory, style: _tableHeadStyle),
              _cell(l10n.pdfReportColCount,
                  style: _tableHeadStyle, alignRight: true),
              _cell(l10n.pdfReportColAmount,
                  style: _tableHeadStyle, alignRight: true),
              _cell(l10n.pdfReportColPercent,
                  style: _tableHeadStyle, alignRight: true),
            ],
          ),
          for (var i = 0; i < cats.length; i++)
            pw.TableRow(children: [
              _cell('${i + 1}', style: _tableStyle),
              _cell(
                cats[i].name,
                style: _tableStyle,
                dot: palette.seriesAt(i),
              ),
              _cell('${cats[i].count}', style: _tableStyle, alignRight: true),
              _cell(formatBalanceFull(cats[i].total, data.currencyCode),
                  style: _tableStyle, alignRight: true),
              _cell(
                total <= 0
                    ? '—'
                    : '${(cats[i].total / total * 100).toStringAsFixed(1)}%',
                style: _tableStyle,
                alignRight: true,
              ),
            ]),
        ],
      );

  // ── 交易明细 ────────────────────────────────────────────────────────────

  List<pw.Widget> _detailSection() => [
        // 标题 + 笔数小字整块不可分割（免得标题孤零零留在上一页页脚）
        _block([
          _sectionTitle(l10n.pdfReportDetailTitle),
          pw.SizedBox(height: 8),
          if (data.entries.isEmpty)
            pw.Text(l10n.pdfReportDetailEmpty, style: _captionStyle)
          else ...[
            pw.Text(l10n.analyticsTxCountShort(data.entries.length),
                style: _captionStyle),
            pw.SizedBox(height: 4),
          ],
        ]),
        if (data.entries.isNotEmpty)
          // 表格必须**直接**挂在 MultiPage 的 build 列表里（不包 Column /
          // Inseparable）：Table 的 `canSpan` 为 true，只有顶层子节点才能跨页；
          // 表头行 `repeat: true` 让它每页都重打一次。
          pw.Table(
            border: null,
            columnWidths: const {
              0: pw.FixedColumnWidth(50), // yyyy-MM-dd
              1: pw.FixedColumnWidth(30), // 类型：支出 / 收入 / 转账
              2: pw.FlexColumnWidth(),
              3: pw.FixedColumnWidth(72), // 账户：转账要放下「转出 → 转入」
              4: pw.FlexColumnWidth(),
              5: pw.FixedColumnWidth(68),
            },
            children: [
              pw.TableRow(
                repeat: true,
                decoration: pw.BoxDecoration(
                  border: pw.Border(
                      bottom: pw.BorderSide(color: palette.divider, width: 0.6)),
                ),
                children: [
                  _cell(l10n.pdfReportColDate, style: _tableHeadStyle),
                  _cell(l10n.pdfReportColType, style: _tableHeadStyle),
                  _cell(l10n.pdfReportColCategory, style: _tableHeadStyle),
                  _cell(l10n.pdfReportColAccount, style: _tableHeadStyle),
                  _cell(l10n.pdfReportColNote, style: _tableHeadStyle),
                  _cell(l10n.pdfReportColAmount,
                      style: _tableHeadStyle, alignRight: true),
                ],
              ),
              for (var i = 0; i < data.entries.length; i++)
                _detailRow(data.entries[i], striped: i.isOdd),
            ],
          ),
      ];

  pw.TableRow _detailRow(PdfReportEntry e, {required bool striped}) {
    final isTransfer = e.type == 'transfer';
    final amountColor = isTransfer
        ? palette.textSecondary
        : (e.type == 'income' ? palette.income : palette.textPrimary);
    return pw.TableRow(
      decoration: striped
          ? pw.BoxDecoration(color: palette.cardBackground)
          : null,
      children: [
        _cell(_day.format(e.at), style: _tableStyle),
        _cell(ledgerCsvTypeLabel(l10n, e.type), style: _tableStyle),
        _cell(e.categoryName ?? (isTransfer ? '—' : l10n.commonUncategorized),
            style: _tableStyle),
        _cell(e.accountName ?? '—', style: _tableStyle),
        _cell(_clip(e.note), style: _tableStyle),
        _cell(formatBalanceFull(e.amount, data.currencyCode),
            style: pw.TextStyle(fontSize: _D.table, color: amountColor),
            alignRight: true),
      ],
    );
  }

  // ── 小工具 ──────────────────────────────────────────────────────────────

  /// 把一段「小标题 + 内容」包成**不可分割**的整体。
  ///
  /// 为什么不能直接用 `pw.Column`：pdf 里 `Flex.canSpan => direction == vertical`，
  /// 所以 MultiPage 会**按剩余空间把一列切开** —— 实测「收入分类排行」的标题
  /// 被留在上一页页脚、饼图与排行表翻到下一页。`pw.Inseparable.canSpan` 恒为
  /// false，空间不够时整块搬到下一页。代价：单块高度必须小于一页，否则
  /// MultiPage 会抛 "Widget won't fit into the page"。
  pw.Widget _block(List<pw.Widget> children) => pw.Inseparable(
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: children,
        ),
      );

  pw.Widget _sectionTitle(String text) => pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(children: [
            pw.Container(width: 3, height: 12, color: palette.accent),
            pw.SizedBox(width: 6),
            pw.Text(text, style: _sectionStyle, maxLines: 1),
          ]),
        ],
      );

  /// 单元格：[dot] 非空时在文字前画一个分类色点（与饼图扇区同色）。
  pw.Widget _cell(
    String text, {
    required pw.TextStyle style,
    bool alignRight = false,
    PdfColor? dot,
  }) {
    final child = pw.Text(text,
        style: style, maxLines: 2, overflow: pw.TextOverflow.clip);
    return pw.Padding(
      padding: const pw.EdgeInsets.symmetric(vertical: 4, horizontal: 3),
      child: alignRight
          ? pw.Align(alignment: pw.Alignment.centerRight, child: child)
          : (dot == null
              ? child
              : pw.Row(children: [
                  pw.Container(width: 6, height: 6, color: dot),
                  pw.SizedBox(width: 5),
                  pw.Expanded(child: child),
                ])),
    );
  }

  /// 备注列：表里放不下整段备注，超出截断（CSV 导出仍有全文）。
  static String _clip(String? note, {int max = 24}) {
    if (note == null || note.isEmpty) return '—';
    final flat = note.replaceAll('\n', ' ');
    return flat.length <= max ? flat : '${flat.substring(0, max)}…';
  }

  /// 只留金额最高的前 [_categoryTopN] 个分类，其余合并成一行「其他」。
  static List<PdfReportCategory> _mergeTopN(
      List<PdfReportCategory> src, String otherLabel) {
    if (src.length <= _categoryTopN) return src;
    var total = 0.0;
    var count = 0;
    for (final c in src.skip(_categoryTopN)) {
      total += c.total;
      count += c.count;
    }
    return [
      ...src.take(_categoryTopN),
      PdfReportCategory(name: otherLabel, total: total, count: count),
    ];
  }

  /// y 轴顶端取整到 1 / 2 / 5 × 10ⁿ。
  static double _niceCeil(double v) {
    final exp = (math.log(v) / math.ln10).floor();
    final base = math.pow(10, exp).toDouble();
    final n = v / base;
    final step = n <= 1 ? 1.0 : (n <= 2 ? 2.0 : (n <= 5 ? 5.0 : 10.0));
    return step * base;
  }
}
