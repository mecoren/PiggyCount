import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/custom_field_stats_service.dart';
import '../../styles/tokens.dart';
import '../biz/amount_text.dart';
import '../charts/line_chart.dart';

/// 下钻目标（prd/custom_field_stats_fullchain F3「下钻即筛选」的载荷）。
///
/// 为什么不直接传「筛选条件对象」：阶段 3 的筛选模型尚未定型，本视图只承诺
/// 「点了哪个字段的哪个值/区间」；翻译成筛选条件是消费方（阶段 3）的事。
/// 形状即类型：值等值下钻与区间下钻语义不同（eq vs between），sealed 穷尽
/// 匹配让消费方必须显式处理两种。
sealed class FieldDrillTarget {
  const FieldDrillTarget({
    required this.fieldSyncId,
    required this.fieldName,
    required this.fieldType,
  });

  /// 目标字段定义 syncId。
  final String fieldSyncId;

  /// 字段名（消费方展示 chip 用，免反查定义）。
  final String fieldName;

  /// 字段类型（值标签规范化依赖它）。
  final String fieldType;
}

/// 值等值下钻（文本系值桶）：筛选「该字段 = value」。
final class FieldDrillValue extends FieldDrillTarget {
  const FieldDrillValue({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.value,
  });

  /// 值桶标签（与聚合桶键同源，已规范化展示）。
  final String value;
}

/// 区间下钻（金额型分布档）：筛选「该字段值 ∈ [lower, upper)」。
final class FieldDrillRange extends FieldDrillTarget {
  const FieldDrillRange({
    required super.fieldSyncId,
    required super.fieldName,
    required super.fieldType,
    required this.lower,
    required this.upper,
  });

  final num lower;

  /// null = 开区间上界（最高档「≥lower」）。
  final num? upper;
}

typedef FieldDrillDown = void Function(FieldDrillTarget target);

/// 分类型字段统计内容区（金额指标/日期趋势/值排行），不含页面铬。
///
/// 渲染分发用 sealed switch 穷尽匹配（R3 约定：不加 default）——新增字段
/// 形状时这里编译报错，强制补全渲染分支。
class FieldStatsDetailView extends StatelessWidget {
  const FieldStatsDetailView({
    super.key,
    required this.stats,
    required this.dim,
    this.onDrillDown,
  });

  /// 当前字段的分类型统计结果。
  final FieldStats stats;

  /// 排序与金额展示维度：'income' | 'expense'（沿用洞察卡 `dim` 约定）。
  final String dim;

  /// 下钻回调；null = 不可点（预览场景）。
  final FieldDrillDown? onDrillDown;

  @override
  Widget build(BuildContext context) {
    return switch (stats) {
      AmountFieldStats s => _AmountStatsView(stats: s, onDrillDown: onDrillDown),
      DateFieldStats s => _DateStatsView(stats: s, dim: dim),
      TextLikeFieldStats s =>
        _TextLikeStatsView(stats: s, dim: dim, onDrillDown: onDrillDown),
    };
  }
}

/// 填写率行（三种形状共用）：填写率 + 已填写笔数。
class FillRateRow extends StatelessWidget {
  const FillRateRow({super.key, required this.stats});

  final FieldStats stats;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Row(
      children: [
        Text(l10n.customFieldAnalysisFillRate,
            style: PiggyTextTokens.caption(context)
                .copyWith(color: PiggyTokens.textTertiary(context))),
        const SizedBox(width: 8),
        Text(
          // 项目百分比既有口径：一位小数（海报/持仓卡同款 toStringAsFixed(1)）。
          '${(stats.fillRate * 100).toStringAsFixed(1)}%',
          style: PiggyTextTokens.strongTitle(context),
        ),
        const SizedBox(width: 12),
        Text(l10n.customFieldFilledCount(stats.filledCount),
            style: PiggyTextTokens.caption(context)
                .copyWith(color: PiggyTokens.textTertiary(context))),
      ],
    );
  }
}

/// 金额型：四指标 + 5 档恒定分布（分布行可点 → 区间下钻）。
class _AmountStatsView extends StatelessWidget {
  const _AmountStatsView({required this.stats, this.onDrillDown});

  final AmountFieldStats stats;
  final FieldDrillDown? onDrillDown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final metrics = [
      (l10n.customFieldStatSum, stats.valueSum),
      (l10n.customFieldStatAvg, stats.valueAvg),
      (l10n.customFieldStatMin, stats.valueMin),
      (l10n.customFieldStatMax, stats.valueMax),
    ];
    final maxCount =
        stats.dist.fold<int>(0, (m, b) => b.count > m ? b.count : m);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            for (final (label, value) in metrics)
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label,
                        style: PiggyTextTokens.caption(context).copyWith(
                            color: PiggyTokens.textTertiary(context))),
                    const SizedBox(height: 2),
                    AmountText(
                      value: value,
                      signed: false,
                      showCurrency: true,
                      useCompactFormat: true,
                      style: PiggyTextTokens.strongTitle(context),
                    ),
                  ],
                ),
              ),
          ],
        ),
        const SizedBox(height: 14),
        Text(l10n.customFieldAnalysisValueDistribution,
            style: PiggyTextTokens.strongTitle(context)),
        const SizedBox(height: 6),
        for (final b in stats.dist)
          _DistRow(
            label: AmountFieldStats.distLabel(b.lower, b.upper),
            count: b.count,
            maxCount: maxCount,
            onTap: onDrillDown == null
                ? null
                : () => onDrillDown!(FieldDrillRange(
                      fieldSyncId: stats.fieldSyncId,
                      fieldName: stats.name,
                      fieldType: stats.fieldType,
                      lower: b.lower,
                      upper: b.upper,
                    )),
          ),
      ],
    );
  }
}

