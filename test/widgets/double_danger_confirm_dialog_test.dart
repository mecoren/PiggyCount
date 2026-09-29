// 高危操作双重危险确认回归：
// - 第一次确认取消 → 不弹第二次，返回 false
// - 第一次确认后弹第二次（各 5 秒倒计时，确认按钮归零前禁用）
// - 两次都确认 → 返回 true
// - 第二次取消 → 返回 false

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/widgets/ui/dialog.dart';

Widget _wrap() => const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('zh'),
      home: Scaffold(body: SizedBox.shrink()),
    );

void main() {
  testWidgets('第一次取消：只弹一次，返回 false', (tester) async {
    var result = true;
    await tester.pumpWidget(_wrap());

    final future = showDoubleDangerConfirmDialog(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      firstMessage: 'first',
      secondMessage: 'second',
    );
    future.then((v) => result = v);

    await tester.pump();
    // 第一段文案可见
    expect(find.text('first'), findsOneWidget);
    // 倒计时按钮禁用（非归零态显示剩余秒数文案）
    expect(find.widgetWithText(TextButton, '确认（5秒）'), findsOneWidget);

    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(result, isFalse);
    // 没有第二次弹窗
    expect(find.text('second'), findsNothing);
  });

  testWidgets('两次都确认：返回 true，第二段文案确实出现', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var result = false;
    await tester.pumpWidget(_wrap());

    final future = showDoubleDangerConfirmDialog(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      firstMessage: 'first',
      secondMessage: 'second',
    );
    future.then((v) => result = v);

    // ---- 第一次弹窗：倒计时归零后确认 ----
    await tester.pump();
    // 5 秒倒计时：逐秒推进
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    expect(find.text('first'), findsOneWidget);
    await tester.tap(find.text('确定'));
    await tester.pump();

    // ---- 第二次弹窗出现：文案为 second ----
    expect(find.text('second'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('确定'));
    // pumpAndSettle 走完第二个弹窗的出栈过渡动画
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text('second'), findsNothing);
  });

  testWidgets('第二次取消：返回 false', (tester) async {
    tester.view.physicalSize = const Size(800, 1200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    var result = true;
    await tester.pumpWidget(_wrap());

    final future = showDoubleDangerConfirmDialog(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      firstMessage: 'first',
      secondMessage: 'second',
    );
    future.then((v) => result = v);

    // 第一次确认
    await tester.pump();
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('确定'));
    await tester.pump();

    // 第二次取消
    expect(find.text('second'), findsOneWidget);
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    await tester.tap(find.text('取消'));
    await tester.pump();

    expect(result, isFalse);
  });

  testWidgets('倒计时未归零时确认按钮禁用', (tester) async {
    await tester.pumpWidget(_wrap());

    final future = showDoubleDangerConfirmDialog(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      firstMessage: 'first',
      secondMessage: 'second',
      countdownSeconds: 5,
    );
    // 忽略返回值，只验证按钮状态

    await tester.pump();
    // 归零前按钮处于禁用态：按钮文案是「确认（N秒）」而非确认标签
    final counting =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '确认（5秒）'));
    expect(counting.onPressed, isNull);

    // 归零后启用
    for (var i = 0; i < 5; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
    final enabled =
        tester.widget<TextButton>(find.widgetWithText(TextButton, '确定'));
    expect(enabled.onPressed, isNotNull);

    await tester.tap(find.text('取消'));
    await tester.pump();
    await future;
  });
}
