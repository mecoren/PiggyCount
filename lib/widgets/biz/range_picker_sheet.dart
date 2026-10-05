import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:table_calendar/table_calendar.dart';

import '../../data/db.dart' show HolidayEntry;
import '../../l10n/app_localizations.dart';
import '../../providers/holiday_providers.dart';
import '../../styles/tokens.dart';
import '../ui/ui.dart';
import 'calendar_date_cell.dart';

/// 区间选择抽屉（自定义区间报表 / 金额偏差报表共用）。
///
/// 日期格是**日历页同款**（[PiggyDateCell]：数字 + 农历/节气副标签 + 右上角
/// 休/班徽标 + 放假/补班底色），外壳是项目选择器统一口径 [PiggyPickerSheet]。
/// 原先两个报表页用的是 Material 原生 `showDateRangePicker`：既没有节假日
/// 标注，也和项目弹层视觉完全不是一套。
///
/// 交互：第一次点 = 起始日，第二次点 = 结束日（点同一天即单日区间），再点顶栏
/// ✓ 确认。选完一整段后再点任意日期 = 重新选起点。
Future<DateTimeRange?> showPiggyRangePickerSheet(
  BuildContext context, {
  required DateTime firstDate,
  required DateTime lastDate,
  required DateTime initialStart,
  required DateTime initialEnd,
}) {
  return showPiggyPickerSheet<DateTimeRange>(
    context,
    builder: (_) => _RangePickerSheet(
      firstDate: firstDate,
      lastDate: lastDate,
      initialStart: initialStart,
      initialEnd: initialEnd,
    ),
  );
}

class _RangePickerSheet extends ConsumerStatefulWidget {
  const _RangePickerSheet({
    required this.firstDate,
    required this.lastDate,
    required this.initialStart,
    required this.initialEnd,
  });

  final DateTime firstDate;
  final DateTime lastDate;

  /// 初始区间两端，都是**含末日**的闭区间（报表页内部用半开 [start, end)，
  /// 调用方自己负责 -1 天 / +1 天换算）。
  final DateTime initialStart;
  final DateTime initialEnd;

  @override
  ConsumerState<_RangePickerSheet> createState() => _RangePickerSheetState();
}

class _RangePickerSheetState extends ConsumerState<_RangePickerSheet> {
  /// 区间起点（永远有值：打开时带初始区间；点任意一天先落起点）。
  late DateTime _start;

  /// 区间终点；null = 只点了起点，顶栏 ✓ 处于禁用态。
  DateTime? _end;

  /// 当前展示的月份。**必须跟随日历**（滑月 / 点日期）回写：table_calendar 的
  /// `didUpdateWidget` 每次重建都会把内部焦点强行拉回 `focusedDay`，这里若写死
  /// 初值，用户滑到别的月点一下日期就会被弹回今天所在的月。
  late DateTime _focusedDay;

  /// 单格行高：数字 18 + 副标签 ~10 + 内边距。选择器没有金额行，比日历页矮。
  static const double _rowHeight = 48;

  @override
  void initState() {
    super.initState();
    final first = _day(widget.firstDate);
    final last = _day(widget.lastDate);
    // 初始区间钳进 [firstDate, lastDate]：调用方给的右端是「含末日」，
    // 越界值（导入脏数据 / 区间滑动过头）钳到边界而不是崩在 TableCalendar 的 assert 上
    _start = _clamp(_day(widget.initialStart), first, last);
    _end = _clamp(_day(widget.initialEnd), first, last);
    if (_end!.isBefore(_start)) _end = _start;
    _focusedDay = _end!;
  }

  static DateTime _day(DateTime d) => DateTime(d.year, d.month, d.day);

  static DateTime _clamp(DateTime d, DateTime first, DateTime last) =>
      d.isBefore(first) ? first : (d.isAfter(last) ? last : d);

