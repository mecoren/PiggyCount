/// v30 记账页手选币种的汇率拉取(L12 配套):
/// 手选币种不在 usedCurrencies(账户币种∪主币种)里,常规 refresh 拉回的组
/// 永远没有它 —— refreshExchangeRates 的 extraQuotes 参数把它并入拉取集合。
library;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/providers/currency_providers.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/services/currency/exchange_rate_service.dart';

/// 假汇率源:固定返回 CNY 基准的几个币种(不打网络)。
class _FakeRateService implements ExchangeRateService {
  int fetchCount = 0;
  @override
  Future<RateFetchResult> fetch(String base) async {
    fetchCount++;
    return const RateFetchResult(
      rateDate: '2026-07-12',
      source: 'fake',
      ratesBaseToQuote: {'USD': '0.139', 'JPY': '20.5', 'EUR': '0.127'},
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  test('extraQuotes:手选币种(JPY)不在使用中币种里,refresh 后其汇率被落库', () async {
    // 单币种环境:无账户、主币种 CNY(usedCurrencies={CNY},常规 refresh 会
    // 因 usedAll<2 直接跳过 —— extraQuotes 撑起集合并把 JPY 带进拉取)。
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    final fake = _FakeRateService();
    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      exchangeRateServiceProvider.overrideWithValue(fake),
      usedCurrenciesProvider.overrideWith((ref) => Future.value({'CNY'})),
    ]);
    addTearDown(container.dispose);

    // riverpod 3：Ref 是 sealed class，测试里无法 implements 伪造；改为在真实
    // provider 内调用，从而拿到真实的 Ref（与生产路径一致）。
    final ok = await container.read(
      FutureProvider<bool>(
        (ref) => refreshExchangeRates(ref, force: true, extraQuotes: {'JPY'}),
      ).future,
    );
    expect(ok, isTrue);
    expect(fake.fetchCount, greaterThan(0));

    final rates = await repo.getLatestAutoRates('CNY');
    final quotes = rates.map((r) => r.quoteCurrency).toSet();
    expect(quotes, contains('JPY'),
        reason: 'extraQuotes 的币种必须进入拉取并落库');
  });
}

