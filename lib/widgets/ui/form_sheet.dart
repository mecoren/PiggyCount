import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'sheet_actions.dart';
import 'sheet_card.dart';
import 'sheet_drag.dart';

/// 表单类底部抽屉的统一外壳（悬浮卡片式），基准实现见云同步配置
/// `cloud_service_page.dart` 的 Supabase / WebDAV / S3 三表单。
///
/// 结构固定为（AGENTS「表单抽屉一律用悬浮卡片外壳」）：
///
/// ```
/// 抓取条（下拉关闭的显式把手）
/// 标题居中（strongTitle + fs17，固定）
///   〔编辑态可选：左上角垃圾桶图标（传 deleteLabel）+ 右上角自定义图标（传 trailingAction）〕
/// p16
/// ┌ 字段区（限高 + 内部滚动，下拉到顶继续拉 = 关闭）┐
/// └ Flexible(loose) → PiggySheetDragContent → SingleChildScrollView ┘
/// p20
/// 「取消｜保存」（PiggySheetActions，**固定在卡片底部**）
/// ```
///
/// 卡片 chrome（键盘避让 / 底部安全区 / 左右留距 / Material）由 [PiggySheetCard]
/// 提供；只有中间字段区滚动，标题与按钮行常驻可见 —— 长表单不必滚到底才能保存。
///
/// **下拉关闭由公共件提供**（2026-10-09 从本文件抽出，列表型选择器同款）：
/// [PiggySheetDragScope] 负责整卡手势 + 跟手位移 + 判定 / 收尾，
/// [PiggySheetDragContent] 负责把字段区的 overscroll 折算成位移。整卡只有一条通路 ——
/// 抓取条 / 标题 / 按钮行走外层手势，字段区走 overscroll，两路都只是「喂进度」。
/// 判定口径、钉顶物理、`RepaintBoundary` 等细节见 `sheet_drag.dart` 的文件头注释，
/// 本组件不再自己实现一遍。
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
    this.deleteLabel,
    this.onDelete,
    this.deleteBusy = false,
    this.trailingAction,
  });

  /// 卡片标题（居中展示，常驻不滚动）。
  final String title;

  /// 表单字段区。**不要**自带滚动容器 / `Expanded` —— 本组件的内容区已限高
  /// 并内部滚动；纵向要撑满用 [BoxConstraints] 限一下即可。
  final Widget child;

  final String cancelLabel;
  final String confirmLabel;

  /// 取消回调；同时作为「抓取条 / 标题 / 按钮行 / 字段区下拉关闭」的收尾动作，
  /// 一般传 `() => Navigator.of(context).pop()`（见类注释：必须真的收起抽屉）。
  final VoidCallback onCancel;

  /// 确认回调；传 `null` 即禁用确认键（如必填项为空时），与
  /// [PiggySheetActions.onConfirm] 的语义一致。
  final VoidCallback? onConfirm;

  /// 确认进行中：确认键转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  /// 编辑态抽屉的删除入口文案（**渲染为标题栏左上角的垃圾桶图标**，本值只作
  /// tooltip）；`null` = 不渲染删除入口（新建态就该传 null）。
  ///
  /// ⚠️ 删除入口**不要**塞进 [child]（字段区）：字段区是滚动区，周期账单那种
  /// 十几个字段的长表单会把入口推到屏幕外，用户以为「没有删除」。交给本参数渲染，
  /// 它固定在标题栏左上角、不随滚动移动，也不占底部动作行的空间。
  ///
  /// 为什么在左：删除不可逆，放在远离右拇指常停留位置的左上角，与「右下角是主
  /// 动作（保存）」形成对角；左侧要放别的图标动作时用 [trailingAction] 那侧。
  final String? deleteLabel;

  /// 删除回调；与 [deleteLabel] 成对使用。
  final VoidCallback? onDelete;

  /// 删除进行中：删除图标禁用（防连点）。
  final bool deleteBusy;

  /// 标题栏**右上角**的自定义图标动作（只渲染图标，`null` = 不渲染）。
  ///
  /// 左侧槽位归 [deleteLabel]（删除便捷写法），右上角留给各页自己的次要动作
  /// （如账户抽屉的「隐藏 / 恢复」）。槽位固定 48 宽，只放图标类动作，塞文字
  /// 按钮会把居中标题挤偏。
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    final String? deleteLabel = this.deleteLabel;
    // 左上角槽位：deleteLabel 的垃圾桶便捷写法（唯一占左侧的动作）。
    final Widget? leading = deleteLabel == null
        ? null
        : IconButton(
            onPressed: deleteBusy ? null : onDelete,
            icon: const Icon(Icons.delete_outline),
            color: PiggyTokens.error(context),
            // 只要图标：文案走 tooltip（长按可见 + 无障碍朗读）。
            tooltip: deleteLabel,
            iconSize: 22,
          );
    return PiggySheetDragScope(
      // 下拉判定关闭 = 取消（项目内一律 `Navigator.pop`）。
      onDismiss: onCancel,
      child: PiggySheetCard(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const _SheetDragHandle(),
            // 标题行：居中标题 + 两侧图标槽（各占 48 等宽，标题不被挤偏）。
            Row(
              children: [
                SizedBox(width: 48, child: leading),
                Expanded(
                  child: Text(
                    title,
                    textAlign: TextAlign.center,
                    style: PiggyTextTokens.strongTitle(context).copyWith(
                      fontSize: PiggyTextTokens.fs17,
                    ),
                  ),
                ),
                SizedBox(width: 48, child: trailingAction),
              ],
            ),
            const SizedBox(height: PiggyDimens.p16),
            // Flexible(loose)：拿到的剩余高度有限（模态抽屉本身有界），
            // 字段少时按内容收缩、字段多时截断并内部滚动。
            Flexible(
              child: PiggySheetDragContent(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.symmetric(
                    horizontal: PiggyDimens.p20,
                  ),
                  child: child,
                ),
              ),
            ),
            const SizedBox(height: PiggyDimens.p20),
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: PiggyDimens.p20,
              ),
              child: PiggySheetActions(
                cancelLabel: cancelLabel,
                confirmLabel: confirmLabel,
                onCancel: onCancel,
                onConfirm: onConfirm,
                confirmBusy: confirmBusy,
              ),
            ),
            const SizedBox(height: PiggyDimens.p20),
          ],
        ),
      ),
    );
  }
}

