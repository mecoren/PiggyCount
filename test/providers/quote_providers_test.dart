/// 行情源装配层（QuoteProviderIdNotifier）契约测试。
///
/// 锁死「换源清旧缓存」：切换行情源时定向清掉「旧源」写入的行情缓存
/// （`quote_source_id == oldId`），旧源价格不得继续参与「生效价」；
/// 切到同源则是幂等空操作，不清任何缓存。
library;

import 'package:drift/native.dart';
import 'package:flutter_market_data_eastmoney/flutter_market_data_eastmoney.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/providers/quote_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late int accountId;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    accountId = await repo.createAccount(
      ledgerId: 0,
      name: '投资账户',
      type: 'investment',
      currency: 'CNY',
    );
  });

  tearDown(() async => db.close());

  Future<int> addHolding() => repo.createHolding(
        accountId: accountId,
        name: '茅台',
        currency: 'CNY',
        symbol: '600519',
        market: 'SH',
        autoQuote: true,
      );

  test('东财源已装配：具备自动拉取能力且覆盖 SH/SZ/HK/FUND', () {
    // F4「最后一公里」的守门：源注册进可选列表、capability.isAutomatic
    // 由 supportedMarkets 非空派生（= 调度器会真的启动），无需密钥。
    expect(kAvailableQuoteProviderIds, contains(EastmoneyQuoteProvider.id));
    final provider = EastmoneyQuoteProvider();
    expect(provider.capability.isAutomatic, isTrue,
        reason: '非空 supportedMarkets 才能让调度器启动');
    expect(provider.capability.supportedMarkets,
        containsAll(<String>['SH', 'SZ', 'HK', 'FUND']));
    expect(provider.capability.requiresApiKey, isFalse);
  });

  test('换源清旧缓存：切走时清掉旧源写入的缓存', () async {
    final id = await addHolding();
    await repo.writeQuoteCache(id,
        price: 1700, fetchedAt: DateTime(2026, 10, 8), sourceId: 'eastmoney');

    final notifier = QuoteProviderIdNotifier(repository: repo);
    // 初始 manual → eastmoney（清 manual，空操作）→ manual（清 eastmoney 缓存）
    await notifier.select('eastmoney');
    await notifier.select('manual');

    final row = await repo.getHolding(id);
    expect(row!.quotePrice, isNull, reason: '旧源（eastmoney）缓存必须被清掉');
    expect(row.quoteFetchedAt, isNull);
    expect(row.quoteSourceId, isNull);
  });

  test('换源清旧缓存：切到同源是幂等空操作，不清任何缓存', () async {
    final id = await addHolding();
    await repo.writeQuoteCache(id,
        price: 1700, fetchedAt: DateTime(2026, 10, 8), sourceId: 'eastmoney');

    final notifier = QuoteProviderIdNotifier(repository: repo);
    await notifier.select('eastmoney'); // manual → eastmoney
    await notifier.select('eastmoney'); // 同源：不触发清理

    final row = await repo.getHolding(id);
    expect(row!.quotePrice, 1700,
        reason: '仍在本源（eastmoney）名下，缓存应保留');
    expect(row.quoteSourceId, 'eastmoney');
  });

  test('select 非法 id → 忽略且不清理缓存', () async {
    final id = await addHolding();
    await repo.writeQuoteCache(id,
        price: 1700, fetchedAt: DateTime(2026, 10, 8), sourceId: 'eastmoney');

    final notifier = QuoteProviderIdNotifier(repository: repo);
    await notifier.select('not-a-real-source');

    final row = await repo.getHolding(id);
    expect(row!.quotePrice, 1700, reason: '非法 id 直接忽略，缓存不动');
  });
}
