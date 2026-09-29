/// 日历页日格回归（prd/calendar_holiday 第 7 步 / AC-A1、A3、A4、A8）。
///
/// 覆盖：
///   - 休 / 班圆徽标渲染（放假日「休」、调休补班「班」）
///   - 农历 / 节气副标签渲染（2026-09-25 = 八月十五 → 「中秋节」）
///   - 系统大字号（textScale 1.3）下不出现 RenderFlex overflow
///
/// 数据来自 `HolidayService.loadAll()` 的预置兜底表（DB 为空 → 内置 2026 表），
/// 全程不出网。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:table_calendar/table_calendar.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/calendar/calendar_page.dart';
import 'package:piggycount/providers/database_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  Ledger cnyLedger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      );

  Widget host({double textScale = 1.0}) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        home: const CalendarPage(),
      ),
    );
  }

  /// 默认 800x600 视口装不下「日历卡 + 当日交易列表」,ListView 懒构建会让
  /// 下半屏压根不 build;撑高到手机比例。
  void useTallPhoneViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// 当日列表骨架(DelayedSkeleton)挂 300ms 定时器,快进测试时钟让它在用例
  /// 结束前自然触发完,避免「A Timer is still pending」告警失败。
  ///
  /// 末尾多推进 3s：`LoggerService` 落盘是 2s 节流定时器（仓库 debug 日志会
  /// 触发一次），不推完同样会被 fake_async 判为「Timer is still pending」。
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  /// 从 initState 的当月滑到 2026-09（跨月数按「当前月」推算，避免测试
  /// 绑死在某个具体日期上）。
  Future<void> swipeToSep2026(WidgetTester tester) async {
    final now = DateTime.now();
    final monthsGap = (now.year * 12 + now.month) - (2026 * 12 + 9);
    for (var i = 0; i < monthsGap; i++) {
      await tester.fling(
          find.byType(TableCalendar), const Offset(300, 0), 1200);
      await tester.pumpAndSettle();
    }
  }

  testWidgets('放假日显示「休」徽标、补班日显示「班」徽标、日期格有农历副标签', (tester) async {
    useTallPhoneViewport(tester);
    await tester.pumpWidget(host());
    await settle(tester);

    await swipeToSep2026(tester);
    await settle(tester);

    // 2026 年 9 月：09-25 / 26 / 27 中秋节放假 → 3 个「休」；09-20 调休补班 → 1 个「班」
    expect(find.text('休'), findsNWidgets(3));
    expect(find.text('班'), findsOneWidget);
    // 09-25 农历八月十五 → 副标签「中秋节」
    expect(find.text('中秋节'), findsOneWidget);
    // 普通日也有副标签（农历日），证明副标签行不只给节日渲染
    // （2026-09-19 = 八月初九，非节日 / 非节气）
    expect(find.text('初九'), findsWidgets);
  });

  testWidgets('底色块撑满整格（回归：不再塌成内容宽度的窄胶囊）', (tester) async {
    useTallPhoneViewport(tester);
    await tester.pumpWidget(host());
    await settle(tester);

    await swipeToSep2026(tester);
    await settle(tester);

    // 09-25 是放假日 → 有浅色底色块（与「今天」无关，不依赖用例执行当天日期）
    final cell = find.byKey(const ValueKey('CellContent-2026-9-25'));
    expect(cell, findsOneWidget);

    // 单元格本体 = table_calendar 给 builder 产物套的那层 Stack；底色块是它的
    // 第一个 Container 子孙。修复前该 Stack 被松约束，底色块随内容缩到约
    // 四成格宽（整行高的窄胶囊），此断言即用于钉住「撑满整格」。
    final cellSize = tester
        .getSize(find.ancestor(of: cell, matching: find.byType(Stack)).first);
    final fillSize = tester.getSize(
        find.descendant(of: cell, matching: find.byType(Container)).first);

    // 底色块内缩 1px（Container margin），宽高都应接近整格
    expect(fillSize.width, greaterThanOrEqualTo(cellSize.width - 3));
    expect(fillSize.height, greaterThanOrEqualTo(cellSize.height - 3));

    // 同一根因的另一症状：Stack 塌缩后徽标（右对齐）会被挤到居中数字上，
    // 修复后必须回到格子的右上角（AC-A4）。
    final badge = find.descendant(
      of: cell,
      matching: find.byWidgetPredicate((w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle),
    );
    expect(badge, findsOneWidget);
    final cellRect = tester
        .getRect(find.ancestor(of: cell, matching: find.byType(Stack)).first);
    final badgeRect = tester.getRect(badge);
    expect(badgeRect.width, 14);
    expect(cellRect.right - badgeRect.right, lessThanOrEqualTo(2));
  });

  testWidgets('textScale 1.3 下日期格不溢出', (tester) async {
    useTallPhoneViewport(tester);
    await tester.pumpWidget(host(textScale: 1.3));
    await settle(tester);

    // 日期格装的是「数字 + 副标签 + 最多两行金额」，FittedBox 兜底后不应有
    // RenderFlex overflow（溢出会以异常形式被测试框架捕获）
    expect(tester.takeException(), isNull);
    // 确认当月日期格确实渲染了（而不是整片空白导致「没溢出」假绿）
    expect(find.byType(TableCalendar), findsOneWidget);
    expect(find.text('初九'), findsWidgets);
  });
}
