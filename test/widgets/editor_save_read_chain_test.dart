/// 关键路径补强（`prd/engineering_debt_cleanup` R3）：**编辑器保存 → 落库 →
/// 读路径看得到** 的主链路。
///
/// 分工背景（2026-10-12 盘点）：`quick_entry_mode_test.dart` 只断言编辑器 UI
/// 落点（`AmountEditorSheet` 在不在），`recycle_bin_round_trip_test.dart` 等
/// repository 级测试不走 UI；「从界面点完保存、库与统计真的变了」这条跨
/// UI → Repository → 统计 SQL 的链此前无人守（设备 E2E 只有
/// `integration_test/recent_entry_inherit_test.dart` 一个文件且 CI 不跑）。
/// 本测试用内存库 + ProviderScope 覆盖，在宿主 VM 可跑可验。
///
/// 基建照抄 `integration_test/recent_entry_inherit_test.dart` 的 override 四件套
/// （Riverpod 3 要求同一棵树上两次 pumpWidget 的覆盖项数量一致）与
/// `quick_entry_mode_test.dart` 的 seed 手法；保存后不用 `pumpAndSettle`——
/// LoggerService 的 2s 节流落盘定时器让它永不收敛，改固定时长 pump
/// （同上两文件的既有记录）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/transaction/transaction_editor_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/ui_state_providers.dart';
import 'package:piggycount/utils/transaction_edit_utils.dart';
import 'package:piggycount/widgets/category/category_selector.dart';

/// 编辑入口宿主：一个按钮走生产同款 `TransactionEditUtils.editTransaction`。
class _EditLauncher extends ConsumerWidget {
  const _EditLauncher({required this.transaction, required this.category});

