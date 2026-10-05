import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import 'haptics.dart';
import 'picker_sheet.dart';

/// 时间选择抽屉（左小时 / 右分钟）。
///
/// 外壳走 [PiggyPickerSheet]：悬浮卡片（四周留距 + 四角圆角）+
/// 顶栏图标化操作（X 取消在左、钩子确定在右，底部不放按钮行）。
class WheelTimePicker extends StatefulWidget {
  final TimeOfDay initial;

  const WheelTimePicker({
    super.key,
    required this.initial,
  });

  @override
  State<WheelTimePicker> createState() => _WheelTimePickerState();
}

Future<TimeOfDay?> showWheelTimePicker(
  BuildContext context, {
  required TimeOfDay initial,
}) {
  // 弹层底透明，卡片本身由 PiggyPickerSheet 内的 Material 绘制四角圆角
  return showPiggyPickerSheet<TimeOfDay>(
    context,
    builder: (_) => WheelTimePicker(initial: initial),
  );
}

class _WheelTimePickerState extends State<WheelTimePicker> {
  late int hour;
  late int minute;
  late FixedExtentScrollController _hourCtrl;
  late FixedExtentScrollController _minuteCtrl;

  @override
  void initState() {
    super.initState();
    hour = widget.initial.hour;
    minute = widget.initial.minute;
    _hourCtrl = FixedExtentScrollController(initialItem: hour);
    _minuteCtrl = FixedExtentScrollController(initialItem: minute);
  }

  @override
  void dispose() {
    _hourCtrl.dispose();
    _minuteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return PiggyPickerSheet(
      title: l10n.commonSelectTime,
      onConfirm: () =>
          Navigator.pop(context, TimeOfDay(hour: hour, minute: minute)),
      // 与 WheelDatePicker 同一口径：itemExtent 52、可见 3 项、字号 18
      child: SizedBox(
        height: 156,
        child: Row(
          children: [
            Expanded(
              child: _hourColumn(context),
            ),
            Text(
              ':',
              style: TextStyle(
                fontSize: PiggyTextTokens.fs18,
                fontWeight: FontWeight.w500,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
            Expanded(
              child: _minuteColumn(context),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hourColumn(BuildContext context) {
    return CupertinoPicker(
      itemExtent: 52,
      scrollController: _hourCtrl,
      onSelectedItemChanged: (index) {
        PiggyHaptics.selection();
        setState(() => hour = index);
      },
      children: [
        for (int h = 0; h < 24; h++)
          Center(
            child: Text(
              h.toString().padLeft(2, '0'),
              style: TextStyle(
                  fontSize: PiggyTextTokens.fs18, color: PiggyTokens.textPrimary(context)),
            ),
          ),
      ],
    );
  }

  Widget _minuteColumn(BuildContext context) {
    return CupertinoPicker(
      itemExtent: 52,
      scrollController: _minuteCtrl,
      onSelectedItemChanged: (index) {
        PiggyHaptics.selection();
        setState(() => minute = index);
      },
      children: [
        for (int m = 0; m < 60; m++)
          Center(
            child: Text(
              m.toString().padLeft(2, '0'),
              style: TextStyle(
                  fontSize: PiggyTextTokens.fs18, color: PiggyTokens.textPrimary(context)),
            ),
          ),
      ],
    );
  }
}
