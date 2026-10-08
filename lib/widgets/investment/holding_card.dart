import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/account_type_utils.dart';
import '../../utils/holding_metrics.dart';
import '../../utils/ui_scale_extensions.dart';
import '../biz/biz.dart';

/// 一条持仓的展示卡（v52）。持仓列表页与账户详情页共用。
///
/// 口径纪律：
/// - 金额一律走 [effectiveUnitPrice]（**生效价单点**）—— 直接读 `holding.unitPrice`
///   会在接入真实行情源后悄悄显示过期价；
/// - 金额用**持仓自己的币种**展示并标注币种符号；账户级合计（折算到账户币种）
///   由持仓列表页的汇总卡负责，两者不混算；
/// - 涨跌用 `incomeColor` / `expenseColor`（Design Token），不用裸 Colors。
class HoldingCard extends ConsumerWidget {
  const HoldingCard({
    super.key,
    required this.holding,
    this.share,
    this.onTap,
  });

  final Holding holding;

  /// 市值占比（0..1，按账户内市值归一）。null = 不渲染占比条
  /// （账户里只有一条持仓时占比恒 100%，画出来是噪声）。
  final double? share;

  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final primary = PiggyTokens.primary(context);

    // 生效价：走 `holdingValueInputOf` 的**唯一定点**（含行情缓存 TTL 判定）。
    // 不要在这里写 `quotePrice != null` —— 那会忽略 TTL，接入真实行情源后
    // 持仓卡用一个过期价、而账户金额按 TTL 剔除，两处口径漂移。
    final effectivePrice = effectivePriceOf(holding);
    final marketValue = holdingMarketValue(
      quantity: holding.quantity,
      unitPrice: holding.unitPrice,
      quotePrice: holding.quotePrice,
      useQuote: holdingValueInputOf(holding).useQuote,
    );
    final cost = holdingCost(
      quantity: holding.quantity,
      unitCost: holding.unitCost,
    );
    final profit = marketValue - cost;
    final rate = profitRate(marketValue: marketValue, cost: cost);
    final profitColor =
        profit < 0 ? PiggyTokens.expenseColor(context, ref) : PiggyTokens.incomeColor(context, ref);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: Padding(
        padding: EdgeInsets.symmetric(
          horizontal: PiggyDimens.p12.scaled(context, ref),
          vertical: PiggyDimens.p12.scaled(context, ref),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _AssetClassBadge(assetClass: holding.assetClass),
                SizedBox(width: PiggyDimens.p12.scaled(context, ref)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        holding.name,
                        style: PiggyTextTokens.body(context).copyWith(
                          fontWeight: FontWeight.w600,
                          color: PiggyTokens.textPrimary(context),
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.0.scaled(context, ref)),
                      Text(
                        _subtitle(l10n),
                        style: PiggyTextTokens.caption(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      SizedBox(height: 2.0.scaled(context, ref)),
                      Text(
                        // 份额 × 生效净值 的算式对账口径（用户最常问「这个数怎么来的」）
                        '${_trimNumber(holding.quantity)} × '
                        '${_trimNumber(effectivePrice)}',
                        style: PiggyTextTokens.caption(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                SizedBox(width: PiggyDimens.p8.scaled(context, ref)),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    AmountText(
                      value: marketValue,
                      signed: false,
                      showCurrency: true,
                      currencyCode: holding.currency,
                      useCompactFormat: ref.watch(compactAmountProvider),
                      style: PiggyTextTokens.body(context).copyWith(
                        fontWeight: FontWeight.w600,
                        color: PiggyTokens.textPrimary(context),
                      ),
                    ),
                    SizedBox(height: 2.0.scaled(context, ref)),
                    AmountText(
                      value: profit,
                      signed: true,
                      showCurrency: true,
                      currencyCode: holding.currency,
                      useCompactFormat: ref.watch(compactAmountProvider),
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: profitColor),
                    ),
                    if (rate != null) ...[
                      SizedBox(height: 2.0.scaled(context, ref)),
                      Text(
                        _formatPercent(rate),
                        style: PiggyTextTokens.caption(context)
                            .copyWith(color: profitColor),
                      ),
                    ],
                  ],
                ),
              ],
            ),
            if (share != null) ...[
              SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
              Row(
                children: [
                  Text(
                    l10n.holdingShareLabel,
                    style: PiggyTextTokens.caption(context),
                  ),
                  SizedBox(width: PiggyDimens.p8.scaled(context, ref)),
                  // 画法与既有 BudgetProgressBar 一致（ClipRRect + LinearProgressIndicator
                  // + 跟随缩放的 minHeight），不要自造 Stack 版进度条。
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(3.0.scaled(context, ref)),
                      child: LinearProgressIndicator(
                        value: share!.clamp(0.0, 1.0),
                        backgroundColor: primary.withValues(alpha: 0.2),
                        valueColor: AlwaysStoppedAnimation(primary),
                        minHeight: 6.0.scaled(context, ref),
                      ),
                    ),
                  ),
                  SizedBox(width: PiggyDimens.p8.scaled(context, ref)),
                  Text(
                    _formatPercent(share!),
                    style: PiggyTextTokens.caption(context),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// 副标题：`代码 · 市场 · 币种`，缺什么省什么（手填版可以只有名字）
  String _subtitle(AppLocalizations l10n) {
    final parts = <String>[
      if ((holding.symbol ?? '').isNotEmpty) holding.symbol!,
      if ((holding.market ?? '').isNotEmpty)
        getHoldingMarketLabel(holding.market, l10n),
      getHoldingAssetClassLabel(holding.assetClass, l10n),
      if (holding.currency.toUpperCase() != 'CNY') holding.currency,
    ];
    return parts.join(' · ');
  }

  /// 份额/价格去掉无意义的尾零（100.0 → 100，1680.50 → 1680.5）
  static String _trimNumber(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  static String _formatPercent(double rate) =>
      '${(rate * 100).toStringAsFixed(2)}%';
}

/// 资产类别徽标（正方形圆角色块 + 类别图标）
class _AssetClassBadge extends ConsumerWidget {
  const _AssetClassBadge({required this.assetClass});

  final String assetClass;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      width: 36.0.scaled(context, ref),
      height: 36.0.scaled(context, ref),
      decoration: BoxDecoration(
        color: PiggyTokens.surfaceChip(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      ),
      child: Icon(
        getHoldingAssetClassIcon(assetClass),
        size: 18.0.scaled(context, ref),
        color: PiggyTokens.textSecondary(context),
      ),
    );
  }
}
