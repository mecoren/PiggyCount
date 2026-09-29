import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../styles/tokens.dart';
import '../../../widgets/ui/haptics.dart';

/// 年份范围选择结果（起止年，含两端）。
typedef HolidayYearRange = ({int startYear, int endYear});

/// 「按年份范围获取」的年份范围抽屉（prd/calendar_holiday 2026-09-29 修订）。
///
/// 结构对齐 [WheelDatePicker] 的双滚轮口径（ym 模式同款：头部 取消/标题/确定，
/// 下方两个等宽 CupertinoPicker），起始 / 结束两轮联动钳制 start ≤ end。
Future<HolidayYearRange?> showHolidayYearRangePicker(
  BuildContext context, {
  required int minYear,
  required int maxYear,
}) {
  return showModalBottomSheet<HolidayYearRange>(
    context: context,
    backgroundColor: PiggyTokens.surfaceElevated(context),
    shape: const RoundedRectangleBorder(
      borderRadius:
          BorderRadius.vertical(top: Radius.circular(PiggyDimens.radiusXl)),
    ),
    isScrollControlled: true,
    builder: (_) => _YearRangePicker(minYear: minYear, maxYear: maxYear),
  );
}

class _YearRangePicker extends StatefulWidget {
  const _YearRangePicker({required this.minYear, required this.maxYear});

  final int minYear;
  final int maxYear;

  @override
  State<_YearRangePicker> createState() => _YearRangePickerState();
}

class _YearRangePickerState extends State<_YearRangePicker> {
  late int _start;
  late int _end;
  late final FixedExtentScrollController _startCtrl;
  late final FixedExtentScrollController _endCtrl;

  List<int> get _years =>
      [for (int y = widget.minYear; y <= widget.maxYear; y++) y];

  @override
  void initState() {
    super.initState();
    // 默认范围 = 预置兜底覆盖的起点 ~ 明年，正对「补齐全部已知年份」的高频意图
    _start = widget.minYear;
    _end = widget.maxYear;
    _startCtrl =
        FixedExtentScrollController(initialItem: _years.indexOf(_start));
    _endCtrl = FixedExtentScrollController(initialItem: _years.indexOf(_end));
  }

  @override
  void dispose() {
    _startCtrl.dispose();
    _endCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              children: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: Text(l10n.commonCancel,
                      // M3 titleMedium = 16/w500,与 WheelDatePicker 头部同观感,
                      // 且不新增硬编码字号(font ratchet 门禁)
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: PiggyTokens.textTertiary(context))),
                ),
                const Spacer(),
                Text(l10n.holidayYearRangeTitle,
                    style: Theme.of(context)
                        .textTheme
                        .titleMedium
                        ?.copyWith(color: PiggyTokens.textPrimary(context))),
                const Spacer(),
                TextButton(
                  onPressed: () => Navigator.pop(
                      context, (startYear: _start, endYear: _end)),
                  child: Text(l10n.commonOk,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          color: Theme.of(context).colorScheme.primary)),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 156 + 28,
            child: Row(
              children: [
                _buildWheel(
                  context,
                  label: l10n.holidayYearRangeStart,
                  controller: _startCtrl,
                  selected: _start,
                  onChanged: (y) => setState(() {
                    _start = y;
                    // 起始越过结束 → 结束跟着推过去，恒有 start ≤ end
                    if (_end < _start) {
                      _end = _start;
                      _jumpToEnd();
                    }
                  }),
                ),
                _buildWheel(
                  context,
                  label: l10n.holidayYearRangeEnd,
                  controller: _endCtrl,
                  selected: _end,
                  onChanged: (y) => setState(() {
                    _end = y;
                    if (_start > _end) {
                      _start = _end;
                      _jumpToStart();
                    }
                  }),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _jumpToStart() {
    final i = _years.indexOf(_start);
    if (i >= 0) _startCtrl.jumpToItem(i);
  }

  void _jumpToEnd() {
    final i = _years.indexOf(_end);
    if (i >= 0) _endCtrl.jumpToItem(i);
  }

  Widget _buildWheel(
    BuildContext context, {
    required String label,
    required FixedExtentScrollController controller,
    required int selected,
    required ValueChanged<int> onChanged,
  }) {
    final years = _years;
    return Expanded(
      child: Column(
        children: [
          SizedBox(
            height: 28,
            child: Text(label, style: PiggyTextTokens.label(context)),
          ),
          Expanded(
            child: CupertinoPicker(
              itemExtent: 52,
              scrollController: controller,
              onSelectedItemChanged: (i) {
                PiggyHaptics.selection();
                onChanged(years[i]);
              },
              children: [
                for (final y in years)
                  Center(
                    child: Text('$y',
                        style: TextStyle(
                            fontSize: 18,
                            fontWeight: y == selected
                                ? FontWeight.w600
                                : FontWeight.normal,
                            color: PiggyTokens.textPrimary(context))),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
