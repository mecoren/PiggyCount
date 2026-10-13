/// 记账抽屉「带出上一笔」的 widget 契约测试。
///
/// 需求口径（用户确认）：
///   - 抽屉右上角一个图标按钮，点它把**同类型本机最近录入的一笔**（按
///     `transactions.created_at` 判定、无时间窗）的**除金额外的全部字段**装填
///     进当前表单：分类 / 账户 / 备注（含敏感标记）/ 标签 / 币种 / 不计入收支
///     与预算 / 自定义字段；
///   - **不带出**金额、原始金额、汇率、发生日期（保持今天）、附件；
///     **金额类型的自定义字段**与「金额」同口径，一律不带出；
///   - **仅填空缺**（2026-10-13 反转原「直接覆盖」）：目标字段已有值就保留用户
///     现值；「有值」判据 —— 分类 / 账户以「用户主动选过」为准（系统预填的默认
///     账户、5 分钟继承的分类不算有值）、备注非空、标签已选、两个开关「已打开」、
///     币种「已手选」、自定义字段该字段非空；
///   - 两种记账形态都有按钮；编辑既有交易、转账段不出现；该类型暂无来源不出现。
///
/// 分三层敲定：
///   1. 快捷形态（金额表单已在屏上）：点按钮**就地装填**，金额与日期一动不动，
///      已有值的字段保留；
///   2. 表单级 kind 守卫：载荷类型与表单类型不符时不得装填（支出 / 收入两份表单
///      在 IndexedStack 里同时保活，同一份载荷会同时到达两者）；
///   3. 分类网格形态：点按钮等同于「选中上一笔的分类并进入记账表单」；上一笔
///      没有分类时只提示、不打开表单。
library;

