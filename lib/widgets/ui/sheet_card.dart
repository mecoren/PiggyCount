import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 底部弹层的**悬浮卡片外壳**：transparent 弹层底之上的那一层 chrome。
///
/// 结构（与 `PiggyPickerSheet` / 表单抽屉同款，见 AGENTS.md「表单抽屉一律用
/// 悬浮卡片外壳」）：键盘避让 → `SafeArea(top: false)` 吃掉底部安全区 →
/// 左右留距 `p16` → 显式 `Material(surfaceElevated / radiusXl / Clip.antiAlias)`。
///
/// 为什么必须显式包 `Material`：transparent 弹层底不提供 Material 祖先，
/// `TextField` / `ListTile` / `CupertinoPicker` 缺了会直接红屏。
///
/// 三种弹层外壳的分工（按内容自带的标题 / 按钮选，别再各写一遍 chrome）：
/// - [PiggySheetCard]：只给卡片，内容完全自备 —— 记账金额面板这类
///   「无标题、无确认按钮、靠内容自身收尾」的面板；
/// - `PiggyPickerSheet`：卡片 + 顶栏「X / 标题 / ✓」—— 选择器与动作菜单；
/// - 表单抽屉（云同步配置 `_CloudConfigSheet`、加密设置密码）：卡片 + 居中标题
///   + 底部「取消｜保存」双等宽按钮行。
class PiggySheetCard extends StatelessWidget {
  const PiggySheetCard({super.key, required this.child});

  /// 卡片内容。卡片高度交给内容；超高时内容自己滚动（见 [PiggyPickerSheet.maxHeight]）。
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 键盘避让：无输入框的选择器一般用不到，保留以防插入输入型内容
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      // SafeArea 在外统一吃掉底部安全区，内部不要再叠 paddingOf.bottom
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PiggyDimens.p16,
            0,
            PiggyDimens.p16,
            PiggyDimens.p16,
          ),
          child: Material(
            color: PiggyTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            clipBehavior: Clip.antiAlias,
            child: child,
          ),
        ),
      ),
    );
  }
}
