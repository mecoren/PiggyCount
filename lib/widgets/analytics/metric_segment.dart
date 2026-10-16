import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import '../ui/segmented_control.dart';

/// 洞察页「统计口径条」的尺寸：轨道高 34（介于上方周/月/季度…的 38 与下方
/// 支出/收入/结余的 32 之间），段高 = 轨道高 - 上下内边距（与滑块分段控件的
/// 胶囊同样留 3）。
const double kMetricBarHeight = 34;
const double kMetricBarSegmentHeight =
    kMetricBarHeight - kPiggySegmentTrackInset * 2;

/// 口径条的最大宽度：两段等分后每段 96。宽度不能再跟着可用空间长下去 ——
/// 宽屏上两段都非默认时会出现一整条蓝，把标题行的视觉重心全抢走。
const double kMetricBarMaxWidth = 192;

/// 段与相邻段、段与轨道边之间的呼吸位。**做在段内、左右对称**：两段相邻时
/// 中间自然留 2+2，只有一段时胶囊的左右留白同样宽。
const double kMetricSegmentGap = 2;

/// 口径入口的两种形态。
enum MetricChipStyle {
  /// 独立描边胶囊：没有同屏分段控件可对齐的页面（区间报表 / 导出页）。
  pill,

  /// 轨道内的一段：洞察页标题行的「统计口径条」，与下方周/月/季度…的滑块
  /// 分段控件**同源**（同一个浅色轨道 + 主色胶囊表示「非默认口径」）——
  /// 各自画一套的话，同一屏里两个分段控件会像两个体系。
  segment,
}

/// 统计口径条里的一段：只有 [label]（非默认口径时再叠一层主色胶囊），点开
/// 对应口径的抽屉。
///
/// 2026-10-16 用户反馈「选完对应的文字后大小会变，而且好丑」，两处一起改：
///
/// 1. **段宽由调用方的 `Expanded` 等分给出**（本组件必须装在宽度有界的
///    `Row` 里），不再按内容自适应。旧实现每段宽度跟着文案长度走，外面套
///    `FittedBox(BoxFit.scaleDown)` 兜底，于是「记账金额」↔「水费」一换口径，
///    整条的等比缩放比例就跟着变（360dp 窄屏实测 0.48 ↔ 0.67），字号在
///    6dp / 8.7dp 之间跳 —— 尺寸跳动与「丑」都是它。等分后切口径只有文字与
///    底色变化，整条口径条纹丝不动。
/// 2. **不画图标**：tune / event 每段白吃 18dp 宽度，而段内文案本身自解释
///    （「记账金额」/「记账时间」/自定义字段名）；去掉后与下方纯文字的滑块
///    分段控件反而更同源。
///
/// 自定义字段名很长时按 [TextOverflow.ellipsis] 截断，**任何时候都不再整条
/// 缩放**（缩放的文字既不清晰，也与同屏其它控件的字号对不上）。
class MetricSegment extends StatelessWidget {
  const MetricSegment({
    super.key,
    required this.label,
    required this.active,
    required this.onTap,
  });

  final String label;

  /// 非默认口径：显示主色胶囊（与分段控件的选中段同款）。
  final bool active;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final fg = piggySegmentTextColor(context, selected: active);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kMetricSegmentGap),
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          height: kMetricBarSegmentHeight,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          alignment: Alignment.center,
          decoration: active
              ? piggySegmentPillDecoration(
                  context, PiggyTokens.primary(context))
              : null,
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: PiggyTextTokens.fs13,
              fontWeight: FontWeight.w500,
              color: fg,
            ),
          ),
        ),
      ),
    );
  }
}
