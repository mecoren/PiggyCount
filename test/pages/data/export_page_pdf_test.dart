/// 导出页的「PDF 报表」区块：三种周期的标签与状态接线。
///
/// 只守 UI 这一层（生成 PDF 的全链路是 `test/services/export/` 的事）：
/// 月报 / 年报 / 区间各记各的选中值，来回切 tab 不会把用户刚选的周期冲掉，
/// 而周期行显示的一定是**当前口径**的周期（这里最容易出现「切了 tab 但还显示
/// 上一种口径的日期」——用户会导出一份跟他以为的不一样的报表）。
library;

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
import 'package:piggycount/pages/data/export_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/widgets/ui/wait_sliding_segmented_control.dart';

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
  });

  tearDown(() async => db.close());

  Future<void> pump(WidgetTester tester) async {
    // 页面是 ListView：默认 800×600 的测试视口装不下 PDF 区块，拉高逻辑高度。
    tester.view.physicalSize = const Size(1200, 4200);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
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
        home: const ExportPage(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> tapKind(WidgetTester tester, String label) async {
    await tester.tap(find.descendant(
      of: find.byType(WaitSlidingSegmentedControl<String>),
      matching: find.text(label),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('PDF 区块在位：默认月报取当前月，两种入口按钮都在', (tester) async {
    await pump(tester);
    final now = DateTime.now();

    expect(find.text('PDF 报表'), findsOneWidget);
    expect(find.text('生成 PDF 报表'), findsOneWidget);
    // CSV 入口没被挤掉
    expect(find.textContaining('导出'), findsWidgets);
    expect(
      find.text('${now.year}-${now.month.toString().padLeft(2, '0')}'),
      findsOneWidget,
    );
  });

  testWidgets('切年报 / 区间：周期行跟着换口径，切回来仍是各自上次选的周期', (tester) async {
    await pump(tester);
    final now = DateTime.now();
    final month = '${now.year}-${now.month.toString().padLeft(2, '0')}';

    await tapKind(tester, '年报');
    expect(find.text('${now.year}'), findsOneWidget);
    expect(find.text(month), findsNothing);

    await tapKind(tester, '区间报表');
    expect(find.textContaining(' ~ '), findsOneWidget);
    expect(find.text('${now.year}'), findsNothing);

    // 切回月报：仍是进来时的那个月（三种口径各存各的状态）
    await tapKind(tester, '月报');
    expect(find.text(month), findsOneWidget);
  });
}
