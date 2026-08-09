import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

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
