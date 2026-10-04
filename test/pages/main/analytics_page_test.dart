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
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/main/analytics_page.dart';
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

  Future<void> pump(WidgetTester tester, {LocalRepository? repository}) async {
    // 页面是 ListView，默认 800×600 视口装不下趋势/分类构成卡，未构建的
    // sliver 里文本找不到。把逻辑高度拉大一次性全渲染。
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
        home: const AnalyticsPage(),
      ),
    ));
    await tester.pumpAndSettle();
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
    expect(find.byType(WaitSlidingSegmentedControl<String>), findsNWidgets(2));

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
