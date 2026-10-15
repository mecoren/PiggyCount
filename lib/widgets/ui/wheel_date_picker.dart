import 'package:flutter/cupertino.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import 'haptics.dart';
import 'picker_sheet.dart';
import 'wheel_key_input.dart';

enum WheelDatePickerMode { y, ym, ymd }

class WheelDatePicker extends StatefulWidget {
  final DateTime initial;
  final WheelDatePickerMode mode;
  final DateTime? minDate;
  final DateTime? maxDate;
  const WheelDatePicker({
    super.key,
    required this.initial,
    this.mode = WheelDatePickerMode.ymd,
    this.minDate,
    this.maxDate,
  });

  @override
  State<WheelDatePicker> createState() => _WheelDatePickerState();
}

Future<DateTime?> showWheelDatePicker(
  BuildContext context, {
  required DateTime initial,
  WheelDatePickerMode mode = WheelDatePickerMode.ymd,
  DateTime? minDate,
  DateTime? maxDate,
}) {
  return showPiggyPickerSheet<DateTime>(
    context,
    builder: (_) => WheelDatePicker(
      initial: initial,
      mode: mode,
      minDate: minDate,
      maxDate: maxDate,
    ),
  );
}

class _WheelDatePickerState extends State<WheelDatePicker>
    with WheelKeyInputMixin<WheelDatePicker> {
  Color _textPrimary(BuildContext context) => PiggyTokens.textPrimary(context);
  late int year;
  late int month;
  late int day;
  late FixedExtentScrollController _yearCtrl;
  FixedExtentScrollController? _monthCtrl;
  FixedExtentScrollController? _dayCtrl;

  @override
  void initState() {
    super.initState();
    final clamped = _clamp(widget.initial);
    year = clamped.year;
    month = clamped.month;
    day = clamped.day;
    // 初始化滚动控制器
    final years = [for (int y = _min.year; y <= _max.year; y++) y];
    _yearCtrl = FixedExtentScrollController(initialItem: years.indexOf(year));
    // month/day 控制器在 build 中根据当前 year/month 的有效范围惰性创建
  }

  DateTime get _min => widget.minDate ?? DateTime(2000, 1, 1);
  DateTime get _max => widget.maxDate ?? DateTime(2100, 12, 31);

  DateTime _clamp(DateTime d) {
    if (d.isBefore(_min)) return _min;
    if (d.isAfter(_max)) return _max;
    return d;
  }

  List<int> _daysInMonth(int y, int m) {
    final last = DateTime(y, m + 1, 0).day;
    return List.generate(last, (i) => i + 1);
  }

  /// 当前可选年份列表（受 `minDate` / `maxDate` 裁剪）。
  /// [build] 与键盘段规格共用这一份计算，避免「滚轮显示的范围」与「键盘 clamp
  /// 的范围」两处口径漂移。
  List<int> _years() => [for (int y = _min.year; y <= _max.year; y++) y];

  /// 指定年份下的可选月份（`minDate` / `maxDate` 只削首尾年）。
  List<int> _monthsOf(int y) {
    int start = 1, end = 12;
    if (y == _min.year) start = _min.month;
    if (y == _max.year) end = _max.month;
    return [for (int m = start; m <= end; m++) m];
  }

  /// 指定年月下的可选日期（当月实际天数 + `minDate` / `maxDate` 裁剪）。
  List<int> _daysOf(int y, int m) {
    int start = 1, end = _daysInMonth(y, m).last;
    if (y == _min.year && m == _min.month) start = _min.day;
    if (y == _max.year && m == _max.month) end = _max.day;
    return [for (int d = start; d <= end; d++) d];
  }

  @override
  List<WheelKeyColumn> buildKeyColumns() {
    final mode = widget.mode;
    return [
      WheelKeyColumn(
        width: 4,
        // 年段是 4 位整体，键入位当高位前缀（`202` → 2020），越界只 clamp 不前推。
        prefixMode: WheelKeyPrefixMode.leadingZeros,
        minOf: () => _years().first,
        maxOf: () => _years().last,
        currentOf: () => year,
        onApply: (v) => _applyYear(v, syncWheel: true),
      ),
      if (mode != WheelDatePickerMode.y)
        WheelKeyColumn(
          width: 2,
          minOf: () => _monthsOf(year).first,
          maxOf: () => _monthsOf(year).last,
          currentOf: () => month,
          onApply: (v) => _applyMonth(v, syncWheel: true),
        ),
      if (mode == WheelDatePickerMode.ymd)
        WheelKeyColumn(
          width: 2,
          minOf: () => _daysOf(year, month).first,
          maxOf: () => _daysOf(year, month).last,
          currentOf: () => day,
          onApply: (v) => _applyDay(v, syncWheel: true),
        ),
    ];
  }

  DateTime get _result {
    switch (widget.mode) {
      case WheelDatePickerMode.y:
        return _clamp(DateTime(year, 1, 1));
      case WheelDatePickerMode.ym:
        return _clamp(DateTime(year, month, 1));
      case WheelDatePickerMode.ymd:
        return _clamp(DateTime(year, month, day));
    }
  }

  @override
  void confirmFromKeyboard() => Navigator.pop(context, _result);

  /// 设值 + 边界收口 + 落位。键盘 / 触摸 / 初始化三条通路共用同一份口径。
  ///
  /// [syncWheel] 只在键盘通路为 true：触摸年轮时若把年轮自己 `jumpToItem`，会把
  /// 用户正在抛掷的动量打断（既有实现只同步「别的」列，口径保留）。
  void _applyYear(int v, {bool syncWheel = false}) {
    setState(() {
      year = v;
      final monthsNow = _monthsOf(year);
      if (month < monthsNow.first) month = monthsNow.first;
      if (month > monthsNow.last) month = monthsNow.last;
      final daysNow = _daysOf(year, month);
      if (day < daysNow.first) day = daysNow.first;
      if (day > daysNow.last) day = daysNow.last;
    });
    _syncMonthWheel();
    _syncDayWheel();
    if (syncWheel) _jumpOnFrame(_yearCtrl, _years().indexOf(year));
  }

  void _applyMonth(int v, {bool syncWheel = false}) {
    setState(() {
      month = v;
      final daysNow = _daysOf(year, month);
      if (day < daysNow.first) day = daysNow.first;
      if (day > daysNow.last) day = daysNow.last;
    });
    _syncDayWheel();
    if (syncWheel) _jumpOnFrame(_monthCtrl, _monthsOf(year).indexOf(month));
  }

  void _applyDay(int v, {bool syncWheel = false}) {
    setState(() => day = v);
    if (syncWheel) _jumpOnFrame(_dayCtrl, _daysOf(year, month).indexOf(day));
  }

  /// 落位到某列第 [index] 项（下一帧执行，等本轮 setState 重建完成）。
  void _jumpOnFrame(FixedExtentScrollController? ctrl, int index) {
    if (ctrl == null || index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.jumpToItem(index));
  }

  /// 同步「月」轮位置。`y` 形态没有月列，控制器未挂载任何滚轮，`jumpToItem`
  /// 会直接断言失败，所以按模式门控。
  void _syncMonthWheel() {
    if (widget.mode == WheelDatePickerMode.y) return;
    _jumpOnFrame(_monthCtrl, _monthsOf(year).indexOf(month));
  }

  /// 同步「日」轮位置。`y` / `ym` 形态没有日列，门控理由同 [_syncMonthWheel]。
  void _syncDayWheel() {
    if (widget.mode != WheelDatePickerMode.ymd) return;
    _jumpOnFrame(_dayCtrl, _daysOf(year, month).indexOf(day));
  }

  @override
  Widget build(BuildContext context) {
    final mode = widget.mode;

    final years = _years();
    final months = _monthsOf(year);
    final days = _daysOf(year, month);

    // 确保 month/day 控制器已创建并指向当前索引
    _monthCtrl ??=
        FixedExtentScrollController(initialItem: months.indexOf(month));
    final dayIndex = days.indexOf(day);
    _dayCtrl ??=
        FixedExtentScrollController(initialItem: dayIndex < 0 ? 0 : dayIndex);

    return PiggyPickerSheet(
      title: AppLocalizations.of(context).homeSelectDate,
      onConfirm: () => Navigator.pop(context, _result),
      child: SizedBox(
        height: 156, // 3个可见项（52*3）更舒适
        child: Row(
          children: [
            Expanded(
              child: keyColumn(
                0,
                CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _yearCtrl,
                  onSelectedItemChanged: (i) {
                    PiggyHaptics.selection();
                    _applyYear(years[i]);
                  },
                  children: [
                    for (final y in years)
                      Center(
                          child: Text('$y',
                              style: TextStyle(
                                  fontSize: PiggyTextTokens.fs18,
                                  color: _textPrimary(context)))),
                  ],
                ),
              ),
            ),
            if (mode != WheelDatePickerMode.y)
              Expanded(
                child: keyColumn(
                  1,
                  CupertinoPicker(
                    itemExtent: 52,
                    scrollController: _monthCtrl,
                    onSelectedItemChanged: (i) {
                      PiggyHaptics.selection();
                      _applyMonth(months[i]);
                    },
                    children: [
                      for (final m in months)
                        Center(
                            child: Text('$m',
                                style: TextStyle(
                                    fontSize: PiggyTextTokens.fs18,
                                    color: _textPrimary(context)))),
                    ],
                  ),
                ),
              ),
            if (mode == WheelDatePickerMode.ymd)
              Expanded(
                child: keyColumn(
                  2,
                  CupertinoPicker(
                    itemExtent: 52,
                    scrollController: _dayCtrl,
                    onSelectedItemChanged: (i) {
                      PiggyHaptics.selection();
                      _applyDay(days[i]);
                    },
                    children: [
                      for (final d in days)
                        Center(
                            child: Text('$d',
                                style: TextStyle(
                                    fontSize: PiggyTextTokens.fs18,
                                    color: _textPrimary(context)))),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// 日期时间组合选择器（两步流程）
/// 第一步选择日期，点击"下一步"后选择时间（时分秒）
Future<DateTime?> showWheelDateTimePicker(
  BuildContext context, {
  required DateTime initial,
  DateTime? maxDate,
}) async {
  // 第一步：选择日期
  final dateResult = await showPiggyPickerSheet<DateTime>(
    context,
    builder: (_) => _DateStepPicker(
      initial: initial,
      maxDate: maxDate,
    ),
  );

  if (dateResult == null || !context.mounted) return null;

  // 第二步：选择时间（时分秒）
  final timeResult =
      await showPiggyPickerSheet<({int hour, int minute, int second})>(
    context,
    builder: (_) => _TimeStepPicker(
      initialHour: initial.hour,
      initialMinute: initial.minute,
      initialSecond: initial.second,
    ),
  );

  if (timeResult == null) return null;

  // 组合日期和时间（含秒）
  return DateTime(
    dateResult.year,
    dateResult.month,
    dateResult.day,
    timeResult.hour,
    timeResult.minute,
    timeResult.second,
  );
}

/// 第一步：日期选择器（右上角为"下一步"）
class _DateStepPicker extends StatefulWidget {
  final DateTime initial;
  final DateTime? maxDate;

  const _DateStepPicker({
    required this.initial,
    this.maxDate,
  });

  @override
  State<_DateStepPicker> createState() => _DateStepPickerState();
}

class _DateStepPickerState extends State<_DateStepPicker>
    with WheelKeyInputMixin<_DateStepPicker> {
  late int year;
  late int month;
  late int day;
  late FixedExtentScrollController _yearCtrl;
  FixedExtentScrollController? _monthCtrl;
  FixedExtentScrollController? _dayCtrl;

  DateTime get _min => DateTime(2000, 1, 1);
  DateTime get _max => widget.maxDate ?? DateTime(2100, 12, 31);

  @override
  void initState() {
    super.initState();
    final clamped = _clamp(widget.initial);
    year = clamped.year;
    month = clamped.month;
    day = clamped.day;
    final years = [for (int y = _min.year; y <= _max.year; y++) y];
    _yearCtrl = FixedExtentScrollController(initialItem: years.indexOf(year));
  }

  DateTime _clamp(DateTime d) {
    if (d.isBefore(_min)) return _min;
    if (d.isAfter(_max)) return _max;
    return d;
  }

  List<int> _daysInMonth(int y, int m) {
    final last = DateTime(y, m + 1, 0).day;
    return List.generate(last, (i) => i + 1);
  }

  /// 当前可选年份列表（受 `maxDate` 裁剪）。[build] 与键盘段规格共用同一份计算，
  /// 避免两处口径漂移。
  List<int> _years() => [for (int y = _min.year; y <= _max.year; y++) y];

  List<int> _monthsOf(int y) {
    int start = 1, end = 12;
    if (y == _min.year) start = _min.month;
    if (y == _max.year) end = _max.month;
    return [for (int m = start; m <= end; m++) m];
  }

  List<int> _daysOf(int y, int m) {
    int start = 1, end = _daysInMonth(y, m).last;
    if (y == _min.year && m == _min.month) start = _min.day;
    if (y == _max.year && m == _max.month) end = _max.day;
    return [for (int d = start; d <= end; d++) d];
  }

  @override
  List<WheelKeyColumn> buildKeyColumns() => [
        WheelKeyColumn(
          width: 4,
          // 年段是 4 位整体，键入位当高位前缀（`202` → 2020），越界只 clamp 不前推。
          prefixMode: WheelKeyPrefixMode.leadingZeros,
          minOf: () => _years().first,
          maxOf: () => _years().last,
          currentOf: () => year,
          onApply: (v) => _applyYear(v, syncWheel: true),
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => _monthsOf(year).first,
          maxOf: () => _monthsOf(year).last,
          currentOf: () => month,
          onApply: (v) => _applyMonth(v, syncWheel: true),
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => _daysOf(year, month).first,
          maxOf: () => _daysOf(year, month).last,
          currentOf: () => day,
          onApply: (v) => _applyDay(v, syncWheel: true),
        ),
      ];

  DateTime get _result => _clamp(DateTime(year, month, day));

  /// 回车 = 顶栏「下一步」：定案日期并弹栈（外层 `showWheelDateTimePicker`
  /// 随后接时间步）。
  @override
  void confirmFromKeyboard() => Navigator.pop(context, _result);

  void _applyYear(int v, {bool syncWheel = false}) {
    setState(() {
      year = v;
      final monthsNow = _monthsOf(year);
      if (month < monthsNow.first) month = monthsNow.first;
      if (month > monthsNow.last) month = monthsNow.last;
      final daysNow = _daysOf(year, month);
      if (day < daysNow.first) day = daysNow.first;
      if (day > daysNow.last) day = daysNow.last;
    });
    _syncMonthWheel();
    _syncDayWheel();
    if (syncWheel) _jumpOnFrame(_yearCtrl, _years().indexOf(year));
  }

  void _applyMonth(int v, {bool syncWheel = false}) {
    setState(() {
      month = v;
      final daysNow = _daysOf(year, month);
      if (day < daysNow.first) day = daysNow.first;
      if (day > daysNow.last) day = daysNow.last;
    });
    _syncDayWheel();
    if (syncWheel) _jumpOnFrame(_monthCtrl, _monthsOf(year).indexOf(month));
  }

  void _applyDay(int v, {bool syncWheel = false}) {
    setState(() => day = v);
    if (syncWheel) _jumpOnFrame(_dayCtrl, _daysOf(year, month).indexOf(day));
  }

  void _jumpOnFrame(FixedExtentScrollController? ctrl, int index) {
    if (ctrl == null || index < 0) return;
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.jumpToItem(index));
  }

  /// 同步「月」轮 / 「日」轮位置（触摸改年 / 月时带动邻居列）。
  void _syncMonthWheel() =>
      _jumpOnFrame(_monthCtrl, _monthsOf(year).indexOf(month));

  void _syncDayWheel() =>
      _jumpOnFrame(_dayCtrl, _daysOf(year, month).indexOf(day));

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    final years = _years();
    final months = _monthsOf(year);
    final days = _daysOf(year, month);

    _monthCtrl ??=
        FixedExtentScrollController(initialItem: months.indexOf(month));
    final dayIndex = days.indexOf(day);
    _dayCtrl ??=
        FixedExtentScrollController(initialItem: dayIndex < 0 ? 0 : dayIndex);

    return PiggyPickerSheet(
      title: l10n.homeSelectDate,
      confirmLabel: l10n.commonNext,
      onConfirm: confirmFromKeyboard,
      child: SizedBox(
        height: 156,
        child: Row(
          children: [
            Expanded(
              child: keyColumn(
                0,
                CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _yearCtrl,
                  onSelectedItemChanged: (i) {
                    PiggyHaptics.selection();
                    _applyYear(years[i]);
                  },
                  children: [
                    for (final y in years)
                      Center(
                          child: Text('$y',
                              style: TextStyle(
                                  fontSize: PiggyTextTokens.fs18,
                                  color: PiggyTokens.textPrimary(context)))),
                  ],
                ),
              ),
            ),
            Expanded(
              child: keyColumn(
                1,
                CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _monthCtrl,
                  onSelectedItemChanged: (i) {
                    PiggyHaptics.selection();
                    _applyMonth(months[i]);
                  },
                  children: [
                    for (final m in months)
                      Center(
                          child: Text('$m',
                              style: TextStyle(
                                  fontSize: PiggyTextTokens.fs18,
                                  color: PiggyTokens.textPrimary(context)))),
                  ],
                ),
              ),
            ),
            Expanded(
              child: keyColumn(
                2,
                CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _dayCtrl,
                  onSelectedItemChanged: (i) {
                    PiggyHaptics.selection();
                    _applyDay(days[i]);
                  },
                  children: [
                    for (final d in days)
                      Center(
                          child: Text('$d',
                              style: TextStyle(
                                  fontSize: PiggyTextTokens.fs18,
                                  color: PiggyTokens.textPrimary(context)))),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 第二步：时间选择器（支持时分秒）
class _TimeStepPicker extends StatefulWidget {
  final int initialHour;
  final int initialMinute;
  final int initialSecond;

  const _TimeStepPicker({
    required this.initialHour,
    required this.initialMinute,
    required this.initialSecond,
  });

  @override
  State<_TimeStepPicker> createState() => _TimeStepPickerState();
}

class _TimeStepPickerState extends State<_TimeStepPicker>
    with WheelKeyInputMixin<_TimeStepPicker> {
  late int hour;
  late int minute;
  late int second;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;
  late FixedExtentScrollController _secondCtrl;

  @override
  void initState() {
    super.initState();
    hour = widget.initialHour;
    minute = widget.initialMinute;
    second = widget.initialSecond;
    _hourCtrl = FixedExtentScrollController(initialItem: hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: minute);
    _secondCtrl = FixedExtentScrollController(initialItem: second);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    _secondCtrl.dispose();
    super.dispose();
  }

  @override
  List<WheelKeyColumn> buildKeyColumns() => [
        WheelKeyColumn(
          width: 2,
          minOf: () => 0,
          maxOf: () => 23,
          currentOf: () => hour,
          onApply: (v) => _applyHour(v, syncWheel: true),
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => 0,
          maxOf: () => 59,
          currentOf: () => minute,
          onApply: (v) => _applyMinute(v, syncWheel: true),
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => 0,
          maxOf: () => 59,
          currentOf: () => second,
          onApply: (v) => _applySecond(v, syncWheel: true),
        ),
      ];

  /// 回车 = 顶栏钩子：定案时分秒并弹栈。
  @override
  void confirmFromKeyboard() =>
      Navigator.pop(context, (hour: hour, minute: minute, second: second));

  /// 设值 + 落位。[syncWheel] 只在键盘通路为 true（触摸时跳自己那列会打断抛掷动量）。
  void _applyHour(int v, {bool syncWheel = false}) {
    setState(() => hour = v);
    if (syncWheel) _jumpOnFrame(_hourCtrl, v);
  }

  void _applyMinute(int v, {bool syncWheel = false}) {
    setState(() => minute = v);
    if (syncWheel) _jumpOnFrame(_minuteCtrl, v);
  }

  void _applySecond(int v, {bool syncWheel = false}) {
    setState(() => second = v);
    if (syncWheel) _jumpOnFrame(_secondCtrl, v);
  }

  void _jumpOnFrame(FixedExtentScrollController ctrl, int index) {
    WidgetsBinding.instance.addPostFrameCallback((_) => ctrl.jumpToItem(index));
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PiggyPickerSheet(
      title: l10n.commonSelectTime,
      onConfirm: confirmFromKeyboard,
      // 与 WheelDatePicker 同一口径：itemExtent 52、可见 3 项、字号 18
      child: SizedBox(
        height: 156,
        child: Row(
          children: [
            Expanded(
              child: keyColumn(0, _timeColumn(_hourCtrl, 24, _applyHour)),
            ),
            _colon(context),
            Expanded(
              child: keyColumn(1, _timeColumn(_minuteCtrl, 60, _applyMinute)),
            ),
            _colon(context),
            Expanded(
              child: keyColumn(2, _timeColumn(_secondCtrl, 60, _applySecond)),
            ),
          ],
        ),
      ),
    );
  }

  /// 时分秒共用的滚轮列：仅列表长度与选中值不同，避免三份重复代码。
  Widget _timeColumn(FixedExtentScrollController ctrl, int count,
      ValueChanged<int> onSelected) {
    return CupertinoPicker(
      itemExtent: 52,
      scrollController: ctrl,
      onSelectedItemChanged: (index) {
        PiggyHaptics.selection();
        onSelected(index);
      },
      children: [
        for (int i = 0; i < count; i++)
          Center(
            child: Text(
              i.toString().padLeft(2, '0'),
              style: TextStyle(
                  fontSize: PiggyTextTokens.fs18,
                  color: PiggyTokens.textPrimary(context)),
            ),
          ),
      ],
    );
  }

  Widget _colon(BuildContext context) => Text(
        ':',
        style: TextStyle(
          fontSize: PiggyTextTokens.fs18,
          fontWeight: FontWeight.w500,
          color: PiggyTokens.textPrimary(context),
        ),
      );
}
