import 'package:flutter/foundation.dart' show SynchronousFuture;
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
import '../../widgets/analytics/amount_metric_chip.dart';
import '../../widgets/analytics/metric_segment.dart';
import '../../widgets/analytics/time_metric_chip.dart';
import '../../widgets/analytics/category_rank_row.dart';
import '../../widgets/analytics/custom_field_stats_card.dart';
import '../../widgets/analytics/analytics_filter_sheet.dart';
import '../../widgets/analytics/insight_card.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../l10n/app_localizations.dart';
import '../../services/export/share_poster_service.dart';
import '../../services/system/logger_service.dart';
import '../../data/db.dart' as db;
import '../../data/models/analytics_amount_metric.dart';
import '../../data/models/analytics_time_metric.dart';
import '../../data/models/analytics_transaction_filter.dart';
import '../report/range_report_page.dart';
import '../../utils/analytics_scope.dart';
import '../../utils/transaction_search_filter.dart';
import '../../utils/month_range.dart';
import '../../utils/week_range.dart';
import '../../utils/format_utils.dart';
import '../../utils/analytics_average.dart';
import '../../utils/analytics_category_rollup.dart';

class AnalyticsPage extends ConsumerStatefulWidget {
  const AnalyticsPage({super.key});

  /// 主壳 Tab 懒加载入口(见 app.dart _LazyTab):首次切到分析 Tab 才 build。
  static Widget builder(BuildContext context) => const AnalyticsPage();

  @override
  ConsumerState<AnalyticsPage> createState() => _AnalyticsPageState();
}

class _AnalyticsPageState extends ConsumerState<AnalyticsPage> {
  AnalyticsScope _scope = AnalyticsScope.month;
  String _type = 'expense'; // expense | income | balance
  AnalyticsTransactionFilter _filter = const AnalyticsTransactionFilter();
  bool _chartSwiped = false; // 吸收图表区域横滑，避免父级切换收入/支出
  bool _localChartDismissed = false;
  // 周报选中的周（该周周一），独立于首页月份状态，避免污染首页
  DateTime _selWeek = weekLabelFor(DateTime.now());

  /// 自定义区间（半开 [start, end)）。与 _selWeek 同定位：页面本地状态，
  /// 不进 selectedMonthProvider（自定义区间不是「共享选中月」语义）。
  /// late 惰性初始化：首次切入自定义档位 = 近 30 天（含今天）。
  late DateRange _customRange = _defaultCustomRange();

  /// 默认自定义区间 = 近 30 天（含今天）：[today-29d, today+1d)。
  DateRange _defaultCustomRange() {
    final today = DateTime.now();
    final start = DateTime(today.year, today.month, today.day - 29);
    return (start: start, end: start.add(const Duration(days: 30)));
  }

  /// 审计 U8：FutureBuilder future 缓存（key: type|start|end|refreshTick）
  ///
  /// 单条记忆化：只保留**最近一次**查询的 future —— 键含 refreshTick/时间戳/
  /// 类型，交互每次变化都产生新键，无淘汰的 Map 会让旧 future（及其持有的
  /// 整段查询结果 list）随交互无限累积（本页常驻主 Tab 栈，泄漏随会话增长）。
  /// 唯一消费点只在 build 里读当前键，历史条目无人再读，保留单条即满足
  /// 「setState 重建复用已发查询」的原始目的。
  ///
  /// 结果形状是 `(口径, 数据包)` 记录：支出/收入/结余三种口径数据包字段不同
  /// （结余是 [BalanceInsightsData]、支出/收入是 [InOutInsightsData]），而
  /// FutureBuilder 换 future 时会**保留**上一份 `_data`，不带口径标签就无法
  /// 判断这份数据能不能给当前口径用——跨口径复用会串数据。
  Future<(String, InsightsData)>? _lastAnalyticsFuture;
  String? _lastAnalyticsKey;

  /// 已查过的口径结果，键 = memoKey（含口径 + 范围 + 刷新 tick）。
  /// 切回看过的口径命中缓存 → `SynchronousFuture` 同帧出数，不再转圈。
  final Map<String, (String, InsightsData)> _resultCache = {};
  String? _cacheScope;

  /// 头部覆盖层（标题/口径条/筛选栏 + 口径说明 + 外币横幅）的挂点，
  /// 只用于量它的高度 —— 见 [_measureHeaderHeight]。
  final GlobalKey _headerKey = GlobalKey();

  /// 头部覆盖层实测高度：列表铺满整个 body（卡片可滚到头部下方，磨砂才有
  /// 内容可模糊），但首屏内容必须从头部下沿开始。这个高度不能用常量兜——
  /// [AmountMetricNote] / [TimeMetricNote] / 外币横幅都是条件渲染，高度随
  /// 口径与账本内容变。
  double _headerHeight = 0;

