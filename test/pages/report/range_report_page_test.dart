// F2 自定义区间报表：页面级冒烟 + 接线正确性。
//
// 仓储层断言已经由 `test/data/report_range_aggregation_test.dart` 钉住，这里
// 只证明页面这一层：
//  1. 三个对比窗（本期 / 环比 / 同比）各查各的区间，数字没串行；
//  2. 维度 tab（支出/收入）会换掉序列、分类、标签三块的数据源，且**不**影响
//     对比表（表里三行永远同时给收支）；
//  3. 空区间走 AppEmpty 而不是画一屏零柱；
//  4. 切维度 / 切区间的在途帧保留上一份结果，不塌成整屏转圈（闪动回归）。
library;

import 'dart:async';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/report/range_report_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/widgets/ui/wait_sliding_segmented_control.dart';
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
  }) async {
    if (blocked) await gate.future;
    return super.totalsByDay(
      ledgerId: ledgerId,
      type: type,
      start: start,
      end: end,
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

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
    final tagId = await db.into(db.tags).insert(
        TagsCompanion.insert(name: '报销中', syncId: const d.Value('t-1')));

    Future<void> tx(double amount,
        {required DateTime at,
        String type = 'expense',
        bool tag = true}) async {
      final id = await db
          .into(db.transactions)
          .insert(TransactionsCompanion.insert(
            ledgerId: 1,
            categoryId: d.Value(categoryId),
            type: type,
            amount: amount,
            happenedAt: d.Value(at),
            syncId: d.Value('tx-$type-${at.millisecondsSinceEpoch}-$amount'),
          ));
      if (tag) {
        await db.into(db.transactionTags).insert(
            TransactionTagsCompanion.insert(transactionId: id, tagId: tagId));
      }
    }

    // 本期 9/1~9/10：支出 300（只有 9/3 那笔打标）、收入 100（未打标）
    await tx(200, at: DateTime(2026, 9, 3));
    await tx(100, at: DateTime(2026, 9, 8), tag: false);
    await tx(100, at: DateTime(2026, 9, 5), type: 'income', tag: false);
    // 环比窗 8/23~9/1（等长 9 天）：支出 100
    await tx(100, at: DateTime(2026, 8, 25));
    // 同比窗 2025/9/1~9/10：支出 50
    await tx(50, at: DateTime(2025, 9, 4));
    // 窗外干扰项（必须不参与）
    await tx(9999, at: DateTime(2026, 9, 20));
  });

  tearDown(() async => db.close());

  Future<void> pump(WidgetTester tester, {LocalRepository? repository}) async {
    // 页面是 ListView，默认 800×600 的测试视口装不下后三张卡（趋势/分类/标签），
    // 未构建的 sliver 里的文本找不到。把逻辑高度拉到 2000 一次性全渲染。
    tester.view.physicalSize = const Size(1200, 6000);
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
        home: RangeReportPage(
          initialStart: DateTime(2026, 9, 1),
          initialEnd: DateTime(2026, 9, 10),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('三个对比窗各查各的区间，标签维度进入报表', (tester) async {
    await pump(tester);

    // 支出行：本期 300 / 环比 +200% / 同比 +500%
    expect(find.text('300.00'), findsWidgets);
    expect(find.text('+200.0%'), findsOneWidget);
    expect(find.text('+500.0%'), findsOneWidget);
    // 环比、同比两列下方是对比窗绝对额
    expect(find.text('100.00'), findsWidgets);
    expect(find.text('50.00'), findsWidgets);
    // 标签是独立维度：只有 9/3 那笔打了标 → 标签块 200/1笔，
    // 分类块仍是全量 300/2笔（两者不同源，串行就会露出来）
    expect(find.text('报销中'), findsOneWidget);
    expect(find.textContaining('200.00'), findsWidgets);
    expect(find.text('1笔'), findsOneWidget);
    expect(find.text('2笔'), findsOneWidget);
    expect(find.textContaining('餐饮'), findsOneWidget);
    // 9 天区间 → 按日柱（dayChartLimit 之上才并月）
    expect(find.text('自定义区间报表'), findsOneWidget);
  });

  testWidgets('切到收入维度：标签块清空、对比表数字不变', (tester) async {
    await pump(tester);
    // 维度选择器是 WaitSlidingSegmentedControl（项目通用 tab 样式）。页面上
    // 「收入」出现两次（tab 段 + 对比表行标签），必须限定在控件内定位。
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text('收入'),
    ));
    await tester.pumpAndSettle();

    // 收入 100 未打标 → 标签构成空
    expect(find.text('报销中'), findsNothing);
    expect(find.textContaining('餐饮'), findsOneWidget);
    // 对比表同时给收支两行，与维度胶囊无关
    expect(find.text('+200.0%'), findsOneWidget);
    expect(find.text('+500.0%'), findsOneWidget);
  });

  testWidgets('区间内无记账 → 空态而不是全零柱', (tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: RangeReportPage(
          initialStart: DateTime(2020, 1, 1),
          initialEnd: DateTime(2020, 1, 8),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('这段时间还没有记账，点上方日期换一个区间'), findsOneWidget);
    // 区间与分类/标签卡都不渲染，但对比表还在（三行全零）
    expect(find.text('餐饮'), findsNothing);
    expect(find.text('报销中'), findsNothing);
  });

  /// 抽屉里的日历（泛型实参不进 runtimeType，byType 匹配不到，用谓词）。
  Finder sheetCalendar() => find.byWidgetPredicate((w) => w is TableCalendar);

  // 区间选择走项目口径抽屉（与日历页同款日期格：农历副标签 + 休/班徽标 + 放假
  // 底色），不再是 Material 原生 showDateRangePicker。
  testWidgets('点区间卡 → 项目区间抽屉，改完区间报表跟着换', (tester) async {
    await pump(tester);
    await tester.tap(find.text('更换区间'));
    await tester.pumpAndSettle();

    expect(find.text('选择区间'), findsOneWidget);
    expect(sheetCalendar(), findsOneWidget);
    // 抽屉内初始区间 = 页面当前区间（页面右端是半开 09-10，抽屉按「含末日」
    // 显示 09-09）；这行文案在副标题 + 区间卡 + 抽屉副标题三处都出现
    expect(find.text('2026.09.01 ~ 2026.09.09'), findsWidgets);

    for (final d in [5, 7]) {
      await tester.tap(find.descendant(
        of: find.byKey(ValueKey('CellContent-2026-9-$d')),
        matching: find.text('$d'),
      ));
      await tester.pumpAndSettle();
    }
    expect(find.text('2026.09.05 ~ 2026.09.07'), findsWidgets);

    await tester.tap(find.byIcon(Icons.check));
    await tester.pumpAndSettle();

    // 抽屉收起，页面区间（副标题 + 区间卡两处）同步更新
    expect(sheetCalendar(), findsNothing);
    expect(find.text('2026.09.05 ~ 2026.09.07'), findsNWidgets(2));
  });

  // 闪动回归：切维度 / 换区间会重新查库，旧实现是「查询在途 → 整页换成居中
  // 转圈 → 数据回来重建」，于是闪一下、滚动位置也回到顶部。现在在途帧继续
  // 渲染上一份结果，只有贴顶进度条在动。
  testWidgets('切维度在途时保留上一份结果，不塌成整屏转圈', (tester) async {
    final gated = _GatedRepository(db);
    await pump(tester, repository: gated);
    expect(find.text('300.00'), findsWidgets); // 首屏支出数据已到位

    gated.blocked = true;
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text('收入'),
    ));
    await tester.pump(); // 只走一帧：查询还卡在闸门上

    expect(find.byType(PiggySpinner), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    // 列表没被销毁重建：对比表 / 分段控件 / 三张卡原地保留（滚动位置也就没丢）
    expect(find.byType(WaitSlidingSegmentedControl<String>), findsOneWidget);
    expect(find.text('+200.0%'), findsOneWidget);
    expect(find.text('收入趋势'), findsOneWidget);

    gated.gate.complete();
    await tester.pumpAndSettle();
    // 放行后是收入口径（100 未打标 → 标签块清空），缓存命中没串数
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.text('报销中'), findsNothing);
    expect(find.textContaining('餐饮'), findsOneWidget);

    // 切回支出：命中维度缓存（SynchronousFuture），闸门还关着也能同帧出数
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text('支出'),
    ));
    await tester.pump();
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(find.byType(PiggySpinner), findsNothing);
    expect(find.text('支出趋势'), findsOneWidget);
    expect(find.text('300.00'), findsWidgets);
  });
}
