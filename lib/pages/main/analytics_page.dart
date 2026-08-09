import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// wheel_date_picker exported via ui barrel
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/charts/line_chart.dart';
import '../../widgets/charts/analytics_bar_chart.dart';
import '../../widgets/charts/category_pie_chart.dart';
import '../../widgets/analytics/analytics_summary.dart';
import '../../widgets/analytics/category_rank_row.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../l10n/app_localizations.dart';
import '../../services/export/share_poster_service.dart';
import '../../data/db.dart' as db;
import '../../utils/month_range.dart';
import '../../utils/week_range.dart';
import '../../utils/format_utils.dart';
import '../../utils/analytics_average.dart';

class AnalyticsPage extends ConsumerStatefulWidget {
  const AnalyticsPage({super.key});

  @override
  ConsumerState<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends ConsumerState<AnalyticsPage> {
  String _scope = 'month'; // week | month | year | all
  String _type = 'expense'; // expense | income | balance
  bool _chartSwiped = false; // 吸收图表区域横滑，避免父级切换收入/支出
  bool _localChartDismissed = false;
  // 周报选中的周（该周周一），独立于首页月份状态，避免污染首页
  DateTime _selWeek = weekLabelFor(DateTime.now());

  // 显示周期选择器
  void _showPeriodPicker() async {
    final selMonth = ref.read(selectedMonthProvider);
    if (_scope == 'week') {
      final res = await showWheelDatePicker(
        context,
        initial: _selWeek,
        mode: WheelDatePickerMode.ymd,
        maxDate: DateTime.now(),
      );
      if (res != null) {
        setState(() => _selWeek = weekLabelFor(res));
      }
      return;
    }
    if (_scope == 'month') {
      final res = await showWheelDatePicker(
        context,
        initial: selMonth,
        mode: WheelDatePickerMode.ym,
        maxDate: DateTime.now(),
      );
      final picked = res == null ? null : DateTime(res.year, res.month, 1);
      if (picked != null) {
        ref.read(selectedMonthProvider.notifier).state = picked;
      }
    } else if (_scope == 'year') {
      final res = await showWheelDatePicker(
        context,
        initial: selMonth,
        mode: WheelDatePickerMode.y,
        maxDate: DateTime.now(),
      );
      if (res != null) {
        ref.read(selectedMonthProvider.notifier).state =
            DateTime(res.year, 1, 1);
      }
    }
    // all视角不显示选择器
  }

  // 显示类型选择菜单
  /// v30 补折算横幅(01 §六):currencyCode≠本位币 且 nativeAmount==amount 的
  /// 存量外币交易 >0 时出现;确认后按当前有效汇率重算(逐笔记 change,L13)。
  Widget _buildRecalcForeignBanner(BuildContext context) {
    final count =
        ref.watch(ledgerUnconvertedForeignTxCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          // 主题色细边框（与洞察页图表卡片统一）
          side: BorderSide(color: ref.watch(primaryColorProvider), width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.currency_exchange,
                  size: 16, color: ref.watch(primaryColorProvider)),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.recalcForeignTxBanner,
                  style: PiggyTextTokens.label(context),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              TextButton(
                onPressed: () => _runRecalcForeignTx(count),
                child: Text(l10n.recalcForeignTxAction,
                    style: TextStyle(fontSize: 12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 折算脚注:账本存在外币交易(含已折算)时,提示统计数字已折本位币。
  Widget _buildConvertedFootnote(BuildContext context) {
    final count = ref.watch(ledgerForeignTxCountProvider).valueOrNull ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final base = ref.watch(currentLedgerCurrencyProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AppLocalizations.of(context).statsConvertedFootnote(base),
          style: TextStyle(
            fontSize: 11,
            color: PiggyTokens.textTertiary(context),
          ),
        ),
      ),
    );
  }

  Future<void> _runRecalcForeignTx(int count) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AlertDialog(
        title: Text(l10n.recalcForeignTxAction),
        content: Text(l10n.recalcSyncCountHint(count)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx, false),
            child: Text(AppLocalizations.of(dctx).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, true),
            child: Text(AppLocalizations.of(dctx).commonConfirm),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    // 补折算前先确保本位币汇率组是新鲜的(反馈17 同款根因:缺组则整体跳过);
    // extraQuotes 带上账本交易实际涉及的外币 —— 无对应账户的币种(CSV 导入/
    // 手选)不在 usedCurrencies 里,不带的话这些币种永远补不上(审查发现)。
    final foreign = await repo.getLedgerForeignCurrencies(ledgerId);
    await refreshExchangeRatesFromUi(ref, force: true, extraQuotes: foreign);
    final n = await repo.recomputeForeignTxForLedger(ledgerId);
    if (!mounted) return;
    showToast(context, l10n.recalcForeignTxDone(n));
    // bump 统计刷新:横幅重查消失 + 各统计图表按新折算重算
    ref.read(statsRefreshProvider.notifier).state++;
  }

  // 循环切换类型（用于滑动）：expense -> income -> balance -> expense
  void _cycleTypeForward() {
    setState(() {
      if (_type == 'expense') {
        _type = 'income';
      } else if (_type == 'income') {
        _type = 'balance';
      } else {
        _type = 'expense';
      }
    });
  }

  void _cycleTypeBackward() {
    setState(() {
      if (_type == 'expense') {
        _type = 'balance';
      } else if (_type == 'balance') {
        _type = 'income';
      } else {
        _type = 'expense';
      }
    });
  }

  // 根据scope切换周期（用于图表滑动 / 导航箭头）
  void _onChartSwipeLeft() {
    final selMonth = ref.read(selectedMonthProvider);
    final now = DateTime.now();
    setState(() {
      if (_scope == 'week') {
        // 周视角：切换到下一周（不能超过当前周）
        final nextWeek = weekAdd(_selWeek, 1);
        if (!nextWeek.isAfter(weekLabelFor(now))) {
          _selWeek = nextWeek;
        }
      } else if (_scope == 'month') {
        // 月视角：切换到下一个月（不能超过当前月）
        final nextMonth = DateTime(selMonth.year, selMonth.month + 1, 1);
        if (nextMonth.year < now.year ||
            (nextMonth.year == now.year && nextMonth.month <= now.month)) {
          ref.read(selectedMonthProvider.notifier).state = nextMonth;
        }
      } else if (_scope == 'year') {
        // 年视角：切换到下一年（不能超过当前年）
        final nextYear = DateTime(selMonth.year + 1, 1, 1);
        if (nextYear.year <= now.year) {
          ref.read(selectedMonthProvider.notifier).state = nextYear;
        }
      }
      // all视角：不做任何操作
    });
  }

  void _onChartSwipeRight() {
    final selMonth = ref.read(selectedMonthProvider);
    setState(() {
      if (_scope == 'week') {
        // 周视角：切换到上一周
        _selWeek = weekAdd(_selWeek, -1);
      } else if (_scope == 'month') {
        // 月视角：切换到上一个月
        final prevMonth = DateTime(selMonth.year, selMonth.month - 1, 1);
        ref.read(selectedMonthProvider.notifier).state = prevMonth;
      } else if (_scope == 'year') {
        // 年视角：切换到上一年
        final prevYear = DateTime(selMonth.year - 1, 1, 1);
        ref.read(selectedMonthProvider.notifier).state = prevYear;
      }
      // all视角：不做任何操作
    });
  }

  /// 周期导航箭头（‹ ›）：圆形描边按钮，参考截图样式
  Widget _periodNavArrow(
      BuildContext context, IconData icon, VoidCallback onTap) {
    return SizedBox(
      width: 30,
      height: 30,
      child: Material(
        color: Colors.transparent,
        shape: const CircleBorder(
          side: BorderSide(color: Color(0xFFCFD8DC), width: 1.4),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Center(
            child: Icon(icon, size: 18, color: PiggyTokens.textSecondary(context)),
          ),
        ),
      ),
    );
  }

  /// 导航行周期文案：周=日期范围，月=yyyy-MM，年=yyyy，全部=全部年份
  String _navPeriodLabel(BuildContext context, DateTime selMonth) {
    switch (_scope) {
      case 'week':
        return weekRangeText(weekRangeFor(_selWeek));
      case 'year':
        return '${selMonth.year}';
      case 'all':
        return AppLocalizations.of(context).analyticsAllYears;
      case 'month':
      default:
        return '${selMonth.year}-${selMonth.month.toString().padLeft(2, '0')}';
    }
  }

  // 将「天」序列聚合为 6 个周桶（本周 + 前5周），桶标签 = 周一起始日
  List<({DateTime day, double total})> _aggregateToWeeks(
    List<({DateTime day, double total})> days,
    DateTime firstWeekStart,
  ) {
    final map = <DateTime, double>{};
    for (final e in days) {
      final ws = weekRangeFor(e.day).start;
      map.update(ws, (v) => v + e.total, ifAbsent: () => e.total);
    }
    final out = <({DateTime day, double total})>[];
    for (int i = 0; i < 6; i++) {
      final ws = firstWeekStart.add(Duration(days: 7 * i));
      out.add((day: ws, total: map[ws] ?? 0));
    }
    return out;
  }

  // 将「天」序列聚合为 6 个月桶（本月 + 前5个月），桶标签 = 周期标签月（含 startDay 语义）
  List<({DateTime month, double total})> _aggregateToMonths(
    List<({DateTime day, double total})> days,
    DateTime firstMonthLabel,
    int startDay,
  ) {
    final map = <DateTime, double>{};
    for (final e in days) {
      final label = labelForDate(e.day, startDay);
      map.update(label, (v) => v + e.total, ifAbsent: () => e.total);
    }
    final out = <({DateTime month, double total})>[];
    for (int i = 0; i < 6; i++) {
      final m = DateTime(firstMonthLabel.year, firstMonthLabel.month + i, 1);
      out.add((month: m, total: map[m] ?? 0));
    }
    return out;
  }

  // 计算结余序列（收入 - 支出）
  dynamic _calculateBalanceSeries(dynamic incomeData, dynamic expenseData) {
    if (incomeData is List<({DateTime day, double total})> &&
        expenseData is List<({DateTime day, double total})>) {
      final Map<DateTime, double> incomeMap = {
        for (var e in incomeData) e.day: e.total
      };
      final Map<DateTime, double> expenseMap = {
        for (var e in expenseData) e.day: e.total
      };
      final allDays = {...incomeMap.keys, ...expenseMap.keys}.toList()..sort();
      return allDays.map((day) {
        final income = incomeMap[day] ?? 0.0;
        final expense = expenseMap[day] ?? 0.0;
        return (day: day, total: income - expense);
      }).toList();
    }
    if (incomeData is List<({DateTime month, double total})> &&
        expenseData is List<({DateTime month, double total})>) {
      final Map<DateTime, double> incomeMap = {
        for (var e in incomeData) e.month: e.total
      };
      final Map<DateTime, double> expenseMap = {
        for (var e in expenseData) e.month: e.total
      };
      final allMonths = {...incomeMap.keys, ...expenseMap.keys}.toList()
        ..sort();
      return allMonths.map((month) {
        final income = incomeMap[month] ?? 0.0;
        final expense = expenseMap[month] ?? 0.0;
        return (month: month, total: income - expense);
      }).toList();
    }
    if (incomeData is List<({int year, double total})> &&
        expenseData is List<({int year, double total})>) {
      final Map<int, double> incomeMap = {
        for (var e in incomeData) e.year: e.total
      };
      final Map<int, double> expenseMap = {
        for (var e in expenseData) e.year: e.total
      };
      final allYears = {...incomeMap.keys, ...expenseMap.keys}.toList()..sort();
      return allYears.map((year) {
        final income = incomeMap[year] ?? 0.0;
        final expense = expenseMap[year] ?? 0.0;
        return (year: year, total: income - expense);
      }).toList();
    }
    return [];
  }

  // 从序列数据中计算总和
  double _getSumFromSeries(dynamic seriesData) {
    if (seriesData is List<({DateTime day, double total})>) {
      return seriesData.fold<double>(0, (sum, e) => sum + e.total);
    }
    if (seriesData is List<({DateTime month, double total})>) {
      return seriesData.fold<double>(0, (sum, e) => sum + e.total);
    }
    if (seriesData is List<({int year, double total})>) {
      return seriesData.fold<double>(0, (sum, e) => sum + e.total);
    }
    return 0.0;
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final selMonth = ref.watch(selectedMonthProvider);
    // 统计刷新 tick：当有新增/编辑/删除时我们会 +1，这里监听以触发重建和重新拉取
    ref.watch(statsRefreshProvider);

    // 时间范围
    late DateTime start;
    late DateTime end;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    final sd = ref.watch(currentMonthStartDayProvider);
    if (_scope == 'week') {
      final range = weekRangeFor(_selWeek);
      start = range.start;
      final isCurrentWeek =
          !now.isBefore(range.start) && now.isBefore(range.end);
      // 当前周：只到今天；历史周：到周末
      end = isCurrentWeek ? today.add(const Duration(days: 1)) : range.end;
    } else if (_scope == 'month') {
      final range = periodForLabel(selMonth.year, selMonth.month, sd);
      start = range.start;
      // 「当前周期」判定用周期标签，不能用自然月相等(6月5日属5月周期)
      final nowLabel = labelForDate(now, sd);
      final isCurrentPeriod =
          selMonth.year == nowLabel.year && selMonth.month == nowLabel.month;
      // 当前周期：只到今天；历史周期：到周期末
      end = isCurrentPeriod ? today.add(const Duration(days: 1)) : range.end;
    } else if (_scope == 'year') {
      final range = yearRangeFor(selMonth.year, sd);
      start = range.start;
      // 当前年度周期：只到今天；历史：到年度周期末
      final isCurrentYear =
          !now.isBefore(range.start) && now.isBefore(range.end);
      end = isCurrentYear ? today.add(const Duration(days: 1)) : range.end;
    } else {
      start = DateTime(1970, 1, 1);
      end = today.add(const Duration(days: 1));
    }

    // 同比所需的上期范围：周视角=上周，月视角=去年同期周期，年视角=去年周期，全部视角无上期
    DateTime? prevStart;
    DateTime? prevEnd;
    if (_scope == 'week') {
      prevStart = weekAdd(_selWeek, -1);
      prevEnd = weekRangeFor(_selWeek).start; // 上周区间 [上周一, 本周一)
    } else if (_scope == 'month') {
      final prevRange = periodForLabel(selMonth.year - 1, selMonth.month, sd);
      prevStart = prevRange.start;
      prevEnd = prevRange.end;
    } else if (_scope == 'year') {
      final prevRange = yearRangeFor(selMonth.year - 1, sd);
      prevStart = prevRange.start;
      prevEnd = prevRange.end;
    }

    // 按视角获取序列
    Future<dynamic> seriesFuture;
    Future<dynamic>? incomeSeriesFuture;
    Future<dynamic>? expenseSeriesFuture;

    if (_type == 'balance') {
      // 结余模式：同时获取收入和支出数据
      if (_scope == 'week' || _scope == 'month') {
        incomeSeriesFuture = repo.totalsByDay(
            ledgerId: ledgerId, type: 'income', start: start, end: end);
        expenseSeriesFuture = repo.totalsByDay(
            ledgerId: ledgerId, type: 'expense', start: start, end: end);
        seriesFuture = Future.value([]); // 占位
      } else if (_scope == 'year') {
        incomeSeriesFuture = repo.totalsByMonth(
            ledgerId: ledgerId, type: 'income', year: selMonth.year);
        expenseSeriesFuture = repo.totalsByMonth(
            ledgerId: ledgerId, type: 'expense', year: selMonth.year);
        seriesFuture = Future.value([]);
      } else {
        incomeSeriesFuture =
            repo.totalsByYearSeries(ledgerId: ledgerId, type: 'income');
        expenseSeriesFuture =
            repo.totalsByYearSeries(ledgerId: ledgerId, type: 'expense');
        seriesFuture = Future.value([]);
      }
    } else {
      // 收入或支出模式
      seriesFuture = (_scope == 'week' || _scope == 'month')
          ? repo.totalsByDay(
              ledgerId: ledgerId, type: _type, start: start, end: end)
          : _scope == 'year'
              ? repo.totalsByMonth(
                  ledgerId: ledgerId, type: _type, year: selMonth.year)
              : repo.totalsByYearSeries(ledgerId: ledgerId, type: _type);
    }

    // 图表固定6根柱的序列（柱状图/折线图共用）：
    //   周报 = 本周 + 前5周；月报 = 本月 + 前5个月；年报 = 本年 + 前5年
    Future<dynamic> buildChartSeries(dynamic repo, int ledgerId, String type) {
      if (_scope == 'week') {
        final cStart = weekAdd(_selWeek, -5);
        final cEnd = weekRangeFor(_selWeek).end;
        return repo.totalsByDay(
            ledgerId: ledgerId, type: type, start: cStart, end: cEnd);
      }
      if (_scope == 'month') {
        final firstLabel = DateTime(selMonth.year, selMonth.month - 5, 1);
        final cStart =
            periodForLabel(firstLabel.year, firstLabel.month, sd).start;
        final cEnd = periodForLabel(selMonth.year, selMonth.month, sd).end;
        return repo.totalsByDay(
            ledgerId: ledgerId, type: type, start: cStart, end: cEnd);
      }
      return repo.totalsByYearSeries(ledgerId: ledgerId, type: type);
    }

    Future<dynamic> chartSeriesFuture;
    if (_type == 'balance') {
      chartSeriesFuture = Future.wait<dynamic>([
        buildChartSeries(repo, ledgerId, 'income'),
        buildChartSeries(repo, ledgerId, 'expense'),
      ]).then((r) => _calculateBalanceSeries(r[0], r[1]));
    } else {
      chartSeriesFuture = buildChartSeries(repo, ledgerId, _type);
    }

    return Scaffold(
      body: Column(
        children: [
          PiggyHeader(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Row(
                children: [
                  Icon(Icons.bar_chart_outlined,
                      color: PiggyTokens.textPrimary(context)),
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(context).tabInsights,
                    style: PiggyTextTokens.title(context),
                  ),
                  const Spacer(),
                  // 分享按钮
                  IconButton(
                    icon: Icon(Icons.share,
                        color: PiggyTokens.textPrimary(context)),
                    onPressed: () async {
                      final ledgerId = ref.read(currentLedgerIdProvider);
                      if (ledgerId == 0) {
                        showToast(context, AppLocalizations.of(context).sharePosterNoLedger);
                        return;
                      }

                      // 显示加载对话框（与轮播海报预览样式统一）
                      showDialog(
                        context: context,
                        barrierDismissible: false,
                        barrierColor: Colors.black.withValues(alpha: 0.3),
                        builder: (ctx) => PopScope(
                          canPop: false,
                          child: Center(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const SizedBox(
                                  width: 50,
                                  height: 50,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 3,
                                    valueColor: AlwaysStoppedAnimation(Colors.white),
                                  ),
                                ),
                                const SizedBox(height: 20),
                                Text(
                                  AppLocalizations.of(context).mineShareGenerating,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      );

                      try {
                        if (context.mounted) {
                          Navigator.of(context).pop(); // 关闭加载对话框

                          // 使用动态预览对话框（支持隐藏收入）
                          if (_scope == 'week') {
                            // 周报回退到该周所在月的月报海报
                            await SharePosterService.showDynamicPosterPreview(
                              context,
                              ref,
                              type: 'month',
                              ledgerId: ledgerId,
                              year: _selWeek.year,
                              month: _selWeek.month,
                            );
                          } else if (_scope == 'month') {
                            await SharePosterService.showDynamicPosterPreview(
                              context,
                              ref,
                              type: 'month',
                              ledgerId: ledgerId,
                              year: selMonth.year,
                              month: selMonth.month,
                            );
                          } else if (_scope == 'year') {
                            await SharePosterService.showDynamicPosterPreview(
                              context,
                              ref,
                              type: 'year',
                              ledgerId: ledgerId,
                              year: selMonth.year,
                            );
                          } else {
                            await SharePosterService.showDynamicPosterPreview(
                              context,
                              ref,
                              type: 'ledger',
                              ledgerId: ledgerId,
                            );
                          }
                        }
                      } catch (e) {
                        if (context.mounted) {
                          Navigator.of(context).pop(); // 关闭加载对话框
                          showToast(context,
                              '${AppLocalizations.of(context).commonError}: $e');
                        }
                      }
                    },
                  ),
                ],
              ),
            ),
                Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
              child: WaitSlidingSegmentedControl<String>(
                selected: _scope,
                height: 38,
                fontSize: 14,
                segments: [
                  WaitSlidingSegment(
                    value: 'week',
                    label: AppLocalizations.of(context).analyticsWeek,
                  ),
                  WaitSlidingSegment(
                    value: 'month',
                    label: AppLocalizations.of(context).analyticsMonth,
                  ),
                  WaitSlidingSegment(
                    value: 'year',
                    label: AppLocalizations.of(context).analyticsYear,
                  ),
                  WaitSlidingSegment(
                    value: 'all',
                    label: AppLocalizations.of(context).analyticsAll,
                  ),
                ],
                onValueChanged: (value) => setState(() => _scope = value),
              ),
            ),
                // 周期导航行：‹ 范围文案 › 居左，支出/收入/结余三段胶囊居右
                Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Row(
                children: [
                  if (_scope != 'all')
                    _periodNavArrow(
                        context, Icons.chevron_left, _onChartSwipeRight),
                  Expanded(
                    child: InkWell(
                      onTap: _scope != 'all' ? _showPeriodPicker : null,
                      child: Center(
                        child: Text(
                          _navPeriodLabel(context, selMonth),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: PiggyTokens.textPrimary(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (_scope != 'all')
                    _periodNavArrow(
                        context, Icons.chevron_right, _onChartSwipeLeft),
                  const SizedBox(width: 8),
                  // 支出/收入/结余：与顶部周/月/年/全部同款滑块胶囊（紧凑高度）
                  SizedBox(
                    width: 180,
                    child: WaitSlidingSegmentedControl<String>(
                      selected: _type,
                      height: 32,
                      fontSize: 13,
                      segments: [
                        WaitSlidingSegment(
                          value: 'expense',
                          label: AppLocalizations.of(context).homeExpense,
                        ),
                        WaitSlidingSegment(
                          value: 'income',
                          label: AppLocalizations.of(context).homeIncome,
                        ),
                        WaitSlidingSegment(
                          value: 'balance',
                          label: AppLocalizations.of(context).homeBalance,
                        ),
                      ],
                      onValueChanged: (v) => setState(() => _type = v),
                    ),
                  ),
                ],
              ),
            ),
                ],
              ),
          ),
          // v30 L11:检测到未折算外币交易 → 补折算横幅(用户确认后按当前汇率重算)
          _buildRecalcForeignBanner(context),
          // v30 折算脚注(01 §五):账本含外币交易时说明统计口径
          _buildConvertedFootnote(context),
          Expanded(
            child: FutureBuilder(
              key: ValueKey('analytics_$_type'),
              future: _type == 'balance'
                  ? _loadBalanceData(repo, ledgerId, start, end, seriesFuture,
                      incomeSeriesFuture!, expenseSeriesFuture!, prevStart,
                      prevEnd, chartSeriesFuture)
                  : _loadCategoryData(repo, ledgerId, _type, start, end,
                      seriesFuture, prevStart, prevEnd, chartSeriesFuture),
              builder: (context, snapshot) {
                if (!snapshot.hasData) {
                  return const Center(child: CircularProgressIndicator());
                }
                final list = snapshot.data as List<dynamic>;

                // 在balance模式下，需要计算结余数据
                dynamic seriesRaw;
                List<({int? id, String name, db.Category? category, double total, int count, List<({int id, db.Category category, String name, double total})> subCategories})>
                    catData;
                int txCount;
                double sum;
                double balance = 0; // 本期收支结余
                double? prevTotal; // 上期总额（同比）
                double expenseTotal = 0; // 本期总支出（结余视角第 4 格用）

                if (_type == 'balance') {
                  // balance模式：list[3]是收入数据，list[4]是支出数据，list[5]是收入交易数量
                  final incomeData = list[3];
                  final expenseData = list[4];

                  // 计算结余序列
                  seriesRaw = _calculateBalanceSeries(incomeData, expenseData);

                  // 分类数据显示支出分类（但结余模式下不显示排行榜）
                  catData = list[0] as List<
                      ({int? id, String name, db.Category? category, double total, int count, List<({int id, db.Category category, String name, double total})> subCategories})>;

                  // 获取收入和支出的交易数量
                  final expenseCount = list[2] as int;
                  final incomeCount = list[5] as int;
                  txCount = expenseCount + incomeCount;

                  // 计算总结余（收入总额 - 支出总额）
                  final incomeSum = _getSumFromSeries(incomeData);
                  final expenseSum = _getSumFromSeries(expenseData);
                  sum = incomeSum - expenseSum;
                  // 结余视角：结余即总额；同比=上期收入-支出；第4格显示总支出
                  final prevTotals = list[6] as (double, double);
                  balance = sum;
                  prevTotal = prevTotals.$1 - prevTotals.$2;
                  expenseTotal = expenseSum;
                } else {
                  catData = list[0] as List<
                      ({int? id, String name, db.Category? category, double total, int count, List<({int id, db.Category category, String name, double total})> subCategories})>;
                  seriesRaw = list[1];
                  txCount = list[2] as int;
                  sum = catData.fold<double>(0, (a, b) => a + b.total);
                  // 本期收支与上期收支（同比）
                  final curTotals = list[3] as (double, double);
                  final prevTotals = list[4] as (double, double);
                  balance = curTotals.$1 - curTotals.$2;
                  prevTotal =
                      _type == 'expense' ? prevTotals.$2 : prevTotals.$1;
                }

                // 统一取数列的数值数组
                List<double> valuesOnly() {
                  if (seriesRaw is List<({DateTime day, double total})>) {
                    return seriesRaw.map((e) => e.total).toList();
                  }
                  if (seriesRaw is List<({DateTime month, double total})>) {
                    return seriesRaw.map((e) => e.total).toList();
                  }
                  if (seriesRaw is List<({int year, double total})>) {
                    return seriesRaw.map((e) => e.total).toList();
                  }
                  return const <double>[];
                }

                final vals = valuesOnly();
                final allZero = vals.isEmpty || vals.every((v) => v == 0);
                if (txCount == 0 || (sum == 0 && allZero)) {
                  return GestureDetector(
                    onHorizontalDragEnd: (details) {
                      // 左右滑动切换周期（月份/年份）
                      if (details.primaryVelocity! > 0) {
                        _onChartSwipeRight(); // 向右滑动 -> 上一个周期
                      } else {
                        _onChartSwipeLeft(); // 向左滑动 -> 下一个周期
                      }
                    },
                    child: ListView(
                      padding: const EdgeInsets.all(16),
                      children: [
                        AppEmpty(
                          text: AppLocalizations.of(context).commonEmpty,
                          subtext: AppLocalizations.of(context)
                              .analyticsNoDataSubtext,
                        ),
                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.center,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.swap_horiz),
                            label: Text(AppLocalizations.of(context)
                                .analyticsSwitchTo(_type == "expense"
                                    ? AppLocalizations.of(context).homeIncome
                                    : _type == "income"
                                        ? AppLocalizations.of(context)
                                            .homeBalance
                                        : AppLocalizations.of(context)
                                            .homeExpense)),
                            onPressed: _cycleTypeForward,
                          ),
                        ),
                        const SizedBox(height: 8),
                        ],
                    ),
                  );
                }

                // 注意：sum 非 0 或曲线存在非零值则继续渲染

                // 过滤数据：只显示到当前时间的数据
                final filteredSeriesRaw = () {
                  if (seriesRaw is List<({DateTime day, double total})>) {
                    // 天数据：已经通过时间范围过滤了
                    return seriesRaw;
                  }
                  if (seriesRaw is List<({DateTime month, double total})>) {
                    // 月数据：过滤到当前月份
                    // 用周期标签判定，避免 sd≠1 时把尚未开始的周期画成零柱
                    // （如 sd=10、6月5日时 June 桶尚未开始但自然月已是6月）
                    final nowLabel = labelForDate(now, sd);
                    final isCurrentYear = selMonth.year == nowLabel.year;
                    if (isCurrentYear) {
                      return seriesRaw
                          .where((e) => e.month.month <= nowLabel.month)
                          .toList();
                    }
                    return seriesRaw;
                  }
                  if (seriesRaw is List<({int year, double total})>) {
                    // 年数据：过滤到当前年份
                    return seriesRaw.where((e) => e.year <= now.year).toList();
                  }
                  return seriesRaw;
                }();

                // ===== 图表6周期序列（柱状图/折线图共用）=====
                // 周报 = 本周+前5周、月报 = 本月+前5月、年报 = 本年+前5年；全部 = 全部年份
                final chartSeriesRaw = list[list.length - 1];
                dynamic chartSeries;
                if (chartSeriesRaw is List<({DateTime day, double total})>) {
                  if (_scope == 'week') {
                    chartSeries =
                        _aggregateToWeeks(chartSeriesRaw, weekAdd(_selWeek, -5));
                  } else if (_scope == 'month') {
                    chartSeries = _aggregateToMonths(
                        chartSeriesRaw,
                        DateTime(selMonth.year, selMonth.month - 5, 1),
                        sd);
                  } else {
                    chartSeries = chartSeriesRaw;
                  }
                } else if (chartSeriesRaw is List<({int year, double total})>) {
                  if (_scope == 'year') {
                    // 年报：选中年 + 前5年（最多6个年份）
                    final ys = chartSeriesRaw
                        .where((e) => e.year <= selMonth.year)
                        .toList();
                    chartSeries =
                        ys.length > 6 ? ys.sublist(ys.length - 6) : ys;
                  } else {
                    // 全部：所有年份
                    chartSeries = chartSeriesRaw
                        .where((e) => e.year <= now.year)
                        .toList();
                  }
                } else {
                  chartSeries = chartSeriesRaw;
                }

                // 转换为折线值数组 + x 轴标签
                final values = () {
                  if (chartSeries is List<({DateTime day, double total})>) {
                    return chartSeries.map((e) => e.total).toList();
                  }
                  if (chartSeries is List<({DateTime month, double total})>) {
                    return chartSeries.map((e) => e.total).toList();
                  }
                  if (chartSeries is List<({int year, double total})>) {
                    return chartSeries.map((e) => e.total).toList();
                  }
                  return const <double>[];
                }();

                final xLabels = () {
                  if (chartSeries is List<({DateTime day, double total})>) {
                    String two(int v) => v.toString().padLeft(2, '0');
                    // 周视角：周一起始日 MM.dd 短标签
                    if (_scope == 'week') {
                      return chartSeries
                          .map((e) => '${two(e.day.month)}.${two(e.day.day)}')
                          .toList(growable: false);
                    }
                    return chartSeries
                        .map((e) => e.day.day.toString())
                        .toList(growable: false);
                  }
                  if (chartSeries is List<({DateTime month, double total})>) {
                    return chartSeries
                        .map((e) => AppLocalizations.of(context).homeMonth(
                            e.month.month.toString().padLeft(2, '0')))
                        .toList(growable: false);
                  }
                  if (chartSeries is List<({int year, double total})>) {
                    return chartSeries
                        .map((e) => e.year.toString())
                        .toList(growable: false);
                  }
                  return const <String>[];
                }();

                // 高亮当前选中周期（最后一根柱/最后一点）；全部视角不高亮
                int? highlightIndex;
                if (_scope != 'all' && xLabels.isNotEmpty) {
                  highlightIndex = xLabels.length - 1;
                }

                final chartDismissed = (ref
                            .watch(analyticsChartHintDismissedProvider)
                            .asData
                            ?.value ??
                        false) ||
                    _localChartDismissed;
                final hide = ref.watch(hideAmountsProvider);
                final l10n = AppLocalizations.of(context);
                // 大金额格式化：币种 + 语言（与 AmountText 同款判定）
                final baseCurrency = ref.watch(currentLedgerCurrencyProvider);
                final selectedLocale = ref.watch(languageProvider);
                final isZh = selectedLocale?.languageCode == 'zh' ||
                    (selectedLocale == null &&
                        Localizations.localeOf(context).languageCode == 'zh');
                final typeWord = _type == 'expense'
                    ? l10n.analyticsExpense
                    : _type == 'income'
                        ? l10n.analyticsIncome
                        : l10n.analyticsBalance
                            .replaceAll(RegExp(r'[\s:：]+$'), '');

                // 折线图卡片标题：本周趋势 / 本月趋势 / 今年趋势 / 全部趋势
                final lineTitle = l10n.analyticsTrendTitle(switch (_scope) {
                  'week' => l10n.analyticsThisWeek,
                  'month' => l10n.analyticsThisMonth,
                  'year' => l10n.analyticsThisYear,
                  _ => l10n.analyticsAll,
                });

                // 折线点按气泡：MM.dd 支出 ¥1,918.03（天序列）/ 标签+金额（月年序列）
                String Function(int)? tooltipText;
                if (chartSeries is List<({DateTime day, double total})>) {
                  tooltipText = (i) {
                    final e = chartSeries[i];
                    String two(int v) => v.toString().padLeft(2, '0');
                    final amt = hide
                        ? '**'
                        : formatBalance(e.total, baseCurrency,
                            isChineseLocale: isZh);
                    return '${two(e.day.month)}.${two(e.day.day)} $typeWord $amt';
                  };
                } else if (chartSeries is List<({DateTime month, double total})>) {
                  tooltipText = (i) {
                    final amt = hide
                        ? '**'
                        : formatBalance(chartSeries[i].total, baseCurrency,
                            isChineseLocale: isZh);
                    return '${xLabels[i]} $typeWord $amt';
                  };
                } else if (chartSeries is List<({int year, double total})>) {
                  tooltipText = (i) {
                    final amt = hide
                        ? '**'
                        : formatBalance(chartSeries[i].total, baseCurrency,
                            isChineseLocale: isZh);
                    return '${xLabels[i]} $typeWord $amt';
                  };
                }

                // 柱状图右上角 badge：compact 总额 + 周期范围
                final barBadge =
                    '${hide ? '**' : formatBalance(sum, baseCurrency, isChineseLocale: isZh)} ${_navPeriodLabel(context, selMonth)}';

                return GestureDetector(
                  onHorizontalDragEnd: (details) {
                    if (_chartSwiped) {
                      setState(() => _chartSwiped = false);
                      return;
                    }
                    // 左右滑动切换类型
                    if (details.primaryVelocity! > 0) {
                      _cycleTypeBackward();
                    } else {
                      _cycleTypeForward();
                    }
                  },
                  child: ListView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                    children: [
                      AnalyticsSummary(
                        scope: _scope,
                        isExpense: _type == 'expense',
                        isBalance: _type == 'balance',
                        total: sum,
                        avg: computeSeriesAverage(filteredSeriesRaw),
                        // 收支配色遵循用户设置的红绿方案
                        expenseColor: PiggyTokens.expenseColor(context, ref),
                        incomeColor: PiggyTokens.incomeColor(context, ref),
                        // 四指标：同比（全部视角无上期→显示记账笔数）+ 结余
                        prevTotal: _scope == 'all' ? null : prevTotal,
                        balance: balance,
                        txCount: txCount,
                        expenseTotal:
                            _type == 'balance' ? expenseTotal : null,
                      ),
                      const SizedBox(height: 12),
                      // 趋势折线卡：标题 + 平滑曲线 + Y轴大金额缩写 + 点按气泡
                      Container(
                        padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
                        decoration: BoxDecoration(
                          color: PiggyTokens.surface(context),
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radius2xl),
                          border: Border.all(
                            color: ref.watch(primaryColorProvider),
                            width: 1.5,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              children: [
                                Container(
                                  width: 3,
                                  height: 14,
                                  margin: const EdgeInsets.only(right: 8),
                                  decoration: BoxDecoration(
                                    color: PiggyTokens.primary(context),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                ),
                                Text(
                                  lineTitle,
                                  style: TextStyle(
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                    color: PiggyTokens.textPrimary(context),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 200,
                              child: LineChart(
                                values: values,
                                xLabels: xLabels,
                                highlightIndex: highlightIndex,
                                hideAmounts: hide,
                                themeColor: PiggyTokens.primary(context),
                                // 使用统一图表令牌
                                lineWidth: PiggyChartTokens.lineWidth,
                                dotRadius: PiggyChartTokens.dotRadius,
                                cornerRadius: PiggyChartTokens.cornerRadius,
                                xLabelFontSize:
                                    PiggyChartTokens.xLabelFontSize,
                                yLabelFontSize:
                                    PiggyChartTokens.yLabelFontSize,
                                onSwipeLeft: () {
                                  // 根据scope切换周期
                                  _onChartSwipeLeft();
                                  setState(() => _chartSwiped = true);
                                },
                                onSwipeRight: () {
                                  // 根据scope切换周期
                                  _onChartSwipeRight();
                                  setState(() => _chartSwiped = true);
                                },
                                showHint: !chartDismissed,
                                hintText: AppLocalizations.of(context)
                                    .analyticsSwipeHint,
                                onCloseHint: () async {
                                  final setter = ref
                                      .read(analyticsHintsSetterProvider);
                                  await setter.dismissChart();
                                  if (mounted) {
                                    setState(
                                        () => _localChartDismissed = true);
                                  }
                                },
                                // minimal：背景/轴线/平均线交给外层卡片
                                whiteBg: false,
                                isDark: PiggyTokens.isDark(context),
                                showGrid: false,
                                showDots: true,
                                annotate: false,
                                minimal: true,
                                smooth: true,
                                showYAxisLabels: true,
                                isChineseLocale: isZh,
                                pointTooltipText: tooltipText,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      AnalyticsBarChart(
                        values: values,
                        xLabels: xLabels,
                        highlightIndex: highlightIndex,
                        hideAmounts: hide,
                        themeColor: PiggyTokens.primary(context),
                        isDark: PiggyTokens.isDark(context),
                        title: l10n.analyticsTrendTitle(typeWord),
                        badgeText: barBadge,
                        isChineseLocale: isZh,
                        pointTooltipText: tooltipText,
                        onSwipeLeft: () {
                          // 根据scope切换周期
                          _onChartSwipeLeft();
                          setState(() => _chartSwiped = true);
                        },
                        onSwipeRight: () {
                          // 根据scope切换周期
                          _onChartSwipeRight();
                          setState(() => _chartSwiped = true);
                        },
                      ),
                      const SizedBox(height: 12),
                      // 结余视角不显示分类构成与排行榜
                      if (_type != 'balance') ...[
                        // 分类构成卡：标题 + 环形图（外置标签），仅展示主分类
                        Builder(builder: (context) {
                          final pieData = <PieCategoryItem>[
                            for (final c in catData)
                              (
                                id: c.id,
                                name: c.name,
                                category: c.category,
                                total: c.total,
                                subCategories: c.subCategories,
                              ),
                          ];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                padding:
                                    const EdgeInsets.fromLTRB(16, 14, 16, 12),
                                decoration: BoxDecoration(
                                  color: PiggyTokens.surface(context),
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radius2xl),
                                  border: Border.all(
                                    color: ref.watch(primaryColorProvider),
                                    width: 1.5,
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Row(
                                      children: [
                                        Container(
                                          width: 3,
                                          height: 14,
                                          margin:
                                              const EdgeInsets.only(right: 8),
                                          decoration: BoxDecoration(
                                            color:
                                                PiggyTokens.primary(context),
                                            borderRadius:
                                                BorderRadius.circular(2),
                                          ),
                                        ),
                                        Expanded(
                                          child: Text(
                                            l10n.analyticsCategoryComposition(
                                                typeWord),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.w600,
                                              color: PiggyTokens.textPrimary(
                                                  context),
                                            ),
                                          ),
                                        ),
                                        ],
                                    ),
                                    const SizedBox(height: 8),
                                    if (pieData.isNotEmpty && sum > 0)
                                      CategoryPieChart(
                                        data: pieData,
                                        sum: sum,
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              // 排行榜卡：序号 + 图标 + 名称笔数 + 进度条 + 百分比金额
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 16, vertical: 6),
                                decoration: BoxDecoration(
                                  color: PiggyTokens.surface(context),
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radius2xl),
                                  border: Border.all(
                                    color: ref.watch(primaryColorProvider),
                                    width: 1.5,
                                  ),
                                ),
                                child: Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    // 仅主分类排行（本项目无子分类），点击直接进分类详情
                                    for (var i = 0; i < catData.length; i++)
                                      CategoryRankRow(
                                        categoryId: catData[i].id,
                                        category: catData[i].category,
                                        name: catData[i].name,
                                        value: catData[i].total,
                                        percent: sum == 0
                                            ? 0
                                            : catData[i].total / sum,
                                        color: _pieColorAt(context, i),
                                        start: start,
                                        end: end,
                                        scope: _scope,
                                        selMonth: selMonth,
                                        rank: i + 1,
                                        count: catData[i].count,
                                        periodLabel: _scope == 'week'
                                            ? weekRangeText(
                                                weekRangeFor(_selWeek))
                                            : null,
                                      ),
                                  ],
                                ),
                              ),
                            ],
                          );
                        }),
                      ],
                      // 底部留白，避免被悬浮 Tab 栏遮挡
                      SizedBox(height: 56 + 12 + MediaQuery.of(context).viewPadding.bottom + 16),
                    ],
                  ),
                );
              },
            ),
          )
        ],
      ),
    );
  }
}

// 顶部类型下拉已移除（改为导航行三段胶囊，与周/月/年/全部同款滑块）

// 自定义选择器：月份（年+月）
// 旧的自定义年月选择器已移除，统一使用 showWheelDatePicker。

/// 排行榜第 i 名的颜色：与环形图扇区调色板一致（前 8 名），其余归入「其他」灰
Color _pieColorAt(BuildContext context, int i) =>
    i < 8 ? kAnalyticsPieColors[i] : PiggyTokens.textTertiary(context);

// 加载分类数据并聚合
// 返回 [catData, seriesRaw, txCount, (本期收入,本期支出), (上期收入,上期支出), chartSeriesRaw]
Future<List<dynamic>> _loadCategoryData(
  dynamic repo,
  int ledgerId,
  String type,
  DateTime start,
  DateTime end,
  Future<dynamic> seriesFuture,
  DateTime? prevStart,
  DateTime? prevEnd,
  Future<dynamic> chartSeriesFuture,
) async {
  final prevTotalsFuture = (prevStart != null && prevEnd != null)
      ? repo.totalsInRange(ledgerId: ledgerId, start: prevStart, end: prevEnd)
      : Future.value((0.0, 0.0));
  final results = await Future.wait<dynamic>([
    repo.totalsByCategoryWithHierarchy(
        ledgerId: ledgerId, type: type, start: start, end: end),
    seriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId, type: type, start: start, end: end),
    repo.getSharedSyntheticCategoriesForLedger(ledgerId),
    // 本期收支（结余用）
    repo.totalsInRange(ledgerId: ledgerId, start: start, end: end),
    prevTotalsFuture,
    chartSeriesFuture,
  ]);

  final hierarchyData = results[0] as List<
      ({
        int? id,
        String name,
        String? icon,
        int? parentId,
        int level,
        double total,
        int count
      })>;
  final sharedSynthetic = results[3] as Map<int, db.Category>;
  final aggregated =
      await _aggregateTopLevelCategories(hierarchyData, repo, sharedSynthetic);

  return [
    aggregated,
    results[1],
    results[2],
    results[4],
    results[5],
    results[6],
  ];
}

// 加载结余数据并聚合
// 返回 [catData, series, expenseCount, incomeSeries, expenseSeries, incomeCount, (上期收入,上期支出), chartSeriesRaw]
Future<List<dynamic>> _loadBalanceData(
  dynamic repo,
  int ledgerId,
  DateTime start,
  DateTime end,
  Future<dynamic> seriesFuture,
  Future<dynamic> incomeSeriesFuture,
  Future<dynamic> expenseSeriesFuture,
  DateTime? prevStart,
  DateTime? prevEnd,
  Future<dynamic> chartSeriesFuture,
) async {
  final prevTotalsFuture = (prevStart != null && prevEnd != null)
      ? repo.totalsInRange(ledgerId: ledgerId, start: prevStart, end: prevEnd)
      : Future.value((0.0, 0.0));
  final results = await Future.wait<dynamic>([
    repo.totalsByCategoryWithHierarchy(
        ledgerId: ledgerId, type: 'expense', start: start, end: end),
    seriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId, type: 'expense', start: start, end: end),
    incomeSeriesFuture,
    expenseSeriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId, type: 'income', start: start, end: end),
    repo.getSharedSyntheticCategoriesForLedger(ledgerId),
    prevTotalsFuture,
    chartSeriesFuture,
  ]);

  final hierarchyData = results[0] as List<
      ({
        int? id,
        String name,
        String? icon,
        int? parentId,
        int level,
        double total,
        int count
      })>;
  final sharedSynthetic = results[6] as Map<int, db.Category>;
  final aggregated =
      await _aggregateTopLevelCategories(hierarchyData, repo, sharedSynthetic);

  return [
    aggregated,
    results[1],
    results[2],
    results[3],
    results[4],
    results[5],
    results[7],
    results[8],
  ];
}

