/// 「字段分析」下钻页契约测试（prd/custom_field_stats_fullchain F2，阶段 2 RED）。
///
/// 保护七件事：
/// 1. 字段切换 chips：默认选中第一个字段，点选即切换渲染内容；
/// 2. 金额型：四指标（求和/均值/最小/最大）+ 值分布 + 填写率；
/// 3. 日期型：按月趋势折线（LineChart 直接消费月序列，values/xLabels 可断言）；
/// 4. 文本系（text/singleSelect/multiSelect 共用）：值排行 + 笔数 + 占比；
/// 5. 无定义：整页空态（AppEmpty + 引导文案），无 chips；
/// 6. 字段无人填写：空态提示文案（不画空图）；
/// 7. 下钻参数：点击值桶回传 FieldDrillValue、点击分布档回传 FieldDrillRange
///    ——阶段 3 筛选联动只消费这个回调契约，不回头改本页形状。
///
/// 渲染断言只钉「文案 + 数据映射」（AmountText 值、LineChart 序列），像素级
/// 图形不进断言（CustomPainter 无法稳定断言）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/custom_field_values.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/analytics/custom_field_analysis_page.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/providers/custom_field_providers.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';
import 'package:piggycount/services/export/custom_field_stats_csv.dart';
import 'package:piggycount/widgets/analytics/field_stats_detail_view.dart';
import 'package:piggycount/widgets/biz/amount_text.dart';
import 'package:piggycount/widgets/biz/app_empty.dart';
import 'package:piggycount/widgets/charts/line_chart.dart';

/// 只实现被测方法，其余走 noSuchMethod（与既有 test fakes 同款）：
/// 明细导出会经 repository 拉区间交易与字段定义。
class FakeRepo implements BaseRepository {
  final List<CustomFieldDefinition> defs;

  FakeRepo(this.defs);

  @override
  Future<List<CustomFieldDefinition>> getDefinitionsForLedger(int ledgerId) async =>
      defs;

  @override
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> getTransactionsByDateRange({
    required int ledgerId,
    required DateTime startDate,
    required DateTime endDate,
  }) async =>
      const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  AmountFieldStats amountField({
    String sid = 'f-amt',
    String name = '押金',
    int filled = 2,
    int total = 4,
  }) {
    return AmountFieldStats(
      fieldSyncId: sid,
      name: name,
      fieldType: CustomFieldType.amount,
      filledCount: filled,
      totalCount: total,
      valueSum: 300,
      valueAvg: 150,
      valueMin: 100,
      valueMax: 200,
      dist: const [
        (lower: 0, upper: 10, count: 0),
        (lower: 10, upper: 100, count: 1),
        (lower: 100, upper: 1000, count: 1),
        (lower: 1000, upper: 10000, count: 0),
        (lower: 10000, upper: null, count: 0),
      ],
    );
  }

  DateFieldStats dateField() {
    return const DateFieldStats(
      fieldSyncId: 'f-date',
      name: '入住日',
      fieldType: CustomFieldType.date,
      filledCount: 2,
      totalCount: 4,
      monthly: [
        (month: '2026-01', count: 1, income: 0, expense: 100),
        (month: '2026-02', count: 1, income: 0, expense: 200),
      ],
    );
  }

  TextLikeFieldStats textField({
    String sid = 'f-sel',
    String name = '渠道',
    // 填写率 3/4=75% 与值桶占比错开，避免「50.0%」文本歧义断言。
    int filled = 3,
    int total = 4,
  }) {
    return TextLikeFieldStats(
      fieldSyncId: sid,
      name: name,
      fieldType: CustomFieldType.singleSelect,
      filledCount: filled,
      totalCount: total,
      values: const [
        (label: '微信', count: 2, income: 0, expense: 200, ratio: 1.0),
        (label: '支付宝', count: 1, income: 50, expense: 0, ratio: 0.5),
      ],
    );
  }

  Widget host({
    required List<FieldStats> data,
    String type = 'expense',
    String? fieldSyncId,
    FieldDrillDown? onDrillDown,
  }) {
    return ProviderScope(
      overrides: [
        // AmountText(showCurrency) 会 watch 当前账本；注入假流避免真实 drift
        // QueryStream 排零位定时器（既有测试同款做法）。
        currentLedgerProvider.overrideWith((ref) => Stream<Ledger?>.value(null)),
        currentLedgerIdProvider.overrideWith((ref) => 7),
        customFieldStatsDetailProvider.overrideWith((ref, q) async => data),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: CustomFieldAnalysisPage(
          start: DateTime(2026, 1, 1),
          end: DateTime(2026, 1, 8),
          type: type,
          fieldSyncId: fieldSyncId,
          onDrillDown: onDrillDown,
        ),
      ),
    );
  }

