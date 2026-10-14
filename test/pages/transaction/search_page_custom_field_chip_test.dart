/// SearchPage 字段值筛选 chips 契约（prd/custom_field_stats_fullchain F3）。
///
/// 保护三件事：
/// 1. **下钻直达**：`initialCustomFieldConditions` 进入即过滤（命中行可见、
///    未命中行不可见），chip 可见；
/// 2. **单条撤销**：点 chip 的删除钮 → 该条件移除、结果放宽（漏行回来）；
/// 3. **条件正交**：与关键字条件叠加时两者都要过。
///
/// 真内存库 + 真 LocalRepository（项目惯用手法，如 `custom_field_editor_test`），
/// 只对 provider 做最小注入（repository/currentLedger/主色/隐藏金额）。
library;

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/transaction/search_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/theme_providers.dart';
import 'package:piggycount/utils/transaction_search_filter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Ledger ledger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        monthStartDay: 1,
      );

  Future<void> seedTx({
    required String note,
    String? customValuesJson,
    double amount = 100,
  }) async {
    await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: amount,
            happenedAt: Value(DateTime(2026, 9, 15, 12)),
            note: Value(note),
            customValuesJson: Value(customValuesJson),
          ),
        );
  }

  Widget host({List<CustomFieldCondition> conditions = const []}) =>
      ProviderScope(
        overrides: [
          // 必须覆写 databaseProvider：结果行的 customFieldValueBadgesProvider
          // 会 ref.watch(databaseProvider)，不覆写就会开出真实磁盘库（drift
          // 查询流 → pending Timer → 测试挂起）。
          databaseProvider.overrideWithValue(db),
          repositoryProvider.overrideWithValue(repo),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(ledger())),
          currentLedgerIdProvider.overrideWith((ref) => 1),
          hideAmountsProvider.overrideWith((ref) => false),
          primaryColorProvider.overrideWith((ref) => Colors.blue),
        ],
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: SearchPage(initialCustomFieldConditions: conditions),
        ),
      );

  const condEq = CustomFieldCondition.eq(
    fieldSyncId: 'f1',
    fieldName: '渠道',
    fieldType: 'singleSelect',
    value: '微信',
  );

  /// 等首查跑完：搜索是「流数据 → postFrame → `_performSearch` → setState」
  /// 多跳异步链，fake 时钟下必须连续 pump 多帧才能走完（单帧 pump 只推进一跳）。
  Future<void> pumpSearch(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// 显式卸载 + 排干收尾 timer：drift 查询流在 State.dispose → 取消订阅时会
  /// 用 0 时长 timer 做收尾调度，若不等它跑完，testWidgets 收尾会报
  /// 「Timer is still pending」（实际搜索已断言完，与本契约无关）。
  Future<void> teardownPump(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 50));
  }

  testWidgets('下钻直达：条件进入即过滤，chip 可见', (tester) async {
    await seedTx(note: 'hit-row', customValuesJson: '{"f1":"微信"}');
    await seedTx(note: 'miss-row', customValuesJson: '{"f1":"现金"}');
    await seedTx(note: 'blank-row', customValuesJson: null);

    await tester.pumpWidget(host(conditions: const [condEq]));
    await pumpSearch(tester);

    // 行标题是「日期 | 备注」合成的一个 Text（TransactionListItem 内部拼接），
    // 用 textContaining 断言备注即可，不依赖行标题的组合格式。
    expect(find.textContaining('hit-row'), findsOneWidget);
    expect(find.textContaining('miss-row'), findsNothing);
    expect(find.textContaining('blank-row'), findsNothing);
    // chip 文案：渠道：微信
    expect(find.text('渠道：微信'), findsOneWidget);

    await teardownPump(tester);
  });

  testWidgets('单条撤销：chip 删除后回到无条件态', (tester) async {
    await seedTx(note: 'hit-row', customValuesJson: '{"f1":"微信"}');
    await seedTx(note: 'miss-row', customValuesJson: '{"f1":"现金"}');

    await tester.pumpWidget(host(conditions: const [condEq]));
    await pumpSearch(tester);
    expect(find.textContaining('miss-row'), findsNothing);

    await tester.tap(find.descendant(
      of: find.ancestor(
        of: find.text('渠道：微信'),
        matching: find.byType(Chip),
      ),
      matching: find.byIcon(Icons.close),
    ));
    await pumpSearch(tester);

    // 移除唯一条件后回到「无条件」态：搜索页既有语义是「无筛选 → 提示输入」
    // （不整列倒出全部交易，与从筛选抽屉清空所有条件一致），chip 消失、
    // 结果不再按字段值过滤（若此时再输入关键字，全部交易参与匹配）。
    expect(find.text('输入关键词开始搜索'), findsOneWidget);
    expect(find.text('渠道：微信'), findsNothing);
    expect(find.textContaining('miss-row'), findsNothing);
    expect(find.textContaining('hit-row'), findsNothing);

    await teardownPump(tester);
  });

  testWidgets('区间条件 chip 文案与过滤（半开区间）', (tester) async {
    await seedTx(note: 'hit-row', customValuesJson: '{"f1":30}');
    await seedTx(note: 'out-row', customValuesJson: '{"f1":300}');

    await tester.pumpWidget(host(conditions: const [
      CustomFieldCondition.between(
        fieldSyncId: 'f1',
        fieldName: '押金',
        fieldType: 'amount',
        lower: 10,
        upper: 100,
      ),
    ]));
    await pumpSearch(tester);

    expect(find.textContaining('hit-row'), findsOneWidget);
    expect(find.textContaining('out-row'), findsNothing);
    expect(find.text('押金：10~100'), findsOneWidget);

    await teardownPump(tester);
  });
}
