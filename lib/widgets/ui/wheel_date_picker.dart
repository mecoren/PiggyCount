import 'package:flutter/cupertino.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import 'haptics.dart';
import 'picker_sheet.dart';

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

class _WheelDatePickerState extends State<WheelDatePicker> {
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

  @override
  Widget build(BuildContext context) {
    final min = _min;
    final max = _max;

    final years = [for (int y = min.year; y <= max.year; y++) y];
    int startMonth = 1, endMonth = 12;
    if (year == min.year) startMonth = min.month;
    if (year == max.year) endMonth = max.month;
    final months = [for (int m = startMonth; m <= endMonth; m++) m];

    int startDay = 1, endDay = _daysInMonth(year, month).last;
    if (year == min.year && month == min.month) startDay = min.day;
    if (year == max.year && month == max.month) endDay = max.day;
    final days = [for (int d = startDay; d <= endDay; d++) d];
    final mode = widget.mode;

    // 确保 month/day 控制器已创建并指向当前索引
    _monthCtrl ??=
        FixedExtentScrollController(initialItem: months.indexOf(month));
    final dayIndex = days.indexOf(day);
    _dayCtrl ??=
        FixedExtentScrollController(initialItem: dayIndex < 0 ? 0 : dayIndex);

    return PiggyPickerSheet(
      title: AppLocalizations.of(context).homeSelectDate,
      onConfirm: () {
        DateTime result;
        switch (mode) {
          case WheelDatePickerMode.y:
            result = _clamp(DateTime(year, 1, 1));
            break;
          case WheelDatePickerMode.ym:
            result = _clamp(DateTime(year, month, 1));
            break;
          case WheelDatePickerMode.ymd:
            result = _clamp(DateTime(year, month, day));
            break;
        }
        Navigator.pop(context, result);
      },
      child: SizedBox(
        height: 156, // 3个可见项（52*3）更舒适
        child: Row(
          children: [
            Expanded(
              child: CupertinoPicker(
                itemExtent: 52,
                scrollController: _yearCtrl,
                onSelectedItemChanged: (i) => setState(() {
                  PiggyHaptics.selection();
                  year = years[i];
                  // 调整月份与日期以符合边界
                  int sm = 1, em = 12;
                  if (year == min.year) sm = min.month;
                  if (year == max.year) em = max.month;
                  if (month < sm) month = sm;
                  if (month > em) month = em;
                  final dim = _daysInMonth(year, month).last;
                  int sd = 1, ed = dim;
                  if (year == min.year && month == min.month) sd = min.day;
                  if (year == max.year && month == max.month) ed = max.day;
                  if (day < sd) day = sd;
                  if (day > ed) day = ed;
                  // 同步月份/日期滚动位置
                  final monthsNow = [for (int m = sm; m <= em; m++) m];
                  final mi = monthsNow.indexOf(month);
                  if (_monthCtrl == null) {
                    _monthCtrl = FixedExtentScrollController(initialItem: mi);
                  } else {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _monthCtrl!.jumpToItem(mi);
                    });
                  }
                  final daysNow = [for (int d = sd; d <= ed; d++) d];
                  final di = daysNow.indexOf(day);
                  if (_dayCtrl == null) {
                    _dayCtrl = FixedExtentScrollController(
                        initialItem: di < 0 ? 0 : di);
                  } else {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _dayCtrl!.jumpToItem(di < 0 ? 0 : di);
                    });
                  }
                }),
                children: [
                  for (final y in years)
                    Center(
                        child: Text('$y',
                            style: TextStyle(
                                fontSize: 18, color: _textPrimary(context)))),
                ],
              ),
            ),
            if (mode != WheelDatePickerMode.y)
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _monthCtrl,
                  onSelectedItemChanged: (i) => setState(() {
                    PiggyHaptics.selection();
                    month = months[i];
                    // 调整日期以符合边界
                    final dim = _daysInMonth(year, month).last;
                    int sd = 1, ed = dim;
                    if (year == min.year && month == min.month) {
                      sd = min.day;
                    }
                    if (year == max.year && month == max.month) {
                      ed = max.day;
                    }
                    if (day < sd) day = sd;
                    if (day > ed) day = ed;
                    // 同步日期滚动位置
                    final daysNow = [for (int d = sd; d <= ed; d++) d];
                    final di = daysNow.indexOf(day);
                    if (_dayCtrl == null) {
                      _dayCtrl = FixedExtentScrollController(
                          initialItem: di < 0 ? 0 : di);
                    } else {
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        _dayCtrl!.jumpToItem(di < 0 ? 0 : di);
                      });
                    }
                  }),
                  children: [
                    for (final m in months)
                      Center(
                          child: Text('$m',
                              style: TextStyle(
                                  fontSize: 18, color: _textPrimary(context)))),
                  ],
                ),
              ),
            if (mode == WheelDatePickerMode.ymd)
              Expanded(
                child: CupertinoPicker(
                  itemExtent: 52,
                  scrollController: _dayCtrl,
                  onSelectedItemChanged: (i) => setState(() {
                    PiggyHaptics.selection();
                    day = days[i];
                  }),
                  children: [
                    for (final d in days)
                      Center(
                          child: Text('$d',
                              style: TextStyle(
                                  fontSize: 18, color: _textPrimary(context)))),
                  ],
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

class _DateStepPickerState extends State<_DateStepPicker> {
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

  @override
  Widget build(BuildContext context) {
    final min = _min;
    final max = _max;
    final l10n = AppLocalizations.of(context);

    final years = [for (int y = min.year; y <= max.year; y++) y];
    int startMonth = 1, endMonth = 12;
    if (year == min.year) startMonth = min.month;
    if (year == max.year) endMonth = max.month;
    final months = [for (int m = startMonth; m <= endMonth; m++) m];

    int startDay = 1, endDay = _daysInMonth(year, month).last;
    if (year == min.year && month == min.month) startDay = min.day;
    if (year == max.year && month == max.month) endDay = max.day;
    final days = [for (int d = startDay; d <= endDay; d++) d];

    _monthCtrl ??=
        FixedExtentScrollController(initialItem: months.indexOf(month));
    final dayIndex = days.indexOf(day);
    _dayCtrl ??=
        FixedExtentScrollController(initialItem: dayIndex < 0 ? 0 : dayIndex);

    return PiggyPickerSheet(
      title: l10n.homeSelectDate,
      confirmLabel: l10n.commonNext,
      onConfirm: () {
        final result = _clamp(DateTime(year, month, day));
        Navigator.pop(context, result);
      },
      child: SizedBox(
        height: 156,
        child: Row(
          children: [
            Expanded(
              child: CupertinoPicker(
                itemExtent: 52,
                scrollController: _yearCtrl,
                onSelectedItemChanged: (i) => setState(() {
                  PiggyHaptics.selection();
                  year = years[i];
                  int sm = 1, em = 12;
                  if (year == min.year) sm = min.month;
                  if (year == max.year) em = max.month;
                  if (month < sm) month = sm;
                  if (month > em) month = em;
                  final dim = _daysInMonth(year, month).last;
                  int sd = 1, ed = dim;
                  if (year == min.year && month == min.month) sd = min.day;
                  if (year == max.year && month == max.month) ed = max.day;
                  if (day < sd) day = sd;
                  if (day > ed) day = ed;
                  final monthsNow = [for (int m = sm; m <= em; m++) m];
                  final mi = monthsNow.indexOf(month);
                  if (_monthCtrl == null) {
                    _monthCtrl = FixedExtentScrollController(initialItem: mi);
                  } else {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _monthCtrl!.jumpToItem(mi);
                    });
                  }
                  final daysNow = [for (int d = sd; d <= ed; d++) d];
                  final di = daysNow.indexOf(day);
                  if (_dayCtrl == null) {
                    _dayCtrl = FixedExtentScrollController(
                        initialItem: di < 0 ? 0 : di);
                  } else {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _dayCtrl!.jumpToItem(di < 0 ? 0 : di);
                    });
                  }
                }),
                children: [
                  for (final y in years)
                    Center(
                        child: Text('$y',
                            style: TextStyle(
                                fontSize: 18,
                                color: PiggyTokens.textPrimary(context)))),
                ],
              ),
            ),
            Expanded(
              child: CupertinoPicker(
                itemExtent: 52,
                scrollController: _monthCtrl,
                onSelectedItemChanged: (i) => setState(() {
                  PiggyHaptics.selection();
                  month = months[i];
                  final dim = _daysInMonth(year, month).last;
                  int sd = 1, ed = dim;
                  if (year == min.year && month == min.month) sd = min.day;
                  if (year == max.year && month == max.month) ed = max.day;
                  if (day < sd) day = sd;
                  if (day > ed) day = ed;
                  final daysNow = [for (int d = sd; d <= ed; d++) d];
                  final di = daysNow.indexOf(day);
                  if (_dayCtrl == null) {
                    _dayCtrl = FixedExtentScrollController(
                        initialItem: di < 0 ? 0 : di);
                  } else {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      _dayCtrl!.jumpToItem(di < 0 ? 0 : di);
                    });
                  }
                }),
                children: [
                  for (final m in months)
                    Center(
                        child: Text('$m',
                            style: TextStyle(
                                fontSize: 18,
                                color: PiggyTokens.textPrimary(context)))),
                ],
              ),
            ),
            Expanded(
              child: CupertinoPicker(
                itemExtent: 52,
                scrollController: _dayCtrl,
                onSelectedItemChanged: (i) => setState(() {
                  PiggyHaptics.selection();
                  day = days[i];
                }),
                children: [
                  for (final d in days)
                    Center(
                        child: Text('$d',
                            style: TextStyle(
                                fontSize: 18,
                                color: PiggyTokens.textPrimary(context)))),
                ],
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

class _TimeStepPickerState extends State<_TimeStepPicker> {
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
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PiggyPickerSheet(
      title: l10n.commonSelectTime,
      onConfirm: () =>
          Navigator.pop(context, (hour: hour, minute: minute, second: second)),
      // 与 WheelDatePicker 同一口径：itemExtent 52、可见 3 项、字号 18
      child: SizedBox(
        height: 156,
        child: Row(
          children: [
            Expanded(
              child: _timeColumn(_hourCtrl, 24, (i) => hour = i),
            ),
            _colon(context),
            Expanded(
              child: _timeColumn(_minuteCtrl, 60, (i) => minute = i),
            ),
            _colon(context),
            Expanded(
              child: _timeColumn(_secondCtrl, 60, (i) => second = i),
            ),
          ],
        ),
      ),
    );
  }

  /// 时分秒共用的滚轮列：仅列表长度与选中值不同，避免三份重复代码。
  Widget _timeColumn(FixedExtentScrollController ctrl, int count,
      ValueChanged<int> onChanged) {
    return CupertinoPicker(
      itemExtent: 52,
      scrollController: ctrl,
      onSelectedItemChanged: (index) {
        PiggyHaptics.selection();
        setState(() => onChanged(index));
      },
      children: [
        for (int i = 0; i < count; i++)
          Center(
            child: Text(
              i.toString().padLeft(2, '0'),
              style: TextStyle(
                  fontSize: 18, color: PiggyTokens.textPrimary(context)),
            ),
          ),
      ],
    );
  }

  Widget _colon(BuildContext context) => Text(
        ':',
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w500,
          color: PiggyTokens.textPrimary(context),
        ),
      );
}
