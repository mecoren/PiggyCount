import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 滑块式分段选择器（wait 系公共组件）
///
/// 设计约束：
/// - 采用半透明玻璃质感（BackdropFilter 模糊 + 低透明度背景 + 顶部折射高光线），
///   使组件在任意背景下呈现通透的「透明质感」。
/// - 选中项使用强调色胶囊，胶囊保留轻微阴影以强化层次。
/// - 分割线上下留出间距，不全满。
/// - 切换时胶囊平滑滑动。
/// - 支持触控拖拽滑动选择和点击选择。
class WaitSlidingSegmentedControl<T> extends StatefulWidget {
  const WaitSlidingSegmentedControl({
    super.key,
    required this.segments,
    required this.selected,
    required this.onValueChanged,
    this.accentColor,
    this.height = 42,
    this.fontSize = 14,
  });

  /// 选项列表
  final List<WaitSlidingSegment<T>> segments;

  /// 当前选中的值（可空，为 null 或未匹配时默认选中第一项）
  final T? selected;

  /// 切换回调
  final ValueChanged<T> onValueChanged;

  /// 选中项的强调色。未指定时使用 [ColorScheme.primary]。
  final Color? accentColor;

  /// 控件高度（默认 42，紧凑场景可传 28 等）
  final double height;

  /// 选项文字字号（默认 14，紧凑场景可传 12 等）
  final double fontSize;

  @override
  State<WaitSlidingSegmentedControl<T>> createState() =>
      _WaitSlidingSegmentedControlState<T>();
}

/// 分段选择器选项（wait 系公共组件）
class WaitSlidingSegment<T> {
  const WaitSlidingSegment({
    required this.value,
    required this.label,
  });

  final T value;
  final String label;
}

