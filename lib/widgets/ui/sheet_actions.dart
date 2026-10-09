import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'piggy_spinner.dart';

/// 底部抽屉双等宽操作按钮：左侧取消（描边）+ 右侧确认（填充）。
///
/// 口径：所有底部抽屉底部的取消/确认操作统一用本组件（对齐日期选择
/// 抽屉的参考样式），不要在各抽屉里手写右对齐小按钮或单个全宽保存键。
class PiggySheetActions extends StatelessWidget {
  /// 双按钮高度：48，保证拇指点按目标。
  static const double kHeight = 48;

  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback? onCancel;
  final VoidCallback? onConfirm;

  /// 确认进行中：确认键切转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  const PiggySheetActions({
    super.key,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
    this.confirmBusy = false,
  });

  @override
  Widget build(BuildContext context) {
    final style = ButtonStyle(
      minimumSize: WidgetStateProperty.all(const Size(0, kHeight)),
      shape: WidgetStateProperty.all(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        ),
      ),
    );
    return Row(
      children: [
        Expanded(
          child: OutlinedButton(
            onPressed: confirmBusy ? null : onCancel,
            style: style,
            child: Text(cancelLabel),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: FilledButton(
            onPressed: confirmBusy ? null : onConfirm,
            style: style,
            child: confirmBusy
                ? PiggySpinner(
                    size: 18,
                    color: PiggyTokens.textOnPrimary(context),
                  )
                : Text(confirmLabel),
          ),
        ),
      ],
    );
  }
}

