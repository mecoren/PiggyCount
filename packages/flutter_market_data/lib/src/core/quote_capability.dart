/// 行情源能力声明。
///
/// 编排层（应用主工程的 `QuoteService`）靠它决定「怎么问」：
/// 不支持批量就逐个问、有最小间隔就节流、支持的市场不匹配就直接判为不可用
/// （省掉一次必然失败的请求）。
class QuoteCapability {
  const QuoteCapability({
    required this.supportedMarkets,
    this.supportsBatch = false,
    this.minRefreshInterval = const Duration(minutes: 15),
    this.requiresApiKey = false,
    this.maxSymbolsPerRequest = 50,
  });

  /// 支持的市场标识集合（见 `QuoteMarket`）。
  /// 空集合 = **不支持任何自动行情**（即「手动录入」源）。
  final Set<String> supportedMarkets;

  /// 是否支持一次请求多个标的
  final bool supportsBatch;

  /// 两次刷新之间的最小间隔（节流依据；调用方取各源的最大值）
  final Duration minRefreshInterval;

  /// 是否需要用户自备 API Key
  final bool requiresApiKey;

  /// 单次批量请求的标的上限（close 超过时编排层负责切片）
  final int maxSymbolsPerRequest;

  /// 本源的「可用性」：能不能承接这个市场。
  bool supports(String? market) {
    if (market == null) return false;
    return supportedMarkets.contains(market.toUpperCase());
  }

  /// 是否具备自动拉取能力（手动源为 false）。
  bool get isAutomatic => supportedMarkets.isNotEmpty;

  @override
  String toString() => 'QuoteCapability(markets=$supportedMarkets, '
      'batch=$supportsBatch, minInterval=$minRefreshInterval)';
}
