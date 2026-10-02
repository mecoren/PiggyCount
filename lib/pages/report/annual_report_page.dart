import 'dart:typed_data';
import 'package:drift/drift.dart' as drift;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../styles/tokens.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../utils/month_range.dart';
import '../../utils/currencies.dart';
import '../../utils/widget_capture.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/posters/annual_report_poster.dart';
import '../../data/db.dart';
import '../../services/export/share_poster_types.dart';
import '../../services/export/share_poster_service.dart';
import '../../services/data/category_service.dart';

/// 年度账单数据
class AnnualReportData {
  final int year;
  final int totalDays;
  final int totalRecords;
  final double totalIncome;
  final double totalExpense;
  final double netSavings;
  final List<CategoryTotal> topExpenseCategories;
  final List<({int month, double income, double expense})> monthlyData;
  final Transaction? largestExpense;
  final Transaction? largestIncome;
  final Transaction? firstRecord;
  final Category? largestExpenseCategory;
  final Category? largestIncomeCategory;
  final Category? firstRecordCategory;
  final int maxConsecutiveDays;

  const AnnualReportData({
    required this.year,
    required this.totalDays,
    required this.totalRecords,
    required this.totalIncome,
    required this.totalExpense,
    required this.netSavings,
    required this.topExpenseCategories,
    required this.monthlyData,
    this.largestExpense,
    this.largestIncome,
    this.firstRecord,
    this.largestExpenseCategory,
    this.largestIncomeCategory,
    this.firstRecordCategory,
    this.maxConsecutiveDays = 0,
  });
}

/// 年度账单数据 Provider
final annualReportDataProvider =
    FutureProvider.family<AnnualReportData?, int>((ref, year) async {
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);
  final db = ref.watch(databaseProvider);

  // 获取年度收支总额
  final (income, expense) =
      await repo.yearlyTotals(ledgerId: ledgerId, year: year);

  if (income == 0 && expense == 0) {
    return null; // 无数据
  }

  // 获取年度交易记录(年 = 12 个自定义周期,design D4;[start, end) 半开)
  final ledger = await repo.getLedgerById(ledgerId);
  final sd = (ledger?.monthStartDay ?? 1).clamp(1, 28);
  final yr = yearRangeFor(year, sd);
  final startDate = yr.start;
  final endDate = yr.end;
  final transactions = await repo.getTransactionsByLedgerInRange(
    ledgerId: ledgerId,
    start: startDate,
    end: endDate,
  );

  // 计算记账天数
  // P7：DateFormat 提出循环（intl 构造不便宜，万行级循环内构造浪费明显）
  final dayKeyFormat = DateFormat('yyyy-MM-dd');
  final uniqueDays = <String>{};
  for (final tx in transactions) {
    uniqueDays.add(dayKeyFormat.format(tx.happenedAt));
  }
  final totalDays = uniqueDays.length;

  // 获取分类统计
  final categoryTotals = await repo.totalsByCategory(
    ledgerId: ledgerId,
    type: 'expense',
    start: startDate,
    end: endDate,
  );

  // 计算总支出用于百分比
  final totalExpenseForPercent =
      categoryTotals.fold<double>(0, (sum, c) => sum + c.total);

  // 转换为 CategoryTotal 列表
  final topCategories = categoryTotals.take(5).map((c) {
    return CategoryTotal(
      id: c.id,
      name: c.name,
      icon: c.icon,
      total: c.total,
      percentage:
          totalExpenseForPercent > 0 ? c.total / totalExpenseForPercent : 0,
    );
  }).toList();

  // 获取月度数据
  // 单条 SQL 按「周期标签月」聚合（此前串行 12 次 monthlyTotals = 12 次
  // 查询往返）。startDay>1 时周期与自然月错位，直接按自然月分组会算错
  // 月份归属 —— 用与 labelForDate 相同的规则在 SQL 内计算标签月。
  final sdValue = sd;
  final monthRows = await db.customSelect(
    "WITH t AS (SELECT "
    "strftime('%Y-%m', happened_at, 'unixepoch', 'localtime', "
    "CASE WHEN CAST(strftime('%d', happened_at, 'unixepoch', 'localtime') AS INTEGER) >= ?3 "
    "THEN 'start of month' ELSE '-1 month' END) AS label, "
    'type AS type, '
    'COALESCE(native_amount, amount) AS v '
    'FROM transactions '
    'WHERE ledger_id = ?1 AND exclude_from_stats = 0 '
    'AND happened_at >= ?2 AND happened_at < ?4) '
    "SELECT label, "
    "SUM(CASE type WHEN 'income' THEN v ELSE 0 END) AS income, "
    "SUM(CASE type WHEN 'expense' THEN v ELSE 0 END) AS expense "
    'FROM t GROUP BY label',
    variables: [
      drift.Variable<int>(ledgerId),
      drift.Variable<DateTime>(startDate),
      drift.Variable<int>(sdValue),
      drift.Variable<DateTime>(endDate),
    ],
    readsFrom: {db.transactions},
  ).get();
  final monthMap = <int, ({double income, double expense})>{
    for (final r in monthRows)
      int.parse(r.read<String>('label').split('-')[1]): (
        income: (r.read<double>('income') as num?)?.toDouble() ?? 0.0,
        expense: (r.read<double>('expense') as num?)?.toDouble() ?? 0.0,
      ),
  };
  final monthlyData = <({int month, double income, double expense})>[
    for (int m = 1; m <= 12; m++)
      (
        month: m,
        income: monthMap[m]?.income ?? 0.0,
        expense: monthMap[m]?.expense ?? 0.0,
      ),
  ];

  // 找出最大支出、最大收入、首笔记录
  Transaction? largestExpense;
  Transaction? largestIncome;
  Transaction? firstRecord;

  // 「最大单笔」按折算值(nativeAmount)比较,否则多币种下 5000 JPY(≈250 CNY)
  // 会因原币数字大被误判为比 300 CNY 更大的支出。展示仍是各笔原币金额。
  double conv(Transaction t) => t.nativeAmount ?? t.amount;
  for (final tx in transactions) {
    if (tx.type == 'expense') {
      if (largestExpense == null || conv(tx) > conv(largestExpense)) {
        largestExpense = tx;
      }
    } else if (tx.type == 'income') {
      if (largestIncome == null || conv(tx) > conv(largestIncome)) {
        largestIncome = tx;
      }
    }
    if (firstRecord == null || tx.happenedAt.isBefore(firstRecord.happenedAt)) {
      firstRecord = tx;
    }
  }

  // 获取分类信息
  Category? largestExpenseCategory;
  Category? largestIncomeCategory;
  Category? firstRecordCategory;

  if (largestExpense?.categoryId != null) {
    largestExpenseCategory =
        await repo.getCategoryById(largestExpense!.categoryId!);
  }
  if (largestIncome?.categoryId != null) {
    largestIncomeCategory =
        await repo.getCategoryById(largestIncome!.categoryId!);
  }
  if (firstRecord?.categoryId != null) {
    firstRecordCategory = await repo.getCategoryById(firstRecord!.categoryId!);
  }

  // 计算最长连续记账天数
  final sortedDays = uniqueDays.toList()..sort();
  int maxConsecutive = 0;
  int currentConsecutive = 1;

  for (int i = 1; i < sortedDays.length; i++) {
    final prev = DateTime.parse(sortedDays[i - 1]);
    final curr = DateTime.parse(sortedDays[i]);
    if (curr.difference(prev).inDays == 1) {
      currentConsecutive++;
      if (currentConsecutive > maxConsecutive) {
        maxConsecutive = currentConsecutive;
      }
    } else {
      currentConsecutive = 1;
    }
  }
  if (sortedDays.length == 1) maxConsecutive = 1;

  return AnnualReportData(
    year: year,
    totalDays: totalDays,
    totalRecords: transactions.length,
    totalIncome: income,
    totalExpense: expense,
    netSavings: income - expense,
    topExpenseCategories: topCategories,
    monthlyData: monthlyData,
    largestExpense: largestExpense,
    largestIncome: largestIncome,
    firstRecord: firstRecord,
    largestExpenseCategory: largestExpenseCategory,
    largestIncomeCategory: largestIncomeCategory,
    firstRecordCategory: firstRecordCategory,
    maxConsecutiveDays: maxConsecutive,
  );
});

