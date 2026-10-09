/// 金额表达式行的横向布局契约（2026-10-09）。
///
/// 背景：分类位一度用 `Expanded(flex: 2)` 与金额位 2:2 分宽度，槽位占半行而 chip
/// 只占其中一小截 —— 右半截空白横在币种标前面，就是用户截图里「分类和币种之间
/// 一道大缝」。改成「槽位宽度按内容算（`_categorySlotWidth`）+ 金额位吃剩余」后，
/// 本用例锁三件事：
///
///   1. **无缝**：分类位右边界紧贴币种标左边界（差 ≤ 1px）；
///   2. **不溢出**：窄屏 + 超长分类名 + 6 位金额仍无水平溢出；
///   3. **不退化**：窄屏未选态仍看得见「选择分类」这行字。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';
import 'package:piggycount/widgets/category_icon.dart';

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

  Ledger cnyLedger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        monthStartDay: 1,
      );

  Widget host({
    Category? displayCategory,
    Future<Category?> Function(Category?, double)? onPickCategory,
    double? initialAmount,
  }) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: AmountEditorSheet(
            categoryName: displayCategory?.name ?? '餐饮',
            categoryId: displayCategory?.id,
            displayCategory: displayCategory,
            onPickCategory: onPickCategory,
            initialDate: DateTime(2026, 9, 18),
            initialAmount: initialAmount,
            ledgerId: 1,
            onSubmit: (_) {},
          ),
        ),
      ),
    );
  }

  /// 分类位右边界到币种标左边界之间的距离。
  double gapToCurrencyChip(WidgetTester tester) {
    final category = tester.getRect(
        find.byKey(const ValueKey('amountEditorCategoryChip')));
    final currency = tester.getRect(
        find.byKey(const ValueKey('amountEditorCurrencyChip')));
    return currency.left - category.right;
  }

  List<String> collectRenderErrors(WidgetTester tester) {
    final errors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (details) => errors.add(details.exceptionAsString());
    addTearDown(() => FlutterError.onError = previous);
    return errors;
  }

  testWidgets('已选分类：分类位右边界紧贴币种标（没有那道缝）', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    final food = (await repo.getCategoryById(
        await repo.createCategory(name: '餐饮', kind: 'expense')))!;

    await tester.pumpWidget(host(
      displayCategory: food,
      onPickCategory: (current, amount) async => null,
    ));
    await tester.pumpAndSettle();

    expect(gapToCurrencyChip(tester), lessThanOrEqualTo(1.0),
        reason: '槽位宽度必须按内容算：分类位与币种标之间不许出现大片空白'
            '（曾经 2:2 固定份额时这里是半个行宽的空白）');
  });

  testWidgets('未选分类：同样没有缝，且「选择分类」可读', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    await tester.pumpWidget(host(onPickCategory: (current, amount) async => null));
    await tester.pumpAndSettle();

    expect(find.text('选择分类'), findsOneWidget);
    expect(gapToCurrencyChip(tester), lessThanOrEqualTo(1.0));
  });

  testWidgets('窄屏 320dp + 超长分类名 + 6 位金额：不水平溢出，分类仍可辨认',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    final long = (await repo.getCategoryById(await repo.createCategory(
        name: '餐饮娱乐交通住房购物医疗教育通讯超长分类名称',
        kind: 'expense')))!;

    final renderErrors = collectRenderErrors(tester);
    await tester.pumpWidget(host(
      displayCategory: long,
      onPickCategory: (current, amount) async => null,
      initialAmount: 123456.78,
    ));
    await tester.pumpAndSettle();

    expect(renderErrors.where((e) => e.contains('on the right')), isEmpty,
        reason: '槽位有 40% 行宽的上界，chip 自己三级让位，不该把行顶破');
    expect(find.byType(CategoryIconWidget), findsOneWidget,
        reason: '让位下限仍是「只剩图标」：分类必须可辨认');
  });

  testWidgets('窄屏 320dp 未选态：仍显示「选择分类」文字（不退化成一个方块）',
      (tester) async {
    tester.view.physicalSize = const Size(320 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final renderErrors = collectRenderErrors(tester);
    await tester.pumpWidget(host(onPickCategory: (current, amount) async => null));
    await tester.pumpAndSettle();

    expect(find.text('选择分类'), findsOneWidget,
        reason: '未选态是必选入口，名字必须看得见（放不下由 FittedBox 整体缩）');
    expect(renderErrors.where((e) => e.contains('on the right')), isEmpty);
  });
}
