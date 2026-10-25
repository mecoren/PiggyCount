// 可点选芯片（PiggySelectChip）的视觉契约守门。
//
// 背景：洞察筛选抽屉的「交易类型」与自定义字段选项曾用 Material 的
// `FilterChip` / `ChoiceChip`，吃的是 M3 默认值（高度 ~32、自带留白 / 勾选图标、
// 未选中灰底），与同一个抽屉里的 PiggyValueRow / PiggySegmentedControl 是两套
// 体系。统一抽成 PiggySelectChip 后，这里把「必须与分段控件同源」钉死：
// - 选中 = 主色描边 1.5 + 12% 主色底，未选 = 中性描边 1 + 无填充
// - 文字色选中 = 主色、未选 = 次要文字
// - 高度与分段控件一致（40），不被内容压缩
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/select_chip.dart';
import 'package:piggycount/widgets/ui/segmented_control.dart';

Widget _host(Widget child) => MaterialApp(
      home: Scaffold(
        body: Center(
          child: Wrap(spacing: PiggyDimens.p8, children: [child]),
        ),
      ),
    );

BoxDecoration _decorationOf(WidgetTester tester) {
  final container =
      tester.widget<AnimatedContainer>(find.byType(AnimatedContainer));
  return container.decoration! as BoxDecoration;
}

void main() {
  testWidgets('选中态与分段控件的选格同源（主色描边 1.5 + 12% 主色底）', (tester) async {
    await tester.pumpWidget(_host(PiggySelectChip(
      label: '支出',
      selected: true,
      onTap: () {},
    )));

    final context = tester.element(find.byType(PiggySelectChip));
    final expected = piggySelectableDecoration(context, selected: true);
    final actual = _decorationOf(tester);

    expect(actual.color, expected.color);
    expect(actual.border, expected.border);
    expect(actual.borderRadius, expected.borderRadius);

    final text = tester.widget<Text>(find.text('支出'));
    expect(
        text.style!.color, piggySelectableTextColor(context, selected: true));
    expect(text.style!.fontSize, PiggyTextTokens.fs13);
  });

  testWidgets('未选中态：无填充 + 中性描边 + 次要文字', (tester) async {
    await tester.pumpWidget(_host(PiggySelectChip(
      label: '收入',
      selected: false,
      onTap: () {},
    )));

    final context = tester.element(find.byType(PiggySelectChip));
    final actual = _decorationOf(tester);
    final expected = piggySelectableDecoration(context, selected: false);

    expect(actual.color, expected.color);
    expect(actual.border, expected.border);
    expect(tester.widget<Text>(find.text('收入')).style!.color,
        piggySelectableTextColor(context, selected: false));
  });

  testWidgets('高度与分段控件同高（40）：抽屉里两种选格对齐同一基线', (tester) async {
    await tester.pumpWidget(_host(PiggySelectChip(
      label: '转账',
      selected: false,
      onTap: () {},
    )));

    expect(tester.getSize(find.byType(PiggySelectChip)).height, 40);
    // 不能再退回 Material 的 Chip 家族（它们自带 M3 高度与留白）。
    expect(find.byType(Chip), findsNothing);
    expect(find.byType(FilterChip), findsNothing);
  });

  testWidgets('点击回调只触发一次，且由调用方决定选中语义', (tester) async {
    var taps = 0;
    await tester.pumpWidget(_host(PiggySelectChip(
      label: '支出',
      selected: false,
      onTap: () => taps++,
    )));

    await tester.tap(find.byType(PiggySelectChip));
    await tester.pumpAndSettle();
    expect(taps, 1);
    // 组件自身不持有选中态：点完外观不变，交给父级的 setState。
    expect(_decorationOf(tester).color, isNull);
  });
}
