/// v52 持仓 → 净值口径注入的集成契约。
///
/// 锁死四件事：
/// 1. **有持仓即接管**：投资账户金额 = Σ(份额 × 生效净值)，手工估值不再被读；
/// 2. **无持仓即回退**：删光持仓后逐字回到 `initial_balance`（可逆、不双计）；
/// 3. **多币种按汇率折算，缺汇率整条剔除**（绝不按 1.0 裸加）；
/// 4. **上层口径全链路生效**：净资产分解 / 按币种分解 / 资产构成 / 净值趋势
///    都建立在 getAccountBalance / getAccountDailyBalances 之上，改底层即全覆盖
///    —— 这条断言就是防「新增净值口径时绕过底层自己算、把持仓漏掉」。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  var seq = 0;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
  });

  tearDown(() async {
    await db.close();
  });

  /// 注入固定汇率表（币种大写 → 1 单位该币种 = ? 单位基准）。
  void injectRates(Map<String, double> rates) {
    repo.setHoldingsRateResolver(() async => rates);
  }

  Future<int> createInvestmentAccount({String currency = 'CNY'}) =>
      repo.createAccount(
        ledgerId: 0,
        name: '投资账户-${seq++}',
        type: 'investment',
        currency: currency,
      );

  group('账户金额接管与回退', () {
    test('投资账户有持仓 → 账户金额 = Σ(份额 × 单位净值)，不再读 initialBalance', () async {
      final accountId = await createInvestmentAccount();
      // 手工估值先写一个「过期」的数：有持仓后它必须被完全忽略
      await repo.updateAccountValuation(accountId, 999999);

      await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY',
          quantity: 100, unitCost: 8, unitPrice: 10);
      await repo.createHolding(
          accountId: accountId, name: 'B', currency: 'CNY',
          quantity: 50, unitCost: 12, unitPrice: 9);

      expect(await repo.getAccountBalance(accountId), closeTo(1450, 1e-9));
      expect(await repo.getAccountGlobalBalance(accountId), closeTo(1450, 1e-9));
    });

    test('删光持仓 → 自动回退 initialBalance（可逆、不双计）', () async {
      final accountId = await createInvestmentAccount();
      await repo.updateAccountValuation(accountId, 5000);
      final h1 = await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY',
          quantity: 100, unitPrice: 10);

      expect(await repo.getAccountBalance(accountId), closeTo(1000, 1e-9));

      await repo.deleteHolding(h1);

      expect(await repo.getAccountBalance(accountId), closeTo(5000, 1e-9),
          reason: 'initialBalance 未被清空/迁移，删光持仓即恢复生效');
    });

    test('非估值账户不受持仓影响（只有估值型账户走持仓口径）', () async {
      final cashId = await repo.createAccount(
          ledgerId: 0, name: '现金-${seq++}', type: 'cash', currency: 'CNY');
      await repo.createHolding(
          accountId: cashId, name: '不该生效', currency: 'CNY',
          quantity: 1000, unitPrice: 1000);

      expect(await repo.getAccountBalance(cashId), 0);
    });
  });

  group('多币种折算', () {
    test('持仓币种 ≠ 账户币种 → 按注入的汇率折算进账户币种', () async {
      injectRates(const {'USD': 7.2, 'CNY': 1.0});
      final accountId = await createInvestmentAccount(currency: 'CNY');

      await repo.createHolding(
        accountId: accountId, name: 'AAPL', currency: 'USD',
        quantity: 100, unitCost: 6, unitPrice: 10,
      );

      expect(await repo.getAccountBalance(accountId), closeTo(7200, 1e-9));
    });

    test('缺汇率的持仓整条剔除，其余照常计入（绝不按 1.0 裸加）', () async {
      injectRates(const {'CNY': 1.0}); // 没有 JPY
      final accountId = await createInvestmentAccount(currency: 'CNY');

      await repo.createHolding(
          accountId: accountId, name: 'CNY 标的', currency: 'CNY',
          quantity: 100, unitPrice: 10);
      await repo.createHolding(
          accountId: accountId, name: 'JPY 标的', currency: 'JPY',
          quantity: 10, unitPrice: 10);

      final summary = await repo.getHoldingsSummaryForAccount(accountId);
      expect(summary.marketValue, closeTo(1000, 1e-9));
      expect(summary.total, 2);
      expect(summary.excluded, 1, reason: '剔除数必须透出给 UI');
      expect(summary.hasExcluded, isTrue);
      expect(await repo.getAccountBalance(accountId), closeTo(1000, 1e-9));
    });

    test('未注入汇率解析器时：同币种照常算，跨币种剔除（安全降级）', () async {
      final accountId = await createInvestmentAccount(currency: 'CNY');
      await repo.createHolding(
          accountId: accountId, name: '本币', currency: 'CNY',
          quantity: 100, unitPrice: 10);
      await repo.createHolding(
          accountId: accountId, name: '外币', currency: 'USD',
          quantity: 100, unitPrice: 10);

      expect(await repo.getAccountBalance(accountId), closeTo(1000, 1e-9));
    });
  });

  group('汇总与账户金额同口径', () {
    test('getHoldingsSummaryForAccount 的市值 == getAccountBalance', () async {
      final accountId = await createInvestmentAccount();
      await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY',
          quantity: 3, unitCost: 10, unitPrice: 12);

      final summary = await repo.getHoldingsSummaryForAccount(accountId);
      expect(summary.marketValue,
          closeTo(await repo.getAccountBalance(accountId), 1e-9));
      expect(summary.cost, closeTo(30, 1e-9));
      expect(summary.profit, closeTo(6, 1e-9));
      expect(summary.profitRate, closeTo(0.2, 1e-12));
    });

    test('无持仓 → 返回空汇总（UI 据此回退手工估值展示）', () async {
      final accountId = await createInvestmentAccount();

      final summary = await repo.getHoldingsSummaryForAccount(accountId);
      expect(summary.total, 0);
      expect(summary.marketValue, 0);
      expect(summary.profitRate, isNull);
    });
  });

  group('上层净值口径全链路', () {
    test('净资产分解 / 按币种分解 / 资产构成 都含持仓市值', () async {
      final accountId = await createInvestmentAccount();
      await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY',
          quantity: 100, unitPrice: 10);

      final breakdown = await repo.getNetWorthBreakdown();
      expect(breakdown.totalAssets, closeTo(1000, 1e-9));
      expect(breakdown.netWorth, closeTo(1000, 1e-9));

      final byCurrency = await repo.getNetWorthBreakdownByCurrency();
      expect(byCurrency['CNY']!.totalAssets, closeTo(1000, 1e-9));

      final composition = await repo.getAssetCompositionByType();
      final investment =
          composition.firstWhere((e) => e.type == 'investment');
      expect(investment.totalBalance, closeTo(1000, 1e-9));

      final compositionByCurrency =
          await repo.getAssetCompositionByTypeAndCurrency();
      expect(
        compositionByCurrency
            .firstWhere((e) => e.type == 'investment' && e.currency == 'CNY')
            .totalBalance,
        closeTo(1000, 1e-9),
      );
    });

    test('批量余额（getAllAccountBalances）含持仓市值', () async {
      final accountId = await createInvestmentAccount();
      await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY',
          quantity: 100, unitPrice: 10);

      final balances = await repo.getAllAccountBalances(0);
      expect(balances[accountId], closeTo(1000, 1e-9));
    });

    test('批量统计（getAllAccountStats）同样走持仓口径 —— 账户列表卡不得显示旧手工估值', () async {
      final accountId = await createInvestmentAccount();
      await repo.updateAccountValuation(accountId, 999999);
      await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY',
          quantity: 100, unitPrice: 10);

      final stats = await repo.getAllAccountStats();
      expect(stats[accountId]!.balance,
          closeTo(await repo.getAccountBalance(accountId), 1e-9),
          reason: '账户总列表卡与账户详情页必须显示同一个金额');
      expect(stats[accountId]!.balance, closeTo(1000, 1e-9));
      expect(stats[accountId]!.expense, 0, reason: '估值账户无日常收支');
      expect(stats[accountId]!.income, 0);
    });

    test('净值趋势序列含持仓市值，且按当前值平铺（与估值账户既有语义一致）', () async {
      final accountId = await createInvestmentAccount();
      await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY',
          quantity: 100, unitPrice: 10);

      final series = await repo.getNetWorthTrendSeries(
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 3),
        ratesToBase: const {'CNY': 1.0},
      );

      expect(series, hasLength(3));
      for (final point in series) {
        expect(point.assets, closeTo(1000, 1e-9),
            reason: '手动估值无历史快照 → 按当前值平铺（${point.date}）');
      }
    });

    test('净值趋势：持仓币种缺汇率 → 整条剔除（不按 1.0 裸加）', () async {
      final accountId = await createInvestmentAccount(currency: 'USD');
      await repo.createHolding(
          accountId: accountId, name: '美股', currency: 'USD',
          quantity: 100, unitPrice: 10);

      final series = await repo.getNetWorthTrendSeries(
        startDate: DateTime(2026, 10, 1),
        endDate: DateTime(2026, 10, 1),
        ratesToBase: const {'CNY': 1.0}, // 缺 USD
      );

      expect(series.single.assets, 0,
          reason: '缺汇率的币种整条剔除，与净资产卡同口径');
    });
  });
}
