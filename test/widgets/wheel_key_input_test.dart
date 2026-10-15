/// 日期/时间滚轮抽屉的**数字键盘输入通路**（2026-10-15）。
///
/// 背景：滚轮抽屉没有输入框、不弹输入法，模拟器 / 投屏注入下拖轮对位极难。
/// 本用例锁四件事：
///
///   1. **定宽数字串**：年 4 位、其余 2 位，敲满自动落下一段（`20261015` → 2026-10-15）；
///   2. **越界前推 / 年末段特例**：`7` `0` `5` → 07:05；年段敲 `3` 只做 clamp 不前推；
///   3. **编辑类按键**：退格跨段回退、`.` 分段、`+/-` 与 `↑/↓` 微调、`←/→` 切段、Enter 确认、Esc 取消；
///   4. **通路与闸门**：原生 keyCode 与框架层等价、非当前路由不接键、抽屉销毁必须撤销原生捕获。
library;

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/platform/hardware_key_bridge.dart';
import 'package:piggycount/widgets/ui/wheel_date_picker.dart';
import 'package:piggycount/widgets/ui/wheel_key_input.dart';
import 'package:piggycount/widgets/ui/wheel_time_picker.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// 日期 ymd 的段规格（与 `WheelDatePicker` 的 `ymd` 模式同口径）。
  List<WheelKeyColumn> dateColumns({
    int minYear = 2000,
    int maxYear = 2100,
    int minMonth = 1,
    int maxMonth = 12,
    int maxDay = 31,
    required ValueChanged<int> onYear,
    required ValueChanged<int> onMonth,
    required ValueChanged<int> onDay,
  }) =>
      [
        WheelKeyColumn(
          width: 4,
          prefixMode: WheelKeyPrefixMode.leadingZeros,
          minOf: () => minYear,
          maxOf: () => maxYear,
          currentOf: () => 0,
          onApply: onYear,
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => minMonth,
          maxOf: () => maxMonth,
          currentOf: () => 0,
          onApply: onMonth,
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => 1,
          maxOf: () => maxDay,
          currentOf: () => 0,
          onApply: onDay,
        ),
      ];

  /// 时/分/秒的段规格。
  List<WheelKeyColumn> timeColumns({
    required ValueChanged<int> onHour,
    required ValueChanged<int> onMinute,
    ValueChanged<int>? onSecond,
  }) =>
      [
        WheelKeyColumn(
          width: 2,
          minOf: () => 0,
          maxOf: () => 23,
          currentOf: () => 0,
          onApply: onHour,
        ),
        WheelKeyColumn(
          width: 2,
          minOf: () => 0,
          maxOf: () => 59,
          currentOf: () => 0,
          onApply: onMinute,
        ),
        if (onSecond != null)
          WheelKeyColumn(
            width: 2,
            minOf: () => 0,
            maxOf: () => 59,
            currentOf: () => 0,
            onApply: onSecond,
          ),
      ];

  group('控制器：定宽数字串', () {
    test('年 4 位 + 月 2 位 + 日 2 位：20261015 → 2026 / 10 / 15', () {
      int? y, m, d;
      final c = WheelKeyInputController(
        columns: dateColumns(
          onYear: (v) => y = v,
          onMonth: (v) => m = v,
          onDay: (v) => d = v,
        ),
        onConfirm: () {},
        onCancel: () {},
      );

      for (final s in ['2', '0', '2', '6', '1', '0', '1', '5']) {
        c.handleLogicalKey(
            kHardwareDigits.entries.firstWhere((e) => e.value == s).key);
      }

      expect(y, 2026);
      expect(m, 10);
      expect(d, 15);
      expect(c.hasKeyboardInput, isTrue);
    });

    test('年段前缀中间态：2 → 2000，202 → 2020，2026 → 2026', () {
      final applied = <int>[];
      final c = WheelKeyInputController(
        columns: [
          WheelKeyColumn(
            width: 4,
            prefixMode: WheelKeyPrefixMode.leadingZeros,
            minOf: () => 2000,
            maxOf: () => 2100,
            currentOf: () => 2000,
            onApply: applied.add,
          ),
        ],
        onConfirm: () {},
        onCancel: () {},
      );

      c.handleLogicalKey(LogicalKeyboardKey.digit2);
      expect(applied.last, 2000);
      c.handleLogicalKey(LogicalKeyboardKey.digit0);
      expect(applied.last, 2000);
      c.handleLogicalKey(LogicalKeyboardKey.digit2);
      expect(applied.last, 2020);
      c.handleLogicalKey(LogicalKeyboardKey.digit6);
      expect(applied.last, 2026);
    });

    test('年段越界只做 clamp，不前推给月段', () {
      int? y, m;
      final c = WheelKeyInputController(
        columns: dateColumns(
            onYear: (v) => y = v, onMonth: (v) => m = v, onDay: (_) {}),
        onConfirm: () {},
        onCancel: () {},
      );

      // 敲 "3"（=3000）应 clamp 到 2100，且月份段一个值都不该收到。
      c.handleLogicalKey(LogicalKeyboardKey.digit3);

      expect(y, 2100);
      expect(m, isNull, reason: '年段溢出不前推（年是 4 位定宽整体）');
    });
  });

  group('控制器：时/分越界前推与自动推进', () {
    test('7 0 5 → 07:05（"70" 越界把 0 前推给分段）', () {
      int? h, m;
      final c = WheelKeyInputController(
        columns: timeColumns(onHour: (v) => h = v, onMinute: (v) => m = v),
        onConfirm: () {},
        onCancel: () {},
      );

      c.handleLogicalKey(LogicalKeyboardKey.digit7);
      expect(h, 7);
      c.handleLogicalKey(LogicalKeyboardKey.digit0);
      expect(h, 7, reason: '时段定案在 07，"70" 越界不生效');
      expect(m, 0, reason: '"0" 前推给分段');
      c.handleLogicalKey(LogicalKeyboardKey.digit5);
      expect(m, 5, reason: '分段缓冲为 "0"，再敲 5 得 05');
    });

    test('1 3 4 5 → 13:45（敲满自动落下一段）', () {
      int? h, m;
      final c = WheelKeyInputController(
        columns: timeColumns(onHour: (v) => h = v, onMinute: (v) => m = v),
        onConfirm: () {},
        onCancel: () {},
      );

      for (final k in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
      ]) {
        c.handleLogicalKey(k);
      }

      expect(h, 13);
      expect(m, 45);
    });

    test('末段越界重开一位：秒段已有 "9" 再敲 9 → 09', () {
      final secs = <int>[];
      final c = WheelKeyInputController(
        columns: timeColumns(
          onHour: (_) {},
          onMinute: (_) {},
          onSecond: secs.add,
        ),
        onConfirm: () {},
        onCancel: () {},
      );

      // 先走到秒段：时 00 分 00。
      for (final k in [
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
      ]) {
        c.handleLogicalKey(k);
      }
      expect(c.activeIndex, 2, reason: '敲满时/分后当前段应落在秒段');

      c.handleLogicalKey(LogicalKeyboardKey.digit9);
      expect(secs.last, 9);
      c.handleLogicalKey(LogicalKeyboardKey.digit9);
      expect(secs.last, 9, reason: '"99" 越界，末段重开一位 → 09');
    });
  });

  group('控制器：编辑类按键', () {
    test('退格跨段回退', () {
      int? m, d;
      final c = WheelKeyInputController(
        columns: dateColumns(
            onYear: (_) {}, onMonth: (v) => m = v, onDay: (v) => d = v),
        onConfirm: () {},
        onCancel: () {},
      );

      for (final v in ['2', '0', '2', '6', '1', '0', '1']) {
        c.handleLogicalKey(
            kHardwareDigits.entries.firstWhere((e) => e.value == v).key);
      }
      expect(d, 1);

      c.handleLogicalKey(LogicalKeyboardKey.backspace);
      expect(d, 1, reason: '日段缓冲删空后值保持');
      expect(c.activeIndex, 2);

      c.handleLogicalKey(LogicalKeyboardKey.backspace);
      expect(m, 1, reason: '继续退格回退到月段：10 → 1');
      expect(c.activeIndex, 1);
    });

    test('句点作分段键：. . 15 → 年月不动、日 = 15', () {
      int? y, m, d;
      final c = WheelKeyInputController(
        columns: dateColumns(
            onYear: (v) => y = v, onMonth: (v) => m = v, onDay: (v) => d = v),
        onConfirm: () {},
        onCancel: () {},
      );

      c.handleLogicalKey(LogicalKeyboardKey.period);
      c.handleLogicalKey(LogicalKeyboardKey.period);
      expect(c.activeIndex, 2);
      expect(y, isNull, reason: '分段键不改值');
      expect(m, isNull);

      c.handleLogicalKey(LogicalKeyboardKey.digit1);
      c.handleLogicalKey(LogicalKeyboardKey.digit5);
      expect(d, 15);
    });

    test('+/- 与 ↑/↓ 微调当前段，且不越界', () {
      final hours = <int>[];
      var current = 23;
      final c = WheelKeyInputController(
        columns: [
          WheelKeyColumn(
            width: 2,
            minOf: () => 0,
            maxOf: () => 23,
            currentOf: () => current,
            onApply: (v) {
              current = v;
              hours.add(v);
            },
          ),
        ],
        onConfirm: () {},
        onCancel: () {},
      );

      c.handleLogicalKey(LogicalKeyboardKey.arrowUp);
      expect(hours.last, 23, reason: '已在段上限，↑ 停在 23');
      c.handleLogicalKey(LogicalKeyboardKey.minus);
      expect(hours.last, 22);
      c.handleLogicalKey(LogicalKeyboardKey.numpadSubtract);
      expect(hours.last, 21);
    });

    test('←/→ 切段：目标段缓冲被重置', () {
      int? h, m;
      final c = WheelKeyInputController(
        columns: timeColumns(onHour: (v) => h = v, onMinute: (v) => m = v),
        onConfirm: () {},
        onCancel: () {},
      );

      // 时分都敲满，当前段在分段（末段）。
      for (final k in [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit3,
        LogicalKeyboardKey.digit4,
        LogicalKeyboardKey.digit5,
      ]) {
        c.handleLogicalKey(k);
      }
      expect(m, 45);

      c.handleLogicalKey(LogicalKeyboardKey.arrowLeft);
      expect(c.activeIndex, 0, reason: '← 回到时段');
      c.handleLogicalKey(LogicalKeyboardKey.digit0);
      c.handleLogicalKey(LogicalKeyboardKey.digit8);
      expect(h, 8, reason: '时段缓冲已重置，"0" "8" 得 08 而不是拼在 13 上');
    });

    test('未被消费的键返回 false', () {
      final c = WheelKeyInputController(
        columns: timeColumns(onHour: (_) {}, onMinute: (_) {}),
        onConfirm: () {},
        onCancel: () {},
      );

      expect(c.handleLogicalKey(LogicalKeyboardKey.asterisk), isFalse);
      expect(
        c.handleLogicalKey(LogicalKeyboardKey.keyA),
        isFalse,
        reason: '字母键不消费',
      );
    });

    test('Enter 走确认、Esc 走取消', () {
      var confirmed = 0, cancelled = 0;
      final c = WheelKeyInputController(
        columns: timeColumns(onHour: (_) {}, onMinute: (_) {}),
        onConfirm: () => confirmed++,
        onCancel: () => cancelled++,
      );

      c.handleLogicalKey(LogicalKeyboardKey.numpadEnter);
      c.handleLogicalKey(LogicalKeyboardKey.escape);

      expect(confirmed, 1);
      expect(cancelled, 1);
    });
  });

  /// 打开抽屉的宿主：按钮 → 弹抽屉 → 结果回填 [result]。
  Widget host({
    required Future<void> Function(BuildContext) open,
  }) =>
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: TextButton(
                onPressed: () => open(context),
                child: const Text('打开选择器'),
              ),
            ),
          ),
        ),
      );

  Future<void> typeKeys(
      WidgetTester tester, List<LogicalKeyboardKey> keys) async {
    for (final k in keys) {
      await tester.sendKeyEvent(k);
      await tester.pump();
    }
  }

  Future<void> pressEnter(WidgetTester tester) async {
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
  }

  const keysChannel = MethodChannel('com.wait.piggycount/hardware_keys');

  /// 模拟原生 Activity 经平台通道回传一个 Android keyCode（native → Dart）。
  Future<void> sendNativeKey(WidgetTester tester, int keyCode) async {
    final data = const StandardMethodCodec()
        .encodeMethodCall(MethodCall('onKeyDown', {'keyCode': keyCode}));
    await tester.binding.defaultBinaryMessenger
        .handlePlatformMessage(keysChannel.name, data, (_) {});
    await tester.pump();
  }

  /// 记录原生侧收到的 setCapture 开关（断言「成对注册/撤销」）。
  List<bool> captureLog() {
    final log = <bool>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keysChannel, (call) async {
      if (call.method == 'setCapture') {
        log.add(call.arguments['enabled'] as bool);
      }
      return null;
    });
    return log;
  }

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(keysChannel, null);
  });

  group('WheelDatePicker', () {
    testWidgets('键盘 20261015 + Enter → 2026-10-15，且年列滚轮实时跟随', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result =
              await showWheelDatePicker(context, initial: DateTime(2026, 9, 5));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await typeKeys(tester, [
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit5,
      ]);

      // 年列（第一个 CupertinoPicker）应已跳到 2026 的索引（2000 起第 26 项）。
      final yearPicker = tester
          .widgetList<CupertinoPicker>(
            find.byType(CupertinoPicker),
          )
          .first;
      expect(yearPicker.scrollController!.selectedItem, 26,
          reason: '键盘改值必须驱动滚轮跳位，不能「值变了轮子不动」');

      await pressEnter(tester);
      expect(result, DateTime(2026, 10, 15));
    });

    testWidgets('minDate 裁剪后键入按当前段范围 clamp', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(
            context,
            initial: DateTime(2026, 10, 15),
            minDate: DateTime(2026, 10, 1),
          );
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      // 月段可选范围是 10..12，键入 "05" 应 clamp 到 10。
      await typeKeys(tester, [
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
      ]);
      await pressEnter(tester);

      expect(result, DateTime(2026, 10, 15));
    });

    testWidgets('ym 模式只有两段：键入 202610 即满', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(
            context,
            initial: DateTime(2026, 3, 1),
            mode: WheelDatePickerMode.ym,
          );
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await typeKeys(tester, [
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit0,
      ]);
      await pressEnter(tester);

      expect(result, DateTime(2026, 10, 1), reason: 'ym 模式日按 1 补齐');
    });

    testWidgets('Esc 关闭且返回 null', (tester) async {
      DateTime? result = DateTime(1999);
      await tester.pumpWidget(host(
        open: (context) async {
          result =
              await showWheelDatePicker(context, initial: DateTime(2026, 9, 5));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(result, isNull);
    });
  });

  group('WheelTimePicker', () {
    testWidgets('键盘 7 0 5 + Enter → 07:05', (tester) async {
      TimeOfDay? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await typeKeys(tester, [
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
      ]);
      await pressEnter(tester);

      expect(result, const TimeOfDay(hour: 7, minute: 5));
    });

    testWidgets('原生 keyCode 通路与框架层等价：0 7 0 5 → 07:05', (tester) async {
      TimeOfDay? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      // Android keyCode：7 = KEYCODE_0，15 = KEYCODE_8… 这里按 0 / 7 / 0 / 5 敲。
      for (final code in [7, 14, 7, 12]) {
        await sendNativeKey(tester, code);
      }
      await sendNativeKey(tester, 66); // KEYCODE_ENTER
      await tester.pumpAndSettle();

      expect(result, const TimeOfDay(hour: 7, minute: 5));
    });

    testWidgets('打开时申请原生捕获，销毁时撤销', (tester) async {
      final log = captureLog();
      await tester.pumpWidget(host(
        open: (context) async {
          await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      expect(log, contains(true), reason: 'MuMu / 投屏注入进不了框架层，必须申请原生捕获');

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(log.last, isFalse, reason: '抽屉销毁必须撤销捕获，否则关闭后持续吞数字键');
    });

    testWidgets('未键入时不出现当前段描边（触摸路径零影响）', (tester) async {
      await tester.pumpWidget(host(
        open: (context) async {
          await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      expect(find.byKey(WheelKeyActiveOverlay.borderKey), findsNothing);

      await typeKeys(tester, [LogicalKeyboardKey.digit7]);
      expect(find.byKey(WheelKeyActiveOverlay.borderKey), findsOneWidget,
          reason: '发生键盘键入后才提示当前段');
    });

    testWidgets('非当前路由不接键', (tester) async {
      TimeOfDay? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      // 在抽屉之上再盖一层路由：抽屉不再是当前路由，按键必须让出去。
      final navigator = tester.state<NavigatorState>(
        find.byType(Navigator).first,
      );
      navigator.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('盖在抽屉上的页面')),
      ));
      await tester.pumpAndSettle();

      await typeKeys(tester, [
        LogicalKeyboardKey.digit7,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
      ]);

      navigator.pop();
      await tester.pumpAndSettle();
      await pressEnter(tester);

      expect(result, const TimeOfDay(hour: 9, minute: 30),
          reason: '抽屉不是当前路由时不得截键');
    });
  });

  /// 断描边落在第 [index] 列（0 起）：描边与所在列同宽同中心，比 dx 即可。
  void expectActiveColumn(WidgetTester tester, int index) {
    final border =
        tester.getCenter(find.byKey(WheelKeyActiveOverlay.borderKey));
    final column = tester.getCenter(find.byType(CupertinoPicker).at(index));
    expect(border.dx, closeTo(column.dx, 1), reason: '描边应落在第 $index 列（0 起）');
  }

  /// 点按某列（模拟器 / 投屏下用鼠标点选该列作为键盘输入目标）。
  Future<void> tapColumn(WidgetTester tester, int index) async {
    await tester.tap(find.byType(CupertinoPicker).at(index));
    await tester.pumpAndSettle();
  }

  group('WheelDatePicker：段选择跟随指针（R7）', () {
    testWidgets('点按日列后敲 5 → 只改日，年月不动，描边落在日列', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(context,
              initial: DateTime(2026, 9, 20));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tapColumn(tester, 2); // 日列
      expect(find.byKey(WheelKeyActiveOverlay.borderKey), findsNothing,
          reason: '触摸选段本身不画描边（AC-R5 #1 零按键零影响）');

      await typeKeys(tester, [LogicalKeyboardKey.digit5]);
      expectActiveColumn(tester, 2);

      await pressEnter(tester);
      expect(result, DateTime(2026, 9, 5), reason: '年、月必须原样不动');
    });

    testWidgets('点按月列后敲 1205 → 月 12 日 5，年不动', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(context,
              initial: DateTime(2026, 3, 20));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tapColumn(tester, 1); // 月列
      await typeKeys(tester, [
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
      ]);
      await pressEnter(tester);
      expect(result, DateTime(2026, 12, 5));
    });

    testWidgets('邻列联动跳动不偷活动段（月→日 clamp 同步）', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(context,
              initial: DateTime(2024, 1, 31));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tapColumn(tester, 1); // 月列
      // 键入 2：月 → 2，日 31 越界被 clamp 到 29，日轮因此跳位（会触发
      // onSelectedItemChanged）。活动段必须仍在月列，不能被这次联动偷走。
      await typeKeys(tester, [LogicalKeyboardKey.digit2]);
      expectActiveColumn(tester, 1);

      await pressEnter(tester);
      expect(result, DateTime(2024, 2, 29));
    });
  });

  group('WheelTimePicker：段选择跟随指针（R7）', () {
    testWidgets('点按分列后敲 5 → 分 5，时不动', (tester) async {
      TimeOfDay? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tapColumn(tester, 1); // 分列
      await typeKeys(tester, [LogicalKeyboardKey.digit5]);
      expectActiveColumn(tester, 1);

      await pressEnter(tester);
      expect(result, const TimeOfDay(hour: 9, minute: 5));
    });
  });

  /// 第 [index] 列滚轮当前停在哪一**项**（`selectedItem` 是滚轮的视觉真相：值变了
  /// 轮子没动、或轮子被悄悄重置，只有它能看见）。
  int wheelIndex(WidgetTester tester, int index) => tester
      .widgetList<CupertinoPicker>(find.byType(CupertinoPicker))
      .elementAt(index)
      .scrollController!
      .selectedItem;

  group('切换输入列不得回退初值（2026-10-15 用户报障回归）', () {
    testWidgets('日期：月列键入 2 后点日列，月轮与月值都不得退回打开时的 10 月', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDatePicker(context,
              initial: DateTime(2026, 10, 15));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      // 滚轮尺寸口径：包裹层不得改变列的尺寸（目标 52 项高 × 可见 3 项）。
      expect(tester.getSize(find.byType(CupertinoPicker).at(0)).height, 156,
          reason: '列的包裹结构不得改变滚轮尺寸');

      await tapColumn(tester, 1); // 月列
      await typeKeys(tester, [LogicalKeyboardKey.digit2]); // 月 → 2
      expect(wheelIndex(tester, 1), 1, reason: '键入 2 后月轮应停在第 2 项（2 月）');

      await tapColumn(tester, 2); // 点日列：月列不再是输入目标
      expect(wheelIndex(tester, 1), 1, reason: '点别的列不能让本列滚轮退回打开时的初值（10 月）');

      await pressEnter(tester);
      expect(result, DateTime(2026, 2, 15), reason: '月值也不得被回退改写');
    });

    testWidgets('时间：分列键入 5 后点时列，分轮与分值都不得退回打开时的 30 分', (tester) async {
      TimeOfDay? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelTimePicker(context,
              initial: const TimeOfDay(hour: 9, minute: 30));
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      await tapColumn(tester, 1); // 分列
      await typeKeys(tester, [LogicalKeyboardKey.digit5]); // 分 → 5
      expect(wheelIndex(tester, 1), 5, reason: '键入 5 后分轮应停在第 5 项');

      await tapColumn(tester, 0); // 点时列
      expect(wheelIndex(tester, 1), 5, reason: '点别的列不能让分轮退回打开时的 30 分');

      await pressEnter(tester);
      expect(result, const TimeOfDay(hour: 9, minute: 5));
    });
  });

  group('两步流', () {
    testWidgets('日期步 Enter 进时间步，时间步 071530 → 07:15:30', (tester) async {
      DateTime? result;
      await tester.pumpWidget(host(
        open: (context) async {
          result = await showWheelDateTimePicker(
            context,
            initial: DateTime(2026, 9, 5, 9, 30, 0),
          );
        },
      ));
      await tester.tap(find.text('打开选择器'));
      await tester.pumpAndSettle();

      // 第一步：日期 2026-10-05。
      await typeKeys(tester, [
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit2,
        LogicalKeyboardKey.digit6,
        LogicalKeyboardKey.digit1,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit0,
        LogicalKeyboardKey.digit5,
      ]);
      await pressEnter(tester);

      // 第二步：时间 07:15:30。
      for (final v in ['0', '7', '1', '5', '3', '0']) {
        await tester.sendKeyEvent(
            kHardwareDigits.entries.firstWhere((e) => e.value == v).key);
        await tester.pump();
      }
      await pressEnter(tester);

      expect(result, DateTime(2026, 10, 5, 7, 15, 30));
    });
  });
}
