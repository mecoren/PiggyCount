import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';
import '../../providers/budget_providers.dart';
import '../budget/budget_page.dart';
import '../../providers.dart';
import '../settings/personalize_page.dart' show headerStyleProvider;
import '../../data/db.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/biz/piggy_icon.dart';
import '../../styles/tokens.dart';
import '../transaction/search_page.dart';
import '../ai/ai_chat_page.dart';
import '../../l10n/app_localizations.dart';
import '../../services/system/logger_service.dart';
import '../../utils/format_utils.dart';
import '../../utils/month_range.dart';
import '../../services/export/share_poster_service.dart';
import '../report/annual_report_page.dart';
import '../calendar/calendar_page.dart';
import '../../widgets/biz/ledger_picker_sheet.dart';
import '../../widgets/biz/home_budget_summary.dart';
import '../../widgets/biz/home_month_summary_card.dart';
import 'ledgers_page_new.dart';

// 优化版首页 - 使用FlutterListView实现精准定位和丝滑跳转
class HomePage extends ConsumerStatefulWidget {
  const HomePage({super.key});

  @override
  ConsumerState<HomePage> createState() => _HomePageState();
}

class _HomePageState extends ConsumerState<HomePage> {
  late FlutterListViewController _listController;
  bool _isJumping = false;
  final GlobalKey<TransactionListState> _transactionListKey =
      GlobalKey<TransactionListState>();

  // 可见性管理
  final Set<String> _visibleHeaders = {}; // 当前可见的日期头部
  Timer? _debounceTimer;

  // StreamBuilder 刷新计数器
  int _streamBuilderKey = 0;

  // home build 缓存的 tx stream。repo.transactionsWithCategoryAll 内部每次调
  // 都 new StreamController,如果在 build 里直接调,只要 home 因任何 setState
  // (例如 _showBudgetSetupHint / _showLastMonthReminder 异步加载完成)重 build,
  // StreamBuilder 看到 stream 引用变了就重新订阅 → snapshot.data 短暂为 null
  // → fallback 到 cachedFullData(只有前 20 条预加载)→ 等 Drift 推数据 → 切回
  // 完整列表,视觉上"整页闪一下"。这里把 stream 缓存到 State,只在 ledgerId
  // 变化时重建,无关 setState 重 build 时复用同一 stream 引用。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>>? _txStream;
  int? _txStreamLedgerId;

  /// M2-a 窗口：当前 `_txStream` 对应的 limit；变了就换引用重订阅。
  int? _txStreamLimit;

