import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import '../../styles/tokens.dart';
import '../../utils/format_utils.dart';
import 'chart_tooltip_bubble.dart';

/// 洞察页柱状图（fl_chart `BarChart` 实现）。
///
/// 与折线图共用同一份 `values`/`xLabels`/`highlightIndex` 数据源，
/// 展示同维度趋势，支持：
/// - 圆角柱 + 今日高亮（[highlightIndex] 对应柱用不透明主题色）
/// - 点按柱体弹出主题色气泡（与折线图同款样式，常驻直到再点空白/滑动），
///   [hideAmounts] 时显示 ****
/// - 横滑切换周期（与折线图一致的 [onSwipeLeft]/[onSwipeRight]）
/// - 可选标题行（[title] + 右上角主题色汇总 [badgeText]）
/// - 左侧 Y 轴大金额缩写标签（[isChineseLocale] 控制 万/k/M）
/// - 暗黑/浅色主题自适应
class AnalyticsBarChart extends StatefulWidget {
  final List<double> values;
  final List<String> xLabels;
  final int? highlightIndex;
  final bool hideAmounts; // 是否隐藏金额
  final Color themeColor;
  final bool isDark; // 是否暗黑模式
  final VoidCallback onSwipeLeft; // 下一周期
  final VoidCallback onSwipeRight; // 上一周期

  /// 卡片标题（如「支出趋势」），null 时不渲染标题行
  final String? title;

  /// 右上角主题色 badge 文案（如「¥4.59万 2026.08.03~08.09」）
  final String? badgeText;

  /// Y 轴/tooltip 缩写语言：中文用「万」，其他用 k/M
  final bool isChineseLocale;

  /// 点按气泡：返回第 index 个数据点的气泡文案（与折线图同款）。
  /// 非空时启用点按气泡，点击柱体显示并常驻，再点空白/滑动消失。
  final String Function(int index)? pointTooltipText;

  const AnalyticsBarChart({
    super.key,
    required this.values,
    required this.xLabels,
    required this.highlightIndex,
    required this.hideAmounts,
    required this.themeColor,
    required this.isDark,
    required this.onSwipeLeft,
    required this.onSwipeRight,
    this.title,
    this.badgeText,
    this.isChineseLocale = true,
    this.pointTooltipText,
  });

  @override
  State<AnalyticsBarChart> createState() => _AnalyticsBarChartState();
}

class _AnalyticsBarChartState extends State<AnalyticsBarChart> {
  int? _touchedIndex;

  // 左侧 Y 轴标签预留宽度 / 底部 X 轴标签预留高度（与 titlesData 配置一致）
  static const double _leftAxisWidth = 38.0;
  static const double _bottomAxisHeight = 26.0;

  void _dismissTooltip() {
    if (_touchedIndex != null) {
      setState(() => _touchedIndex = null);
    }
  }

  /// 判断第 [i] 根柱是否高亮：点按选中时高亮该柱；未点按时回落到
  /// 当前周期（[widget.highlightIndex]）默认高亮。
  bool _isHighlighted(int i) {
    if (_touchedIndex != null) {
      return _touchedIndex == i;
    }
    return widget.highlightIndex != null && i == widget.highlightIndex;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.values.isEmpty) return const SizedBox.shrink();

    // Y 轴范围：支持结余视角的负值，顶部/底部各留 25% 空间
    final maxV = widget.values.fold<double>(0.0, (acc, v) => v > acc ? v : acc);
    final minV = widget.values.fold<double>(0.0, (acc, v) => v < acc ? v : acc);
    final maxY = maxV > 0 ? maxV * 1.25 : 1.0;
    final minY = minV < 0 ? minV * 1.25 : 0.0;

    // X 轴标签采样步长：与折线图一致，最多约 8 个标签
    int step = (widget.values.length / 8).ceil();
    if (step < 1) step = 1;

