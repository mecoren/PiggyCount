import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../pages/budget/widgets/budget_progress_bar.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../biz/biz.dart';

/// 单个储蓄目标的卡片（v53）。
///
/// 进度条直接复用预算的 [BudgetProgressBar]（语义同构：「已用 / 总量 + 分档配色
/// + clamp」），避免出现第二套配色与高度口径；本卡片不做任何金额计算 ——
/// 解算全在 `savingsGoalProgressProvider`（单一口径）。
class SavingsGoalCard extends ConsumerWidget {
  const SavingsGoalCard({super.key, required this.item, this.onTap});

  final SavingsGoalWithProgress item;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final goal = item.goal;
    final progress = item.progress;
    final currency = goal.currency;
    final hide = ref.watch(hideAmountsProvider);
    final primary = ref.watch(primaryColorProvider);
    final muted = PiggyTextTokens.caption(context);

    final source = item.tracksAccount
        ? '${l10n.savingsGoalSourceAccount} · ${item.accountName}'
        : l10n.savingsGoalSourceManual;

    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: PiggyDimens.p16,
          vertical: 14.0.scaled(context, ref),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    goal.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PiggyTextTokens.body(context).copyWith(
                      fontWeight: FontWeight.w600,
                      color: PiggyTokens.textPrimary(context),
                    ),
                  ),
                ),
                if (progress.achieved)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: primary.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                    ),
                    child: Text(
                      l10n.savingsGoalAchieved,
                      style: TextStyle(
                        fontSize: PiggyTextTokens.fs12,
                        color: primary,
                      ),
                    ),
                  ),
              ],
            ),
            SizedBox(height: 4.0.scaled(context, ref)),
            Text(source, style: muted),
            SizedBox(height: 12.0.scaled(context, ref)),
            BudgetProgressBar(
              used: progress.saved,
              budget: progress.target,
              showLabel: false,
              height: 8,
              // 目标型进度：达成/超额是好事，不套用预算的「超支红」危险档位。
              positiveOverflow: true,
            ),
            SizedBox(height: 8.0.scaled(context, ref)),
            Row(
              children: [
                Flexible(
                  child: AmountText(
                    value: progress.saved,
                    signed: false,
                    showCurrency: true,
                    currencyCode: currency,
                    useCompactFormat: true,
                    hide: hide,
                    style: muted,
                  ),
                ),
                Text(' / ', style: muted),
                Flexible(
                  child: AmountText(
                    value: progress.target,
                    signed: false,
                    showCurrency: true,
                    currencyCode: currency,
                    useCompactFormat: true,
                    hide: hide,
                    style: muted,
                  ),
                ),
                const Spacer(),
                if (!progress.achieved)
                  Flexible(
                    child: AmountText(
                      value: progress.remaining,
                      signed: false,
                      showCurrency: true,
                      currencyCode: currency,
                      useCompactFormat: true,
                      hide: hide,
                      style: muted.copyWith(color: primary),
                    ),
                  ),
              ],
            ),
            if (progress.estimatedDate != null) ...[
              SizedBox(height: 6.0.scaled(context, ref)),
              Text(
                l10n.savingsGoalEstimatedDate(
                  _formatDate(progress.estimatedDate!),
                ),
                style: muted,
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// yyyy-MM-dd（与项目其它日期展示同款）。
  String _formatDate(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
}
