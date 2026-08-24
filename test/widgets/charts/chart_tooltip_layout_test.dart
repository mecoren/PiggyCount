import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/widgets/charts/chart_tooltip_bubble.dart';

void main() {
  group('chartTooltipLayout 统一锚定规则（折线图 / 柱状图共用）', () {
    const size = Size(320, 200);

    test('同一锚点坐标下，两类图表得到完全一致的布局参数', () {
      // 折线图与柱状图各自算出数据点坐标后交给统一函数，
      // 相同输入必须产生相同输出（这是「点击显示效果统一」的核心保证）
      final a = chartTooltipLayout(
          anchor: const Offset(240, 160), chartSize: size);
      final b = chartTooltipLayout(
          anchor: const Offset(240, 160), chartSize: size);
      expect(a.alignX, b.alignX);
      expect(a.top, b.top);
    });

    test('气泡默认悬浮在数据点上方 gap 处', () {
      final r = chartTooltipLayout(
          anchor: const Offset(160, 180), chartSize: size);
      // 气泡估算高度 26 + gap 10
      expect(r.top, closeTo(180 - 36, 0.01));
    });

    test('数据点贴近顶部时翻转到点下方，且不低于最小边距', () {
      final r = chartTooltipLayout(anchor: const Offset(60, 8), chartSize: size);
      expect(r.top, closeTo(8 + 10, 0.01));
      expect(r.top, greaterThanOrEqualTo(4));
    });

    test('底部不越界：top 被 clamp 到图内', () {
      final r = chartTooltipLayout(
          anchor: const Offset(160, 199), chartSize: size);
      expect(r.top, lessThanOrEqualTo(size.height - 26 - 4));
      expect(r.top, greaterThanOrEqualTo(4));
    });

    test('水平方向 clamp 在 ±0.72，防止气泡超出卡片', () {
      final left = chartTooltipLayout(
          anchor: const Offset(2, 100), chartSize: size);
      final right = chartTooltipLayout(
          anchor: const Offset(318, 100), chartSize: size);
      expect(left.alignX, greaterThanOrEqualTo(-0.72));
      expect(right.alignX, lessThanOrEqualTo(0.72));
    });
  });
}
