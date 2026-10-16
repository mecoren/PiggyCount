import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/analytics_amount_metric.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../ui/ui.dart';

/// 金额口径 chip：显示当前口径，点开底部抽屉单选（记账金额 / 原始金额）。
///
/// 为什么是 chip + 抽屉而不是再压一行分段胶囊：洞察页头部已有「档位 / 周期 /
/// 收支」三行，第四行常驻会再吃掉一截首屏高度；而这个口径是低频切换项，收进
/// 抽屉即可（与项目「选择器抽屉统一口径」一致，走 [showPiggyOptionSheet]）。
///
/// 口径值存在全局 [analyticsAmountMetricProvider]（持久化），所以洞察页、
/// 区间报表、导出页上的同一枚 chip 改的是同一个值 —— 读数到哪都一致。
class AmountMetricChip extends ConsumerWidget {
  const AmountMetricChip({super.key, this.compact = true});

  /// 紧凑档：高度 30（与洞察页导航行的圆形箭头 / 收支胶囊齐平）。
  /// 传 false 时高度 36，用于报表页的常规行。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final metric = ref.watch(analyticsAmountMetricProvider);
    final isDefault = metric == AnalyticsAmountMetric.recorded;
    // 非默认口径用主色强调：让「数字不是按记账金额算的」一眼可见。
    final fg = isDefault
        ? PiggyTokens.textSecondary(context)
        : PiggyTokens.primary(context);

    return Material(
      color: PiggyTokens.surface(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        side: BorderSide(color: PiggyTokens.borderThemed(context), width: 1.4),
      ),
      child: InkWell(
        key: const Key('amount-metric-chip'),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        onTap: () => showPiggyOptionSheet<AnalyticsAmountMetric>(
          context: context,
          title: l10n.analyticsAmountMetricTitle,
          selected: metric,
          options: [
            PiggyOptionSheetItem(
              value: AnalyticsAmountMetric.recorded,
              title: l10n.analyticsAmountMetricRecorded,
              desc: l10n.analyticsAmountMetricRecordedDesc,
              icon: Icons.account_balance_wallet_outlined,
            ),
            PiggyOptionSheetItem(
              value: AnalyticsAmountMetric.original,
              title: l10n.analyticsAmountMetricOriginal,
              desc: l10n.analyticsAmountMetricOriginalDesc,
              icon: Icons.receipt_long_outlined,
            ),
          ],
          onSelected: (v) =>
              ref.read(analyticsAmountMetricProvider.notifier).state = v,
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: SizedBox(
            height: compact ? 30 : 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 14, color: fg),
                const SizedBox(width: 4),
                Text(
                  _label(l10n, metric),
                  style: TextStyle(
                    fontSize: compact
                        ? PiggyTextTokens.fs12
                        : PiggyTextTokens.fs13,
                    color: fg,
                    fontWeight: isDefault ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
                Icon(Icons.expand_more, size: 15, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  static String _label(
          AppLocalizations l10n, AnalyticsAmountMetric metric) =>
      switch (metric) {
        AnalyticsAmountMetric.recorded => l10n.analyticsAmountMetricRecorded,
        AnalyticsAmountMetric.original => l10n.analyticsAmountMetricOriginal,
      };
}

/// 非默认口径时的口径说明行（内容区顶部的小字）。
///
/// 只在 [AnalyticsAmountMetric.original] 下出现：原始金额口径有一条必须说明的
/// 兜底语义（未填写即按记账金额计），不写清楚用户会以为「数字变小 = 丢数据」。
/// 默认口径下返回零高占位，不占版面。
class AmountMetricNote extends ConsumerWidget {
  const AmountMetricNote({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 0),
  });

  /// 外层内边距：页面级独立一行用默认值；嵌在行内（如区间报表的口径行）
  /// 传 `EdgeInsets.only(left: 8)`。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final metric = ref.watch(analyticsAmountMetricProvider);
    if (metric == AnalyticsAmountMetric.recorded) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          AppLocalizations.of(context).analyticsAmountMetricNote,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PiggyTextTokens.caption(context),
        ),
      ),
    );
  }
}
