import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/savings_goal_progress.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/savings_goal/savings_goal_card.dart';
import '../../widgets/ui/ui.dart';
import '../budget/widgets/budget_progress_bar.dart';
import 'savings_goal_edit_page.dart';

/// 储蓄目标列表页（v53）。
///
/// 数据源单一：`savingsGoalProgressProvider`（目标 × 进度的解算结果）——
/// 页面不做金额计算，也不自己查账户余额（见 `lib/providers/savings_goal_providers.dart`）。
class SavingsGoalsPage extends ConsumerWidget {
  const SavingsGoalsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final itemsAsync = ref.watch(savingsGoalProgressProvider);
    final summary = ref.watch(savingsGoalSummaryProvider).value;
    final currencyCode =
        ref.watch(currentLedgerProvider).value?.currency ?? 'CNY';
    final items = itemsAsync.value ?? const <SavingsGoalWithProgress>[];

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.savingsGoalPageTitle,
        showBack: true,
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => showSavingsGoalFormBottomSheet(context),
        icon: const Icon(Icons.add_rounded),
        label: Text(l10n.savingsGoalAddTitle),
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          0,
          PiggyTokens.topScrollablePadding(context),
          0,
          96, // 给 FAB 留位
        ),
        children: [
          if (summary != null && summary.totalCount > 0)
            _SummaryCard(summary: summary, currencyCode: currencyCode),
          if (items.isEmpty && itemsAsync.hasValue)
            Padding(
              padding: EdgeInsets.only(
                top: 48.0.scaled(context, ref),
                left: 24.0.scaled(context, ref),
                right: 24.0.scaled(context, ref),
              ),
              child: AppEmpty(
                icon: Icons.savings_outlined,
                text: l10n.savingsGoalEmpty,
                subtext: l10n.savingsGoalEmptyHint,
              ),
            )
          else
            SectionCard(
              child: Column(
                children: [
                  for (var i = 0; i < items.length; i++) ...[
                    if (i > 0)
                      Divider(height: 1, color: PiggyTokens.divider(context)),
                    SavingsGoalCard(
                      item: items[i],
                      onTap: () => showSavingsGoalFormBottomSheet(
                        context,
                        goal: items[i].goal,
                      ),
                    ),
                  ],
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// 顶部汇总卡：总目标 / 总已存 / 总体进度 + 外币剔除提示。
///
/// **只汇总与账本本位币同币种的目标**（视图期没有可靠汇率，硬折会给出错误数字）；
/// 被剔除的外币目标数必须显式告诉用户，静默少算会被当成「App 算错了」。
class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.summary, required this.currencyCode});

  final SavingsGoalSummary summary;
  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final hide = ref.watch(hideAmountsProvider);
    final valueStyle = PiggyTextTokens.body(context).copyWith(
      fontWeight: FontWeight.w600,
      color: PiggyTokens.textPrimary(context),
    );

    Widget metric(String label, double value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: PiggyTextTokens.caption(context)),
            SizedBox(height: 2.0.scaled(context, ref)),
            AmountText(
              value: value,
              signed: false,
              showCurrency: true,
              currencyCode: currencyCode,
              useCompactFormat: true,
              hide: hide,
              style: valueStyle,
            ),
          ],
        );

    return SectionCard(
      child: Padding(
        padding: EdgeInsets.all(PiggyDimens.p8.scaled(context, ref)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: metric(l10n.savingsGoalTotalTarget, summary.totalTarget),
                ),
                Expanded(
                  child: metric(l10n.savingsGoalTotalSaved, summary.totalSaved),
                ),
              ],
            ),
            SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
            BudgetProgressBar(
              used: summary.totalSaved,
              budget: summary.totalTarget,
              showLabel: false,
              height: 10,
            ),
            if (summary.foreignCount > 0) ...[
              SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: PiggyTokens.warning(context),
                  ),
                  SizedBox(width: PiggyDimens.p4.scaled(context, ref)),
                  Expanded(
                    child: Text(
                      l10n.savingsGoalForeignExcluded(summary.foreignCount),
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: PiggyTokens.warning(context)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