/// 年度账单页面
class AnnualReportPage extends ConsumerStatefulWidget {
  final int? initialYear;

  const AnnualReportPage({super.key, this.initialYear});

  @override
  ConsumerState<AnnualReportPage> createState() => _AnnualReportPageState();
}

class _AnnualReportPageState extends ConsumerState<AnnualReportPage> {
  late PageController _pageController;
  int _currentPage = 0;
  late int _selectedYear;

  /// 各 _buildPage* 方法签名不带 l10n(历史原因),统一经此取词。
  AppLocalizations l10nInsight(BuildContext context) =>
      AppLocalizations.of(context);

  /// 页面金额的币种符号（同 [l10nInsight] 的「统一经此取词」思路）。
  ///
  /// 口径 = **账本本位币**：本页所有金额都是 `COALESCE(native_amount, amount)`
  /// （见年度汇总 SQL），与年/月/账本总结海报（A1）同一来源。历史实现写死
  /// '¥'；后来一度传主币种（baseCurrencyProvider）—— 主币种≠账本币种时
  /// 整页/整张海报的符号还是错的。屏幕符号与分享海报必须同源。
  String get currencySymbol => getCurrencySymbol(_ledgerCurrencyCode);

  /// 当前账本的本位币代码（ISO 大写，兜底 CNY）。
  String get _ledgerCurrencyCode {
    final currency =
        ref.read(currentLedgerProvider).asData?.value?.currency ?? '';
    final code = currency.trim();
    return code.isEmpty ? 'CNY' : code.toUpperCase();
  }

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    // 如果传入了初始年份则使用，否则使用当前年份
    _selectedYear = widget.initialYear ?? DateTime.now().year;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final dataAsync = ref.watch(annualReportDataProvider(_selectedYear));