// 聚合一级分类数据（将二级分类金额/笔数聚合到一级分类）
Future<List<({int? id, String name, db.Category? category, double total, int count, List<({int id, db.Category category, String name, double total})> subCategories})>>
    _aggregateTopLevelCategories(
        List<
                ({
                  int? id,
                  String name,
                  String? icon,
                  int? parentId,
                  int level,
                  double total,
                  int count
                })>
            hierarchyData,
        dynamic repo,
        Map<int, db.Category> sharedSynthetic) async {
  // 1. 先收集所有一级分类的完整信息
  // §7 共享账本:Editor 的 tx 用 SharedLedger* 表(synthetic 负 id),
  // 主表 getCategoryById 查不到。topLevelNames/Icons 兜底从 hierarchyData
  // 直接取,渲染时不再依赖 db.Category 对象。
  final topLevelInfo = <int, db.Category>{};
  final topLevelNames = <int?, String>{};
  final topLevelIcons = <int?, String?>{};
  for (final item in hierarchyData) {
    if (item.level == 1) {
      topLevelNames[item.id] = item.name;
      topLevelIcons[item.id] = item.icon;
      if (item.id != null && item.id! > 0) {
        // 主表正 id:查 db.Category
        final category = await repo.getCategoryById(item.id!);
        if (category != null) {
          topLevelInfo[item.id!] = category;
        }
      } else if (item.id != null && item.id! < 0) {
        // SharedLedger* synthetic 负 id:从 sharedSynthetic 取合成 Category
        // (含 iconType/customIconPath,UI 能正确渲染自定义图标)
        final synthetic = sharedSynthetic[item.id!];
        if (synthetic != null) {
          topLevelInfo[item.id!] = synthetic;
        }
      }
    }
  }

  // 2. 收集所有需要查询的父分类ID（二级分类的父分类，但在topLevelInfo中不存在的）
  final parentIdsToQuery = <int>{};
  for (final item in hierarchyData) {
    if (item.level == 2 &&
        item.parentId != null &&
        !topLevelInfo.containsKey(item.parentId!)) {
      parentIdsToQuery.add(item.parentId!);
    }
  }

  // 3. 查询缺失的父分类信息
  // §7 共享账本:负 id 是 SharedLedger* 的 synthetic id,主表 getCategoryById
  // 查不到 — fallback 到 sharedSynthetic map(已含所有 SharedLedger 分类)。
  // 顺便补 topLevelNames / topLevelIcons,让结果阶段(line 1146+)能正确
  // fallback 渲染 L1 分类名字 / 图标。
  for (final parentId in parentIdsToQuery) {
    if (parentId < 0 && sharedSynthetic.containsKey(parentId)) {
      final synthetic = sharedSynthetic[parentId]!;
      topLevelInfo[parentId] = synthetic;
      topLevelNames[parentId] = synthetic.name;
      topLevelIcons[parentId] = synthetic.icon;
      continue;
    }
    final category = await repo.getCategoryById(parentId);
    if (category != null) {
      topLevelInfo[parentId] = category;
    }
  }

  // 4. 聚合金额与笔数，同时收集子分类明细
  final topLevelMap = <int?, double>{};
  final topLevelCountMap = <int?, int>{};
  final subCategoriesMap = <int?, List<({int id, db.Category category, String name, double total})>>{};

  for (final item in hierarchyData) {
    if (item.level == 1) {
      // 一级分类：累加金额与笔数
      topLevelMap.update(item.id, (v) => v + item.total,
          ifAbsent: () => item.total);
      topLevelCountMap.update(item.id, (v) => v + item.count,
          ifAbsent: () => item.count);
    } else if (item.level == 2 && item.parentId != null) {
      // 二级分类：累加到父分类
      topLevelMap.update(item.parentId, (v) => v + item.total,
          ifAbsent: () => item.total);
      topLevelCountMap.update(item.parentId, (v) => v + item.count,
          ifAbsent: () => item.count);
      // 收集子分类明细 — §7 共享账本:负 id 的 L2 走 sharedSynthetic
      // fallback,主表 getCategoryById 查不到。这样点击一级分类才能展开
      // SharedLedger* 的子分类,点击子分类才能进 CategoryDetailPage。
      if (item.id != null) {
        db.Category? subCategory;
        if (item.id! < 0) {
          subCategory = sharedSynthetic[item.id!];
        } else {
          subCategory = await repo.getCategoryById(item.id!);
        }
        if (subCategory != null) {
          subCategoriesMap.putIfAbsent(item.parentId, () => []);
          subCategoriesMap[item.parentId]!.add((
            id: item.id!,
            category: subCategory,
            name: item.name,
            total: item.total,
          ));
        }
      }
    }
  }

  // 5. 对每个父分类的子分类按金额降序排列
  for (final subs in subCategoriesMap.values) {
    subs.sort((a, b) => b.total.compareTo(a.total));
  }

  // 6. 转换为列表并排序
  final result = topLevelMap.entries.map((e) {
    final id = e.key;
    final total = e.value;
    final subs = subCategoriesMap[id] ?? <({int id, db.Category category, String name, double total})>[];

    final count = topLevelCountMap[id] ?? 0;
    // 获取一级分类信息
    if (id != null && topLevelInfo.containsKey(id)) {
      final category = topLevelInfo[id]!;
      return (
        id: id,
        name: category.name,
        category: category,
        total: total,
        count: count,
        subCategories: subs,
      );
    } else if (topLevelNames.containsKey(id)) {
      // SharedLedger* 兜底:有 name 但 db.Category 为 null,UI 用 name fallback
      return (
        id: id,
        name: topLevelNames[id]!,
        category: null,
        total: total,
        count: count,
        subCategories: subs,
      );
    } else {
      return (
        id: id,
        name: '未分类',
        category: null,
        total: total,
        count: count,
        subCategories: subs,
      );
    }
  }).toList()
    ..sort((a, b) => b.total.compareTo(a.total));

  return result;
}
