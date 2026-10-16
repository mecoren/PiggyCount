/// 金额口径 chip（`AmountMetricChip` / `AmountMetricNote`）契约测试。
///
/// 保护四件事：
/// 1. 默认显示「记账金额」，点开抽屉选项齐全，选中即收起并写全局 provider；
/// 2. 切到「原始金额」后 chip 文案变更、口径说明行出现（默认口径下说明行零高）；
/// 3. **金额型自定义字段**进抽屉：只有 `amount` 类型、且有 syncId 的字段可选，
///    选中后 chip 显示字段名、说明行换成「未填写不参与统计」；
/// 4. 陈旧口径守卫：字段被删（或 json 探针不可用）后回落默认口径 —— 否则
///    该口径下所有明细被过滤，页面读数静默变 0。
///
/// chip 改的是**全局** [analyticsAmountMetricProvider]（洞察页 / 区间报表 /
/// 导出页共用一枚），不是页面局部状态。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_amount_metric.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/providers/custom_field_providers.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/analytics/amount_metric_chip.dart';
import 'package:piggycount/widgets/analytics/metric_segment.dart';
import 'package:piggycount/widgets/ui/segmented_control.dart';

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

  /// 「水费」= 金额型（进抽屉）；「备注」「入住日」不是金额，不进。
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
              children: [AmountMetricChip(), AmountMetricNote()],
            ),
          ),
        ),
      ),
    );
    // 定义与探针都是 Future，等它们落地
    await tester.pumpAndSettle();
    return container;
  }

  /// 轨内段形态（洞察页「统计口径条」）：装进 [PiggySegmentTrack] 里。
  Future<ProviderContainer> pumpSegmentChip(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      customFieldsForCurrentLedgerProvider.overrideWith((ref) async => defaultDefs()),
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
                      AmountMetricChip(style: MetricChipStyle.segment),
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

  testWidgets('轨内形态：默认口径无胶囊，非默认口径 = 主色胶囊（与分段控件同源）',
      (tester) async {
    final container = await pumpSegmentChip(tester);

    // 段内的胶囊容器（MetricSegment 里唯一的 AnimatedContainer）
    BoxDecoration? segDecoration() => tester
            .widget<AnimatedContainer>(find.descendant(
              of: find.byType(MetricSegment),
              matching: find.byType(AnimatedContainer),
            ))
            .decoration
        as BoxDecoration?;

    // 默认口径：透明底，与未选中的分段一样
    expect(segDecoration(), isNull);

    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.original;
    await tester.pumpAndSettle();

    final context = tester.element(find.byType(MetricSegment));
    final deco = segDecoration();
    expect(deco, isNotNull);
    // 与滑块分段控件的选中段同源（同一套 decoration 函数 → 同色同圆角）
    expect(deco!.color, PiggyTokens.primary(context));
    expect(deco.borderRadius,
        BorderRadius.circular(PiggyDimens.radiusLg - kPiggySegmentTrackInset));

    // 轨内段同样点开抽屉（pill / segment 共用一份选项与回调）
    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();
    expect(find.text(l10n.analyticsAmountMetricTitle), findsOneWidget);
    // 「原始金额」同时出现在段内文案与抽屉选项行
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsNWidgets(2));
  });

  testWidgets('轨内形态：切口径后段宽不变（不按内容自适应、不缩放）', (tester) async {
    // 用户反馈「选完对应的文字后大小会变」的回归：旧实现每段宽度跟着文案长度
    // 走（「记账金额」≈69 ↔ 「水费」≈42），外面再套 FittedBox(scaleDown) 兜底，
    // 于是切口径 = 整条尺寸跳一次、缩放比例也跳一次。现在段宽由槽位等分给出。
    final container = await pumpSegmentChip(tester);

    final widthBefore =
        tester.getSize(find.byKey(const Key('amount-metric-chip')));
    final textBefore = find.text(l10n.analyticsAmountMetricRecorded);
    // 未被缩放：实渲染宽 == 布局宽（缩放会小于布局宽）
    expect(tester.getRect(textBefore).width, tester.getSize(textBefore).width);

    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.customField('f-water');
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const Key('amount-metric-chip'))),
        widthBefore);
    final textAfter = find.text('水费');
    expect(tester.getRect(textAfter).width, tester.getSize(textAfter).width);
  });

  testWidgets('默认口径：chip 显示「记账金额」，说明行零高不占版面', (tester) async {
    final container = await pumpChip(tester);

    expect(find.text(l10n.analyticsAmountMetricRecorded), findsOneWidget);
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsNothing);
    expect(find.text(l10n.analyticsAmountMetricNote), findsNothing);
    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.recorded);
  });

  testWidgets('点击 chip 开抽屉：内置两个口径 + 金额型字段（非金额字段不进）',
      (tester) async {
    await pumpChip(tester);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.analyticsAmountMetricTitle), findsOneWidget);
    // 记账金额同时出现在 chip 与抽屉选项行（抽屉是浮层，底下页面仍在树上）
    expect(find.text(l10n.analyticsAmountMetricRecorded), findsNWidgets(2));
    expect(find.text(l10n.analyticsAmountMetricOriginal), findsOneWidget);
    // 金额型字段进抽屉，描述点明「未填写该字段的明细不参与统计」
    expect(find.text('水费'), findsOneWidget);
    expect(
        find.text(l10n.analyticsAmountMetricCustomFieldDesc('水费')),
        findsOneWidget);
    // 文本 / 日期字段没有可求和的金额，不进
    expect(find.text('备注'), findsNothing);
    expect(find.text('入住日'), findsNothing);
  });

  testWidgets('选「原始金额」：全局 provider 更新，chip 文案与说明行同步',
      (tester) async {
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
    expect(find.text(l10n.analyticsAmountMetricNoteCustomField), findsNothing);
  });

  testWidgets('选字段口径：chip 显示字段名，说明行换成「未填写不参与统计」',
      (tester) async {
    final container = await pumpChip(tester);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('水费'));
    await tester.pumpAndSettle();

    final metric = container.read(analyticsAmountMetricProvider);
    expect(metric, AnalyticsAmountMetric.customField('f-water'));
    expect(metric.isDefault, isFalse);
    expect(find.text('水费'), findsOneWidget); // chip 文案
    expect(find.text(l10n.analyticsAmountMetricNoteCustomField), findsOneWidget);
    expect(find.text(l10n.analyticsAmountMetricNote), findsNothing);
  });

  testWidgets('json 探针不可用：抽屉不提供字段口径（宁可不给，也不给必然读 0 的项）',
      (tester) async {
    await pumpChip(tester, supported: false);

    await tester.tap(find.byKey(const Key('amount-metric-chip')));
    await tester.pumpAndSettle();

    expect(find.text(l10n.analyticsAmountMetricOriginal), findsOneWidget);
    expect(find.text('水费'), findsNothing);
  });

  testWidgets('陈旧口径守卫：字段已删 / 切到没有该字段的账本 → 回落默认口径',
      (tester) async {
    final container = await pumpChip(tester);
    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.customField('f-deleted');
    await tester.pumpAndSettle();

    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.recorded);
    expect(find.text(l10n.analyticsAmountMetricNoteCustomField), findsNothing);
  });

  testWidgets('陈旧口径守卫：探针不可用时不保留字段口径', (tester) async {
    final container = await pumpChip(tester, supported: false);
    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.customField('f-water');
    await tester.pumpAndSettle();

    expect(container.read(analyticsAmountMetricProvider),
        AnalyticsAmountMetric.recorded);
  });

  testWidgets('已是原始金额时再选记账金额：能切回默认（说明行随之消失）',
      (tester) async {
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
