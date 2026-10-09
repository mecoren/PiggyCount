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
      floatingActionButton: FloatingActionButton(
        onPressed: () => showSavingsGoalFormBottomSheet(context),
        // 只要一个「+」按钮，不带文字；按钮名走 tooltip（长按提示 + 无障碍朗读）
        tooltip: l10n.savingsGoalAddTitle,
        child: const Icon(Icons.add_rounded),
      ),
      // 汇总卡**固定**在标题栏下方，只有明细区滚动：原先整页共用一个 ListView，
      // 往下滚时汇总卡会被标题栏切掉（总进度看不到），与「总览常驻」的预期不符。
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(
              // 标题栏下方留出呼吸位（与预算页口径一致），否则首卡顶边贴住标题栏下缘
              top: PiggyTokens.topScrollablePadding(
                context,
                extra: PiggyDimens.p8,
              ),
            ),
            child: Column(
              children: [
                if (summary != null && summary.totalCount > 0) ...[
                  _SummaryCard(summary: summary, currencyCode: currencyCode),
                  // SectionCard 只带水平 margin，卡与卡的纵向间距要在这里补，
                  // 否则汇总卡与列表卡上下贴死（间距口径取预算页的 12）
                  SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
                ],
              ],
            ),
          ),
          Expanded(
            child: ListView(
              padding: EdgeInsets.only(
                // 给 FAB 留位 + 底部安全区
                bottom: 96 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
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
                            Divider(
                                height: 1,
                                color: PiggyTokens.divider(context)),
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
    // 汇总金额用 boldTitle（18 / w700，令牌里「大额数字」档）：比目标卡的
    // body 金额（14）大一档，汇总卡整体看起来才是「总览」而不是又一条明细
    final valueStyle = PiggyTextTokens.boldTitle(context);

    Widget metric(String label, double value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: PiggyTextTokens.caption(context)),
            SizedBox(height: 4.0.scaled(context, ref)),
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
      // 主题色描边（去掉阴影）：汇总卡与下方普通列表卡区分开，
      // 外观口径同预算页「总预算卡」/ 持仓页汇总区
      borderColor: ref.watch(primaryColorProvider),
      child: Padding(
        // 水平 16（+ SectionCard 自身 12 = 28）：与下方目标卡的文字 / 进度条左缘
        // 对齐，两张卡的进度条起止点才落在同一条竖线上
        padding: EdgeInsets.symmetric(
          horizontal: PiggyDimens.p16.scaled(context, ref),
          vertical: PiggyDimens.p12.scaled(context, ref),
        ),
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
            SizedBox(height: PiggyDimens.p16.scaled(context, ref)),
            BudgetProgressBar(
              used: summary.totalSaved,
              budget: summary.totalTarget,
              showLabel: false,
              // 比目标卡的 8 更粗（同预算页「总预算卡」的 12）：汇总卡是主线，
              // 粗细差异让「总进度」与「单条进度」一眼分层
              height: 12,
              // 目标型进度：达成不报警（同目标卡口径）。
              positiveOverflow: true,
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
