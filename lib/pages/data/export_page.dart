import 'dart:io';
import 'dart:convert';
import 'package:csv/csv.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../l10n/app_localizations.dart';
import 'package:intl/intl.dart';
import '../../providers.dart';
import '../../data/repositories/base_repository.dart';
import '../../data/db.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../widgets/analytics/amount_metric_chip.dart';
import '../../widgets/biz/biz.dart';
import '../../services/export/ledger_csv.dart';
import '../../services/export/pdf_report_service.dart';
import '../../styles/tokens.dart';
import '../../utils/month_range.dart';

import '../../utils/platform_info.dart';

class ExportPage extends ConsumerStatefulWidget {
  const ExportPage({super.key});
  @override
  ConsumerState<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends ConsumerState<ExportPage> {
  bool exporting = false;
  double progress = 0;
  String? savedPath;

  // ── PDF 报表 ──────────────────────────────────────────────────────────────
  //
  // 三种周期各自独立存状态（而不是共用一个 DateTime）：月报记「哪个月」、
  // 年报记「哪一年」、区间记「起止」，来回切 tab 时用户上次选的周期还在，
  // 不会被另一种口径的默认值冲掉。
  bool pdfExporting = false;
  String? pdfSavedPath;
  String _pdfKind = 'month';
  DateTime _pdfMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
  int _pdfYear = DateTime.now().year;
  late DateTime _pdfRangeStart =
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  late DateTime _pdfRangeEnd = DateTime(
      DateTime.now().year, DateTime.now().month, DateTime.now().day + 1);

  static final DateFormat _stampFormat = DateFormat('yyyyMMdd_HHmmss');
  static final DateFormat _dateFormat = DateFormat('yyyy.MM.dd');

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.exportTitle,
        showBack: true,
      ),
      // 标题栏避让做进列表自身 padding（不能包在 body 外），
      // 滚动内容才能穿到标题栏下方、磨砂才有内容可模糊。
      body: ListView(
        // top 含标题栏避让，内容可从标题栏下方穿过
        padding: EdgeInsets.fromLTRB(
          16,
          PiggyTokens.topScrollablePadding(context) + 8,
          16,
          24,
        ),
        children: [
          Text(l10n.exportDescription),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: exporting ? null : () => _export(repo, ledgerId),
            icon: const Icon(Icons.save_alt_outlined),
            label: Text(PlatformInfo.isIOS
                ? l10n.exportButtonIOS
                : l10n.exportButtonAndroid),
          ),
          if (exporting) ...[
            const SizedBox(height: 16),
            Row(
              children: [
                PiggySpinner(size: 20, color: PiggyTokens.primary(context)),
                const SizedBox(width: 12),
                Expanded(
                  child: LinearProgressIndicator(
                      value: progress == 0 ? null : progress),
                ),
              ],
            ),
          ],
          if (savedPath != null) ...[
            const SizedBox(height: 12),
            Text(l10n.exportSavedTo(savedPath!)),
          ],
          const SizedBox(height: 28),
          _pdfSection(context, l10n),
        ],
      ),
    );
  }

  // ── PDF 报表区块 ──────────────────────────────────────────────────────────

  Widget _pdfSection(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.exportPdfSectionTitle,
            style: PiggyTextTokens.strongTitle(context)),
        const SizedBox(height: 4),
        Text(
          l10n.exportPdfSectionDesc,
          style: PiggyTextTokens.caption(context)
              .copyWith(color: PiggyTokens.textSecondary(context)),
        ),
        const SizedBox(height: 12),
        WaitSlidingSegmentedControl<String>(
          selected: _pdfKind,
          height: 34,
          fontSize: PiggyTextTokens.fs13,
          segments: [
            WaitSlidingSegment(value: 'month', label: l10n.exportPdfKindMonth),
            WaitSlidingSegment(value: 'year', label: l10n.exportPdfKindYear),
            WaitSlidingSegment(value: 'range', label: l10n.exportPdfKindRange),
          ],
          onValueChanged: (value) => setState(() => _pdfKind = value),
        ),
        const SizedBox(height: 12),
        // 金额口径（全局，与洞察页 / 区间报表同一枚 chip）：PDF 数字随它走，
        // 报表页与导出口径必须一致（报销 / 对账场景）。说明另起一行 —— 与 chip
        // 同排会被挤成半句（窄屏）。
        const Align(
          alignment: Alignment.centerLeft,
          child: AmountMetricChip(compact: false),
        ),
        const AmountMetricNote(padding: EdgeInsets.only(top: 6)),
        const SizedBox(height: 12),
        // 周期行：与区间报表页的「区间卡」同款（点整行换周期）
        Material(
          color: PiggyTokens.surface(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
          child: InkWell(
            borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
            onTap: pdfExporting ? null : _pickPdfPeriod,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Icon(Icons.calendar_today_outlined,
                      size: 18, color: PiggyTokens.primary(context)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(_pdfPeriodLabel(),
                        style: PiggyTextTokens.strongTitle(context)),
                  ),
                  Text(
                    l10n.rangeReportChangeRange,
                    style: PiggyTextTokens.caption(context)
                        .copyWith(color: PiggyTokens.textTertiary(context)),
                  ),
                  Icon(Icons.expand_more,
                      color: PiggyTokens.textTertiary(context)),
                ],
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: pdfExporting ? null : _exportPdf,
          icon: const Icon(Icons.picture_as_pdf_outlined),
          label: Text(
              pdfExporting ? l10n.exportPdfGenerating : l10n.exportPdfButton),
        ),
        if (pdfExporting) ...[
          const SizedBox(height: 16),
          Row(
            children: [
              PiggySpinner(size: 20, color: PiggyTokens.primary(context)),
              const SizedBox(width: 12),
              Expanded(
                child: Text(l10n.exportPdfGenerating,
                    style: PiggyTextTokens.caption(context)),
              ),
            ],
          ),
        ],
        if (pdfSavedPath != null) ...[
          const SizedBox(height: 12),
          Text(l10n.exportSavedTo(pdfSavedPath!)),
        ],
      ],
    );
  }

  /// 周期标签一律用**数字格式**（2026-10 / 2026 / 2026.10.01 ~ 2026.10.31）：
  /// 与洞察页的周期导航行同款，不新增「X年X月」这类要翻译的文案，跨语言也稳。
  String _pdfPeriodLabel() {
    switch (_pdfKind) {
      case 'year':
        return '$_pdfYear';
      case 'range':
        return '${_dateFormat.format(_pdfRangeStart)} ~ '
            '${_dateFormat.format(_pdfRangeEnd.subtract(const Duration(days: 1)))}';
      case 'month':
      default:
        return '${_pdfMonth.year}-${_pdfMonth.month.toString().padLeft(2, '0')}';
    }
  }

  Future<void> _pickPdfPeriod() async {
    final now = DateTime.now();
    switch (_pdfKind) {
      case 'year':
        final picked = await showWheelDatePicker(
          context,
          initial: DateTime(_pdfYear, 1, 1),
          mode: WheelDatePickerMode.y,
          maxDate: now,
        );
        if (picked == null || !mounted) return;
        setState(() => _pdfYear = picked.year);
        return;
      case 'range':
        final picked = await showPiggyRangePickerSheet(
          context,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year, now.month, now.day),
          initialStart: _pdfRangeStart,
          initialEnd: _pdfRangeEnd.subtract(const Duration(days: 1)),
        );
        if (picked == null || !mounted) return;
        setState(() {
          _pdfRangeStart = picked.start;
          // 选择器给的是「含末日」，统计口径统一按半开区间 [start, end)。
          // 用「日 + 1」而不是 `+ Duration(days: 1)`：夏令时切换日加 24h 会偏。
          _pdfRangeEnd =
              DateTime(picked.end.year, picked.end.month, picked.end.day + 1);
        });
        return;
      case 'month':
      default:
        final picked = await showWheelDatePicker(
          context,
          initial: _pdfMonth,
          mode: WheelDatePickerMode.ym,
          maxDate: now,
        );
        if (picked == null || !mounted) return;
        setState(() => _pdfMonth = DateTime(picked.year, picked.month, 1));
    }
  }

  /// 当前选中的周期 → 半开区间 `[start, end)`。
  ///
  /// 月报 / 年报按**账本 `monthStartDay`** 划周期（`lib/utils/month_range.dart`
  /// 是唯一口径），否则「每月 10 号记账」的用户拿到的月报会跟首页对不上。
  (DateTime, DateTime) _pdfPeriod(int monthStartDay) {
    switch (_pdfKind) {
      case 'year':
        final r = yearRangeFor(_pdfYear, monthStartDay);
        return (r.start, r.end);
      case 'range':
        return (_pdfRangeStart, _pdfRangeEnd);
      case 'month':
      default:
        final r =
            periodForLabel(_pdfMonth.year, _pdfMonth.month, monthStartDay);
        return (r.start, r.end);
    }
  }

  String _pdfKindLabel(AppLocalizations l10n) {
    switch (_pdfKind) {
      case 'year':
        return l10n.exportPdfKindYear;
      case 'range':
        return l10n.exportPdfKindRange;
      case 'month':
      default:
        return l10n.exportPdfKindMonth;
    }
  }

  Future<void> _exportPdf() async {
    // 首个 await 前把 context 相关的东西都取出来（l10n / 主色 / 账本 / 口径）
    final l10n = AppLocalizations.of(context);
    final accent = PiggyTokens.primary(context);
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    final monthStartDay = ref.read(currentMonthStartDayProvider);
    final isChinese = _isChineseLocale();
    // 标题 = 周期 + 报表类型（「2026-10 月报」），跨语言不需要新文案
    final documentTitle = '${_pdfPeriodLabel()} ${_pdfKindLabel(l10n)}';

    setState(() {
      pdfExporting = true;
      pdfSavedPath = null;
    });
    try {
      final (start, end) = _pdfPeriod(monthStartDay);
      final data = await PdfReportService.loadData(
        repo,
        ledgerId: ledgerId,
        start: start,
        end: end,
        l10n: l10n,
        amountMetric: ref.read(analyticsAmountMetricProvider),
      );
      final bytes = await PdfReportService.generatePdf(
        data: data,
        l10n: l10n,
        accent: accent,
        isChineseLocale: isChinese,
        documentTitle: documentTitle,
      );

      final target = await _targetDirectory();
      final ts = _stampFormat.format(DateTime.now());
      final path = p.join(target.directory, 'piggycount_report_$ts.pdf');
      await File(path).writeAsBytes(bytes, flush: true);

      if (!mounted) return;
      setState(() {
        pdfSavedPath = path;
        pdfExporting = false;
      });
      final saved = path;
      await _notifySaved(saved, target.shareAfter);
    } catch (e) {
      if (!mounted) return;
      setState(() => pdfExporting = false);
      final l10nError = AppLocalizations.of(context);
      await AppDialog.error(context,
          title: l10nError.exportFailedTitle, message: e.toString());
    }
  }

  /// PDF 里的金额单位（万 / k）与界面语言一致，复用区间报表页同款判据。
  bool _isChineseLocale() {
    final locale = ref.read(languageProvider);
    return locale?.languageCode == 'zh' ||
        (locale == null &&
            Localizations.localeOf(context).languageCode == 'zh');
  }

  // ── 落地目录 / 完成提示（CSV 与 PDF 共用） ────────────────────────────────

  /// 导出落地目录：iOS 写应用文档目录并走系统分享；Android 直写公共
  /// `Download/PiggyCount`。两种导出（CSV / PDF）共用，避免又抄一份。
  Future<({String directory, bool shareAfter})> _targetDirectory() async {
    if (PlatformInfo.isIOS) {
      final docDir = await getApplicationDocumentsDirectory();
      return (directory: docDir.path, shareAfter: true);
    }
    const downloadPath = '/storage/emulated/0/Download/PiggyCount';
    final dir = Directory(downloadPath);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return (directory: downloadPath, shareAfter: false);
  }

  Future<void> _notifySaved(String path, bool shareAfter) async {
    if (!mounted) return;
    final l10nDialog = AppLocalizations.of(context);
    if (shareAfter) {
      // 触发分享面板
      await SharePlus.instance.share(
          ShareParams(files: [XFile(path)], text: l10nDialog.exportShareText));
      // 分享面板关闭后再校验,页面已销毁则不再弹成功提示
      if (!mounted) return;
      await AppDialog.info(context,
          title: l10nDialog.exportSuccessTitle,
          message: l10nDialog.exportSuccessMessageIOS(path));
    } else {
      await AppDialog.info(context,
          title: l10nDialog.exportSuccessTitle,
          message: l10nDialog.exportSuccessMessageAndroid(path));
    }
  }

  // ── CSV 导出 ──────────────────────────────────────────────────────────────

  Future<void> _export(BaseRepository repo, int ledgerId) async {
    // 在首个 await 前获取本地化实例,避免 async gap 后使用 BuildContext
    final l10n = AppLocalizations.of(context);
    try {
      setState(() {
        exporting = true;
        progress = 0;
        savedPath = null;
      });
      final target = await _targetDirectory();

      // 获取交易和分类数据
      final transactionsWithCategory =
          await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;
      final total = transactionsWithCategory.length;
      // 表头与数据行都由 services/export/ledger_csv 唯一构造（列序对齐可单测）
      final rows = <List<dynamic>>[ledgerCsvHeaders(l10n)];

      // 批量获取所有交易的标签
      final transactionIds =
          transactionsWithCategory.map((tx) => tx.t.id).toList();
      final tagsMap = await repo.getTagsForTransactions(transactionIds);

      // 批量获取所有交易的附件
      final attachmentsMap =
          await repo.getAttachmentsForTransactions(transactionIds);

      // v46 自定义字段：定义（按 sortOrder）用于把交易上的值翻译成用户看得懂
      // 的字段名；值批量取一次，避免逐条查询（N+1）。
      final customFieldDefs = await repo.getDefinitionsForLedger(ledgerId);
      final customValuesMap = customFieldDefs.isEmpty
          ? const <int, Map<String, dynamic>>{}
          : await repo.getValuesForTransactions(transactionIds);

      // 缓存所有账户信息，避免重复查询
      final allAccounts = await repo.getAllAccounts();
      final accountMap = {for (var acc in allAccounts) acc.id: acc};

      // v30 多币种:账本本位币(currencyCode 为 NULL 的历史行按账户/本位币兜底,
      // 与统计读取端同语义 —— 导出自包含,回导不丢币种)
      final ledgerData = await repo.getLedgerById(ledgerId);
      final ledgerBase = ((ledgerData?.currency.isNotEmpty ?? false)
              ? ledgerData!.currency
              : 'CNY')
          .toUpperCase();

      // 缓存所有分类信息（包括父分类）
      final incomeCategories = await repo.getTopLevelCategories('income');
      final expenseCategories = await repo.getTopLevelCategories('expense');
      final allCategories = <int, Category>{};
      for (final cat in [...incomeCategories, ...expenseCategories]) {
        allCategories[cat.id] = cat;
        // 获取子分类
        final subCategories = await repo.getSubCategories(cat.id);
        for (final subCat in subCategories) {
          allCategories[subCat.id] = subCat;
        }
      }

      // await 后校验 mounted,后续循环中会将 context 传给工具方法
      if (!mounted) return;

      for (int i = 0; i < transactionsWithCategory.length; i++) {
        final txWithCat = transactionsWithCategory[i];
        final t = txWithCat.t;
        rows.add(buildLedgerCsvRow(
          l10n: l10n,
          tx: t,
          category: txWithCat.category,
          // 转账时 account 即转出账户（账户名与币种兜底都用它）
          account: t.accountId != null ? accountMap[t.accountId] : null,
          toAccount: accountMap[t.toAccountId],
          allCategories: allCategories,
          tagNames: (tagsMap[t.id] ?? const []).map((tag) => tag.name).toList(),
          attachmentFileNames: (attachmentsMap[t.id] ?? const [])
              .map((att) => att.fileName)
              .toList(),
          customFieldDefinitions: customFieldDefs,
          customValues: customValuesMap[t.id],
          ledgerBaseCurrency: ledgerBase,
        ));
        if (i % 50 == 0) {
          setState(() => progress = (i + 1) / (total == 0 ? 1 : total));
        }
      }

      // csv 8.x：ListToCsvConverter 已随 7.0 重写移除，改由 Csv 编解码器承担。
      // 保持行尾 '\n'（默认是 '\r\n'）与旧行为一致。
      final csvStr = Csv(lineDelimiter: '\n').encode(rows);
      final ts = _stampFormat.format(DateTime.now());
      final path = p.join(target.directory, 'piggycount_$ts.csv');

      // 添加UTF-8 BOM标记，确保Excel正确识别中文编码
      const utf8Bom = '\uFEFF';
      await File(path).writeAsString(utf8Bom + csvStr,
          encoding: Encoding.getByName('utf-8')!);
      setState(() {
        savedPath = path;
        exporting = false;
        progress = 1;
      });
      await _notifySaved(path, target.shareAfter);
    } catch (e) {
      if (!mounted) return;
      setState(() => exporting = false);
      final l10nError = AppLocalizations.of(context);
      await AppDialog.error(context,
          title: l10nError.exportFailedTitle, message: e.toString());
    }
  }
}
