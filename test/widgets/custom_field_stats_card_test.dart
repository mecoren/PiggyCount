/// 洞察页「自定义字段汇总」卡（`CustomFieldStatsCard`）契约测试。
///
/// 保护四件事（prd/analytics_custom_field_card F1/F2 + 决策 3）：
/// 1. 结余视角隐藏（与分类构成/排行榜同口径）；
/// 2. 聚合为空（无定义或无值行）不渲染，无空态占位；
/// 3. 有数据时出卡：标题（复用 rangeReportCustomFieldTitle）+ 值桶行，
///    维度跟随视角（income 显示收入额 / expense 显示支出额）；
/// 4. 查询键含 ledgerId/start/end/refreshTick —— 换区间即换键重查（refreshTick
///    与它是同一机制，键测试即钉住）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_amount_metric.dart';
import 'package:piggycount/data/models/analytics_time_metric.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/analytics/custom_field_analysis_page.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/providers/custom_field_providers.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';
import 'package:piggycount/widgets/biz/amount_text.dart';
import 'package:piggycount/widgets/analytics/custom_field_stats_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  CustomFieldFieldStats field(String name, double expense, double income,
      {int count = 1}) {
    return CustomFieldFieldStats(
      fieldSyncId: 'f-$name',
      name: name,
      fieldType: 'amount',
      buckets: {
        'v': (income: income, expense: expense, count: count),
      },
    );
  }

  Widget host({
    required String type,
    required List<CustomFieldFieldStats> data,
    DateTime? start,
    AnalyticsAmountMetric amountMetric = AnalyticsAmountMetric.recorded,
    AnalyticsTimeMetric timeMetric = AnalyticsTimeMetric.happenedAt,
    List<
            ({
              int ledgerId,
              DateTime start,
              DateTime end,
              int refreshTick,
              AnalyticsAmountMetric amountMetric,
              AnalyticsTimeMetric timeMetric
            })>?
        calls,
  }) {
    return ProviderScope(
      overrides: [
        // AmountText(showCurrency) 会 watch 当前账本；注入假流避免真实 drift
        // QueryStream 排零位定时器（既有测试同款做法）。
        currentLedgerProvider.overrideWith((ref) => Stream<Ledger?>.value(null)),
        currentLedgerIdProvider.overrideWith((ref) => 7),
        customFieldStatsForRangeProvider.overrideWith((ref, q) async {
          calls?.add(q);
          return data;
        }),
        // 下钻页只 watch 这一个数据源；注入空结果让「整卡可点」用例能
        // 真正 push 页面而不碰真实 drift。
        customFieldStatsDetailProvider.overrideWith((ref, q) async => const []),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CustomFieldStatsCard(
            start: start ?? DateTime(2026, 1, 1),
            end: DateTime(2026, 1, 8),
            type: type,
            amountMetric: amountMetric,
            timeMetric: timeMetric,
          ),
        ),
      ),
    );
  }

  testWidgets('结余视角隐藏本卡', (tester) async {
    await tester.pumpWidget(host(
        type: 'balance', data: [field('渠道', 100, 0)], calls: []));
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(AmountText), findsNothing);
    expect(find.text('渠道'), findsNothing);
  });

  testWidgets('聚合为空：不渲染、无空态占位', (tester) async {
    await tester.pumpWidget(host(type: 'expense', data: const [], calls: []));
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(AmountText), findsNothing);
    expect(find.text(l10n.rangeReportCustomFieldTitle), findsNothing);
  });

  testWidgets('支出视角出卡：标题 + 值桶行，金额取支出', (tester) async {
    await tester.pumpWidget(host(
        type: 'expense', data: [field('渠道', 300, 50)], calls: []));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(l10n.rangeReportCustomFieldTitle), findsOneWidget);
    expect(find.text('渠道'), findsOneWidget);
    expect(
        tester
            .widgetList<AmountText>(find.byType(AmountText))
            .map((w) => w.value)
            .toList(),
        [300.0]);
  });

  testWidgets('收入视角：维度跟随，金额取收入', (tester) async {
    await tester.pumpWidget(host(
        type: 'income', data: [field('渠道', 300, 50)], calls: []));
    await tester.pump(const Duration(seconds: 3));

    expect(
        tester
            .widgetList<AmountText>(find.byType(AmountText))
            .map((w) => w.value)
            .toList(),
        [50.0]);
  });

  testWidgets('查询键含账本/起止/refreshTick，换区间即换键重查', (tester) async {
    final calls = <({
      int ledgerId,
      DateTime start,
      DateTime end,
      int refreshTick,
      AnalyticsAmountMetric amountMetric,
      AnalyticsTimeMetric timeMetric
    })>[];
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        start: DateTime(2026, 1, 1),
        calls: calls));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        start: DateTime(2026, 2, 1),
        calls: calls));
    await tester.pump(const Duration(seconds: 3));

    expect(calls.length, 2);
    expect(calls[0].ledgerId, 7);
    expect(calls[0].start, DateTime(2026, 1, 1));
    expect(calls[1].start, DateTime(2026, 2, 1));
  });

  testWidgets('整卡可点：点卡片主体（标题/值桶行）也能进字段分析页', (tester) async {
    await tester.pumpWidget(host(
        type: 'expense', data: [field('渠道', 300, 50)], calls: []));
    await tester.pump(const Duration(seconds: 3));

    final card = find.byKey(const Key('custom-field-stats-card'));
    final rect = tester.getRect(card);

    // 热区 = 整卡（此前只有右上角那行小字的 InkWell，点主体无反应 ——
    // 无障碍树却把整卡合并成一个 clickable 节点）。
    final titleRect = tester.getRect(find.text(l10n.rangeReportCustomFieldTitle));
    final rowRect = tester.getRect(find.text('渠道'));
    expect(rect.contains(titleRect.center), isTrue);
    expect(rect.contains(rowRect.center), isTrue);

    // 点值桶行（离右上角最远处）也要能下钻
    await tester.tapAt(rowRect.center);
    await tester.pumpAndSettle();
    expect(find.byType(CustomFieldAnalysisPage), findsOneWidget);
  });

  testWidgets('查询键含金额口径：卡内金额与页面其余卡片同源', (tester) async {
    final calls = <({
      int ledgerId,
      DateTime start,
      DateTime end,
      int refreshTick,
      AnalyticsAmountMetric amountMetric,
      AnalyticsTimeMetric timeMetric
    })>[];
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        calls: calls));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        amountMetric: AnalyticsAmountMetric.original,
        calls: calls));
    await tester.pump(const Duration(seconds: 3));

    // 换口径 = 换键重查（不换就是要拿到「界面按 A 口径、卡片按 B 口径」的 bug）
    expect(calls.length, 2);
    expect(calls[0].amountMetric, AnalyticsAmountMetric.recorded);
    expect(calls[1].amountMetric, AnalyticsAmountMetric.original);
  });

  testWidgets('查询键含统计时间口径：卡内区间与页面其余卡片同源', (tester) async {
    final calls = <({
      int ledgerId,
      DateTime start,
      DateTime end,
      int refreshTick,
      AnalyticsAmountMetric amountMetric,
      AnalyticsTimeMetric timeMetric
    })>[];
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        calls: calls));
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpWidget(host(
        type: 'expense',
        data: [field('渠道', 1, 0)],
        timeMetric: AnalyticsTimeMetric.customField('f-date'),
        calls: calls));
    await tester.pump(const Duration(seconds: 3));

    // 换时间口径 = 换键重查（漏传会让本卡按记账时间、页面其余卡片按字段日期）
    expect(calls.length, 2);
    expect(calls[0].timeMetric, AnalyticsTimeMetric.happenedAt);
    expect(calls[1].timeMetric, AnalyticsTimeMetric.customField('f-date'));
  });
}