    final axisLabelColor =
        widget.isDark ? Colors.white70 : PiggyTokens.secondaryTextStatic;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onHorizontalDragEnd: (details) {
        _dismissTooltip();
        final v = details.primaryVelocity ?? 0;
        if (v < 0) {
          widget.onSwipeLeft();
        } else if (v > 0) {
          widget.onSwipeRight();
        }
      },
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 8),
        decoration: BoxDecoration(
          color: PiggyTokens.surface(context),
          borderRadius: BorderRadius.circular(PiggyChartTokens.cornerRadius),
          // 主题色细边框（与洞察页折线图卡统一）
          border: Border.all(
            color: Theme.of(context).colorScheme.primary,
            width: 1.5,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.title != null) ...[
              Row(
                children: [
                  Container(
                    width: 3,
                    height: 14,
                    margin: const EdgeInsets.only(right: 8),
                    decoration: BoxDecoration(
                      color: widget.themeColor,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      widget.title!,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: PiggyTokens.textPrimary(context),
                      ),
                    ),
                  ),
                  if (widget.badgeText != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: widget.themeColor,
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusLg),
                      ),
                      child: Text(
                        widget.badgeText!,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 12),
            ],
            SizedBox(
              height: 180,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final chartSize = Size(constraints.maxWidth, constraints.maxHeight);
                  return Stack(
                    children: [
                      Positioned.fill(
                        child: BarChart(
                          BarChartData(
                            minY: minY,
                            maxY: maxY,
                            alignment: BarChartAlignment.spaceAround,
                            gridData: FlGridData(
                              show: true,
                              drawVerticalLine: false,
                              getDrawingHorizontalLine: (value) => FlLine(
                                color: PiggyTokens.dividerStatic,
                                strokeWidth: 1,
                                dashArray: [4, 4],
                              ),
                            ),
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              rightTitles: const AxisTitles(
                                  sideTitles: SideTitles(showTitles: false)),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: _leftAxisWidth,
                                  interval: (maxY - minY) / 4,
                                  getTitlesWidget: (value, meta) {
                                    // 顶/底部端点不画，避免与卡片边缘重叠
                                    if (value == meta.max || value == meta.min) {
                                      return const SizedBox.shrink();
                                    }
                                    return SideTitleWidget(
                                      axisSide: meta.axisSide,
                                      space: 4,
                                      child: Text(
                                        widget.hideAmounts
                                            ? '**'
                                            : formatCompactAxis(value,
                                                isChinese: widget
                                                    .isChineseLocale),
                                        style: TextStyle(
                                          fontSize: PiggyChartTokens
                                                  .xLabelFontSize -
                                              1,
                                          color: axisLabelColor,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              bottomTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: _bottomAxisHeight,
                                  getTitlesWidget: (value, meta) {
                                    final i = value.toInt();
                                    if (i < 0 || i >= widget.xLabels.length) {
                                      return const SizedBox.shrink();
                                    }
                                    final isHi = _isHighlighted(i);
                                    // 采样显示，避免标签拥挤；高亮索引的标签始终保留
                                    if (!isHi && i % step != 0) {
                                      return const SizedBox.shrink();
                                    }
                                    return SideTitleWidget(
                                      axisSide: meta.axisSide,
                                      space: 6,
                                      child: Text(
                                        widget.xLabels[i],
                                        style: TextStyle(
                                          fontSize:
                                              PiggyChartTokens.xLabelFontSize,
                                          color: isHi
                                              ? PiggyTokens.textPrimary(context)
                                              : axisLabelColor,
                                          fontWeight: isHi
                                              ? FontWeight.w600
                                              : FontWeight.w400,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            // 关闭内置 tooltip，改用自绘主题色气泡（与折线图一致）
                            barTouchData: BarTouchData(
                              enabled: true,
                              handleBuiltInTouches: true,
                              touchTooltipData: BarTouchTooltipData(
                                getTooltipColor: (_) => Colors.transparent,
                                getTooltipItem: (_, __, ___, ____) => null,
                              ),
                              touchCallback: (event, response) {
                                if (!event.isInterestedForInteractions) {
                                  return;
                                }
                                final idx =
                                    response?.spot?.touchedBarGroupIndex;
                                setState(() {
                                  if (idx == null ||
                                      idx < 0 ||
                                      idx >= widget.values.length) {
                                    _touchedIndex = null;
                                  } else {
                                    _touchedIndex = idx;
                                  }
                                });
                              },
                            ),
                            barGroups:
                                List.generate(widget.values.length, (i) {
                              final v = widget.values[i];
                              final isHi = _isHighlighted(i);
                              return BarChartGroupData(
                                x: i,
                                barRods: [
                                  BarChartRodData(
                                    toY: v,
                                    width: _barWidth(widget.values.length),
                                    color: isHi
                                        ? widget.themeColor
                                        : widget.themeColor
                                            .withValues(alpha: 0.35),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                ],
                              );
                            }),
                          ),
                        ),
                      ),
                      // 点按气泡：主题色底白字，位于柱顶上方，常驻直到再点空白/滑动
                      if (_touchedIndex != null &&
                          widget.pointTooltipText != null &&
                          _touchedIndex! < widget.values.length)
                        _buildTooltip(context, chartSize),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 点按气泡定位：柱体水平居中于其 band，垂直贴柱顶上方。
  Widget _buildTooltip(BuildContext context, Size size) {
    final i = _touchedIndex!;
    final plotWidth = size.width - _leftAxisWidth;
    final band = plotWidth / widget.values.length;
    // 柱体中心 x → Align 坐标（-1..1），留出边距防止气泡超出卡片
    final centerX = _leftAxisWidth + band * (i + 0.5);
    final alignX = ((centerX / size.width) * 2 - 1).clamp(-0.72, 0.72);

    // 柱顶 y：按 minY..maxY 线性映射到绘图区（与 fl_chart 归一化一致）
    final maxV = widget.values.fold<double>(0.0, (a, v) => v > a ? v : a);
    final minV = widget.values.fold<double>(0.0, (a, v) => v < a ? v : a);
    final maxY = maxV > 0 ? maxV * 1.25 : 1.0;
    final minY = minV < 0 ? minV * 1.25 : 0.0;
    final plotBottom = size.height - _bottomAxisHeight;
    final t = (widget.values[i] - minY) / (maxY - minY);
    final barEndY = plotBottom * (1 - t);
    final top = (barEndY - 46).clamp(4.0, size.height - 56);

    return Positioned.fill(
      child: Align(
        alignment: Alignment(alignX, -1),
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: ChartTooltipBubble(
            text: widget.pointTooltipText!(i),
            color: widget.themeColor,
          ),
        ),
      ),
    );
  }

  /// 根据数据点数量自适应柱宽，避免月视角（31 天）下柱体重叠
  double _barWidth(int n) {
    if (n > 24) return 5;
    if (n > 12) return 7;
    return 10;
  }
}
