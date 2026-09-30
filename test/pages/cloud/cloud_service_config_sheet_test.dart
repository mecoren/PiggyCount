import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/cloud/cloud_service_page.dart';
import 'package:piggycount/providers/sync_providers.dart';

/// 云服务配置抽屉回归测试。
///
/// 背景：配置弹窗抽屉化时外壳用了 transparent 底的普通 Container，
/// 里面的 TextField 找不到 Material 祖先，真机直接红屏
/// （No Material widget found）。本测试走真实页面点开 WebDAV 配置
/// 抽屉，断言 4 个输入框正常渲染且 pump 全程无异常。
void main() {
  const webdavCfg = CloudServiceConfig(
    type: CloudBackendType.webdav,
    name: 'WebDAV',
    webdavUrl: 'https://dav.example.com',
    webdavUsername: 'user',
    webdavPassword: 'pass',
    webdavRemotePath: '/piggycount',
  );

  Widget host() {
    return ProviderScope(
      overrides: [
        activeCloudConfigProvider.overrideWith((ref) async => webdavCfg),
        supabaseConfigProvider.overrideWith((ref) async => null),
        webdavConfigProvider.overrideWith((ref) async => webdavCfg),
        s3ConfigProvider.overrideWith((ref) async => null),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('zh'),
        home: CloudServicePage(),
      ),
    );
  }

  setUp(() {
    // _autoTestActiveConnection 读 SharedPreferences，先给 mock 初值
    //（multi_device_sync 缺省 false，直接跳过自动测试，无网络请求）。
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('点配置打开 WebDAV 抽屉：输入框正常渲染且无 Material 缺失异常', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    // 首帧时激活配置 future 尚未落定，初始 tab 为离线模式，手动切到备份同步。
    await tester.tap(find.text('备份同步'));
    await tester.pumpAndSettle();

    // 已配置的 WebDAV 卡片带唯一的「配置」按钮（S3 未配置，无此按钮）。
    final configureBtn = find.text('配置');
    expect(configureBtn, findsOneWidget);
    await tester.tap(configureBtn);
    await tester.pumpAndSettle();

    // 抽屉标题 + 4 个输入框（地址/用户名/密码/远程路径）。
    expect(find.text('配置 WebDAV'), findsOneWidget);
    expect(find.byType(TextField), findsNWidgets(4));
    // 底部双等宽操作按钮：取消（描边）+ 保存（填充），与加密「设置密码」
    // 等表单抽屉统一口径（历史断言：曾短暂改为标题栏两端图标，再统一回
    // 底部按钮行，故这里不再断言 Tooltip / IconButton）。
    expect(find.widgetWithText(OutlinedButton, '取消'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '保存'), findsOneWidget);

    // 构建期抛出的 FlutterError（如缺 Material 祖先）会沉淀在这里。
    expect(tester.takeException(), isNull);
  });
}
