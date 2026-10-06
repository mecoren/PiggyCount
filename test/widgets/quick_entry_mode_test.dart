/// P1-E 快捷记账模式 —— R2/R3/R4 的 widget 契约测试。
///
/// 对齐 `prd/p1e_quick_entry_mode/requirements.md` 的 AC-R2 七个场景
/// （另加 AC-R4 #1 的「关掉后不回到新分支」回归保护）。
///
/// 分三层断言，各管一段责任：
///   1. `AmountEditorSheet` 的分类位 —— AC-R2 #2 / #3 / #6 的**展示与回路**半边；
///   2. `TransactionEditorPage` 的落点 —— AC-R2 #1 / #4 / #5 / #7 的**落点**半边；
///   3. `quickEntryLastCategoryProvider` 的校验 —— AC-R2 #4 的**数据**半边。
///
/// 为什么 #4 要拆到第三层测：页面拿到的已经是「provider 校验过的 id」，
/// 用 provider 覆盖去喂一个不存在的 id 只能验证**页面**的兜底；
/// 而「记忆到已被删除的分类 → 不预填」这条规则的主体在 provider 里
/// （`getCategoryById` 复核 + 共享账本 synthetic id 必须属于当前账本），
/// 只有跑真实 provider 才算验证了它。
///
/// 落点断言的判别器用 `find.byType(AmountEditorSheet)`：金额表单是盖在
/// 分类网格**之上**的模态路由，网格本身仍在树里，所以「网格在不在」
/// 不能反过来证明「表单有没有直接打开」—— 只有前者能。
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
import 'package:piggycount/providers/quick_entry_providers.dart';
import 'package:piggycount/utils/shared_ledger_picker_filter.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';
import 'package:piggycount/widgets/category/category_selector.dart';
import 'package:piggycount/widgets/category_icon.dart';
import 'package:piggycount/widgets/transaction/transfer_form.dart';
import 'package:piggycount/widgets/ui/ui.dart';

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

  Ledger cnyLedger({String? syncId}) => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
        syncId: syncId,
      );

  MaterialApp wrap(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  // ——— 第一层：AmountEditorSheet 的分类位 ———

  /// 把渲染期异常收成**列表**，而不是用 `tester.takeException()`。
  ///
  /// `takeException()` 一次只留得下一条：窄屏用例里同时会有两条溢出
  /// （分类位水平 + 键盘日期键纵向），实测它只会回一句
  /// 「Multiple exceptions (2) were detected…至少一条非预期」，无法分辨是哪条、
  /// 也判不出方向。收成列表后就能只盯「分类位该负责的那一条」。
  List<String> collectRenderErrors() {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    addTearDown(() => FlutterError.onError = previous);
    return errors;
  }

  /// 窄屏用例只守**水平**溢出。
  ///
  /// 360dp + 测试字体（`FlutterTest` 字体每字宽 1em，比真机字体宽近一倍）下，
  /// 数字键盘的日期键会因为「2026/9/18」放不下 70px 键宽而换行，纵向溢出
  /// 6.0px —— 不传分类位的对照组同样溢出，是既有问题、与本需求无关
  /// （真机字体下该文本约 45px，不换行）。所以本用例的判据是「水平溢出为 0」，
  /// 纵向那条由对照用例一起记录、留作既有问题另记。
  List<String> rightOverflows(List<String> renderErrors) =>
      renderErrors.where((e) => e.contains('on the right')).toList();

  Widget sheetHost({
    Category? displayCategory,
    Future<Category?> Function(Category?, double)? onPickCategory,
    double? initialAmount,
  }) =>
      ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
        ],
        child: wrap(Scaffold(
          body: AmountEditorSheet(
            // categoryName 是「仅用于上层提交、不在 UI 展示」的字段：
            // 不传 displayCategory 时它**不该**泄漏到界面上。
            categoryName: displayCategory?.name ?? '餐饮',
            categoryId: displayCategory?.id,
            displayCategory: displayCategory,
            onPickCategory: onPickCategory,
            initialDate: DateTime(2026, 9, 18),
            initialAmount: initialAmount,
            ledgerId: 1,
            onSubmit: (_) {},
          ),
        )),
      );

  group('AC-R2 分类位（AmountEditorSheet）', () {
    testWidgets('#2 传 displayCategory → 显示该分类的图标与名称', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final id = await repo.createCategory(name: '餐饮', kind: 'expense');
      final category = (await repo.getCategoryById(id))!;

      await tester.pumpWidget(sheetHost(
        displayCategory: category,
        onPickCategory: (current, amount) async => null,
      ));
      await tester.pumpAndSettle();

      expect(find.text('餐饮'), findsOneWidget, reason: '分类位必须显示分类名');
      expect(find.byType(CategoryIconWidget), findsOneWidget,
          reason: '分类位必须显示图标（结论 B：金额表单原本完全不显示分类）');
    });

    testWidgets('未传 displayCategory → 零占位，既有调用方布局不变', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

      await tester.pumpWidget(sheetHost());
      await tester.pumpAndSettle();

      expect(find.byType(CategoryIconWidget), findsNothing);
      expect(find.text('餐饮'), findsNothing,
          reason: 'categoryName 仍不该在 UI 出现（转账表单等调用方零影响）');
    });

    testWidgets('#3 点分类位回传的是**当前已输**金额，不是进入时的初始金额', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final id = await repo.createCategory(name: '餐饮', kind: 'expense');
      final category = (await repo.getCategoryById(id))!;
      double? picked;

      await tester.pumpWidget(sheetHost(
        displayCategory: category,
        onPickCategory: (current, amount) async {
          picked = amount;
          return null;
        },
        initialAmount: 12.5,
      ));
      await tester.pumpAndSettle();

      // 退格一次：'12.5' → '12.'（值随之变成 12.0）。
      // 用「输入被改动过」来区分「读的是当前输入框」和「读的是 initialAmount」。
      await tester.tap(find.byIcon(Icons.backspace_outlined));
      await tester.pump();

      await tester.tap(find.byType(CategoryIconWidget));
      await tester.pump();

      expect(picked, 12.0, reason: '换分类时带回的必须是输入框当前值，否则用户改过的金额会被吃掉');
    });

    testWidgets('可分换但尚未选分类 → 显示「选择分类」占位且可点（新流程的入口）', (tester) async {
      // 「金额表单优先」形态下分类由记忆/显式传入决定，可能为空。此时分类位
      // 必须仍有一个可点入口，否则用户会卡在「没分类又无处可选」。
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      var taps = 0;

      await tester.pumpWidget(sheetHost(
        onPickCategory: (current, amount) async {
          taps++;
          return null;
        },
      ));
      await tester.pumpAndSettle();

      expect(find.text('选择分类'), findsOneWidget, reason: '未选分类时要有占位文案');
      expect(find.byIcon(Icons.category_outlined), findsOneWidget);

      await tester.tap(find.text('选择分类'));
      await tester.pump();
      expect(taps, 1, reason: '占位必须可点，否则新流程没有选分类的入口');
    });

    testWidgets('换分类返回新分类 → 分类位就地更新，表单不关闭', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = (await repo.getCategoryById(
          await repo.createCategory(name: '餐饮', kind: 'expense')))!;
      final traffic = (await repo.getCategoryById(
          await repo.createCategory(name: '交通', kind: 'expense')))!;

      await tester.pumpWidget(sheetHost(
        displayCategory: food,
        onPickCategory: (current, amount) async => traffic,
      ));
      await tester.pumpAndSettle();

      expect(find.text('餐饮'), findsOneWidget);

      await tester.tap(find.byType(CategoryIconWidget));
      await tester.pumpAndSettle();

      // 分类位换成新分类，且整张表单仍在（没有「缩进去」）
      expect(find.text('交通'), findsOneWidget);
      expect(find.text('餐饮'), findsNothing);
      expect(
          find.byKey(const ValueKey('amountEditorAmountValue')), findsOneWidget,
          reason: '记账表单必须原地保留 —— 换分类不能把记账界面收起来');
    });

    testWidgets('窄屏（360dp）+ 超长分类名 + 6 位金额 → 分类位不引入水平溢出', (tester) async {
      // 分类位是金额行里**新加进来的第三个元素**（原本只有币种标 + 算式），
      // design.md 第四节把「表单是否因此显得拥挤」列为 R2 的主要不确定性 ——
      // 这条用例就是它的自动化守卫。
      //
      // 守卫的不是「窄屏下名字还能显示全」，而是**分类位让位的下限**：槽位不够时
      // 它必须自己逐级收（名字 → 箭头 → 只剩图标），任何一级都不许把金额行顶出
      // 水平溢出。实测过反例：不做让位时槽位仅剩 14.8px 而内部固定物 37px，
      // 溢出 22px（分类名已被压到 0 也救不回来）。
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);

      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final id = await repo.createCategory(
          name: '餐饮娱乐交通住房购物医疗教育通讯超长分类名称', kind: 'expense');
      final category = (await repo.getCategoryById(id))!;

      final renderErrors = collectRenderErrors();
      await tester.pumpWidget(sheetHost(
        displayCategory: category,
        onPickCategory: (current, amount) async => null,
        initialAmount: 123456.78,
      ));
      await tester.pumpAndSettle();

      expect(rightOverflows(renderErrors), isEmpty,
          reason: '分类位不得把金额行顶出水平溢出（应逐级让位到「只剩图标」）');
      expect(find.byType(CategoryIconWidget), findsOneWidget,
          reason: '让位的下限是只剩图标：分类必须始终可辨认，不能整个消失');
    });

    testWidgets('对照组：同场景不传分类位 → 本就没有水平溢出（分类位净贡献 0）', (tester) async {
      // 上一条用例的判据成立的前提 —— 不传分类位时金额行本身就有水平溢出的余量
      // （360dp 下测试字体里「123456.78 + 币种标」约 296px，可用 328px）。它同时
      // 记录了窄屏下的既有问题：键盘日期键纵向溢出，与本需求无关。
      tester.view.physicalSize = const Size(360 * 3, 800 * 3);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.reset);
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

      final renderErrors = collectRenderErrors();
      await tester.pumpWidget(sheetHost(initialAmount: 123456.78));
      await tester.pumpAndSettle();

      expect(rightOverflows(renderErrors), isEmpty,
          reason: '对照组若也有水平溢出，上一条用例的判据就不成立');
      // 记录既有问题（不参与判据）：分类位与它无关，这里显式确认两条用例
      // 看到的是同一批纵向溢出。
      expect(renderErrors.where((e) => e.contains('on the bottom')), isNotEmpty,
          reason: '既有问题留痕：键盘日期键在窄屏 + 测试字体下纵向溢出');
    });

    testWidgets('onPickCategory 为 null → 分类位只读，点击无副作用', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final id = await repo.createCategory(name: '餐饮', kind: 'expense');
      final category = (await repo.getCategoryById(id))!;

      await tester.pumpWidget(sheetHost(displayCategory: category));
      await tester.pumpAndSettle();

      expect(find.byType(CategoryIconWidget), findsOneWidget,
          reason: '分类可见性是硬约束，即使不可换也必须显示');
      await tester.tap(find.byType(CategoryIconWidget));
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  // ——— 第二层：TransactionEditorPage 的落点 ———

  /// 落点测试的宿主。
  ///
  /// 关键在于**先把「记忆」预热到 ready 再挂页面**：页面 `initState` 只在首帧后
  /// 采样一次 provider（`.value`），而生产里 `app.dart` 已在启动首帧预热过，
  /// 用户点 FAB 时 provider 早就 resolved。测试若不预热，首帧采到的必然是 loading
  /// 态 → 走的是「未就绪退回网格」那条路，就测不到「命中直落表单」。
  Future<Widget> pageHost({
    bool quickMode = false,
    int? rememberedCategoryId,
    bool overrideMemory = true,
    int? initialCategoryId,
    int? editingTransactionId,
    bool renderAsBottomSheet = false,
  }) async {
    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      // 不覆盖它的话，未覆盖记忆的用例会走真实 provider → 再 new 一个
      // PiggyDatabase，drift 会打「同一 QueryExecutor 多实例」的警告。
      databaseProvider.overrideWithValue(db),
      currentLedgerProvider
          .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
      if (overrideMemory)
        quickEntryLastCategoryProvider('expense')
            .overrideWith((ref) async => rememberedCategoryId),
    ]);
    addTearDown(container.dispose);
    await container.read(quickEntryLastCategoryProvider('expense').future);

    return UncontrolledProviderScope(
      container: container,
      child: wrap(TransactionEditorPage(
        initialKind: 'expense',
        quickAdd: true,
        quickMode: quickMode,
        initialCategoryId: initialCategoryId,
        editingTransactionId: editingTransactionId,
        renderAsBottomSheet: renderAsBottomSheet,
      )),
    );
  }

  /// 凡是用例打开过金额表单，收尾都要把 LoggerService 的 2s 节流落盘定时器
  /// 跑完 —— 否则 flutter_test 会因「树已销毁却仍有 pending timer」判失败。
  Future<void> drainLoggerTimer(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  group('AC-R2 落点（TransactionEditorPage.quickMode）', () {
    testWidgets('#1 快捷模式 + 记忆命中 → 不做任何点击就落在金额表单', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: food,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '跳过分类网格，直接出金额表单（R2 的核心预期）');
      // 分类网格在模态表单**下面**仍在树里，所以必须限定在表单子树内断言
      expect(
        find.descendant(
            of: find.byType(AmountEditorSheet), matching: find.text('餐饮')),
        findsOneWidget,
        reason: '表单里的分类位必须显示记忆到的那个分类',
      );

      await drainLoggerTimer(tester);
    });

    testWidgets('#5 首次使用（记忆为 null）→ 退回分类网格，不显示空的快捷态', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: null,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsNothing);
      expect(find.byType(CategorySelector), findsWidgets, reason: '应落在分类网格');
      expect(tester.takeException(), isNull, reason: '不得报错/白屏');
    });

    testWidgets('#4 记忆指向的分类已不存在 → 静默退回网格，不预填不报错', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: 999999, // 已被删除 / 不属于本账本
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsNothing);
      expect(find.byType(CategorySelector), findsWidgets);
      expect(tester.takeException(), isNull,
          reason: '预填错分类的危害大于不预填 —— 校验失败必须静默落回网格');
    });

    testWidgets('带 initialCategoryId 的既有路径（小组件分类格）保持直落金额表单', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        overrideMemory: false,
        initialCategoryId: food,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget);
      expect(
        find.descendant(
            of: find.byType(AmountEditorSheet), matching: find.text('餐饮')),
        findsOneWidget,
      );

      await drainLoggerTimer(tester);
    });

    testWidgets('#7 编辑交易走新形态：直接落在金额表单，原有分类就在分类位上', (tester) async {
      // 编辑入口（transaction_edit_utils / AI 对话页）恒传 quickMode: true，
      // 与「记一笔」共用同一形态 —— 编辑的第一屏就该是这笔交易的表单。
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        initialCategoryId: food,
        editingTransactionId: 1,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '编辑的第一屏就是这笔交易的表单');
      expect(find.byType(CategorySelector), findsNothing,
          reason: '分类是要点分类位才弹出的子界面，不再先铺网格');
      expect(
        find.descendant(
            of: find.byType(AmountEditorSheet), matching: find.text('餐饮')),
        findsOneWidget,
        reason: '这笔交易原有的分类直接显示在分类位上',
      );

      await drainLoggerTimer(tester);
    });

    testWidgets('AC-R4 #1 回归保护：关掉开关（quickMode=false）→ 停网格，不预填', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: false,
        rememberedCategoryId: food, // 记忆命中也不许用 —— 关掉就该等于改动前
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsNothing);
      expect(find.byType(CategorySelector), findsWidgets);
    });

    // ——— 抽屉形态：「金额表单优先，分类只是子界面」 ———

    testWidgets('抽屉形态：点击记账直接落在记账界面，不铺开分类网格', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: food,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '点击记账只弹记账界面');
      expect(find.byType(CategorySelector), findsNothing,
          reason: '分类界面要点击分类位才作为**子界面**弹出，不再默认铺开');
      expect(
        find.descendant(
            of: find.byType(AmountEditorSheet), matching: find.text('餐饮')),
        findsOneWidget,
        reason: '记忆分类异步补进已渲染的表单',
      );

      await drainLoggerTimer(tester);
    });

    testWidgets('抽屉形态：记忆未命中也不退回网格，分类位给「选择分类」占位', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: null,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget);
      expect(find.byType(CategorySelector), findsNothing);
      expect(find.text('选择分类'), findsOneWidget,
          reason: '没有记忆分类也要能记账：分类位留可点占位，而不是把人丢回分类网格');

      await drainLoggerTimer(tester);
    });

    testWidgets('抽屉形态：点分类位弹出分类子界面，记账界面原地不动', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: food,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      await tester.tap(find.byType(CategoryIconWidget));
      await tester.pumpAndSettle();

      expect(find.byType(CategorySelector), findsWidgets, reason: '分类子界面已弹出');
      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '弹出分类时记账界面不能被关掉 / 缩进去');

      await drainLoggerTimer(tester);
    });

    testWidgets('抽屉形态：走项目「悬浮卡片」外壳（左右 / 底部留距，非全宽平底）', (tester) async {
      // 回归守卫：`_buildQuickEntrySheet` 曾自带「全宽 Material(scaffoldBackground)
      // + PiggyTitleBar」的旧平底弹层，与全站其它抽屉（左右 / 底部留距的悬浮卡片）
      // 视觉漂移。判据认**外壳组件**而不是量像素：留距由 PiggySheetCard 统一负责，
      // 调 token 不该让本用例变红。
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: food,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      expect(find.byType(PiggySheetCard), findsWidgets,
          reason: '记账抽屉必须用项目统一的悬浮卡片外壳（左右 / 底部 p16 留距）');
      expect(find.byType(PiggySheetHeader), findsOneWidget,
          reason: '顶栏走共用 X 左 / 标题居中 那套，不再自拼 PiggyTitleBar');
      expect(find.byType(PiggyTitleBar), findsNothing,
          reason: 'PiggyTitleBar 是页面级 appBar，抽屉里不该再用');
      // 卡片左右必须真的让开屏幕边缘，否则等于没换外壳。量的是卡片自己的
      // Material —— PiggySheetCard 本身是个 Padding，外壳留距在它内侧。
      final card = find
          .descendant(
              of: find.byType(PiggySheetCard), matching: find.byType(Material))
          .first;
      expect(tester.getTopLeft(card).dx, greaterThan(0),
          reason: '卡片左边必须留距（p16），全宽就等于旧样式');
      expect(
          MediaQuery.sizeOf(tester.element(card)).width -
              tester.getSize(card).width,
          greaterThan(0),
          reason: '卡片宽度必须窄于屏宽（左右各留 p16）');

      await drainLoggerTimer(tester);
    });

    testWidgets('抽屉形态：切到转账时抽屉高度与支出/收入一致（不跳到全屏）', (tester) async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        rememberedCategoryId: food,
        renderAsBottomSheet: true,
      ));
      await tester.pumpAndSettle();

      final expenseHeight =
          tester.getSize(find.byKey(const ValueKey('quickEntrySheet'))).height;
      expect(expenseHeight, greaterThan(0));

      await tester.tap(find.text('转账'));
      await tester.pumpAndSettle();

      final transferHeight =
          tester.getSize(find.byKey(const ValueKey('quickEntrySheet'))).height;
      expect(find.byType(TransferForm), findsOneWidget, reason: '已切到转账表单');
      expect(transferHeight, expenseHeight,
          reason: '转账的账户网格很高，但抽屉必须锁到金额表单的实测高度 —— '
              '否则切分段时的高度突变就是用户看到的「闪现」');

      await drainLoggerTimer(tester);
    });
  });

  // ——— 第三层：quickEntryLastCategoryProvider 的校验 ———

  group('AC-R2 #4 记忆校验（quickEntryLastCategoryProvider）', () {
    ProviderContainer container() => ProviderContainer(overrides: [
          repositoryProvider.overrideWithValue(repo),
          databaseProvider.overrideWithValue(db),
        ]);

    test('记忆到的本地分类仍存在 → 返回该 id', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 9, 1),
      );

      final c = container();
      addTearDown(c.dispose);
      expect(
          await c.read(quickEntryLastCategoryProvider('expense').future), food);
    });

    test('记忆到的分类已被删除 → 返回 null（不得把死 id 预填进表单）', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 9, 1),
      );
      await repo.deleteCategory(food);

      final c = container();
      addTearDown(c.dispose);
      expect(await c.read(quickEntryLastCategoryProvider('expense').future),
          isNull);
    });

    test('共享账本 synthetic id 属于当前账本 → 返回该 synthetic id', () async {
      const ledgerSync = 'ledger-sync-1';
      const catSync = 'owner-cat-1';
      await db
          .into(db.ledgers)
          .insert(cnyLedger(syncId: ledgerSync).toCompanion(true));
      await db.into(db.sharedLedgerCategories).insert(
            SharedLedgerCategoriesCompanion.insert(
              ledgerSyncId: ledgerSync,
              syncId: catSync,
              name: '餐饮',
              kind: 'expense',
              updatedAt: DateTime(2026, 9, 1),
            ),
          );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categorySyncIdOverride: catSync,
        happenedAt: DateTime(2026, 9, 1),
      );

      final c = container();
      addTearDown(c.dispose);
      expect(
        await c.read(quickEntryLastCategoryProvider('expense').future),
        syntheticIdForSyncId(catSync),
      );
    });

    test('共享账本 synthetic id **不属于**当前账本 → 返回 null（跨账本不得串台）', () async {
      const catSync = 'owner-cat-1';
      // 当前账本没有 syncId；SharedLedger* 里的这条属于**别的**账本。
      await db.into(db.ledgers).insert(cnyLedger().toCompanion(true));
      await db.into(db.sharedLedgerCategories).insert(
            SharedLedgerCategoriesCompanion.insert(
              ledgerSyncId: 'other-ledger-sync',
              syncId: catSync,
              name: '餐饮',
              kind: 'expense',
              updatedAt: DateTime(2026, 9, 1),
            ),
          );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categorySyncIdOverride: catSync,
        happenedAt: DateTime(2026, 9, 1),
      );

      final c = container();
      addTearDown(c.dispose);
      expect(
        await c.read(quickEntryLastCategoryProvider('expense').future),
        isNull,
        reason: '不能复用全库扫描的 findCategoryBySyntheticId —— 会命中别的账本',
      );
    });
  });
}