  testWidgets('字段切换 chips：默认第一字段，点选切换渲染', (tester) async {
    await tester.pumpWidget(host(data: [
      textField(sid: 'f-a', name: '渠道'),
      TextLikeFieldStats(
        fieldSyncId: 'f-b',
        name: '支付',
        fieldType: CustomFieldType.text,
        filledCount: 1,
        totalCount: 4,
        values: const [
          (label: '信用卡', count: 1, income: 0, expense: 90, ratio: 1.0),
        ],
      ),
    ]));
    await tester.pump(const Duration(seconds: 3));

    // 默认第一字段：微信桶可见、第二字段的桶不可见
    expect(find.text('微信'), findsOneWidget);
    expect(find.text('信用卡'), findsNothing);

    await tester.tap(find.descendant(
      of: find.byKey(const Key('field-switch-chips')),
      matching: find.text('支付'),
    ));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text('信用卡'), findsOneWidget);
    expect(find.text('微信'), findsNothing);
  });

  testWidgets('金额型：四指标 + 值分布 + 填写率', (tester) async {
    await tester.pumpWidget(host(data: [amountField()]));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(l10n.customFieldStatSum), findsOneWidget);
    expect(find.text(l10n.customFieldStatAvg), findsOneWidget);
    expect(find.text(l10n.customFieldStatMin), findsOneWidget);
    expect(find.text(l10n.customFieldStatMax), findsOneWidget);
    expect(find.text(l10n.customFieldAnalysisValueDistribution), findsOneWidget);
    // 四指标数值（sum/avg/min/max 顺序即渲染顺序）
    expect(
      tester
          .widgetList<AmountText>(find.byType(AmountText))
          .map((w) => w.value)
          .toList(),
      [300.0, 150.0, 100.0, 200.0],
    );
    // 5 档恒定分布标签（含空档，空档也要出——分布完整性）
    expect(find.text('0~10'), findsOneWidget);
    expect(find.text('10~100'), findsOneWidget);
    expect(find.text('100~1000'), findsOneWidget);
    expect(find.text('1000~10000'), findsOneWidget);
    expect(find.text('≥10000'), findsOneWidget);
    // 填写率 2/4
    expect(find.text('50.0%'), findsOneWidget);
    expect(find.text(l10n.customFieldFilledCount(2)), findsOneWidget);
  });

  testWidgets('日期型：按月趋势折线消费月序列', (tester) async {
    await tester.pumpWidget(host(data: [dateField()]));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(l10n.customFieldAnalysisMonthlyTrend), findsOneWidget);
    final chart = tester.widget<LineChart>(find.byType(LineChart));
    expect(chart.values, [100.0, 200.0]);
    expect(chart.xLabels, ['2026-01', '2026-02']);
  });

  testWidgets('文本系：值排行 + 笔数 + 占比', (tester) async {
    await tester.pumpWidget(host(data: [textField()]));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(l10n.customFieldAnalysisValueRank), findsOneWidget);
    expect(find.text('微信'), findsOneWidget);
    expect(find.text('支付宝'), findsOneWidget);
    expect(find.text(l10n.analyticsTxCountShort(2)), findsOneWidget);
    expect(find.text(l10n.analyticsTxCountShort(1)), findsOneWidget);
    expect(find.text('100.0%'), findsOneWidget);
    expect(find.text('50.0%'), findsOneWidget);
    // 排行金额按视角维度（expense）取支出额：微信 200 / 支付宝 0
    expect(
      tester
          .widgetList<AmountText>(find.byType(AmountText))
          .map((w) => w.value)
          .toList(),
      [200.0, 0.0],
    );
  });

  testWidgets('无定义：整页空态、无 chips', (tester) async {
    await tester.pumpWidget(host(data: const []));
    await tester.pump(const Duration(seconds: 3));

    expect(find.byType(AppEmpty), findsOneWidget);
    expect(find.text(l10n.customFieldAnalysisEmptySubtext), findsOneWidget);
    expect(find.byKey(const Key('field-switch-chips')), findsNothing);
  });

  testWidgets('字段无人填写：空态提示文案，不画空图', (tester) async {
    await tester.pumpWidget(host(data: [
      TextLikeFieldStats(
        fieldSyncId: 'f-empty',
        name: '渠道',
        fieldType: CustomFieldType.singleSelect,
        filledCount: 0,
        totalCount: 4,
        values: const [],
      ),
    ]));
    await tester.pump(const Duration(seconds: 3));

    expect(find.text(l10n.customFieldAnalysisEmptySubtext), findsOneWidget);
    expect(find.byType(LineChart), findsNothing);
  });

  testWidgets('下钻参数：值桶 eq、分布区间 between', (tester) async {
    final hits = <FieldDrillTarget>[];
    await tester.pumpWidget(host(
      data: [textField(), amountField()],
      fieldSyncId: 'f-sel',
      onDrillDown: hits.add,
    ));
    await tester.pump(const Duration(seconds: 3));

    await tester.tap(find.text('微信'));
    await tester.pump(const Duration(seconds: 3));
    expect(hits, hasLength(1));
    final value = hits.single as FieldDrillValue;
    expect(value.fieldSyncId, 'f-sel');
    expect(value.value, '微信');

    // 切到金额字段，点分布档 → 区间下钻
    await tester.tap(find.descendant(
      of: find.byKey(const Key('field-switch-chips')),
      matching: find.text('押金'),
    ));
    await tester.pump(const Duration(seconds: 3));
    await tester.tap(find.text('10~100'));
    await tester.pump(const Duration(seconds: 3));
    expect(hits, hasLength(2));
    final range = hits.last as FieldDrillRange;
    expect(range.fieldSyncId, 'f-amt');
    expect(range.lower, 10);
    expect(range.upper, 100);
  });

  // ── 上线清单 #10：新交互元素 Semantics（与洞察卡入口同规格） ────────────

  testWidgets('下钻可点行带 button Semantics（值排行行 + 分布档行）', (tester) async {
    // SemanticsHandle 必须在测试主体内 dispose（框架在 endOfTestVerifications
    // 之前校验；addTearDown 时机太晚会报「handle still active」）。
    final handle = tester.ensureSemantics();

    await tester.pumpWidget(host(data: [textField(), amountField()]));
    await tester.pump(const Duration(seconds: 3));

    // 值排行行（文本系）：可点 → 读屏报按钮
    // （flagsCollection.isButton 直读布尔属性；hasFlag 已弃用）
    expect(tester.getSemantics(find.text('微信')).flagsCollection.isButton, isTrue);

    // 切到金额字段看分布档行
    await tester.tap(find.descendant(
      of: find.byKey(const Key('field-switch-chips')),
      matching: find.text('押金'),
    ));
    await tester.pump(const Duration(seconds: 3));
    expect(tester.getSemantics(find.text('10~100')).flagsCollection.isButton, isTrue);
    handle.dispose();
  });

  // ── 阶段 4：导出菜单接线（prd/custom_field_stats_fullchain F4） ──────────

  Widget hostWithRepo({
    required List<FieldStats> data,
    required FakeRepo repo,
    required CustomFieldCsvExport onExportCsv,
  }) =>
      ProviderScope(
        overrides: [
          currentLedgerProvider.overrideWith((ref) => Stream<Ledger?>.value(null)),
          currentLedgerIdProvider.overrideWith((ref) => 7),
          customFieldStatsDetailProvider.overrideWith((ref, q) async => data),
          repositoryProvider.overrideWithValue(repo),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: CustomFieldAnalysisPage(
            start: DateTime(2026, 1, 1),
            end: DateTime(2026, 1, 8),
            type: 'expense',
            onExportCsv: onExportCsv,
          ),
        ),
      );

  testWidgets('导出菜单：汇总表/明细两入口产出对应 CSV 行', (tester) async {
    final calls = <({CustomFieldCsvKind kind, List<List<dynamic>> rows})>[];
    final repo = FakeRepo([
      CustomFieldDefinition(
        id: 1,
        ledgerId: 7,
        name: '押金',
        fieldType: CustomFieldType.amount,
        sortOrder: 0,
        createdAt: DateTime(2026, 1, 1),
        syncId: 'f-amt',
        isRequired: false,
      ),
    ]);
    await tester.pumpWidget(hostWithRepo(
      data: [amountField()],
      repo: repo,
      onExportCsv: (kind, rows) => calls.add((kind: kind, rows: rows)),
    ));
    await tester.pump(const Duration(seconds: 3));

    // 菜单入口可见（tooltip 即 l10n.customFieldExportCsv）
    expect(find.byTooltip(l10n.customFieldExportCsv), findsOneWidget);

    await tester.tap(find.byTooltip(l10n.customFieldExportCsv));
    // 菜单展开是路由入场动画：单帧 pump(3s) 只推进假时钟，动画只跑首帧
    // （elapsed=0，FadeTransition opacity=0），菜单项仍不可命中，点击会
    // 穿透到下方 ModalBarrier（最小复现已证与页面无关，纯 PopupMenuButton
    // 同样复现）。必须等入场动画完成后再点菜单项。
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.customFieldExportAggregateCsv));
    await tester.pump(const Duration(seconds: 3));

    expect(calls, hasLength(1));
    expect(calls.single.kind, CustomFieldCsvKind.aggregate);
    // 汇总行首列是字段名（表头 11 列已在 csv 纯函数测试锁死，此处只钉接线）
    expect(calls.single.rows[1][0], '押金');

    await tester.tap(find.byTooltip(l10n.customFieldExportCsv));
    await tester.pumpAndSettle(); // 同上：等菜单入场动画完成再点
    await tester.tap(find.text(l10n.customFieldExportDetailCsv));
    await tester.pump(const Duration(seconds: 3));

    expect(calls, hasLength(2));
    expect(calls.last.kind, CustomFieldCsvKind.detail);
    // 明细表头 = 时间/类型/金额/备注 + 字段定义列
    expect(calls.last.rows.first, hasLength(5));
    expect(calls.last.rows.first.last, '押金');
  });

  testWidgets('无数据：导出菜单不出现', (tester) async {
    await tester.pumpWidget(host(data: const []));
    await tester.pump(const Duration(seconds: 3));

    expect(find.byTooltip(l10n.customFieldExportCsv), findsNothing);
  });
}
