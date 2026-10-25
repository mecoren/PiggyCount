// 云同步页「配置读取失败」回归。
//
// 背景：`activeCloudConfigProvider` 在安全存储读失败时**原样上抛**（AsyncError
// 且没有历史值），页面用 `cloudConfig.value!` 判定后端类型。Riverpod 3 的
// `AsyncValue.value` 是可空的（无数据时为 null），空断言在 build 期直接抛
// 「Null check operator used on a null value」：整个内容区被 ErrorWidget 顶成
// 红屏，连「云端配置读取失败，请重新配置」的 banner 一起没了。
//
// 这里把 provider 按失败态注入（不需要真实数据库：同步服务已降级为
// LocalOnlySyncService），断言页面仍完整渲染、banner 给出直达云服务配置页的
// 入口，且云相关入口降级为不可用。
library;

import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudServiceConfig, NoopAuthService;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/cloud/cloud_sync_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Future<void> pumpWithBrokenConfig(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      currentLedgerIdProvider.overrideWith((ref) => 1),
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
      authServiceProvider.overrideWith((ref) => NoopAuthService()),
      // 读取失败：无历史值、纯 AsyncError —— 正是空断言炸掉的形态
      activeCloudConfigProvider.overrideWith((ref) =>
          Future<CloudServiceConfig>.error(StateError('cloud config broken'))),
      cloudConfigCorruptionProvider.overrideWith(
          (ref) => (backend: 'secure_storage', message: 'cloud config broken')),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const CloudSyncPage(),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('配置读取失败：内容区不塌成红屏，banner 提供重新配置入口', (tester) async {
    await pumpWithBrokenConfig(tester);

    // 曾经的真实故障：空断言把整个内容区换成 ErrorWidget
    expect(tester.takeException(), isNull);
    expect(find.text('云端配置读取失败，自动同步已暂停。请重新配置云服务。'), findsOneWidget);

    // banner 整条可点 → 云服务配置页（文案说「重新配置」就得有路可走）
    final action = find.text('去重新配置');
    expect(action, findsOneWidget);
    expect(
      find.ancestor(of: action, matching: find.byType(ListTile)),
      findsOneWidget,
    );

    // 配置不可用时云相关入口整体降级：全量覆盖 / 同步健康卡不再渲染
    expect(find.text('全量上传'), findsNothing);
    expect(find.text('同步健康'), findsNothing);
  });
}
