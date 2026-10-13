/// PDF 报表导出：**取数 + 字体 + 生成**的唯一入口。
///
/// 分工：
/// - 本文件：从 Repository 取数（口径与洞察页 / 区间报表页同源）、加载内嵌中文
///   字体、生成字节；
/// - [pdf_report_document]：纯排版（数据 → A4 页面）；
/// - [pdf_report_types]：纯数据模型（便于单测）。
///
/// 为什么不用「截图成图片再塞进 PDF」：截图路线（`renderWidgetToImage`）虽然
/// 免字体，但一页 A4 的位图在 pixelRatio 3 下就是 6MB 级，十几页的年报轻松
/// 几十 MB —— 报销邮件发不出去，也没法在 PDF 里选字/搜索。向量 PDF 带字体
/// 子集后整份只有几百 KB（`pdf` 包只内嵌实际用到的字形）。
library;

import 'dart:typed_data';

import 'package:flutter/material.dart' show Color;
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/widgets.dart' as pw;

import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/analytics_category_rollup.dart';
import '../../utils/category_utils.dart';
import 'pdf_report_document.dart';
import 'pdf_report_types.dart';

/// `getTransactionsByDateRange` 的行类型（含分类 / 账户，明细表要用的字段都在）。
typedef _TxRow = ({
  Transaction t,
  Category? category,
  List<Tag> tags,
  List<TransactionAttachment> attachments,
  Account? account,
});

/// `totalsByDay` 的返回行。
typedef _DayTotal = ({DateTime day, double total});

/// `totalsByCategoryWithHierarchy` 的返回行。
typedef _CategoryRow = ({
  int? id,
  String name,
  String? icon,
  int? parentId,
  int level,
  double total,
  int count,
});

class PdfReportService {
  PdfReportService._();

  /// 内嵌字体资产（Noto Sans SC 子集；生成方式见
  /// `scripts/fetch_pdf_report_font.py`）。
  static const String regularFontAsset =
      'assets/fonts/NotoSansSC-Regular-subset.ttf';
  static const String boldFontAsset =
      'assets/fonts/NotoSansSC-Bold-subset.ttf';

  /// 日桶上限：区间超过这么多天就按月聚桶。
  ///
  /// 与区间报表页 `RangeReportPage.dayChartLimit` 同值同口径 —— 两处都画的是
  /// 「一根柱一天」，不设上限时一年报表会画出 365 根柱，PDF 里会糊成一片。
  static const int dayBucketLimit = 31;

  /// 字体只解析一次（2.5MB × 2 的资产没必要每次导出都读一遍）。
  ///
  /// `pw.Font` 只是「字体字节 + 每个 PDF 文档内一份 PdfTtfFont」的持有者，
  /// 跨文档复用是包的既定用法（`PdfGoogleFonts` 同样缓存）。
  static PdfReportFonts? _fonts;

  static Future<PdfReportFonts> loadFonts() async {
    final cached = _fonts;
    if (cached != null) return cached;
    final regular = pw.Font.ttf(await rootBundle.load(regularFontAsset));
    final bold = pw.Font.ttf(await rootBundle.load(boldFontAsset));
    return _fonts = PdfReportFonts(regular: regular, bold: bold);
  }

  /// 取一份报表的全部数据。
  ///
  /// [start] / [end] 是**半开区间**（`[start, end)`），调用方负责把「月周期」
  /// 换算好 —— 月报用 `periodForLabel`（账本 `monthStartDay`），年报用
  /// `yearRangeFor`，区间报表用选择器给的起止（末日 +1 天）。日历换算刻意不
  /// 放在这里：那是 `lib/utils/month_range.dart` 的既定职责，报表只认区间。
  static Future<PdfReportData> loadData(
    BaseRepository repo, {
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    required AppLocalizations l10n,
  }) async {
    final rows = await Future.wait<dynamic>([
      repo.totalsInRange(ledgerId: ledgerId, start: start, end: end),
      repo.totalsByDay(
          ledgerId: ledgerId, type: 'expense', start: start, end: end),
      repo.totalsByDay(
          ledgerId: ledgerId, type: 'income', start: start, end: end),
      repo.totalsByCategoryWithHierarchy(
          ledgerId: ledgerId, type: 'expense', start: start, end: end),
      repo.totalsByCategoryWithHierarchy(
          ledgerId: ledgerId, type: 'income', start: start, end: end),
      repo.getTransactionsByDateRange(
          ledgerId: ledgerId, startDate: start, endDate: end),
      repo.getLedgerById(ledgerId),
      repo.getAllAccounts(),
    ]);

    final totals = rows[0] as (double, double);
    final byMonth = end.difference(start).inDays > dayBucketLimit;
    final ledger = rows[6] as Ledger?;
    // 账户名索引：明细里转账要拼「转出 → 转入」，而 getTransactionsByDateRange
    // 只带回转出（account），转入需要按 toAccountId 自己查。
    final accounts = {
      for (final a in rows[7] as List<Account>) a.id: a.name,
    };
    final entries = _entries(rows[5] as List<_TxRow>, l10n, accounts);

    return PdfReportData(
      ledgerName: ledger?.name ?? '',
      currencyCode: ledger?.currency.toUpperCase() ?? 'CNY',
      start: start,
      end: end,
      income: totals.$1,
      expense: totals.$2,
      // 笔数与合计同口径：明细已滤掉「不计收支」，转账也不计入（与首页一致）。
      // 刻意**不**用 `countByTypeInRange` —— 它不过滤 exclude_from_stats，
      // 会让「200 元 / 8 笔」里的笔数跟金额对不上账。
      txCount: entries.where((e) => e.type != 'transfer').length,
      expenseCategories: await _categories(
          rows[3] as List<_CategoryRow>, repo, l10n, 'expense'),
      incomeCategories: await _categories(
          rows[4] as List<_CategoryRow>, repo, l10n, 'income'),
      buckets: _buckets(
        rows[1] as List<_DayTotal>,
        rows[2] as List<_DayTotal>,
        byMonth: byMonth,
      ),
      byMonth: byMonth,
      entries: entries,
    );
  }