class _WaitSlidingSegmentedControlState<T>
    extends State<WaitSlidingSegmentedControl<T>> {
  /// 是否正在拖拽
  bool _isDragging = false;

  /// 拖拽时拇指位置（以分段索引为单位，可为小数）
  double _dragThumbIndex = 0;

  int get _selectedIndex {
    final index =
        widget.segments.indexWhere((s) => s.value == widget.selected);
    return index >= 0 ? index : 0;
  }

  /// 拖拽时，文本高亮跟随拇指位置
  int get _effectiveSelectedIndex {
    if (_isDragging) {
      return _dragThumbIndex.round().clamp(0, widget.segments.length - 1);
    }
    return _selectedIndex;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final accentColor = widget.accentColor ?? colorScheme.primary;

    // 圆角令牌：外层轨道使用 radiusLg（12px，与按钮/菜单项同级）；
    // 内层胶囊半径 = 外圆角 - 3px（胶囊 top/bottom 各 3px 内边距），
    // 使胶囊贴合外层曲率，视觉上呈「内嵌胶囊」效果。
    final double outerRadius = PiggyDimens.radiusLg;
    final double thumbRadius = outerRadius - 3;

    return LayoutBuilder(
      builder: (context, constraints) {
        final totalWidth = constraints.maxWidth;
        if (totalWidth <= 0 || widget.segments.isEmpty) {
          return const SizedBox.shrink();
        }
        final segmentWidth = totalWidth / widget.segments.length;
        final selectedIndex = _selectedIndex;
        final effectiveSelected = _effectiveSelectedIndex;

        // 拇指位置：拖拽时跟随手指，非拖拽时对齐选中分段
        final double thumbLeft;
        if (_isDragging) {
          thumbLeft = _dragThumbIndex * segmentWidth + 3;
        } else {
          thumbLeft = selectedIndex * segmentWidth + 3;
        }
        final thumbWidth = segmentWidth - 6;

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          // 点击选择
          onTapUp: (details) {
            final index = (details.localPosition.dx / segmentWidth)
                .floor()
                .clamp(0, widget.segments.length - 1);
            widget.onValueChanged(widget.segments[index].value);
          },
          // 拖拽开始
          onHorizontalDragStart: (details) {
            setState(() {
              _isDragging = true;
              _dragThumbIndex = selectedIndex.toDouble();
            });
          },
          // 拖拽更新：拇指跟随手指
          onHorizontalDragUpdate: (details) {
            final RenderBox box =
                context.findRenderObject() as RenderBox;
            final localPosition = box.globalToLocal(details.globalPosition);
            setState(() {
              _dragThumbIndex = (localPosition.dx / segmentWidth - 0.5).clamp(
                0.0,
                (widget.segments.length - 1).toDouble(),
              );
            });
          },
          // 拖拽结束：吸附到最近分段
          onHorizontalDragEnd: (details) {
            final nearestIndex = _dragThumbIndex
                .round()
                .clamp(0, widget.segments.length - 1);
            setState(() {
              _isDragging = false;
            });
            widget.onValueChanged(widget.segments[nearestIndex].value);
          },
          child: Container(
            height: widget.height,
            // 95% 中性实色背景（与底部导航栏/头部统一），消除 BackdropFilter 模糊开销
            decoration: BoxDecoration(
              color: PiggyTokens.tabBarBackground(context),
              borderRadius: BorderRadius.circular(outerRadius),
              // 细微边框用于界定轨道
              border: Border.all(
                color: colorScheme.outline.withValues(alpha: 0.3),
                width: 0.5,
              ),
            ),
            child: Stack(
              children: [
                // 顶部折射高光线（呼应头部语言）
                Positioned(
                  top: 0,
                  left: 0,
                  right: 0,
                  child: Container(
                    height: 0.5,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.centerLeft,
                        end: Alignment.centerRight,
                        colors: [
                          Colors.white.withValues(alpha: 0.0),
                          Colors.white.withValues(alpha: 0.35),
                          Colors.white.withValues(alpha: 0.0),
                        ],
                      ),
                    ),
                  ),
                ),
                      // 滑动强调色胶囊
                      _isDragging
                          ? Positioned(
                              left: thumbLeft,
                              top: 3,
                              bottom: 3,
                              width: thumbWidth,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: accentColor,
                                  borderRadius: BorderRadius.circular(thumbRadius),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accentColor.withValues(alpha: 0.35),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          : AnimatedPositioned(
                              duration: const Duration(milliseconds: 220),
                              curve: Curves.easeInOutCubic,
                              left: selectedIndex >= 0
                                  ? selectedIndex * segmentWidth + 3
                                  : 0,
                              top: 3,
                              bottom: 3,
                              width: segmentWidth - 6,
                              child: Container(
                                decoration: BoxDecoration(
                                  color: accentColor,
                                  borderRadius: BorderRadius.circular(thumbRadius),
                                  boxShadow: [
                                    BoxShadow(
                                      color: accentColor.withValues(alpha: 0.35),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                      // 选项标签 + 分割线
                      Row(
                        children:
                            widget.segments.asMap().entries.map((entry) {
                          final index = entry.key;
                          final segment = entry.value;
                          final isSelected = index == effectiveSelected;
                          final isLast =
                              index == widget.segments.length - 1;

                          return Expanded(
                            // 无障碍基线：每个分段独立成为可聚焦选项
                            // （button 角色 + selected 状态 + 双击切换动作），
                            // 不再是整条控件一个无法操作的焦点；label 由
                            // 内部 Text 语义合并提供
                            child: Semantics(
                              button: true,
                              selected: isSelected,
                              onTap: () => widget.onValueChanged(
                                  widget.segments[index].value),
                              child: Center(
                                child: Container(
                                  height: widget.height,
                                  alignment: Alignment.center,
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Center(
                                          child: AnimatedDefaultTextStyle(
                                            duration: const Duration(
                                              milliseconds: 200,
                                            ),
                                            style: TextStyle(
                                              fontSize: widget.fontSize,
                                              fontWeight: FontWeight.w500,
                                              color: isSelected
                                                  ? colorScheme.surface
                                                  : colorScheme.onSurfaceVariant,
                                            ),
                                            child: Text(segment.label),
                                          ),
                                        ),
                                      ),
                                      // 分割线：上下留出间距，不全满（随高度缩放）
                                      if (!isLast)
                                        Padding(
                                          padding: EdgeInsets.symmetric(
                                            vertical: widget.height * 0.25,
                                          ),
                                          child: Container(
                                            width: 0.5,
                                            color: colorScheme.outline
                                                .withValues(alpha: 0.2),
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ],
                  ),
          ),
        );
      },
    );
  }
}
