/// 金额表单的硬件键盘输入通路（2026-10-15）。
///
/// 背景：金额位是纯展示组件（无输入连接，**这条通路不弹输入法**），模拟器硬件
/// 键盘 / 投屏注入 / 蓝牙键盘的物理按键曾经无处可去 —— 敲键盘没反应。现在由
/// [HardwareKeyboard] 全局监听接住后路由到屏幕小键盘的既有逻辑。本用例锁四件事：
///
///   1. 数字 / 小数 / 退格键输进金额位；
///   2. 运算符键 + Enter 先当等号求值（不直接提交）；
///   3. 输入框（备注）持有焦点时不抢它的键；
///   4. [AmountEditorSheet.hardwareKeysEnabled] 为 false（IndexedStack 里保活
///      但不可见的那份表单）时不接键。
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

  const keysChannel = MethodChannel('com.wait.piggycount/hardware_keys');

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keysChannel, null);
  });

  /// 模拟原生 Activity 经平台通道回传一个 Android keyCode（native → Dart）。
  Future<void> sendNativeKey(WidgetTester tester, int keyCode) async {
    final data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall('onKeyDown', {'keyCode': keyCode}));
    await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
        'com.wait.piggycount/hardware_keys', data, (_) {});
    await tester.pump();
  }

  Ledger cnyLedger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        monthStartDay: 1,
      );

  Widget host({
    bool hardwareKeysEnabled = true,
    ValueChanged<AmountEditorResult>? onSubmit,
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
            categoryName: '餐饮',
            initialDate: DateTime(2026, 9, 18),
            ledgerId: 1,
            hardwareKeysEnabled: hardwareKeysEnabled,
            onSubmit: onSubmit ?? (_) {},
          ),
        ),
      ),
    );
  }

  String amountText(WidgetTester tester) => tester
      .widget<Text>(find.byKey(const ValueKey('amountEditorAmountValue')))
      .data!;

  Future<void> type(
      WidgetTester tester, List<LogicalKeyboardKey> keys) async {
    for (final k in keys) {
      // 模拟器按 debugName 反查物理键：Add 没有同名物理键（物理侧叫
      // Numpad Add），不显式指定会在模拟阶段直接断言失败。
      await tester.sendKeyEvent(
        k,
        physicalKey:
            k == LogicalKeyboardKey.add ? PhysicalKeyboardKey.numpadAdd : null,
      );
      await tester.pump();
    }
  }

  testWidgets('数字 / 小数 / 退格键输进金额位', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await type(tester, [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.period,
      LogicalKeyboardKey.digit5,
    ]);
    expect(amountText(tester), '12.5');

    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(amountText(tester), '12.');
  });

  testWidgets('Delete 键与退格同效', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await type(tester, [LogicalKeyboardKey.digit1, LogicalKeyboardKey.digit2]);
    expect(amountText(tester), '12');

    await tester.sendKeyEvent(LogicalKeyboardKey.delete);
    await tester.pump();
    expect(amountText(tester), '1', reason: 'Delete 与退格同效');
  });

  testWidgets('Esc 键：与标题栏关闭同一动作，关掉弹层', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 推入路由而非直接当 home：Esc 走 maybePop，放在根路由上没得弹、断言不了。
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
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => Scaffold(
                      body: AmountEditorSheet(
                        categoryName: '餐饮',
                        initialDate: DateTime(2026, 9, 18),
                        ledgerId: 1,
                        onSubmit: (_) {},
                      ),
                    ),
                  ),
                ),
                child: const Text('打开记账'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开记账'));
    await tester.pumpAndSettle();
    expect(find.byType(AmountEditorSheet), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(AmountEditorSheet), findsNothing,
        reason: 'Esc 与标题栏关闭按钮同动作，应关掉弹层');
  });

  testWidgets('运算符键 + Enter 先当等号求值，不提交', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    var submitted = 0;
    await tester.pumpWidget(host(onSubmit: (_) => submitted++));
    await tester.pumpAndSettle();

    await type(tester, [
      LogicalKeyboardKey.digit1,
      LogicalKeyboardKey.add,
      LogicalKeyboardKey.digit2,
      LogicalKeyboardKey.enter,
    ]);
    expect(amountText(tester), '3');
    expect(submitted, 0, reason: '运算模式下 Enter 当等号，不能直接提交');
  });

  testWidgets('备注框持有焦点时不抢它的键', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    // 硬件键把字符插进输入框是引擎侧行为，widget 测试模拟不到；这里锁的契约是
    // 「输入框持有焦点时金额表单不消费按键」—— 消费了输入框就收不到字。
    final handled = await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
    await tester.pump();

    expect(handled, isFalse, reason: '备注框持有焦点时硬件键不应被金额表单消费');
    expect(amountText(tester), '0');
  });

  testWidgets('hardwareKeysEnabled 为 false 时不接键', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host(hardwareKeysEnabled: false));
    await tester.pumpAndSettle();

    await type(tester, [LogicalKeyboardKey.digit5]);
    expect(amountText(tester), '0');
  });

  testWidgets('选过备注后点金额位，硬件键回到金额位', (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 备注获焦：硬件键不消费（让给输入框）。
    await tester.tap(find.byType(TextField));
    await tester.pumpAndSettle();
    expect(await tester.sendKeyEvent(LogicalKeyboardKey.digit7), isFalse);

    // 点金额位 = 回到键盘输入：收起备注焦点后硬件键重新被金额位消费。
    await tester.tap(find.byKey(const ValueKey('amountEditorAmountValue')));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.digit7);
    await tester.pump();
    expect(amountText(tester), '7');
  });

  testWidgets('原生 Activity 回传的 keyCode 也输进金额位（MuMu / 投屏兜底）',
      (tester) async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 8=KEYCODE_1, 9=KEYCODE_2, 56=KEYCODE_PERIOD, 12=KEYCODE_5
    for (final code in [8, 9, 56, 12]) {
      await sendNativeKey(tester, code);
    }
    expect(amountText(tester), '12.5');

    // 54=KEYCODE_Z：不在映射内，不应被金额表单消费（否则打字 z 会变成小数点）。
    await sendNativeKey(tester, 54);
    expect(amountText(tester), '12.5');

    await sendNativeKey(tester, 67); // DEL（退格）
    expect(amountText(tester), '12.');
  });

  testWidgets('可见表单请求原生捕获，hardwareKeysEnabled=false 不请求', (tester) async {
    final captured = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keysChannel, (call) async {
      if (call.method == 'setCapture') {
        captured.add((call.arguments as Map)['enabled'] as bool);
      }
      return true;
    });

    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();
    expect(captured, contains(true), reason: '可见且可接键时应请求原生捕获');

    captured.clear();
    await tester.pumpWidget(host(hardwareKeysEnabled: false));
    await tester.pumpAndSettle();
    expect(captured, contains(false),
        reason: '切到不可见分段（hardwareKeysEnabled=false）应释放原生捕获');
  });
}
