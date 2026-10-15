// 表单输入框装饰（piggyOutlinedDecoration）契约 —— 浅灰填充 + 细描边 + 浮动
// 标签：待机 1px 中性描边、聚焦主题色 1.6、错误 error 1 / 1.6、圆角 14（与底部
// 按钮行同档）、水平内边距 p16。改样式时同步改本测试与 `AGENTS.md` 输入框口径。

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/piggy_input.dart';

OutlineInputBorder _borderOf(InputBorder? border) =>
    border! as OutlineInputBorder;

void main() {
  /// 真实路径渲染：TextField 经装饰器产出，顺带拿到应用后的 decoration。
  Future<void> pumpField(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextField(
              decoration: piggyOutlinedDecoration(context, label: '服务器地址'),
            ),
          ),
        ),
      ),
    );
  }

  InputDecoration decorationOf(WidgetTester tester) =>
      tester.widget<InputDecorator>(find.byType(InputDecorator)).decoration;

  testWidgets('浅灰填充 + 圆角 14 + 待机 1px 中性描边 + 内边距 16/14', (tester) async {
    await pumpField(tester);
    final context = tester.element(find.byType(TextField));
    final d = decorationOf(tester);
    expect(d.labelText, '服务器地址');
    expect(d.filled, isTrue);
    expect(d.fillColor, PiggyTokens.surfaceSecondary(context));
    expect(
      d.contentPadding,
      const EdgeInsets.symmetric(horizontal: PiggyDimens.p16, vertical: 14),
    );
    expect(
      _borderOf(d.border).borderRadius,
      BorderRadius.circular(14),
      reason: '圆角必须与底部按钮行同档（14）',
    );
    expect(_borderOf(d.border).borderSide, BorderSide.none);
    expect(
      _borderOf(d.enabledBorder).borderSide,
      BorderSide(color: PiggyTokens.borderStrong(context), width: 1),
    );
  });

  testWidgets('聚焦主题色 1.6 / 错误 error 色 1 与 1.6', (tester) async {
    await pumpField(tester);
    final context = tester.element(find.byType(TextField));
    final d = decorationOf(tester);
    expect(
      _borderOf(d.focusedBorder).borderSide,
      BorderSide(color: PiggyTokens.primary(context), width: 1.6),
    );
    expect(
      _borderOf(d.errorBorder).borderSide,
      BorderSide(color: PiggyTokens.error(context), width: 1),
    );
    expect(
      _borderOf(d.focusedErrorBorder).borderSide,
      BorderSide(color: PiggyTokens.error(context), width: 1.6),
    );
  });
}
