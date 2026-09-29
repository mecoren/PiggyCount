// AppDialog 确认框回归（左图 iOS 口径）：
// - destructive: true → 窄卡片 + 居中标题/说明 + 底部「取消｜删除」
//   分栏文本按钮（确认侧 error 色），点删除返回 true、取消返回 false
// - 默认 confirm → 同样 iOS 分栏，确认侧主题 primary 色
// - info 单按钮 → 单个全宽确认钮

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/dialog.dart';

Widget _wrap() => const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('zh'),
      home: Scaffold(body: SizedBox.shrink()),
    );

void main() {
  testWidgets('destructive 确认框：点删除返回 true', (tester) async {
    await tester.pumpWidget(_wrap());

    final future = AppDialog.confirm<bool>(
      tester.element(find.byType(Scaffold)),
      title: '删除确认',
      message: '确定要删除这条记账吗？',
      okLabel: '删除',
      destructive: true,
    );
    var result = false;
    future.then((v) => result = v ?? false);

    await tester.pump();
    expect(find.text('删除确认'), findsOneWidget);
    expect(find.text('确定要删除这条记账吗？'), findsOneWidget);
    // iOS 分栏：文本按钮，无 Filled/Outlined 大按钮
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '删除'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pump();
    expect(result, isTrue);
  });

  testWidgets('destructive 确认框：点取消返回 false', (tester) async {
    await tester.pumpWidget(_wrap());

    final future = AppDialog.confirm<bool>(
      tester.element(find.byType(Scaffold)),
      title: '删除确认',
      message: '确定要删除这条记账吗？',
      okLabel: '删除',
      destructive: true,
    );
    var result = true;
    future.then((v) => result = v ?? true);

    await tester.pump();
    await tester.tap(find.text('取消'));
    await tester.pump();
    expect(result, isFalse);
  });

  testWidgets('按钮文字颜色：取消正文色、删除危险色', (tester) async {
    // 回归：bodyLarge 自带 onSurface 默认色，曾盖掉按钮 foregroundColor
    // 导致「删除」红字显示为深色。
    await tester.pumpWidget(_wrap());

    AppDialog.confirm<bool>(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      message: 'M',
      okLabel: '删除',
      destructive: true,
    );
    await tester.pump();

    final ctx = tester.element(find.byType(Scaffold));
    final cancelStyle = tester.widget<Text>(find.text('取消')).style;
    final okStyle = tester.widget<Text>(find.text('删除')).style;
    expect(cancelStyle?.color, PiggyTokens.textPrimary(ctx));
    expect(okStyle?.color, PiggyTokens.error(ctx));

    await tester.tap(find.text('取消'));
    await tester.pump();
  });

  testWidgets('默认确认框：同为 iOS 分栏，确认钮主题色', (tester) async {
    await tester.pumpWidget(_wrap());

    AppDialog.confirm<bool>(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      message: 'M',
    );

    await tester.pump();
    // 默认 confirm 同样走 iOS 外壳，只是确认侧为主题色而非红色
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.byType(FilledButton), findsNothing);
    expect(find.widgetWithText(TextButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '确定'), findsOneWidget);

    final ctx = tester.element(find.byType(Scaffold));
    final okStyle = tester.widget<Text>(find.text('确定')).style;
    expect(okStyle?.color, PiggyTokens.primary(ctx));

    await tester.tap(find.text('取消'));
    await tester.pump();
  });

  testWidgets('info 单按钮：单个全宽确认钮', (tester) async {
    await tester.pumpWidget(_wrap());

    AppDialog.info<void>(
      tester.element(find.byType(Scaffold)),
      title: 'T',
      message: 'M',
    );

    await tester.pump();
    expect(find.widgetWithText(TextButton, '确定'), findsOneWidget);
    expect(find.text('取消'), findsNothing);

    await tester.tap(find.text('确定'));
    await tester.pump();
  });
}