/// 分布档行：标签 + 笔数 + 迷你条（条形只表达 count，金额不进条）。
class _DistRow extends StatelessWidget {
  const _DistRow({
    required this.label,
    required this.count,
    required this.maxCount,
    this.onTap,
  });

  final String label;
  final int count;
  final int maxCount;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fraction = maxCount == 0 ? 0.0 : count / maxCount;
    // 可点分布档 = 新增交互元素：按项目约束补 Semantics（读屏报「按钮」），
    // 内部视觉子节点 ExcludeSemantics 收拢为单条朗读，避免碎碎念逐字播报。
    return Semantics(
      button: true,
      label: '$label ${l10n.analyticsTxCountShort(count)}',
      child: ExcludeSemantics(
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 5),
            child: Row(
              children: [
                SizedBox(width: 96, child: Text(label, style: PiggyTextTokens.body(context))),
                Expanded(
                  child: _MiniBar(fraction: fraction),
                ),
                const SizedBox(width: 10),
                Text(l10n.analyticsTxCountShort(count),
                    style: PiggyTextTokens.caption(context)
                        .copyWith(color: PiggyTokens.textTertiary(context))),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 迷你占比条（静态宽度因子，无动画/定时器——widget 测试零 pending Timer）。
class _MiniBar extends StatelessWidget {
  const _MiniBar({required this.fraction});

  final double fraction;

  @override
  Widget build(BuildContext context) {
    final primary = PiggyTokens.primary(context);
    return SizedBox(
      height: 6,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: fraction.clamp(0.0, 1.0),
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: primary,
                borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 日期型：按月趋势折线（直接消费月序列，UI 层零日期解析）。
class _DateStatsView extends StatelessWidget {
  const _DateStatsView({required this.stats, required this.dim});

  final DateFieldStats stats;
  final String dim;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final values = [
      for (final m in stats.monthly) dim == 'income' ? m.income : m.expense,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.customFieldAnalysisMonthlyTrend,
            style: PiggyTextTokens.strongTitle(context)),
        const SizedBox(height: 8),
        SizedBox(
          // LineChart 内部 LayoutBuilder 需有界高度（ListView 里裸放会无界布局报错）。
          height: 200,
          // RepaintBoundary：图表重绘不扩散到整页（洞察页同款）。
          child: RepaintBoundary(
            child: LineChart(
              values: values,
              xLabels: [for (final m in stats.monthly) m.month],
              highlightIndex: null,
              onSwipeLeft: () {},
              onSwipeRight: () {},
              showHint: false,
              themeColor: PiggyTokens.primary(context),
              interactive: false,
              showYAxisLabels: true,
              isChineseLocale:
                  Localizations.localeOf(context).languageCode == 'zh',
            ),
          ),
        ),
      ],
    );
  }
}

/// 文本系（text/singleSelect/multiSelect 共用）：值排行 + 笔数 + 占比（可点 →
/// 值下钻）。
class _TextLikeStatsView extends StatelessWidget {
  const _TextLikeStatsView({
    required this.stats,
    required this.dim,
    this.onDrillDown,
  });

  final TextLikeFieldStats stats;
  final String dim;
  final FieldDrillDown? onDrillDown;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.customFieldAnalysisValueRank,
            style: PiggyTextTokens.strongTitle(context)),
        const SizedBox(height: 6),
        for (final v in stats.values)
          // 可点值排行行 = 新增下钻交互元素：按项目约束补 Semantics
          //（读屏报「按钮」+ 值名），内部子节点收拢为单条朗读。
          Semantics(
            button: true,
            label: '${v.label} ${l10n.analyticsTxCountShort(v.count)}',
            child: ExcludeSemantics(
              child: InkWell(
            onTap: onDrillDown == null
                ? null
                : () => onDrillDown!(FieldDrillValue(
                      fieldSyncId: stats.fieldSyncId,
                      fieldName: stats.name,
                      fieldType: stats.fieldType,
                      value: v.label,
                    )),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Row(
                children: [
                  Expanded(
                    child: Text(v.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PiggyTextTokens.body(context)),
                  ),
                  const SizedBox(width: 8),
                  Text(l10n.analyticsTxCountShort(v.count),
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: PiggyTokens.textTertiary(context))),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 52,
                    child: Text(
                      // 占比与海报同口径：一位小数百分比。
                      '${(v.ratio * 100).toStringAsFixed(1)}%',
                      textAlign: TextAlign.right,
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: PiggyTokens.textTertiary(context)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  AmountText(
                    value: dim == 'income' ? v.income : v.expense,
                    signed: false,
                    showCurrency: true,
                    useCompactFormat: true,
                    style: PiggyTextTokens.strongTitle(context),
                  ),
                ],
              ),
            ),
              ),
            ),
          ),
      ],
    );
  }
}
