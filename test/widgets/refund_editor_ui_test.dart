/// v56 退款关联 + 报销状态（F1-b）**编辑器 UI 契约**：
///
/// 1. 新建收入：打开「关联原交易」行 → 选择器选一笔支出 → 保存后
///    `refund_of_id` 指向该支出；
/// 2. 旗标对话框选「待报销」→ 保存后 `reimburse_status = 'pending'`；
/// 3. 编辑回显：既有退款行打开编辑器，关联摘要与报销状态正确回显
///    （经生产入口 `TransactionEditUtils.editTransaction`）。
///
/// 基建同 `editor_save_read_chain_test.dart`（内存库 + ProviderScope 四件套
/// 覆盖 + 固定时长 pump + 收尾排空 drift 定时器）。
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
import 'package:piggycount/widgets/ui/option_sheet.dart';

/// 编辑入口宿主：一个按钮走生产同款 `TransactionEditUtils.editTransaction`
/// （它负责加载回显参数，页面自身不按 id 查库）。
class _EditLauncher extends ConsumerWidget {
  const _EditLauncher({required this.transaction, required this.category});

  final Transaction transaction;
  final Category? category;

  @override
  Widget build(BuildContext context, WidgetRef ref) => Scaffold(
        body: Center(
          child: ElevatedButton(
            onPressed: () => TransactionEditUtils.editTransaction(
                context, ref, transaction, category),
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
    await repo.createCategory(name: '餐饮', kind: 'expense');
    await repo.createCategory(name: '奖金', kind: 'income');
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

  /// 挂新建收入编辑器（quick 形态）。
  Future<void> openIncomeEditor(WidgetTester tester) async {
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
        home: Scaffold(
          body: TransactionEditorPage(
            initialKind: 'income',
            quickAdd: true,
            quickMode: true,
            renderAsBottomSheet: true,
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// 保存后的收敛等待 + 卸载排空（同 editor_save_read_chain_test）。
  Future<void> settleAndDrain(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pump(const Duration(milliseconds: 900));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// 新建收入必须先选分类（项目口径：新建记账强制选分类，否则「完成」被拦）。
  Future<void> pickIncomeCategory(WidgetTester tester) async {
    await tester.ensureVisible(find.text('选择分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('选择分类'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('奖金').last);
    await tester.pumpAndSettle();
  }

  /// 滚到可见再点（金额表单属性区可滚，退款关联行在账户行之后，首屏可能在
  /// 折叠线以下）。
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder);
    await tester.pumpAndSettle();
  }

  /// 旗标图标：active 态（任一标记/报销状态非默认）是实心 `Icons.flag`，
  /// 否则空心 `Icons.outlined_flag` —— 两种都认。
  Finder flagIconFinder() => find.byWidgetPredicate((w) =>
      w is Icon && (w.icon == Icons.flag || w.icon == Icons.outlined_flag));

  String l10nOf(WidgetTester tester, String Function(AppLocalizations) pick) =>
      pick(AppLocalizations.of(
          tester.element(find.byType(TransactionEditorPage))));

  group('新建收入：退款关联', () {
    testWidgets('选一笔支出关联 → 保存后 refund_of_id 指向它', (tester) async {
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime.now(),
      );
      await openIncomeEditor(tester);

      // 打开退款关联行 → 选择器
      await tapVisible(tester, find.text(l10nOf(tester, (l) => l.refundLinkTitle)));
      expect(find.text(l10nOf(tester, (l) => l.refundPickerTitle)),
          findsOneWidget);

      // 选第一笔（也是唯一一笔）支出。按「含金额文本的选项行」限定作用域 ——
      // 选择器行现在是统一件 PiggyOptionRow（不是 ListTile）。
      await tester.tap(find.widgetWithText(PiggyOptionRow, '100'));
      await tester.pumpAndSettle();
      // 选择器必须已关闭（否则后续点按会被模态屏障拦截）
      expect(find.text(l10nOf(tester, (l) => l.refundPickerTitle)),
          findsNothing);

      // 摘要回显：冲正：100.00 · 日期
      expect(find.textContaining('冲正'), findsOneWidget);
      expect(find.text(l10nOf(tester, (l) => l.refundLinkSubtitle)),
          findsNothing, reason: '已关联后不再显示未关联副标题');

      // 选分类（新建强制）+ 金额 + 完成。两个数字键之间必须 pump —— 否则
      // 第二个 finder 解析时第一个的 setState 尚未生效，金额显示仍是 '0'，
      // 与键盘 '0' 撞车。
      await pickIncomeCategory(tester);
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.commonFinish)));
      await settleAndDrain(tester);

      final txs = await repo.getTransactionsByLedger(1);
      final income = txs.firstWhere((t) => t.type == 'income');
      final original = txs.firstWhere((t) => t.type == 'expense');
      expect(income.refundOfId, original.id,
          reason: '保存后退款关联必须落到原交易的本地 id');
      expect(income.amount, closeTo(30, 0.001));
    });

    testWidgets('清除键解除关联 → 保存后 refund_of_id 为 null', (tester) async {
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime.now(),
      );
      await openIncomeEditor(tester);

      await tapVisible(tester,
          find.text(l10nOf(tester, (l) => l.refundLinkTitle)));
      await tester.tap(find.widgetWithText(PiggyOptionRow, '100'));
      await tester.pumpAndSettle();
      expect(find.textContaining('冲正'), findsOneWidget);

      // 点摘要行里的清除键（X —— 用 ValueKey 与抽屉标题栏的关闭 X 区分）
      await tester.tap(find.byKey(const ValueKey('refundLinkClear')));
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester, (l) => l.refundLinkSubtitle)), findsOneWidget,
          reason: '解除关联后回到未关联态');

      await pickIncomeCategory(tester);
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.commonFinish)));
      await settleAndDrain(tester);

