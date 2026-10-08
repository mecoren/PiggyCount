// 订阅管理页（周期账单派生视图）：空态 / 收录口径 / 年支出汇总 / 外币提示。
//
// 折算与汇总的数值口径已由 test/utils/subscription_estimate_test.dart 钉住，
// 这里只证明页面这一层：口径正确接线、收入与停用项不出现、外币不计入合计。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/transaction/subscription_page.dart';
import 'package:piggycount/providers/database_providers.dart';

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

  /// 建一条周期账单模板（直接经仓储，保持与真实写入路径一致）。
  Future<void> seed({
    required String frequency,
    required double amount,
    required String note,
    int interval = 1,
    String type = 'expense',
    bool enabled = true,
    String? currencyCode,
  }) async {
    await repo.addRecurringTransaction(
      ledgerId: 1,
      type: type,
      amount: amount,
      note: note,
      frequency: frequency,
      interval: interval,
      startDate: DateTime(2026, 1, 1),
      enabled: enabled,
      currencyCode: currencyCode,
    );
  }

  Future<void> pump(WidgetTester tester) async {
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
        home: const SubscriptionPage(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('无支出型周期账单 → 空态与创建引导', (tester) async {
    // 收入型不算订阅
    await seed(frequency: 'monthly', amount: 300, note: '工资', type: 'income');
    await pump(tester);

    expect(find.text('暂无订阅'), findsOneWidget);
    expect(find.text('去创建周期账单'), findsOneWidget);
    expect(find.text('工资'), findsNothing);
  });

  testWidgets('收录启用中的支出型模板，年支出与月均按频率折算', (tester) async {
    await seed(frequency: 'monthly', amount: 100, note: '视频会员'); // 1200/年
    await seed(frequency: 'yearly', amount: 200, note: '云存储'); // 200/年
    await seed(
      frequency: 'monthly',
      amount: 500,
      note: '已停用',
      enabled: false,
    );
    await seed(frequency: 'monthly', amount: 300, note: '工资', type: 'income');
    await pump(tester);

    // 收录口径：停用与收入项都不出现
    expect(find.text('视频会员'), findsOneWidget);
    expect(find.text('云存储'), findsOneWidget);
    expect(find.text('已停用'), findsNothing);
    expect(find.text('工资'), findsNothing);
    expect(find.text('共 2 个订阅'), findsOneWidget);

    // 年支出 = 100×12 + 200 = 1400；月均 ≈ 116.67
    expect(find.textContaining('1400.00'), findsWidgets);
    expect(find.textContaining('116.67'), findsWidgets);

    // 每条都带下次扣款日（无 endDate，必然算得出）
    expect(find.textContaining('下次扣款'), findsNWidgets(2));
    // 周期描述按各自频率渲染
    expect(find.textContaining('每月'), findsOneWidget);
    expect(find.textContaining('每年'), findsOneWidget);
  });

  testWidgets('外币订阅只计数不计入合计，并给出提示', (tester) async {
    await seed(frequency: 'monthly', amount: 100, note: '视频会员'); // 本位币
    await seed(
      frequency: 'yearly',
      amount: 999,
      note: 'Netflix',
      currencyCode: 'USD',
    );
    await pump(tester);

    expect(find.text('共 2 个订阅'), findsOneWidget);
    expect(find.text('另有 1 个外币订阅未计入合计'), findsOneWidget);
    expect(find.text('USD'), findsOneWidget);
    // 合计只含本位币项：1200（外币 999 被排除）
    expect(find.textContaining('1400.00'), findsNothing);
    expect(find.textContaining('1200.00'), findsWidgets);
  });
}
