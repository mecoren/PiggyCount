/// 行情市场标识常量。
///
/// 取值与应用主工程 `lib/utils/account_type_utils.dart` 的 `holdingMarketOrder`
/// 必须保持一致 —— 那里是 UI 选择器的取值来源，这里是行情源的路由键。
/// 本包不能引用主工程，所以只能靠两处常量 + 契约测试对齐。
class QuoteMarket {
  const QuoteMarket._();

  /// 上交所
  static const String sh = 'SH';

  /// 深交所
  static const String sz = 'SZ';

  /// 港交所
  static const String hk = 'HK';

  /// 美股
  static const String us = 'US';

  /// 场外基金（按基金代码）
  static const String fund = 'FUND';

  /// 数字货币
  static const String crypto = 'CRYPTO';

  /// 全部已知市场（顺序即 UI 展示顺序）
  static const List<String> all = <String>[sh, sz, hk, us, fund, crypto];
}

/// 一次行情查询里的一项（标的）。
class QuoteRequestItem {
  const QuoteRequestItem({required this.symbol, this.market});

  /// 行情代码（如 `600519` / `AAPL` / `BTC`）
  final String symbol;

  /// 市场标识（见 [QuoteMarket]）。null = 由行情源自行推断
  /// （多数公开接口能按代码形态猜，但不保证；能填就填）。
  final String? market;

  /// 请求 / 结果匹配键：`市场|代码`（都大写）。
  ///
  /// **必须带市场**：`000001` 在 SZ 是平安银行、在 SH 是上证指数，只按代码
  /// 匹配会把两个完全不同的标的混成一条。
  String get key => '${(market ?? '').toUpperCase()}|${symbol.toUpperCase()}';

  @override
  String toString() => 'QuoteRequestItem($key)';
}

/// 一次行情查询请求。
///
/// 一次请求可以带多个标的（是否真正批量由行情源 [QuoteCapability.supportsBatch]
/// 声明、由调用方编排层按源能力分组）。
class QuoteRequest {
  const QuoteRequest({required this.items, this.currency});

  final List<QuoteRequestItem> items;

  /// 期望的报价币种（ISO 大写，如 `CNY`）。
  /// null = 不指定，行情源通常返回标的的**本币**报价。
  final String? currency;

  bool get isEmpty => items.isEmpty;
}

/// 单条行情结果。
class Quote {
  const Quote({
    required this.symbol,
    required this.price,
    this.market,
    this.currency,
    this.asOf,
    this.sourceId,
    this.previousClose,
  });

  final String symbol;

  /// 市场标识（见 [QuoteMarket]）
  final String? market;

  /// 最新价（标的计价币种下的价格）
  final double price;

  /// 报价币种（ISO 大写）。null = 与持仓币种相同（行情源未指明）。
  final String? currency;

  /// 行情自身的**数据时间**（不是拉取时刻；盘中 / 收盘价语义由源决定）
  final DateTime? asOf;

  /// 提供该行情的行情源 identifier
  final String? sourceId;

  /// 昨收（用于算当日涨跌幅）。null = 该源不提供。
  final double? previousClose;

  /// 与 [QuoteRequestItem.key] 同口径的匹配键。
  String get key => '${(market ?? '').toUpperCase()}|${symbol.toUpperCase()}';

  /// 当日涨跌幅；无昨收或昨收 ≤ 0 时为 null（不做除零）。
  double? get changeRate {
    final prev = previousClose;
    if (prev == null || prev <= 0) return null;
    return (price - prev) / prev;
  }

  @override
  String toString() => 'Quote($key, $price $currency, asOf=$asOf)';
}
