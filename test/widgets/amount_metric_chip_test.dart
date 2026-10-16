/// 金额口径 chip（`AmountMetricChip` / `AmountMetricNote`）契约测试。
///
/// 保护三件事：
/// 1. 默认显示「记账金额」，点开抽屉两个选项都在，选中即收起并写全局 provider；
/// 2. 切到「原始金额」后 chip 文案变更、口径说明行出现（默认口径下说明行零高）；
/// 3. chip 改的是**全局** [analyticsAmountMetricProvider]（洞察页 / 区间报表 /
///    导出页共用一枚），不是页面局部状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/models/analytics_amount_metric.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/widgets/analytics/amount_metric_chip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  Future<ProviderContainer> pumpChip(WidgetTester tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const Scaffold(
            body: Column(
              children: [AmountMetricChip(), AmountMetricNote()],
            ),
          ),
        ),
      ),
    );
    return container;
  }

  testWidgets('默认口径：chip 显示「记账金额」，说明行零高不占版面', (tester) async {
    final container = await pumpChip(tester);

    expect(find.text(l10n.analyticsAmountMetricRecorded), findsOneWidget);
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsNothing);
    expect(find.text(l10n.analyticsAmountMetricNote), findsNothing);
    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.recorded);
  });

  testWidgets('点击 chip 开抽屉：两个口径都在，带兜底说明', (tester) async {
    await pumpChip(tester);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.analyticsAmountMetricTitle), findsOneWidget);
    // 记账金额同时出现在 chip 与抽屉选项行（抽屉是浮层，底下页面仍在树上）
    expect(find.text(l10n.analyticsAmountMetricRecorded), findsNWidgets(2));
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsOneWidget);
    expect(find.text(l10n.analyticsAmountMetricOriginalDesc), findsOneWidget);
  });

  testWidgets('选「原始金额」：全局 provider 更新，chip 文案与说明行同步', (tester) async {
    final container = await pumpChip(tester);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.analyticsAmountMetricOriginal));
    await tester.pumpAndSettle();

    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.original);
    // 抽屉已收起，只剩 chip 上的文案 + 新出现的说明行
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsOneWidget);
    expect(find.text(l10n.analyticsAmountMetricNote), findsOneWidget);
  });

  testWidgets('已是原始金额时再选记账金额：能切回默认（说明行随之消失）', (tester) async {
    final container = await pumpChip(tester);
    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.original;
    await tester.pump();

    expect(find.text(l10n.analyticsAmountMetricNote), findsOneWidget);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.analyticsAmountMetricRecorded));
    await tester.pumpAndSettle();

    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.recorded);
    expect(find.text(l10n.analyticsAmountMetricNote), findsNothing);
  });
}
