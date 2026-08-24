import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

/// 图表点按气泡锚定布局参数（折线图 / 柱状图共用）。
///
/// 统一「全部趋势」折线卡与「支出趋势」柱状卡的气泡位置规则：
/// - 水平：气泡中心对齐数据点 x，并 clamp 在图表内（±0.72）
/// - 垂直：默认悬浮在数据点上方 [gap] 处；数据点贴近顶部时翻转到点下方；
///   底部留出边距避免被卡片裁切
({double alignX, double top}) chartTooltipLayout({
  required Offset anchor,
  required Size chartSize,
}) {
  final alignX = ((anchor.dx / chartSize.width) * 2 - 1).clamp(-0.72, 0.72);
  // 单行 11px 文案气泡的估算高度（fontSize 11 + 上下 padding 5×2）
  const bubbleHeight = 26.0;
  const gap = 10.0;
  double top = anchor.dy - bubbleHeight - gap;
  if (top < 4) {
    // 数据点贴近图表顶部：气泡翻到点下方（偏移避开高亮圆环）
    top = anchor.dy + gap;
  }
  final maxTop = chartSize.height - bubbleHeight - 4;
  if (top > maxTop) top = math.max(4.0, maxTop);
  return (alignX: alignX, top: top);
}

/// 图表点按气泡（折线图 / 柱状图共用，样式统一）。
///
/// 主题色底、白字、圆角，参考收支报表的点按浮层样式。
class ChartTooltipBubble extends StatelessWidget {
  final String text;
  final Color color;

  const ChartTooltipBubble({super.key, required this.text, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color,
        // 与项目里 toast / popup menu / tag selector 等提示浮层一致：
        // 统一用 radiusLg，保持胶囊提示的视觉调性，避免 radiusXl 偏胶囊形。
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      child: Text(
        text,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
