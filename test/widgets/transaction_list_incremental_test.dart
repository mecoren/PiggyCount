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

typedef TxItem = ({Transaction t, Category? category, Account? account, Account? toAccount});

TxItem item(int id, DateTime at, {double amount = 10}) => (
      t: Transaction(
        id: id,
        ledgerId: 1,
        type: 'expense',
        amount: amount,
        happenedAt: at,
        excludeFromStats: false,
        excludeFromBudget: false,
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

  Widget host(List<TxItem> transactions, GlobalKey<TransactionListState> key) {
    return ProviderScope(
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
          ),
        ),
      ),
    );
  }

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

    // riverpod 3 改变了 provider 通知/重建时机，TransactionList 内部基于
    // Future.delayed 的收尾任务会比 2.x 晚结束。卸载并推进时间让残留 Timer
    // 跑完，避免 "A Timer is still pending even after the widget tree was disposed"。
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump(const Duration(seconds: 1));
  });
}
