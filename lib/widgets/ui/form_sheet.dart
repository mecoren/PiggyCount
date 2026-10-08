import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'sheet_actions.dart';
import 'sheet_card.dart';

/// 表单类底部抽屉的统一外壳（悬浮卡片式），基准实现见云同步配置
/// `cloud_service_page.dart` 的 Supabase / WebDAV / S3 三表单。
///
/// 结构固定为（AGENTS「表单抽屉一律用悬浮卡片外壳」）：
///
/// ```
/// 抓取条（下拉关闭的显式把手）
/// 标题居中（strongTitle + fs17，固定）
/// p16
/// ┌ 字段区（限高 + 内部滚动，下拉到顶继续拉 = 关闭）┐
/// └ Flexible(loose) → SingleChildScrollView ┘
/// p20
/// 「取消｜保存」（PiggySheetActions，**固定在卡片底部**）
/// ```
///
/// 卡片 chrome（键盘避让 / 底部安全区 / 左右留距 / Material）由 [PiggySheetCard]
/// 提供；只有中间字段区滚动，标题与按钮行常驻可见 —— 长表单不必滚到底才能保存。
///
/// 为什么字段区要自己兜「下拉关闭」：模态底抽屉自身的下拉手势会被内部可滚动区
/// 在手势竞技场里吃掉（`test/widgets/form_sheet_shell_test.dart` 的探针用例复现：
/// 长内容在标题或字段上拖动都不会关闭）。因此抓取条 / 标题 / 按钮行这些
/// **非滚动区**靠外层手势关闭，字段区由 [_DragToDismiss] 兜住。
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

  /// 卡片标题（居中展示，常驻不滚动）。
  final String title;

  /// 表单字段区。**不要**自带滚动容器 / `Expanded` —— 本组件的内容区已限高
  /// 并内部滚动；纵向要撑满用 [BoxConstraints] 限一下即可。
  final Widget child;

  final String cancelLabel;
  final String confirmLabel;

  /// 取消回调；同时作为「抓取条 / 标题 / 字段区下拉关闭」的收尾动作，
  /// 一般传 `() => Navigator.of(context).pop()`。
  final VoidCallback onCancel;

  /// 确认回调；传 `null` 即禁用确认键（如必填项为空时），与
  /// [PiggySheetActions.onConfirm] 的语义一致。
  final VoidCallback? onConfirm;

  /// 确认进行中：确认键转圈并与取消键一并禁用（防连点）。
  final bool confirmBusy;

  @override
  Widget build(BuildContext context) {
    return PiggySheetCard(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const _SheetDragHandle(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              PiggyDimens.p20,
              PiggyDimens.p4,
              PiggyDimens.p20,
              0,
            ),
            child: Text(
              title,
              textAlign: TextAlign.center,
              style: PiggyTextTokens.strongTitle(context).copyWith(
                fontSize: PiggyTextTokens.fs17,
              ),
            ),
          ),
          const SizedBox(height: PiggyDimens.p16),
          // Flexible(loose)：拿到的剩余高度有界（模态抽屉本身有界），
          // 字段少时按内容收缩、字段多时截断并内部滚动。
          Flexible(
            child: _DragToDismiss(
              onDismiss: onCancel,
              child: SingleChildScrollView(
                // 固定 Clamping：各平台手感一致，且顶部继续下拉会发
                // OverscrollNotification（bouncing 物理不会发，那样 iOS 上
                // 字段区就永远关不掉抽屉）。代价是抽屉字段区不做回弹。
                physics: const ClampingScrollPhysics(),
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

/// 字段区的「下拉到顶继续拉 = 关闭抽屉」。
///
/// 只对**顶部**过度滚动累计（`OverscrollNotification.overscroll < 0`），
/// 累计超过阈值触发一次 [onDismiss]；滚动开始 / 结束清零，避免跨手势串味。
class _DragToDismiss extends StatefulWidget {
  const _DragToDismiss({required this.onDismiss, required this.child});

  final VoidCallback onDismiss;
  final Widget child;

  @override
  State<_DragToDismiss> createState() => _DragToDismissState();
}

class _DragToDismissState extends State<_DragToDismiss> {
  /// 关闭阈值（逻辑像素）：够长以免和「滚回顶部」的手感冲突，
  /// 又不至于要拉半屏。
  static const double _dismissThreshold = 72;

  double _pulled = 0;

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollNotification>(
      onNotification: (notification) {
        if (notification is ScrollStartNotification ||
            notification is ScrollEndNotification) {
          _pulled = 0;
        } else if (notification is OverscrollNotification &&
            notification.dragDetails != null) {
          if (notification.overscroll < 0) {
            _pulled += -notification.overscroll;
            if (_pulled >= _dismissThreshold) {
              _pulled = 0;
              widget.onDismiss();
            }
          } else {
            _pulled = 0;
          }
        }
        // 不拦截通知：让 overscroll 指示器等继续收到
        return false;
      },
      child: widget.child,
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
