import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'dart:math' as math;
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/format_utils.dart';
import 'chart_tooltip_bubble.dart';

class LineChart extends StatefulWidget {
  final List<double> values;
  final List<double>? secondaryValues; // 第二条线的数据（可选）
  final Color? secondaryColor; // 第二条线的颜色（可选）
  final List<String> xLabels;
  final int? highlightIndex;
  final VoidCallback onSwipeLeft; // 下一周期
  final VoidCallback onSwipeRight; // 上一周期
  final bool showHint;
  final String? hintText;
  final VoidCallback? onCloseHint;
  final VoidCallback? onPrimaryLineTap; // 主线点击回调
  final VoidCallback? onSecondaryLineTap; // 副线点击回调
  final bool whiteBg;
  final bool showGrid;
  final bool showDots;
  final bool annotate;
  final bool hideAmounts; // 是否隐藏金额
  final Color themeColor;
  // 令牌化参数
  final double lineWidth;
  final double dotRadius;
  final double cornerRadius;
  final double xLabelFontSize;
  final double yLabelFontSize;
  final bool isDark; // 是否暗黑模式
  // minimal 模式:用于 sparkline 等嵌入场景,去掉背景 RRect / Y 轴线 / 平均值虚线,
  // 避免卡中卡(白底套白底 + 轴线)的视觉污染。默认 false,旧调用方零变化。
  final bool minimal;

  /// 是否启用内部手势(点击高亮 / 横滑切周期)。资产卡内嵌图等设 false,把 tap
  /// 让给外层 InkWell(点击进全屏页);否则内部 opaque GestureDetector 会吞掉 tap。
  final bool interactive;

  /// 平滑曲线（单调三次插值，不 overshoot）。默认 false，旧调用方零变化。
  final bool smooth;

  /// 左侧 Y 轴大金额缩写标签（配合 [isChineseLocale] 用 万/k/M）。
  /// 开启后图表左侧预留标签位。默认 false。
  final bool showYAxisLabels;

  /// Y 轴缩写语言：中文用「万」，其他用 k/M/B。
  final bool isChineseLocale;

  /// 点按气泡：返回第 index 个数据点的气泡文案（如「08.09 支出 ¥1,918.03」）。
  /// 非空时启用点按气泡，再次点击空白处消失。
  final String Function(int index)? pointTooltipText;

  const LineChart({
    super.key,
    required this.values,
    this.secondaryValues,
    this.secondaryColor,
    required this.xLabels,
    required this.highlightIndex,
    required this.onSwipeLeft,
    required this.onSwipeRight,
    required this.showHint,
    this.hintText,
    this.onCloseHint,
    this.onPrimaryLineTap,
    this.onSecondaryLineTap,
    this.whiteBg = true,
    this.showGrid = true,
    this.showDots = true,
    this.annotate = true,
    this.hideAmounts = false,
    required this.themeColor,
    this.lineWidth = 2.0,
    this.dotRadius = 2.5,
    this.cornerRadius = 12,
    this.xLabelFontSize = 10,
    this.yLabelFontSize = 10,
    this.isDark = false,
    this.minimal = false,
    this.interactive = true,
    this.smooth = false,
    this.showYAxisLabels = false,
    this.isChineseLocale = true,
    this.pointTooltipText,
  });

  @override
  State<LineChart> createState() => _LineChartState();
}

class _LineChartState extends State<LineChart> {
  int? _tappedIndex;

