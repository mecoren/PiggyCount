// 洞察页切口径/切周期的闪动回归。
//
// 背景：FutureBuilder 曾挂 `key: ValueKey('analytics_$_type')`。切支出/收入/
// 结余时 key 变 → 元素被销毁重建 → snapshot 归零 → 整页塌成居中转圈，且
// ListView 重建导致滚动位置回到顶部。切周/月/年/全部、切 ‹ › 周期虽然 key
// 不变，但换 future 后仍要等查询才出数，期间的空白同样表现为闪一下。
//
// 现在口径标签随数据走（见 analytics_page 的 _shapeOf），在途帧继续渲染
// 上一份**同口径**结果：切口径/切周期都不再塌成整屏转圈。
library;

import 'dart:async';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/models/analytics_amount_metric.dart';
import 'package:piggycount/data/models/analytics_time_metric.dart';
import 'package:piggycount/data/models/analytics_transaction_filter.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/main/analytics_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/providers/ui_state_providers.dart';
import 'package:piggycount/widgets/ui/closable_chip.dart';
import 'package:piggycount/widgets/ui/segmented_control.dart';
import 'package:piggycount/widgets/ui/wait_sliding_segmented_control.dart';
import 'package:piggycount/widgets/ui/piggy_header.dart';
import 'package:piggycount/widgets/ui/piggy_spinner.dart';

/// 可挂起的仓储：[blocked] 打开后 [totalsByDay] 停在闸门不再返回，用来把页面
/// 按在「查询在途」的中间态——闪动回归必须在数据回来之前取一帧。
class _GatedRepository extends LocalRepository {
  _GatedRepository(super.db);

  final Completer<void> gate = Completer<void>();
  bool blocked = false;

