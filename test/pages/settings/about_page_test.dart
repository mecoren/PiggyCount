/// 关于页回归（2026-10-03）：
///   - 更新日志收进功能卡（与「日志中心」同款菜单行）；
///   - 底部 ICP 备案号与「隐私政策」入口整条移除（隐私政策页已整体下线）。
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/settings/about_page.dart';
import 'package:piggycount/widgets/biz/settings_widgets.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  // 关于页 initState 里读 PackageInfo；测试环境没有插件实现，mock 一个固定值。
  const channel = MethodChannel('dev.fluttercommunity.plus/package_info');
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            channel,
            (call) async => {
                  'appName': '小猪记账',
                  'packageName': 'com.wait.piggycount',
                  'version': '0.1.0',
                  'buildNumber': '42',
                });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Widget host() {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const AboutPage(),
      ),
    );
  }

  /// 默认 800×600 视口装不下「图标 150px + 功能卡 4 行」，ListView 懒构建会让
  /// 尾部压根不 build；撑高到手机长屏比例（顺带保证底部不再有可点区域）。
  void useTallViewport(WidgetTester tester) {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('更新日志与日志中心同为卡内菜单行（图标 + 标题 + 副标题）', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 版本号读到了 PackageInfo 的 mock（顺带证明 initState 那条异步链没炸）
    expect(find.text('dev-0.1.0 (42)'), findsOneWidget);

    for (final navFinder in [
      find.ancestor(
          of: find.text('日志中心'), matching: find.byType(SettingsNavItem)),
      find.ancestor(
          of: find.text('更新日志'), matching: find.byType(SettingsNavItem)),
    ]) {
      expect(navFinder, findsOneWidget, reason: '该入口应是卡内菜单行');
    }
    // 副标题与「日志中心」同款（图标 + 标题 + 副标题 + chevron）
    expect(find.text('查看应用运行日志'), findsOneWidget);
    expect(find.text('查看每个版本更新了什么'), findsOneWidget);
  });

  testWidgets('关于页不再出现备案号与隐私政策入口', (tester) async {
    useTallViewport(tester);
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.textContaining('ICP'), findsNothing);
    expect(find.textContaining('备'), findsNothing);
    // 隐私政策页整体下线：关于页不再有这个入口，也没有 WebView 兜底页
    expect(find.text('隐私政策'), findsNothing);
    expect(find.byType(WebViewWidget), findsNothing);
  });
}
