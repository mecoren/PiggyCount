import 'dart:math' as math;

import 'package:flutter_market_data/flutter_market_data.dart';

/// 东方财富的「市场 → 代码规范化 / secid 构造 / 价格缩放」纯函数。
///
/// 与 HTTP 解耦，全部静态、无副作用，便于单测锁死各市场的规范化规则：
/// - **A 股 / 场外基金**：6 位数字，缺一不可（用户少打一位会得到「代码非法」
///   而不是一个错误标的）；
/// - **港股**：1~5 位数字，左补零到 5 位（`700` → `00700`）；
/// - 价格字段 `f43` / `f60` 是缩放整数，真实价 = `原始值 / 10^小数位`。
class EastmoneyCodec {
  const EastmoneyCodec._();

  /// 支持的市场标识（与 [QuoteMarket] 一致）。**不含**美股 / 加密：
  /// 东方财富的免费公开接口不覆盖，编排层会按 [QuoteCapability.supports] 跳过。
  static const Set<String> supportedMarkets = <String>{'SH', 'SZ', 'HK', 'FUND'};

  /// 代码规范化：返回可用于请求的纯数字代码；无法规范化返回 null
  /// （调用方据此抛 [QuoteException]，kind = `parse`）。
  static String? normalizeCode(String raw, String market) {
    final digits = raw.trim().replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.isEmpty) return null;
    switch (market.trim().toUpperCase()) {
      case 'HK':
        if (digits.length > 5) return null;
        return digits.padLeft(5, '0');
      case 'SH':
      case 'SZ':
      case 'FUND':
        if (digits.length != 6) return null;
        return digits;
      default:
        return null;
    }
  }

  /// 规范化后的代码 → 东方财富 `secid`（`{市场前缀}.{代码}`）。
  ///
  /// 前缀：沪 `1`、深 `0`、港 `116`。[FUND] 走独立净值接口，不走 secid，
  /// 传入会抛 [QuoteException]（kind = `unsupportedMarket`）。
  static String toSecid(String code, String market) {
    switch (market.trim().toUpperCase()) {
      case 'SH':
        return '1.$code';
      case 'SZ':
        return '0.$code';
      case 'HK':
        return '116.$code';
      default:
        throw const QuoteException(
          QuoteErrorKind.unsupportedMarket,
          'eastmoney: no secid for market',
        );
    }
  }

  /// 把东方财富的缩放整数价格除以 `10^decimals` 还原为真实价格。
  static double scalePrice(num raw, int decimals) {
    return raw.toDouble() / math.pow(10, decimals);
  }

  /// 市场 → 报价币种（ISO 大写）。A 股 / 基金以人民币计价，港股以港币计价。
  static String currencyOf(String market) {
    switch (market.trim().toUpperCase()) {
      case 'HK':
        return 'HKD';
      default:
        return 'CNY';
    }
  }
}
