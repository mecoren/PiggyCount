// P1-C 增量分组集成测试：TransactionList 经「指纹门 → 增量 diff → 扁平项
// 重建」的完整链路。断言用 jumpToMonth（依赖 _dateIndexMap）探测日期索引的
// 增删 —— flutter_list_view 1.1.29 在 widget 测试环境不渲染任何子项
// （最小复现已验证，与列表逻辑无关），故不能用 find.text / DaySectionHeader。
// 数据级算法等价性见 transaction_day_grouper_test.dart 的差分对拍用例。
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/transaction_list.dart';

typedef TxItem = ({
  Transaction t,
  Category? category,
  Account? account,
  Account? toAccount
});

TxItem item(int id, DateTime at, {double amount = 10}) => (
      t: Transaction(
        id: id,
        ledgerId: 1,
        type: 'expense',
        amount: amount,
        happenedAt: at,
        excludeFromStats: false,
        excludeFromBudget: false,
        reimburseStatus: 'none',
      ),
      category: null,
      account: null,
      toAccount: null,
    );

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

  test('吸附日期：取日期倒序里第一个仍可见的组', () {
    const ordered = ['2026-10-03', '2026-10-02', '2026-10-01'];
    expect(
      firstVisibleDayKey(ordered, {'2026-10-02', '2026-10-01'}),
      '2026-10-02',
    );
    expect(firstVisibleDayKey(ordered, {'2026-10-01'}), '2026-10-01');
    expect(firstVisibleDayKey(ordered, {}), isNull);
  });

  Widget host(
    List<TxItem> transactions,
    GlobalKey<TransactionListState> key, {
    bool sticky = false,
  }) {
    return ProviderScope(
      // riverpod 3：provider 失败后会自动重试（指数退避 Timer），残留的 timer 会
      // 触发 flutter_test 的 pending-timer 断言。本测试只验证列表增量 diff 行为，
      // 故禁用重试。
      retry: (retryCount, error) => null,
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerIdProvider.overrideWith((ref) => 1),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: TransactionList(
            key: key,
            transactions: transactions,
            hideAmounts: false,
            stickyDateHeader: sticky,
          ),
        ),
      ),
    );
  }

  // 列表停在顶部时，首组卡片顶边正贴着视口顶，真实组头本来就完整可见；
  // 此时若也叠一层吸附头，它的圆角顶边会和卡片自己的圆角顶边重合成两条线
  // （用户看到的就是「两侧挑出两个尖」）。
  testWidgets('stickyDateHeader：停在顶部不叠吸附头（不与真实组头重影）', (tester) async {
    final key = GlobalKey<TransactionListState>();
    await tester.pumpWidget(host([
      for (var d = 1; d <= 10; d++)
        item(d, DateTime(2024, 1, d), amount: d.toDouble()),
    ], key, sticky: true));
    await tester.pumpAndSettle();

    expect(key.currentState!.stickyPinned, isFalse);
    expect(find.byKey(const Key('sticky-date-header')), findsNothing);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('stickyDateHeader：滚过日期头后出现吸附头，金额沿用日合计', (tester) async {
    final key = GlobalKey<TransactionListState>();
    await tester.pumpWidget(host([
      for (var d = 1; d <= 10; d++)
        item(d, DateTime(2024, 1, d), amount: d.toDouble()),
    ], key, sticky: true));
    await tester.pumpAndSettle();

    await tester.drag(find.byType(TransactionList), const Offset(0, -420));
    await tester.pumpAndSettle();

    expect(key.currentState!.stickyPinned, isTrue);
    expect(find.byKey(const Key('sticky-date-header')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(milliseconds: 1));
  });

  testWidgets('指纹门 → 增量 diff → _dateIndexMap 增删正确（jumpToMonth 探测）',
      (tester) async {
    final key = GlobalKey<TransactionListState>();

    // v1：2024-01 两天
    await tester.pumpWidget(host([
      item(1, DateTime(2024, 1, 1), amount: 5),
      item(2, DateTime(2024, 1, 2), amount: 6),
    ], key));
    await tester.pumpAndSettle();

    expect(key.currentState!.jumpToMonth(DateTime(2024, 1, 15)), isTrue);
    expect(key.currentState!.jumpToMonth(DateTime(2024, 2, 15)), isFalse);

    // v2（新列表引用，同 State 实例 → 走增量 diff）：
    // id1 同日改金额 + 新增 2024-02 新日
    await tester.pumpWidget(host([
      item(3, DateTime(2024, 2, 15), amount: 7),
      item(1, DateTime(2024, 1, 1), amount: 50),
      item(2, DateTime(2024, 1, 2), amount: 6),
    ], key));
    await tester.pumpAndSettle();

    // 新日进入日期索引，既有日保留
    expect(key.currentState!.jumpToMonth(DateTime(2024, 2, 15)), isTrue);
    expect(key.currentState!.jumpToMonth(DateTime(2024, 1, 15)), isTrue);

    // v3（新列表引用）：删除 2024-02 当日全部交易 → 该月从索引移除
    await tester.pumpWidget(host([
      item(1, DateTime(2024, 1, 1), amount: 50),
      item(2, DateTime(2024, 1, 2), amount: 6),
    ], key));
    await tester.pumpAndSettle();

    expect(key.currentState!.jumpToMonth(DateTime(2024, 2, 15)), isFalse);
    expect(key.currentState!.jumpToMonth(DateTime(2024, 1, 15)), isTrue);

    // v4（新列表引用，值相等 → diff 无变化）：索引保持
    await tester.pumpWidget(host([
      item(2, DateTime(2024, 1, 2), amount: 6),
      item(1, DateTime(2024, 1, 1), amount: 50),
    ], key));
    await tester.pumpAndSettle();

    expect(key.currentState!.jumpToMonth(DateTime(2024, 1, 15)), isTrue);

    // riverpod 3：ProviderScope 卸载时 StreamProvider 会去 dispose drift 的
    // QueryStream，后者用 Timer(Duration.zero) 异步关闭。该断言在测试体结束、
    // tearDown 之前执行，故必须在这里把时间推进掉，否则残留 pending timer。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // pump() 不推进时间，drift 的 Timer(Duration.zero) 需要显式推进才会执行
    await tester.pump(const Duration(milliseconds: 1));
  });
}
