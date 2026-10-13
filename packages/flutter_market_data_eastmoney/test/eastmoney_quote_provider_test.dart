import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:flutter_market_data_eastmoney/flutter_market_data_eastmoney.dart';

void main() {
  group('EastmoneyCodec', () {
    test('A 股 / 基金：6 位数字，少一位即非法', () {
      expect(EastmoneyCodec.normalizeCode('600519', 'SH'), '600519');
      expect(EastmoneyCodec.normalizeCode('000001', 'SZ'), '000001');
      expect(EastmoneyCodec.normalizeCode('161725', 'FUND'), '161725');
      // 过滤非数字（用户可能粘贴带前缀/空格的代码）
      expect(EastmoneyCodec.normalizeCode(' sh600519 ', 'SH'), '600519');
      // 位数不对 → null
      expect(EastmoneyCodec.normalizeCode('519', 'SH'), isNull);
      expect(EastmoneyCodec.normalizeCode('6005190', 'SZ'), isNull);
      expect(EastmoneyCodec.normalizeCode('ABC', 'SH'), isNull);
    });

    test('港股：1~5 位左补零到 5 位，超过 5 位非法', () {
      expect(EastmoneyCodec.normalizeCode('700', 'HK'), '00700');
      expect(EastmoneyCodec.normalizeCode('09988', 'HK'), '09988');
      expect(EastmoneyCodec.normalizeCode('123456', 'HK'), isNull);
    });

    test('secid 前缀：沪 1 / 深 0 / 港 116', () {
      expect(EastmoneyCodec.toSecid('600519', 'SH'), '1.600519');
      expect(EastmoneyCodec.toSecid('000001', 'SZ'), '0.000001');
      expect(EastmoneyCodec.toSecid('00700', 'HK'), '116.00700');
      expect(
        () => EastmoneyCodec.toSecid('161725', 'FUND'),
        throwsA(isA<QuoteException>()),
      );
    });

    test('价格缩放：f43 除以 10^小数位', () {
      expect(EastmoneyCodec.scalePrice(170050, 2), 1700.5);
      expect(EastmoneyCodec.scalePrice(1234, 3), 1.234);
    });

    test('币种：港股 HKD，其余 CNY', () {
      expect(EastmoneyCodec.currencyOf('HK'), 'HKD');
      expect(EastmoneyCodec.currencyOf('SH'), 'CNY');
      expect(EastmoneyCodec.currencyOf('FUND'), 'CNY');
    });
  });

  group('EastmoneyQuoteProvider', () {
    test('A 股：正确 secid + 缩放价格 + CNY', () async {
      late Uri requested;
      final client = MockClient((req) async {
        requested = req.url;
        return http.Response(
          jsonEncode({
            'rc': 0,
            'data': {
              'f43': 170050,
              'f57': '600519',
              'f58': '贵州茅台',
              'f59': 2,
              'f60': 168000,
            },
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final provider = EastmoneyQuoteProvider(client: client);

      final quotes = await provider.fetchQuotes(const QuoteRequest(items: [
        QuoteRequestItem(symbol: '600519', market: 'SH'),
      ]));

      expect(requested.queryParameters['secid'], '1.600519');
      expect(quotes.keys, ['SH|600519']);
      final q = quotes['SH|600519']!;
      expect(q.price, 1700.5);
      expect(q.name, '贵州茅台');
      expect(q.currency, 'CNY');
      expect(q.sourceId, 'eastmoney');
      expect(q.previousClose, 1680.0);
    });

    test('港股：代码左补零 + secid 116 + HKD', () async {
      late Uri requested;
      final client = MockClient((req) async {
        requested = req.url;
        return http.Response(
          jsonEncode({
            'data': {'f43': 456700, 'f58': '腾讯控股', 'f59': 3, 'f60': 450000},
          }),
          200,
          headers: {'content-type': 'application/json; charset=utf-8'},
        );
      });
      final provider = EastmoneyQuoteProvider(client: client);

      final quotes = await provider.fetchQuotes(const QuoteRequest(items: [
        QuoteRequestItem(symbol: '700', market: 'HK'),
      ]));

      expect(requested.queryParameters['secid'], '116.00700');
      expect(quotes['HK|700']!.price, 456.7);
      expect(quotes['HK|700']!.name, '腾讯控股');
      expect(quotes['HK|700']!.currency, 'HKD');
    });

    test('场外基金：解析 JSONP，优先估算净值 gsz', () async {
      late Uri requested;
      final client = MockClient((req) async {
        requested = req.url;
        return http.Response(
          'jsonpgz({"fundcode":"161725","name":"招商中证白酒指数(LOF)A",'
          '"dwjz":"1.2345","gsz":"1.2400","gszzl":"0.45"});',
          200,
          headers: {'content-type': 'application/javascript; charset=utf-8'},
        );
      });
      final provider = EastmoneyQuoteProvider(client: client);

      final quotes = await provider.fetchQuotes(const QuoteRequest(items: [
        QuoteRequestItem(symbol: '161725', market: 'FUND'),
      ]));

      expect(requested.path, endsWith('/161725.js'));
      final q = quotes['FUND|161725']!;
      expect(q.price, 1.24);
      expect(q.name, '招商中证白酒指数(LOF)A');
      expect(q.currency, 'CNY');
      expect(q.previousClose, 1.2345);
    });

    test('名称占位符 `-` / 缺失 → name 为 null', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({
              'data': {'f43': 170050, 'f58': '-', 'f59': 2},
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final provider = EastmoneyQuoteProvider(client: client);

      final quotes = await provider.fetchQuotes(const QuoteRequest(items: [
        QuoteRequestItem(symbol: '600519', market: 'SH'),
      ]));

      expect(quotes['SH|600519']!.name, isNull);
    });

    test('未命中（data 为 null）→ 不出现在结果里', () async {
      final client = MockClient((req) async => http.Response(
            jsonEncode({'rc': 0, 'data': null}),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          ));
      final provider = EastmoneyQuoteProvider(client: client);

      final quotes = await provider.fetchQuotes(const QuoteRequest(items: [
        QuoteRequestItem(symbol: '999999', market: 'SH'),
      ]));

      expect(quotes, isEmpty);
    });

    test('非 2xx → QuoteException(network)', () async {
      final client = MockClient((req) async => http.Response('', 500));
      final provider = EastmoneyQuoteProvider(client: client);

      expect(
        () => provider.fetchQuotes(const QuoteRequest(items: [
          QuoteRequestItem(symbol: '600519', market: 'SH'),
        ])),
        throwsA(isA<QuoteException>()
            .having((e) => e.kind, 'kind', QuoteErrorKind.network)),
      );
    });

    test('非法 JSON → QuoteException(parse)', () async {
      final client = MockClient((req) async => http.Response('not-json', 200));
      final provider = EastmoneyQuoteProvider(client: client);

      expect(
        () => provider.fetchQuotes(const QuoteRequest(items: [
          QuoteRequestItem(symbol: '600519', market: 'SH'),
        ])),
        throwsA(isA<QuoteException>()
            .having((e) => e.kind, 'kind', QuoteErrorKind.parse)),
      );
    });

    test('代码无法规范化 → QuoteException(parse)', () async {
      final client = MockClient((req) async => http.Response('{}', 200));
      final provider = EastmoneyQuoteProvider(client: client);

      expect(
        () => provider.fetchQuotes(const QuoteRequest(items: [
          QuoteRequestItem(symbol: 'ABC', market: 'SH'),
        ])),
        throwsA(isA<QuoteException>()
            .having((e) => e.kind, 'kind', QuoteErrorKind.parse)),
      );
    });

    test('不支持的市场 → QuoteException(unsupportedMarket)', () async {
      final client = MockClient((req) async => http.Response('{}', 200));
      final provider = EastmoneyQuoteProvider(client: client);

      expect(
        () => provider.fetchQuotes(const QuoteRequest(items: [
          QuoteRequestItem(symbol: 'AAPL', market: 'US'),
        ])),
        throwsA(isA<QuoteException>()
            .having((e) => e.kind, 'kind', QuoteErrorKind.unsupportedMarket)),
      );
    });

    test('能力声明：不支持批量、免密钥、覆盖 SH/SZ/HK/FUND', () {
      final provider = EastmoneyQuoteProvider(client: MockClient((r) async {
        return http.Response('{}', 200);
      }));
      expect(provider.providerId, 'eastmoney');
      expect(provider.capability.isAutomatic, isTrue);
      expect(provider.capability.supportsBatch, isFalse);
      expect(provider.capability.requiresApiKey, isFalse);
      expect(provider.capability.supportedMarkets,
          {'SH', 'SZ', 'HK', 'FUND'});
    });
  });
}