  final Transaction transaction;
  final Category? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () =>
                TransactionEditUtils.editTransaction(context, ref, transaction, category),
            child: const Text('edit'),
          ),
        ),
      );
}

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
        monthStartDay: 1,
        syncId: 'ledger-1',
      );

  /// 挂记账页（与生产同一入口组件）；外层 Scaffold 同
  /// `recent_entry_inherit_test.dart` 的注释理由（Navigator 路由边界）。
  Future<void> openEditor(WidgetTester tester) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        databaseProvider.overrideWithValue(db),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
        // 恒覆盖（Riverpod 3 覆盖项数量一致性断言）；null = 无默认账户，
        // 本链路不验证账户预填，落一笔无账户交易即可走完保存与读路径。
        defaultExpenseAccountIdProvider.overrideWith((ref) async => null),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: TransactionEditorPage(
            initialKind: 'expense',
            quickAdd: true,
            quickMode: true,
            renderAsBottomSheet: true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 保存后的收敛等待：LoggerService 2s 节流定时器让 pumpAndSettle 永不收敛。
  Future<void> settleAfterSave(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 900));
  }

  /// 收尾排空：drift 的 `StreamQueryStore.markAsClosed` 用 `Timer.run`
  /// （零延迟）关流查询缓存，而它只在 ProviderScope 卸载时才创建 —— 不主动
  /// 卸载 + 推进时钟，flutter_test 的「A Timer is still pending」断言必炸
  /// （drift 源码 `stream_queries.dart:150-151` 对此有专门注释）。
  /// 在测试体内先卸载树，零定时器才有机会在fake_async 里烧掉。
  Future<void> drainAndUnmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  }

  group('编辑器保存 → 落库 → 读路径主链路', () {
    testWidgets('新建支出：列表 / 区间统计 / 账本余额三条读路径都看得到', (tester) async {
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await openEditor(tester);

      // 选分类 → 分类选择器（模态）→ 餐饮
      await tester.tap(find.text('选择分类'));
      await tester.pumpAndSettle();
      expect(find.byType(CategorySelector), findsOneWidget);
      await tester.tap(find.text('餐饮').last);
      await tester.pumpAndSettle();

      // 金额键盘输入 12 → 完成
      await tester.tap(find.text('1'));
      await tester.tap(find.text('2'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppLocalizations.of(
              tester.element(find.byType(TransactionEditorPage)))
          .commonFinish));
      await settleAfterSave(tester);

      // 读路径 1：交易列表数据源
      final txs = await repo.getTransactionsByLedger(1);
      expect(txs, hasLength(1), reason: '保存后账本下应恰好一笔交易');
      expect(txs.single.type, 'expense');
      expect(txs.single.amount, closeTo(12, 0.001));
      expect(txs.single.categoryId, isNotNull);

      // 读路径 2：统计（totalsInRange 口径 exclude_from_stats = 0）
      final now = DateTime.now();
      final totals = await repo.totalsInRange(
        ledgerId: 1,
        start: DateTime(now.year, now.month).subtract(const Duration(days: 1)),
        end: DateTime(now.year, now.month + 1, 1),
      );
      expect(totals.$2, closeTo(12, 0.001), reason: '区间统计支出应含新交易');
      expect(totals.$1, closeTo(0, 0.001));

      // 读路径 3：账本汇总（余额 = 收入 - 支出）
      final stats = await repo.getLedgerStats(ledgerId: 1);
      expect(stats.transactionCount, 1);
      expect(stats.balance, closeTo(-12, 0.001));

      await drainAndUnmount(tester);
    });

    testWidgets('新建支出金额 0：可保存并落库', (tester) async {
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await openEditor(tester);

      await tester.tap(find.text('选择分类'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('餐饮').last);
      await tester.pumpAndSettle();

      // 初始金额为 0，不输入数字，直接完成。
      await tester.tap(find.text(AppLocalizations.of(
              tester.element(find.byType(TransactionEditorPage)))
          .commonFinish));
      await settleAfterSave(tester);

      final txs = await repo.getTransactionsByLedger(1);
      expect(txs, hasLength(1), reason: '0 元也必须允许落库');
      expect(txs.single.amount, closeTo(0, 0.001));

      final stats = await repo.getLedgerStats(ledgerId: 1);
      expect(stats.transactionCount, 1);
      expect(stats.balance, closeTo(0, 0.001));

      await drainAndUnmount(tester);
    });

    testWidgets('编辑已存在交易：改金额后保存，读路径反映新值', (tester) async {
      final categoryId = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: categoryId,
        happenedAt: DateTime.now(),
      );
      final tx = (await repo.getTransactionsByLedger(1)).single;
      final category = await repo.getCategoryById(categoryId);

      // 生产同款编辑入口：`TransactionEditUtils.editTransaction` 负责加载回显
      // 参数（金额/日期/备注/账户/标签/自定义字段）再弹抽屉 —— 页面自身不按
      // editingTransactionId 查库，直传 id 会是空表单。
      await tester.pumpWidget(ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          databaseProvider.overrideWithValue(db),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
          defaultExpenseAccountIdProvider.overrideWith((ref) async => null),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: _EditLauncher(transaction: tx, category: category),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();

      // 回显校验：金额位应显示原金额 10
      expect(find.text('10'), findsWidgets, reason: '编辑态应回显原金额');

      // 金额键盘追加一位：10 → 105
      await tester.tap(find.text('5'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(AppLocalizations.of(
              tester.element(find.byType(TransactionEditorPage)))
          .commonFinish));
      await settleAfterSave(tester);

      final txs = await repo.getTransactionsByLedger(1);
      expect(txs, hasLength(1), reason: '编辑不得复制出新行');
      expect(txs.single.amount, closeTo(105, 0.001));

      final now = DateTime.now();
      final totals = await repo.totalsInRange(
        ledgerId: 1,
        start: DateTime(now.year, now.month).subtract(const Duration(days: 1)),
        end: DateTime(now.year, now.month + 1, 1),
      );
      expect(totals.$2, closeTo(105, 0.001), reason: '统计应反映编辑后的金额');

      await drainAndUnmount(tester);
    });
  });
}
