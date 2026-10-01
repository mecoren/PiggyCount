import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:table_calendar/table_calendar.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart';
import '../../utils/lunar/chinese_almanac.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/biz/transaction_list_item.dart';
import '../../widgets/category_icon.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../providers.dart';
import '../../providers/calendar_providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../l10n/app_localizations.dart';
import '../transaction/transaction_editor_page.dart';

class CalendarPage extends ConsumerStatefulWidget {
  const CalendarPage({super.key});

  @override
  ConsumerState<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends ConsumerState<CalendarPage> {
  // 日历可浏览范围(移植 BeeCount #429)。下界从硬编码 2020-01-01 放宽到
  // 2000-01-01(与 WheelDatePicker 默认 minDate 对齐),导入 2020 年前账单
  // 的用户也能翻到;上界沿用「今天 + 1 年」以覆盖未来记账/周期记账。
  //
  // TableCalendar 与年月选择器必须绑同一份边界 —— focusedDay 落到界外会踩
  // table_calendar 内部 assert(table_calendar_base.dart:77)。
  static final DateTime _calFirstDay = DateTime(2000, 1, 1);

  // 取整到「日」:同一天内多次读取结果恒等,避免 TableCalendar 与选择器
  // 各自 DateTime.now() 差出微秒级不一致。
  DateTime get _calLastDay {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day)
        .add(const Duration(days: 365));
  }

  late DateTime _focusedMonth;
  DateTime? _selectedDay;

  // 月度统计缓存:切月 = autoDispose family 新实例,首帧必为 loading;
  // loading 分支用这里的历史月份统计先把网格(含金额)渲染出来,
  // 避免「整卡塌骨架再弹回」的滑月白闪。键为月初,页销毁随之丢弃。
  final Map<DateTime, Map<String, (double, double)>> _totalsCache = {};