  @override
  Future<List<({DateTime day, double total})>> totalsByDay({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    AnalyticsAmountMetric amountMetric = AnalyticsAmountMetric.recorded,
    AnalyticsTimeMetric timeMetric = AnalyticsTimeMetric.happenedAt,
    AnalyticsTransactionFilter filter = const AnalyticsTransactionFilter(),
  }) async {
    if (blocked) await gate.future;
    return super.totalsByDay(
      ledgerId: ledgerId,
      type: type,
      start: start,
      end: end,
      amountMetric: amountMetric,
      timeMetric: timeMetric,
      filter: filter,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  // 固定「今天」：页面用 DateTime.now() 截断当前周期到今天，测试数据要落在
  // 这个窗口里，否则断言的是空态而不是闪动。
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '账本',
          currency: const d.Value('CNY'),
          syncId: const d.Value('ledger-1'),
        ));
    final categoryId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));

    Future<void> tx(double amount,
        {required DateTime at, String type = 'expense'}) async {
      await db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            categoryId: d.Value(categoryId),
            type: type,
            amount: amount,
            happenedAt: d.Value(at),
            syncId: d.Value('tx-$type-${at.millisecondsSinceEpoch}-$amount'),
          ));
    }

    // 今天 + 更早几天：让折线/柱状图有多个非零点，且都在当前周期内。
    await tx(200, at: today);
    await tx(100, at: today.subtract(const Duration(days: 1)));
    await tx(50, at: today.subtract(const Duration(days: 2)));
    await tx(100, at: today, type: 'income');
  });

  tearDown(() async => db.close());

  Future<ProviderContainer> pump(WidgetTester tester,
      {LocalRepository? repository, Size size = const Size(1200, 6000)}) async {
    // 页面是 ListView，默认 800×600 视口装不下趋势/分类构成卡，未构建的
    // sliver 里文本找不到。把逻辑高度拉大一次性全渲染。
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repository ?? repo),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const AnalyticsPage(),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// 切到「收入」段（页面同款 tab 样式；页面上多处出现「收入」，限定在控件内）。
  Future<void> tapIncome(WidgetTester tester) async {
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text('收入'),
    ));
    await tester.pump();
  }

  testWidgets('首屏支出数据到位', (tester) async {
    await pump(tester);
    expect(find.byType(PiggySpinner), findsNothing);
    expect(find.text('支出趋势'), findsOneWidget);
    // 本期支出 200+100+50 = 350
    expect(find.text('350.00'), findsWidgets);
  });

  // 头部磨砂（GradientBackdropFilter）只有「下面真的滚过内容」才看得出效果：
  // 头部必须是覆盖层（贴屏幕顶、不占布局位），列表视口也必须是整块 body，
  // 靠列表自身 padding 让出头部高度。退回 body: Column 就会让列表视口从头部
  // 下沿开始、卡片永远穿不到头部后面（磨砂只剩一片纯色）。
  testWidgets('列表铺满 body + 首屏留白让出头部覆盖层', (tester) async {
    await pump(tester);
    final listFinder = find.byType(ListView);
    expect(listFinder, findsOneWidget);
    final listRect = tester.getRect(listFinder);
    final headerRect = tester.getRect(find.byType(PiggyHeader));
    final padding = tester.widget<ListView>(listFinder).padding! as EdgeInsets;

    expect(headerRect.top, 0, reason: '头部覆盖层要贴屏幕顶（自带状态栏避让）');
    expect(listRect.top, 0, reason: '列表视口从屏幕顶开始，卡片才能滚到头部下方');
    expect(listRect.height, greaterThan(headerRect.height),
        reason: '列表不能只占头部以下的剩余高度');
    expect(padding.top, greaterThanOrEqualTo(headerRect.height),
        reason: '首屏内容必须整块落在头部下沿之下（留白取实测头部高度）');
  });

  testWidgets('洞察筛选抽屉：选择交易类型后显示已启用与条件摘要', (tester) async {
    await pump(tester);

    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();
    expect(find.text('洞察筛选'), findsOneWidget);
    expect(find.text('交易类型'), findsOneWidget);
    // 抽屉内的选格必须是项目自己的 PiggySelectChip，不能再退回 Material 的
    // FilterChip / ChoiceChip（M3 默认高度、留白与配色跟抽屉其它字段不是一套）。
    expect(find.byType(FilterChip), findsNothing);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byKey(const ValueKey('analyticsFilterType_expense')),
        findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('analyticsFilterType_income')));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.text('筛选已启用'), findsOneWidget);
    // 已应用条件是项目自己的 PiggyClosableChip（主色浅底 + 主色描边），
    // 不能再退回 Material 的 InputChip（M3 默认 8 圆角 + surface 白底 + 红叉，
    // 与左侧「筛选已启用」描边胶囊不是一套语言）。
    expect(find.widgetWithText(PiggyClosableChip, '收入'), findsOneWidget);
    expect(find.byType(InputChip), findsNothing);
    expect(find.text('当前筛选没有匹配账单'), findsOneWidget);

    await tester.tap(find.text('清空筛选'));
    await tester.pumpAndSettle();
    expect(find.text('筛选'), findsOneWidget);
    expect(find.text('350.00'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('洞察筛选抽屉：文本 / 单选 / 多选自定义字段', (tester) async {
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '商户',
            fieldType: 'text',
            syncId: const d.Value('sid_text'),
          ),
        );
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '场景',
            fieldType: 'singleSelect',
            syncId: const d.Value('sid_single'),
            optionsJson: const d.Value('["日常","工资"]'),
          ),
        );
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '标签',
            fieldType: 'multiSelect',
            syncId: const d.Value('sid_multi'),
            optionsJson: const d.Value('["外出","居家"]'),
          ),
        );
    await (db.update(db.transactions)).write(
      TransactionsCompanion(
        customValuesJson: d.Value(jsonEncode({
          'sid_text': '今天咖啡',
          'sid_single': '日常',
          'sid_multi': ['外出'],
        })),
      ),
    );

    await pump(tester);
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    expect(find.text('商户'), findsWidgets);
    expect(find.text('场景'), findsWidgets);
    expect(find.text('标签'), findsWidgets);

    await tester.enterText(find.byType(TextFormField), '咖啡');
    await tester
        .tap(find.byKey(const ValueKey('analyticsFilterOption_sid_single_日常')));
    await tester.pump();
    await tester
        .tap(find.byKey(const ValueKey('analyticsFilterOption_sid_multi_外出')));
    await tester.pump();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(PiggyClosableChip, '商户：咖啡'), findsOneWidget);
    expect(find.widgetWithText(PiggyClosableChip, '场景：日常'), findsOneWidget);
    expect(find.widgetWithText(PiggyClosableChip, '标签：外出'), findsOneWidget);
  });

  testWidgets('筛选清空：文本框内容同步清空', (tester) async {
    await db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: '商户',
            fieldType: 'text',
            syncId: const d.Value('sid_text'),
          ),
        );
    await pump(tester);
    await tester.tap(find.text('筛选'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextFormField), '咖啡');
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '咖啡');

    await tester.tap(find.text('清空筛选'));
    await tester.pump();

    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
  });

  testWidgets('窄屏（360dp）+ 两枚口径 chip：标题行不溢出、口径条不被缩放', (tester) async {
    // 有日期型字段时统计时间 chip 才会出现（它在标题行与金额 chip 并排）。
    // 360dp 窄屏 + 4 字字段名是最挤的组合：两枚 chip + 标题 + 右侧两个
    // IconButton 放不下，必须压缩到槽位内，而不是整行溢出红条。
    await db
        .into(db.customFieldDefinitions)
        .insert(CustomFieldDefinitionsCompanion.insert(
          ledgerId: 1,
          name: '消费日期',
          fieldType: 'date',
          syncId: const d.Value('f-date'),
        ));

    await pump(tester, size: const Size(1080, 6000)); // 360dp × dpr 3

    // 溢出会让 flutter_test 直接失败（RenderFlex overflowed），到达这里即无溢出
    expect(tester.takeException(), isNull);
    expect(find.byKey(const Key('amount-metric-chip')), findsOneWidget);
    expect(find.byKey(const Key('time-metric-chip')), findsOneWidget);
    // 两个口径入口装在同一款轨道里（与下方 周/月/季度… 滑块分段控件同源：
    // 轨道装饰与主色胶囊都取 segmented_control.dart 里的同一套函数）
    expect(find.byType(PiggySegmentTrack), findsOneWidget);
    for (final key in const ['amount-metric-chip', 'time-metric-chip']) {
      expect(
        find.descendant(
          of: find.byType(PiggySegmentTrack),
          matching: find.byKey(Key(key)),
        ),
        findsOneWidget,
      );
    }
    // 两枚 chip 都要**完整可见**：右缘不压右侧的日历 / 分享按钮，左缘不越过标题
    // （曾经的横向滚动方案会按 reverse 贴右、把左边的金额 chip 裁成「额▾」，
    // 392dp 真机实测到过）
    expect(
      tester.getRect(find.byKey(const Key('time-metric-chip'))).right,
      lessThanOrEqualTo(
          tester.getRect(find.byIcon(Icons.date_range_outlined)).left),
    );
    expect(
      tester.getRect(find.byKey(const Key('amount-metric-chip'))).left,
      greaterThanOrEqualTo(
          tester.getRect(find.byIcon(Icons.bar_chart_outlined)).right),
    );
    // **不再等比缩放整条**：旧实现在这个屏宽下用 FittedBox 把整条缩到 0.48
    // （字号 ≈6dp）。被缩放时实渲染宽会明显小于布局宽，这里逐层兜住。
    void expectNotScaled(Finder f) => expect(
          tester.getRect(f).width,
          moreOrLessEquals(tester.getSize(f).width, epsilon: 0.5),
        );
    expectNotScaled(find.byType(PiggySegmentTrack));
    expectNotScaled(find.byKey(const Key('amount-metric-chip')));
    expectNotScaled(find.byKey(const Key('time-metric-chip')));
    // 两段等分：金额段与时间段同宽（段宽由槽位给出，不随文案长短变）
    expect(
      tester.getSize(find.byKey(const Key('amount-metric-chip'))).width,
      moreOrLessEquals(
          tester.getSize(find.byKey(const Key('time-metric-chip'))).width,
          epsilon: 0.5),
    );
  });

  testWidgets('切口径：口径条尺寸与字号都不变（不整条缩放、不按内容自适应）', (tester) async {
    // 用户在 360dp 真机上的反馈「选完对应的文字后大小会变，而且好丑」：
    // 旧实现靠 FittedBox(scaleDown) 兜底，文案一换缩放比例就换
    // （「记账金额」0.48 ↔ 「水费」0.67），字号在 6dp / 8.7dp 之间跳。
    await db
        .into(db.customFieldDefinitions)
        .insert(CustomFieldDefinitionsCompanion.insert(
          ledgerId: 1,
          name: '水费',
          fieldType: 'amount',
          syncId: const d.Value('f-water'),
        ));
    final container = await pump(tester, size: const Size(1080, 6000));

    final track = tester.getSize(find.byType(PiggySegmentTrack));
    final seg = tester.getSize(find.byKey(const Key('amount-metric-chip')));
    final recorded = find.text('记账金额');
    expect(tester.getRect(recorded).width,
        moreOrLessEquals(tester.getSize(recorded).width, epsilon: 0.5));

    // 切到金额型自定义字段口径（文案 4 字 → 2 字）
    container.read(analyticsAmountMetricProvider.notifier).state =
        AnalyticsAmountMetric.customField('f-water');
    await tester.pumpAndSettle();

    // 整条口径条与段的尺寸纹丝不动；换的只有文字与底色
    expect(tester.getSize(find.byType(PiggySegmentTrack)), track);
    expect(tester.getSize(find.byKey(const Key('amount-metric-chip'))), seg);
    final water = find.text('水费');
    expect(tester.getRect(water).width,
        moreOrLessEquals(tester.getSize(water).width, epsilon: 0.5));
  });

  // 闪动回归：切口径在途帧保留上一份同口径结果，不塌成整屏转圈。
  //
  // 断言锚点说明：卡标题「支出趋势/收入趋势」由 _type 直接推导，切口径那一帧
  // 就会立刻变（这是对的，用户点了就该有反馈）；真正会被闪掉的是**数据**——
  // 旧实现 key 变 → 元素重建 → snapshot 归零 → 转圈 → 数据回来才重排。
  // 所以这里盯金额（数据驱动）：在途帧应继续显示上一份 350.00。
  testWidgets('切支出/收入在途时保留上一份结果，不塌成整屏转圈', (tester) async {
    final gated = _GatedRepository(db);
    await pump(tester, repository: gated);
    expect(find.text('350.00'), findsWidgets); // 首屏支出数据已到位

    gated.blocked = true;
    await tapIncome(tester); // 只走一帧：查询还卡在闸门上

    // 旧实现这里是 PiggySpinner（key 变 → 元素重建 → snapshot 归零）
    expect(find.byType(PiggySpinner), findsNothing);
    // 同口径（支出/收入共用一套 list 位次）→ 上一份结果继续渲染，不闪
    expect(find.text('350.00'), findsWidgets);
    // 两个分段控件（scope=<AnalyticsScope>、type=<String>）都应原地保留；
    // byType 是精确 runtimeType 匹配兜不住两种泛型实例化，改用无泛型 is 谓词
    expect(
      find.byWidgetPredicate((w) => w is WaitSlidingSegmentedControl),
      findsNWidgets(2),
    );

    gated.gate.complete();
    await tester.pumpAndSettle();
    // 放行后换成收入口径的数据（本期收入 100）
    expect(find.byType(PiggySpinner), findsNothing);
    expect(find.text('收入趋势'), findsOneWidget);
    expect(find.text('100.00'), findsWidgets);
    expect(find.text('350.00'), findsNothing);
  });

  // 切回已查过的口径命中结果缓存（SynchronousFuture），闸门还关着也能同帧出数。
  testWidgets('切回已查口径命中缓存，同帧出数不转圈', (tester) async {
    final gated = _GatedRepository(db);
    await pump(tester, repository: gated);

    gated.blocked = true;
    await tapIncome(tester); // 收入首次查询被闸门挡住
    expect(find.text('350.00'), findsWidgets); // 在途仍渲染支出

    gated.gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('收入趋势'), findsOneWidget);

    // 切回支出：命中缓存（SynchronousFuture），闸门重新关上也能同帧出数
    gated.blocked = true;
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text('支出'),
    ));
    await tester.pump();
    expect(find.byType(PiggySpinner), findsNothing);
    expect(find.text('支出趋势'), findsOneWidget);
    expect(find.text('350.00'), findsWidgets);
  });
}
