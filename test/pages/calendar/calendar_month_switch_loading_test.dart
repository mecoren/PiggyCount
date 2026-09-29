/// 日历页滑月白闪回归（prd/calendar_holiday / 2026-09-29 滑月优化）。
///
/// `dailyTotalsByMonthProvider` 是 autoDispose family：切月 = 新实例，首帧必为
/// loading。修复前 loading 分支用 DelayedSkeleton 整卡替换日历 —— 卡片先塌成
/// 空白再弹回，就是滑月白闪。本用例把统计 future 钉在 pending，钉住
/// 「统计 loading 期间日历网格照常渲染、无骨架；数据迟到后金额正常补上」。
library;

import 'dart:async';

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
import 'package:piggycount/providers/calendar_providers.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/ui/ui.dart';

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

  Widget host(Completer<Map<String, (double, double)>> pendingTotals) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
        dailyTotalsByMonthProvider
            .overrideWith((ref, params) => pendingTotals.future),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const CalendarPage(),
      ),
    );
  }

  // DelayedSkeleton / LoggerService 的挂起定时器快进完,
  // 避免「A Timer is still pending」告警失败
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 3));
  }

  String dateKey(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  testWidgets('月度统计一直 loading 时,日历网格照常渲染且不出现骨架', (tester) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final pendingTotals = Completer<Map<String, (double, double)>>();
    await tester.pumpWidget(host(pendingTotals));
    await settle(tester);

    // 统计永不到达:日历本体必须在,骨架必须一个都没有(修复前这里塌成骨架)
    expect(find.byType(TableCalendar), findsOneWidget);
    expect(find.byType(SkeletonBar), findsNothing);
    // 网格内容真实渲染(今天日期数字在格子里),不是空白卡
    expect(find.text('${DateTime.now().day}'), findsOneWidget);

    // 数据迟到到达:金额正常补上,全程无异常
    pendingTotals.complete({
      dateKey(DateTime.now()): (66.0, 0.0),
    });
    await settle(tester);
    expect(tester.takeException(), isNull);
    expect(find.text('+66'), findsOneWidget);
  });
}
