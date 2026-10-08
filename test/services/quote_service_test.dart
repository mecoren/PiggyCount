/// v52 行情编排服务（QuoteService）契约测试。
///
/// 用**手写 Fake 行情源**（不用 mock 库）驱动真实的内存 Drift 库，锁死：
/// 1. 手动源 / 无候选持仓 → **零请求**（默认关闭就是真的不发网络）；
/// 2. `autoQuote=false`、无代码、市场不被支持的持仓**不进请求**；
/// 3. 只写本地专有缓存三列，**绝不碰手填净值 unitPrice**；
/// 4. 未命中的标的不写缓存（保留旧值，不写脏值）；
/// 5. 请求失败保留旧缓存并把错误类别透出给调用方；
/// 6. 按源能力切片（批量上限 / 是否支持批量）。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/investment/quote_service.dart';

/// 可编排的假行情源：记录收到的请求、按脚本返回价格或抛错。
class _FakeQuoteProvider implements QuoteProvider {
  _FakeQuoteProvider({
    Set<String> markets = const {'SH', 'SZ', 'US'},
    bool batch = true,
    int maxPerRequest = 50,
  }) : _capability = QuoteCapability(
          supportedMarkets: markets,
          supportsBatch: batch,
          maxSymbolsPerRequest: maxPerRequest,
          minRefreshInterval: Duration.zero,
        );

  final QuoteCapability _capability;

  final Map<String, double> _prices = <String, double>{};

  /// 非 null 时 [fetchQuotes] 直接抛该异常
  QuoteException? throwError;

  /// 记录每次请求里的标的 key（顺序保留），用于断言切片与跳过
  final List<List<String>> requests = <List<String>>[];

  @override
  String get providerId => 'fake';

  @override
  String get providerName => 'Fake';

  @override
  QuoteCapability get capability => _capability;

  /// 预置某标的的价格（key 用 `市场|代码` 大写）
  void price(String market, String symbol, double value) {
    _prices['${market.toUpperCase()}|${symbol.toUpperCase()}'] = value;
  }

  @override
  Future<void> initialize(Map<String, dynamic> config) async {}

  @override
  Future<Map<String, Quote>> fetchQuotes(QuoteRequest request) async {
    requests.add(request.items.map((e) => e.key).toList());
    final err = throwError;
    if (err != null) throw err;
    final out = <String, Quote>{};
    for (final item in request.items) {
      final price = _prices[item.key];
      if (price == null) continue; // 未命中：不出现在结果里
      out[item.key] = Quote(
        symbol: item.symbol,
        market: item.market,
        price: price,
        sourceId: providerId,
        asOf: DateTime(2026, 10, 8),
      );
    }
    return out;
  }

  @override
  Future<void> dispose() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late int accountId;
  var seq = 0;

