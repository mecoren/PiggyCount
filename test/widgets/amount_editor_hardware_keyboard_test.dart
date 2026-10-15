/// 记账表单（[AmountEditorSheet]）的**物理键盘输入**契约。
///
/// 金额位是刻意不用 TextField 的：它由下方自制数字键盘输入（避免系统键盘与
/// 自制键盘打架）。代价是——在模拟器 / 连了实机键盘时，宿主机键盘敲进去什么
/// 也不会发生。本用例锁四条判据：
///
///   1. **数字键**：0–9 追加到当前输入目标（这里是记账金额）；
///   2. **小数点 / 退格**：'.' 追加一个小数点，Backspace 删掉末位；
///   3. **Enter**：等价于点「完成」，触发提交；
///   4. **不抢文本框的键**：备注框聚焦时，数字键不许被金额位吞掉。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

  AmountEditorResult? submitted;

  Widget host({double? initialAmount}) {
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
            initialDate: DateTime(2026, 10, 13),
            initialAmount: initialAmount,
            ledgerId: 1,
            onSubmit: (r) => submitted = r,
          ),
        ),
      ),
    );
  }

  Future<void> pumpSheet(WidgetTester tester, {double? initialAmount}) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    submitted = null;
    await tester.pumpWidget(host(initialAmount: initialAmount));
    await tester.pumpAndSettle();
  }

  /// 当前记账金额的显示串（金额位那个 Text 的内容）。
  String amountText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('amountEditorAmountValue')))
      .data!;

  testWidgets('物理键盘数字键：追加到记账金额', (tester) async {
    await pumpSheet(tester, initialAmount: 12);
    expect(amountText(tester), '12');

    await tester.sendKeyEvent(LogicalKeyboardKey.digit3);
    await tester.pump();

    expect(amountText(tester), '123', reason: '宿主机键盘敲 3 应追加到金额串');
  });

  testWidgets('物理键盘小数点：追加一个点', (tester) async {
    await pumpSheet(tester, initialAmount: 12);

    await tester.sendKeyEvent(LogicalKeyboardKey.period);
    await tester.pump();

    expect(amountText(tester), '12.');
  });

  testWidgets('物理键盘退格：删掉末位', (tester) async {
    await pumpSheet(tester, initialAmount: 12);

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();

    expect(amountText(tester), '1');
  });

  testWidgets('物理键盘 Enter：等价于点「完成」，触发提交', (tester) async {
    await pumpSheet(tester, initialAmount: 12);

    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();

    expect(submitted, isNotNull, reason: 'Enter 应触发提交（与点「完成」同一条路径）');
    expect(submitted!.amount, 12);
  });

  testWidgets('备注框聚焦时：数字键进备注，不被金额位吞掉', (tester) async {
    await pumpSheet(tester, initialAmount: 12);

    // 点备注框让它拿到焦点（表单里唯一那个「备注...」TextField）。
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();

    await tester.sendKeyEvent(LogicalKeyboardKey.digit5);
    await tester.pump();

    expect(amountText(tester), '12',
        reason: '备注框聚焦时，数字键归文本框，金额串不许被改动');
  });
}
