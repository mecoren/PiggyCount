import 'dart:async';
import 'dart:convert';

import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:http/http.dart' as http;

import 'eastmoney_codec.dart';

/// 东方财富（Eastmoney）行情源 —— 免费公开源，覆盖 A 股（沪/深）、港股、场外基金。
///
/// 实现约定（与 `QuoteProvider` 契约一致）：
/// - 所有失败一律抛 [QuoteException]，`kind` 选对：网络超时 / 非 2xx → `network`，
///   JSON / 字段解析失败 → `parse`，代码无法规范化 → `parse`，市场不被支持 →
///   `unsupportedMarket`；
/// - 代码合法但源无数据（`data == null` / 价格缺失或非正）→ **不出现在返回 map**，
///   编排层据此保留旧缓存、绝不写脏值；
/// - 单标的接口（`supportsBatch = false`），一次 [fetchQuotes] 逐项询问；
/// - 报价币种：A 股 / 基金 = CNY，港股 = HKD（见 [EastmoneyCodec.currencyOf]）。
class EastmoneyQuoteProvider implements QuoteProvider {
  EastmoneyQuoteProvider({http.Client? client})
      : _client = client ?? http.Client();

  /// 持久化用稳定标识（装配层与设置页据此映射 l10n）。
  static const String id = 'eastmoney';

  /// A 股 / 港股行情接口（`secid` 单标的查询）。
  static const String _quoteBaseUrl = 'https://push2.eastmoney.com/api/qt/stock/get';

  /// 场外基金实时估值接口（JSONP）。
  static const String _fundBaseUrl = 'https://fundgz.1234567.com.cn/js';

  static const Duration _timeout = Duration(seconds: 10);

  final http.Client _client;

  @override
  String get providerId => id;

  @override
  String get providerName => 'Eastmoney';

  @override
  QuoteCapability get capability => const QuoteCapability(
        supportedMarkets: {'SH', 'SZ', 'HK', 'FUND'},
        supportsBatch: false,
        // 免费公开源，15 分钟节流避免被限流；调用方取「用户频率 / 源最小间隔」的较大值。
        minRefreshInterval: Duration(minutes: 15),
        requiresApiKey: false,
      );

  @override
  Future<void> initialize(Map<String, dynamic> config) async {}

  @override
  Future<Map<String, Quote>> fetchQuotes(QuoteRequest request) async {
    final out = <String, Quote>{};
    for (final item in request.items) {
      final quote = await _fetchOne(item);
      if (quote != null) out[item.key] = quote;
    }
    return out;
  }

  @override
  Future<void> dispose() async {
    _client.close();
  }

  Future<Quote?> _fetchOne(QuoteRequestItem item) async {
    final market = (item.market ?? '').trim().toUpperCase();
    if (!capability.supportedMarkets.contains(market)) {
      throw const QuoteException(
        QuoteErrorKind.unsupportedMarket,
        'eastmoney: unsupported market',
      );
    }
    final code = EastmoneyCodec.normalizeCode(item.symbol, market);
    if (code == null) {
      throw QuoteException(
        QuoteErrorKind.parse,
        'eastmoney: cannot normalize code "${item.symbol}" for $market',
      );
    }
    return market == 'FUND'
        ? _fetchFund(item, code)
        : _fetchStock(item, market, code);
  }

  Future<Quote?> _fetchStock(
    QuoteRequestItem item,
    String market,
    String code,
  ) async {
    final uri = Uri.parse(_quoteBaseUrl).replace(queryParameters: <String, String>{
      'secid': EastmoneyCodec.toSecid(code, market),
      'fields': 'f43,f57,f58,f59,f60',
    });
    final body = await _getBody(uri);
    final json = _decodeJson(body);
    final data = json['data'];
    if (data == null) return null;

    final decimals = _toInt(data['f59']) ?? 2;
    final priceRaw = data['f43'];
    if (priceRaw is! num) return null;
    final price = EastmoneyCodec.scalePrice(priceRaw, decimals);
    if (price <= 0) return null;

    final prevRaw = data['f60'];
    final previousClose =
        prevRaw is num ? EastmoneyCodec.scalePrice(prevRaw, decimals) : null;

    return Quote(
      symbol: item.symbol,
      market: market,
      price: price,
      name: _cleanName(data['f58']),
      currency: EastmoneyCodec.currencyOf(market),
      sourceId: providerId,
      previousClose: previousClose,
    );
  }

  Future<Quote?> _fetchFund(QuoteRequestItem item, String code) async {
    final uri = Uri.parse('$_fundBaseUrl/$code.js');
    final body = await _getBody(uri);
    final json = _decodeJsonp(body);

    // gsz = 盘中估算净值（交易时段有效），dwjz = 最近确认的单位净值。
    final gsz = _toDouble(json['gsz']);
    final dwjz = _toDouble(json['dwjz']);
    final price = (gsz != null && gsz > 0) ? gsz : dwjz;
    if (price == null || price <= 0) return null;

    return Quote(
      symbol: item.symbol,
      market: 'FUND',
      price: price,
      name: _cleanName(json['name']),
      currency: 'CNY',
      sourceId: providerId,
      previousClose: (dwjz != null && dwjz > 0) ? dwjz : null,
    );
  }

  /// 名称字段清洗：非字符串 / 空串 / 占位符 `-` 一律当作「源未提供」。
  static String? _cleanName(Object? v) {
    if (v is! String) return null;
    final s = v.trim();
    if (s.isEmpty || s == '-') return null;
    return s;
  }

  /// GET 并统一把超时 / 连接失败 / 非 2xx 映射为 `network`。
  Future<String> _getBody(Uri uri) async {
    http.Response resp;
    try {
      resp = await _client.get(uri).timeout(_timeout);
    } catch (e) {
      throw QuoteException(
        QuoteErrorKind.network,
        'eastmoney: request failed',
        cause: e,
      );
    }
    if (resp.statusCode != 200) {
      throw QuoteException(
        QuoteErrorKind.network,
        'eastmoney: HTTP ${resp.statusCode}',
      );
    }
    return resp.body;
  }

  Map<String, dynamic> _decodeJson(String body) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('top-level is not a map');
      }
      return decoded;
    } catch (e) {
      throw QuoteException(
        QuoteErrorKind.parse,
        'eastmoney: invalid JSON',
        cause: e,
      );
    }
  }

  /// 解析基金接口的 JSONP 包裹：`jsonpgz({...});` → `{...}`。
  Map<String, dynamic> _decodeJsonp(String body) {
    final start = body.indexOf('(');
    final end = body.lastIndexOf(')');
    if (start < 0 || end <= start) {
      throw const QuoteException(
        QuoteErrorKind.parse,
        'eastmoney: invalid fund JSONP',
      );
    }
    return _decodeJson(body.substring(start + 1, end));
  }

  int? _toInt(Object? v) {
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  double? _toDouble(Object? v) {
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }
}
