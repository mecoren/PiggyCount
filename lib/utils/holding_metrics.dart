/// 投资持仓的纯计算层：无 IO、无 Flutter 依赖，供 Repository 与 UI 共用。
///
/// 口径契约（改任何一条都要同步看
/// `lib/data/repositories/local/local_account_repository.dart` 的「有效账户金额」
/// helper 与 `test/utils/holding_metrics_test.dart`）：
///
/// - **生效价单点**：行情缓存可用时取行情价，否则回退手填净值。手填值永不清空，
///   行情失效 / 未配置 / TTL 过期时自动回退，保证「删光行情即回到今天的行为」可逆。
///   净值链路与 UI **一律**读 [effectiveUnitPrice]，不要直接读 `unitPrice`。
/// - **缺汇率整条剔除**：折算不到账户币种的持仓不计入金额，只计数透出
///   （[HoldingsValueSummary.excluded]），**绝不按 1.0 裸加** —— 与净资产卡
///   既有口径一致（见 `local_account_repository.dart` 的 getNetWorthTrendSeries）。
/// - **收益率**：成本 <= 0 时返回 null，UI 显示「—」，不做除零（成本为 0 的持仓
///   在「别人送的」/ 只记录份额场景真实存在）。
library;

import '../data/db.dart';

/// 一笔持仓的计算输入。
///
/// 刻意与 Drift 的 `Holding` 行解耦：本层保持纯函数，Repository 负责把行映射进来。
class HoldingValueInput {
  const HoldingValueInput({
    required this.quantity,
    required this.unitCost,
    required this.unitPrice,
    required this.currency,
    this.quotePrice,
    this.useQuote = false,
  });

  /// 持有份额
  final double quantity;

  /// 单位成本（持仓币种）
  final double unitCost;

  /// 手填单位净值（持仓币种）
  final double unitPrice;

  /// 行情缓存价（null = 从未拉到过行情）
  final double? quotePrice;

  /// 该笔是否允许采用行情价。由上层按「行情源已配置 + 该行 autoQuote 开启 +
  /// 缓存未过期」判定后传入 —— 本层不做策略判断，只做取值。
  final bool useQuote;

  /// 持仓计价币种
  final String currency;
}

/// 行情缓存的最大可用时长：超过即视为过期 → 生效价回退手填净值。
///
/// 之所以有 TTL 而不是「有缓存就用」：手填版用户把某个持仓的净值填好后，
/// 若该持仓曾在别的设备/别的行情源下留下缓存，不设期限会让一个陈旧价格
/// 永久覆盖用户当前的手填值。
const Duration kQuoteMaxAge = Duration(hours: 24);

/// 判定某持仓的行情缓存是否可用于「生效价」。
///
/// 规则：有价 **且** 有拉取时刻 **且** 未超过 [maxAge]。
/// 缺拉取时刻时判为不可用 —— 不知道是否过期，宁可回退手填净值，也不拿一个
/// 来历不明的价格改净资产。
///
/// 当前唯一行情源是「手动录入」（`ManualQuoteProvider`，不写缓存列），
/// 所以调用方拿到的 `quotePrice` 恒为 null、本函数恒 false，
/// 与「没有持仓功能之前的行为」逐字一致。接入真实行情源后，所有
/// TTL / 换源 / 市场休市等判定都加在这里一处。
bool isQuoteUsable({
  required double? quotePrice,
  required DateTime? quoteFetchedAt,
  required DateTime now,
  Duration maxAge = kQuoteMaxAge,
}) {
  if (quotePrice == null || quoteFetchedAt == null) return false;
  // 时钟回拨/未来时间不当作过期：负时长一定小于 maxAge。
  return now.difference(quoteFetchedAt) <= maxAge;
}

/// 持仓行 → 纯计算输入。
///
/// **「行情缓存是否可用」判定的唯一定点**：Repository 的净值口径与全部 UI 都必须
/// 走它，不要各自写 `quotePrice != null` —— 那种写法忽略了 [isQuoteUsable] 的 TTL
/// 与「缺拉取时刻」判定，接入真实行情源后会让持仓卡用一个过期价、而账户金额
/// 按 TTL 剔除，两处口径悄悄漂移。
HoldingValueInput holdingValueInputOf(Holding holding, {DateTime? now}) =>
    HoldingValueInput(
      quantity: holding.quantity,
      unitCost: holding.unitCost,
      unitPrice: holding.unitPrice,
      quotePrice: holding.quotePrice,
      useQuote: isQuoteUsable(
        quotePrice: holding.quotePrice,
        quoteFetchedAt: holding.quoteFetchedAt,
        now: now ?? DateTime.now(),
      ),
      currency: holding.currency,
    );

/// 持仓的**生效单位净值**（UI 单条渲染用；与口径层同一判定）。
double effectivePriceOf(Holding holding, {DateTime? now}) {
  final input = holdingValueInputOf(holding, now: now);
  return effectiveUnitPrice(
    unitPrice: input.unitPrice,
    quotePrice: input.quotePrice,
    useQuote: input.useQuote,
  );
}

