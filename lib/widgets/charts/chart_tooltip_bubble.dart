import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 趋势图读屏摘要（折线 / 柱状共用）。
///
/// 图是画出来的：TalkBack/VoiceOver 对着柱状图只能念出坐标轴上那几个采样的
/// 标签，等于没有信息。这里把整条序列摊成一句话，调用方把它放进
/// `Semantics(label:)`，同时给轴标签加 `excludeSemantics`（避免摘要与散标签混着念）。
///
/// ponytail: 全量摊平，31 个点的月视图约 20~30 秒朗读。升级点是逐点语义节点
/// （fl_chart 的 `BarTouchData`/自绘侧发 `SemanticsData`），让读屏能一柱一柱滑。
String chartSeriesSemantics(
  BuildContext context, {
  required List<String> xLabels,
  required List<List<double>> series,
  required bool hideAmounts,
}) {
  final parts = <String>[
    for (var i = 0; i < xLabels.length; i++)
      hideAmounts
          ? xLabels[i]
          : '${xLabels[i]} ${[
              for (final s in series)
                if (i < s.length) s[i].toStringAsFixed(2)
            ].join(' / ')}'
  ];
  return AppLocalizations.of(context)
      .semanticsChartSeries(xLabels.length, parts.join(', '));
}

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
  // 单行文案气泡的估算高度（tooltipFontSize(11) + 上下 padding 5×2）
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
          fontSize: PiggyChartTokens.tooltipFontSize,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
