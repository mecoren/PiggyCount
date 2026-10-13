/// 从「行情代码」推断持仓的 **市场 / 资产类别 / 币种**（纯函数、无 IO）。
///
/// 为什么需要：编辑持仓时用户往往只记得代码（如 `159361`），市场与资产类别
/// 得手动再选一次、且容易选错 —— `159xxx` 是深市 ETF，资产类别应为「基金」
/// 而非「股票」。本推断补上「敲代码 → 下面几项自动带出」这条路径，用户仍可
/// 手动覆盖。
///
/// ## 能力边界（务必知悉）
///
/// 6 位数字代码里「场外基金」与「交易所证券」存在**天然重叠**（如 `110xxx`
/// 既是沪市可转债、也是场外基金代码；`001xxx` 既是深市股票、也有场外基金），
/// 离线无法 100% 区分。规则按「**交易所特征前缀优先，其余归入场外基金兜底**」
/// 取舍：覆盖绝大多数常见代码，个别歧义以用户手动选择为准。要在歧义上做到
/// 精确，只能走联网查询（东方财富 suggest 接口），不在本函数职责内。
///
/// 取值与顺序对齐 `account_type_utils.dart` 的 [holdingMarketOrder] /
/// [holdingAssetClassOrder]，不要在这里另造一套枚举。
library;

/// 已知加密货币符号（大写，仅收主流、且与常见美股 ticker 冲突极小的一批）。
/// 命中即归 `CRYPTO` / `crypto`；否则含字母的代码一律按美股 ticker 处理。
const Set<String> _cryptoSymbols = <String>{
  'BTC', 'ETH', 'USDT', 'BNB', 'SOL', 'XRP', 'ADA', 'DOGE', 'LTC', 'BCH',
  'DOT', 'TRX', 'SHIB', 'AVAX', 'LINK', 'ATOM', 'ETC', 'UNI', 'XLM', 'EOS',
};

/// 推断结果。字段为 null = 该维度「无法判断 / 不改动」。
class HoldingCodeGuess {
  const HoldingCodeGuess({this.market, this.assetClass, this.currency});

  /// 市场标识（`SH` / `SZ` / `HK` / `US` / `FUND` / `CRYPTO`）
  final String? market;

  /// 资产类别（`stock` / `fund` / `bond` / `crypto` / `other`）
  final String? assetClass;

  /// 计价币种（ISO 大写）
  final String? currency;

  bool get isEmpty => market == null && assetClass == null && currency == null;

  @override
  String toString() =>
      'HoldingCodeGuess(market=$market, assetClass=$assetClass, currency=$currency)';
}

/// 沪市 ETF/基金前缀（510~518 / 560~563 / 588）。**不含** `519xxx` 等场外基金。
const Set<String> _shFundPrefixes = <String>{
  '510', '511', '512', '513', '515', '516', '517', '518',
  '560', '561', '562', '563', '588',
};

/// 沪市可转债前缀。
const Set<String> _shBondPrefixes = <String>{'110', '111', '113'};

/// 深市股票前缀（主板 / 中小板 / 创业板）。
const Set<String> _szStockPrefixes = <String>{'000', '001', '002', '003', '300', '301'};

/// 深市可转债前缀。
const Set<String> _szBondPrefixes = <String>{'123', '127', '128'};

/// 推断入口。
HoldingCodeGuess guessHoldingFromCode(String raw) {
  final code = raw.trim().toUpperCase();
  if (code.isEmpty) return const HoldingCodeGuess();

  // ── 含字母 ──
  // 加密货币符号优先，其余 1~5 位字母串按美股 ticker。
  if (RegExp(r'[A-Z]').hasMatch(code)) {
    if (_cryptoSymbols.contains(code)) {
      return const HoldingCodeGuess(
        market: 'CRYPTO',
        assetClass: 'crypto',
        currency: 'USD',
      );
    }
    return const HoldingCodeGuess(
      market: 'US',
      assetClass: 'stock',
      currency: 'USD',
    );
  }

  final digits = code.replaceAll(RegExp(r'[^0-9]'), '');
  if (digits.isEmpty) return const HoldingCodeGuess();

  // ── 港股：1~5 位数字 ──
  if (digits.length <= 5) {
    return const HoldingCodeGuess(
      market: 'HK',
      assetClass: 'stock',
      currency: 'HKD',
    );
  }
  // 只认 6 位；其余长度不猜。
  if (digits.length != 6) return const HoldingCodeGuess();

  final p2 = digits.substring(0, 2);
  final p3 = digits.substring(0, 3);

  // ── 上交所 ──
  // 股票：600/601/603/605、688（科创板）、9（B 股）
  if (p2 == '60' || p2 == '68' || p2.startsWith('9')) {
    return const HoldingCodeGuess(
      market: 'SH',
      assetClass: 'stock',
      currency: 'CNY',
    );
  }
  if (_shFundPrefixes.contains(p3)) {
    return const HoldingCodeGuess(
      market: 'SH',
      assetClass: 'fund',
      currency: 'CNY',
    );
  }
  if (_shBondPrefixes.contains(p3)) {
    return const HoldingCodeGuess(
      market: 'SH',
      assetClass: 'bond',
      currency: 'CNY',
    );
  }

  // ── 深交所 ──
  if (_szStockPrefixes.contains(p3)) {
    return const HoldingCodeGuess(
      market: 'SZ',
      assetClass: 'stock',
      currency: 'CNY',
    );
  }
  // 基金/ETF/LOF：159xxx、15xxxx、16xxxx、18xxxx
  if (p3 == '159' || p2 == '15' || p2 == '16' || p2 == '18') {
    return const HoldingCodeGuess(
      market: 'SZ',
      assetClass: 'fund',
      currency: 'CNY',
    );
  }
  if (_szBondPrefixes.contains(p3)) {
    return const HoldingCodeGuess(
      market: 'SZ',
      assetClass: 'bond',
      currency: 'CNY',
    );
  }

  // ── 兜底：其余 6 位数字按「场外基金」处理 ──
  // 这是「场外基金也要有推断方法」的落点：它们没有交易所特征前缀，离线无从
  // 与交易所证券区分，只能整段归入 FUND（如 004xxx / 007xxx / 519xxx / 2xxxxx）。
  return const HoldingCodeGuess(
    market: 'FUND',
    assetClass: 'fund',
    currency: 'CNY',
  );
}
