import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart' as db;
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/custom_field_stats_service.dart';
import '../../styles/tokens.dart';
import '../../utils/analytics_category_rollup.dart';
import '../../utils/format_utils.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/analytics/category_rank_row.dart';
import '../../widgets/charts/analytics_bar_chart.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';

/// F2 自定义区间报表：任意起止 + 环比/同比 + 分类/标签两个维度。
///
/// 为什么不并进「洞察」页（`analytics_page.dart`）：那页 1.5k 行、视角固定为
/// 周/月/年/全部，数据靠 `List<dynamic>` 位次传递，摘要卡只有**一个**
/// `prevTotal` 槽。在它上面同时挂环比+同比、再加标签维度，改动面会铺到 4 个
/// 视角的取数、滑动手势语义（那页左右滑=切周期）和分享海报分支。新页只复用
/// 现成件（`AnalyticsBarChart` / `CategoryRankRow` /
/// [aggregateTopLevelCategories]），口径与洞察页同源，回归面隔离。
///
/// 统计口径全部沿用既有 SQL 聚合：`COALESCE(native_amount, amount)`、
/// `exclude_from_stats = 0`、半开区间 `[start, end)`。v44 回收站里的交易已经
/// 不在 `transactions` 表，所以天然不进本报表（与首页/洞察页一致）。
class RangeReportPage extends ConsumerStatefulWidget {
  const RangeReportPage({super.key, this.initialStart, this.initialEnd});

  final DateTime? initialStart;
  final DateTime? initialEnd;

  /// 日粒度上限：区间超过它就按自然月聚桶（3 年区间会画 1000+ 根柱）。
  static const int dayChartLimit = 31;

  /// 紧邻本期之前、等长的窗口（环比）。
  static (DateTime, DateTime) momWindow(DateTime start, DateTime end) {
    final len = end.difference(start);
    return (start.subtract(len), start);
  }

  /// 整窗回退一年（同比）。2/29 这类不存在的日期由 DateTime 自动进位到 3/1，
  /// 宁可多算一天也不要抛异常。
  static (DateTime, DateTime) yoyWindow(DateTime start, DateTime end) => (
        DateTime(start.year - 1, start.month, start.day),
        DateTime(end.year - 1, end.month, end.day),
      );

  /// 变化率；上期为 0 时返回 null（无基准，渲染成「—」而不是 +∞%）。
  static double? changeRate(double cur, double prev) =>
      prev == 0 ? null : (cur - prev) / prev.abs();

  /// 按自然月把日序列并桶（保持日序列同形状，图表侧不用分支）。
  static List<({DateTime day, double total})> rollToMonths(
      List<({DateTime day, double total})> days) {
    final map = <DateTime, double>{};
    for (final e in days) {
      final label = DateTime(e.day.year, e.day.month, 1);
      map.update(label, (v) => v + e.total, ifAbsent: () => e.total);
    }
    final out = map.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return [for (final e in out) (day: e.key, total: e.value)];
  }

  @override
  ConsumerState<RangeReportPage> createState() => _RangeReportPageState();
}

class _RangeReportPageState extends ConsumerState<RangeReportPage> {
  late DateTime _start = widget.initialStart ??
      DateTime(DateTime.now().year, DateTime.now().month, 1);

  /// 半开区间右端：默认到今天 24:00
  late DateTime _end = widget.initialEnd ??
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
          .add(const Duration(days: 1));

  /// 序列 / 分类 / 标签三块的统计维度（对比表与它无关，始终同时给收支）
  String _dim = 'expense';

  Future<_ReportData>? _future;
  String? _futureKey;

  /// 维度缓存：键=dim（expense/income），值=该维度已查好的整份报表。
  /// 收支来回切命中缓存后**同帧出数**（SynchronousFuture），既不闪也不用
  /// 再查一次库。区间/账本/刷新 tick 一变（scope 对不上）就整体作废，
  /// 最多留 2 条，不随交互增长。
  final Map<String, _ReportData> _dimCache = {};
  String? _dimCacheScope;

