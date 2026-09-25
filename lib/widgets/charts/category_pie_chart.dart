import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/category_utils.dart';
import '../../data/db.dart' as db;
import '../biz/biz.dart';

/// 分类饼图条目
typedef PieCategoryItem = ({
  int? id,
  String name,
  db.Category? category,
  double total,
  List<({int id, db.Category category, String name, double total})>
      subCategories,
});

/// 分类占比环形图（donut，外置引线标签：名称 + 百分比）
class CategoryPieChart extends ConsumerStatefulWidget {
  final List<PieCategoryItem> data;
  final double sum;

  /// 选中扇区回调，返回分类索引（-1 表示取消选中）
  final ValueChanged<int>? onSectionTap;

  const CategoryPieChart({
    super.key,
    required this.data,
    required this.sum,
    this.onSectionTap,
  });

  @override
  ConsumerState<CategoryPieChart> createState() => _CategoryPieChartState();
}

class _CategoryPieChartState extends ConsumerState<CategoryPieChart> {
  int _touchedIndex = -1;

  /// 最多显示的扇区数（超出合并为「其他」）
  static const _maxSlices = 8;

  @override
  void didUpdateWidget(CategoryPieChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.data != widget.data) {
      _touchedIndex = -1;
    }
  }

  /// 将原始分类列表合并为 ≤ _maxSlices 条，多余归入「其他」
  List<({String name, double total, Color color, int originalIndex})>
      _buildSlices() {
    final sorted = List.generate(widget.data.length, (i) => i);
    sorted.sort((a, b) => widget.data[b].total.compareTo(widget.data[a].total));

    final slices =
        <({String name, double total, Color color, int originalIndex})>[];
    double otherTotal = 0;

    for (var i = 0; i < sorted.length; i++) {
      final idx = sorted[i];
      final item = widget.data[idx];
      if (item.total <= 0) continue;

      if (slices.length < _maxSlices) {
        slices.add((
          name: item.name,
          total: item.total,
          color: PiggyChartTokens
              .seriesColors[slices.length % PiggyChartTokens.seriesColors.length],
          originalIndex: idx,
        ));
      } else {
        otherTotal += item.total;
      }
    }

    if (otherTotal > 0) {
      slices.add((
        name: '_other_',
        total: otherTotal,
        color: PiggyTokens.textTertiary(context),
        originalIndex: -1,
      ));
    }

    return slices;
  }

  @override
  Widget build(BuildContext context) {
    if (widget.data.isEmpty || widget.sum <= 0) {
      return const SizedBox.shrink();
    }

    final slices = _buildSlices();
    if (slices.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);

    // 选中扇区的信息（显示在环形中心）
    final hasSelection = _touchedIndex >= 0 && _touchedIndex < slices.length;
    final selectedSlice = hasSelection ? slices[_touchedIndex] : null;

    return SizedBox(
      // 高度给外置标签留足上下边距：标签锚点在环外（见 badgePositionPercentageOffset），
      // 过矮会导致底部扇区的百分比文字被裁切
      height: 264,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // U4：读屏摘要。扇区与外置标签都是画出来的，不补这层
          // TalkBack/VoiceOver 对饼图无话可念（与柱状/折线图的
          // chartSeriesSemantics 同思路；饼图只暴露名称+占比，无金额可隐）。
          Positioned.fill(
            child: Semantics(
              label: [
                for (final s in slices)
                  '${s.name == "_other_" ? l10n.commonOther : CategoryUtils.getDisplayName(s.name, context)} '
                      '${(s.total / widget.sum * 100).toStringAsFixed(1)}%'
              ].join('，'),
            ),
          ),
          PieChart(
            PieChartData(
              pieTouchData: PieTouchData(
                touchCallback: (event, response) {
                  if (!event.isInterestedForInteractions ||
                      response == null ||
                      response.touchedSection == null) {
                    if (_touchedIndex != -1) {
                      setState(() => _touchedIndex = -1);
                      widget.onSectionTap?.call(-1);
                    }
                    return;
                  }
                  final idx = response.touchedSection!.touchedSectionIndex;
                  if (idx != _touchedIndex) {
                    setState(() => _touchedIndex = idx);
                    if (idx >= 0 && idx < slices.length) {
                      widget.onSectionTap?.call(slices[idx].originalIndex);
                    }
                  }
                },
              ),
              sectionsSpace: 2,
              centerSpaceRadius: 52,
              sections: List.generate(slices.length, (i) {
                final s = slices[i];
                final pct = (s.total / widget.sum * 100);
                final isTouched = i == _touchedIndex;
                final displayName = s.name == '_other_'
                    ? l10n.commonOther
                    : CategoryUtils.getDisplayName(s.name, context);
                return PieChartSectionData(
                  color: s.color,
                  value: s.total,
                  title: '',
                  radius: isTouched ? 40 : 32,
                  // 外置标签：名称 + 百分比（占比过小的扇区不标，避免拥挤）
                  showTitle: false,
                  badgeWidget: pct >= 4
                      ? _ExternalLabel(
                          name: displayName,
                          percent: pct,
                          color: s.color,
                          highlighted: isTouched,
                        )
                      : null,
                  // 标签锚点 = centerRadius + radius × offset。1.42 时标签
                  // 内缘恰好落在环外缘之外，百分比文字不再压在扇区色块上
                  // （1.28 时会与环体重叠导致看不清）
                  badgePositionPercentageOffset: 1.42,
                );
              }),
            ),
          ),
          // 环形中心：显示选中分类的名称和金额，或总金额
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                selectedSlice != null
                    ? (selectedSlice.name == '_other_'
                        ? l10n.commonOther
                        : CategoryUtils.getDisplayName(
                            selectedSlice.name, context))
                    : l10n.analyticsTotalAmount,
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: PiggyTokens.textTertiary(context),
                      fontSize: PiggyChartTokens.legendFontSize,
                    ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 2),
              AmountText(
                value: selectedSlice?.total ?? widget.sum,
                signed: false,
                useCompactFormat: true,
                style: TextStyle(
                  fontSize: PiggyChartTokens.centerValueFontSize,
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textPrimary(context),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 环形图外置标签：彩色圆点 + 名称 + 百分比
class _ExternalLabel extends StatelessWidget {
  final String name;
  final double percent;
  final Color color;
  final bool highlighted;

  const _ExternalLabel({
    required this.name,
    required this.percent,
    required this.color,
    required this.highlighted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 6,
              height: 6,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 3),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 64),
              child: Text(
                name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PiggyChartTokens.xLabelFontSize,
                  fontWeight:
                      highlighted ? FontWeight.w600 : FontWeight.w400,
                  color: PiggyTokens.textPrimary(context),
                ),
              ),
            ),
          ],
        ),
        Text(
          '${percent.toStringAsFixed(2)}%',
          // 百分比是关键信息：比名称略小但需高对比（此前 9px + textTertiary
          // 在浅色扇区上几乎看不清）
          style: TextStyle(
            fontSize: PiggyChartTokens.xLabelFontSize,
            fontWeight: FontWeight.w600,
            color: PiggyTokens.textSecondary(context),
          ),
        ),
      ],
    );
  }
}
