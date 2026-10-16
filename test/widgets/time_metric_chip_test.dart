/// 统计时间口径 chip（`TimeMetricChip` / `TimeMetricNote`）契约测试。
///
/// 保护四件事：
/// 1. 默认显示「记账时间」，说明行零高不占版面；**没有日期型字段时整个 chip
///    不渲染**（不给一个点了也没用的入口）；
/// 2. 点开抽屉：只有 `date` 类型、且有 syncId 的字段可选（金额 / 文本 / 单选
///    没有可统计的时间）；
/// 3. 选中后写**全局** [analyticsTimeMetricProvider]，chip 显示字段名，说明行
///    出现并点明「未填该字段的明细不参与统计」；
/// 4. 陈旧口径守卫：字段被删（或 json 探针不可用）后回落记账时间 —— 否则该
///    口径下所有明细被过滤，页面读数静默变 0。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_time_metric.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/providers/custom_field_providers.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/analytics/metric_segment.dart';
import 'package:piggycount/widgets/ui/segmented_control.dart';
import 'package:piggycount/widgets/analytics/time_metric_chip.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  CustomFieldDefinition field({
    required int id,
    required String name,
    required String syncId,
    required String fieldType,
  }) =>
      CustomFieldDefinition(
        id: id,
        ledgerId: 7,
        name: name,
        fieldType: fieldType,
        sortOrder: id,
        createdAt: DateTime(2026, 1, 1),
        syncId: syncId,
        isRequired: false,
      );

  /// 「入住日」「报销日」= 日期型（进抽屉）；其余类型不进。
  List<CustomFieldDefinition> defaultDefs() => [
        field(
            id: 1,
            name: '水费',
            syncId: 'f-water',
            fieldType: CustomFieldType.amount),
        field(
            id: 2,
            name: '备注',
            syncId: 'f-note',
            fieldType: CustomFieldType.text),
        field(
            id: 3,
            name: '入住日',
            syncId: 'f-date',
            fieldType: CustomFieldType.date),
        field(
            id: 4,
            name: '报销日',
            syncId: 'f-date-2',
            fieldType: CustomFieldType.date),
      ];

  Future<ProviderContainer> pumpChip(
    WidgetTester tester, {
    List<CustomFieldDefinition>? defs,
    bool supported = true,
  }) async {
    final container = ProviderContainer(overrides: [
      customFieldsForCurrentLedgerProvider
          .overrideWith((ref) async => defs ?? defaultDefs()),
      customFieldAmountMetricSupportedProvider
          .overrideWith((ref) async => supported),
    ]);
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
              children: [TimeMetricChip(), TimeMetricNote()],
            ),
          ),
        ),
      ),
    );
    // 定义与探针都是 Future，等它们落地
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('默认口径：chip 显示「记账时间」，说明行零高不占版面', (tester) async {
    final container = await pumpChip(tester);

    expect(find.text(l10n.analyticsTimeMetricHappenedAt), findsOneWidget);
    expect(find.text(l10n.analyticsTimeMetricNote), findsNothing);
    expect(container.read(analyticsTimeMetricProvider),
        AnalyticsTimeMetric.happenedAt);
  });

  testWidgets('没有日期型字段：chip 不渲染（点了也没用的入口不给）', (tester) async {
    await pumpChip(tester, defs: [
      field(
          id: 1,
          name: '水费',
          syncId: 'f-water',
          fieldType: CustomFieldType.amount),
      field(
          id: 2,
          name: '备注',
          syncId: 'f-note',
          fieldType: CustomFieldType.text),
    ]);

    expect(find.byKey(const Key('time-metric-chip')), findsNothing);
    expect(find.text(l10n.analyticsTimeMetricHappenedAt), findsNothing);
  });

  /// 轨内段形态（洞察页「统计口径条」）：装进 [PiggySegmentTrack] 里。
  Future<ProviderContainer> pumpSegmentChip(
    WidgetTester tester, {
    List<CustomFieldDefinition>? defs,
  }) async {
    final container = ProviderContainer(overrides: [
      customFieldsForCurrentLedgerProvider
          .overrideWith((ref) async => defs ?? defaultDefs()),
      customFieldAmountMetricSupportedProvider.overrideWith((ref) async => true),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          // 与洞察页标题行同一结构：口径条封顶（[kMetricBarMaxWidth]）+ 段由
          // `Expanded` 等分 —— 段宽由槽位给出，不再随文案长度变。
          home: Scaffold(
            body: Center(
              child: ConstrainedBox(
                constraints:
                    const BoxConstraints(maxWidth: kMetricBarMaxWidth),
                child: PiggySegmentTrack(
                  height: kMetricBarHeight,
                  child: Row(
                    mainAxisSize: MainAxisSize.max,
                    children: const [
                      TimeMetricChip(style: MetricChipStyle.segment),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  testWidgets('轨内形态：有日期型字段时渲染为一段，非默认口径 = 主色胶囊',
      (tester) async {
    final container = await pumpSegmentChip(tester);
    expect(find.byKey(const Key('time-metric-chip')), findsOneWidget);

    BoxDecoration? segDecoration() => tester
            .widget<AnimatedContainer>(find.descendant(
              of: find.byType(MetricSegment),
              matching: find.byType(AnimatedContainer),
            ))
            .decoration
        as BoxDecoration?;

    // 默认口径：透明底（与未选中的分段一样）
    expect(segDecoration(), isNull);

    final context = tester.element(find.byType(MetricSegment));
    container.read(analyticsTimeMetricProvider.notifier).state =
        AnalyticsTimeMetric.customField('f-date');
    await tester.pumpAndSettle();

    expect(segDecoration()?.color, PiggyTokens.primary(context));
    expect(find.text('入住日'), findsOneWidget); // 段内文案取字段名

    // 轨内段共用同一份抽屉选项
    await tester.tap(find.byKey(const Key('time-metric-chip')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.analyticsTimeMetricTitle), findsOneWidget);
  });

  testWidgets('点击 chip 开抽屉：内置「记账时间」+ 日期型字段（其它类型不进）',
      (tester) async {
    await pumpChip(tester);

    await tester.tap(find.byKey(const Key('time-metric-chip')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.analyticsTimeMetricTitle), findsOneWidget);
    // 记账时间同时出现在 chip 与抽屉选项行（抽屉是浮层，底下页面仍在树上）
    expect(find.text(l10n.analyticsTimeMetricHappenedAt), findsNWidgets(2));
    expect(find.text('入住日'), findsOneWidget);
    expect(find.text('报销日'), findsOneWidget);
    expect(find.text(l10n.analyticsTimeMetricCustomFieldDesc('入住日')),
        findsOneWidget);
    // 金额 / 文本字段没有可统计的时间，不进
    expect(find.text('水费'), findsNothing);
    expect(find.text('备注'), findsNothing);
  });

  testWidgets('选字段口径：全局 provider 更新，chip 文案与说明行同步', (tester) async {
    final container = await pumpChip(tester);

    await tester.tap(find.byKey(const Key('time-metric-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('入住日'));
    await tester.pumpAndSettle();

    expect(container.read(analyticsTimeMetricProvider),
        AnalyticsTimeMetric.customField('f-date'));
    expect(find.text('入住日'), findsOneWidget); // chip 文案
    expect(find.text(l10n.analyticsTimeMetricNote), findsOneWidget);
  });

  testWidgets('已是字段口径时再选记账时间：能切回默认（说明行随之消失）',
      (tester) async {
    final container = await pumpChip(tester);
    container.read(analyticsTimeMetricProvider.notifier).state =
        AnalyticsTimeMetric.customField('f-date');
    await tester.pump();

    expect(find.text(l10n.analyticsTimeMetricNote), findsOneWidget);

    await tester.tap(find.byKey(const Key('time-metric-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.analyticsTimeMetricHappenedAt).last);
    await tester.pumpAndSettle();

    expect(container.read(analyticsTimeMetricProvider),
        AnalyticsTimeMetric.happenedAt);
    expect(find.text(l10n.analyticsTimeMetricNote), findsNothing);
  });

  testWidgets('陈旧口径守卫：字段已删 / 切到没有该字段的账本 → 回落记账时间',
      (tester) async {
    final container = await pumpChip(tester);
    container.read(analyticsTimeMetricProvider.notifier).state =
        AnalyticsTimeMetric.customField('f-deleted');
    await tester.pumpAndSettle();

    expect(container.read(analyticsTimeMetricProvider),
        AnalyticsTimeMetric.happenedAt);
    expect(find.text(l10n.analyticsTimeMetricNote), findsNothing);
  });

  testWidgets('陈旧口径守卫：json 探针不可用时不保留字段口径', (tester) async {
    final container = await pumpChip(tester, supported: false);
    container.read(analyticsTimeMetricProvider.notifier).state =
        AnalyticsTimeMetric.customField('f-date');
    await tester.pumpAndSettle();

    expect(container.read(analyticsTimeMetricProvider),
        AnalyticsTimeMetric.happenedAt);
  });
}
