import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'sheet_actions.dart';
import 'sheet_card.dart';

/// 表单类底部抽屉的统一外壳（悬浮卡片式），基准实现见云同步配置
/// `cloud_service_page.dart` 的 WebDAV / S3 / Supabase 三表单。
///
/// 结构固定为（AGENTS.md「表单抽屉一律用悬浮卡片外壳」）：
/// **标题居中 → `p16` → 表单字段 → `p20` → `PiggySheetActions`「取消｜保存」**，
/// 卡片 chrome（键盘避让 / 底部安全区 / 左右留距 / Material）由 [PiggySheetCard]
/// 提供；内容超长时整卡滚动，标题与按钮行始终留在卡片内。
///
/// 与另两种外壳的分工：
/// - 本组件：**含输入框的表单**（标题 + 字段 + 取消｜保存）；
/// - [PiggyPickerSheet]：选择器 / 动作菜单（顶栏 X + 标题，无底部按钮行）；
/// - [PiggySheetCard]：内容自备标题与按钮的面板（记账金额面板）。
class PiggyFormSheet extends StatelessWidget {
  const PiggyFormSheet({
    super.key,
    required this.title,
    required this.child,
    required this.cancelLabel,
    required this.confirmLabel,
    required this.onCancel,
    required this.onConfirm,
    this.confirmBusy = false,
  });

  /// 卡片标题（居中展示）。
  final String title;

  /// 表单字段区。**不要**自带滚动容器 / `Expanded` —— 本组件的内容区已限高
  /// 并内部滚动；纵向要撑满用 [BoxConstraints] 限一下即可。
  final Widget child;

  final String cancelLabel;
  final String confirmLabel;
  final VoidCallback onCancel;
  final VoidCallback onConfirm;

  /// 确认进行中：确认键转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  @override
  Widget build(BuildContext context) {
    return PiggySheetCard(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(PiggyDimens.p20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              title,
              textAlign: TextAlign.center,
              style: PiggyTextTokens.strongTitle(context).copyWith(
                fontSize: 17,
              ),
            ),
            const SizedBox(height: PiggyDimens.p16),
            child,
            const SizedBox(height: PiggyDimens.p20),
            PiggySheetActions(
              cancelLabel: cancelLabel,
              confirmLabel: confirmLabel,
              onCancel: onCancel,
              onConfirm: onConfirm,
              confirmBusy: confirmBusy,
            ),
          ],
        ),
      ),
    );
  }
}

/// 以统一外壳弹出表单抽屉：[T] 是抽屉返回值类型。
///
/// 弹层底必须透明 —— 卡片由 [PiggyFormSheet] 内的 Material 绘制四角圆角与
/// 悬浮留距（传实色底会变成旧的全宽平底弹层）。
Future<T?> showPiggyFormSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: builder,
  );
}
