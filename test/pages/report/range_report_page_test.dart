// F2 自定义区间报表：页面级冒烟 + 接线正确性。
//
// 仓储层断言已经由 `test/data/report_range_aggregation_test.dart` 钉住，这里
// 只证明页面这一层：
//  1. 三个对比窗（本期 / 环比 / 同比）各查各的区间，数字没串行；
//  2. 维度胶囊（支出/收入）会换掉序列、分类、标签三块的数据源，且**不**影响
//     对比表（表里三行永远同时给收支）；
//  3. 空区间走 AppEmpty 而不是画一屏零柱。
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
import 'package:piggycount/pages/report/range_report_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

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
    final categoryId = await db.into(db.categories).insert(
        CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    final tagId = await db
        .into(db.tags)
        .insert(TagsCompanion.insert(name: '报销中', syncId: const d.Value('t-1')));

    Future<void> tx(double amount,
        {required DateTime at, String type = 'expense', bool tag = true}) async {
      final id = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
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

  Future<void> pump(WidgetTester tester) async {
    // 页面是 ListView，默认 800×600 的测试视口装不下后三张卡（趋势/分类/标签），
    // 未构建的 sliver 里的文本找不到。把逻辑高度拉到 2000 一次性全渲染。
    tester.view.physicalSize = const Size(1200, 6000);
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
    await tester.tap(find.widgetWithText(ChoiceChip, '收入'));
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
}