      final txs = await repo.getTransactionsByLedger(1);
      final income = txs.firstWhere((t) => t.type == 'income');
      expect(income.refundOfId, isNull);
    });
  });

  group('旗标对话框：报销状态', () {
    testWidgets('选「待报销」→ 保存后 reimburse_status = pending', (tester) async {
      await openIncomeEditor(tester);

      // 打开旗标对话框（旗标图标在账户/标签属性行，先滚到可见）
      await tapVisible(tester, flagIconFinder());
      expect(find.text(l10nOf(tester, (l) => l.txFlagDialogTitle)),
          findsOneWidget);

      // 选「待报销」（对话框内容可能超高，先滚到可见）
      await tester.ensureVisible(
          find.text(l10nOf(tester, (l) => l.reimbursePending)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.reimbursePending)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.commonConfirm)));
      await tester.pumpAndSettle();

      await pickIncomeCategory(tester);
      await tester.tap(find.text('3'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('0'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.commonFinish)));
      await settleAndDrain(tester);

      final txs = await repo.getTransactionsByLedger(1);
      final income = txs.firstWhere((t) => t.type == 'income');
      expect(income.reimburseStatus, 'pending');
    });
  });

  group('编辑回显（生产入口 TransactionEditUtils.editTransaction）', () {
    testWidgets('既有退款行：摘要 + 报销状态回显，改状态后保存生效', (tester) async {
      final originalId = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 100,
        happenedAt: DateTime(2026, 7, 1, 10),
      );
      final incomeId = await repo.addTransaction(
        ledgerId: 1,
        type: 'income',
        amount: 30,
        happenedAt: DateTime(2026, 7, 3, 10),
        refundOfId: originalId,
        reimburseStatus: 'pending',
      );
      final income = (await repo.getTransactionsByLedger(1))
          .firstWhere((t) => t.id == incomeId);
      final category =
          (await repo.getAllCategories()).firstWhere((c) => c.kind == 'income');

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
          home: Scaffold(
            body: _EditLauncher(transaction: income, category: category),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.text('edit'));
      await tester.pumpAndSettle();

      // 回显：关联摘要（冲正：100 · 2026-07-01 —— formatMoneyCompact 去零）
      expect(find.textContaining('冲正'), findsOneWidget);
      expect(find.textContaining('100'), findsWidgets);

      // 旗标对话框回显：当前选中「待报销」
      await tapVisible(tester, flagIconFinder());
      expect(find.text(l10nOf(tester, (l) => l.reimburseStatusLabel)),
          findsOneWidget);
      // 改选「已报销」并确认
      await tester.ensureVisible(
          find.text(l10nOf(tester, (l) => l.reimburseReimbursed)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.reimburseReimbursed)));
      await tester.pumpAndSettle();
      await tester.tap(find.text(l10nOf(tester, (l) => l.commonConfirm)));
      await tester.pumpAndSettle();

      await tester.tap(find.text(l10nOf(tester, (l) => l.commonFinish)));
      await settleAndDrain(tester);

      final saved = (await repo.getTransactionsByLedger(1))
          .firstWhere((t) => t.id == incomeId);
      expect(saved.refundOfId, originalId, reason: '编辑不得丢关联');
      expect(saved.reimburseStatus, 'reimbursed', reason: '改选后必须落库');
    });
  });
}