  final fixedNow = DateTime(2026, 10, 8, 15, 30);

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    seq++;
    accountId = await repo.createAccount(
        ledgerId: 0, name: '投资账户-$seq', type: 'investment', currency: 'CNY');
  });

  tearDown(() async => db.close());

  Future<int> addHolding({
    required String name,
    String? symbol,
    String? market,
    bool autoQuote = true,
    double unitPrice = 10,
  }) =>
      repo.createHolding(
        accountId: accountId,
        name: name,
        currency: 'CNY',
        symbol: symbol,
        market: market,
        autoQuote: autoQuote,
        quantity: 100,
        unitCost: 8,
        unitPrice: unitPrice,
      );

  QuoteService serviceWith(QuoteProvider provider) => QuoteService(
        repository: repo,
        provider: provider,
        now: () => fixedNow,
      );

  group('零请求路径（默认关闭）', () {
    test('手动源（capability 无支持市场）→ 不发任何请求、不写任何缓存', () async {
      await addHolding(name: '茅台', symbol: '600519', market: 'SH');
      final provider = _FakeQuoteProvider(markets: const <String>{});
      final service = serviceWith(provider);

      expect(service.supportsAutomaticQuotes, isFalse,
          reason: '手动源不具备自动拉取能力 → 调度层据此不启动');

      final result = await service.refreshQuotes();

      expect(provider.requests, isEmpty, reason: '绝不能发网络请求');
      expect(result.updated, 0);
      expect(result.skipped, 1);

      final row = (await repo.getHoldingsByAccount(accountId)).single;
      expect(row.quotePrice, isNull);
      expect(row.quoteSourceId, isNull);
    });

    test('无任何持仓 → 零请求', () async {
      final provider = _FakeQuoteProvider();
      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, isEmpty);
      expect(result.updated, 0);
      expect(result.requestCount, 0);
    });

    test('所有持仓 autoQuote=false → 零请求（逐笔开关优先于全局）', () async {
      await addHolding(
          name: '茅台', symbol: '600519', market: 'SH', autoQuote: false);
      final provider = _FakeQuoteProvider();

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, isEmpty);
      expect(result.skipped, 1);
      expect(result.updated, 0);
    });

    test('无行情代码 / 市场不被源支持 → 不进请求', () async {
      await addHolding(name: '无代码持仓');
      await addHolding(name: '港股', symbol: '00700', market: 'HK');
      final provider = _FakeQuoteProvider(markets: const {'SH', 'SZ', 'US'});

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, isEmpty, reason: '候选为空 → 一次也不该问');
      expect(result.skipped, 2);
    });
  });

  group('写入本地专有缓存列', () {
    test('拉到行情 → 写 quotePrice/fetchedAt/sourceId，且不动 unitPrice', () async {
      final id = await addHolding(
          name: '茅台', symbol: '600519', market: 'SH', unitPrice: 1680);
      final provider = _FakeQuoteProvider()..price('SH', '600519', 1700.5);

      final result = await serviceWith(provider).refreshQuotes();

      expect(result.updated, 1);
      expect(result.failed, 0);
      final row = await repo.getHolding(id);
      expect(row!.quotePrice, 1700.5);
      expect(row.quoteFetchedAt, fixedNow);
      expect(row.quoteSourceId, 'fake');
      expect(row.unitPrice, 1680, reason: '手填净值是用户数据，行情不得覆盖');
    });

    test('未命中的标的 → 不写缓存（保留旧值，绝不清零）', () async {
      final id = await addHolding(
          name: '茅台', symbol: '600519', market: 'SH');
      await repo.writeQuoteCache(id,
          price: 1600, fetchedAt: DateTime(2026, 10, 7), sourceId: 'fake');
      final provider = _FakeQuoteProvider(); // 没预置价格 → 未命中

      final result = await serviceWith(provider).refreshQuotes();

      expect(result.updated, 0);
      expect(result.requestCount, 1, reason: '问了但没命中');
      final row = await repo.getHolding(id);
      expect(row!.quotePrice, 1600, reason: '旧缓存必须保留');
      expect(row.quoteFetchedAt, DateTime(2026, 10, 7));
    });

    test('写缓存不产生 local_changes（行情刷新对同步不可见）', () async {
      final id = await addHolding(
          name: '茅台', symbol: '600519', market: 'SH');
      final provider = _FakeQuoteProvider()..price('SH', '600519', 1700);

      await serviceWith(provider).refreshQuotes();

      // repo 未注入 tracker，这里断言列值即可；变更登记隔离由
      // test/data/local_holding_repository_test.dart 的专项用例覆盖。
      expect((await repo.getHolding(id))!.quotePrice, 1700);
    });
  });

  group('失败降级', () {
    test('请求抛 QuoteException → 保留旧缓存并把错误类别透出', () async {
      final id = await addHolding(
          name: '茅台', symbol: '600519', market: 'SH');
      await repo.writeQuoteCache(id,
          price: 1600, fetchedAt: DateTime(2026, 10, 7), sourceId: 'fake');
      final provider = _FakeQuoteProvider()
        ..throwError = const QuoteException(
            QuoteErrorKind.rateLimited, 'too many requests');

      final result = await serviceWith(provider).refreshQuotes();

      expect(result.updated, 0);
      expect(result.failed, 1);
      expect(result.errorKind, QuoteErrorKind.rateLimited);
      final row = await repo.getHolding(id);
      expect(row!.quotePrice, 1600, reason: '失败必须保留旧缓存，不能写脏值');
      expect(row.quoteFetchedAt, DateTime(2026, 10, 7),
          reason: '拉取时刻也不该被推进 —— 否则 TTL 会误判为「刚更新过」');
    });

    test('非 QuoteException 的意外异常 → 归类 unknown，不冒泡崩调用方', () async {
      await addHolding(name: '茅台', symbol: '600519', market: 'SH');
      final provider = _ThrowingProvider();

      final result = await serviceWith(provider).refreshQuotes();

      expect(result.failed, 1);
      expect(result.errorKind, QuoteErrorKind.unknown);
    });
  });

  group('按源能力编排请求', () {
    test('支持批量的源 → 一次请求带上全部候选', () async {
      await addHolding(name: 'A', symbol: '600519', market: 'SH');
      await addHolding(name: 'B', symbol: '000001', market: 'SZ');
      final provider = _FakeQuoteProvider(batch: true)
        ..price('SH', '600519', 1700)
        ..price('SZ', '000001', 11);

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, hasLength(1));
      expect(provider.requests.single, hasLength(2));
      expect(result.updated, 2);
      expect(result.requestCount, 1);
    });

    test('不支持批量的源 → 逐个请求', () async {
      await addHolding(name: 'A', symbol: '600519', market: 'SH');
      await addHolding(name: 'B', symbol: '000001', market: 'SZ');
      final provider = _FakeQuoteProvider(batch: false)
        ..price('SH', '600519', 1700)
        ..price('SZ', '000001', 11);

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, hasLength(2));
      expect(provider.requests.every((r) => r.length == 1), isTrue);
      expect(result.updated, 2);
      expect(result.requestCount, 2);
    });

    test('超过 maxSymbolsPerRequest → 切片成多次请求', () async {
      for (var i = 0; i < 5; i++) {
        await addHolding(name: 'H$i', symbol: '60051$i', market: 'SH');
      }
      final provider = _FakeQuoteProvider(batch: true, maxPerRequest: 2);

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests, hasLength(3), reason: '5 条 / 每片 2 条 → 3 次');
      expect(provider.requests.map((r) => r.length).toList(), [2, 2, 1]);
      expect(result.requestCount, 3);
    });

    test('同一标的多条持仓 → 只请求一次，但都写缓存', () async {
      final a = await addHolding(name: 'A', symbol: '600519', market: 'SH');
      final b = await addHolding(name: 'B', symbol: '600519', market: 'SH');
      final provider = _FakeQuoteProvider()..price('SH', '600519', 1700);

      final result = await serviceWith(provider).refreshQuotes();

      expect(provider.requests.single, hasLength(1),
          reason: '同一 (市场,代码) 只该问一次');
      expect(result.updated, 2);
      expect((await repo.getHolding(a))!.quotePrice, 1700);
      expect((await repo.getHolding(b))!.quotePrice, 1700);
    });
  });
}

/// 抛非 QuoteException 的源，验证编排层的兜底分类。
class _ThrowingProvider implements QuoteProvider {
  @override
  String get providerId => 'throwing';

  @override
  String get providerName => 'Throwing';

  @override
  QuoteCapability get capability => const QuoteCapability(
        supportedMarkets: {'SH'},
        supportsBatch: true,
        minRefreshInterval: Duration.zero,
      );

  @override
  Future<void> initialize(Map<String, dynamic> config) async {}

  @override
  Future<Map<String, Quote>> fetchQuotes(QuoteRequest request) async =>
      throw StateError('boom');

  @override
  Future<void> dispose() async {}
}
