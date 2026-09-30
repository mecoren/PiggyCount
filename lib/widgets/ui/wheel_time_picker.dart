import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import 'haptics.dart';

/// 时间选择抽屉（左小时 / 右分钟）。
///
/// 外壳与云同步配置抽屉同口径：悬浮卡片（四周留距 + 四角圆角）+
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
  // 弹层底透明，卡片本身由 WheelTimePicker 内的 Material 绘制四角圆角
  return showModalBottomSheet<TimeOfDay>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    useSafeArea: true,
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
    return Padding(
      // 键盘避让：本抽屉无输入框，保留以防未来插入输入型内容
      padding:
          EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      // SafeArea 在外统一吃掉底部安全区，内部不再叠 paddingOf.bottom，避免双重留白
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PiggyDimens.p16,
            0,
            PiggyDimens.p16,
            PiggyDimens.p16,
          ),
          // CupertinoPicker / IconButton 均为 Material 系组件，transparent
          // 路由底不提供 Material 祖先，必须显式包一层，否则直接红屏
          child: Material(
            color: PiggyTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 标题栏：X 在左 + 标题居中 + 钩子在右（与云同步配置抽屉一致）
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                  child: Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.close),
                        tooltip: l10n.commonCancel,
                        onPressed: () => Navigator.pop(context),
                      ),
                      Expanded(
                        child: Text(
                          l10n.commonSelectTime,
                          textAlign: TextAlign.center,
                          style: PiggyTextTokens.strongTitle(context)
                              .copyWith(fontSize: 17),
                        ),
                      ),
                      IconButton(
                        icon: Icon(Icons.check,
                            color: PiggyTokens.primary(context)),
                        tooltip: l10n.commonOk,
                        onPressed: () => Navigator.pop(
                            context, TimeOfDay(hour: hour, minute: minute)),
                      ),
                    ],
                  ),
                ),
                // 与 WheelDatePicker 同一口径：itemExtent 52、可见 3 项、字号 18
                SizedBox(
                  height: 156,
                  child: Row(
                    children: [
                      Expanded(
                        child: _hourColumn(context),
                      ),
                      Text(
                        ':',
                        style: TextStyle(
                          fontSize: 18,
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
                const SizedBox(height: 12),
              ],
            ),
          ),
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
              style:
                  TextStyle(fontSize: 18, color: PiggyTokens.textPrimary(context)),
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
              style:
                  TextStyle(fontSize: 18, color: PiggyTokens.textPrimary(context)),
            ),
          ),
      ],
    );
  }
}