  @override
  void initState() {
    super.initState();
    final now = DateTime.now();
    _focusedMonth = DateTime(now.year, now.month, 1);
    _selectedDay = now;

    // 同步到 Provider
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(calendarSelectedMonthProvider.notifier).state = _focusedMonth;
      ref.read(calendarSelectedDateProvider.notifier).state = _selectedDay;
    });
  }

  void _onDaySelected(DateTime selectedDay, DateTime focusedDay) {
    setState(() {
      _selectedDay = selectedDay;
    });
    ref.read(calendarSelectedDateProvider.notifier).state = selectedDay;
  }

  void _onPageChanged(DateTime focusedMonth) {
    setState(() {
      _focusedMonth = focusedMonth;
      // 切换月份时，清空选中日期
      _selectedDay = null;
    });
    ref.read(calendarSelectedMonthProvider.notifier).state = focusedMonth;
    ref.read(calendarSelectedDateProvider.notifier).state = null;
  }

  void _jumpToToday() {
    final now = DateTime.now();
    setState(() {
      _focusedMonth = DateTime(now.year, now.month, 1);
      _selectedDay = now;
    });
    ref.read(calendarSelectedMonthProvider.notifier).state = _focusedMonth;
    ref.read(calendarSelectedDateProvider.notifier).state = _selectedDay;
  }

  // 点头部「20xx年xx月 ▾」跳转指定年月(移植 BeeCount #429)。复用全 App
  // 通用的年月滚轮,与分析页同一范式。
  Future<void> _showMonthJumpPicker() async {
    // 上界故意跟随日历的 _calLastDay 而非 DateTime.now():日历本身能横滑到
    // 未来一年,若选择器卡在今天就会出现「手能滑到、选择器跳不到」的割裂。
    final picked = await showWheelDatePicker(
      context,
      initial: _focusedMonth,
      mode: WheelDatePickerMode.ym,
      minDate: _calFirstDay,
      maxDate: _calLastDay,
    );
    if (picked == null || !mounted) return;
    _jumpToMonth(picked);
  }

  void _jumpToMonth(DateTime target) {
    // 选择器已按 min/max 限制返回值,这里只是兜底,防止将来改动边界后越界崩溃。
    // 钳制同样落到月初 —— _focusedMonth 恒为月初是本页各处共同的前置假设。
    var month = DateTime(target.year, target.month, 1);
    if (month.isBefore(_calFirstDay)) {
      month = DateTime(_calFirstDay.year, _calFirstDay.month, 1);
    }
    final lastDay = _calLastDay;
    if (month.isAfter(lastDay)) {
      month = DateTime(lastDay.year, lastDay.month, 1);
    }

    setState(() {
      _focusedMonth = month;
      // 与滑动切月(_onPageChanged)保持同一语义:清空选中日,下方当日列表收起
      _selectedDay = null;
    });
    // 程序化跳转时 table_calendar 不会回调 onPageChanged,两个 provider 必须手动同步
    ref.read(calendarSelectedMonthProvider.notifier).state = month;
    ref.read(calendarSelectedDateProvider.notifier).state = null;
  }

  Future<void> _addTransactionForSelectedDate() async {
    // 优先使用当前选中日期，未选中时回退到今天。
    // 把时间锁到中午,避开 UTC 边界导致跨日的问题(交易列表按日期分组,
    // 凌晨 00:00 在某些时区可能被算作前一天)。
    final base = _selectedDay ?? DateTime.now();
    final initialDate = DateTime(base.year, base.month, base.day, 12, 0, 0);

    // 与 FAB「记一笔」同款「金额表单优先」底部抽屉：不再整屏跳分类网格，
    // 分类是要点分类位才弹出的子界面；记忆分类照常预填，日期用选中日。
    // quickMode: true 恒定（不受快捷记账开关控制）——入口形态应全局一致。
    await showTransactionFormBottomSheet(
      context,
      initialKind: 'expense',
      quickAdd: true,
      quickMode: true,
      initialDate: initialDate,
    );

    // 编辑器关闭后,主动刷新日历的统计与当日交易列表
    // (FutureProvider 不会因 Drift 写入自动重算)
    if (mounted) {
      ref.read(calendarRefreshProvider.notifier).state++;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final primaryColor = ref.watch(primaryColorProvider);

    // 监听数据刷新
    ref.watch(calendarRefreshProvider);

    // 获取当月统计数据
    final monthTotalsParams = (ledgerId: ledgerId, month: _focusedMonth);
    final dailyTotalsAsync =
        ref.watch(dailyTotalsByMonthProvider(monthTotalsParams));

    // 节假日本地缓存（DB 为空时 Service 回落 2026 预置表，冷启动 / 离线仍可标注）。
    // 加载中先给空 map —— 日历照常渲染，只是暂不带休/班徽标，避免整页闪骨架。
    final holidays = ref.watch(holidayMapProvider).valueOrNull ??
        const <String, HolidayEntry>{};

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.calendarTitle,
        showBack: true,
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 8),
            child: TextButton(
              onPressed: _jumpToToday,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
              ),
              child: Text(
                l10n.calendarToday,
                style: TextStyle(
                  color: PiggyTokens.textPrimary(context),
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            // 日历主体
            Expanded(
              child: ListView(
                padding: EdgeInsets.symmetric(
                  horizontal: 12.0.scaled(context, ref),
                  vertical: 8.0.scaled(context, ref),
                ),
                children: [
                  // 日历视图(小米口径:素卡,不带主题色描边)
                  SectionCard(
                    margin: EdgeInsets.zero,
                    child: dailyTotalsAsync.when(
                      // 记账等触发 calendarRefreshProvider 时不切到 loading,
                      // 旧统计保留,等新数据来无缝替换 — 避免日历整页 spinner 闪烁
                      skipLoadingOnReload: true,
                      // 切月 loading:网格(日期/农历/徽标/周末色)不依赖统计,
                      // 必须照常渲染 —— 换成骨架会让整卡塌空白再弹回,
                      // 正是滑月白闪的根源;只有金额行晚一两帧补上
                      data: (dailyTotals) {
                        _totalsCache[monthTotalsParams.month] = dailyTotals;
                        return _buildCalendar(
                            context, dailyTotals, holidays, primaryColor);
                      },
                      loading: () => _buildCalendar(
                        context,
                        _totalsCache[_focusedMonth] ??
                            const <String, (double, double)>{},
                        holidays,
                        primaryColor,
                      ),
                      error: (err, stack) => Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text('Error: $err'),
                        ),
                      ),
                    ),
                  ),

                  SizedBox(height: 12.0.scaled(context, ref)),

                  // 选中日期的交易列表（无日期标题和统计）
                  if (_selectedDay != null)
                    _buildDateTransactionsList(
                        context, ledgerId, _selectedDay!),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCalendar(
    BuildContext context,
    Map<String, (double, double)> dailyTotals,
    Map<String, HolidayEntry> holidays,
    Color primaryColor,
  ) {
    final locale = Localizations.localeOf(context);

    // 头部标题样式:headerStyle 与自定义 headerTitleBuilder 共用同一份,避免走样
    final titleTextStyle = PiggyTextTokens.strongTitle(context).copyWith(
      fontSize: 17,
    );

    return TableCalendar(
      locale: locale.toString(),
      firstDay: _calFirstDay,
      lastDay: _calLastDay,
      focusedDay: _focusedMonth,
      selectedDayPredicate: (day) {
        return _selectedDay != null && isSameDay(_selectedDay, day);
      },
      onDaySelected: _onDaySelected,
      onPageChanged: _onPageChanged,
      calendarFormat: CalendarFormat.month,
      startingDayOfWeek: StartingDayOfWeek.monday,
      availableGestures: AvailableGestures.horizontalSwipe,

      // 行高:单格最多 4 行内容(数字 + 农历/节气副标签 + 支出 + 收入)。
      // 小米口径:格子紧凑近方形,内容垂直居中 —— 72 已装下最坏 4 行组合
      // (18 + 10 + 11 + 11 + 内边距 5 ≈ 55),不再留半截空底
      // (骨架高度同步见 _buildCalendarSkeleton)
      rowHeight: 72,
      daysOfWeekHeight: 30,

      // Header 样式
      headerStyle: HeaderStyle(
        formatButtonVisible: false,
        titleCentered: true,
        leftChevronIcon: Icon(Icons.chevron_left, color: primaryColor),
        rightChevronIcon: Icon(Icons.chevron_right, color: primaryColor),
        titleTextStyle: titleTextStyle,
      ),

      // 日历样式
      calendarStyle: CalendarStyle(
        // 今天样式 — 圆角统一使用项目标准 PiggyDimens.radius2xl,
        // 与 tokens.dart 注释「海报、日历选中态、特殊突出元素」一致;
        // 避免与项目其他卡片圆角风格不一致。
        todayDecoration: BoxDecoration(
          color: primaryColor.withValues(alpha: 0.2),
          borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        ),
        todayTextStyle: TextStyle(
          color: primaryColor,
          fontWeight: FontWeight.bold,
        ),

        // 选中样式 — 同上,圆角统一为项目标准 radius2xl
        selectedDecoration: BoxDecoration(
          color: primaryColor,
          borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        ),
        selectedTextStyle: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),

        // 日期文字样式
        defaultTextStyle: TextStyle(
          color: PiggyTokens.textPrimary(context),
        ),
        outsideTextStyle: TextStyle(
          color: PiggyTokens.textTertiary(context).withValues(alpha: 0.3),
        ),

        // 周末样式
        weekendTextStyle: TextStyle(
          color: PiggyTokens.textPrimary(context),
        ),

        // 标记样式
        markersAlignment: Alignment.bottomCenter,
        markerDecoration: BoxDecoration(
          color: primaryColor,
          shape: BoxShape.circle,
        ),
      ),

      // 星期标题样式
      daysOfWeekStyle: DaysOfWeekStyle(
        weekdayStyle: PiggyTextTokens.label(context),
        weekendStyle: PiggyTextTokens.label(context),
      ),

      // 日期标记构建器
      calendarBuilders: CalendarBuilders(
        // 头部标题改为「20xx年xx月 ▾」可点入口(移植 BeeCount #429)。
        // 注意:headerTitleBuilder 会整体替换掉 table_calendar 内置那层
        // GestureDetector,onHeaderTapped 因此不会回调 —— 点击手势挂在这里。
        headerTitleBuilder: (context, month) {
          // SectionCard 是纯 Container,不提供 Material —— 水波纹会画到
          // Scaffold 那层 Material 上、被卡片背景挡住。补一层透明 Material。
          return Material(
            color: Colors.transparent,
            child: InkWell(
              onTap: _showMonthJumpPicker,
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    // Flexible + ellipsis:标题字号固定 17,系统「更大字体」放大后
                    // 纯 Text 会先吃满整行、把 20pt 的箭头挤出去触发 RenderFlex
                    // overflow
                    Flexible(
                      child: Text(
                        // 与内置实现同格式,四语显示与改造前完全一致
                        DateFormat.yMMMM(locale.toString()).format(month),
                        style: titleTextStyle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(
                      Icons.arrow_drop_down,
                      size: 20,
                      color: PiggyTokens.textPrimary(context),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
        // 自定义默认日期单元格
        // 「今天」在 _buildDateCell 内部自行判定 —— selectedDayPredicate 命中
        // 今天时 table_calendar 走的是 selectedBuilder 而非 todayBuilder,
        // 靠 builder 传参判定会把「今天且被选中」误算成非今天。
        defaultBuilder: (context, day, focusedDay) {
          return _buildDateCell(
              context, day, dailyTotals, holidays, primaryColor,
              isSelected: false, isOutside: false);
        },
        // 自定义今天日期单元格
        todayBuilder: (context, day, focusedDay) {
          return _buildDateCell(
              context, day, dailyTotals, holidays, primaryColor,
              isSelected: false, isOutside: false);
        },
        // 自定义选中日期单元格
        selectedBuilder: (context, day, focusedDay) {
          return _buildDateCell(
              context, day, dailyTotals, holidays, primaryColor,
              isSelected: true, isOutside: false);
        },
        // 自定义非当前月日期
        outsideBuilder: (context, day, focusedDay) {
          return _buildDateCell(
              context, day, dailyTotals, holidays, primaryColor,
              isSelected: false, isOutside: true);
        },
      ),
    );
  }

  /// 单个日期格（orbit 结构 + 小米日历风格）。
  ///
  /// 布局三层：整格内缩底色块（Stack 底层）→ 数字 / 副标签 / 金额 → 右上角
  /// 休·班徽标（`Positioned` 叠加，**不占布局高度**，也就不会挤压副标签）。
  /// 高度预算 72：数字 18 + 副标签 ~10 + 支出 ~12 + 收入 ~12 + 内边距 ~5。
  /// 内容整组垂直居中（小米口径，不留半截空底）；副标签与金额整块再套
  /// `FittedBox(scaleDown)` 兜底系统大字号，保证 AC-A8「不出现 RenderFlex 溢出」。
  Widget _buildDateCell(
    BuildContext context,
    DateTime day,
    Map<String, (double, double)> dailyTotals,
    Map<String, HolidayEntry> holidays,
    Color primaryColor, {
    required bool isSelected,
    required bool isOutside,
  }) {
    final l10n = AppLocalizations.of(context);
    final dateKey = _formatDate(day);
    final totals = dailyTotals[dateKey];
    final (income, expense) = totals ?? (0.0, 0.0);
    final hasTransaction = income > 0 || expense > 0;

    // 补位格（上/下月溢出到本月的日期）一律弱化：不染周末色、不带副标签与徽标
    final isToday = !isOutside && isSameDay(day, DateTime.now());
    final holiday = isOutside ? null : holidays[dateKey];
    final isOffDay = holiday?.isHoliday ?? false; // 法定放假（含调休假）
    final isWorkday = holiday != null && !holiday.isHoliday; // 调休补班（周末上班）
    final isWeekend =
        day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;

    final infoColor = PiggyTokens.info(context);
    final warningColor = PiggyTokens.warning(context);

    // 「休息日识别色」的判定口径：放假（含国庆落在工作日的那些天）与真正的
    // 周末都算；补班日虽然落在周六/周日但要上班，按工作日处理，不染蓝。
    final isRestDay = isOffDay || (isWeekend && !isWorkday);

    // 底色优先级（小米口径）：选中实心主色 > 今天浅主色底 > 放假日浅底 >
    // 补班压暗底 > 无底；选中块同时压过节假日识别底
    final Color? fillColor;
    if (isSelected) {
      fillColor = primaryColor;
    } else if (isToday) {
      fillColor = primaryColor.withValues(alpha: 0.12);
    } else if (isOffDay) {
      fillColor = infoColor.withValues(alpha: 0.10);
    } else if (isWorkday) {
      fillColor = warningColor.withValues(alpha: 0.07);
    } else {
      fillColor = null;
    }

    // 数字色（AC-A2/A5/A9）：补位弱化 > 选中实心块白字 > 今天主色 >
    // 休息日识别色 > 常规色
    final Color numberColor;
    if (isOutside) {
      numberColor = PiggyTokens.textTertiary(context).withValues(alpha: 0.3);
    } else if (isSelected) {
      numberColor = Colors.white;
    } else if (isToday) {
      numberColor = primaryColor;
    } else if (isRestDay) {
      numberColor = infoColor;
    } else {
      numberColor = PiggyTokens.textPrimary(context);
    }

    // 选中格是实心主色，副标签 / 金额文字一律转白（AC-A6：不得用彩色，
    // 否则在主色底上对比度不足）；今天未选中只是浅底，金额保留语义色
    final onSolidColor = Colors.white.withValues(alpha: 0.9);

    // 副标签：公历节日 > 农历节日 > 节气 > 农历日（初一显示月名）。
    // 小米口径：补位格也弱显农历（与数字同灰阶），徽标 / 金额仍不渲染
    final subLabel = ChineseAlmanac.daySubLabel(day);

    // fit: StackFit.expand 不可省：table_calendar 会把 builder 产物再套一层
    // `Stack(fit: loose, alignment: markersAlignment)`（table_calendar.dart:695），
    // 松约束下本 Stack 会缩到「内容固有尺寸」——底色块随之塌成一条内容宽、
    // 整行高的窄胶囊，徽标也被挤到数字上。expand 让本 Stack 撑满整格
    // （单元格宽来自 Table 的 tight 宽度，高来自 rowHeight），底色块与徽标
    // 才回到「整格块 + 右上角」的设计口径。
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底色层：整格内缩 1px 的圆角色块（与 orbit 的 inset 色块同口径）
        Positioned.fill(
          child: Container(
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            ),
          ),
        ),
        // 内容层
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 3, 1, 2),
          child: Column(
            // 整组内容垂直居中(小米口径):数字 + 副标签 + 金额作为一组
            // 落在格子中线,选中实心块内不再出现「字挤在顶、底下大片空」
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  color: numberColor,
                  fontSize: 18,
                  fontWeight:
                      isSelected || isToday ? FontWeight.w700 : FontWeight.w600,
                  height: 1.0,
                ),
              ),
              // 副标签 + 收支金额:整块可等比缩小,宽/高任意一边超出都被兜住。
              // 用 Flexible(loose) 而非 Expanded —— Expanded 会把数字顶回格顶,
              // 破坏居中;loose 下内容取固有高度,超出的部分仍被钳住由
              // FittedBox 缩小,溢出兜底语义不变
              if (subLabel != null || (!isOutside && hasTransaction))
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (subLabel != null)
                          Text(
                            subLabel,
                            style: TextStyle(
                              color: isSelected
                                  ? onSolidColor
                                  : isOutside
                                      ? PiggyTokens.textTertiary(context)
                                          .withValues(alpha: 0.3)
                                      : PiggyTokens.textSecondary(context),
                              fontSize: 10,
                              height: 1.0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (!isOutside && hasTransaction) ...[
                          if (expense > 0)
                            Text(
                              _formatAmount(expense, isExpense: true),
                              style: TextStyle(
                                color: isSelected
                                    ? onSolidColor
                                    : PiggyTokens.expenseColor(context, ref),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (income > 0)
                            Text(
                              _formatAmount(income, isExpense: false),
                              style: TextStyle(
                                color: isSelected
                                    ? onSolidColor
                                    : PiggyTokens.incomeColor(context, ref),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 休 / 班徽标：绝对定位叠加在右上角（AC-A4），不进 Column 布局
        if (holiday != null)
          Positioned(
            top: 1,
            right: 1,
            child: _buildHolidayBadge(
              l10n.holidayBadgeOff,
              l10n.holidayBadgeWork,
              isHoliday: isOffDay,
              color: isOffDay ? infoColor : warningColor,
            ),
          ),
      ],
    );
  }

  /// 右上角休·班圆徽标：14px 圆底、白字 9px（AC-A4）
  Widget _buildHolidayBadge(
    String offLabel,
    String workLabel, {
    required bool isHoliday,
    required Color color,
  }) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        isHoliday ? offLabel : workLabel,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }

  /// 金额缩写：>= 1万 用 w、>= 1千 用 k，支出带 `-`、收入带 `+`
  String _formatAmount(double value, {required bool isExpense}) {
    final sign = isExpense ? '-' : '+';
    if (value >= 10000) return '$sign${(value / 10000).toStringAsFixed(1)}w';
    if (value >= 1000) return '$sign${(value / 1000).toStringAsFixed(1)}k';
    return '$sign${value.toInt()}';
  }

  // 构建选中日期的交易列表（上方含"日期 + 在该日记账"紧凑头）
  Widget _buildDateTransactionsList(
      BuildContext context, int ledgerId, DateTime date) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final localeName = Localizations.localeOf(context).toString();
    final dateLabel = DateFormat.MMMMd(localeName).format(date);
    final weekdayLabel = DateFormat.E(localeName).format(date);

    final transactionsAsync = ref.watch(
      transactionsByDateProvider((ledgerId: ledgerId, date: date)),
    );

    final header = Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                Text(
                  dateLabel,
                  style: PiggyTextTokens.strongTitle(context),
                ),
                const SizedBox(width: 6),
                Text(
                  weekdayLabel,
                  style: PiggyTextTokens.label(context)
                      .copyWith(color: PiggyTokens.textTertiary(context)),
                ),
              ],
            ),
          ),
          // 主操作按钮 — 用项目标准按钮圆角 radiusLg(12),与全局主按钮风格一致;
          // 旧版 radius2xl(20) ≈ 按钮半高 = pill 胶囊形,不符合主操作按钮标准。
          Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
              onTap: _addTransactionForSelectedDate,
              child: Ink(
                decoration: BoxDecoration(
                  color: primaryColor,
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                  boxShadow: [
                    BoxShadow(
                      color: primaryColor.withValues(alpha: 0.28),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.add_rounded,
                          size: 18, color: Colors.white),
                      const SizedBox(width: 4),
                      Text(
                        l10n.calendarAddTransaction,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white,
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
    );

    final card = SectionCard(
      margin: EdgeInsets.zero,
      child: transactionsAsync.when(
        // 同上:bump 刷新触发的 reload 不切到 loading 分支,旧列表保持显示
        skipLoadingOnReload: true,
        data: (transactions) {
          if (transactions.isEmpty) {
            return Padding(
              padding: EdgeInsets.all(24.0.scaled(context, ref)),
              child: Center(
                child: Text(
                  l10n.calendarNoTransactions,
                  style: TextStyle(
                    color: PiggyTokens.textTertiary(context),
                  ),
                ),
              ),
            );
          }

          // 直接显示交易列表
          return ListView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            padding: EdgeInsets.zero,
            itemCount: transactions.length,
            itemBuilder: (context, index) {
              final item = transactions[index];
              final category = item.category;
              final isExpense = item.t.type == 'expense';
              final isTransfer = item.t.type == 'transfer';

              // 分类名称
              final categoryName = category?.name ?? l10n.commonUncategorized;

              // 备注作为副标题
              final subtitle = item.t.note ?? '';

              // 标签列表
              final tagsList = item.tags
                  .map((tag) => (id: tag.id, name: tag.name, color: tag.color))
                  .toList();

              // v47：自定义字段角标（无值/定义解析不出 → 不显示）。
              final customBadges = ref
                      .watch(customFieldValueBadgesProvider)
                      .valueOrNull?[item.t.id] ??
                  const <({String name, String display})>[];
              final customBadgeTexts = [
                for (final b in customBadges) '${b.name}: ${b.display}',
              ];

              return TransactionListItem(
                icon: getCategoryIconData(
                    category: category, categoryName: categoryName),
                category: category,
                title: isTransfer
                    ? (subtitle.isNotEmpty ? subtitle : l10n.transferTitle)
                    : (subtitle.isNotEmpty ? subtitle : categoryName),
                categoryName: isTransfer
                    ? null
                    : (subtitle.isNotEmpty ? categoryName : null),
                amount: item.t.amount,
                transactionId: item.t.id,
                currencyCode: item.t.currencyCode,
                nativeAmount: item.t.nativeAmount,
                isExpense: isExpense,
                isTransfer: isTransfer,
                happenedAt: item.t.happenedAt,
                accountName: item.account?.name,
                tags: tagsList.isNotEmpty ? tagsList : null,
                attachmentCount: item.attachments.length,
                customFieldBadges:
                    customBadgeTexts.isNotEmpty ? customBadgeTexts : null,
                onTap: () async {
                  await TransactionEditUtils.editTransaction(
                    context,
                    ref,
                    item.t,
                    item.category,
                  );
                },
              );
            },
          );
        },
        loading: () => _buildTransactionsSkeleton(context),
        error: (err, stack) => Padding(
          padding: const EdgeInsets.all(24),
          child: Center(child: Text('Error: $err')),
        ),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [header, card],
    );
  }

  // _buildMonthTransactionsList 已随 BeeCount #429 移植删除:全文件无调用方,
  // 唯一引用的 monthTransactionsProvider 也一并清理(死代码,无行为变更)。

  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }

  // 当日交易列表骨架(3 条 ListTile 风格占位)
  Widget _buildTransactionsSkeleton(BuildContext context) {
    return const DelayedSkeleton(
      placeholder: SizedBox(height: 200),
      child: PulseSkeleton(
        child: Column(
          children: [
            SkeletonListTile(),
            SkeletonListTile(),
            SkeletonListTile(),
          ],
        ),
      ),
    );
  }
}
