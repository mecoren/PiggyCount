// 周期账单「表单抽屉」契约（AGENTS.md：表单抽屉一律用悬浮卡片外壳）：
// 新建与编辑都必须以 [PiggyFormSheet] 弹出，不得回退成整屏页面。
//
// 覆盖两个入口：
//  - 周期账单列表（标题栏「+」与条目点击）
//  - 订阅管理（订阅条目点击复用同一个编辑器）

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/transaction/recurring_transaction_page.dart';
import 'package:piggycount/pages/transaction/subscription_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/ui/form_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
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

  Future<void> seedTemplate({String note = '视频会员'}) async {
    await repo.addRecurringTransaction(
      ledgerId: 1,
      type: 'expense',
      amount: 100,
      note: note,
      frequency: 'monthly',
      interval: 1,
      startDate: DateTime(2026, 1, 20),
      enabled: true,
    );
  }

  Future<void> pumpHost(WidgetTester tester, Widget home) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('周期账单列表「+」→ 悬浮卡片表单抽屉（不是整屏页）', (tester) async {
    await pumpHost(tester, const RecurringTransactionPage());

    await tester.tap(find.byIcon(Icons.add));
    await tester.pumpAndSettle();

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    // 抽屉自带居中标题与「取消｜保存」按钮行
    expect(find.text('添加周期账单'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    expect(find.text('保存'), findsOneWidget);
    // 新建态不出现删除
    expect(find.text('删除'), findsNothing);

    // 取消即收起，回到列表。表单较长，按钮行在卡片内容末尾 —— 需先滚到可见
    // （PiggyFormSheet 的既定行为：标题与按钮行随卡片一起滚动）。
    await tester.ensureVisible(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.byType(PiggyFormSheet), findsNothing);
  });

  testWidgets('周期账单条目点击 → 编辑抽屉，删除落在表单主体内', (tester) async {
    await seedTemplate();
    await pumpHost(tester, const RecurringTransactionPage());

    // 卡片第二行是「账本 · 频率 · 时间」，点频率文案命中卡片
    await tester.tap(find.text('每月'));
    await tester.pumpAndSettle();

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('编辑周期账单'), findsOneWidget);
    // 编辑态的删除按钮渲染在表单主体末尾（与预算 / 账户抽屉同款）
    expect(find.text('删除'), findsOneWidget);
    expect(find.widgetWithText(OutlinedButton, '删除'), findsOneWidget);
  });

  testWidgets('订阅管理条目点击 → 同一个编辑抽屉', (tester) async {
    await seedTemplate();
    await pumpHost(tester, const SubscriptionPage());

    await tester.tap(find.text('视频会员'));
    await tester.pumpAndSettle();

    expect(find.byType(PiggyFormSheet), findsOneWidget);
    expect(find.text('编辑周期账单'), findsOneWidget);
  });
}
