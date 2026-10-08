import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart' show primaryColorProvider;
import '../../providers/subscription_providers.dart';
import '../../services/data/recurring_transaction_service.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../utils/subscription_estimate.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/amount_text.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/category_icon.dart';
import '../../widgets/ui/ui.dart';
import 'recurring_transaction_edit_page.dart';

/// 订阅管理页 —— 周期账单的派生视图（零识别）。
///
/// 收录「当前账本启用中的支出型周期账单」，展示年支出 / 月均与下次扣款日；
/// 条目点击直接进对应周期账单编辑页。见
/// prd/subscription_and_overspend_alerts/requirements.md §4.1。
///
/// 版式与 [BudgetPage] / [CategoryBudgetTile] 同款：页面壳
/// （`PiggyTokens.scaffoldBackground` + `PiggyTitleBar` + `topScrollablePadding`）
/// → 一张 `SectionCard`（主题色描边）装汇总、一张装列表、条目用
/// `InkWell` + `.scaled()` 间距；间距/图标尺寸一律走 `ui_scale_extensions`。
class SubscriptionPage extends ConsumerWidget {
  const SubscriptionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final overviewAsync = ref.watch(subscriptionOverviewProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.subscriptionPageTitle,
        showBack: true,
        actions: [
          // 与周期记账页 / 预算页同款：标题栏右侧「+」直达新建表单
          IconButton(
            onPressed: () => _createSubscription(context, ref),
            icon: const Icon(Icons.add),
            tooltip: l10n.recurringTransactionAdd,
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  PiggyHaptics.light();
                  ref.invalidate(subscriptionOverviewProvider);
                  try {
                    await ref.read(subscriptionOverviewProvider.future);
                  } catch (_) {
                    // 失败保持静默，错误分支由 when 展示
                  }
                },
                child: overviewAsync.when(
                  // skipLoading*: 下拉刷新后保留旧数据渲染，避免整页闪 loading
                  skipLoadingOnReload: true,
                  skipLoadingOnRefresh: true,
                  loading: () => Center(
                    child: PiggySpinner(
                      size: 36,
                      color: PiggyTokens.primary(context),
                    ),
                  ),
                  error: (error, stack) => Center(
                    child: Text('${l10n.commonFailed}: $error'),
                  ),
                  data: (overview) {
                    if (overview.items.isEmpty) {
                      return _EmptyView(
                        onCreate: () => _createSubscription(context, ref),
                      );
                    }
                    return ListView(
                      padding: EdgeInsets.symmetric(
                        horizontal: 12.0.scaled(context, ref),
                        vertical: 8.0.scaled(context, ref),
                      ),
                      // AlwaysScrollable: 内容不满一屏时也能下拉刷新
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        _SummaryCard(summary: overview.summary),
                        SizedBox(height: 12.0.scaled(context, ref)),
                        SectionCard(
                          margin: EdgeInsets.zero,
                          borderColor: ref.watch(primaryColorProvider),
                          child: Column(
                            children: [
                              for (final item in overview.items)
                                _SubscriptionTile(
                                  item: item,
                                  baseCurrency: overview.summary.currencyCode,
                                  onTap: () async {
                                    final result =
                                        await showRecurringFormBottomSheet(
                                      context,
                                      recurring: item.recurring,
                                    );
                                    if (result == true) {
                                      ref.invalidate(
                                          subscriptionOverviewProvider);
                                    }
                                  },
                                ),
                            ],
                          ),
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 新建订阅（= 新建支出型周期账单）：走周期账单的统一表单抽屉，返回 true 即刷新。
Future<void> _createSubscription(BuildContext context, WidgetRef ref) async {
  final result = await showRecurringFormBottomSheet(context);
  if (result == true) {
    ref.invalidate(subscriptionOverviewProvider);
  }
}

/// 空态：引导去创建支出型周期账单（按钮样式同 [BudgetPage] 空态）。
class _EmptyView extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyView({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: AppEmpty(
            text: l10n.subscriptionEmpty,
            subtext: l10n.subscriptionEmptyHint,
            icon: Icons.subscriptions_outlined,
            action: ElevatedButton.icon(
              onPressed: onCreate,
              icon: Icon(Icons.add, color: PiggyTokens.buttonPrimaryText(context)),
              label: Text(l10n.subscriptionEmptyAction),
              style: ElevatedButton.styleFrom(
                backgroundColor: PiggyTokens.buttonPrimary(context),
                foregroundColor: PiggyTokens.buttonPrimaryText(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 顶部汇总卡：年支出 / 月均 / 订阅数（+ 外币未计入提示）。
class _SummaryCard extends ConsumerWidget {
  final SubscriptionSummary summary;

  const _SummaryCard({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return SectionCard(
      margin: EdgeInsets.zero,
      borderColor: ref.watch(primaryColorProvider),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.subscriptionCountLabel(summary.count),
            style: PiggyTextTokens.label(context)
                .copyWith(color: PiggyTokens.textTertiary(context)),
          ),
          SizedBox(height: 12.0.scaled(context, ref)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SummaryMetric(
                  label: l10n.subscriptionAnnualLabel,
                  value: summary.annualAmount,
                  currencyCode: summary.currencyCode,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs20,
                    fontWeight: FontWeight.w700,
                    color: PiggyTokens.textPrimary(context),
                  ),
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  label: l10n.subscriptionMonthlyLabel,
                  value: summary.monthlyAmount,
                  currencyCode: summary.currencyCode,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs16,
                    fontWeight: FontWeight.w600,
                    color: PiggyTokens.textSecondary(context),
                  ),
                ),
              ),
            ],
          ),
          if (summary.hasForeign) ...[
            SizedBox(height: 10.0.scaled(context, ref)),
            Text(
              l10n.subscriptionForeignHint(summary.foreignCount),
              style: TextStyle(
                fontSize: PiggyTextTokens.fs12,
                color: PiggyTokens.textTertiary(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryMetric extends ConsumerWidget {
  final String label;
  final double value;
  final String currencyCode;
  final TextStyle style;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.currencyCode,
    required this.style,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs12,
            color: PiggyTokens.textTertiary(context),
          ),
        ),
        SizedBox(height: 4.0.scaled(context, ref)),
        Align(
          alignment: Alignment.centerLeft,
          child: AmountText(
            value: value,
            signed: false,
            showCurrency: true,
            useCompactFormat: true,
            currencyCode: currencyCode,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// 单条订阅（版式同 [CategoryBudgetTile]：36 图标盒 + 两行信息 + 右侧金额）。
class _SubscriptionTile extends ConsumerWidget {
  final SubscriptionItem item;
  final String baseCurrency;
  final VoidCallback onTap;

  const _SubscriptionTile({
    required this.item,
    required this.baseCurrency,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final primary = PiggyTokens.primary(context);

    final name = item.displayName ??
        (item.category != null
            ? CategoryUtils.getDisplayName(item.category!.name, context)
            : null) ??
        l10n.subscriptionUnknownName;

    final currencyCode =
        (item.recurring.currencyCode ?? baseCurrency).trim().toUpperCase();
    final nextDue = item.nextDueDate;
    final dueText = nextDue == null
        ? l10n.subscriptionNoNextDue
        : l10n.subscriptionNextDue(DateFormat.Md().format(nextDue));

    final subStyle = PiggyTextTokens.label(context)
        .copyWith(color: PiggyTokens.textTertiary(context));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: 12.0.scaled(context, ref),
          horizontal: 4.0.scaled(context, ref),
        ),
        child: Row(
          children: [
            Container(
              width: 36.0.scaled(context, ref),
              height: 36.0.scaled(context, ref),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(
                    PiggyDimens.radiusSm.scaled(context, ref)),
              ),
              alignment: Alignment.center,
              child: item.category != null
                  ? CategoryIconWidget(
                      category: item.category,
                      size: 20.0.scaled(context, ref),
                      color: primary,
                    )
                  : Icon(
                      Icons.subscriptions_outlined,
                      size: 20.0.scaled(context, ref),
                      color: primary,
                    ),
            ),
            SizedBox(width: 12.0.scaled(context, ref)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: PiggyTextTokens.fs14,
                      fontWeight: FontWeight.w500,
                      color: PiggyTokens.textPrimary(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 4.0.scaled(context, ref)),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _frequencyDescription(
                            l10n,
                            RecurringFrequency.fromString(
                                item.recurring.frequency),
                            item.recurring.interval,
                          ),
                          style: subStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 分隔点与周期账单列表同款（label 字号 + tertiary 色）
                      Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.0.scaled(context, ref)),
                        child: Text('·', style: subStyle),
                      ),
                      Flexible(
                        child: Text(
                          dueText,
                          style: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
                            color: nextDue == null
                                ? PiggyTokens.textTertiary(context)
                                : primary,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (item.isForeign) ...[
              SizedBox(width: 12.0.scaled(context, ref)),
              Text(
                currencyCode,
                style: TextStyle(
                  fontSize: PiggyTextTokens.fs12,
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textSecondary(context),
                ),
              ),
              SizedBox(width: 4.0.scaled(context, ref)),
            ] else
              SizedBox(width: 12.0.scaled(context, ref)),
            AmountText(
              value: item.recurring.amount,
              signed: false,
              decimals: 2,
              style: TextStyle(
                fontSize: PiggyTextTokens.fs16,
                fontWeight: FontWeight.w600,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _frequencyDescription(
    AppLocalizations l10n,
    RecurringFrequency frequency,
    int interval,
  ) {
    if (interval == 1) {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionDaily;
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionWeekly;
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionMonthly;
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionYearly;
      }
    } else {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionEveryNDays(interval);
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionEveryNWeeks(interval);
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionEveryNMonths(interval);
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionEveryNYears(interval);
      }
    }
  }
}
