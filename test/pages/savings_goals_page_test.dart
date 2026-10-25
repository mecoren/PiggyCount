/// v53 储蓄目标页 UI 回归。
///
/// 锁死四条用户可见行为：
/// 1. 无目标 → 空态引导（不能是空白页，否则用户找不到录入入口）；
/// 2. 有目标 → 汇总卡 + 目标名 + 进度条渲染；
/// 3. 账户模式的目标必须透出「关联账户 · 账户名」，让用户知道进度来自哪里；
/// 4. 新增目标表单保存后**真的落库**（走 Repository，不是直接写 Drift）；
/// 5. 头部是覆盖层（渐变磨砂），列表铺满 body：往上滑时汇总卡滚到磨砂层下面，
///    「总目标 / 总已存」收进标题栏右上角的紧凑版（总览常驻，不会因为卡滚走而消失）。
///
/// ⚠️ 每个用例结束都要 [settlePage] 推时间：drift 的 QueryStream 在 dispose 时用
/// `Timer(Duration.zero)` 异步关闭、LoggerService 有 2s 落盘节流定时器 —— 不推进
/// 时间就会撞上「A Timer is still pending」断言（见 AGENTS.md Riverpod 3 迁移注意 #8）。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/budget/widgets/budget_progress_bar.dart';
import 'package:piggycount/pages/savings_goal/savings_goal_edit_page.dart';
import 'package:piggycount/pages/savings_goal/savings_goals_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/biz.dart';
import 'package:piggycount/widgets/savings_goal/savings_goal_card.dart';
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

  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: SavingsGoalsPage(),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// 卸载页面并推进时间，清掉 drift / LoggerService 的挂起定时器。
  Future<void> settlePage(
      WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 3));
  }

  /// 取 l10n 必须用**页面内部**的 element：`MaterialApp` 自身的 element 在
  /// Localizations 之上，查不到（返回 null）。
  AppLocalizations l10nOf(WidgetTester tester, [Finder? of]) =>
      AppLocalizations.of(
          tester.element((of ?? find.byType(SavingsGoalsPage)).first));

  testWidgets('无目标 → 渲染空态引导', (tester) async {
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    expect(find.text(l10n.savingsGoalEmpty), findsOneWidget);
    expect(find.text(l10n.savingsGoalEmptyHint), findsOneWidget);

    await settlePage(tester, container);
  });

  testWidgets('有目标 → 渲染目标名、汇总卡与进度条', (tester) async {
    await repo.createSavingsGoal(
      ledgerId: 1,
      name: '日本旅行',
      targetAmount: 20000,
      savedAmount: 5000,
    );
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    expect(find.text('日本旅行'), findsOneWidget);
    expect(find.text(l10n.savingsGoalTotalTarget), findsOneWidget);
    expect(find.text(l10n.savingsGoalTotalSaved), findsOneWidget);
    expect(find.text(l10n.savingsGoalSourceManual), findsOneWidget);
    // 汇总卡 1 条 + 目标卡 1 条
    expect(find.byType(BudgetProgressBar), findsNWidgets(2));
    expect(find.text(l10n.savingsGoalEmpty), findsNothing);

    await settlePage(tester, container);
  });

  testWidgets('账户模式 → 来源标签透出「关联账户 · 账户名」', (tester) async {
    final accountId = await repo.createAccount(
      ledgerId: 1,
      name: '储蓄账户',
      type: 'bank',
      currency: 'CNY',
      initialBalance: 2500,
    );
    await repo.createSavingsGoal(
      ledgerId: 1,
      name: '换相机',
      targetAmount: 8000,
      accountId: accountId,
      currency: 'CNY',
    );
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    expect(
      find.text('${l10n.savingsGoalSourceAccount} · 储蓄账户'),
      findsOneWidget,
      reason: '账户模式必须让用户看出进度来自哪个账户',
    );
    expect(find.text(l10n.savingsGoalSourceManual), findsNothing);

    await settlePage(tester, container);
  });

  testWidgets('表单抽屉：分段来源 + 行式字段（不再用 ChoiceChip / ListTile）', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    final sheet = find.byType(SavingsGoalEditPage);
    expect(find.byType(PiggyFormSheet), findsOneWidget);

    // 版式语言与搜索筛选抽屉统一：分段控件 + 图标行；
    // 旧版并排 ChoiceChip / 两行堆叠 ListTile 一律不许回来
    // （Chip 各自成块、高度对不齐，见 AGENTS「表单字段用行式组件」）。
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    expect(find.byType(PiggySegmentedControl<bool>), findsOneWidget);
    // 手动模式：已存 / 币种 / 起算日 / 目标日期 四行
    expect(find.byType(PiggyValueRow), findsNWidgets(4));
    // 已存金额走 AmountText（跟随全局「隐藏金额」开关，不自己拼字符串）
    expect(find.byType(AmountText), findsOneWidget);

    // 切到账户模式：币种锁成账户币种，改为只读行 + 尾注说明出处
    final l10n = l10nOf(tester, sheet);
    await tester.tap(find.text(l10n.savingsGoalSourceAccount));
    await tester.pumpAndSettle();
    expect(find.text(l10n.savingsGoalCurrencyFollowsAccount), findsOneWidget);
    expect(find.byType(AmountText), findsNothing, reason: '手动草稿行在账户模式下应整行消失');

    await settlePage(tester, container);
  });

  testWidgets('往上滑 → 汇总卡滚到磨砂层下面，总目标/总已存收进右上角', (tester) async {
    for (var i = 0; i < 12; i++) {
      await repo.createSavingsGoal(
        ledgerId: 1,
        name: '目标$i',
        targetAmount: 1000,
        savedAmount: 100,
      );
    }
    final container = await pumpPage(tester);
    final l10n = l10nOf(tester);

    // 头部是覆盖层（不占布局位）：列表视口贴屏幕顶，卡片才穿得到磨砂层下面
    expect(tester.getTopLeft(find.byType(ListView)).dy, 0,
        reason: '列表要从屏幕顶开始滚，磨砂层才有内容可模糊');

    // 汇总卡里的那个（限定在列表内找：滚动后标题栏里还会出现同名标签）
    final cardLabel = find.descendant(
      of: find.byType(ListView),
      matching: find.text(l10n.savingsGoalTotalTarget),
    );
    final before = tester.getTopLeft(cardLabel);
    expect(before.dy, greaterThan(kToolbarHeight),
        reason: '汇总卡应落在标题栏下方，而不是被标题栏盖住');

    final firstCardBefore =
        tester.getTopLeft(find.byType(SavingsGoalCard).first);

    // 拖 120dp：够把汇总卡的两个数字顶到磨砂层下沿，又不至于把首卡滑出
    // sliver 的缓存区（滑出去元素会被回收，位置断言就取不到了）
    await tester.drag(
        find.byType(SavingsGoalCard).first, const Offset(0, -120));
    await tester.pumpAndSettle();

    // 列表真的滚了：汇总卡跟着往上走（钻进磨砂层），不再是「钉死在标题栏下方」
    expect(
        tester
            .state<ScrollableState>(find.byType(Scrollable).first)
            .position
            .pixels,
        greaterThan(0));
    expect(tester.getTopLeft(cardLabel).dy, lessThan(before.dy),
        reason: '汇总卡要跟着列表滚走，否则磨砂层下面永远没内容');
    expect(tester.getTopLeft(find.byType(SavingsGoalCard).first).dy,
        lessThan(firstCardBefore.dy));

    // 滚走后「总目标 / 总已存」收进标题栏右上角（限定在头部里找，避免和卡片里的撞）
    final compact = find.descendant(
      of: find.byType(PiggyHeader),
      matching: find.text(l10n.savingsGoalTotalTarget),
    );
    expect(compact, findsOneWidget, reason: '总览数字不能因为卡滚走就看不到');
    final compactPos = tester.getTopLeft(compact);
    expect(compactPos.dy, lessThan(kToolbarHeight), reason: '紧凑汇总要落在标题栏这一行内');
    expect(compactPos.dx,
        greaterThan(tester.getSize(find.byType(SavingsGoalsPage)).width / 2),
        reason: '「收进右上角」——紧凑汇总必须靠右，不能留在左侧标题区');

    await settlePage(tester, container);
  });

  testWidgets('新增目标表单保存 → 经 Repository 落库', (tester) async {
    final container = await pumpPage(tester);

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();
    expect(find.byType(SavingsGoalEditPage), findsOneWidget);

    // 字段顺序：名称 / 目标金额 / 备注
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(0), '应急金');
    await tester.enterText(fields.at(1), '30000');
    await tester.pump();

    await tester.tap(
        find.text(l10nOf(tester, find.byType(SavingsGoalEditPage)).commonSave));
    await tester.pumpAndSettle();

    final saved = await repo.getSavingsGoalsByLedger(1);
    expect(saved, hasLength(1));
    expect(saved.single.name, '应急金');
    expect(saved.single.targetAmount, 30000);
    expect(saved.single.accountId, isNull, reason: '默认手动模式');
    expect(saved.single.currency, 'CNY', reason: '默认跟随账本本位币');
    expect(saved.single.syncId, isNotNull, reason: '建行即生成跨设备身份锚点');

    await settlePage(tester, container);
  });

  testWidgets('完整交互无 element 生命周期断言：切来源 / 存入 / 保存 / 删除', (tester) async {
    await repo.createSavingsGoal(
      ledgerId: 1,
      name: '应急金',
      targetAmount: 30000,
      savedAmount: 1000,
    );
    final container = await pumpPage(tester);

    // 点卡片打开编辑抽屉
    await tester.tap(find.text('应急金'));
    await tester.pumpAndSettle();
    final sheet = find.byType(SavingsGoalEditPage);
    expect(sheet, findsOneWidget);
    final l10n = l10nOf(tester, sheet);
    // 卡片上也渲染了来源标签，finder 必须限定在抽屉内（否则 tap 命中多个）
    Finder inSheet(String text) =>
        find.descendant(of: sheet, matching: find.text(text));

    // 进度来源两态互相切换（children 列表长度/类型会变，最容易踩 element 复用断言）
    await tester.tap(inSheet(l10n.savingsGoalSourceAccount));
    await tester.pumpAndSettle();
    await tester.tap(inSheet(l10n.savingsGoalSourceManual));
    await tester.pumpAndSettle();

    // 存入 → 弹金额输入 → 确认（只改草稿）
    await tester.tap(inSheet(l10n.savingsGoalDeposit));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, '500');
    await tester.tap(find.text(l10n.commonConfirm));
    await tester.pumpAndSettle();

    // 保存（草稿随 savedAmount 落库）
    await tester.tap(inSheet(l10n.commonSave));
    await tester.pumpAndSettle();
    expect(find.byType(SavingsGoalEditPage), findsNothing);
    expect((await repo.getSavingsGoalsByLedger(1)).single.savedAmount, 1500);

    // 再进编辑 → 删除（入口是标题栏右上角的垃圾桶图标，常驻可见、无需滚动）
    await tester.tap(find.text('应急金'));
    await tester.pumpAndSettle();
    final l10n2 = l10nOf(tester, find.byType(SavingsGoalEditPage));
    final sheetDelete = find.descendant(
        of: find.byType(SavingsGoalEditPage),
        matching: find.byIcon(Icons.delete_outline));
    expect(sheetDelete, findsOneWidget);
    await tester.tap(sheetDelete);
    await tester.pumpAndSettle();
    // 危险确认：确认按钮在 3 秒倒计时内禁用（pumpAndSettle 会把倒计时推完），
    // 这里再显式推进一次，保证归零后按钮可用。
    await tester.pump(const Duration(seconds: 3));
    // 抽屉侧的删除已改为图标，文字「删除」只剩危险确认框里那个。
    await tester.tap(find.text(l10n2.commonDelete));
    await tester.pumpAndSettle();

    expect(await repo.getSavingsGoalsByLedger(1), isEmpty);

    await settlePage(tester, container);
  });
}
