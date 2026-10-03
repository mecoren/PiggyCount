/// 区间选择抽屉（`showPiggyRangePickerSheet`）回归。
///
/// 覆盖：
///   - 日期格沿用日历页口径：农历/节日副标签 + 休/班徽标（预置 2026 表，全程不出网）
///   - 两次点选定区间（终点早于起点自动对调；同一天两次 = 单日区间）
///   - 只点了起点时顶栏 ✓ 禁用，点完启用并回传 DateTimeRange
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
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/range_picker_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  /// 抽屉选完后的回传结果（每个用例独立，避免跨用例串值）。
  late ValueNotifier<DateTimeRange?> picked;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    picked = ValueNotifier<DateTimeRange?>(null);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async {
    picked.dispose();
    await db.close();
  });

  Widget host() {
    return ProviderScope(
      overrides: [repositoryProvider.overrideWithValue(repo)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  picked.value = await showPiggyRangePickerSheet(
                    context,
                    firstDate: DateTime(2026, 1, 1),
                    lastDate: DateTime(2026, 9, 30),
                    initialStart: DateTime(2026, 9, 1),
                    initialEnd: DateTime(2026, 9, 30),
                  );
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 抽屉内没有定时器，但节假日 provider 与 LoggerService 会挂 2s 节流定时器
  /// （仓库 debug 日志每次都会重置），不推完会被判「Timer is still pending」。
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
    await tester.pumpAndSettle();
  }

  Future<void> openSheet(WidgetTester tester) async {
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.tap(find.text('打开'));
    await settle(tester);
  }

  /// 抽屉里的日历（泛型实参不进 runtimeType，byType 匹配不到，用谓词）。
  Finder sheetCalendar() => find.byWidgetPredicate((w) => w is TableCalendar);

  /// 按 y/m/d 定位日格（table_calendar 给 builder 产物套的 CellContent key）。
  Finder cellOf(int y, int m, int d) =>
      find.byKey(ValueKey('CellContent-$y-$m-$d'));

  /// 点某一天（点格内数字文本）。
  Future<void> tapDay(WidgetTester tester, int day) async {
    await tester.tap(find.descendant(
      of: cellOf(2026, 9, day),
      matching: find.text('$day'),
    ));
    await settle(tester);
  }

  /// 顶栏确认钩子（find.byIcon 命中的是 Icon，取它外层的 IconButton）。
  IconButton confirmButton(WidgetTester tester) =>
      tester.widget<IconButton>(find
          .ancestor(
              of: find.byIcon(Icons.check), matching: find.byType(IconButton))
          .first);

  testWidgets('打开即带初始区间，日期格有节日副标签与休/班徽标', (tester) async {
    await openSheet(tester);

    expect(find.text('选择区间'), findsOneWidget);
    expect(find.text('2026.09.01 ~ 2026.09.30'), findsOneWidget);
    // 09-25 中秋（放假日）→ 副标签 + 「休」徽标；09-20 调休补班 → 「班」
    expect(find.descendant(of: cellOf(2026, 9, 25), matching: find.text('中秋节')),
        findsOneWidget);
    expect(find.descendant(of: cellOf(2026, 9, 25), matching: find.text('休')),
        findsOneWidget);
    expect(find.descendant(of: cellOf(2026, 9, 20), matching: find.text('班')),
        findsOneWidget);
    // 普通日不带徽标（防徽标误挂到非节假日）
    expect(find.descendant(of: cellOf(2026, 9, 19), matching: find.text('休')),
        findsNothing);
    expect(find.descendant(of: cellOf(2026, 9, 19), matching: find.text('班')),
        findsNothing);
  });

  testWidgets('两次点选定区间：只点起点时 ✓ 禁用，选完启用并回传', (tester) async {
    await openSheet(tester);

    await tapDay(tester, 28);
    // 只点了起点 → 提示下一步，顶栏 ✓ 禁用（防「只选了一半」就应用）
    expect(find.text('点一下选结束日期'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNull);

    await tapDay(tester, 30);
    expect(find.text('2026.09.28 ~ 2026.09.30'), findsOneWidget);
    expect(confirmButton(tester).onPressed, isNotNull);

    await tester.tap(find.byIcon(Icons.check));
    await settle(tester);
    expect(picked.value, isNotNull);
    expect(picked.value!.start, DateTime(2026, 9, 28));
    expect(picked.value!.end, DateTime(2026, 9, 30));
    expect(sheetCalendar(), findsNothing);
  });

  testWidgets('终点早于起点自动对调；同一天点两次 = 单日区间', (tester) async {
    await openSheet(tester);

    await tapDay(tester, 30);
    await tapDay(tester, 12);
    expect(find.text('2026.09.12 ~ 2026.09.30'), findsOneWidget);

    // 已有完整区间后再点任意一天 = 重新选起点
    await tapDay(tester, 5);
    expect(find.text('点一下选结束日期'), findsOneWidget);
    await tapDay(tester, 5);
    expect(find.text('2026.09.05 ~ 2026.09.05'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check));
    await settle(tester);
    expect(picked.value!.start, DateTime(2026, 9, 5));
    expect(picked.value!.end, DateTime(2026, 9, 5));
  });

  testWidgets('滑到别的月点日期，不会被弹回初始（今天）所在的月', (tester) async {
    await openSheet(tester);
    expect(find.text('2026年9月'), findsOneWidget);

    // 往前滑一个月（table_calendar 内部焦点移到 8 月）
    await tester.fling(sheetCalendar(), const Offset(300, 0), 1200);
    await settle(tester);
    expect(find.text('2026年8月'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('CellContent-2026-8-12')),
      matching: find.text('12'),
    ));
    await settle(tester);

    // 回归：table_calendar 的 didUpdateWidget 会把内部焦点拉回 focusedDay，
    // 若这里回写的是初值，点完日期视图就跳回 9 月（= 报表默认区间的今天所在月）
    expect(find.text('2026年8月'), findsOneWidget);
    expect(find.text('2026年9月'), findsNothing);
    expect(find.text('点一下选结束日期'), findsOneWidget);

    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('CellContent-2026-8-20')),
      matching: find.text('20'),
    ));
    await settle(tester);
    expect(find.text('2026年8月'), findsOneWidget);
    expect(find.text('2026.08.12 ~ 2026.08.20'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.check));
    await settle(tester);
    expect(picked.value!.start, DateTime(2026, 8, 12));
    expect(picked.value!.end, DateTime(2026, 8, 20));
  });

  testWidgets('越界日（晚于 lastDate）不可选', (tester) async {
    await openSheet(tester);
    // 九月视图尾部的 10-01 已越界（lastDate = 09-30）→ 弱显且点不动
    expect(find.byKey(const ValueKey('CellContent-2026-10-1')), findsOneWidget);
    await tester.tap(find.descendant(
      of: find.byKey(const ValueKey('CellContent-2026-10-1')),
      matching: find.text('1'),
    ));
    await settle(tester);
    // 起点仍是初始值（越界日的点按被 table_calendar 拦掉）
    expect(find.text('2026.09.01 ~ 2026.09.30'), findsOneWidget);
    expect(picked.value, isNull);
  });

  testWidgets('关闭（X）不回调结果', (tester) async {
    await openSheet(tester);
    await tester.tap(find.byIcon(Icons.close));
    await settle(tester);
    expect(picked.value, isNull);
    expect(sheetCalendar(), findsNothing);
  });
}
