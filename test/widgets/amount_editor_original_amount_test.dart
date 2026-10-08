/// v45 记账弹窗「输入目标切换」回归：点哪个金额位，下方自定义数字键盘就输哪个。
///
/// - 默认目标 = 记账金额（原行为不变）；
/// - 点原始金额位后，数字键写进原始金额，记账金额不受影响；
/// - 原始金额退格清空 = 未填写（回显 hint，不补 0）—— 与记账金额清空回落
///   '0' 的行为刻意不同；
/// - 运算符作用于**当前目标**，不把焦点抢回记账金额；两个金额位的算式
///   各自独立（累加器按目标隔离），互不污染。
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

  Widget host({double? initialAmount, double? initialOriginalAmount}) {
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
            categoryName: '餐饮',
            initialDate: DateTime(2026, 7, 12),
            initialAmount: initialAmount,
            initialOriginalAmount: initialOriginalAmount,
            ledgerId: 1,
            onSubmit: (_) {},
          ),
        ),
      ),
    );
  }

  /// 弹窗整体比默认测试视口高（含数字键盘），放大视口保证所有键可点。
  Future<void> pumpEditor(WidgetTester tester, Widget widget) async {
    tester.view.physicalSize = const Size(1200, 2800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(widget);
  }

  String textOf(WidgetTester tester, String key) =>
      tester.widget<Text>(find.byKey(ValueKey(key))).data!;

  Future<void> tapKey(WidgetTester tester, String label) async {
    await tester.tap(find.byKey(ValueKey('amountKey_$label')));
    await tester.pump();
  }

  Future<void> tapBackspace(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.backspace_outlined));
    await tester.pump();
  }

  Future<void> tapOp(WidgetTester tester, String addSubOp) async {
    await tester.tap(find.byKey(ValueKey('amountOpKey_$addSubOp')));
    // 运算符键的 InkWell 同时挂了 onDoubleTap/onLongPress，单击要等
    // 双击判定窗口过去才分发给 onTap。
    await tester.pump(const Duration(milliseconds: 400));
  }

  testWidgets('默认输入目标是记账金额', (tester) async {
    await pumpEditor(tester, host(initialAmount: 7));

    expect(textOf(tester, 'amountEditorAmountValue'), '7');
    // 原始金额位是空串 → 显示 hint。
    expect(textOf(tester, 'amountEditorOriginalValue'), '留空则按记账金额');

    await tapKey(tester, '5');
    await tapKey(tester, '0');

    expect(textOf(tester, 'amountEditorAmountValue'), '750');
    expect(textOf(tester, 'amountEditorOriginalValue'), '留空则按记账金额');
  });

  testWidgets('点原始金额位后，数字键输到原始金额且不动记账金额', (tester) async {
    await pumpEditor(tester, host(initialAmount: 366));

    await tester.tap(find.byKey(const ValueKey('amountEditorOriginalValue')));
    await tester.pump();

    await tapKey(tester, '4');
    await tapKey(tester, '0');
    await tapKey(tester, '0');

    expect(textOf(tester, 'amountEditorOriginalValue'), '400');
    expect(textOf(tester, 'amountEditorAmountValue'), '366');
  });

  testWidgets('原始金额退格清空 = 未填写（回显 hint，不补 0）', (tester) async {
    await pumpEditor(
        tester, host(initialAmount: 366, initialOriginalAmount: 400));

    await tester.tap(find.byKey(const ValueKey('amountEditorOriginalValue')));
    await tester.pump();

    await tapBackspace(tester); // 40
    await tapBackspace(tester); // 4
    await tapBackspace(tester); // 空
    expect(textOf(tester, 'amountEditorOriginalValue'), '留空则按记账金额');

    // 记账金额清空则回落 '0'（保持原行为，两者语义不同）。
    await tester.tap(find.byKey(const ValueKey('amountEditorAmountValue')));
    await tester.pump();
    await tapBackspace(tester); // 36
    await tapBackspace(tester); // 3
    await tapBackspace(tester); // 0
    expect(textOf(tester, 'amountEditorAmountValue'), '0');
  });

  testWidgets('原始金额位按运算符不跳回记账金额，两个算式各自独立', (tester) async {
    await pumpEditor(tester, host(initialAmount: 100));

    // 1) 记账金额位起一个未完成的算式：100 + 20
    await tapOp(tester, '+');
    await tapKey(tester, '2');
    await tapKey(tester, '0');
    expect(textOf(tester, 'amountEditorAmountValue'), '20');

    // 2) 切到原始金额位输入 40，再按 + ：焦点不能被抢回记账金额
    await tester.tap(find.byKey(const ValueKey('amountEditorOriginalValue')));
    await tester.pump();
    await tapKey(tester, '4');
    await tapKey(tester, '0');
    await tapOp(tester, '+');

    // 原始金额位就地显示自己的算式（40 + 0），焦点仍在这里
    expect(textOf(tester, 'amountEditorOriginalValue'), '40 + 0');

    await tapKey(tester, '5');
    expect(textOf(tester, 'amountEditorOriginalValue'), '40 + 5');

    // 记账金额的算式没被污染
    expect(textOf(tester, 'amountEditorAmountValue'), '20');
  });

  testWidgets('切回记账金额后，数字键重新作用于记账金额', (tester) async {
    await pumpEditor(tester, host(initialAmount: 100));

    await tester.tap(find.byKey(const ValueKey('amountEditorOriginalValue')));
    await tester.pump();
    await tapKey(tester, '9');
    expect(textOf(tester, 'amountEditorOriginalValue'), '9');

    await tester.tap(find.byKey(const ValueKey('amountEditorAmountValue')));
    await tester.pump();
    await tapKey(tester, '8');

    expect(textOf(tester, 'amountEditorAmountValue'), '1008');
    expect(textOf(tester, 'amountEditorOriginalValue'), '9');
  });
}
