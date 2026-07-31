import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'piggy_header.dart';

/// 可扩展底部抽屉容器
///
/// 基于 [DraggableScrollableSheet] 实现从底部弹出的抽屉，支持：
/// - 默认半屏展示
/// - 向上拖动扩展至全屏
/// - 顶部拖动指示条
/// - 左上角关闭按钮、右上角保存按钮
/// - 与内部滚动视图共享 [ScrollController]，实现联动
///
/// 物理动画：启用 [DraggableScrollableSheet.snap] 后，松手时由 Flutter 内置的
/// 弹簧物理驱动抽屉吸附到最近的 snap 点。松手速度足够快时顺势完成动作。
class ExpandableBottomSheet extends StatelessWidget {
  const ExpandableBottomSheet({
    super.key,
    required this.title,
    required this.onClose,
    this.onSave,
    this.saveIcon,
    required this.builder,
    this.initialChildSize = 0.65,
    this.minChildSize = 0.35,
    this.maxChildSize = 1.0,
    this.snapSizes,
    this.showDragHandle = true,
    this.backgroundColor,
    this.titleWidget,
    this.bottom,
    this.bottomHeight = 0,
  });

  /// 标题栏文字
  final String title;

  /// 关闭按钮回调
  final VoidCallback onClose;

  /// 保存按钮回调，为 null 时不显示保存按钮
  final VoidCallback? onSave;

  /// 保存按钮图标，为 null 时不显示保存按钮
  final Widget? saveIcon;

  /// 内容构建器，接收 [ScrollController] 用于内部滚动视图
  final Widget Function(BuildContext context, ScrollController scrollController)
      builder;

  /// 抽屉初始高度占屏幕比例
  final double initialChildSize;

  /// 抽屉最小高度占屏幕比例
  final double minChildSize;

  /// 抽屉最大高度占屏幕比例
  final double maxChildSize;

  /// 自定义 snap 吸附点（不含 min/max，它们自动作为吸附点）
  ///
  /// 为 null 时自动计算：若 [initialChildSize] 介于 min 和 max 之间，
  /// 则以 [initialChildSize] 作为中间吸附点；否则无中间吸附点。
  final List<double>? snapSizes;

  /// 是否显示顶部拖动指示条
  final bool showDragHandle;

  /// 抽屉背景色，默认使用主题 surface
  final Color? backgroundColor;

  /// 标题栏右侧自定义 widget（与 [onSave] 互斥：同时存在时 [titleWidget] 优先）
  final Widget? titleWidget;

  /// 标题栏底部独立区域（用于 TabBar / 分段选择器）
  final Widget? bottom;

  /// [bottom] 的高度
  final double bottomHeight;

  /// 计算有效的 snap 吸附点列表
  ///
  /// snapSizes 必须满足：每个值严格介于 minChildSize 和 maxChildSize 之间，且升序排列。
  List<double> _effectiveSnapSizes() {
    if (snapSizes != null) return snapSizes!;
    if (initialChildSize > minChildSize && initialChildSize < maxChildSize) {
      return [initialChildSize];
    }
    return const [];
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = backgroundColor ?? PiggyTokens.surface(context);
    final effectiveSnapSizes = _effectiveSnapSizes();

    return DraggableScrollableSheet(
      initialChildSize: initialChildSize,
      minChildSize: minChildSize,
      maxChildSize: maxChildSize,
      // 启用 snap：松手后由弹簧物理驱动吸附到最近的 snap 点
      snap: true,
      snapSizes: effectiveSnapSizes,
      // 拖到最小高度时自动关闭抽屉
      shouldCloseOnMinExtent: true,
      expand: false,
      builder: (context, scrollController) {
        return Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(PiggyDimens.radiusXl),
            ),
          ),
          child: Column(
            children: [
              if (showDragHandle)
                _DragHandle(scrollController: scrollController),
              // 底部抽屉使用纯色背景：禁用毛玻璃模糊与底部高光线，
              // 使标题栏与内容区视觉上无缝融合，避免突兀的分界线
              PiggyTitleBar(
                title: title,
                titleWidget: titleWidget,
                showBack: true,
                backIcon: const Icon(Icons.close),
                onBack: onClose,
                actions: [
                  if (onSave != null && saveIcon != null)
                    IconButton(
                      icon: saveIcon!,
                      onPressed: onSave,
                    ),
                ],
                backgroundColor: bgColor,
                bottom: bottom,
                bottomHeight: bottomHeight,
                compact: true,
              ),
              // 用 RepaintBoundary 隔离表单内容，键盘动画时仅重绘此区域
              Expanded(
                child: RepaintBoundary(
                  // 将 viewInsets 读取隔离到独立叶子组件：
                  // 键盘动画期间每帧变化的 viewInsets 仅触发此组件重建，
                  // 不会重建上层 DraggableScrollableSheet / PiggyTitleBar / 表单体
                  child: _KeyboardBottomPadding(
                    child: builder(context, scrollController),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 键盘底部避让 Padding
///
/// 独立读取 [MediaQuery.viewInsetsOf] 以隔离 rebuild 范围。
/// 键盘弹出/收起动画期间 viewInsets 每帧变化，若在父级 build 中读取
/// 会导致整棵表单子树每帧重建。提取为叶子组件后，仅此 Padding 重建，
/// child（表单内容）不受影响。
class _KeyboardBottomPadding extends StatelessWidget {
  const _KeyboardBottomPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: child,
    );
  }
}

/// 顶部拖动指示条
///
/// 提供视觉反馈，并允许用户拖动以扩展/收起抽屉。
class _DragHandle extends StatelessWidget {
  const _DragHandle({required this.scrollController});

  final ScrollController scrollController;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      color: Colors.transparent,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Container(
        width: 40,
        height: 4,
        decoration: BoxDecoration(
          color: PiggyTokens.iconTertiary(context).withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
