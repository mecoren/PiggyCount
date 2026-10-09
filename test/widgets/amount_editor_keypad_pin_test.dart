/// 快捷记账抽屉（`AmountEditorSheet` + `pinKeypad`）的**高度契约**守门。
///
/// 2026-10-09 之前，数字键盘是随整张表单一起进 `SingleChildScrollView` 的
/// （宿主 `transaction_editor_page.dart`）。屏幕一矮，整块一起滚：数字键位置随
/// 内容高度漂移（肌肉记忆失效），「完成」键还会被滚出可视区。改成「上半属性区
/// 自己滚 + 键盘钉在卡片底部」后，用例锁三条判据：
///
///   1. **钉住**：属性区滚到底，「完成」键的 y 一动不动，且始终可点；
///   2. **不留白**：空间够时表单仍是自然高度（不因为多了滚动容器就顶满可用高）；
///   3. **窄屏可辨**：320dp 下未选分类仍显示「选择分类」文字（退化成一个方块
///      图标就认不出这是必选入口），且不产生水平溢出。
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

  /// 把表单放进**给定高度**的容器：等价于抽屉里「留给表单的可用高度」，
  /// 比调 devicePixelRatio 更直观地控制「够 / 不够」两种情形。
  ///
  /// [height] 传 null = 不限高（默认路径用：那种形态下高度由内容决定，外层
  /// 限高反而会逼出溢出 —— 真实调用方是自己套滚动容器）。
  Widget host({double? height, bool pinKeypad = true}) {
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
          body: SizedBox(
            height: height,
            child: AmountEditorSheet(
              pinKeypad: pinKeypad,
              categoryName: '餐饮',
              initialDate: DateTime(2026, 7, 12),
              initialAmount: 12,
              ledgerId: 1,
              onSubmit: (_) {},
            ),
          ),
        ),
      ),
    );
  }

  Finder inSheet(Finder matching) => find.descendant(
        of: find.byType(AmountEditorSheet),
        matching: matching,
      );

  testWidgets('钉键盘：属性区滚到底，「完成」键位置不动且仍可点', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    // 500 装不下「属性区自然高(~300+) + 键盘(294)」→ 走限高 + 属性区滚动分支
    await tester.pumpWidget(host(height: 500));
    await tester.pumpAndSettle();

    final done = inSheet(find.text('完成'));
    expect(done, findsOneWidget, reason: '「完成」键必须在树里');
    final before = tester.getTopLeft(done).dy;

    // 「完成」此刻就该在容器内（键盘钉底的意义：滚动区再长也不把它推出可视区）
    expect(tester.getBottomLeft(done).dy, lessThanOrEqualTo(500),
        reason: '矮屏下「完成」键必须仍在可视区内，否则用户提交不了');

    // 把属性区滚到底，键盘不该跟着动
    final attrScroll = inSheet(find.byType(SingleChildScrollView));
    expect(attrScroll, findsOneWidget,
        reason: '空间不够时滚的是属性区（不是整块表单）');
    await tester.drag(attrScroll, const Offset(0, -200));
    await tester.pumpAndSettle();

    expect(tester.getTopLeft(done).dy, before,
        reason: '键盘必须钉住：属性区滚动不得让数字键 / 「完成」键漂移');

    // 可点（hit testable）——tap 落在不可见 widget 上会直接抛异常
    await tester.tap(done);
    // 提交后按钮转 spinner（无限动画），只能 pump 不能 pumpAndSettle
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('不留白：可用高度宽裕时表单仍按自然高度，不顶满', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    await tester.pumpWidget(host(height: 900));
    await tester.pumpAndSettle();

    final formHeight =
        tester.getSize(find.byType(AmountEditorSheet)).height;
    expect(formHeight, lessThan(900),
        reason: '空间够时必须保持自然高度 —— 用了滚动容器就顶满会留下一大片空白');
    expect(formHeight, greaterThan(500),
        reason: '自然高度应覆盖属性区 + 键盘，别被误压扁');
  });

  testWidgets('窄屏 320dp：未选分类仍显示「选择分类」，且无水平溢出',
      (tester) async {
    // 未选态是「忘了选分类」这条最高频卡住路径，分类位退化成光秃秃的图标
    // （截图里那个方框）用户就认不出来历、也不知道能点。
    tester.view.physicalSize = const Size(320 * 3, 640 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final renderErrors = <String>[];
    final previous = FlutterError.onError;
    FlutterError.onError = (d) => renderErrors.add(d.exceptionAsString());
    addTearDown(() => FlutterError.onError = previous);

    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    await tester.pumpWidget(ProviderScope(
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
            pinKeypad: true,
            categoryName: '餐饮',
            initialDate: DateTime(2026, 7, 12),
            ledgerId: 1,
            // 新建记账的常态：可换分类、但还没选
            onPickCategory: (current, amount) async => null,
            onSubmit: (_) {},
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('选择分类'), findsOneWidget,
        reason: '窄屏也必须看得见「选择分类」这行字');
    expect(
      renderErrors.where((e) => e.contains('on the right')),
      isEmpty,
      reason: '强制显示名字后不许把金额行顶出水平溢出（FittedBox 等比缩兜底）',
    );
  });

  testWidgets('默认（pinKeypad=false）路径不变：表单整体一个滚动容器由调用方决定',
      (tester) async {
    // 转账表单 / 分类网格路径等既有调用方仍走默认形态，布局与改动前逐字一致。
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    await tester.pumpWidget(host(pinKeypad: false));
    await tester.pumpAndSettle();

    expect(
      find.descendant(
        of: find.byType(AmountEditorSheet),
        matching: find.byType(SingleChildScrollView),
      ),
      findsNothing,
      reason: '默认路径不该自带滚动容器（整块交给调用方）',
    );
  });
}
