import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/piggy_spinner.dart';

Widget _wrap(Widget child, {Brightness brightness = Brightness.light}) {
  return MaterialApp(
    theme: ThemeData(brightness: brightness),
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  testWidgets('按 size 渲染方形占位', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(size: 24)));

    expect(tester.getSize(find.byType(PiggySpinner)), const Size(24, 24));
  });

  testWidgets('默认尺寸为 20', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner()));

    expect(tester.getSize(find.byType(PiggySpinner)), const Size(20, 20));
  });

  testWidgets('亮/暗两种主题下默认色（取 iconPrimary）均能构建', (tester) async {
    for (final brightness in Brightness.values) {
      await tester
          .pumpWidget(_wrap(const PiggySpinner(), brightness: brightness));
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets('显式传色（主题色按钮 / 深底遮罩用法）可构建', (tester) async {
    await tester.pumpWidget(
      _wrap(
        Builder(
          builder: (context) => PiggySpinner(
            size: 18,
            color: PiggyTokens.textOnPrimary(context),
          ),
        ),
      ),
    );

    expect(find.byType(PiggySpinner), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('描边宽度按 size 比例推导（组件刻意不暴露该参数）', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(size: 40)));

    final painter = tester
        .widget<CustomPaint>(
          find.descendant(
            of: find.byType(PiggySpinner),
            matching: find.byType(CustomPaint),
          ),
        )
        .painter as dynamic;
    expect(painter.strokeWidth, closeTo(40 * 0.08, 0.001));
    expect(tester.takeException(), isNull);
  });

  testWidgets('semanticLabel 透传为 Semantics 标签', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(semanticLabel: '正在加载')));

    expect(find.bySemanticsLabel('正在加载'), findsOneWidget);
  });

  testWidgets('semanticLabel 为 null 时不注入语义节点', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(size: 20)));

    final handle = tester.ensureSemantics();
    expect(find.bySemanticsLabel('正在加载'), findsNothing);
    handle.dispose();
  });

  testWidgets('点持续绕行：多帧推进不抛异常且仍在绘制', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(size: 24)));

    // 只看组件自身子树：Scaffold 的 Material/PhysicalShape 也会建 CustomPaint。
    final ownPaint = find.descendant(
      of: find.byType(PiggySpinner),
      matching: find.byType(CustomPaint),
    );
    expect(ownPaint, findsOneWidget);
    await tester.pump(const Duration(milliseconds: 300));

    // 点确实在动：动画处于播放中且相位已推进（非冻结帧）。
    final painter = tester.widget<CustomPaint>(ownPaint).painter as dynamic;
    expect(painter.animation.isAnimating, isTrue);
    final phase1 = painter.animation.value as double;
    await tester.pump(const Duration(milliseconds: 600));

    expect((painter.animation.value as double), isNot(phase1));
    expect(tester.takeException(), isNull);
    expect(ownPaint, findsOneWidget);
  });

  testWidgets('duration 变更不抛异常（控制器时长同步）', (tester) async {
    Widget build(Duration d) => _wrap(PiggySpinner(size: 20, duration: d));

    await tester.pumpWidget(build(const Duration(milliseconds: 1200)));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pumpWidget(build(const Duration(milliseconds: 400)));
    await tester.pump(const Duration(milliseconds: 100));

    expect(tester.takeException(), isNull);
  });

  testWidgets('卸载时释放动画控制器（dispose 不抛异常）', (tester) async {
    await tester.pumpWidget(_wrap(const PiggySpinner(size: 20)));
    await tester.pump(const Duration(milliseconds: 100));

    await tester.pumpWidget(_wrap(const SizedBox.shrink()));

    expect(tester.takeException(), isNull);
  });
}