/// 抽屉顶部抓取条（32×4 中性色圆角条）：既是「可下拉关闭」的视觉提示，
/// 也是长表单里最稳的拖拽落点。
class _SheetDragHandle extends StatelessWidget {
  const _SheetDragHandle();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(
        top: PiggyDimens.p8,
        bottom: PiggyDimens.p4,
      ),
      child: Center(
        child: Container(
          width: 32,
          height: 4,
          decoration: BoxDecoration(
            color: PiggyTokens.borderStrong(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
          ),
        ),
      ),
    );
  }
}

/// 以统一外壳弹出表单抽屉：[T] 是抽屉返回值类型。
///
/// 弹层底必须透明 —— 卡片由 [PiggyFormSheet] 内的 Material 绘制四角圆角与
/// 悬浮留距（传实色底会变成旧的全宽平底弹层）。
///
/// `enableDrag: false`：模态抽屉自身的拖拽按 `route.animation` 的曲线折算位移，
/// 只能盖住非滚动区，与字段区必定两套手感；整卡下拉统一交给 [PiggyFormSheet]
/// （内部是 [PiggySheetDragScope]），见其类注释。
Future<T?> showPiggyFormSheet<T>(
  BuildContext context, {
  required WidgetBuilder builder,
}) {
  return showModalBottomSheet<T>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    enableDrag: false,
    builder: builder,
  );
}