  /// 上一次流已到达的窗口行（M2-a）。
  ///
  /// `limit` 增长时会换一个新 stream，StreamBuilder 短暂 `hasData == false`；
  /// 没有它就会回落到「启动预载的 20 条」→ 视觉上整页闪一下（这正是
  /// `_txStream` 缓存当初要解决的那个问题，分页把同一个坑又挖了回来）。
  List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })>? _lastStreamRows;

  // 月初提醒状态
  bool _showLastMonthReminder = false;
  static const String _reminderDismissedKey = 'last_month_reminder_dismissed';

  // 年度账单提醒状态（12月15日 - 次年1月31日显示）
  bool _showAnnualReportReminder = false;
  static const String _annualReportDismissedKey =
      'annual_report_reminder_dismissed';

  // 预算设置引导卡片状态
  bool _showBudgetSetupHint = false;
  static const String _budgetSetupHintDismissedKey =
      'budget_setup_hint_dismissed';

  @override
  void initState() {
    super.initState();
    _listController = FlutterListViewController();
    _checkLastMonthReminder();
    _checkAnnualReportReminder();
    _checkBudgetSetupHint();
  }

  // 检查是否应该显示上月报告提醒
  Future<void> _checkLastMonthReminder() async {
    final now = DateTime.now();
    // 只在每月前7天显示提醒
    if (now.day > 7) return;

    final prefs = await SharedPreferences.getInstance();
    final dismissedMonth = prefs.getString(_reminderDismissedKey);
    final currentMonth = '${now.year}-${now.month}';

    // 如果当月已经关闭过，不再显示
    if (dismissedMonth == currentMonth) return;

    if (mounted) {
      setState(() {
        _showLastMonthReminder = true;
      });
    }
  }

  // 关闭上月报告提醒
  Future<void> _dismissLastMonthReminder() async {
    final now = DateTime.now();
    final currentMonth = '${now.year}-${now.month}';
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_reminderDismissedKey, currentMonth);

    if (mounted) {
      setState(() {
        _showLastMonthReminder = false;
      });
    }
  }

  // 检查是否应该显示年度账单提醒（12月15日 - 次年1月31日）
  Future<void> _checkAnnualReportReminder() async {
    final now = DateTime.now();

    // 判断是否在提醒时间范围内：12月15日 - 次年1月31日
    final isInRange = (now.month == 12 && now.day >= 15) || now.month == 1;
    if (!isInRange) return;

    // 确定要展示的年度（12月展示当年，1月展示上一年）
    final reportYear = now.month == 1 ? now.year - 1 : now.year;

    final prefs = await SharedPreferences.getInstance();
    final dismissedYear = prefs.getInt(_annualReportDismissedKey);

    // 如果这个年度已经关闭过，不再显示
    if (dismissedYear == reportYear) return;

    if (mounted) {
      setState(() {
        _showAnnualReportReminder = true;
      });
    }
  }

  // 关闭年度账单提醒
  Future<void> _dismissAnnualReportReminder() async {
    final now = DateTime.now();
    final reportYear = now.month == 1 ? now.year - 1 : now.year;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_annualReportDismissedKey, reportYear);

    if (mounted) {
      setState(() {
        _showAnnualReportReminder = false;
      });
    }
  }

  // 检查是否应该显示预算设置引导卡片
  Future<void> _checkBudgetSetupHint() async {
    final prefs = await SharedPreferences.getInstance();
    final dismissed = prefs.getBool(_budgetSetupHintDismissedKey) ?? false;
    if (dismissed) return;

    if (mounted) {
      setState(() {
        _showBudgetSetupHint = true;
      });
    }
  }

  // 关闭预算设置引导卡片（永不再显示）
  Future<void> _dismissBudgetSetupHint() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_budgetSetupHintDismissedKey, true);

    if (mounted) {
      setState(() {
        _showBudgetSetupHint = false;
      });
    }
  }

  @override
  void dispose() {
    _debounceTimer?.cancel();
    _listController.dispose();
    super.dispose();
  }

  // 精准月份跳转 - 使用TransactionList组件的跳转功能
  Future<void> _jumpToTargetMonth(DateTime targetMonth) async {
    if (_isJumping) return; // 防止重复跳转

    setState(() {
      _isJumping = true;
    });

    try {
      // 使用TransactionList组件的跳转方法
      final transactionListState = _transactionListKey.currentState;
      if (transactionListState != null && mounted) {
        final startDay = ref.read(currentMonthStartDayProvider);
        var found = transactionListState.jumpToMonth(
          targetMonth,
          startDay: startDay,
        );

        // M2-a 降级：目标月还没加载进窗口 → 逐页把窗口撑大再试。
        // 有界 best-effort：上限 20 页，且只在「上一页确实是满页（可能还有更多）」
        // 时继续，避免目标月根本不存在时无限拉。窗口行由 StreamBuilder 异步
        // 送达，故每轮让出一帧再试。
        final ledgerIdNow = ref.read(currentLedgerIdProvider);
        var grown = 0;
        while (!found &&
            grown < 20 &&
            mounted &&
            (_lastStreamRows?.length ?? 0) >=
                ref.read(homeTxWindowLimitProvider(ledgerIdNow))) {
          growHomeTxWindow(ref, ledgerIdNow);
          grown++;
          await Future<void>.delayed(const Duration(milliseconds: 80));
          if (!mounted) break;
          found = transactionListState.jumpToMonth(
            targetMonth,
            startDay: startDay,
          );
        }
      }
    } finally {
      if (mounted) {
        setState(() {
          _isJumping = false;
        });
      }
    }
  }

  // 日期头部可见性变化
  void _onHeaderVisibilityChanged(String dateKey, bool isVisible) {
    if (_isJumping) return;

    if (isVisible) {
      _visibleHeaders.add(dateKey);
    } else {
      _visibleHeaders.remove(dateKey);
    }

    // 防抖更新月份
    _debounceTimer?.cancel();
    _debounceTimer = Timer(const Duration(milliseconds: 100), () {
      _updateCurrentMonth();
    });
  }

  // 更新当前月份
  void _updateCurrentMonth() {
    if (_isJumping || !mounted || _visibleHeaders.isEmpty) return;

    try {
      // 获取最顶部的可见日期头部（按日期排序，取最新的）
      final sortedDates = _visibleHeaders.toList()
        ..sort((a, b) => b.compareTo(a));
      final topDateKey = sortedDates.first;

      final dateParts = topDateKey.split('-');
      if (dateParts.length != 3) return;

      final year = int.parse(dateParts[0]);
      final month = int.parse(dateParts[1]);
      final day = int.parse(dateParts[2]);
      // 交易日期 → 它所属周期的标签月(startDay>1 时月初几天属上个标签月)
      final sd = ref.read(currentMonthStartDayProvider);
      final detectedMonth = labelForDate(DateTime(year, month, day), sd);

      // 更新选中月份
      final currentSelected = ref.read(selectedMonthProvider);
      if (currentSelected.year != detectedMonth.year ||
          currentSelected.month != detectedMonth.month) {
        ref.read(selectedMonthProvider.notifier).state = detectedMonth;
      }
    } catch (e) {
      // 忽略错误，继续正常运行
    }
  }

  // FlutterListView不需要手动计算偏移量，直接使用jumpToIndex即可！

  // 月份选择由 HomeMonthSummaryCard 内部处理（chevron / 弹 WheelDatePicker），
  // 选择后通过 onMonthSelected 回调触发列表跳转。

  // 构建月初提醒卡片
  Widget _buildLastMonthReminderCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final sd = ref.watch(currentMonthStartDayProvider);
    final currentLabel = labelForDate(now, sd);
    final lastMonth = DateTime(currentLabel.year, currentLabel.month - 1, 1);
    final monthFormat = DateFormat.MMMM(l10n.localeName);
    final primaryColor = ref.watch(primaryColorProvider);

    return Container(
      margin: PiggyDimens.cardMargin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        color: PiggyTokens.surface(context),
        // 主题色细边框（与统计页图表卡片统一），用边框替代阴影
        border: Border.all(color: primaryColor, width: 1.5),
        boxShadow: null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: PiggyDimens.reminderCardPadding,
              child: Row(
                children: [
                  // 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_awesome,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: monthFormat.format(lastMonth),
                                  style: TextStyle(
                                    fontWeight: FontWeight.w600,
                                    color: primaryColor,
                                  ),
                                ),
                                TextSpan(
                                  text: ' ${l10n.homeLastMonthReportSubtitle}',
                                  style: TextStyle(
                                    color: PiggyTokens.textSecondary(context),
                                  ),
                                ),
                              ],
                            ),
                            style: PiggyTextTokens.body(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 查看按钮（查看后本次隐藏，下次打开app还会显示）
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      SharePosterService.showPosterCarouselPreview(
                        context,
                        year: lastMonth.year,
                        month: lastMonth.month,
                      );
                      // 只临时隐藏，不保存到 prefs
                      setState(() {
                        _showLastMonthReminder = false;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Text(
                        l10n.homeLastMonthReportView,
                        style: PiggyTextTokens.body(context).copyWith(
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮（关闭后当月不再显示）
                  GestureDetector(
                    onTap: _dismissLastMonthReminder,
                    behavior: HitTestBehavior.opaque,
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.close,
                        size: 18,
                        color: PiggyTokens.textDisabled(context),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 年度账单提醒卡片（样式与月初提醒一致）
  Widget _buildAnnualReportReminderCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final now = DateTime.now();
    final reportYear = now.month == 1 ? now.year - 1 : now.year;
    final primaryColor = ref.watch(primaryColorProvider);

    return Container(
      margin: PiggyDimens.cardMargin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        color: PiggyTokens.surface(context),
        // 主题色细边框（与统计页图表卡片统一），用边框替代阴影
        border: Border.all(color: primaryColor, width: 1.5),
        boxShadow: null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: PiggyDimens.reminderCardPadding,
              child: Row(
                children: [
                  // 图标 + 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.auto_graph_rounded,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.homeAnnualReportReminder(reportYear),
                            style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 查看按钮
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) =>
                              AnnualReportPage(initialYear: reportYear),
                        ),
                      );
                      // 临时隐藏
                      setState(() {
                        _showAnnualReportReminder = false;
                      });
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 4, vertical: 6),
                      child: Text(
                        l10n.homeAnnualReportView,
                        style: PiggyTextTokens.body(context).copyWith(
                          fontWeight: FontWeight.w600,
                          color: primaryColor,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮
                  // 无障碍基线：图标按钮补语义（button 角色 +「关闭」标签），
                  // TalkBack/VoiceOver 用户可感知并操作；
                  // 外面再包 Tooltip 提供视觉长按提示，excludeFromSemantics
                  // 避免读屏重复播报（否则会念「关闭，关闭」）。
                  Tooltip(
                    message: l10n.commonClose,
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: l10n.commonClose,
                      child: GestureDetector(
                        onTap: _dismissAnnualReportReminder,
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.all(6),
                          child: Icon(
                            Icons.close,
                            size: 18,
                            color: PiggyTokens.textDisabled(context),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // 预算设置引导卡片（无预算时显示，样式与月初提醒一致）
  Widget _buildBudgetSetupHintCard(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);

    return Container(
      margin: PiggyDimens.cardMargin,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        color: PiggyTokens.surface(context),
        // 主题色细边框（与统计页图表卡片统一），用边框替代阴影
        border: Border.all(color: primaryColor, width: 1.5),
        boxShadow: null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        child: Stack(
          children: [
            // 左侧装饰条
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              child: Container(
                width: 4,
                color: primaryColor,
              ),
            ),
            // 主体内容
            Padding(
              padding: PiggyDimens.reminderCardPadding,
              child: Row(
                children: [
                  // 图标 + 文案
                  Expanded(
                    child: Row(
                      children: [
                        Icon(
                          Icons.pie_chart_outline_rounded,
                          color: primaryColor,
                          size: 18,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l10n.budgetSetupHint,
                            style: PiggyTextTokens.body(context).copyWith(
                              color: PiggyTokens.textSecondary(context),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 去设置按钮
                  GestureDetector(
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const BudgetPage()),
                      );
                    },
                    child: Text(
                      l10n.budgetSetupAction,
                      style: PiggyTextTokens.body(context).copyWith(
                        fontWeight: FontWeight.w600,
                        color: primaryColor,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  // 关闭按钮（无障碍基线：button 角色 +「关闭」标签；
                  // Tooltip 提供视觉长按提示，excludeFromSemantics 防重复播报）
                  Tooltip(
                    message: l10n.commonClose,
                    excludeFromSemantics: true,
                    child: Semantics(
                      button: true,
                      label: l10n.commonClose,
                      child: GestureDetector(
                        onTap: _dismissBudgetSetupHint,
                        behavior: HitTestBehavior.opaque,
                        child: Icon(
                          Icons.close,
                          size: 18,
                          color: PiggyTokens.textDisabled(context),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    // 预加载数据（含标签、附件、账户，仅前 N 条）
    final cachedFullData = ref.watch(cachedTransactionsProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);

    // 检测账本切换 → 用 listen,避免在 build 中直接写 state 触发
    // "Tried to modify a provider while the widget tree was building"
    ref.listen<int>(currentLedgerIdProvider, (previous, next) {
      if (previous != null && previous != next) {
        _streamBuilderKey++;
        // 清空缓存,避免旧账本 cache 在切换后被当作 fallback 显示。
        ref.read(cachedTransactionsProvider.notifier).state = null;
        // M2-a：窗口行同样不能跨账本复用（否则新账本会先显示旧账本的行）。
        _lastStreamRows = null;
        _txStreamLimit = null;
        logger.info('HomePage',
            '账本切换: $previous → $next, 刷新StreamBuilder (key=$_streamBuilderKey)');
      }
    });

    // 监听滚动到顶部的信号
    ref.listen<int>(homeScrollToTopProvider, (previous, next) {
      if (previous != next) {
        // 滚动到列表顶部
        _transactionListKey.currentState?.jumpToTop();
      }
    });

    // 监听切换到 Stream 模式的信号
    ref.listen<int>(homeSwitchToStreamProvider, (previous, next) {
      if (previous != next) {
        _transactionListKey.currentState?.switchToStreamMode();
      }
    });

    // D 方案后:Drift JOIN 已经在 Repository 层自动响应分类 / 账户变化,tx
    // stream 会重 emit 出带新 name 的记录。不再需要在 HomePage 强制
    // _streamBuilderKey++ / invalidate accountForTxProvider 这种激进刷新 ——
    // 那会让编辑 tx 的本地 push-pull 循环触发整个 StreamBuilder 子树重建
    // ("首页全局刷新"症状)。StreamBuilder key 重建保持不动。

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context), // ⭐ 自适应背景色
      body: Column(
        children: [
          Consumer(builder: (context, ref, _) {
            ref.watch(headerStyleProvider);
            // P1-C provider 收敛：AI 开关只影响头部入口按钮，watch 收敛在
            // 头部 Consumer 内 —— 设置页切换 AI 不再整页重建（StreamBuilder
            // 子树保持不动），仅本 Consumer 重建。
            final aiEnabled =
                ref.watch(aiAssistantEnabledProvider).asData?.value ?? true;
            return PiggyHeader(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // 头部 - 左：账本选择胶囊, 中：小猪记账 logo + 标题, 右：操作按钮
                  SizedBox(
                    height: 56,
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                      children: [
                        // 左侧：账本选择（无背景，纯文字 + 下拉箭头，限定最大宽度防长账本名挤压中间标题，与屏幕左缘保持间距）
                        Padding(
                          padding: const EdgeInsets.only(left: 12),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 160),
                            child: Consumer(builder: (context, ref, _) {
                              final currentLedger =
                                  ref.watch(currentLedgerProvider);
                              return currentLedger.when(
                                // invalidate(远端改名 / 改币种)期间继续
                                // 显示旧值,避免账本名瞬间消失再出现 —
                                // 用户感知"首页全量刷新"的主要来源。
                                skipLoadingOnReload: true,
                                data: (ledger) {
                                  // ledger == null:还没有账本(welcome 未勾默认账本
                                  // / 老用户导入配置不含账本),直接显示「新建账本」
                                  // + 加号图标,点击 push LedgersPage 并自动弹创建对
                                  // 话框,省两步点击。
                                  final isEmpty = ledger == null;
                                  return GestureDetector(
                                    onTap: () {
                                      if (isEmpty) {
                                        Navigator.push(
                                          context,
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const LedgersPageNew(
                                                    autoOpenCreateDialog: true),
                                          ),
                                        );
                                      } else {
                                        showLedgerPicker(context);
                                      }
                                    },
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        if (isEmpty) ...[
                                          Icon(
                                            Icons.add,
                                            size: 16,
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodyLarge
                                                ?.color,
                                          ),
                                          const SizedBox(width: 4),
                                        ],
                                        Flexible(
                                          child: Text(
                                            isEmpty
                                                ? AppLocalizations.of(context)
                                                    .ledgersNew
                                                : translateLedgerName(
                                                    context, ledger.name),
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            softWrap: false,
                                            style: PiggyTextTokens.body(context)
                                                .copyWith(
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
                                        ),
                                        // 没账本时不显示下拉箭头(没东西可选)
                                        if (!isEmpty) ...[
                                          const SizedBox(width: 2),
                                          Icon(
                                            Icons.keyboard_arrow_down,
                                            size: 16,
                                            color: Theme.of(context)
                                                .textTheme
                                                .bodyMedium
                                                ?.color
                                                ?.withValues(alpha: 0.5),
                                          ),
                                        ],
                                      ],
                                    ),
                                  );
                                },
                                loading: () => const SizedBox.shrink(),
                                error: (_, __) => const SizedBox.shrink(),
                              );
                            }),
                          ),
                        ),
                        // 中间：小猪记账 logo + 标题（居中显示）。
                        // Flexible：小屏/长账本名时允许中间段收缩，
                        // 否则 左(≤160)+中(≈104)+右(3×48=144) 固定宽度
                        // 在窄屏上会溢出（实测 RIGHT OVERFLOWED BY 3.5px）。
                        Flexible(
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              PiggyIcon(
                                size: 28,
                              ),
                              const SizedBox(width: 4),
                              Flexible(
                                child: Text(
                                  AppLocalizations.of(context).homeAppTitle,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.copyWith(
                                        color: Theme.of(context)
                                            .textTheme
                                            .bodyLarge
                                            ?.color,
                                      ),
                                ),
                              ),
                            ],
                          ),
                        ),
                        // 右侧操作按钮
                        if (aiEnabled)
                          IconButton(
                            tooltip: AppLocalizations.of(context).aiChatTitle,
                            padding: const EdgeInsets.all(8),
                            style: IconButton.styleFrom(
                              // UI-03：视觉保持紧凑，但命中区恢复 ≥48×48
                              //（无障碍 / 单手操作，shrinkWrap 下由
                              // minimumSize 兜底热区）
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              minimumSize: const Size(48, 48),
                            ),
                            onPressed: () {
                              _transactionListKey.currentState
                                  ?.switchToStreamMode();
                              Navigator.of(context).push(
                                MaterialPageRoute(
                                  builder: (context) => const AIChatPage(),
                                ),
                              );
                            },
                            icon: Icon(
                              Icons.auto_awesome_outlined,
                              size: 20,
                              color: Theme.of(context).iconTheme.color,
                            ),
                          ),
                        IconButton(
                          tooltip: AppLocalizations.of(context).calendarTitle,
                          padding: const EdgeInsets.all(6),
                          style: IconButton.styleFrom(
                            // UI-03：同上，热区 ≥48×48
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () {
                            Navigator.push(
                              context,
                              MaterialPageRoute(
                                builder: (_) => const CalendarPage(),
                              ),
                            );
                          },
                          icon: Icon(
                            Icons.calendar_month_outlined,
                            size: 20,
                            color: Theme.of(context).iconTheme.color,
                          ),
                        ),
                        IconButton(
                          tooltip: AppLocalizations.of(context).homeSearch,
                          padding: const EdgeInsets.all(6),
                          style: IconButton.styleFrom(
                            // UI-03：同上，热区 ≥48×48
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            minimumSize: const Size(48, 48),
                          ),
                          onPressed: () {
                            _transactionListKey.currentState
                                ?.switchToStreamMode();
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (context) => const SearchPage(),
                              ),
                            );
                          },
                          icon: Icon(
                            Icons.search,
                            size: 20,
                            color: Theme.of(context).iconTheme.color,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  // 预算总结卡片（固定在顶部）
                  const HomeBudgetSummary(),
                ],
              ),
            );
          }),
          const SizedBox(height: 0),
          // 月初提醒卡片
          if (_showLastMonthReminder) _buildLastMonthReminderCard(context),
          // 年度账单提醒卡片（12月15日 - 次年1月31日）
          if (_showAnnualReportReminder)
            _buildAnnualReportReminderCard(context),
          // 预算设置引导卡片（无预算 + 未关闭过）
          Consumer(builder: (context, ref, _) {
            final overviewAsync = ref.watch(budgetOverviewProvider);
            final hasBudget = overviewAsync.when(
              data: (overview) =>
                  overview != null && overview.totalBudget != null,
              loading: () => true, // loading 时不显示引导
              error: (_, __) => true, // 出错时不显示引导
            );
            if (!hasBudget && _showBudgetSetupHint) {
              return _buildBudgetSetupHintCard(context);
            }
            return const SizedBox.shrink();
          }),
          // 月总结卡片固定在顶部，不随明细滚动
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: HomeMonthSummaryCard(
              onMonthSelected: _jumpToTargetMonth,
            ),
          ),
          Expanded(
            child: StreamBuilder<
                List<
                    ({
                      Transaction t,
                      Category? category,
                      Account? account,
                      Account? toAccount
                    })>>(
              key: ValueKey('transactions_$_streamBuilderKey'), // 使用递增key强制重建
              stream: () {
                final windowLimit =
                    ref.watch(homeTxWindowLimitProvider(ledgerId));
                // ledgerId 变了或第一次进来才重建 stream;无关 setState(预算
                // 提示卡片、月度提醒等)的 home rebuild 复用同一 stream 引用,
                // StreamBuilder 不会重新订阅,不会闪到 fallback 数据。
                if (_txStream == null ||
                    _txStreamLedgerId != ledgerId ||
                    _txStreamLimit != windowLimit) {
                  // M2-a：窗口化 —— 不再整本账本进内存，只取最新 `windowLimit`
                  // 行；limit 只增（滚动追加），已显示的行不会被挤出窗口，
                  // 因此日分组器的删除检测语义不变。
                  _txStream = repo.watchTransactionWindow(
                      ledgerId: ledgerId, limit: windowLimit);
                  _txStreamLedgerId = ledgerId;
                  _txStreamLimit = windowLimit;
                }
                return _txStream;
              }(),
              builder: (context, snapshot) {
                // Stream 数据到来前，使用预加载数据；到来后使用 Stream 数据。
                // 用 snapshot.hasData 区分"流已加载(可能为空)"与"流尚未返回",
                // 避免空列表被当作未加载而回退到启动缓存(删除最后一笔后旧记录残留)。
                final windowLimit =
                    ref.watch(homeTxWindowLimitProvider(ledgerId));
                final streamData = snapshot.data;
                final hasStreamData = snapshot.hasData;
                if (hasStreamData) _lastStreamRows = streamData;

                // 如果 Stream 没数据，先回退**上一帧的窗口行**（limit 增长换流时
                // 的短暂空窗），再退回启动预载；避免整页闪一下。
                final transactions = hasStreamData
                    ? (streamData ?? const [])
                    : (_lastStreamRows ??
                        cachedFullData
                            ?.map((item) => (
                                  t: item.t,
                                  category: item.category,
                                  account: item.account,
                                  toAccount: item.toAccount,
                                ))
                            .toList() ??
                        []);

                // M2-a 日合计：窗口最旧一天可能只加载了部分行，表头数字必须用
                // SQL 口径（family key = 最旧一天，同日增删不重复取数）。
                final oldestLocal = transactions.isEmpty
                    ? null
                    : transactions.last.t.happenedAt.toLocal();
                final dayTotals = oldestLocal == null
                    ? null
                    : ref
                        .watch(homeDayTotalsProvider((
                          ledgerId: ledgerId,
                          oldestDay: DateTime(oldestLocal.year,
                              oldestLocal.month, oldestLocal.day),
                        )))
                        .value;

                // Stream 首帧已到 → 启动预载缓存(20 条含标签/附件详情的
                // 拷贝)完成使命,post-frame 清空避免与 Stream 全量数据双份
                // 常驻。列表详情在 Stream 模式下由 TransactionList 自行
                // 按需批量加载,不依赖这份缓存。
                if (hasStreamData && cachedFullData != null) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    ref.read(cachedTransactionsProvider.notifier).state = null;
                  });
                }

                return TransactionList(
                  key: _transactionListKey,
                  transactions: transactions,
                  // 传入预加载数据供详情使用（标签、附件、账户）
                  transactionsWithDetails: cachedFullData,
                  hideAmounts: ref.watch(hideAmountsProvider),
                  enableVisibilityTracking: true,
                  onDateVisibilityChanged: _onHeaderVisibilityChanged,
                  // M2-a：窗口日合计（SQL 口径）+ 触底加载下一页
                  dayTotals: dayTotals,
                  hasMore: hasStreamData &&
                      (streamData?.length ?? 0) >= windowLimit,
                  onLoadMore: () => growHomeTxWindow(ref, ledgerId),
                  controller: _listController,
                  emptyWidget: AppEmpty(
                    text: AppLocalizations.of(context).homeNoRecords,
                    subtext: AppLocalizations.of(context).homeNoRecordsSubtext,
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
