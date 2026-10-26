// 「已应用条件」可移除 chip（PiggyClosableChip）的视觉契约守门。
//
// 背景：洞察页筛选行与搜索页的已选条件曾用 Material 的 `InputChip` / `Chip`，
// 吃的是 M3 默认值（8 号圆角、`surface` 底色 + 中性描边、字号 14、`error` 红叉），
// 与同排的「筛选 / 筛选已启用」描边胶囊、以及筛选抽屉里的 PiggySelectChip /
// 分段控件完全是两套语言（截图里就是「蓝描边胶囊 + 白底灰边红叉胶囊」并排）。
// 统一抽成 PiggyClosableChip 后，这里把四件事钉死：
// - 圆角 / 高度与同排按钮齐平（radiusLg、32）
// - 浅主色底 + 主色描边 + 主色文字（与可选格选中态同源，不再有红色叉）
// - 字号 12 / w600
// - 只有叉可点（移除本条件），点文字不触发
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/closable_chip.dart';
import 'package:piggycount/widgets/ui/segmented_control.dart';

Widget _host(Widget child, {TextScaler textScaler = TextScaler.noScaling}) =>
    MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: textScaler),
        child: Scaffold(
          body: Center(
            child: Wrap(spacing: PiggyDimens.p8, children: [child]),
          ),
        ),
      ),
    );

Material _materialOf(WidgetTester tester) => tester.widget<Material>(
      find
          .descendant(
            of: find.byType(PiggyClosableChip),
            matching: find.byType(Material),
          )
          .first,
    );

void main() {
  testWidgets('视觉与项目 token 同源：浅主色底 + 主色描边 + radiusLg', (tester) async {
    await tester.pumpWidget(
        _host(PiggyClosableChip(label: '收入', onDeleted: () {})));

    final context = tester.element(find.byType(PiggyClosableChip));
    final primary = PiggyTokens.primary(context);
    final shape = _materialOf(tester).shape! as RoundedRectangleBorder;
    final material = _materialOf(tester);

    expect(material.color, primary.withValues(alpha: kPiggySelectableFillAlpha));
    expect(shape.side.color, primary);
    expect(shape.side.width, 1);
    expect(
      shape.borderRadius,
      BorderRadius.circular(PiggyDimens.radiusLg),
    );

    final text = tester.widget<Text>(find.text('收入'));
    expect(text.style!.color, primary);
    expect(text.style!.fontSize, PiggyTextTokens.fs12);
    expect(text.style!.fontWeight, FontWeight.w600);
    // 超长自定义字段值不换行，靠省略号收住（见 maxWidth 默认值）。
    expect(text.maxLines, 1);
    expect(text.overflow, TextOverflow.ellipsis);
  });

  testWidgets('高度 32：与同排 compact OutlinedButton 齐平', (tester) async {
    await tester.pumpWidget(
        _host(PiggyClosableChip(label: '收入', onDeleted: () {})));

    expect(tester.getSize(find.byType(PiggyClosableChip)).height, 32);
    // 不能再退回 Material 的 Chip 家族（它们自带 M3 高度、留白与配色）。
    expect(find.byType(Chip), findsNothing);
    expect(find.byType(InputChip), findsNothing);
  });

  testWidgets('删除叉是主色 14 号（不是 error 红）', (tester) async {
    await tester.pumpWidget(
        _host(PiggyClosableChip(label: '收入', onDeleted: () {})));

    final context = tester.element(find.byType(PiggyClosableChip));
    final icon = tester.widget<Icon>(find.byIcon(Icons.close));
    expect(icon.size, 14);
    expect(icon.color, PiggyTokens.primary(context));
    expect(icon.color, isNot(PiggyTokens.error(context)));
  });

  testWidgets('只有叉可点：移除本条件，点文字不触发', (tester) async {
    var deleted = 0;
    await tester.pumpWidget(
        _host(PiggyClosableChip(label: '收入', onDeleted: () => deleted++)));

    await tester.tap(find.text('收入'));
    await tester.pumpAndSettle();
    expect(deleted, 0);

    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(deleted, 1);
  });

  testWidgets('系统字号放大时按需长高，不裁字', (tester) async {
    await tester.pumpWidget(_host(
      PiggyClosableChip(label: '收入', onDeleted: () {}),
      textScaler: const TextScaler.linear(2),
    ));

    // 高度是 minHeight，不是固定高度：2 倍字号下允许长高（无障碍 U2）。
    expect(
      tester.getSize(find.byType(PiggyClosableChip)).height,
      greaterThanOrEqualTo(32),
    );
    expect(tester.takeException(), isNull);
  });
}
