import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 滚轮选择器统一的顶部操作栏：取消（左）｜标题（居中，16 w500）｜确认（右，主色）。
///
/// 抽成共用组件的原因：`WheelPicker` / `WheelDatePicker` / `WheelTimePicker`
/// 曾各自复制同一段结构，改样式时极易漂移（时间选择器一度变成 17px 加粗标题 +
/// 底部分割线 + 16 内边距，与另外两个不一致）。
///
/// 左侧取消固定回退（`Navigator.pop` 无返回值），右侧动作由调用方决定——
/// 日期时间选择器的第一步返回「下一步」而非「确定」。
class WheelPickerHeader extends StatelessWidget {
  const WheelPickerHeader({
    super.key,
    required this.title,
    required this.onConfirm,
    this.confirmLabel,
  });

  final String title;

  /// 右侧按钮文案，为空时回落「确定」。
  final String? confirmLabel;

  /// 右侧按钮回调，通常由调用方 `Navigator.pop(context, 结果)`。
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return SizedBox(
      height: 52,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(
                l10n.commonCancel,
                style: TextStyle(
                  fontSize: 16,
                  color: PiggyTokens.textTertiary(context),
                ),
              ),
            ),
            const Spacer(),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w500,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: onConfirm,
              child: Text(
                confirmLabel ?? l10n.commonOk,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}