  /// 最近一次查好的结果。新查询在途时用它兜底渲染：页面不再整块塌成居中
  /// 转圈，ListView 也不被销毁重建（滚动位置、分段控件胶囊动画都保住）。
  _ReportData? _lastData;

  Future<_ReportData> _load(int ledgerId) async {
    final repo = ref.read(repositoryProvider);
    final (momStart, momEnd) = RangeReportPage.momWindow(_start, _end);
    final (yoyStart, yoyEnd) = RangeReportPage.yoyWindow(_start, _end);
    final days = _end.difference(_start).inDays;
    final byMonth = days > RangeReportPage.dayChartLimit;
    final results = await Future.wait<dynamic>([
      repo.totalsInRange(ledgerId: ledgerId, start: _start, end: _end),
      repo.totalsInRange(ledgerId: ledgerId, start: momStart, end: momEnd),
      repo.totalsInRange(ledgerId: ledgerId, start: yoyStart, end: yoyEnd),
      repo.totalsByDay(
          ledgerId: ledgerId, type: _dim, start: _start, end: _end),
      repo.totalsByCategoryWithHierarchy(
          ledgerId: ledgerId, type: _dim, start: _start, end: _end),
      repo.totalsByTag(
          ledgerId: ledgerId, type: _dim, start: _start, end: _end),
      repo.countByTypeInRange(
          ledgerId: ledgerId, type: _dim, start: _start, end: _end),
    ]);
    // B2(v47):自定义字段汇总。定义非空才查值行(绝大多数账本零定义,少一次查询)。
    final cfDefs = await repo.getDefinitionsForLedger(ledgerId);
    final cfRows = cfDefs.isEmpty
        ? const <({
            String type,
            double nativeAmount,
            String? customValuesJson
          })>[]
        : await repo.customFieldStatsRows(
            ledgerId: ledgerId, start: _start, end: _end);
    final customFieldStats =
        CustomFieldStatsService.aggregate(defs: cfDefs, rows: cfRows);
    final rawSeries = results[3] as List<({DateTime day, double total})>;
    return _ReportData(
      cur: results[0] as (double, double),
      mom: results[1] as (double, double),
      yoy: results[2] as (double, double),
      series: byMonth ? RangeReportPage.rollToMonths(rawSeries) : rawSeries,
      byMonth: byMonth,
      cats: await aggregateTopLevelCategories(
          results[4] as List<
              ({
                int? id,
                String name,
                String? icon,
                int? parentId,
                int level,
                double total,
                int count
              })>,
          repo),
      tags: results[5] as List<
          ({int id, String name, String? color, double total, int count})>,
      txCount: results[6] as int,
      customFields: customFieldStats,
    );
  }