/// 生效单位净值：行情可用则取行情价，否则回退手填净值。
double effectiveUnitPrice({
  required double unitPrice,
  double? quotePrice,
  bool useQuote = false,
}) =>
    (useQuote && quotePrice != null) ? quotePrice : unitPrice;

/// 持仓市值（**持仓币种**口径，未折算）。= 份额 × 生效净值。
double holdingMarketValue({
  required double quantity,
  required double unitPrice,
  double? quotePrice,
  bool useQuote = false,
}) =>
    quantity *
    effectiveUnitPrice(
      unitPrice: unitPrice,
      quotePrice: quotePrice,
      useQuote: useQuote,
    );

/// 持仓成本（**持仓币种**口径，未折算）。= 份额 × 单位成本。
double holdingCost({required double quantity, required double unitCost}) =>
    quantity * unitCost;

/// 成本收益率 = (市值 − 成本) / 成本。成本 <= 0 时返回 null（不做除零）。
double? profitRate({required double marketValue, required double cost}) {
  if (cost <= 0) return null;
  return (marketValue - cost) / cost;
}

/// 跨币种折算率：1 单位 [from] = ? 单位 [to]。
///
/// [ratesToBase] 是既有汇率链的产物（币种大写 → 「1 单位该币种 = ? 单位本位币」，
/// 见 `lib/providers/currency_providers.dart`）。因此跨币种折算 = 两地本位币
/// 汇率之比，**不需要额外引入本位币之外的汇率数据**。
///
/// 同币种（大小写不敏感）恒为 1，且**不消费任何汇率数据** —— 保证「账户与持仓
/// 同币种」这一最常见场景在汇率还没加载完时也能算出金额。
/// 缺任一汇率、或目标汇率为 0 时返回 null（调用方须剔除该持仓，不得 1.0 兜底）。
double? crossRate({
  required String from,
  required String to,
  required Map<String, double> ratesToBase,
}) {
  final f = from.toUpperCase();
  final t = to.toUpperCase();
  if (f == t) return 1.0;
  final fromRate = ratesToBase[f];
  final toRate = ratesToBase[t];
  if (fromRate == null || toRate == null || toRate == 0) return null;
  return fromRate / toRate;
}

/// 一组持仓折算到**账户币种**后的汇总。
class HoldingsValueSummary {
  const HoldingsValueSummary({
    required this.marketValue,
    required this.cost,
    required this.profitRate,
    required this.total,
    required this.excluded,
  });

  /// 空汇总（无持仓 / 账户不存在时用）
  static const empty = HoldingsValueSummary(
    marketValue: 0,
    cost: 0,
    profitRate: null,
    total: 0,
    excluded: 0,
  );

  /// 折算到账户币种的持仓总市值
  final double marketValue;

  /// 折算到账户币种的持仓总成本
  final double cost;

  /// 基于折算后市值 / 成本计算的收益率；成本为 0 时为 null
  final double? profitRate;

  /// 参与汇总的持仓笔数（**含**因缺汇率被剔除的）
  final int total;

  /// 因缺汇率被剔除、未计入金额的持仓笔数
  final int excluded;

  /// 有持仓因缺汇率被剔除 —— UI 必须给出可见提示（不能静默少算）
  bool get hasExcluded => excluded > 0;

  /// 浮动盈亏 = 市值 − 成本（可能为负）
  double get profit => marketValue - cost;
}

/// 把一组持仓折算并汇总到 [accountCurrency]。
///
/// [ratesToBase] 缺省为空 map 时：只有「持仓币种 == 账户币种」的持仓会被计入，
/// 其余全部走剔除分支 —— 这是刻意的（宁可显示「N 项因缺汇率未计入」，也不把
/// 100 USD 当 100 CNY 加进净资产）。
HoldingsValueSummary summarizeHoldings({
  required List<HoldingValueInput> holdings,
  required String accountCurrency,
  required Map<String, double> ratesToBase,
}) {
  var marketValue = 0.0;
  var cost = 0.0;
  var excluded = 0;

  for (final h in holdings) {
    final rate = crossRate(
      from: h.currency,
      to: accountCurrency,
      ratesToBase: ratesToBase,
    );
    if (rate == null) {
      excluded++;
      continue;
    }
    marketValue += holdingMarketValue(
          quantity: h.quantity,
          unitPrice: h.unitPrice,
          quotePrice: h.quotePrice,
          useQuote: h.useQuote,
        ) *
        rate;
    cost += holdingCost(quantity: h.quantity, unitCost: h.unitCost) * rate;
  }

  return HoldingsValueSummary(
    marketValue: marketValue,
    cost: cost,
    profitRate: profitRate(marketValue: marketValue, cost: cost),
    total: holdings.length,
    excluded: excluded,
  );
}
