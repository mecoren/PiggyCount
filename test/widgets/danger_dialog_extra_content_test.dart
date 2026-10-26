// 危险确认弹窗的附加区块契约：
// - `messageWidget` 必须原样渲染在说明正文下方（测试数据工具用它逐行展示运行环境）；
// - 传了附加区块也不能破坏按钮区与倒计时逻辑（确认键仍可点、仍能返回 true）。
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/widgets/ui/dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpHost(
    WidgetTester tester,
    Future<void> Function(BuildContext context) onPressed,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Builder(
          builder: (context) => Scaffold(
            body: ElevatedButton(
              onPressed: () => onPressed(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('附加区块渲染在正文下方，确认后返回 true', (tester) async {
    bool? result;
    await pumpHost(tester, (context) async {
      result = await showDangerConfirmDialog(
        context,
        title: '清理测试数据？',
        message: '说明正文',
        countdownSeconds: 0,
        messageWidget: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('run-env'),
            Text('flavor=dev'),
          ],
        ),
      );
    });

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('说明正文'), findsOneWidget);
    expect(find.text('run-env'), findsOneWidget);
    expect(find.text('flavor=dev'), findsOneWidget);

    // 附加区块不能把确认键挤掉。
    final confirm = find.byType(TextButton).last;
    await tester.tap(confirm);
    await tester.pumpAndSettle();

    expect(result, isTrue);
    expect(find.text('run-env'), findsNothing);
  });
}