import 'dart:convert';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/last_entry_draft.dart';
import 'package:piggycount/pages/transaction/transaction_editor_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/theme_providers.dart';
import 'package:piggycount/widgets/biz/account_selector.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  /// 固定的「现在」之外的墙钟锚点：源交易的录入时刻（3 天前）。
  ///
  /// 刻意避开「5 分钟内继承上一笔」的窗口 —— 那条链路会自动预填分类 / 账户，
  /// 用它之外的取值才能证明「装填是按钮干的」。
  final sourceRecordedAt = DateTime.now().subtract(const Duration(days: 3));

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
      );

  MaterialApp wrap(Widget home) => MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: home,
      );

  /// 页面级宿主（与 `quick_entry_mode_test` 同款：真库 + ProviderContainer）。
  Future<Widget> pageHost({
    required bool quickMode,
    bool renderAsBottomSheet = true,
    int? editingTransactionId,
    DateTime? initialDate,
    String? initialNote,
    int? initialAccountId,
    List<int>? initialTagIds,
    bool initialExcludeFromStats = false,
    bool initialExcludeFromBudget = false,
    String? initialCurrencyCode,
    Map<String, dynamic> initialCustomValues = const {},
  }) async {
    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(repo),
      // 不覆盖它的话，按 id 取分类 / 账户的 provider 会再 new 一个 PiggyDatabase。
      databaseProvider.overrideWithValue(db),
      currentLedgerProvider
          .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
    ]);
    addTearDown(container.dispose);

    return UncontrolledProviderScope(
      container: container,
      // 套一层 Scaffold 提供 Material 祖先：真机上抽屉由 `showModalBottomSheet`
      // 的 BottomSheet(Material) 承担，测试里直接 pump 页面就得自己补上 ——
      // 「分类网格」形态的网格项是 InkWell，缺 Material 会直接断言失败。
      child: wrap(Scaffold(
        body: TransactionEditorPage(
          initialKind: 'expense',
          quickAdd: true,
          quickMode: quickMode,
          renderAsBottomSheet: renderAsBottomSheet,
          editingTransactionId: editingTransactionId,
          initialDate: initialDate,
          initialNote: initialNote,
          initialAccountId: initialAccountId,
          initialTagIds: initialTagIds,
          initialExcludeFromStats: initialExcludeFromStats,
          initialExcludeFromBudget: initialExcludeFromBudget,
          initialCurrencyCode: initialCurrencyCode,
          initialCustomValues: initialCustomValues,
        ),
      )),
    );
  }

  /// 种一笔「上一笔」：除金额外的字段全填满，用来验证装填范围。
  Future<int> seedLastEntry({
    String type = 'expense',
    int? categoryId,
    int? accountId,
    String? note,
    int? tagId,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
    String? currencyCode,
    Map<String, dynamic> customValues = const {},
    DateTime? createdAt,
  }) async {
    final id = await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: type,
          amount: 999,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          createdAt: d.Value(createdAt ?? sourceRecordedAt),
          happenedAt: d.Value(sourceRecordedAt),
          note: d.Value(note),
          excludeFromStats: d.Value(excludeFromStats),
          excludeFromBudget: d.Value(excludeFromBudget),
          currencyCode: d.Value(currencyCode),
          customValuesJson:
              d.Value(customValues.isEmpty ? null : jsonEncode(customValues)),
        ));
    if (tagId != null) {
      await repo.addTagToTransaction(transactionId: id, tagId: tagId);
    }
    return id;
  }

  /// 该笔自定义字段需要一条**定义**才会渲染输入位。
  ///
  /// `fieldType: 'amount'` 用于验证「金额类型的自定义字段永不带出」。
  Future<void> seedCustomField({
    String syncId = 'f-text',
    String name = '商户',
    String fieldType = 'text',
  }) {
    return db.into(db.customFieldDefinitions).insert(
          CustomFieldDefinitionsCompanion.insert(
            ledgerId: 1,
            name: name,
            fieldType: fieldType,
            syncId: d.Value(syncId),
          ),
        );
  }

  /// 凡是用例打开过金额表单，收尾都要把 LoggerService 的 2s 节流落盘定时器
  /// 跑完 —— 否则 flutter_test 会因「树已销毁却仍有 pending timer」判失败。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  String amountText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('amountEditorAmountValue')))
      .data!;

  Finder inSheet(Finder matching) =>
      find.descendant(of: find.byType(AmountEditorSheet), matching: matching);

  /// 读账户选择器**当前选中**的账户 id。
  ///
  /// 不能用 `find.text('支付宝')` 判断选中：账户选择器会把**全部**候选账户
  /// 渲染成横滑芯片（未选中的也在屏上），文本存在 ≠ 被选中。
  int? selectedAccountId(WidgetTester tester) => tester
      .widget<AccountSelector>(inSheet(find.byType(AccountSelector)))
      .selectedAccountId;

  // ——— 第一层：快捷形态（金额表单已在屏上） ———

  group('快捷形态：就地装填', () {
    testWidgets('点按钮装填除金额外的字段，金额与日期一动不动', (tester) async {
      // 默认 800×600 下数字键盘会落到视口外：加高窗口让整块键盘可见（不能改窄）。
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createCategory(name: '交通', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      final tagId = await repo.createTag(name: '差旅');
      await seedCustomField();
      await seedLastEntry(
        categoryId: food,
        accountId: cash,
        note: '午饭',
        tagId: tagId,
        excludeFromStats: true,
        excludeFromBudget: true,
        customValues: {'f-text': 'A店'},
      );

      // 日期固定成一个可断言的值：装填后必须原样（「日期不带出」）。
      final initialDate = DateTime(2026, 9, 18);
      await tester.pumpWidget(await pageHost(
        quickMode: true,
        initialDate: initialDate,
      ));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      // 装填前：分类位是占位（源在 5 分钟窗口外，继承不参与）、备注 / 标签 / 开关为空。
      expect(inSheet(find.text('选择分类')), findsOneWidget,
          reason: '3 天前那一笔不在继承窗口内，分类位应是占位');
      expect(inSheet(find.text('午饭')), findsNothing);
      expect(inSheet(find.byIcon(Icons.outlined_flag)), findsOneWidget);

      // 先输一个金额：装填后必须保持
      await tester.tap(find.byKey(const ValueKey('amountKey_1')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('amountKey_2')));
      await tester.pumpAndSettle();
      expect(amountText(tester), '12');

      // 按钮可见（有来源）→ 点它
      expect(find.byTooltip('带出上一笔'), findsOneWidget);
      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      // 分类 / 账户 / 备注 / 标签 / 开关 / 自定义字段全部就位
      expect(inSheet(find.text('餐饮')), findsOneWidget, reason: '分类被带出');
      expect(inSheet(find.text('现金')), findsOneWidget, reason: '账户被带出');
      expect(inSheet(find.text('午饭')), findsOneWidget, reason: '备注被带出');
      expect(inSheet(find.text('差旅')), findsOneWidget, reason: '标签被带出');
      expect(inSheet(find.byIcon(Icons.flag)), findsOneWidget,
          reason: '「不计入收支 / 预算」开关被带出（旗标激活态）');
      expect(inSheet(find.text('A店')), findsOneWidget,
          reason: '自定义字段值被带出（text 字段靠换 key 重建分区刷新）');

      // 金额与日期：一动不动
      expect(amountText(tester), '12', reason: '金额属显著排除项，必须保持用户输入');
      expect(find.text('2026/9/18'), findsOneWidget, reason: '日期不带出，保持原值');

      await drainTimers(tester);
    });

    testWidgets('该类型暂无来源 → 按钮不渲染', (tester) async {
      await repo.createCategory(name: '餐饮', kind: 'expense');

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.byTooltip('带出上一笔'), findsNothing,
          reason: '空账本里没有「上一笔」，入口不该出现（避免点不动的按钮）');
      // 标题仍严格居中：顶栏右侧是等宽占位。
      expect(find.byType(AmountEditorSheet), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('收入有来源、支出没有 → 切到支出段按钮消失', (tester) async {
      await repo.createCategory(name: '工资', kind: 'income');
      await seedLastEntry(type: 'income');

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      // 首段是支出：支出没有来源 → 无按钮
      expect(find.byTooltip('带出上一笔'), findsNothing);

      await tester.tap(find.text('收入'));
      await tester.pumpAndSettle();
      await drainTimers(tester);

      expect(find.byTooltip('带出上一笔'), findsOneWidget,
          reason: '「上一笔」按类型分族：收入有来源时切过去就该出现');

      await drainTimers(tester);
    });

    testWidgets('转账段不渲染按钮（TransferForm 是另一套状态机）', (tester) async {
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedLastEntry();

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(find.byTooltip('带出上一笔'), findsOneWidget);

      await tester.tap(find.text('转账'));
      await tester.pumpAndSettle();
      await drainTimers(tester);

      expect(find.byTooltip('带出上一笔'), findsNothing);
    });

    testWidgets('编辑既有交易不渲染按钮', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedLastEntry(categoryId: food);
      final id = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 5,
        happenedAt: sourceRecordedAt,
        categoryId: food,
      );

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        editingTransactionId: id,
      ));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.byTooltip('带出上一笔'), findsNothing,
          reason: '编辑时「这一笔自己的值」就是答案，不该被上一笔覆盖');

      await drainTimers(tester);
    });
  });

  // ——— 第一层 B：仅填空缺（2026-10-13 用户口径，反转原「直接覆盖」） ———

  group('快捷形态：仅填空缺', () {
    /// 读自定义「金额」字段当前显示串（空 → 显示 hint 文案）。
    String amountFieldText(WidgetTester tester, String syncId) => tester
        .widget<Text>(
            find.byKey(ValueKey('custom_field_amount_value_$syncId')))
        .data!;

    testWidgets('已有值的备注 / 标签 / 自定义字段保留，空白的才被补上', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      await seedCustomField(); // f-text「商户」
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final mineTag = await repo.createTag(name: '我的标签');
      final srcTag = await repo.createTag(name: '差旅');
      await seedLastEntry(
        categoryId: food,
        note: '午饭',
        tagId: srcTag,
        customValues: {'f-text': 'A店'},
      );

      // 表单里这几项都已经有值：备注、标签、自定义字段各占一项；分类位仍空着。
      await tester.pumpWidget(await pageHost(
        quickMode: true,
        initialNote: '我自己写的',
        initialTagIds: [mineTag],
        initialCustomValues: {'f-text': 'B店'},
      ));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(inSheet(find.text('我自己写的')), findsOneWidget);
      expect(inSheet(find.text('B店')), findsOneWidget);
      expect(inSheet(find.text('选择分类')), findsOneWidget,
          reason: '3 天前那一笔不在继承窗口内，分类位应是占位');

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      // 已有值 → 保留
      expect(inSheet(find.text('我自己写的')), findsOneWidget,
          reason: '备注已有值，不被上一笔覆盖');
      expect(inSheet(find.text('午饭')), findsNothing);
      expect(inSheet(find.text('我的标签')), findsOneWidget,
          reason: '标签已选，不被上一笔覆盖');
      expect(inSheet(find.text('差旅')), findsNothing);
      expect(inSheet(find.text('B店')), findsOneWidget,
          reason: '自定义字段已有值，不被上一笔覆盖');
      expect(inSheet(find.text('A店')), findsNothing);
      // 空白 → 补上
      expect(inSheet(find.text('餐饮')), findsOneWidget,
          reason: '分类位仍空白，应被上一笔补上');

      await drainTimers(tester);
    });

    testWidgets('自定义金额字段永不带出值（源有值、表单为空也不带）', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      await seedCustomField(syncId: 'f-amt', name: '折扣', fieldType: 'amount');
      await seedCustomField(); // f-text「商户」
      await seedLastEntry(customValues: {'f-amt': 88, 'f-text': 'A店'});

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(amountFieldText(tester, 'f-amt'), isNot('88'),
          reason: '装填前金额字段应是空的');

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('A店')), findsOneWidget,
          reason: '非金额自定义字段照常带出');
      expect(amountFieldText(tester, 'f-amt'), isNot('88'),
          reason: '金额类型的自定义字段与「金额」同口径，一律不带出');

      await drainTimers(tester);
    });

    testWidgets('开关：已打开的不被关掉，未打开的才被补上', (tester) async {
      // 来源两个开关都关；表单已打开「不计入收支」→ 复制不得把它关掉。
      await seedLastEntry();

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        initialExcludeFromStats: true,
      ));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(inSheet(find.byIcon(Icons.flag)), findsOneWidget,
          reason: '表单已打开标记');

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(inSheet(find.byIcon(Icons.flag)), findsOneWidget,
          reason: '「已打开」算有值，上一笔的「关」不得把它关掉');
      expect(inSheet(find.byIcon(Icons.outlined_flag)), findsNothing);

      await drainTimers(tester);
    });

    testWidgets('开关：未打开的会被上一笔补上', (tester) async {
      await seedLastEntry(excludeFromBudget: true);

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(inSheet(find.byIcon(Icons.outlined_flag)), findsOneWidget);

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(inSheet(find.byIcon(Icons.flag)), findsOneWidget,
          reason: '开关默认关 = 空缺，应被上一笔补上');

      await drainTimers(tester);
    });

    testWidgets('币种：已手选的不被覆盖', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      await seedLastEntry(currencyCode: 'JPY');

      await tester.pumpWidget(await pageHost(
        quickMode: true,
        initialCurrencyCode: 'USD',
      ));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(inSheet(find.text('USD')), findsOneWidget);

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('USD')), findsOneWidget,
          reason: '「已手选」算有值，币种不被上一笔覆盖');
      expect(inSheet(find.text('JPY')), findsNothing);

      await drainTimers(tester);
    });

    testWidgets('系统预填的账户不算有值，会被上一笔覆盖', (tester) async {
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      final alipay = await repo.createAccount(ledgerId: 1, name: '支付宝');
      await seedLastEntry(accountId: cash);

      // 用户没主动选过，账户只是系统预填（同「默认账户」那条链路）。
      await tester.pumpWidget(
          await pageHost(quickMode: true, initialAccountId: alipay));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();
      expect(selectedAccountId(tester), alipay,
          reason: '系统预填选中支付宝（用户没主动选过）');

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(selectedAccountId(tester), cash,
          reason: '系统预填的账户「不算有值」，允许被上一笔替换');

      await drainTimers(tester);
    });

    testWidgets('用户主动选过的分类不算空缺，不被上一笔覆盖', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createCategory(name: '交通', kind: 'expense');
      await seedLastEntry(categoryId: food);

      await tester.pumpWidget(await pageHost(quickMode: true));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      // 用户主动选「交通」：点分类位 → 分类选择子界面 → 选中。
      await tester.tap(find.byKey(const ValueKey('amountEditorCategoryChip')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('交通').last);
      await tester.pumpAndSettle();
      expect(inSheet(find.text('交通')), findsOneWidget);

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();

      expect(inSheet(find.text('交通')), findsOneWidget,
          reason: '用户主动选过的分类算有值，不被上一笔覆盖');
      expect(inSheet(find.text('餐饮')), findsNothing);

      await drainTimers(tester);
    });
  });

  // ——— 第二层：表单级 kind 守卫 ———

  group('AmountEditorSheet 的载荷守卫', () {
    /// 可手动递增 token 的宿主：模拟「表单已在屏上，调用方送来新载荷」。
    Widget sheetHost({
      required String transactionKind,
      required void Function(StateSetter) exposeRebuild,
      required LastEntryDraft? Function() draftOf,
      required int Function() tokenOf,
    }) {
      return ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          databaseProvider.overrideWithValue(db),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
          showTransactionTimeProvider.overrideWith((ref) => false),
        ],
        child: wrap(Scaffold(
          body: StatefulBuilder(
            builder: (context, setState) {
              exposeRebuild(setState);
              return AmountEditorSheet(
                categoryName: '餐饮',
                initialDate: DateTime(2026, 9, 18),
                initialAmount: 100,
                ledgerId: 1,
                transactionKind: transactionKind,
                // 与生产网格路径一致（v56 起该路径也走钉底形态：属性区自滚，
                // 收入表单的退款关联行不会再让矮屏硬溢出）。
                pinKeypad: true,
                prefill: draftOf(),
                prefillToken: tokenOf(),
                onSubmit: (_) {},
              );
            },
          ),
        )),
      );
    }

    testWidgets('载荷 kind 与表单 kind 不符 → 不装填', (tester) async {
      await seedCustomField();
      StateSetter? rebuild;
      LastEntryDraft? draft;
      var token = 0;

      await tester.pumpWidget(sheetHost(
        transactionKind: 'income',
        exposeRebuild: (fn) => rebuild = fn,
        draftOf: () => draft,
        tokenOf: () => token,
      ));
      await tester.pumpAndSettle();

      // 支出载荷送到收入表单：必须整个丢掉（IndexedStack 双活场景）
      draft = const LastEntryDraft(
        kind: 'expense',
        note: '午饭',
        noteSensitive: true,
        customValues: {'f-text': 'A店'},
      );
      token = 1;
      rebuild!(() {});
      await tester.pumpAndSettle();

      expect(inSheet(find.text('午饭')), findsNothing,
          reason: 'kind 不符的载荷不得装填（否则支出数据会灌进收入表单）');
      expect(inSheet(find.text('A店')), findsNothing);
    });

    testWidgets('载荷 kind 相符 → 装填（含 text 自定义字段的刷新）', (tester) async {
      await seedCustomField();
      StateSetter? rebuild;
      LastEntryDraft? draft;
      var token = 0;

      await tester.pumpWidget(sheetHost(
        transactionKind: 'expense',
        exposeRebuild: (fn) => rebuild = fn,
        draftOf: () => draft,
        tokenOf: () => token,
      ));
      await tester.pumpAndSettle();
      expect(inSheet(find.text('A店')), findsNothing);

      draft = const LastEntryDraft(
        kind: 'expense',
        note: '午饭',
        customValues: {'f-text': 'A店'},
      );
      token = 1;
      rebuild!(() {});
      await tester.pumpAndSettle();

      expect(inSheet(find.text('午饭')), findsOneWidget);
      expect(inSheet(find.text('A店')), findsOneWidget,
          reason: 'text 类型的自定义字段内部状态只在 initState 播种，'
              '装填必须换 key 重建分区才刷得出来');

      // 用户先把字段改成 B店，再点一次（token 再 +1）：**仅填空缺** —— 已有值
      // 的字段保留用户现值，不再被载荷覆盖。
      await tester.enterText(
        find.byKey(const ValueKey('custom_field_input_f-text')),
        'B店',
      );
      await tester.pumpAndSettle();
      expect(inSheet(find.text('B店')), findsOneWidget);

      token = 2;
      rebuild!(() {});
      await tester.pumpAndSettle();

      expect(inSheet(find.text('B店')), findsOneWidget,
          reason: '字段已有值，再次带出不得覆盖（仅填空缺）');
      expect(inSheet(find.text('A店')), findsNothing);
    });
  });

  // ——— 第三层：分类网格形态 ———

  group('分类网格形态（快捷开关关闭）', () {
    testWidgets('点按钮 = 选中上一笔的分类并进入表单，字段从初值起即带出', (tester) async {
      await tester.binding.setSurfaceSize(const Size(800, 1200));
      addTearDown(() async => tester.binding.setSurfaceSize(null));

      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      await seedLastEntry(categoryId: food, accountId: cash, note: '午饭');

      await tester.pumpWidget(await pageHost(quickMode: false));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      // 网格形态：还没进表单，按钮在标题栏右上角
      expect(find.byType(AmountEditorSheet), findsNothing);
      expect(find.byTooltip('带出上一笔'), findsOneWidget);

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '网格形态点按钮 = 替用户点一下上一笔的分类格');
      expect(inSheet(find.text('餐饮')), findsOneWidget);
      expect(inSheet(find.text('午饭')), findsOneWidget);
      expect(inSheet(find.text('现金')), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('上一笔没有分类 → 不打开表单，只提示「请选择分类」', (tester) async {
      // 历史数据 / 跨类型来源：没有可落脚的分类格。
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedLastEntry(note: '午饭');

      await tester.pumpWidget(await pageHost(quickMode: false));
      await tester.pumpAndSettle();
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('带出上一笔'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(find.byType(AmountEditorSheet), findsNothing,
          reason: '没有分类就没有「进哪张表单」的落点，只能等用户点分类格');
      expect(find.text('已带出上一笔，请选择分类'), findsOneWidget);

      // toast 自带 2s 停留定时器：跑完再收尾，否则测试结束时有 pending timer。
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpAndSettle();
    });
  });
}