  /// 生成 PDF 字节。
  ///
  /// [documentTitle] 缺省用 `l10n.pdfReportTitle`；月报 / 年报由调用方传更具体
  /// 的标题（如「2026年10月月报」），标题里的日期一律用数字格式，不新增文案。
  static Future<Uint8List> generatePdf({
    required PdfReportData data,
    required AppLocalizations l10n,
    required Color accent,
    required bool isChineseLocale,
    String? documentTitle,
  }) async {
    final fonts = await loadFonts();
    return buildPdfReportDocument(
      data: data,
      l10n: l10n,
      fonts: fonts,
      accent: PdfReportPalette.of(accent),
      isChineseLocale: isChineseLocale,
      documentTitle: documentTitle,
    );
  }

  // ── 内部换算 ────────────────────────────────────────────────────────────

  /// 一级分类排行（`aggregateTopLevelCategories` 把二级金额并进父分类，与
  /// 洞察页 / 区间报表页同一份聚合）→ 报表模型，并翻译默认分类 key。
  static Future<List<PdfReportCategory>> _categories(
    List<_CategoryRow> rows,
    BaseRepository repo,
    AppLocalizations l10n,
    String type,
  ) async {
    final rolled = await aggregateTopLevelCategories(rows, repo);
    return [
      for (final c in rolled)
        PdfReportCategory(
          name: CategoryUtils.getDisplayNameWith(l10n, c.name, kind: type),
          total: c.total,
          count: c.count,
        ),
    ];
  }

  /// 收入 / 支出的日序列 → 趋势桶（按月聚桶时按自然月合并）。
  ///
  /// `totalsByDay` 已保证区间内逐日连续（缺的日子补 0），所以两张表键集一致；
  /// 仍需并集兜底 —— 一侧查空时不该把另一侧的数据吞掉。
  ///
  /// ⚠️ 归并必须用 `update` 累加，**不能**写成
  /// `{for (final e in days) key(e.day): e.total}` —— 一个月里多天的键相同，
  /// 而 map 字面量的重复键只保留最后一个值：月桶会只剩月末那天的金额
  /// （实测 10 月两笔支出被抹成 0，年报表整年金额全丢）。
  static List<PdfReportBucket> _buckets(
    List<_DayTotal> expenseDays,
    List<_DayTotal> incomeDays, {
    required bool byMonth,
  }) {
    DateTime key(DateTime day) => byMonth
        ? DateTime(day.year, day.month, 1)
        : DateTime(day.year, day.month, day.day);

    final expense = <DateTime, double>{};
    final income = <DateTime, double>{};
    for (final e in expenseDays) {
      expense.update(key(e.day), (v) => v + e.total, ifAbsent: () => e.total);
    }
    for (final e in incomeDays) {
      income.update(key(e.day), (v) => v + e.total, ifAbsent: () => e.total);
    }

    final keys = {...expense.keys, ...income.keys}.toList()..sort();
    return [
      for (final k in keys)
        PdfReportBucket(
          bucket: k,
          income: income[k] ?? 0,
          expense: expense[k] ?? 0,
        ),
    ];
  }

  /// 明细行。金额取 `native_amount ?? amount`（与合计口径一致），
  /// 转账把两侧账户拼成「转出 → 转入」。
  static List<PdfReportEntry> _entries(
    List<_TxRow> rows,
    AppLocalizations l10n,
    Map<int, String> accounts,
  ) {
    final entries = <PdfReportEntry>[];
    for (final row in rows) {
      final t = row.t;
      // 「不计收支」不进报表：合计（`totalsInRange`）本来就把它排除了，明细若
      // 照收，用户会看到「表里五行加起来 13299，合计却写 300」的假 bug。
      if (t.excludeFromStats) continue;
      final isTransfer = t.type == 'transfer';
      // 转账两侧账户都可能在已隐藏账户里（getAllAccounts 已含隐藏），
      // 名字取不到时留 null 由排版层补占位符。
      final fromName =
          row.account?.name ?? (t.accountId == null ? null : accounts[t.accountId]);
      final toName = t.toAccountId == null ? null : accounts[t.toAccountId!];
      entries.add(PdfReportEntry(
        at: t.happenedAt.toLocal(),
        type: t.type,
        amount: t.nativeAmount ?? t.amount,
        // 无分类留 null，由排版层补「未分类」（与分类排行里 SQL 给的
        // 「未分类」同名）；不能落 CategoryUtils 的「默认分类」——同一份报表里
        // 两个名字会让用户以为是两回事。
        categoryName: isTransfer || row.category == null
            ? null
            : CategoryUtils.getDisplayNameWith(l10n, row.category!.name,
                kind: t.type),
        accountName: isTransfer
            ? '${fromName ?? ''} → ${toName ?? ''}'.trim()
            : fromName,
        note: t.note,
      ));
    }
    // 报表按时间**升序**（与账单核对顺序一致），仓储侧给的是降序。
    entries.sort((a, b) => a.at.compareTo(b.at));
    return entries;
  }
}
