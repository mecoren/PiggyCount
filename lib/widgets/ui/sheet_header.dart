import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 底部弹层的顶栏（项目「悬浮卡片」口径）：取消 X 在左（中性色）+ 标题居中
/// （[PiggyTextTokens.strongTitle] 17）+ 右侧动作位。
///
/// 卡片 chrome（左右 / 底部留距、键盘避让、`Material`）由 [PiggySheetCard] 提供，
/// 本组件只管顶栏本身。抽成共用组件的原因：`PiggyPickerSheet`（选择器 / 动作菜单）
/// 与「金额表单优先」记账抽屉（`TransactionEditorPage._buildQuickEntrySheet`，
/// 标题 + 分段 + 内容自备）曾各写一份，再加一处就要动两处 —— 顶栏样式漂移过一次。
class PiggySheetHeader extends StatelessWidget {
  const PiggySheetHeader({
    super.key,
    required this.title,
    this.subtitle,
    this.onCancel,
    this.onConfirm,
    this.confirmLabel,
    this.confirmEnabled = true,
    this.trailingAction,
  });

  /// 顶栏居中标题。
  final String title;

  /// 标题下的副说明（小号三级色），可空。
  final String? subtitle;

  /// 关闭 / 取消回调，为空回落 `Navigator.pop`。
  final VoidCallback? onCancel;

  /// 顶栏右侧确认钩子（主色 ✓），调用方通常在其中 `Navigator.pop(context, 结果)`。
  /// 为空 = 无确认动作（点选即应用 / 点选即收起）：右侧补等宽占位，保证标题居中。
  final VoidCallback? onConfirm;

  /// 钩子的语义文案，仅用于 tooltip / 无障碍朗读，为空回落「确定」。
  final String? confirmLabel;

  /// 钩子是否可用；置 false 时钩子以禁用态呈现（如数据未就绪）。
  final bool confirmEnabled;

  /// 顶栏**右上角**的自定义图标动作（只渲染图标，`null` = 补等宽占位）。
  ///
  /// 与 [onConfirm] 互斥且 [onConfirm] 优先：右侧只留**一个**动作位，确认钩子是
  /// 主流程。槽位与左侧取消键等宽（标题因此始终居中），只放图标类动作，文案走
  /// `IconButton.tooltip` —— 塞文字按钮会把居中标题挤偏。
  ///
  /// 当前唯一在用者：记账抽屉（`TransactionEditorPage._buildQuickEntrySheet`）的
  /// 「带出上一笔」。
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: l10n.commonCancel,
            onPressed: onCancel ?? () => Navigator.pop(context),
          ),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  textAlign: TextAlign.center,
                  style: PiggyTextTokens.strongTitle(context)
                      .copyWith(fontSize: PiggyTextTokens.fs17),
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    textAlign: TextAlign.center,
                    style: PiggyTextTokens.label(context).copyWith(
                      color: PiggyTokens.textTertiary(context),
                    ),
                  ),
              ],
            ),
          ),
          if (onConfirm != null)
            IconButton(
              icon: Icon(Icons.check, color: PiggyTokens.primary(context)),
              tooltip: confirmLabel ?? l10n.commonOk,
              onPressed: confirmEnabled ? onConfirm : null,
            )
          else
            SizedBox(width: 48, child: trailingAction),
        ],
      ),
    );
  }
}
