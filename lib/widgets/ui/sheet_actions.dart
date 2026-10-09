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

/// 编辑态表单抽屉底部的「删除」按钮：全宽、error 色描边、与 [PiggySheetActions]
/// 同高（48）。
///
/// 位置口径：**固定在卡片底部**、排在「取消｜保存」之上，不随字段区滚动 ——
/// 长表单（周期账单有十几个字段）也必须一眼看得到删除入口，不必滚到底。
///
/// 一般不用手写本组件：[PiggyFormSheet] 的 `deleteLabel` / `onDelete` 会在正确
/// 位置渲染它。手写会漏掉「不滚动」这一条（此前四个编辑抽屉都把它塞在字段区
/// 末尾，长表单里删除入口被推到屏幕外）。
class PiggySheetDeleteButton extends StatelessWidget {
  final String label;
  final VoidCallback? onDelete;

  /// 删除进行中：转圈并禁用（防连点）。
  final bool busy;

  const PiggySheetDeleteButton({
    super.key,
    required this.label,
    required this.onDelete,
    this.busy = false,
  });

  @override
  Widget build(BuildContext context) {
    final error = PiggyTokens.error(context);
    return SizedBox(
      width: double.infinity,
      height: PiggySheetActions.kHeight,
      child: OutlinedButton(
        onPressed: busy ? null : onDelete,
        style: OutlinedButton.styleFrom(
          foregroundColor: error,
          // 边框与前景同源（不写死 Colors.red：不跟随暗黑与主题错误色）。
          side: BorderSide(color: error, width: 1.5),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          ),
        ),
        child: busy
            ? PiggySpinner(size: 18, color: error)
            : Text(
                label,
                style: const TextStyle(
                  fontSize: PiggyTextTokens.fs16,
                  fontWeight: FontWeight.w600,
                ),
              ),
      ),
    );
  }
}
