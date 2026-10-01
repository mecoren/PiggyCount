// AppDialogShell 回归（弹窗语言统一）：
// - 不再走 Material 默认 AlertDialog（内容左对齐 + 右下角小号文字按钮），
//   而是项目自有语言：项目卡片 + 居中标题 + 底部横线分隔的分栏动作区；
// - 窄卡片 270（PiggyDimens.alertWidth）/ 宽卡片 340（alertWidthWide）；
// - 分栏按钮与 PiggyDialogActions 同配色：末位=主题色（确认），其余=正文色；
// - 纯文案内容居中，表单 / 列表内容保持调用方版式。

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/styles/tokens.dart';
import 'package:piggycount/widgets/ui/dialog.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    );

void main() {
  testWidgets('外壳：非 AlertDialog + 居中标题 + 分栏文本按钮', (tester) async {
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(Scaffold));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogShell(
        title: const Text('重算折算'),
        content: const Text('将重算并同步 2 笔交易'),
        actions: [
          TextButton(onPressed: () {}, child: const Text('取消')),
          TextButton(onPressed: () {}, child: const Text('确定')),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 卡片形态：走项目 Dialog 而不是 AlertDialog
    expect(find.byType(AlertDialog), findsNothing);
    expect(
      tester.getSize(find.byKey(const ValueKey('piggyDialogCard'))).width,
      PiggyDimens.alertWidth,
      reason: '默认窄卡片 = 与 AppDialog 的确认框同宽',
    );

    // 标题与说明居中
    final title = tester.renderObject<RenderParagraph>(find.text('重算折算'));
    expect(title.textAlign, TextAlign.center);
    final message =
        tester.renderObject<RenderParagraph>(find.text('将重算并同步 2 笔交易'));
    expect(message.textAlign, TextAlign.center,
        reason: '纯文案内容按提醒口径居中，与 AppDialog 一致');

    // 分栏：两颗按钮左右各占一半、同一行
    final cancel = tester.getCenter(find.widgetWithText(TextButton, '取消'));
    final ok = tester.getCenter(find.widgetWithText(TextButton, '确定'));
    expect(cancel.dy, ok.dy);
    expect(cancel.dx < ok.dx, isTrue);

    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('分栏配色：末位=主题色（确认），前位=正文色（取消）', (tester) async {
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(Scaffold));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogShell(
        title: const Text('T'),
        content: const Text('M'),
        actions: [
          TextButton(onPressed: () {}, child: const Text('取消')),
          TextButton(onPressed: () {}, child: const Text('确定')),
        ],
      ),
    );
    await tester.pumpAndSettle();

    // 颜色由分栏的 TextButtonTheme 提供，取渲染后的文字样式
    final cancelColor =
        tester.renderObject<RenderParagraph>(find.text('取消')).text.style?.color;
    final okColor =
        tester.renderObject<RenderParagraph>(find.text('确定')).text.style?.color;
    expect(cancelColor, PiggyTokens.textPrimary(ctx));
    expect(okColor, PiggyTokens.primary(ctx));
  });

  testWidgets('wide：表单弹窗用宽卡片（340）', (tester) async {
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(Scaffold));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogShell(
        wide: true,
        title: const Text('T'),
        content: const TextField(),
        actions: [TextButton(onPressed: () {}, child: const Text('确定'))],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.getSize(find.byKey(const ValueKey('piggyDialogCard'))).width,
        PiggyDimens.alertWidthWide);
    expect(find.byType(TextField), findsOneWidget);
  });

  testWidgets('长文案 + 3 个动作不溢出（内容区滚动、动作区换行）', (tester) async {
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(Scaffold));

    showDialog<void>(
      context: ctx,
      builder: (_) => AppDialogShell(
        title: const Text('冲突处理'),
        content: Text('云端与本地都有改动，' * 30),
        actions: [
          TextButton(onPressed: () {}, child: const Text('取消')),
          TextButton(onPressed: () {}, child: const Text('以云端覆盖')),
          TextButton(onPressed: () {}, child: const Text('以本地覆盖')),
        ],
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.text('以本地覆盖'), findsOneWidget);
  });

  testWidgets('PiggyDialogActionsBar：自绘弹窗复用同一套收尾（末位=确认）',
      (tester) async {
    await tester.pumpWidget(_wrap(const SizedBox.shrink()));
    final ctx = tester.element(find.byType(Scaffold));

    showDialog<void>(
      context: ctx,
      builder: (dialogCtx) => Dialog(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(padding: EdgeInsets.all(20), child: Text('自绘内容')),
            PiggyDialogActionsBar(
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('分享'),
                ),
                TextButton(
                  onPressed: () => Navigator.pop(dialogCtx),
                  child: const Text('保存'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
    await tester.pumpAndSettle();

    // 分栏结构：同一行、左右各半
    final share = tester.getCenter(find.widgetWithText(TextButton, '分享'));
    final save = tester.getCenter(find.widgetWithText(TextButton, '保存'));
    expect(share.dy, save.dy);
    expect(share.dx < save.dx, isTrue);

    // 配色口径与 PiggyDialogActions 一致：末位主题色、前位正文色
    final styleCtx = tester.element(find.byType(Scaffold));
    expect(
      tester.renderObject<RenderParagraph>(find.text('保存')).text.style?.color,
      PiggyTokens.primary(styleCtx),
    );
    expect(
      tester.renderObject<RenderParagraph>(find.text('分享')).text.style?.color,
      PiggyTokens.textPrimary(styleCtx),
    );

    await tester.tap(find.text('分享'));
    await tester.pumpAndSettle();
    expect(find.text('自绘内容'), findsNothing);
  });
}
