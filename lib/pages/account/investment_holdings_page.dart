import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/holding_metrics.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/investment/holding_card.dart';
import '../../widgets/ui/ui.dart';
import 'holding_edit_page.dart';

/// 某投资账户的持仓列表页（v52）。
///
/// 金额口径**全部**来自 `accountHoldingsSummaryProvider`（内部走
/// `LocalAccountRepository.getHoldingsSummaryForAccount`）—— 与账户卡上显示的
/// 账户金额共用同一个 helper，因此「这里的合计」与「账户页的金额」永不漂移。
/// 本页不自行做汇率折算（那会变成第二套口径）。
class InvestmentHoldingsPage extends ConsumerWidget {
  const InvestmentHoldingsPage({super.key, required this.accountId});

  final int accountId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final accountAsync = ref.watch(accountByIdProvider(accountId));
    final holdingsAsync = ref.watch(holdingsByAccountProvider(accountId));
    final summaryAsync = ref.watch(accountHoldingsSummaryProvider(accountId));

    final account = accountAsync.value;
    final holdings = holdingsAsync.value ?? const <Holding>[];

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.holdingPageTitle,
        showBack: true,
      ),
      // 只要一个「+」按钮，不带文字；按钮名走 tooltip（长按提示 + 无障碍朗读）
      // —— 与储蓄目标页同款口径。
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEdit(context, ref, null),
        tooltip: l10n.holdingAddTitle,
        child: const Icon(Icons.add_rounded),
      ),
      // 汇总卡**固定**在标题栏下方，只有明细区滚动：整页共用一个 ListView 时，
      // 往下滚会把「总市值」一起卷走，与「总览常驻」的预期不符（口径同储蓄目标页）。
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(
              // 标题栏下方留出呼吸位（与预算页 / 储蓄页口径一致），
              // 否则首卡顶边贴住标题栏下缘
              top: PiggyTokens.topScrollablePadding(
                context,
                extra: PiggyDimens.p8,
              ),
            ),
            child: Column(
              children: [
                if (summaryAsync.value != null && summaryAsync.value!.total > 0) ...[
                  _SummaryCard(
                    summary: summaryAsync.value!,
                    account: account,
                  ),
                  // SectionCard 只带水平 margin，卡与卡的纵向间距要在这里补，
                  // 否则汇总卡与列表卡上下贴死（间距口径取预算 / 储蓄页的 12）
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
                if (holdings.isEmpty && holdingsAsync.hasValue)
                  Padding(
                    padding: EdgeInsets.only(
                      top: 48.0.scaled(context, ref),
                      left: 24.0.scaled(context, ref),
                      right: 24.0.scaled(context, ref),
                    ),
                    child: AppEmpty(
                      icon: Icons.trending_up_outlined,
                      text: l10n.holdingEmptyTitle,
                      subtext: l10n.holdingEmptySubtitle,
                    ),
                  )
                else
                  SectionCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < holdings.length; i++) ...[
                          if (i > 0)
                            Divider(
                                height: 1,
                                color: PiggyTokens.divider(context)),
                          HoldingCard(
                            holding: holdings[i],
                            share: _shareOf(
                                holdings, holdings[i], summaryAsync.value),
                            onTap: () => _openEdit(context, ref, holdings[i]),
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

  /// 占比（0..1）。
  ///
  /// 只在「账户内全部持仓与账户同币种」时计算 —— 跨币种时逐条市值是各自币种的
  /// 数字，直接相除毫无意义；此时返回 null 不画占比条（汇总卡仍有折算后的合计，
  /// 并会透出缺汇率提示）。
  double? _shareOf(
    List<Holding> all,
    Holding holding,
    HoldingsValueSummary? summary,
  ) {
    if (summary == null || summary.total < 2 || summary.marketValue <= 0) {
      return null;
    }
    final sameCurrency = all.every(
      (h) => h.currency.toUpperCase() == all.first.currency.toUpperCase(),
    );
    if (!sameCurrency) return null;
    // 生效价判定与汇总走同一处（holding_metrics 的 holdingValueInputOf），
    // 否则占比之和可能不等于 100%。
    final input = holdingValueInputOf(holding);
    final value = holdingMarketValue(
      quantity: input.quantity,
      unitPrice: input.unitPrice,
      quotePrice: input.quotePrice,
      useQuote: input.useQuote,
    );
    return value / summary.marketValue;
  }

  /// 打开新增 / 编辑表单抽屉（项目统一的表单外壳，见 holding_edit_page.dart）
  Future<void> _openEdit(
    BuildContext context,
    WidgetRef ref,
    Holding? holding,
  ) {
    return showHoldingFormBottomSheet(
      context,
      accountId: accountId,
      holding: holding,
    );
  }
}

/// 汇总卡：总市值 / 总成本 / 浮动盈亏 + 缺汇率提示。
///
/// 金额币种 = **账户币种**（`accountHoldingsSummaryProvider` 已折算到账户币种）；
/// 缺汇率的持仓被整条剔除，这里必须把剔除笔数显式告诉用户 —— 静默少算会被当成
/// 「App 算错了」。
class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.summary, required this.account});

  final HoldingsValueSummary summary;
  final Account? account;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final currencyCode = account?.currency ?? 'CNY';
    final profitColor = summary.profit < 0
        ? PiggyTokens.expenseColor(context, ref)
        : PiggyTokens.incomeColor(context, ref);

    return SectionCard(
      // 主题色描边（去掉阴影）：汇总卡与下方普通列表卡区分开，
      // 外观口径同储蓄页汇总卡 / 预算页「总预算卡」
      borderColor: ref.watch(primaryColorProvider),
      child: Padding(
        // 水平 12（+ SectionCard 自身 12 = 24）：与下方持仓卡的内容左缘对齐
        // （HoldingCard 自带水平 p12 + SectionCard 的 p12）
        padding: EdgeInsets.symmetric(
          horizontal: PiggyDimens.p12.scaled(context, ref),
          vertical: PiggyDimens.p12.scaled(context, ref),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.holdingSummaryMarketValue,
              style: PiggyTextTokens.caption(context),
            ),
            SizedBox(height: 4.0.scaled(context, ref)),
            AmountText(
              value: summary.marketValue,
              signed: false,
              showCurrency: true,
              currencyCode: currencyCode,
              useCompactFormat: ref.watch(compactAmountProvider),
              style: TextStyle(
                fontSize: PiggyTextTokens.fs28,
                fontWeight: FontWeight.bold,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
            SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
            Row(
              children: [
                Expanded(
                  child: _Metric(
                    label: l10n.holdingSummaryCost,
                    value: summary.cost,
                    currencyCode: currencyCode,
                    color: PiggyTokens.textSecondary(context),
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: l10n.holdingSummaryProfit,
                    value: summary.profit,
                    currencyCode: currencyCode,
                    color: profitColor,
                    signed: true,
                  ),
                ),
                Expanded(
                  child: _Metric(
                    label: l10n.holdingSummaryReturnRate,
                    value: null,
                    text: summary.profitRate == null
                        ? '—'
                        : '${(summary.profitRate! * 100).toStringAsFixed(2)}%',
                    currencyCode: currencyCode,
                    color: profitColor,
                  ),
                ),
              ],
            ),
            if (summary.hasExcluded) ...[
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
                      l10n.holdingExcludedRateWarning(summary.excluded),
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

/// 汇总卡里的单个指标（有 [value] 走金额渲染，否则渲染 [text]）
class _Metric extends ConsumerWidget {
  const _Metric({
    required this.label,
    required this.currencyCode,
    required this.color,
    this.value,
    this.text,
    this.signed = false,
  });

  final String label;
  final double? value;

  /// 非金额指标的文本（如收益率「12.34%」或「—」）
  final String? text;
  final String currencyCode;
  final Color color;
  final bool signed;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final style = PiggyTextTokens.body(context).copyWith(
      fontWeight: FontWeight.w600,
      color: color,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: PiggyTextTokens.caption(context)),
        SizedBox(height: 2.0.scaled(context, ref)),
        if (value != null)
          AmountText(
            value: value!,
            signed: signed,
            showCurrency: false,
            currencyCode: currencyCode,
            useCompactFormat: ref.watch(compactAmountProvider),
            style: style,
          )
        else
          Text(text ?? '—', style: style),
      ],
    );
  }
}