  @override
  void didUpdateWidget(covariant LineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 数据/周期切换后旧索引可能越界，直接收起气泡；
    // 注意比较内容而非实例——调用方每次 build 都会重建列表
    if (_tappedIndex != null &&
        (_tappedIndex! >= widget.values.length ||
            !listEquals(oldWidget.values, widget.values))) {
      _tappedIndex = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      // interactive=false(资产卡内嵌图等)不自带手势:tap/swipe 让位给外层
      // (如外层 InkWell 点击进全屏页)。否则内部 opaque GestureDetector 会
      // 赢得手势竞技场、吞掉外层的点击。
      behavior: widget.interactive
          ? HitTestBehavior.opaque
          : HitTestBehavior.translucent,
      onTapDown: !widget.interactive
          ? null
          : (details) {
              if (widget.pointTooltipText != null) {
                _handlePointTap(details.localPosition);
              } else if (widget.onPrimaryLineTap != null ||
                  widget.onSecondaryLineTap != null) {
                _handleLineTap(details.localPosition, context);
              }
            },
      onHorizontalDragEnd: !widget.interactive
          ? null
          : (details) {
              final v = details.primaryVelocity ?? 0;
              if (v < 0) {
                setState(() => _tappedIndex = null);
                widget.onSwipeLeft();
              } else if (v > 0) {
                setState(() => _tappedIndex = null);
                widget.onSwipeRight();
              }
            },
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          return Stack(
            fit: StackFit.expand,
            children: [
              CustomPaint(
                painter: _LinePainter(
                  values: widget.values,
                  secondaryValues: widget.secondaryValues,
                  secondaryColor: widget.secondaryColor,
                  xLabels: widget.xLabels,
                  highlightIndex: widget.highlightIndex,
                  whiteBg: widget.whiteBg,
                  showGrid: widget.showGrid,
                  showDots: widget.showDots,
                  annotate: widget.annotate,
                  hideAmounts: widget.hideAmounts,
                  themeColor: widget.themeColor,
                  lineWidth: widget.lineWidth,
                  dotRadius: widget.dotRadius,
                  cornerRadius: widget.cornerRadius,
                  xLabelFontSize: widget.xLabelFontSize,
                  yLabelFontSize: widget.yLabelFontSize,
                  isDark: widget.isDark,
                  minimal: widget.minimal,
                  smooth: widget.smooth,
                  showYAxisLabels: widget.showYAxisLabels,
                  isChineseLocale: widget.isChineseLocale,
                  tappedIndex: _tappedIndex,
                ),
              ),
              if (_tappedIndex != null &&
                  widget.pointTooltipText != null &&
                  _tappedIndex! < widget.values.length &&
                  size.width > 0 &&
                  size.height > 0)
                _buildTooltip(context, size, _tappedIndex!),
              if (widget.showHint)
                Positioned(
                  right: 8,
                  top: 8,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: PiggyTokens.dividerStatic,
                      borderRadius:
                          BorderRadius.circular(PiggyDimens.radiusLg),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 4),
                      child: Row(
                        children: [
                          Icon(Icons.swipe,
                              size: 14,
                              color: PiggyTokens.textSecondary(context)),
                          const SizedBox(width: 4),
                          Text(
                            widget.hintText ??
                                AppLocalizations.of(context)
                                    .analyticsSwipeHint,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color:
                                        PiggyTokens.textSecondary(context)),
                          ),
                          const SizedBox(width: 4),
                          InkWell(
                            onTap: widget.onCloseHint,
                            child: Icon(Icons.close,
                                size: 14,
                                color: PiggyTokens.textTertiary(context)),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// 点按气泡：主题色底白字，位于数据点上方，水平居中于点并限制在图内。
  Widget _buildTooltip(BuildContext context, Size size, int index) {
    final points = _ChartGeom.pointsFor(
        widget.values,
        _ChartGeom.range(widget.values, widget.secondaryValues),
        size,
        widget.showYAxisLabels);
    final p = points[index];
    // Align x ∈ [-1,1]，留出边距防止气泡超出卡片
    final alignX = ((p.dx / size.width) * 2 - 1).clamp(-0.72, 0.72);
    final top = math.max(p.dy - 52.0, 4.0);
    return Positioned.fill(
      child: Align(
        alignment: Alignment(alignX, -1),
        child: Padding(
          padding: EdgeInsets.only(top: top),
          child: ChartTooltipBubble(
            text: widget.pointTooltipText!(index),
            color: widget.themeColor,
          ),
        ),
      ),
    );
  }

  /// 点按气泡手势：命中数据点附近(28px)则显示/切换气泡，否则收起。
  void _handlePointTap(Offset localPosition) {
    final renderBox = context.findRenderObject() as RenderBox?;
    if (renderBox == null) return;
    final size = renderBox.size;
    if (widget.values.isEmpty) return;
    final points = _ChartGeom.pointsFor(
        widget.values,
        _ChartGeom.range(widget.values, widget.secondaryValues),
        size,
        widget.showYAxisLabels);
    int? hit;
    double minDist = double.infinity;
    for (int i = 0; i < points.length; i++) {
      final d = (points[i] - localPosition).distance;
      if (d < minDist) {
        minDist = d;
        hit = i;
      }
    }
    setState(() {
      _tappedIndex = (hit != null && minDist <= 28) ? hit : null;
    });
  }

  /// 旧版线点击手势：判断点击位置离主线/副线哪条更近。
  void _handleLineTap(Offset localPosition, BuildContext context) {
    final size = context.size;
    if (size == null) return;
    final range = _ChartGeom.range(widget.values, widget.secondaryValues);

    final primaryPoints = widget.values.isEmpty
        ? <Offset>[]
        : _ChartGeom.pointsFor(
            widget.values, range, size, widget.showYAxisLabels);
    final secondaryPoints =
        (widget.secondaryValues == null || widget.secondaryValues!.isEmpty)
            ? <Offset>[]
            : _ChartGeom.pointsFor(widget.secondaryValues!, range, size,
                widget.showYAxisLabels);

    double minPrimaryDist = double.infinity;
    for (final p in primaryPoints) {
      final d = (p - localPosition).distance;
      if (d < minPrimaryDist) minPrimaryDist = d;
    }
    double minSecondaryDist = double.infinity;
    for (final p in secondaryPoints) {
      final d = (p - localPosition).distance;
      if (d < minSecondaryDist) minSecondaryDist = d;
    }

    if (secondaryPoints.isEmpty || minPrimaryDist <= minSecondaryDist) {
      widget.onPrimaryLineTap?.call();
    } else {
      widget.onSecondaryLineTap?.call();
    }
  }
}

/// 图表几何计算：State(手势/气泡) 与 Painter 共用，保证两边坐标一致。
class _ChartGeom {
  static const double topPad = 12.0;
  static const double bottomPad = 20.0;
  static const double rightPad = 12.0;

  /// 左侧内边距：显示 Y 轴标签时预留标签位
  static double leftInset(bool showYAxisLabels) => showYAxisLabels ? 44 : 12;

  /// 全体数据(主线+副线)的值域
  static (double min, double max) range(
      List<double> values, List<double>? secondary) {
    final all = <double>[...values];
    if (secondary != null && secondary.isNotEmpty) all.addAll(secondary);
    if (all.isEmpty) return (0, 0);
    return (all.reduce(math.min), all.reduce(math.max));
  }

  static double yFor(
      double v, double min, double span, double height) {
    if (span == 0) return height / 2;
    final t = (v - min) / span;
    return topPad + (1 - t) * (height - topPad - bottomPad);
  }

  static List<Offset> pointsFor(
      List<double> values, (double, double) range, Size size, bool yAxis) {
    final (minV, maxV) = range;
    final span = (maxV - minV).abs();
    final left = leftInset(yAxis);
    final dx = (size.width - left - rightPad) / (values.length - 1).clamp(1, 999);
    return [
      for (int i = 0; i < values.length; i++)
        Offset(left + i * dx, yFor(values[i], minV, span, size.height)),
    ];
  }
}

/// 单调三次插值(Fritsch–Carlson)：平滑且不在数据点间 overshoot。
Path _smoothPath(List<Offset> pts) {
  final path = Path()..moveTo(pts.first.dx, pts.first.dy);
  final n = pts.length;
  if (n == 2) {
    path.lineTo(pts[1].dx, pts[1].dy);
    return path;
  }
  final slopes = List<double>.filled(n - 1, 0);
  for (int i = 0; i < n - 1; i++) {
    final ddx = pts[i + 1].dx - pts[i].dx;
    slopes[i] = ddx == 0 ? 0 : (pts[i + 1].dy - pts[i].dy) / ddx;
  }
  final tangents = List<double>.filled(n, 0);
  tangents[0] = slopes.first;
  tangents[n - 1] = slopes.last;
  for (int i = 1; i < n - 1; i++) {
    tangents[i] =
        (slopes[i - 1] * slopes[i] <= 0) ? 0 : (slopes[i - 1] + slopes[i]) / 2;
  }
  for (int i = 0; i < n - 1; i++) {
    if (slopes[i] == 0) {
      tangents[i] = 0;
      tangents[i + 1] = 0;
      continue;
    }
    final a = tangents[i] / slopes[i];
    final b = tangents[i + 1] / slopes[i];
    final s = a * a + b * b;
    if (s > 9) {
      final t = 3 / math.sqrt(s);
      tangents[i] = t * a * slopes[i];
      tangents[i + 1] = t * b * slopes[i];
    }
  }
  for (int i = 0; i < n - 1; i++) {
    final seg = pts[i + 1].dx - pts[i].dx;
    path.cubicTo(
      pts[i].dx + seg / 3,
      pts[i].dy + tangents[i] * seg / 3,
      pts[i + 1].dx - seg / 3,
      pts[i + 1].dy - tangents[i + 1] * seg / 3,
      pts[i + 1].dx,
      pts[i + 1].dy,
    );
  }
  return path;
}

class _LinePainter extends CustomPainter {
  final List<double> values;
  final List<double>? secondaryValues;
  final Color? secondaryColor;
  final List<String> xLabels;
  final int? highlightIndex;
  final bool whiteBg;
  final bool showGrid;
  final bool showDots;
  final bool annotate;
  final bool hideAmounts;
  final Color themeColor;
  final double lineWidth;
  final double dotRadius;
  final double cornerRadius;
  final double xLabelFontSize;
  final double yLabelFontSize;
  final bool isDark;
  final bool minimal;
  final bool smooth;
  final bool showYAxisLabels;
  final bool isChineseLocale;
  final int? tappedIndex;

  _LinePainter({
    required this.values,
    this.secondaryValues,
    this.secondaryColor,
    required this.xLabels,
    required this.highlightIndex,
    required this.whiteBg,
    required this.showGrid,
    required this.showDots,
    required this.annotate,
    required this.hideAmounts,
    required this.themeColor,
    this.lineWidth = 2.0,
    this.dotRadius = 2.5,
    this.cornerRadius = 12,
    this.xLabelFontSize = 10,
    this.yLabelFontSize = 10,
    this.isDark = false,
    this.minimal = false,
    this.smooth = false,
    this.showYAxisLabels = false,
    this.isChineseLocale = true,
    this.tappedIndex,
  });

  // 获取主文字颜色（暗黑模式感知）
  Color get primaryTextColor =>
      isDark ? Colors.white : PiggyTokens.primaryTextStatic;

  // 获取次要文字颜色（暗黑模式感知）
  Color get secondaryTextColor =>
      isDark ? Colors.white70 : PiggyTokens.secondaryTextStatic;

  @override
  void paint(Canvas canvas, Size size) {
    final left = _ChartGeom.leftInset(showYAxisLabels);

    // 背景:minimal 模式不画(sparkline 嵌入卡片内,避免卡中卡)
    if (!minimal) {
      final rect = Offset.zero & size;
      final bgPaint =
          Paint()..color = whiteBg ? Colors.white : PiggyTokens.dividerStatic;
      canvas.drawRRect(
          RRect.fromRectAndRadius(rect, Radius.circular(cornerRadius)),
          bgPaint);
    }

    // 网格（可选）
    if (showGrid) {
      final gridPaint = Paint()
        ..color = PiggyTokens.dividerStatic
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1;
      const rows = 4;
      for (int i = 1; i <= rows; i++) {
        final y = size.height * i / (rows + 1);
        canvas.drawLine(
            Offset(left, y), Offset(size.width - 8, y), gridPaint);
      }
    }

    if (values.isEmpty) return;

    // 数据归一化 - 包含所有值（包括0）用于正确的Y轴缩放
    final (minV, maxV) = _ChartGeom.range(values, secondaryValues);

    // 计算主线非零值的平均值，用于平均线绘制
    final nonZeroVals = values.where((v) => v != 0).toList();
    final avgV = nonZeroVals.isEmpty
        ? 0.0
        : nonZeroVals.reduce((a, b) => a + b) / nonZeroVals.length;

    // 计算副线非零值的平均值和索引
    final secondaryNonZeroVals = secondaryValues == null
        ? <double>[]
        : secondaryValues!.where((v) => v != 0).toList();
    final avgSecondaryV = secondaryNonZeroVals.isEmpty
        ? 0.0
        : secondaryNonZeroVals.reduce((a, b) => a + b) /
            secondaryNonZeroVals.length;

    final span = (maxV - minV).abs();
    const topPadding = _ChartGeom.topPad;
    const bottomPadding = _ChartGeom.bottomPad;
    double yFor(double v) => _ChartGeom.yFor(v, minV, span, size.height);

    // 为所有点生成坐标，包括零值点，确保线条连续
    final allPoints =
        _ChartGeom.pointsFor(values, (minV, maxV), size, showYAxisLabels);

    // 收集非零点的索引，用于绘制圆点和标注
    final nzIndices = <int>[];
    for (int i = 0; i < values.length; i++) {
      if (values[i] != 0) nzIndices.add(i);
    }

    final line = Paint()
      ..color = themeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = lineWidth
      ..isAntiAlias = true;

    // 绘制连续的折线，包括所有点（包括零值点）
    if (allPoints.length >= 2) {
      if (smooth) {
        canvas.drawPath(_smoothPath(allPoints), line);
      } else {
        final path = Path()..moveTo(allPoints.first.dx, allPoints.first.dy);
        for (int i = 1; i < allPoints.length; i++) {
          path.lineTo(allPoints[i].dx, allPoints[i].dy);
        }
        canvas.drawPath(path, line);
      }
    }

    // 绘制第二条线（如果有）
    if (secondaryValues != null &&
        secondaryValues!.isNotEmpty &&
        secondaryColor != null) {
      final secondaryAllPoints = _ChartGeom.pointsFor(
          secondaryValues!, (minV, maxV), size, showYAxisLabels);

      final secondaryNzIndices = <int>[];
      for (int i = 0; i < secondaryValues!.length; i++) {
        if (secondaryValues![i] != 0) secondaryNzIndices.add(i);
      }

      final secondaryLine = Paint()
        ..color = secondaryColor!
        ..style = PaintingStyle.stroke
        ..strokeWidth = lineWidth
        ..isAntiAlias = true;

      if (secondaryAllPoints.length >= 2) {
        if (smooth) {
          canvas.drawPath(_smoothPath(secondaryAllPoints), secondaryLine);
        } else {
          final secondaryPath = Path()
            ..moveTo(secondaryAllPoints.first.dx, secondaryAllPoints.first.dy);
          for (int i = 1; i < secondaryAllPoints.length; i++) {
            secondaryPath.lineTo(
                secondaryAllPoints[i].dx, secondaryAllPoints[i].dy);
          }
          canvas.drawPath(secondaryPath, secondaryLine);
        }
      }

      if (showDots) {
        final secondaryDot = Paint()..color = secondaryColor!;
        // 只在非零值点绘制圆点
        for (final i in secondaryNzIndices) {
          canvas.drawCircle(secondaryAllPoints[i], dotRadius, secondaryDot);
        }
      }
    }

    if (showDots) {
      final dot = Paint()..color = themeColor;
      // 只在非零值点绘制圆点
      for (final i in nzIndices) {
        canvas.drawCircle(allPoints[i], dotRadius, dot);
      }
    }

    // 点按高亮圆环
    if (tappedIndex != null && tappedIndex! < allPoints.length) {
      final ringPaint = Paint()
        ..color = themeColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2;
      canvas.drawCircle(allPoints[tappedIndex!], dotRadius + 3.5, ringPaint);
      final fillPaint = Paint()..color = themeColor;
      canvas.drawCircle(allPoints[tappedIndex!], dotRadius + 0.5, fillPaint);
    }

    // 左侧Y轴线（minimal 模式不画）
    if (!minimal) {
      final axisPaint = Paint()
        ..color = PiggyTokens.dividerStatic
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(left, topPadding),
          Offset(left, size.height - bottomPadding), axisPaint);
    }

    // Y 轴大金额缩写标签（4 档，右对齐于标签位）
    if (showYAxisLabels && span > 0) {
      final labelStyle = TextStyle(
          fontSize: yLabelFontSize - 1, color: secondaryTextColor);
      for (int i = 0; i <= 4; i++) {
        final v = minV + span * i / 4;
        final tp = TextPainter(
          text: TextSpan(
              text: hideAmounts
                  ? '**'
                  : formatCompactAxis(v, isChinese: isChineseLocale),
              style: labelStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: left - 8);
        final y = (yFor(v) - tp.height / 2)
            .clamp(topPadding, size.height - bottomPadding - tp.height);
        tp.paint(canvas, Offset(left - 6 - tp.width, y));
      }
    }

    // 主线平均线（虚线，minimal 模式不画）
    if (!minimal) {
      final avgY = yFor(avgV);
      final avgLinePaint = Paint()
        ..color = PiggyTokens.secondaryTextStatic.withValues(alpha: 0.55)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      _drawDashedLine(
          canvas, Offset(left, avgY), Offset(size.width - 8, avgY), avgLinePaint,
          dashWidth: 6, gapWidth: 4);
    }

    // 副线平均线（虚线，副线色）
    if (secondaryValues != null &&
        secondaryValues!.isNotEmpty &&
        secondaryColor != null) {
      final avgSecY = yFor(avgSecondaryV);
      final avgSecLinePaint = Paint()
        ..color = secondaryColor!.withValues(alpha: 0.55)
        ..strokeWidth = 1.0
        ..style = PaintingStyle.stroke;
      _drawDashedLine(canvas, Offset(left, avgSecY),
          Offset(size.width - 8, avgSecY), avgSecLinePaint,
          dashWidth: 6, gapWidth: 4);
    }

    // 所有非零点数值标注
    if (annotate) {
      // 主线标注
      final textStyle =
          TextStyle(fontSize: yLabelFontSize - 1, color: primaryTextColor);
      for (final i in nzIndices) {
        final displayText = hideAmounts ? '**' : _fmt(values[i]);
        final tp = TextPainter(
          text: TextSpan(text: displayText, style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 60);
        final pos = allPoints[i] + const Offset(0, -10);
        tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height));
      }
      // 副线标注
      if (secondaryValues != null &&
          secondaryValues!.isNotEmpty &&
          secondaryColor != null) {
        final secPoints = _ChartGeom.pointsFor(
            secondaryValues!, (minV, maxV), size, showYAxisLabels);
        for (int i = 0; i < secondaryValues!.length; i++) {
          final v = secondaryValues![i];
          if (v == 0) continue;
          final displayText = hideAmounts ? '**' : _fmt(v);
          final pos = secPoints[i] + const Offset(0, -10);
          final tp = TextPainter(
            text: TextSpan(
                text: displayText,
                style: TextStyle(
                    fontSize: yLabelFontSize - 1, color: secondaryColor)),
            textDirection: TextDirection.ltr,
          )..layout(maxWidth: 60);
          tp.paint(canvas, Offset(pos.dx - tp.width / 2, pos.dy - tp.height));
        }
      }
    }

    // X 轴标签（保持原始标签与索引）
    if (xLabels.isNotEmpty) {
      final baseStyle =
          TextStyle(fontSize: xLabelFontSize, color: secondaryTextColor);
      final hiStyle = TextStyle(
          fontSize: xLabelFontSize,
          color: primaryTextColor,
          fontWeight: FontWeight.w600);
      final n = xLabels.length;
      int step = (n / 8).ceil();
      if (step < 1) step = 1;
      for (int i = 0; i < n; i += step) {
        final lbl = xLabels[i];
        final tp = TextPainter(
          text: TextSpan(
              text: lbl,
              style: (highlightIndex != null && i == highlightIndex)
                  ? hiStyle
                  : baseStyle),
          textDirection: TextDirection.ltr,
        )..layout(maxWidth: 60);
        final dxi =
            (i / (n - 1).clamp(1, 999)) * (size.width - left - 12) + left;
        tp.paint(
            canvas, Offset(dxi - tp.width / 2, size.height - tp.height - 2));
      }
    }
  }

  String _fmt(double v) =>
      formatCompactAxis(v, isChinese: isChineseLocale);

  @override
  bool shouldRepaint(covariant _LinePainter oldDelegate) {
    return oldDelegate.values != values ||
        oldDelegate.xLabels != xLabels ||
        oldDelegate.highlightIndex != highlightIndex ||
        oldDelegate.whiteBg != whiteBg ||
        oldDelegate.showGrid != showGrid ||
        oldDelegate.showDots != showDots ||
        oldDelegate.annotate != annotate ||
        oldDelegate.isDark != isDark ||
        oldDelegate.minimal != minimal ||
        oldDelegate.smooth != smooth ||
        oldDelegate.showYAxisLabels != showYAxisLabels ||
        oldDelegate.isChineseLocale != isChineseLocale ||
        oldDelegate.tappedIndex != tappedIndex;
  }
}

void _drawDashedLine(Canvas canvas, Offset p1, Offset p2, Paint paint,
    {double dashWidth = 5, double gapWidth = 3}) {
  final total = (p2 - p1).distance;
  final dir = (p2 - p1) / total;
  double drawn = 0;
  while (drawn < total) {
    final start = p1 + dir * drawn;
    final end = p1 + dir * (drawn + dashWidth).clamp(0, total);
    canvas.drawLine(start, end, paint);
    drawn += dashWidth + gapWidth;
  }
}
