/// 主题层「组件圆角」守门（AGENTS.md「Material 组件的圆角禁止吃框架默认值」）。
///
/// 为什么值得钉住：`FloatingActionButton` 在 M3 下的 16 是 **Flutter SDK 硬编码
/// 默认值**（`RoundedRectangleBorder(radius 16)`），而 `PiggyDimens.radiusXl`
/// 恰好也是 16 —— 数值相同、但一处 token 都没引用。于是会出现「改 token 或升
/// Flutter 后圆角静默漂移，而没有任何测试变红」的假一致。本测试把亮 / 暗两套
/// 主题的 FAB 形状钉成 `radiusXl`：要么显式走 token，要么红。
///
/// 亮 / 暗都必须断言：两套主题分叉过一次（dark 的 foregroundColor 就与 light
/// 不同），只测一侧会漏掉另一侧。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/theme.dart';

void main() {
  // 任意主题色即可：形状与 primary 无关。
  const primary = Color(0xFF4A90E2);

  final fabShape = RoundedRectangleBorder(
    borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
  );

  test('亮 / 暗主题的 FAB 圆角都显式声明为 PiggyDimens.radiusXl', () {
    // 真实入口：main.dart `_buildLightTheme` 直通 base（`floatingActionButtonTheme:
    // base.floatingActionButtonTheme`）透传，所以这里等价于 App 上看到的形状。
    expect(
      PiggyTheme.lightTheme(primary: primary).floatingActionButtonTheme.shape,
      fabShape,
      reason: '亮色主题的 FAB 圆角必须走 token，不能吃 SDK 默认值',
    );
    expect(
      PiggyTheme.darkTheme(primary: primary).floatingActionButtonTheme.shape,
      fabShape,
      reason: '暗色主题必须与亮色同值（两套主题不得分叉）',
    );
  });

  testWidgets('FAB 实际渲染出的形状 = radiusXl', (tester) async {
    for (final entry in <String, ThemeData>{
      '亮色': PiggyTheme.lightTheme(primary: primary),
      '暗色': PiggyTheme.darkTheme(primary: primary),
    }.entries) {
      await tester.pumpWidget(
        MaterialApp(
          theme: entry.value,
          home: Scaffold(
            floatingActionButton: FloatingActionButton(
              onPressed: () {},
              child: const Icon(Icons.add_rounded),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final material = tester.widget<Material>(
        find
            .descendant(
              of: find.byType(FloatingActionButton),
              matching: find.byType(Material),
            )
            .first,
      );
      expect(material.shape, fabShape, reason: '${entry.key}主题');
    }
  });
}