  /// 点选：第一次点定起点，第二次点定终点（早于起点自动对调；同一天 = 单日区间）。
  /// 已有完整区间时再点任意一天 = 重新选起点。
  ///
  /// [focusedDay] 是 table_calendar 内部焦点（点补位格时它会挪到当月边界），
  /// 原样回写 [ _focusedDay ]，避免下面的 setState 触发 didUpdateWidget 把视图
  /// 弹回初值月。
  void _onDaySelected(DateTime day, DateTime focusedDay) {
    final d = _day(day);
    setState(() {
      _focusedDay = _day(focusedDay);
      if (_end != null) {
        _start = d;
        _end = null;
        return;
      }
      final anchor = _start;
      _start = d.isBefore(anchor) ? d : anchor;
      _end = d.isAfter(anchor) ? d : anchor;
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = PiggyTokens.primary(context);
    // 节假日本地缓存（DB 为空时 Service 回落预置表，冷启动 / 离线仍可标注）；
    // 加载中先给空 map —— 日历照常渲染，只暂不带休/班徽标，不塌骨架。
    final holidays = ref.watch(holidayMapProvider).valueOrNull ??
        const <String, HolidayEntry>{};

    final screenH = MediaQuery.sizeOf(context).height;
    // 日历需要**有界**高度（内部 PageView 用 Expanded 铺格），按「最坏月份」
    // 定：6 行 × [_rowHeight] + 星期行 30 + 月份头部约 40 ≈ 400。固定高度而非
    // 自适应，切到 5 行月份时抽屉不会自己变矮（视觉跳动）。矮屏按可用高度收。
    final calendarH = math.min(400.0, math.max(240.0, screenH - 200));

    return PiggyPickerSheet(
      title: l10n.rangePickerTitle,
      // 副标题兼「选到哪一步」的提示：只点了起点 = 提示再点一下，否则显示区间。
      subtitle: _end == null ? l10n.rangePickerHintEnd : _rangeText(),
      confirmEnabled: _end != null,
      onConfirm: () => Navigator.pop(
        context,
        DateTimeRange(start: _start, end: _end!),
      ),
      maxHeight: calendarH + 110,
      child: SizedBox(
        height: calendarH,
        child: TableCalendar<void>(
          locale: Localizations.localeOf(context).toString(),
          firstDay: widget.firstDate,
          lastDay: widget.lastDate,
          focusedDay: _focusedDay,
          onDaySelected: _onDaySelected,
          // 滑月后回写展示月（不 setState：下次重建传同值即可，重建由日历自己触发）
          onPageChanged: (day) => _focusedDay = _day(day),
          calendarFormat: CalendarFormat.month,
          startingDayOfWeek: StartingDayOfWeek.monday,
          availableGestures: AvailableGestures.horizontalSwipe,
          rowHeight: _rowHeight,
          daysOfWeekHeight: 30,
          headerStyle: HeaderStyle(
            formatButtonVisible: false,
            titleCentered: true,
            titleTextStyle:
                PiggyTextTokens.strongTitle(context).copyWith(fontSize: PiggyTextTokens.fs17),
            leftChevronIcon: Icon(Icons.chevron_left, color: primary),
            rightChevronIcon: Icon(Icons.chevron_right, color: primary),
          ),
          calendarStyle: CalendarStyle(
            cellMargin: const EdgeInsets.all(2),
            outsideDaysVisible: true,
          ),
          daysOfWeekStyle: DaysOfWeekStyle(
            weekdayStyle: PiggyTextTokens.label(context),
            weekendStyle: PiggyTextTokens.label(context),
          ),
          calendarBuilders: CalendarBuilders<void>(
            // prioritizedBuilder 盖过全部内置 builder（含 today/selected/
            // range* 与越界格），一处出图，不必逐个 builder 重复判定。
            prioritizedBuilder: (context, day, focusedDay) {
              final isOutside = day.month != focusedDay.month;
              final disabled = _outOfRange(day);
              final end = _end;
              final isEdge = isSameDay(day, _start) ||
                  (end != null && isSameDay(day, end));
              final inRange = !isEdge &&
                  end != null &&
                  _dayIndex(day) > _dayIndex(_start) &&
                  _dayIndex(day) < _dayIndex(end);
              return PiggyDateCell(
                day: day,
                primaryColor: primary,
                holiday: isOutside || disabled ? null : holidays[_dateKey(day)],
                isSelected: isEdge,
                isInRange: inRange,
                isToday:
                    !isOutside && !disabled && isSameDay(day, DateTime.now()),
                isOutside: isOutside,
                isDisabled: disabled,
              );
            },
          ),
        ),
      ),
    );
  }

  /// 区间文案与报表页的区间卡同格式（yyyy.MM.dd），避免卡片与抽屉两种写法。
  String _rangeText() {
    final f = DateFormat('yyyy.MM.dd');
    return '${f.format(_start)} ~ ${f.format(_end!)}';
  }

  /// 是否越界（早于 firstDate / 晚于 lastDate）。
  ///
  /// 不能直接 `day.isBefore(firstDate)`：table_calendar 内部的日格是
  /// `DateTime.utc(...)`，拿它跟本地零点的边界比会差一个时区偏移，把边界当天
  /// 误判成越界。统一走 [_dayIndex] 的「同一天 UTC 零点」再比。
  bool _outOfRange(DateTime day) {
    final d = _dayIndex(day);
    return d < _dayIndex(widget.firstDate) || d > _dayIndex(widget.lastDate);
  }

  /// 同一天 UTC 零点的时间戳：只跟 y/m/d 有关，跨时区可比。
  static int _dayIndex(DateTime d) =>
      DateTime.utc(d.year, d.month, d.day).millisecondsSinceEpoch;

  static String _dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