  /// 三级取数：同键复用已发查询 → 维度缓存同帧命中 → 都没有才真查库
  /// （键含区间/维度/账本/刷新 tick，交互每次变化才产生新键）。
  Future<_ReportData> _futureFor(int ledgerId, int refreshTick) {
    final scope = '$ledgerId|${_start.microsecondsSinceEpoch}'
        '|${_end.microsecondsSinceEpoch}|$refreshTick';
    if (_dimCacheScope != scope) {
      _dimCacheScope = scope;
      _dimCache.clear();
    }
    final dim = _dim;
    final key = '$scope|$dim';
    if (_futureKey == key && _future != null) return _future!;
    final cached = _dimCache[dim];
    if (cached != null) return SynchronousFuture(cached);
    final f = _load(ledgerId).then((data) {
      // 慢响应不能污染缓存：期间区间已经换掉的话，它的数属于旧 scope。
      if (_dimCacheScope == scope) _dimCache[dim] = data;
      _lastData = data;
      return data;
    });
    _futureKey = key;
    _future = f;
    return f;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    // 项目口径的区间选择抽屉（与日历页同款日期格：农历副标签 + 休/班徽标 + 放假底色）
    final picked = await showPiggyRangePickerSheet(
      context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialStart: _start,
      initialEnd: _end.subtract(const Duration(days: 1)),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _start = picked.start;
      // 选择器给的是「含末日」，报表统一按半开区间 [start, end) 取数。
      // 用「日 + 1」而不是 `+ Duration(days: 1)`：夏令时切换日加 24h 会偏一小时。
      _end = DateTime(picked.end.year, picked.end.month, picked.end.day + 1);
    });
  }

  /// 柱状图左右滑 = 整窗按自身长度平移（与洞察页「左右滑切周期」同手感）
  void _shiftWindow(int direction) {
    final len = _end.difference(_start);
    setState(() {
      _start = _start.add(len * direction);
      _end = _end.add(len * direction);
    });
  }

  bool get _isChinese {
    final locale = ref.watch(languageProvider);
    return locale?.languageCode == 'zh' ||
        (locale == null &&
            Localizations.localeOf(context).languageCode == 'zh');
  }

  String _rangeText() {
    final f = DateFormat('yyyy.MM.dd');
    return '${f.format(_start)} ~ '
        '${f.format(_end.subtract(const Duration(days: 1)))}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final refreshTick = ref.watch(statsRefreshProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.rangeReportTitle,
        subtitle: _rangeText(),
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(top: MediaQuery.of(context).padding.top + 80),
        child: FutureBuilder<_ReportData>(
          future: _futureFor(ledgerId, refreshTick),
          builder: (context, snap) {
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('${l10n.commonError}: ${snap.error}'),
                ),
              );
            }
            // 在途查询继续渲染上一份结果（首屏才转圈）：切区间/切收支只是
            // 数字就地更新，不再整页塌成转圈再重建——闪动与滚动位置丢失
            // （ListView 被销毁重建）的根因就在这一行判断。
            final data = snap.data ?? _lastData;
            if (data == null) {
              return Center(
                child: PiggySpinner(
                  size: 36,
                  color: PiggyTokens.primary(context),
                ),
              );
            }
            final loading = snap.connectionState != ConnectionState.done;
            final dimWord =
                _dim == 'expense' ? l10n.homeExpense : l10n.homeIncome;
            return Stack(
              children: [
                ListView(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                  children: [
                    _rangeCard(context, l10n),
                    const SizedBox(height: 12),
                    _compareCard(context, l10n, data),
                    const SizedBox(height: 12),
                    // 支出/收入维度：项目通用 tab 样式（WaitSlidingSegmentedControl），
                    // 与洞察页同款（固定宽度 + 紧凑高度）。切换只有胶囊滑动，无闪动。
                    SizedBox(
                      width: 168,
                      child: WaitSlidingSegmentedControl<String>(
                        selected: _dim,
                        height: 32,
                        fontSize: PiggyTextTokens.fs13,
                        segments: [
                          WaitSlidingSegment(
                            value: 'expense',
                            label: l10n.homeExpense,
                          ),
                          WaitSlidingSegment(
                            value: 'income',
                            label: l10n.homeIncome,
                          ),
                        ],
                        onValueChanged: (value) => setState(() => _dim = value),
                      ),
                    ),
                    if (data.txCount == 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 24),
                        child: AppEmpty(
                            text: l10n.commonEmpty,
                            subtext: l10n.rangeReportEmptySubtext),
                      )
                    else ...[
                      const SizedBox(height: 12),
                      _card(
                        context,
                        title: l10n.analyticsTrendTitle(dimWord),
                        child: SizedBox(
                          height: 220,
                          child: RepaintBoundary(
                            child: _trend(context, l10n, data, dimWord),
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      _card(
                        context,
                        title: l10n.analyticsCategoryComposition(dimWord),
                        child: _categoryRanking(context, data),
                      ),
                      const SizedBox(height: 12),
                      _card(
                        context,
                        title: l10n.analyticsTagComposition(dimWord),
                        child: _tagRanking(context, l10n, data),
                      ),
                      // B2(v47):自定义字段汇总(有定义且有值才出现)。
                      if (data.customFields.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _card(
                          context,
                          title: l10n.rangeReportCustomFieldTitle,
                          child: _customFieldStats(context, l10n, data),
                        ),
                      ],
                    ],
                  ],
                ),
                // 更新中提示：贴顶 2px 进度条（滚走也不会丢），替代原来
                // 整屏转圈的粗暴反馈。
                if (loading)
                  const Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: LinearProgressIndicator(minHeight: 2),
                  ),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _rangeCard(BuildContext context, AppLocalizations l10n) {
    return Material(
      color: PiggyTokens.surface(context),
      borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        onTap: _pickRange,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.calendar_today_outlined,
                  size: 18, color: PiggyTokens.primary(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_rangeText(),
                    style: PiggyTextTokens.strongTitle(context)),
              ),
              Text(
                l10n.rangeReportChangeRange,
                style: PiggyTextTokens.caption(context)
                    .copyWith(color: PiggyTokens.textTertiary(context)),
              ),
              Icon(Icons.expand_more, color: PiggyTokens.textTertiary(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _card(BuildContext context,
      {required String title, required Widget child}) {
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        border: Border.all(color: PiggyTokens.primary(context), width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
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
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
              ),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PiggyTextTokens.strongTitle(context)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }

  /// 对比表：行=支出/收入/结余，列=本期 / 环比上期 / 同比去年同期。
  ///
  /// 环比、同比两列各占一格：上行是变化率，下行是**对比窗的绝对额**。
  /// 涨绿跌红按行语义走（支出涨=坏，收入涨=好），颜色仍取用户的红绿方案。
  Widget _compareCard(
      BuildContext context, AppLocalizations l10n, _ReportData data) {
    final rows = <(String, double, double, double, bool)>[
      (l10n.homeExpense, data.cur.$2, data.mom.$2, data.yoy.$2, false),
      (l10n.homeIncome, data.cur.$1, data.mom.$1, data.yoy.$1, true),
      (
        l10n.homeBalance,
        data.cur.$1 - data.cur.$2,
        data.mom.$1 - data.mom.$2,
        data.yoy.$1 - data.yoy.$2,
        true,
      ),
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        border: Border.all(color: PiggyTokens.primary(context), width: 1.5),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Row(
              children: [
                const SizedBox(width: 44),
                Expanded(
                    child: _headCell(context, l10n.rangeReportColumnCurrent)),
                Expanded(child: _headCell(context, l10n.rangeReportColumnMom)),
                Expanded(child: _headCell(context, l10n.rangeReportColumnYoy)),
              ],
            ),
          ),
          for (final row in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox(
                    width: 44,
                    child: Text(row.$1, style: PiggyTextTokens.label(context)),
                  ),
                  Expanded(
                      child: AmountText(
                          value: row.$2,
                          signed: false,
                          useCompactFormat: true,
                          style: const TextStyle(
                              fontSize: PiggyTextTokens.fs14, fontWeight: FontWeight.w700))),
                  Expanded(
                      child: _deltaCell(context, ref, row.$2, row.$3,
                          goodWhenUp: row.$5)),
                  Expanded(
                      child: _deltaCell(context, ref, row.$2, row.$4,
                          goodWhenUp: row.$5)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _headCell(BuildContext context, String text) {
    return Text(
      text,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: PiggyTextTokens.caption(context)
          .copyWith(color: PiggyTokens.textTertiary(context)),
    );
  }

  Widget _deltaCell(
      BuildContext context, WidgetRef ref, double cur, double prev,
      {required bool goodWhenUp}) {
    final rate = RangeReportPage.changeRate(cur, prev);
    final up = (rate ?? 0) > 0;
    final rateColor = rate == null || rate == 0
        ? PiggyTokens.textTertiary(context)
        : (up == goodWhenUp
            ? PiggyTokens.incomeColor(context, ref)
            : PiggyTokens.expenseColor(context, ref));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          rate == null
              ? '—'
              : '${rate > 0 ? '+' : ''}${(rate * 100).toStringAsFixed(1)}%',
          style: TextStyle(
              fontSize: PiggyTextTokens.fs13, fontWeight: FontWeight.w600, color: rateColor),
        ),
        AmountText(
          value: prev,
          signed: false,
          useCompactFormat: true,
          style: PiggyTextTokens.caption(context)
              .copyWith(color: PiggyTokens.textTertiary(context)),
        ),
      ],
    );
  }

  Widget _trend(BuildContext context, AppLocalizations l10n, _ReportData data,
      String word) {
    final hide = ref.watch(hideAmountsProvider);
    final currency = ref.watch(currentLedgerCurrencyProvider);
    final fmt = data.byMonth ? DateFormat('MM') : DateFormat('d');
    final series = data.series;
    return AnalyticsBarChart(
      values: [for (final e in series) e.total],
      xLabels: [for (final e in series) fmt.format(e.day)],
      highlightIndex: null,
      hideAmounts: hide,
      themeColor: PiggyTokens.primary(context),
      isDark: PiggyTokens.isDark(context),
      onSwipeLeft: () => _shiftWindow(1),
      onSwipeRight: () => _shiftWindow(-1),
      isChineseLocale: _isChinese,
      pointTooltipText: (i) => '${fmt.format(series[i].day)} $word '
          '${hide ? '**' : formatBalance(series[i].total, currency, isChineseLocale: _isChinese)}',
    );
  }

  Widget _categoryRanking(BuildContext context, _ReportData data) {
    final sum = data.cats.fold<double>(0, (a, b) => a + b.total);
    return Column(
      children: [
        for (var i = 0; i < data.cats.length; i++)
          CategoryRankRow(
            categoryId: data.cats[i].id,
            category: data.cats[i].category,
            name: data.cats[i].name,
            value: data.cats[i].total,
            percent: sum == 0 ? 0 : data.cats[i].total / sum,
            color: i < PiggyChartTokens.seriesColors.length
                ? PiggyChartTokens.seriesColors[i]
                : PiggyTokens.textTertiary(context),
            start: _start,
            end: _end,
            // 组件按 scope 决定「是否把区间带给分类详情页」（'all' 会丢掉），
            // 自定义区间要原样透传，所以这里给非 'all' 的值 + 显式标签文案。
            scope: 'month',
            selMonth: _start,
            periodLabel: _rangeText(),
            rank: i + 1,
            count: data.cats[i].count,
          ),
      ],
    );
  }

  Widget _tagRanking(
      BuildContext context, AppLocalizations l10n, _ReportData data) {
    if (data.tags.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(l10n.commonEmpty, style: PiggyTextTokens.caption(context)),
      );
    }
    // 标签不互斥（一笔可挂多个），各行之和通常大于区间总额 → 占比按
    // 「标签行之和」算，与标签详情页的单标签口径一致。
    final sum = data.tags.fold<double>(0, (a, b) => a + b.total);
    return Column(
      children: [
        for (var i = 0; i < data.tags.length; i++)
          _tagRow(context, l10n, data.tags[i], i, sum),
      ],
    );
  }

  Widget _tagRow(
      BuildContext context,
      AppLocalizations l10n,
      ({int id, String name, String? color, double total, int count}) tag,
      int index,
      double sum) {
    final color = _parseTagColor(tag.color) ??
        PiggyChartTokens
            .seriesColors[index % PiggyChartTokens.seriesColors.length];
    final percent = sum == 0 ? 0.0 : tag.total / sum;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Container(
            width: 10,
            height: 10,
            margin: const EdgeInsets.only(right: 10),
            decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(PiggyDimens.radiusXs)),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(tag.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: PiggyTextTokens.body(context)),
                    ),
                    const SizedBox(width: 6),
                    Text(l10n.analyticsTxCountShort(tag.count),
                        style: PiggyTextTokens.caption(context).copyWith(
                            color: PiggyTokens.textTertiary(context))),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                  child: Stack(
                    children: [
                      Container(
                          height: 5, color: color.withValues(alpha: 0.15)),
                      FractionallySizedBox(
                        widthFactor: percent.clamp(0, 1),
                        child: Container(
                            height: 5, color: color.withValues(alpha: 0.9)),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('${(percent * 100).toStringAsFixed(1)}%',
                  style: PiggyTextTokens.caption(context)
                      .copyWith(color: PiggyTokens.textTertiary(context))),
              const SizedBox(height: 2),
              AmountText(
                value: tag.total,
                signed: false,
                showCurrency: true,
                useCompactFormat: true,
                style:
                    const TextStyle(fontSize: PiggyTextTokens.fs14, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// B2(v47)：自定义字段汇总卡内容。每个字段一段：字段名 + 值桶行。
  /// 桶按当前维度（_dim）金额降序，超过 [_cfTopN] 合并进「其他」。
  /// 注意：本卡的文字一律走 PiggyTextTokens —— 不新增 fontSize 字面量，
  /// 避免把 U1 ratchet 基线顶高。
  Widget _customFieldStats(
      BuildContext context, AppLocalizations l10n, _ReportData data) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final field in data.customFields) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child:
                Text(field.name, style: PiggyTextTokens.strongTitle(context)),
          ),
          ..._customFieldValueRows(context, l10n, field),
        ],
      ],
    );
  }

  List<Widget> _customFieldValueRows(BuildContext context,
      AppLocalizations l10n, CustomFieldFieldStats field) {
    const topN = 8;
    final all = field.sorted(_dim);
    final shown = all.take(topN).toList();
    final rest = all.skip(topN).toList();
    ({double income, double expense, int count}) mergeRest(
        List<({String label, double income, double expense, int count})> src) {
      var income = 0.0, expense = 0.0, count = 0;
      for (final b in src) {
        income += b.income;
        expense += b.expense;
        count += b.count;
      }
      return (income: income, expense: expense, count: count);
    }

    final buckets = [...shown];
    if (rest.isNotEmpty) {
      final merged = mergeRest(rest);
      buckets.add((
        label: l10n.commonOther,
        income: merged.income,
        expense: merged.expense,
        count: merged.count
      ));
    }
    return [
      for (final b in buckets)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(b.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PiggyTextTokens.body(context)),
              ),
              const SizedBox(width: 6),
              Text(l10n.analyticsTxCountShort(b.count),
                  style: PiggyTextTokens.caption(context)
                      .copyWith(color: PiggyTokens.textTertiary(context))),
              const SizedBox(width: 12),
              AmountText(
                value: _dim == 'income' ? b.income : b.expense,
                signed: false,
                showCurrency: true,
                useCompactFormat: true,
                style: PiggyTextTokens.strongTitle(context),
              ),
            ],
          ),
        ),
    ];
  }

  /// 标签颜色是用户输入的 `#RRGGBB` / `#AARRGGBB`，脏值回落到调色板。
  static Color? _parseTagColor(String? raw) {
    if (raw == null) return null;
    final hex = raw.replaceFirst('#', '');
    if (hex.length != 6 && hex.length != 8) return null;
    final v = int.tryParse(hex, radix: 16);
    if (v == null) return null;
    return hex.length == 8 ? Color(v) : Color(0xFF000000 | v);
  }
}

class _ReportData {
  const _ReportData({
    required this.cur,
    required this.mom,
    required this.yoy,
    required this.series,
    required this.byMonth,
    required this.cats,
    required this.tags,
    required this.txCount,
    required this.customFields,
  });

  /// (收入, 支出) —— 位次与 `totalsInRange` 的返回一致
  final (double income, double expense) cur;
  final (double income, double expense) mom;
  final (double income, double expense) yoy;
  final List<({DateTime day, double total})> series;
  final bool byMonth;
  final List<
      ({
        int? id,
        String name,
        db.Category? category,
        double total,
        int count,
        List<
            ({
              int id,
              db.Category category,
              String name,
              double total
            })> subCategories
      })> cats;
  final List<({int id, String name, String? color, double total, int count})>
      tags;
  final int txCount;

  /// B2(v47)：自定义字段汇总（定义非空且区间内有值才有内容）。
  final List<CustomFieldFieldStats> customFields;
}