    return Scaffold(
      backgroundColor: primaryColor,
      body: dataAsync.when(
        loading: () => _buildLoading(l10n),
        error: (e, _) => _buildError(l10n, e.toString()),
        data: (data) {
          if (data == null) {
            return _buildNoData(l10n);
          }
          return _buildContent(context, data);
        },
      ),
    );
  }

  Widget _buildLoading(AppLocalizations l10n) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: Colors.white),
          const SizedBox(height: 16),
          Text(
            l10n.annualReportGenerating,
            style: const TextStyle(color: Colors.white, fontSize: 16),
          ),
        ],
      ),
    );
  }

  Widget _buildError(AppLocalizations l10n, String error) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.error_outline, color: Colors.white, size: 48),
          const SizedBox(height: 16),
          Text(
            '${l10n.commonError}: $error',
            style: const TextStyle(color: Colors.white),
          ),
          const SizedBox(height: 16),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonBack,
                style: const TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _buildNoData(AppLocalizations l10n) {
    // 空态文字/图标默认白色;用户选浅主题色(如蜂蜜黄)时白字对比度
    // 跌破 WCAG,按 primary 亮度切换深色
    final primary = ref.read(primaryColorProvider);
    final onPrimary = primary.computeLuminance() > 0.5
        ? Colors.black.withValues(alpha: 0.7)
        : Colors.white;
    return SafeArea(
      child: Column(
        children: [
          _buildHeader(l10n),
          Expanded(
            child: Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.inbox_outlined, color: onPrimary, size: 64),
                  const SizedBox(height: 16),
                  Text(
                    l10n.annualReportNoData(_selectedYear),
                    style: TextStyle(color: onPrimary, fontSize: 16),
                  ),
                  const SizedBox(height: 24),
                  _buildYearSelector(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close, color: Colors.white),
            tooltip: l10n.commonClose,
            onPressed: () => Navigator.pop(context),
          ),
          const Spacer(),
          _buildYearSelector(),
          const Spacer(),
          const SizedBox(width: 48), // Balance the close button
        ],
      ),
    );
  }

  Widget _buildYearSelector() {
    final currentYear = DateTime.now().year;
    final years = List.generate(5, (i) => currentYear - i);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
      ),
      child: DropdownButton<int>(
        value: _selectedYear,
        // 浮层走项目口径：卡片底色 + radiusLg 圆角（与 popover / 选择器同源），
        // 底色仍是海报页主题色（该页整屏都是主题色渐变，白底浮层会突兀）
        dropdownColor: ref.watch(primaryColorProvider),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        underline: const SizedBox(),
        icon: const Icon(Icons.arrow_drop_down, color: Colors.white),
        style: const TextStyle(
            color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
        items: years.map((year) {
          return DropdownMenuItem(
            value: year,
            child: Text('$year'),
          );
        }).toList(),
        onChanged: (year) {
          if (year != null) {
            setState(() => _selectedYear = year);
          }
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      child: Column(
        children: [
          _buildHeader(l10n),
          Expanded(
            child: PageView(
              controller: _pageController,
              onPageChanged: (page) => setState(() => _currentPage = page),
              children: [
                _buildPage1Overview(context, data),
                _buildPageInsights(context, data), // 年度洞察
                _buildPageIncomeVsExpense(context, data), // 收支对比
                _buildPage2Categories(context, data),
                _buildPage3MonthlyTrend(context, data),
                _buildPage4SpecialMoments(context, data),
                _buildPage5Achievements(context, data),
              ],
            ),
          ),
          _buildPageIndicator(7), // 7页
          const SizedBox(height: 16),
          _buildBottomActions(l10n),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildPageIndicator(int pageCount) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(pageCount, (index) {
        final isActive = index == _currentPage;
        return AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          margin: const EdgeInsets.symmetric(horizontal: 4),
          width: isActive ? 24 : 8,
          height: 8,
          decoration: BoxDecoration(
            color:
                isActive ? Colors.white : Colors.white.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
          ),
        );
      }),
    );
  }

  Widget _buildBottomActions(AppLocalizations l10n) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton.icon(
          onPressed: _generatePoster,
          icon: const Icon(Icons.share),
          label: Text(l10n.annualReportShareButton),
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.white,
            foregroundColor: ref.watch(primaryColorProvider),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
          ),
        ),
      ),
    );
  }

  Future<void> _generatePoster() async {
    final dataAsync = ref.read(annualReportDataProvider(_selectedYear));
    final data = dataAsync.valueOrNull;
    if (data == null) return;

    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.read(primaryColorProvider);
    final currencyCode = _ledgerCurrencyCode;

    // Show loading：项目统一阻塞进度弹窗（禁止点外部 / 返回键关闭）
    final block = showBlockingProgressDialog(
      context,
      title: l10n.annualReportGenerating,
    );

    try {
      // Precache logo image —— key 必须和 annual_report_poster.dart 的
      // Image.asset(cacheWidth: 256) 一致，否则预热的是另一个缓存条目，海报上会空出 logo
      await precacheImage(
        ResizeImage(const AssetImage('assets/logo2.png'), width: 256),
        context,
      );

      // Create poster widget
      // U1：统一截屏入口（pixelRatio 3.0，替代旧 2.0 —— 同一张海报此前
      // 从首页/我的入口分享是高清的，从年报预览入口低 33%）
      if (!mounted) return; // precacheImage 异步间隙后用 context 前确认挂载
      final pngBytes = await renderWidgetToImage(
        context,
        AnnualReportPoster(
          data: data,
          primaryColor: primaryColor,
          currencyCode: currencyCode,
        ),
      );
      if (pngBytes == null) throw Exception('Failed to render poster');

      if (!mounted) return;
      await block.close(); // Close loading dialog

      // Show preview dialog
      if (!mounted) return;
      await showDialog(
        context: context,
        builder: (dialogContext) => _AnnualReportPosterPreview(
          initialImageBytes: pngBytes,
          data: data,
          primaryColor: primaryColor,
          currencyCode: currencyCode,
        ),
      );
    } catch (e) {
      if (!mounted) return;
      // close() 幂等：渲染失败时 loading 弹窗可能尚未关闭
      await block.close();
      if (!mounted) return;
      showToast(context, '${l10n.commonError}: $e');
    }
  }

  // ==================== Page 1: Overview ====================
  Widget _buildPage1Overview(BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 标题
          Text(
            l10n.annualReportPage1Title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.annualReportPage1Subtitle(data.year),
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 32),

          // 记账天数和笔数
          Row(
            children: [
              Expanded(
                child: _buildStatCard(
                  icon: Icons.calendar_today_rounded,
                  label: l10n.annualReportTotalDays,
                  value: '${data.totalDays}',
                  unit: l10n.annualReportUnitDay,
                ),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: _buildStatCard(
                  icon: Icons.edit_note_rounded,
                  label: l10n.annualReportTotalRecords,
                  value: '${data.totalRecords}',
                  unit: l10n.annualReportUnitEntries,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),

          // 收支卡片
          _buildAmountCard(
            icon: Icons.trending_up_rounded,
            label: l10n.annualReportTotalIncome,
            amount: data.totalIncome,
            color: PiggyTokens.success(context),
          ),
          const SizedBox(height: 12),
          _buildAmountCard(
            icon: Icons.trending_down_rounded,
            label: l10n.annualReportTotalExpense,
            amount: data.totalExpense,
            color: PiggyTokens.error(context),
          ),
          const SizedBox(height: 12),
          _buildAmountCard(
            icon: data.netSavings >= 0
                ? Icons.savings_rounded
                : Icons.warning_rounded,
            label: l10n.annualReportNetSavings,
            amount: data.netSavings,
            color: data.netSavings >= 0
                ? PiggyTokens.success(context)
                : PiggyTokens.error(context),
            showSign: true,
          ),
        ],
      ),
    );
  }

  Widget _buildStatCard({
    required IconData icon,
    required String label,
    required String value,
    required String unit,
  }) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Column(
        children: [
          Icon(icon, color: Colors.white, size: 28),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 32,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text(
                  unit,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAmountCard({
    required IconData icon,
    required String label,
    required double amount,
    required Color color,
    bool showSign = false,
  }) {
    final formatter = NumberFormat('#,##0.00', 'zh_CN');
    final sign = showSign ? (amount >= 0 ? '+' : '-') : '';

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            ),
            child: Icon(icon, color: color, size: 24),
          ),
          const SizedBox(width: 16),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              color: PiggyTokens.textSecondary(context),
            ),
          ),
          const Spacer(),
          Text(
            '$sign$currencySymbol${formatter.format(amount.abs())}',
            style: TextStyle(
              fontSize: 22,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 年度洞察页 ====================
  Widget _buildPageInsights(BuildContext context, AnnualReportData data) {
    final formatter = NumberFormat('#,##0.00', 'zh_CN');
    final primaryColor = ref.watch(primaryColorProvider);

    // 计算各种洞察数据
    final avgExpensePerRecord =
        data.totalRecords > 0 ? data.totalExpense / data.totalRecords : 0.0;

    // 计算年度总天数：过去年份用全年天数，当前年份用截至今天的天数
    final now = DateTime.now();
    final sd = ref.watch(currentMonthStartDayProvider);
    final yr = yearRangeFor(data.year, sd);
    final isCurrentYear = !now.isBefore(yr.start) && now.isBefore(yr.end);
    final yearEnd =
        isCurrentYear ? now : yr.end.subtract(const Duration(days: 1));
    final yearStart = yr.start;
    final totalCalendarDays = yearEnd.difference(yearStart).inDays + 1;

    final dailyAvg =
        totalCalendarDays > 0 ? data.totalExpense / totalCalendarDays : 0;
    final monthlyAvg = data.totalExpense / 12;

    // 找出记账最多的月份
    int busiestMonth = 1;
    double maxMonthlyTotal = 0;
    for (final m in data.monthlyData) {
      final total = m.income + m.expense;
      if (total > maxMonthlyTotal) {
        maxMonthlyTotal = total;
        busiestMonth = m.month;
      }
    }

    // 储蓄率
    final savingsRate =
        data.totalIncome > 0 ? (data.netSavings / data.totalIncome * 100) : 0.0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            AppLocalizations.of(context).annualReportInsightTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            AppLocalizations.of(context).annualReportInsightSubtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 24),

          // 洞察卡片
          _buildInsightItem(
            icon: Icons.receipt_long_rounded,
            title: l10nInsight(context).annualReportAvgPerTxTitle,
            value: '$currencySymbol${formatter.format(avgExpensePerRecord)}',
            description: l10nInsight(context).annualReportAvgPerTxDesc,
            primaryColor: primaryColor,
          ),
          const SizedBox(height: 12),

          _buildInsightItem(
            icon: Icons.schedule_rounded,
            title: l10nInsight(context).annualReportAvgDailyTitle,
            value: '$currencySymbol${formatter.format(dailyAvg)}',
            description: l10nInsight(context).annualReportAvgDailyDesc,
            primaryColor: primaryColor,
          ),
          const SizedBox(height: 12),

          _buildInsightItem(
            icon: Icons.date_range_rounded,
            title: l10nInsight(context).annualReportAvgMonthlyTitle,
            value: '$currencySymbol${formatter.format(monthlyAvg)}',
            description: l10nInsight(context).annualReportAvgMonthlyDesc,
            primaryColor: primaryColor,
          ),
          const SizedBox(height: 12),

          _buildInsightItem(
            icon: Icons.calendar_month_rounded,
            title: l10nInsight(context).annualReportActiveMonthTitle,
            value: l10nInsight(context).annualReportMonthValue(busiestMonth),
            description: l10nInsight(context).annualReportActiveMonthDesc,
            primaryColor: primaryColor,
          ),
          const SizedBox(height: 12),

          _buildInsightItem(
            icon: Icons.category_rounded,
            title: l10nInsight(context).annualReportCategoryCountTitle,
            value: l10nInsight(context)
                .annualReportCategoryCountValue(data.topExpenseCategories.length),
            description: l10nInsight(context).annualReportCategoryCountDesc,
            primaryColor: primaryColor,
          ),
          const SizedBox(height: 12),

          // 储蓄率（仅在有收入数据时显示）
          if (data.totalIncome > 0)
            _buildInsightItem(
              icon: Icons.savings_rounded,
              title: l10nInsight(context).annualReportSavingsRateTitle,
              value: '${savingsRate.toStringAsFixed(1)}%',
              description: savingsRate >= 0
                  ? l10nInsight(context).annualReportSavingsRateDescPos
                  : l10nInsight(context).annualReportSavingsRateDescNeg,
              primaryColor: savingsRate >= 0
                  ? PiggyTokens.success(context)
                  : PiggyTokens.error(context),
            ),
        ],
      ),
    );
  }

  Widget _buildInsightItem({
    required IconData icon,
    required String title,
    required String value,
    required String description,
    required Color primaryColor,
  }) {
    // 判断是否使用特殊颜色（红/绿）
    final isSpecialColor = primaryColor == PiggyTokens.success(context) ||
        primaryColor == PiggyTokens.error(context);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Row(
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            ),
            child: Icon(icon, color: Colors.white, size: 24),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  description,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: isSpecialColor ? primaryColor : Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== 收支对比页 ====================
  Widget _buildPageIncomeVsExpense(
      BuildContext context, AnnualReportData data) {
    final formatter = NumberFormat('#,##0', 'zh_CN');

    // 找出最高和最低月份
    double maxIncome = 0;
    double maxExpense = 0;
    int maxIncomeMonth = 1;
    int maxExpenseMonth = 1;

    for (final m in data.monthlyData) {
      if (m.income > maxIncome) {
        maxIncome = m.income;
        maxIncomeMonth = m.month;
      }
      if (m.expense > maxExpense) {
        maxExpense = m.expense;
        maxExpenseMonth = m.month;
      }
    }

    final maxValue = maxIncome > maxExpense ? maxIncome : maxExpense;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10nInsight(context).annualReportCompareTitle,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10nInsight(context).annualReportCompareSubtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 24),

          // 图例
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: PiggyTokens.success(context),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10nInsight(context).analyticsIncome,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                ),
              ),
              const SizedBox(width: 24),
              Container(
                width: 12,
                height: 12,
                decoration: BoxDecoration(
                  color: PiggyTokens.error(context),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                l10nInsight(context).analyticsExpense,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 14,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),

          // 月度对比条形图
          ...data.monthlyData.map((m) {
            final incomeRatio = maxValue > 0 ? m.income / maxValue : 0.0;
            final expenseRatio = maxValue > 0 ? m.expense / maxValue : 0.0;
            final isMaxIncome = m.month == maxIncomeMonth;
            final isMaxExpense = m.month == maxExpenseMonth;

            return Padding(
              padding: const EdgeInsets.only(bottom: 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 月份标签
                  Row(
                    children: [
                      Text(
                        l10nInsight(context).annualReportMonthValue(m.month),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      if (isMaxIncome)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: PiggyTokens.success(context)
                                .withValues(alpha: 0.2),
                            borderRadius:
                                BorderRadius.circular(PiggyDimens.radiusXs),
                          ),
                          child: Text(
                            l10nInsight(context).annualReportTopIncome,
                            style: TextStyle(
                              color: PiggyTokens.success(context),
                              fontSize: 10,
                            ),
                          ),
                        ),
                      if (isMaxExpense)
                        Container(
                          margin: EdgeInsets.only(left: isMaxIncome ? 6 : 0),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: PiggyTokens.error(context)
                                .withValues(alpha: 0.2),
                            borderRadius:
                                BorderRadius.circular(PiggyDimens.radiusXs),
                          ),
                          child: Text(
                            l10nInsight(context).annualReportTopExpense,
                            style: TextStyle(
                              color: PiggyTokens.error(context),
                              fontSize: 10,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  // 收入条
                  Row(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius:
                                    BorderRadius.circular(PiggyDimens.radiusXs),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: incomeRatio.clamp(0.0, 1.0),
                              child: Container(
                                height: 16,
                                decoration: BoxDecoration(
                                  color: PiggyTokens.success(context),
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radiusXs),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: Text(
                          '$currencySymbol${formatter.format(m.income)}',
                          style: TextStyle(
                            color: PiggyTokens.success(context),
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  // 支出条
                  Row(
                    children: [
                      Expanded(
                        child: Stack(
                          children: [
                            Container(
                              height: 16,
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.1),
                                borderRadius:
                                    BorderRadius.circular(PiggyDimens.radiusXs),
                              ),
                            ),
                            FractionallySizedBox(
                              widthFactor: expenseRatio.clamp(0.0, 1.0),
                              child: Container(
                                height: 16,
                                decoration: BoxDecoration(
                                  color: PiggyTokens.error(context),
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radiusXs),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 80,
                        child: Text(
                          '$currencySymbol${formatter.format(m.expense)}',
                          style: TextStyle(
                            color: PiggyTokens.error(context),
                            fontSize: 12,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            );
          }),
        ],
      ),
    );
  }

  // ==================== Page 2: Categories ====================
  Widget _buildPage2Categories(BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);
    final formatter = NumberFormat('#,##0.00', 'zh_CN');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.annualReportPage2Title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.annualReportPage2Subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 32),

          // TOP 分类列表
          ...data.topExpenseCategories.asMap().entries.map((entry) {
            final index = entry.key;
            final category = entry.value;
            final rankColors = [
              const Color(0xFFFFD700),
              const Color(0xFFC0C0C0),
              const Color(0xFFCD7F32),
              Colors.white.withValues(alpha: 0.6),
              Colors.white.withValues(alpha: 0.6),
            ];

            return Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
                ),
                child: Row(
                  children: [
                    // 排名
                    Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: rankColors[index],
                        shape: BoxShape.circle,
                      ),
                      child: Center(
                        child: Text(
                          '${index + 1}',
                          style: TextStyle(
                            // 底色亮度自适应:金银铜牌(亮底)用深字,
                            // 半透明白徽(叠在深主题色上)与深主题色下用浅字,
                            // 避免 black54 在深色主题上跌破对比度
                            color: index < 3
                                ? Colors.black87
                                : (Theme.of(context).brightness ==
                                        Brightness.dark
                                    ? Colors.white
                                    : Colors.black87),
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    // 图标
                    if (category.icon != null)
                      Icon(
                        CategoryService.getCategoryIcon(category.icon),
                        color: Colors.white,
                        size: 24,
                      ),
                    const SizedBox(width: 12),
                    // 名称
                    Expanded(
                      child: Text(
                        category.name,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    // 金额和占比
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '$currencySymbol${formatter.format(category.total)}',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          '${(category.percentage * 100).toStringAsFixed(1)}%',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  // ==================== Page 3: Monthly Trend ====================
  Widget _buildPage3MonthlyTrend(BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);
    final formatter = NumberFormat('#,##0', 'zh_CN');

    // 找出最高和最低支出月份
    double maxExpense = 0;
    double minExpense = double.infinity;
    int maxMonth = 1;
    int minMonth = 1;

    for (final m in data.monthlyData) {
      if (m.expense > maxExpense) {
        maxExpense = m.expense;
        maxMonth = m.month;
      }
      if (m.expense < minExpense && m.expense > 0) {
        minExpense = m.expense;
        minMonth = m.month;
      }
    }

    // 如果没有支出，重置最小值
    if (minExpense == double.infinity) minExpense = 0;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.annualReportPage3Title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.annualReportPage3Subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 24),

          // 最高/最低月份
          Row(
            children: [
              Expanded(
                child: _buildHighlightCard(
                  label: l10n.annualReportHighestMonth,
                  value: '$maxMonth月',
                  subValue: '$currencySymbol${formatter.format(maxExpense)}',
                  color: PiggyTokens.error(context),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _buildHighlightCard(
                  label: l10n.annualReportLowestMonth,
                  value: '$minMonth月',
                  subValue: '$currencySymbol${formatter.format(minExpense)}',
                  color: PiggyTokens.success(context),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),

          // 简易柱状图
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            ),
            child: Column(
              children: [
                // 柱状图
                SizedBox(
                  height: 200,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: data.monthlyData.map((m) {
                      final heightRatio =
                          maxExpense > 0 ? m.expense / maxExpense : 0.0;
                      return Expanded(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 2),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.end,
                            children: [
                              Container(
                                height: 160 * heightRatio,
                                decoration: BoxDecoration(
                                  color: m.month == maxMonth
                                      ? PiggyTokens.error(context)
                                      : m.month == minMonth
                                          ? PiggyTokens.success(context)
                                          : Colors.white.withValues(alpha: 0.6),
                                  borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(
                                          PiggyDimens.radiusXs)),
                                ),
                              ),
                              const SizedBox(height: 8),
                              Text(
                                '${m.month}',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.7),
                                  fontSize: 11,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHighlightCard({
    required String label,
    required String value,
    required String subValue,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: PiggyTextTokens.label(context),
          ),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: color,
              fontSize: 24,
              fontWeight: FontWeight.bold,
            ),
          ),
          Text(
            subValue,
            style: TextStyle(
              color: color.withValues(alpha: 0.7),
              fontSize: 14,
            ),
          ),
        ],
      ),
    );
  }

  // ==================== Page 4: Special Moments ====================
  Widget _buildPage4SpecialMoments(
      BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);
    final dateFormatter = DateFormat('MM月dd日');

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.annualReportPage4Title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.annualReportPage4Subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 32),

          // 最大支出
          if (data.largestExpense != null)
            _buildMomentCard(
              icon: Icons.arrow_downward_rounded,
              label: l10n.annualReportLargestExpense,
              amount: data.largestExpense!.amount,
              note: data.largestExpense!.note ??
                  data.largestExpenseCategory?.name ??
                  '',
              date: dateFormatter.format(data.largestExpense!.happenedAt),
              color: PiggyTokens.error(context),
            ),

          if (data.largestIncome != null) ...[
            const SizedBox(height: 16),
            _buildMomentCard(
              icon: Icons.arrow_upward_rounded,
              label: l10n.annualReportLargestIncome,
              amount: data.largestIncome!.amount,
              note: data.largestIncome!.note ??
                  data.largestIncomeCategory?.name ??
                  '',
              date: dateFormatter.format(data.largestIncome!.happenedAt),
              color: PiggyTokens.success(context),
            ),
          ],

          if (data.firstRecord != null) ...[
            const SizedBox(height: 16),
            _buildMomentCard(
              icon: Icons.flag_rounded,
              label: l10n.annualReportFirstRecord,
              amount: data.firstRecord!.amount,
              note: data.firstRecord!.note ??
                  data.firstRecordCategory?.name ??
                  '',
              date: dateFormatter.format(data.firstRecord!.happenedAt),
              color: ref.watch(primaryColorProvider),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildMomentCard({
    required IconData icon,
    required String label,
    required double amount,
    required String note,
    required String date,
    required Color color,
  }) {
    final formatter = NumberFormat('#,##0.00', 'zh_CN');

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                ),
                child: Icon(icon, color: color, size: 20),
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: PiggyTextTokens.body(context)
                    .copyWith(color: PiggyTokens.textSecondary(context)),
              ),
              const Spacer(),
              Text(
                date,
                style: PiggyTextTokens.label(context)
                    .copyWith(color: PiggyTokens.textTertiary(context)),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '$currencySymbol${formatter.format(amount)}',
            style: TextStyle(
              color: color,
              fontSize: 28,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (note.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              note,
              style: PiggyTextTokens.body(context)
                  .copyWith(color: PiggyTokens.textSecondary(context)),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  // ==================== Page 5: Achievements ====================
  Widget _buildPage5Achievements(BuildContext context, AnnualReportData data) {
    final l10n = AppLocalizations.of(context);

    // 定义成就
    final achievements =
        <({String title, String desc, IconData icon, bool unlocked})>[
      (
        title: l10n.annualReportAchievementConsistent,
        desc:
            l10n.annualReportAchievementConsistentDesc(data.maxConsecutiveDays),
        icon: Icons.local_fire_department_rounded,
        unlocked: data.maxConsecutiveDays >= 7,
      ),
      (
        title: l10n.annualReportAchievementSaver,
        desc: l10n.annualReportAchievementSaverDesc,
        icon: Icons.savings_rounded,
        unlocked: data.netSavings > 0,
      ),
      (
        title: l10n.annualReportAchievementDetail,
        desc: l10n.annualReportAchievementDetailDesc(data.totalRecords),
        icon: Icons.auto_awesome_rounded,
        unlocked: data.totalRecords >= 100,
      ),
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.annualReportPage5Title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 32,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.annualReportPage5Subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 16,
            ),
          ),
          const SizedBox(height: 32),

          // 成就列表
          ...achievements.map((a) => Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: _buildAchievementCard(
                  icon: a.icon,
                  title: a.title,
                  desc: a.desc,
                  unlocked: a.unlocked,
                ),
              )),
        ],
      ),
    );
  }

  Widget _buildAchievementCard({
    required IconData icon,
    required String title,
    required String desc,
    required bool unlocked,
  }) {
    final primaryColor = ref.watch(primaryColorProvider);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: unlocked ? Colors.white : Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Row(
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: unlocked
                  ? primaryColor.withValues(alpha: 0.1)
                  : PiggyTokens.iconTertiary(context).withValues(alpha: 0.2),
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color:
                  unlocked ? primaryColor : PiggyTokens.iconTertiary(context),
              size: 28,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    color: unlocked
                        ? PiggyTokens.textPrimary(context)
                        : PiggyTokens.textTertiary(context),
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  desc,
                  style: TextStyle(
                    color: unlocked
                        ? PiggyTokens.textSecondary(context)
                        : PiggyTokens.textTertiary(context),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
          if (unlocked)
            Icon(
              Icons.check_circle,
              color: primaryColor,
              size: 28,
            )
          else
            Icon(
              Icons.lock_outline,
              color: PiggyTokens.textTertiary(context),
              size: 24,
            ),
        ],
      ),
    );
  }
}

/// 年度账单海报预览对话框
class _AnnualReportPosterPreview extends StatefulWidget {
  final Uint8List initialImageBytes;
  final AnnualReportData data;
  final Color primaryColor;
  final String currencyCode;

  const _AnnualReportPosterPreview({
    required this.initialImageBytes,
    required this.data,
    required this.primaryColor,
    required this.currencyCode,
  });

  @override
  State<_AnnualReportPosterPreview> createState() =>
      _AnnualReportPosterPreviewState();
}

class _AnnualReportPosterPreviewState
    extends State<_AnnualReportPosterPreview> {
  late Uint8List _imageBytes;
  bool _hideIncome = false;
  bool _isGenerating = false;

  @override
  void initState() {
    super.initState();
    _imageBytes = widget.initialImageBytes;
  }

  Future<void> _toggleHideIncome() async {
    setState(() {
      _hideIncome = !_hideIncome;
      _isGenerating = true;
    });

    try {
      // 重新生成海报
      // U1：统一截屏入口（见 renderWidgetToImage 注释）
      final pngBytes = await renderWidgetToImage(
        context,
        AnnualReportPoster(
          data: widget.data,
          primaryColor: widget.primaryColor,
          hideIncome: _hideIncome,
          currencyCode: widget.currencyCode,
        ),
      );
      if (pngBytes == null) throw Exception('Failed to render poster');

      if (mounted) {
        setState(() {
          _imageBytes = pngBytes;
          _isGenerating = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isGenerating = false);
        showToast(context, AppLocalizations.of(context).commonError);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    // 外壳走项目图片预览统一件（[PiggyImagePreviewDialog]）：透明底 + 限高
    // 预览区 + 底部操作区，不再自绘 Dialog + 右上角关闭圆钮（点遮罩/返回即可关）
    return PiggyImagePreviewDialog(
      horizontalInset: 16,
      preview: ClipRRect(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        child: Stack(
          children: [
            InteractiveViewer(
              minScale: 0.5,
              maxScale: 3.0,
              child: Image.memory(
                _imageBytes,
                fit: BoxFit.contain,
              ),
            ),
            // 生成中的加载指示器
            if (_isGenerating)
              Positioned.fill(
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3),
                  child: const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation(Colors.white),
                    ),
                  ),
                ),
              ),
            // 隐藏收入切换按钮
            if (!_isGenerating)
              Positioned(
                top: 16,
                right: 16,
                child: Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _toggleHideIncome,
                    borderRadius:
                        BorderRadius.circular(PiggyDimens.radius2xl),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.5),
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radius2xl),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _hideIncome
                                ? Icons.visibility_off
                                : Icons.visibility,
                            size: 16,
                            color: Colors.white,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            _hideIncome
                                ? l10n.sharePosterShowIncome
                                : l10n.sharePosterHideIncome,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // 保存按钮
          _buildActionButton(
            context: context,
            icon: Icons.save_alt,
            label: l10n.sharePosterSave,
            onTap: _isGenerating ? null : () => _savePoster(context),
            isPrimary: true,
          ),
          const SizedBox(width: 16),
          // 分享按钮
          _buildActionButton(
            context: context,
            icon: Icons.share,
            label: l10n.sharePosterShare,
            onTap: _isGenerating ? null : () => _sharePoster(context),
            isPrimary: false,
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required BuildContext context,
    required IconData icon,
    required String label,
    required VoidCallback? onTap,
    required bool isPrimary,
  }) {
    final isDisabled = onTap == null;
    final bgColor = isPrimary ? widget.primaryColor : Colors.white;
    final fgColor = isPrimary ? Colors.white : widget.primaryColor;

    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: isDisabled ? 0.5 : 1.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(PiggyDimens.radius3xl),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                icon,
                size: 20,
                color: fgColor,
              ),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _savePoster(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final result = await SharePosterService.savePosterToGallery(_imageBytes);

    if (!context.mounted) return;

    switch (result) {
      case SavePosterResult.success:
        showToast(context, l10n.annualReportSaveSuccess);
        Navigator.pop(context);
        break;
      case SavePosterResult.accessDenied:
        showToast(context, l10n.commonFailed);
        break;
      case SavePosterResult.failed:
        showToast(context, l10n.commonFailed);
        break;
    }
  }

  Future<void> _sharePoster(BuildContext context) async {
    await SharePosterService.sharePoster(_imageBytes);
  }
}
