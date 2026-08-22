import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/widgets/encryption/password_setup_dialog.dart';

void main() {
  testWidgets('change模式 400x520 小屏：无溢出且确认密码框可达', (tester) async {
    tester.view.physicalSize = const Size(400, 520);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MediaQuery(
      // 模拟小屏+键盘弹起（审计 U3 真实场景）
      data: const MediaQueryData(viewInsets: EdgeInsets.only(bottom: 320)),
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Builder(builder: (ctx) => Scaffold(body: Center(child: FilledButton(
          onPressed: () => PasswordSetupDialog.showForResult(
              ctx, mode: PasswordDialogMode.change),
          child: const Text('open'),
        )))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(TextField), findsNWidgets(3),
        reason: '旧密码/新密码/确认密码');
    await tester.ensureVisible(find.byType(TextField).at(2));
    expect(tester.takeException(), isNull,
        reason: '不允许 RenderFlex overflow');
  });
}