  /// 在 build 里登记「帧末量一次头部高度」。
  ///
  /// 量高度必须在布局提交之后（build 期间 render 尺寸还是上一帧的），所以走
  /// post-frame；变化不足 0.5 不 setState，否则「setState → 再量 → 再 setState」
  /// 会无限重建。
  void _measureHeaderHeight() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final box = _headerKey.currentContext?.findRenderObject();
      if (box is! RenderBox || !box.hasSize) return;
      final h = box.size.height;
      if ((h - _headerHeight).abs() > 0.5) {
        setState(() => _headerHeight = h);
      }
    });
  }

  /// U8 缓存的记忆化入口：键命中返回已发 future；未命中发起查询并替换
  /// 旧条目（单条容量，见 _lastAnalyticsFuture 注释）。
  ///
  /// 三级取数（与 range_report_page 的 `_futureFor` 同款）：同键复用已发查询
  /// → 口径缓存命中同步出数 → 都没有才真查库。
  Future<(String, InsightsData)> _rememberAnalyticsFuture(String memoKey,
      String scopeKey, Future<(String, InsightsData)> Function() create) {
    if (_cacheScope != scopeKey) {
      _cacheScope = scopeKey;
      _resultCache.clear();
    }
    final cached = _resultCache[memoKey];
    if (cached != null) return SynchronousFuture(cached);
    if (_lastAnalyticsKey == memoKey && _lastAnalyticsFuture != null) {
      return _lastAnalyticsFuture!;
    }
    final future = create();
    future.then((value) {
      // 慢响应不能污染缓存：期间范围已经换掉的话，它的数属于旧 scope。
      if (_cacheScope == scopeKey) _resultCache[memoKey] = value;
    }).catchError((Object e, StackTrace st) {
      // P1-B：查询失败必须落日志（带记忆键上下文，可定位是哪个视角/类型的
      // 查询挂了）；错误仍原样传给 FutureBuilder 渲染错误态。
      logger.warning('Analytics', '统计数据查询失败 key=$memoKey: $e\n$st');
    });
    _lastAnalyticsKey = memoKey;
    _lastAnalyticsFuture = future;
    return future;
  }

  // 显示周期选择器
  void _showPeriodPicker() async {
    final selMonth = ref.read(selectedMonthProvider);
    // 穷尽 switch（无 default）：新增档位时编译器强制补分支
    switch (_scope) {
      case AnalyticsScope.week:
        final res = await showWheelDatePicker(
          context,
          initial: _selWeek,
          mode: WheelDatePickerMode.ymd,
          maxDate: DateTime.now(),
        );
        if (res != null) {
          setState(() => _selWeek = weekLabelFor(res));
        }
      case AnalyticsScope.month:
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
      case AnalyticsScope.year:
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
      case AnalyticsScope.quarter:
        // 无 yq 模式 wheel：用年月选择后吸附到该月所在季度首月标签月
        // （锚点形状 DateTime(y, 3k+1, 1)，见 analytics_scope.dart D2/D3）
        final res = await showWheelDatePicker(
          context,
          initial: selMonth,
          mode: WheelDatePickerMode.ym,
          maxDate: DateTime.now(),
        );
        if (res != null) {
          ref.read(selectedMonthProvider.notifier).state =
              DateTime(res.year, ((res.month - 1) ~/ 3) * 3 + 1, 1);
        }
      case AnalyticsScope.custom:
        // 项目统一区间抽屉（与 RangeReportPage 同款）：抽屉收含端日期，
        // 页面统一存半开区间 [start, end)，故 end 回读时 +1 天
        final r = _customRange;
        final now = DateTime.now();
        final picked = await showPiggyRangePickerSheet(
          context,
          firstDate: DateTime(2000),
          lastDate: DateTime(now.year, now.month, now.day),
          initialStart: r.start,
          initialEnd: r.end.subtract(const Duration(days: 1)),
        );
        if (picked != null) {
          setState(() {
            _customRange = (
              start: picked.start,
              end: DateTime(
                  picked.end.year, picked.end.month, picked.end.day + 1),
            );
          });
        }
      case AnalyticsScope.all:
        break; // all视角不显示选择器
    }
  }

  Future<void> _openFilterSheet() async {
    final result = await showAnalyticsFilterSheet(context, initial: _filter);
    if (result == null || !mounted) return;
    setState(() => _filter = result);
  }

  String _typeFilterLabel(String type, AppLocalizations l10n) => switch (type) {
        'income' => l10n.homeIncome,
        'transfer' => l10n.transferTitle,
        _ => l10n.homeExpense,
      };

  String _conditionFilterLabel(
      CustomFieldCondition condition, AppLocalizations l10n) {
    final value = switch (condition) {
      CustomFieldConditionEq(:final value) => value,
      CustomFieldConditionContains(:final value) => value,
      CustomFieldConditionAnyOf(:final values) =>
        (values.toList()..sort()).join(' / '),
      CustomFieldConditionBetween(:final lower, :final upper) =>
        upper == null ? '≥$lower' : '$lower~$upper',
    };
    return l10n.customFieldFilterChip(condition.fieldName, value);
  }

  Widget _buildFilterBar(AppLocalizations l10n, Color primary) {
    final chips = <Widget>[
      for (final type in (_filter.types.toList()..sort()))
        InputChip(
          label: Text(_typeFilterLabel(type, l10n)),
          onDeleted: () => setState(() {
            final next = {..._filter.types}..remove(type);
            _filter = _filter.copyWith(types: next);
          }),
          deleteIconColor: PiggyTokens.error(context),
        ),
      for (final condition in _filter.customFieldConditions)
        InputChip(
          label: Text(_conditionFilterLabel(condition, l10n)),
          onDeleted: () => setState(() {
            _filter = _filter.copyWith(customFieldConditions: [
              for (final c in _filter.customFieldConditions)
                if (c != condition) c,
            ]);
          }),
          deleteIconColor: PiggyTokens.error(context),
        ),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          OutlinedButton.icon(
            onPressed: _openFilterSheet,
            icon: Icon(
              _filter.isEmpty ? Icons.filter_alt_outlined : Icons.filter_alt,
              size: 16,
            ),
            label: Text(
              _filter.isEmpty
                  ? l10n.analyticsFilterEntry
                  : l10n.analyticsFilterApplied,
            ),
            style: OutlinedButton.styleFrom(
              foregroundColor: primary,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              visualDensity: VisualDensity.compact,
            ),
          ),
          if (chips.isNotEmpty) ...[
            const SizedBox(width: 8),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (final chip in chips)
                      Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: chip,
                      ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // 显示类型选择菜单
  /// v30 补折算横幅(01 §六):currencyCode≠本位币 且 nativeAmount==amount 的
  /// 存量外币交易 >0 时出现;确认后按当前有效汇率重算(逐笔记 change,L13)。
  Widget _buildRecalcForeignBanner(BuildContext context) {
    final count = ref.watch(ledgerUnconvertedForeignTxCountProvider).value ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final primary = ref.watch(primaryColorProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
      child: Material(
        color: PiggyTokens.surface(context),
        // shape 与 borderRadius 互斥（Material 断言）：圆角统一由 shape 提供
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          // 主题色细边框（与洞察页图表卡片统一）
          side: BorderSide(color: primary, width: 1.5),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              Icon(Icons.currency_exchange, size: 16, color: primary),
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
                    style: TextStyle(fontSize: PiggyTextTokens.fs12)),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 折算脚注:账本存在外币交易(含已折算)时,提示统计数字已折本位币。
  Widget _buildConvertedFootnote(BuildContext context) {
    final count = ref.watch(ledgerForeignTxCountProvider).value ?? 0;
    if (count <= 0) return const SizedBox.shrink();
    final base = ref.watch(currentLedgerCurrencyProvider);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AppLocalizations.of(context).statsConvertedFootnote(base),
          style: PiggyTextTokens.caption(context),
        ),
      ),
    );
  }

  Future<void> _runRecalcForeignTx(int count) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dctx) => AppDialogShell(
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
  // 步进+钳制已收拢到 analytics_scope.dart 的 nextAnchor/prevAnchor 纯函数；
  // 状态写回留页面：周→_selWeek 本地，月/季/年→selectedMonthProvider 共享，
  // 自定义→_customRange 本地（等长平移，shiftCustomRange）。
  void _onChartSwipeLeft() {
    if (_scope == AnalyticsScope.custom) {
      setState(() => _customRange = shiftCustomRange(_customRange, 1));
      return;
    }
    final selMonth = ref.read(selectedMonthProvider);
    final sd = ref.read(currentMonthStartDayProvider);
    setState(() {
      final anchor = _scope == AnalyticsScope.week ? _selWeek : selMonth;
      final next = nextAnchor(_scope, anchor, DateTime.now(), startDay: sd);
      if (next == null) return; // all视角不操作 / 已钳制在当前周期
      if (_scope == AnalyticsScope.week) {
        _selWeek = next;
      } else {
        ref.read(selectedMonthProvider.notifier).state = next;
      }
    });
  }

  void _onChartSwipeRight() {
    if (_scope == AnalyticsScope.custom) {
      setState(() => _customRange = shiftCustomRange(_customRange, -1));
      return;
    }
    final selMonth = ref.read(selectedMonthProvider);
    setState(() {
      final anchor = _scope == AnalyticsScope.week ? _selWeek : selMonth;
      final prev = prevAnchor(_scope, anchor);
      if (prev == null) return; // all视角不操作
      if (_scope == AnalyticsScope.week) {
        _selWeek = prev;
      } else {
        ref.read(selectedMonthProvider.notifier).state = prev;
      }
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
        // UI-10：边框走 token，暗色模式下不再用固定浅灰导致不可见
        shape: CircleBorder(
          side:
              BorderSide(color: PiggyTokens.borderThemed(context), width: 1.4),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Center(
            child:
                Icon(icon, size: 18, color: PiggyTokens.textSecondary(context)),
          ),
        ),
      ),
    );
  }

  /// 导航行周期文案：周=日期范围，月=yyyy-MM，季=yyyyQn，年=yyyy，
  /// 自定义=起止日期（含端展示），全部=全部年份
  String _navPeriodLabel(BuildContext context, DateTime selMonth) =>
      switch (_scope) {
        AnalyticsScope.week => weekRangeText(weekRangeFor(_selWeek)),
        AnalyticsScope.month =>
          '${selMonth.year}-${selMonth.month.toString().padLeft(2, '0')}',
        AnalyticsScope.quarter =>
          '${selMonth.year}Q${((selMonth.month - 1) ~/ 3) + 1}',
        AnalyticsScope.year => '${selMonth.year}',
        AnalyticsScope.custom => _customRangeText(),
        AnalyticsScope.all => AppLocalizations.of(context).analyticsAllYears,
      };

  /// 自定义区间文案：yyyy-MM-dd ~ yyyy-MM-dd（含端展示，与
  /// RangeReportPage._rangeText 同风格；内部存半开区间故 end -1 天）
  String _customRangeText() {
    final r = _customRange;
    final e = r.end.subtract(const Duration(days: 1));
    String f(DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
    return '${f(r.start)} ~ ${f(e)}';
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

  @override
  Widget build(BuildContext context) {
    // 帧末量一次头部覆盖层高度（说明行 / 外币横幅条件渲染，高度不固定）；
    // 首帧量到前按 0 计，此时内容被头部覆盖层遮住，没有可见跳动。
    _measureHeaderHeight();
    final headerInset = _headerHeight;
    final repo = ref.watch(repositoryProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final selMonth = ref.watch(selectedMonthProvider);
    // 统计刷新 tick：当有新增/编辑/删除时我们会 +1，这里监听以触发重建和重新拉取
    final refreshTick = ref.watch(statsRefreshProvider);
    // 金额口径（记账金额 / 原始金额，全局持久化）：所有取数与缓存键都带上它
    final amountMetric = ref.watch(analyticsAmountMetricProvider);
    // 统计时间口径（记账时间 / 日期型自定义字段，全局持久化）：区间判定与分桶
    // 都带上它 —— 漏传一处就是「总额按字段日期、分类构成按记账时间」的对不上账
    final timeMetric = ref.watch(analyticsTimeMetricProvider);
    final now = DateTime.now();
    final sd = ref.watch(currentMonthStartDayProvider);
    // 时间范围 + 同比上期窗口：周期计算收拢在 analytics_scope.dart 纯函数
    // （含「当前周期只到今天」截断与各档上期口径，行为冻结见该文件文档）
    final anchor = _scope == AnalyticsScope.week ? _selWeek : selMonth;
    final period = resolveAnalyticsPeriod(_scope,
        anchor: anchor, range: _customRange, startDay: sd, now: now);
    final start = period.start;
    final end = period.end;
    final prevStart = period.prevStart;
    final prevEnd = period.prevEnd;

    // 按视角获取序列
    Future<dynamic> seriesFuture = Future.value(<dynamic>[]);
    Future<dynamic>? incomeSeriesFuture;
    Future<dynamic>? expenseSeriesFuture;
    Future<dynamic> chartSeriesFuture = Future.value(<dynamic>[]);

    // P1 优化：先算 U8 记忆化键，命中则整体跳过下方建查询。drift 查询
    // 调用即执行，原实现每次 setState 都白发 4~6 条聚合 SQL，命中时结果
    // 被 _rememberAnalyticsFuture 丢弃；命中时闭包不执行，占位 future 安全。
    final scopeKey = '${start.millisecondsSinceEpoch}|'
        '${end.millisecondsSinceEpoch}|$refreshTick|$ledgerId|'
        '${amountMetric.storageValue}|${timeMetric.storageValue}|'
        '${_filter.cacheKey}';
    final memoKey = '$_type|$scopeKey';

    // 命中 = 已发查询复用 或 口径缓存已有结果，两种都不必再建查询。
    final memoHit = _resultCache.containsKey(memoKey) ||
        (_lastAnalyticsKey == memoKey && _lastAnalyticsFuture != null);

    if (!memoHit) {
      // 全部聚合都带上当前金额口径与时间口径 —— 汇总卡 / 图表 / 环形图 /
      // 排行同源，少传一处就会出现「总额按原始金额、分类构成按记账金额」或
      // 「总额按字段日期、趋势按记账时间」的对不上账。
      final metric = amountMetric;
      final time = timeMetric;
      final extraFilter = _filter;
      // 主序列路由由 seriesKind 决定：week/month=日、year=月、all=年序列
      if (_type == 'balance') {
        // 结余模式：同时获取收入和支出数据
        switch (_scope.seriesKind) {
          case AnalyticsSeriesKind.day:
            incomeSeriesFuture = repo.totalsByDay(
                ledgerId: ledgerId,
                type: 'income',
                start: start,
                end: end,
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
            expenseSeriesFuture = repo.totalsByDay(
                ledgerId: ledgerId,
                type: 'expense',
                start: start,
                end: end,
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
          case AnalyticsSeriesKind.month:
            incomeSeriesFuture = repo.totalsByMonth(
                ledgerId: ledgerId,
                type: 'income',
                year: selMonth.year,
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
            expenseSeriesFuture = repo.totalsByMonth(
                ledgerId: ledgerId,
                type: 'expense',
                year: selMonth.year,
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
          case AnalyticsSeriesKind.yearSeries:
            incomeSeriesFuture = repo.totalsByYearSeries(
                ledgerId: ledgerId,
                type: 'income',
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
            expenseSeriesFuture = repo.totalsByYearSeries(
                ledgerId: ledgerId,
                type: 'expense',
                amountMetric: metric,
                timeMetric: time,
                filter: extraFilter);
        }
        seriesFuture = Future.value([]); // 占位
      } else {
        // 收入或支出模式
        seriesFuture = switch (_scope.seriesKind) {
          AnalyticsSeriesKind.day => repo.totalsByDay(
              ledgerId: ledgerId,
              type: _type,
              start: start,
              end: end,
              amountMetric: metric,
              timeMetric: time,
              filter: extraFilter),
          AnalyticsSeriesKind.month => repo.totalsByMonth(
              ledgerId: ledgerId,
              type: _type,
              year: selMonth.year,
              amountMetric: metric,
              timeMetric: time,
              filter: extraFilter),
          AnalyticsSeriesKind.yearSeries => repo.totalsByYearSeries(
              ledgerId: ledgerId,
              type: _type,
              amountMetric: metric,
              timeMetric: time,
              filter: extraFilter),
        };
      }

      // 图表固定6根柱的序列（柱状图/折线图共用）：本期 + 前5期
      // （窗口见 chartSeriesWindow：周=本周+前5周、月=本月+前5周期月；
      // 年/全部走年序列无窗口）
      Future<dynamic> buildChartSeries(
          dynamic repo, int ledgerId, String type) {
        final w = chartSeriesWindow(_scope,
            anchor: anchor, range: _customRange, startDay: sd);
        if (w == null) {
          return repo.totalsByYearSeries(
              ledgerId: ledgerId,
              type: type,
              amountMetric: metric,
              timeMetric: time,
              filter: extraFilter);
        }
        return repo.totalsByDay(
            ledgerId: ledgerId,
            type: type,
            start: w.start,
            end: w.end,
            amountMetric: metric,
            timeMetric: time,
            filter: extraFilter);
      }

      if (_type == 'balance') {
        chartSeriesFuture = Future.wait<dynamic>([
          buildChartSeries(repo, ledgerId, 'income'),
          buildChartSeries(repo, ledgerId, 'expense'),
        ]).then((r) => _calculateBalanceSeries(r[0], r[1]));
      } else {
        chartSeriesFuture = buildChartSeries(repo, ledgerId, _type);
      }
    }

    return Scaffold(
      body: Stack(
        children: [
          // 内容层：列表铺满整个 body，首屏留白由列表自身 padding 让出
          // （_headerHeight）。这样卡片能滚到头部下方 —— 头部磨砂层只有
          // 下面真的滚过内容才看得出效果，否则模糊的是纯背景色。
          Positioned.fill(
            child: FutureBuilder(
              // ⚠️ 这里曾挂 `key: ValueKey('analytics_$_type')`——切支出/收入/
              // 结余时 key 变 → 整个 FutureBuilder 元素被销毁重建 → snapshot
              // 归零 → 整页塌成居中转圈（且 ListView 重建，滚动位置回到顶部）。
              // 口径差异改由数据自带的 shape 标签判定（见 _shapeOf），不能再靠
              // key 强制换元素。
              //
              // 审计 U8：缓存 future——任意 setState（横幅交互等）重建时
              // 复用已发查询，不再整段重发导致闪烁；数据变化（refreshTick）
              // 或时间范围/类型变化才发起新查询。单条记忆化：旧键的 future
              // 无人再读，直接丢弃防止随交互无限累积（见字段注释）。
              future: _rememberAnalyticsFuture(
                // P1：键已在上方计算并用于跳过建查询，此处直接复用
                memoKey,
                scopeKey,
                () {
                  // 口径在建查询时就钉死：create() 是立即执行的，.then 里再读
                  // _type 可能已被切走，标签会标错。
                  final shape = _shapeOf(_type);
                  return (_type == 'balance'
                          ? _loadBalanceData(
                              repo,
                              ledgerId,
                              start,
                              end,
                              seriesFuture,
                              incomeSeriesFuture!,
                              expenseSeriesFuture!,
                              prevStart,
                              prevEnd,
                              chartSeriesFuture,
                              amountMetric,
                              timeMetric,
                              _filter)
                          : _loadCategoryData(
                              repo,
                              ledgerId,
                              _type,
                              start,
                              end,
                              seriesFuture,
                              prevStart,
                              prevEnd,
                              chartSeriesFuture,
                              amountMetric,
                              timeMetric,
                              _filter))
                      .then((loaded) => (shape, loaded));
                },
              ),
              builder: (context, snapshot) {
                // P1-B：查询失败时不能落进「!hasData → 无限转圈」（DB 异常
                // 后页面永久卡死），渲染错误态；重试通过 bump statsRefresh
                // 改变记忆化键，触发重新发起查询。
                if (snapshot.hasError) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline,
                            size: 40, color: PiggyTokens.textTertiary(context)),
                        const SizedBox(height: 12),
                        Text(
                          AppLocalizations.of(context)
                              .commonLoadFailed(snapshot.error.toString()),
                          textAlign: TextAlign.center,
                          style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context)),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: () =>
                              ref.read(statsRefreshProvider.notifier).state++,
                          child: Text(
                              AppLocalizations.of(context).helpCenterRetry),
                        ),
                      ],
                    ),
                  );
                }
                // 在途查询继续渲染上一份**同口径**结果（首屏才转圈）：切支出/
                // 收入/结余、切周/月/年/全部、切周期都只是数字就地更新，不再
                // 整页塌成转圈再重建——闪动与滚动位置丢失的根因就在这行判断。
                // FutureBuilder 换 future 时保留的 _data 是上一口径的记录，
                // 口径不匹配时必须丢弃（否则按错位次取值 = 串数据）。
                final tag = snapshot.data;
                final data =
                    (tag != null && tag.$1 == _shapeOf(_type)) ? tag.$2 : null;
                if (data == null) {
                  return Center(
                    child: PiggySpinner(
                      size: 36,
                      color: PiggyTokens.primary(context),
                    ),
                  );
                }

                // 在balance模式下，需要计算结余数据
                dynamic seriesRaw;
                List<CatAgg> catData;
                int txCount;
                double sum;
                double balance = 0; // 本期收支结余
                double? prevTotal; // 上期总额（同比）
                double expenseTotal = 0; // 本期总支出（结余视角第 4 格用）

                // 穷尽 switch（无 default）：新增数据包子类时编译器强制补分支
                switch (data) {
                  case BalanceInsightsData(
                      :final series,
                      :final cats,
                      :final curTotals,
                      :final prevTotals,
                      :final expenseCount,
                      :final incomeCount,
                    ):
                    // 结余序列由加载侧算好（见 BalanceInsightsData.series）
                    seriesRaw = series;

                    // 分类数据显示支出分类（但结余模式下不显示排行榜）
                    catData = cats;

                    // 收入和支出的交易数量合计
                    txCount = expenseCount + incomeCount;

                    // 总结余 = 收入总额 - 支出总额（总额由加载侧求和）
                    sum = curTotals.$1 - curTotals.$2;
                    // 结余视角：结余即总额；同比=上期收入-支出；第4格显示总支出
                    balance = sum;
                    prevTotal = prevTotals.$1 - prevTotals.$2;
                    expenseTotal = curTotals.$2;
                  case InOutInsightsData(
                      :final series,
                      :final cats,
                      :final curTotals,
                      :final prevTotals,
                    ):
                    catData = cats;
                    seriesRaw = series;
                    // 不解构 txCount：pattern 绑定会同名遮蔽外层局部变量
                    txCount = data.txCount;
                    sum = catData.fold<double>(0, (a, b) => a + b.total);
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
                  final l10n = AppLocalizations.of(context);
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
                      // top 让出头部覆盖层：内容可从头部下方滚过
                      padding:
                          EdgeInsets.fromLTRB(16, headerInset + 16, 16, 16),
                      children: [
                        if (_filter.isNotEmpty) ...[
                          AppEmpty(
                            text: l10n.analyticsFilterNoResults,
                            subtext: l10n.analyticsFilterNoResultsSubtext,
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.center,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.filter_alt_off_outlined),
                              label: Text(l10n.searchClearFilter),
                              onPressed: () => setState(() =>
                                  _filter = const AnalyticsTransactionFilter()),
                            ),
                          ),
                        ] else ...[
                          AppEmpty(
                            text: l10n.commonEmpty,
                            subtext: l10n.analyticsNoDataSubtext,
                          ),
                          const SizedBox(height: 12),
                          Align(
                            alignment: Alignment.center,
                            child: OutlinedButton.icon(
                              icon: const Icon(Icons.swap_horiz),
                              label:
                                  Text(l10n.analyticsSwitchTo(_type == "expense"
                                      ? l10n.homeIncome
                                      : _type == "income"
                                          ? l10n.homeBalance
                                          : l10n.homeExpense)),
                              onPressed: _cycleTypeForward,
                            ),
                          ),
                        ],
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
                final chartSeriesRaw = data.chartSeries;
                dynamic chartSeries;
                if (chartSeriesRaw is List<({DateTime day, double total})>) {
                  // 桶起点与查询窗口同源（chartSeriesWindow）：6 桶 = 本期+前5期
                  final w = chartSeriesWindow(_scope,
                      anchor: anchor, range: _customRange, startDay: sd);
                  chartSeries = switch (_scope) {
                    AnalyticsScope.week =>
                      _aggregateToWeeks(chartSeriesRaw, w!.start),
                    AnalyticsScope.month => _aggregateToMonths(
                        chartSeriesRaw, labelForDate(w!.start, sd), sd),
                    // 季度：日序列滚 6 个季度桶（本期+前5季），桶键=季度首月标签月
                    AnalyticsScope.quarter => () {
                        final ql = quarterLabelFor(w!.start, sd);
                        return aggregateToQuarters(chartSeriesRaw,
                            firstQuarterLabel:
                                DateTime(ql.year, (ql.quarter - 1) * 3 + 1, 1),
                            startDay: sd);
                      }(),
                    // 自定义：≤31 天按天画；超限按自然月并桶（同收支报表口径）
                    AnalyticsScope.custom =>
                      chartSeriesRaw.length > RangeReportPage.dayChartLimit
                          ? RangeReportPage.rollToMonths(chartSeriesRaw)
                          : chartSeriesRaw,
                    AnalyticsScope.year || AnalyticsScope.all => chartSeriesRaw,
                  };
                } else if (chartSeriesRaw is List<({int year, double total})>) {
                  chartSeries = switch (_scope) {
                    // 年报：选中年 + 前5年（最多6个年份）
                    AnalyticsScope.year => () {
                        final ys = chartSeriesRaw
                            .where((e) => e.year <= selMonth.year)
                            .toList();
                        return ys.length > 6 ? ys.sublist(ys.length - 6) : ys;
                      }(),
                    // 全部/其他：所有年份（过滤未来年份）
                    AnalyticsScope.week ||
                    AnalyticsScope.month ||
                    AnalyticsScope.quarter ||
                    AnalyticsScope.custom ||
                    AnalyticsScope.all =>
                      chartSeriesRaw.where((e) => e.year <= now.year).toList(),
                  };
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
                    if (_scope == AnalyticsScope.week) {
                      return chartSeries
                          .map((e) => '${two(e.day.month)}.${two(e.day.day)}')
                          .toList(growable: false);
                    }
                    // 自定义：≤31 天按天 MM.dd；超限已并桶为月（day=月首），yy.MM
                    if (_scope == AnalyticsScope.custom) {
                      final rolled =
                          chartSeriesRaw.length > RangeReportPage.dayChartLimit;
                      return chartSeries
                          .map((e) => rolled
                              ? '${e.day.year.toString().substring(2)}.${two(e.day.month)}'
                              : '${two(e.day.month)}.${two(e.day.day)}')
                          .toList(growable: false);
                    }
                    return chartSeries
                        .map((e) => e.day.day.toString())
                        .toList(growable: false);
                  }
                  if (chartSeries is List<({DateTime month, double total})>) {
                    // 季度桶：桶键=季度首月标签月，标 yyQn 短标签
                    if (_scope == AnalyticsScope.quarter) {
                      return chartSeries
                          .map((e) =>
                              '${e.month.year.toString().substring(2)}Q${quarterOf(e.month)}')
                          .toList(growable: false);
                    }
                    // 自定义月桶（防御分支，实际 custom 保持天形状）：yy.MM
                    if (_scope == AnalyticsScope.custom) {
                      return chartSeries
                          .map((e) =>
                              '${e.month.year.toString().substring(2)}.${e.month.month.toString().padLeft(2, '0')}')
                          .toList(growable: false);
                    }
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

                // 高亮当前选中周期（最后一根柱/最后一点）；全部/自定义无「当前期」不高亮
                int? highlightIndex;
                if (_scope != AnalyticsScope.all &&
                    _scope != AnalyticsScope.custom &&
                    xLabels.isNotEmpty) {
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

                // 折线图卡片标题：本周趋势 / 本月趋势 / 本季度趋势 / 今年趋势 / …
                final lineTitle = l10n.analyticsTrendTitle(switch (_scope) {
                  AnalyticsScope.week => l10n.analyticsThisWeek,
                  AnalyticsScope.month => l10n.analyticsThisMonth,
                  AnalyticsScope.quarter => l10n.analyticsThisQuarter,
                  AnalyticsScope.year => l10n.analyticsThisYear,
                  AnalyticsScope.custom => l10n.analyticsSelectedRange,
                  AnalyticsScope.all => l10n.analyticsAll,
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
                } else if (chartSeries
                    is List<({DateTime month, double total})>) {
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

                // 分类构成卡的环形图数据（record 映射移出内层 Builder，见
                // design.md §一.3：Builder 只保树形，不再藏取数逻辑）
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

                // ===== 洞察卡片注册表 =====
                // 新增/隐藏卡片 = 清单一项 + 谓词一处；五卡顺序与收编前逐项
                // 一致。build 返回「卡片 + 后置间距」片段——卡片间距不均匀
                // （排行榜与自定义字段卡之间无间距），片段化才能保持树形。
                final cards = <InsightCardDef>[
                  InsightCardDef(
                    id: 'summary',
                    visible: true,
                    build: () => [
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
                        prevTotal:
                            _scope == AnalyticsScope.all ? null : prevTotal,
                        balance: balance,
                        txCount: txCount,
                        expenseTotal: _type == 'balance' ? expenseTotal : null,
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  InsightCardDef(
                    id: 'trendChart',
                    visible: true,
                    build: () => [
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
                                    borderRadius: BorderRadius.circular(
                                        PiggyDimens.radiusXs),
                                  ),
                                ),
                                Text(
                                  lineTitle,
                                  style: PiggyTextTokens.strongTitle(context),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              height: 200,
                              // RepaintBoundary:图表触摸/tooltip 只重绘图表层,
                              // 不把整页(三图表+排行榜)卷进 repaint
                              child: RepaintBoundary(
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
                                    final setter =
                                        ref.read(analyticsHintsSetterProvider);
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
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 12),
                      RepaintBoundary(
                        child: AnalyticsBarChart(
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
                      ),
                      const SizedBox(height: 12),
                    ],
                  ),
                  // 分类构成卡：标题 + 环形图（外置标签），仅展示主分类
                  // 结余视角不显示（与排行榜同口径）
                  InsightCardDef(
                    id: 'categoryBreakdown',
                    visible: _type != 'balance',
                    build: () => [
                      Builder(builder: (context) {
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
                                        margin: const EdgeInsets.only(right: 8),
                                        decoration: BoxDecoration(
                                          color: PiggyTokens.primary(context),
                                          borderRadius: BorderRadius.circular(
                                              PiggyDimens.radiusXs),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          l10n.analyticsCategoryComposition(
                                              typeWord),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: PiggyTextTokens.strongTitle(
                                              context),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  if (pieData.isNotEmpty && sum > 0)
                                    RepaintBoundary(
                                      // 环形图扇区触摸高亮隔离,避免排行榜重绘
                                      child: CategoryPieChart(
                                        data: pieData,
                                        sum: sum,
                                      ),
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 12),
                          ],
                        );
                      }),
                    ],
                  ),
                  // 排行榜卡：序号 + 图标 + 名称笔数 + 进度条 + 百分比金额
                  InsightCardDef(
                    id: 'categoryRank',
                    visible: _type != 'balance',
                    build: () => [
                      Builder(builder: (context) {
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 6),
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
                              // 仅主分类排行（本项目无子分类），点击直接进分类详情
                              //
                              // ponytail: 下钻的分类明细页仍按**记账时间**过滤
                              // （CategoryRankRow → CategoryDetailPage 只吃
                              // start/end），故统计时间口径选了自定义字段时，明细
                              // 页的条数可能与这里的「n 笔」对不上。要收敛得给
                              // CategoryDetailPage 也加时间口径（它会连带改明细
                              // 列表的筛选语义），先记账不动。
                              for (var i = 0; i < catData.length; i++)
                                CategoryRankRow(
                                  categoryId: catData[i].id,
                                  category: catData[i].category,
                                  name: catData[i].name,
                                  value: catData[i].total,
                                  percent:
                                      sum == 0 ? 0 : catData[i].total / sum,
                                  color: _pieColorAt(context, i),
                                  start: start,
                                  end: end,
                                  scope: _scope,
                                  selMonth: selMonth,
                                  rank: i + 1,
                                  count: catData[i].count,
                                  // 周/自定义由页面传入范围文案（自定义区间
                                  // 在 row 侧无法还原，其余档位 row 自算）
                                  periodLabel: switch (_scope) {
                                    AnalyticsScope.week =>
                                      weekRangeText(weekRangeFor(_selWeek)),
                                    AnalyticsScope.custom => _customRangeText(),
                                    AnalyticsScope.month ||
                                    AnalyticsScope.quarter ||
                                    AnalyticsScope.year ||
                                    AnalyticsScope.all =>
                                      null,
                                  },
                                ),
                            ],
                          ),
                        );
                      }),
                    ],
                  ),
                  // 自定义字段汇总卡：结余视角与空数据自隐藏
                  // （prd/analytics_custom_field_card，数据自取不走位次表）
                  InsightCardDef(
                    id: 'customFieldSummary',
                    // 卡片内部自隐藏（balance/聚合空）；谓词恒真不重复判定
                    visible: true,
                    build: () => [
                      CustomFieldStatsCard(
                        start: start,
                        end: end,
                        type: _type,
                        amountMetric: amountMetric,
                        timeMetric: timeMetric,
                        filter: _filter,
                      ),
                    ],
                  ),
                ];

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
                    // top 让出头部覆盖层：内容可从头部下方滚过
                    padding: EdgeInsets.fromLTRB(16, headerInset + 8, 16, 16),
                    children: [
                      // 注册表驱动渲染：可见卡片的「卡片 + 后置间距」片段
                      // 依序展开，树形与收编前逐节点一致；底部留白非卡片保持原样
                      for (final card in cards)
                        if (card.visible) ...card.build(),
                      // 底部留白，避免被悬浮 Tab 栏遮挡
                      SizedBox(
                          height: 56 +
                              12 +
                              MediaQuery.of(context).viewPadding.bottom +
                              16),
                    ],
                  ),
                );
              },
            ),
          ),
          // 头部层：标题/口径条/筛选栏 + 口径说明 + 外币横幅，盖在内容之上。
          // 高度实测（_headerKey）：说明行与横幅都是条件渲染，高度随口径变。
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: KeyedSubtree(
              key: _headerKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  PiggyHeader(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          child: Row(
                            children: [
                              Icon(Icons.bar_chart_outlined,
                                  color: PiggyTokens.textPrimary(context)),
                              const SizedBox(width: 8),
                              Text(
                                AppLocalizations.of(context).tabInsights,
                                style: PiggyTextTokens.title(context),
                              ),
                              // 统计口径条：金额口径（记账金额 / 原始金额）+ 统计时间口径
                              // （记账时间 / 日期型自定义字段）装进**同一个轨道**，与下方
                              // 周/月/季度… 的滑块分段控件同源（同轨道底 / 同圆角 / 同主色
                              // 胶囊表示「非默认口径」）。2026-10-16 用户反馈：两枚自带
                              // 描边的独立小胶囊与下方控件像两个体系、太突兀。
                              //
                              // 2026-10-16 二次修订（用户：「选完对应的文字后大小会变，
                              // 而且好丑」）：这里**去掉 Spacer、去掉整条等比缩放**——
                              // - 原来标题与口径条之间夹一个 `Spacer`，它与口径条各分一半
                              //   剩余宽度，360dp 窄屏只留给口径条 89.5dp（而内容要 187dp）；
                              // - 原来靠 `FittedBox(BoxFit.scaleDown)` 兜底，于是文案一换
                              //   缩放比例就换（「记账金额」0.48 / 「水费」0.67），字号在
                              //   6dp / 8.7dp 之间跳，既跳且糊。
                              // 现在口径条独占剩余宽度、封顶 [kMetricBarMaxWidth]，两段由
                              // `Expanded` 等分、超长文案走省略号：**切口径时整条尺寸不变**，
                              // 只有文字与胶囊底色变化。无日期型字段时时间那段不参与 flex
                              // （见 TimeMetricChip），金额段独占同一个槽位，仍不超上限。
                              const SizedBox(width: 12),
                              Flexible(
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                        maxWidth: kMetricBarMaxWidth),
                                    child: PiggySegmentTrack(
                                      height: kMetricBarHeight,
                                      child: Row(
                                        mainAxisSize: MainAxisSize.max,
                                        children: const [
                                          AmountMetricChip(
                                              style: MetricChipStyle.segment),
                                          TimeMetricChip(
                                              style: MetricChipStyle.segment),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 4),
                              // F2 自定义区间报表入口（任意起止 + 环比/同比 + 标签维度）
                              Tooltip(
                                message: AppLocalizations.of(context)
                                    .rangeReportTitle,
                                child: IconButton(
                                  icon: Icon(Icons.date_range_outlined,
                                      color: PiggyTokens.textPrimary(context)),
                                  onPressed: () {
                                    Navigator.of(context).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const RangeReportPage()),
                                    );
                                  },
                                ),
                              ),
                              // 分享按钮（自定义区间无海报模板，隐藏入口，Q5）
                              if (_scope != AnalyticsScope.custom)
                                IconButton(
                                  icon: Icon(Icons.share,
                                      color: PiggyTokens.textPrimary(context)),
                                  tooltip: AppLocalizations.of(context)
                                      .sharePosterShare,
                                  onPressed: () async {
                                    final ledgerId =
                                        ref.read(currentLedgerIdProvider);
                                    if (ledgerId == 0) {
                                      showToast(
                                          context,
                                          AppLocalizations.of(context)
                                              .sharePosterNoLedger);
                                      return;
                                    }

                                    // 显示加载弹窗：项目统一阻塞进度弹窗
                                    final block = showBlockingProgressDialog(
                                      context,
                                      title: AppLocalizations.of(context)
                                          .mineShareGenerating,
                                    );

                                    try {
                                      if (context.mounted) {
                                        await block.close(); // 关闭加载对话框
                                        if (!context.mounted) return;

                                        // 使用动态预览对话框（支持隐藏收入）
                                        // 注意：周报回退到该周所在月的月报海报（现状语义）
                                        // 季度→年报回退（Q5）；自定义区间无海报模板，
                                        // 分享入口已隐藏（Q5），null 仅作防御性兜底。
                                        final poster = switch (_scope) {
                                          AnalyticsScope.week => (
                                              type: 'month',
                                              year: _selWeek.year,
                                              month: _selWeek.month,
                                            ),
                                          AnalyticsScope.month => (
                                              type: 'month',
                                              year: selMonth.year,
                                              month: selMonth.month,
                                            ),
                                          AnalyticsScope.quarter => (
                                              type: 'year',
                                              year: selMonth.year,
                                              month: null,
                                            ),
                                          AnalyticsScope.year => (
                                              type: 'year',
                                              year: selMonth.year,
                                              month: null,
                                            ),
                                          AnalyticsScope.custom => null,
                                          AnalyticsScope.all => (
                                              type: 'ledger',
                                              year: null,
                                              month: null,
                                            ),
                                        };
                                        if (poster == null) return;
                                        await SharePosterService
                                            .showDynamicPosterPreview(
                                          context,
                                          ref,
                                          type: poster.type,
                                          ledgerId: ledgerId,
                                          year: poster.year,
                                          month: poster.month,
                                        );
                                      }
                                    } catch (e) {
                                      if (context.mounted) {
                                        await block.close(); // 关闭加载对话框
                                        if (!context.mounted) return;
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
                          child: WaitSlidingSegmentedControl<AnalyticsScope>(
                            selected: _scope,
                            height: 38,
                            fontSize: PiggyTextTokens.fs14,
                            segments: [
                              WaitSlidingSegment(
                                value: AnalyticsScope.week,
                                label:
                                    AppLocalizations.of(context).analyticsWeek,
                              ),
                              WaitSlidingSegment(
                                value: AnalyticsScope.month,
                                label:
                                    AppLocalizations.of(context).analyticsMonth,
                              ),
                              WaitSlidingSegment(
                                value: AnalyticsScope.quarter,
                                label: AppLocalizations.of(context)
                                    .analyticsQuarter,
                              ),
                              WaitSlidingSegment(
                                value: AnalyticsScope.year,
                                label:
                                    AppLocalizations.of(context).analyticsYear,
                              ),
                              WaitSlidingSegment(
                                value: AnalyticsScope.custom,
                                label: AppLocalizations.of(context)
                                    .analyticsCustom,
                              ),
                              WaitSlidingSegment(
                                value: AnalyticsScope.all,
                                label:
                                    AppLocalizations.of(context).analyticsAll,
                              ),
                            ],
                            onValueChanged: (value) => setState(() {
                              _scope = value;
                              if (value == AnalyticsScope.quarter) {
                                // 切到季档：锚点吸附到所在季度首月标签月
                                // （月/季/年共享 selectedMonthProvider，D5）
                                final sel = ref.read(selectedMonthProvider);
                                ref.read(selectedMonthProvider.notifier).state =
                                    DateTime(sel.year,
                                        ((sel.month - 1) ~/ 3) * 3 + 1, 1);
                              }
                            }),
                          ),
                        ),
                        // 周期导航行：‹ 范围文案 › 居左，支出/收入/结余三段胶囊居右
                        Padding(
                          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
                          child: Row(
                            children: [
                              if (_scope != AnalyticsScope.all)
                                _periodNavArrow(context, Icons.chevron_left,
                                    _onChartSwipeRight),
                              Expanded(
                                child: InkWell(
                                  onTap: _scope != AnalyticsScope.all
                                      ? _showPeriodPicker
                                      : null,
                                  child: Center(
                                    child: Text(
                                      _navPeriodLabel(context, selMonth),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      textAlign: TextAlign.center,
                                      style:
                                          // 周视角文案如 "08.03～08.09",两侧圆形箭头 +
                                          // 右侧胶囊挤压可用宽度;字号 16 在窄屏上会截断,
                                          // 微降到 15 给周范围留足显示空间。
                                          PiggyTextTokens.strongTitle(context),
                                    ),
                                  ),
                                ),
                              ),
                              if (_scope != AnalyticsScope.all)
                                _periodNavArrow(context, Icons.chevron_right,
                                    _onChartSwipeLeft),
                              const SizedBox(width: 8),
                              // 支出/收入/结余：与顶部周/月/年/全部同款滑块胶囊（紧凑高度）
                              SizedBox(
                                width: 168,
                                child: WaitSlidingSegmentedControl<String>(
                                  selected: _type,
                                  height: 32,
                                  fontSize: PiggyTextTokens.fs13,
                                  segments: [
                                    WaitSlidingSegment(
                                      value: 'expense',
                                      label: AppLocalizations.of(context)
                                          .homeExpense,
                                    ),
                                    WaitSlidingSegment(
                                      value: 'income',
                                      label: AppLocalizations.of(context)
                                          .homeIncome,
                                    ),
                                    WaitSlidingSegment(
                                      value: 'balance',
                                      label: AppLocalizations.of(context)
                                          .homeBalance,
                                    ),
                                  ],
                                  onValueChanged: (v) =>
                                      setState(() => _type = v),
                                ),
                              ),
                            ],
                          ),
                        ),
                        _buildFilterBar(
                          AppLocalizations.of(context),
                          ref.watch(primaryColorProvider),
                        ),
                      ],
                    ),
                  ),
                  // 非默认金额口径的说明行（默认口径下零高，不占版面）
                  const AmountMetricNote(),
                  // 非默认统计时间口径的说明行（默认口径下零高，不占版面）
                  const TimeMetricNote(),
                  // v30 L11:检测到未折算外币交易 → 补折算横幅(用户确认后按当前汇率重算)
                  _buildRecalcForeignBanner(context),
                  // v30 折算脚注(01 §五):账本含外币交易时说明统计口径
                  _buildConvertedFootnote(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// 顶部类型下拉已移除（改为导航行三段胶囊，与周/月/年/全部同款滑块）

// 自定义选择器：月份（年+月）
// 旧的自定义年月选择器已移除，统一使用 showWheelDatePicker。

/// 排行榜第 i 名的颜色：与环形图扇区调色板一致（前 8 名），其余归入「其他」灰
Color _pieColorAt(BuildContext context, int i) => i < 8
    ? PiggyChartTokens.seriesColors[i]
    : PiggyTokens.textTertiary(context);

/// 查询结果的「形状」标签：支出/收入共用一套 list 位次（6 位），可在途互相
/// 顶替显示；结余是另一套（9 位），换向它只能转圈等新查询。给数据打上这个
/// 标签，未来就能判断手上这份数据能不能给当前口径用——这是把
/// `key: ValueKey(_type)`（切口径销毁元素→整页转圈）换成数据自带标签的前提。
String _shapeOf(String type) => type == 'balance' ? 'balance' : 'inOut';

// 从序列数据中计算总和：day/month/year 三种 record 形状逐项累加 total，
// 未知形状返回 0（形状分派保留——series 保持 dynamic 是本批边界，见
// prd/analytics_card_registry/design.md §一.2）。原为 State 方法
// _getSumFromSeries，收编为顶层纯函数以便脱离页面单测。
double sumOfSeries(dynamic seriesData) {
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

/// 分类聚合行：`aggregateTopLevelCategories` 返回的 record 形状别名
/// （此前在 build/load 两侧重复展开 7 层 record 字面量）。
typedef CatAgg = ({
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
      })> subCategories,
});

/// 洞察页查询结果数据包（批次②：替代 `List<dynamic>` 位次表）。
///
/// 两口径的同名字段语义不同（series：分类主序列 vs 结余序列；笔数：单维 vs
/// 收支合计），sealed 穷尽匹配把「跨形状误读」从运行时静默错值变成编译错误。
/// `series`/`chartSeries` 保持 dynamic（day/month/year 三种 record 形状）：
/// 形状强类型化波及图表全家桶的 `is` 分派，超出本批「收编位次」边界。
sealed class InsightsData {
  const InsightsData({
    required this.shape,
    required this.series,
    required this.chartSeries,
    required this.cats,
    required this.curTotals,
    required this.prevTotals,
  });

  /// 形状标签（'inOut' | 'balance'）：在途复用闸门用，语义见 [_shapeOf]。
  final String shape;

  /// 主序列：收支口径 = 分类维度总额序列；结余口径 = 结余序列。
  final dynamic series;

  /// 图表 6 周期序列（原 `list[list.length - 1]` 隐式约定，命名后消失）。
  final dynamic chartSeries;

  /// 一级分类聚合（含子分类明细），排行榜/分类构成用。
  final List<CatAgg> cats;

  /// (本期收入, 本期支出)；结余口径同构（由收支序列求和而来）。
  final (double, double) curTotals;

  /// (上期收入, 上期支出)。
  final (double, double) prevTotals;
}

/// 支出/收入口径数据包（原 6 位位次表）。
final class InOutInsightsData extends InsightsData {
  const InOutInsightsData({
    required super.shape,
    required super.series,
    required super.chartSeries,
    required super.cats,
    required super.curTotals,
    required super.prevTotals,
    required this.txCount,
  });

  /// 本期该口径交易笔数。
  final int txCount;
}

/// 结余口径数据包（原 9 位位次表）。
final class BalanceInsightsData extends InsightsData {
  const BalanceInsightsData({
    required super.shape,
    required super.series,
    required super.chartSeries,
    required super.cats,
    required super.curTotals,
    required super.prevTotals,
    required this.expenseCount,
    required this.incomeCount,
    required this.incomeSeries,
    required this.expenseSeries,
  });

  final int expenseCount;
  final int incomeCount;

  /// 收入/支出序列（求和即 [curTotals]，保留原始序列供形状分派复用）。
  final dynamic incomeSeries;
  final dynamic expenseSeries;
}

// 加载分类数据并聚合
// 返回命名数据包（原 6 位位次表，见 InsightsData）
Future<InOutInsightsData> _loadCategoryData(
  dynamic repo,
  int ledgerId,
  String type,
  DateTime start,
  DateTime end,
  Future<dynamic> seriesFuture,
  DateTime? prevStart,
  DateTime? prevEnd,
  Future<dynamic> chartSeriesFuture,
  AnalyticsAmountMetric amountMetric,
  AnalyticsTimeMetric timeMetric,
  AnalyticsTransactionFilter filter,
) async {
  final prevTotalsFuture = (prevStart != null && prevEnd != null)
      ? repo.totalsInRange(
          ledgerId: ledgerId,
          start: prevStart,
          end: prevEnd,
          amountMetric: amountMetric,
          timeMetric: timeMetric,
          filter: filter)
      : Future.value((0.0, 0.0));
  final results = await Future.wait<dynamic>([
    repo.totalsByCategoryWithHierarchy(
        ledgerId: ledgerId,
        type: type,
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
    seriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId,
        type: type,
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
    // 本期收支（结余用）
    repo.totalsInRange(
        ledgerId: ledgerId,
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
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
  final aggregated = await aggregateTopLevelCategories(hierarchyData, repo);

  // 命名数据包（原 6 位位次表：0=catData 1=series 2=txCount
  // 3=(本期收入,本期支出) 4=(上期收入,上期支出) 5=chartSeries）
  return InOutInsightsData(
    shape: _shapeOf(type),
    series: results[1],
    chartSeries: results[5],
    cats: aggregated,
    curTotals: results[3] as (double, double),
    prevTotals: results[4] as (double, double),
    txCount: results[2] as int,
  );
}

// 加载结余数据并聚合
// 返回命名数据包（原 9 位位次表，见 BalanceInsightsData）
Future<BalanceInsightsData> _loadBalanceData(
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
  AnalyticsAmountMetric amountMetric,
  AnalyticsTimeMetric timeMetric,
  AnalyticsTransactionFilter filter,
) async {
  final prevTotalsFuture = (prevStart != null && prevEnd != null)
      ? repo.totalsInRange(
          ledgerId: ledgerId,
          start: prevStart,
          end: prevEnd,
          amountMetric: amountMetric,
          timeMetric: timeMetric,
          filter: filter)
      : Future.value((0.0, 0.0));
  final results = await Future.wait<dynamic>([
    repo.totalsByCategoryWithHierarchy(
        ledgerId: ledgerId,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
    seriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId,
        type: 'expense',
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
    incomeSeriesFuture,
    expenseSeriesFuture,
    repo.countByTypeInRange(
        ledgerId: ledgerId,
        type: 'income',
        start: start,
        end: end,
        amountMetric: amountMetric,
        timeMetric: timeMetric,
        filter: filter),
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
  final aggregated = await aggregateTopLevelCategories(hierarchyData, repo);

  // 结余序列在加载侧算：两份按日/按月序列各最长 6 桶×31 天，合并是纯函数，
  // 放在 build 里等于每次 setState 重排一遍（F2 顺手收的旧账）。
  // 命名数据包（原 9 位位次表：0=catData 1=series 2=expenseCount
  // 3=incomeSeries 4=expenseSeries 5=incomeCount 6=(上期收入,上期支出)
  // 7=结余序列 8=chartSeries）
  return BalanceInsightsData(
    shape: _shapeOf('balance'),
    series: _calculateBalanceSeries(results[3], results[4]),
    chartSeries: results[7],
    cats: aggregated,
    curTotals: (
      sumOfSeries(results[3]),
      sumOfSeries(results[4]),
    ),
    prevTotals: results[6] as (double, double),
    expenseCount: results[2] as int,
    incomeCount: results[5] as int,
    incomeSeries: results[3],
    expenseSeries: results[4],
  );
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
    final allMonths = {...incomeMap.keys, ...expenseMap.keys}.toList()..sort();
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
