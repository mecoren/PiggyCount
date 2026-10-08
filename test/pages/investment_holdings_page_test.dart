/// v52 投资持仓页 UI 回归。
///
/// 锁死三条用户可见行为：
/// 1. 无持仓 → 空态引导（不能是空白页，否则用户找不到录入入口）；
/// 2. 有持仓 → 汇总卡 + 持仓名渲染（金额口径来自 Repository 的汇总 helper）；
/// 3. 新增持仓表单保存后**真的落库**（走 Repository，不是直接写 Drift）。
///
/// 以及一条口径提示：缺汇率的持仓必须显式提示「N 项未计入」，
/// 静默少算会被当成「App 算错了」。
///
/// ⚠️ 每个用例结束都要 [settlePage] 推时间：drift 的 QueryStream 在 dispose 时用
/// `Timer(Duration.zero)` 异步关闭、LoggerService 有 2s 落盘节流定时器 —— 不推进
/// 时间就会撞上「A Timer is still pending」断言（见 AGENTS.md Riverpod 3 迁移注意 #8）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/account/holding_edit_page.dart';
import 'package:piggycount/pages/account/investment_holdings_page.dart';
import 'package:piggycount/providers/database_providers.dart';

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

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: InvestmentHoldingsPage(accountId: accountId),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// 卸载页面并推进时间，清掉 drift / LoggerService 的挂起定时器。
  Future<void> settlePage(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 3));
  }

  /// 取 l10n 必须用**页面内部**的 element：`MaterialApp` 自身的 element 在
  /// Localizations 之上，查不到（返回 null）。
  ///
  /// [of] 用于被新路由覆盖的页面（`find.byType` 默认跳过 offstage 的旧路由）。
  AppLocalizations l10nOf(WidgetTester tester, [Finder? of]) =>
      AppLocalizations.of(tester.element(
          (of ?? find.byType(InvestmentHoldingsPage)).first));

  testWidgets('无持仓 → 渲染空态引导', (tester) async {
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.holdingEmptyTitle), findsOneWidget);
    expect(find.text(l10n.holdingEmptySubtitle), findsOneWidget);

    await settlePage(tester, container);
  });

  testWidgets('有持仓 → 渲染持仓名与汇总卡（收益率两处一致）', (tester) async {
    await repo.createHolding(
      accountId: accountId,
      name: '贵州茅台',
      currency: 'CNY',
      symbol: '600519',
      market: 'SH',
      assetClass: 'stock',
      quantity: 100,
      unitCost: 1500,
      unitPrice: 1680,
    );
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    expect(find.text('贵州茅台'), findsOneWidget);
    expect(find.text(l10n.holdingSummaryMarketValue), findsOneWidget);
    expect(find.text(l10n.holdingSummaryCost), findsOneWidget);
    expect(find.text(l10n.holdingEmptyTitle), findsNothing);
    // (168000 − 150000) / 150000 = 12.00%：持仓卡与汇总卡各一处，两处必须一致
    expect(find.text('12.00%'), findsNWidgets(2));

    await settlePage(tester, container);
  });

  testWidgets('跨币种缺汇率 → 必须显式提示未计入笔数', (tester) async {
    // 未注入汇率解析器（= 汇率不可用）→ USD 持仓被整条剔除
    await repo.createHolding(
      accountId: accountId,
      name: '本币标的',
      currency: 'CNY',
      quantity: 100,
      unitPrice: 10,
    );
    await repo.createHolding(
      accountId: accountId,
      name: '美股标的',
      currency: 'USD',
      quantity: 10,
      unitPrice: 100,
    );
    final container = await pumpPage(tester);

    expect(
      find.text(l10nOf(tester).holdingExcludedRateWarning(1)),
      findsOneWidget,
    );

    await settlePage(tester, container);
  });

  testWidgets('新增持仓表单保存 → 经 Repository 落库', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(HoldingEditPage), findsOneWidget);

    // 字段顺序：名称 / 代码 / 份额 / 单位成本 / 当前净值 / 备注
    // （币种是 Dropdown，不占 TextField 序号）
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '沪深300ETF');
    await tester.enterText(fields.at(2), '1000');
    await tester.enterText(fields.at(3), '3.5');
    await tester.enterText(fields.at(4), '4.2');
    await tester.pump();

    // 表单是项目统一的悬浮卡片抽屉（PiggyFormSheet）：「取消｜保存」固定在卡片
    // 底部常驻可见，不需要滚到表单末尾
    await tester.tap(
        find.text(l10nOf(tester, find.byType(HoldingEditPage)).commonSave));
    await tester.pumpAndSettle();

    final saved = await repo.getHoldingsByAccount(accountId);
    expect(saved, hasLength(1));
    expect(saved.single.name, '沪深300ETF');
    expect(saved.single.quantity, 1000);
    expect(saved.single.unitCost, 3.5);
    expect(saved.single.unitPrice, 4.2);
    expect(saved.single.currency, 'CNY', reason: '新建默认跟随账户币种');
    expect(saved.single.syncId, isNotNull, reason: '建行即生成跨设备身份锚点');

    await settlePage(tester, container);
  });
}
