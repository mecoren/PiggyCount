// 云服务页「配置读取失败」回归。
//
// 背景：`activeCloudConfigProvider` 读失败（安全存储/系统存储故障）时，旧实现
// 只在页面正中打一行 `错误: Invalid argument: Instance of 'JObject'` —— 平台
// 内部错误串既看不懂，也没有任何出口（重试不了、退不回离线模式）。
//
// 现在该分支必须给出：可读的说明 + 重试 + 先使用离线模式 + 默认收起的错误详情，
// 以及「清空本机偏好设置后自愈」这条唯一能在坏数据下自救的通道。
library;

import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudServiceConfig;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_platform_interface/types.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/cloud/cloud_service_page.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/services/system/logger_service.dart';

/// 坏掉的偏好存储：`getAll` 抛平台侧那类 `ArgumentError`（真实故障形态），
/// 只有从平台层 `clear()` 之后才恢复可读 —— 正是「清空本机设置并修复」要验证的。
class _PoisonedPrefsStore extends SharedPreferencesStorePlatform {
  bool cleared = false;
  final Map<String, Object> data = <String, Object>{};

  @override
  Future<Map<String, Object>> getAll() async {
    if (!cleared) throw ArgumentError("Instance of 'JObject'");
    return Map<String, Object>.from(data);
  }

  @override
  Future<Map<String, Object>> getAllWithParameters(
      GetAllParameters parameters) async {
    return getAll();
  }

  @override
  Future<bool> clear() async {
    cleared = true;
    data.clear();
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    data.remove(key);
    return true;
  }

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    data[key] = value;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  // 错误态会把原始异常写入日志（写盘有 2s 节流 Timer），
  // 不在收尾清掉会触发「A Timer is still pending」
  tearDown(() => LoggerService().resetForTesting());

  final broken = ArgumentError("Instance of 'JObject'");

  /// [brokenActiveConfig] 为 false 时走真实 `activeCloudConfigProvider`
  ///（自愈用例需要真实链路：读失败 → 清空 → 重读成功）。
  Future<void> pumpPage(
    WidgetTester tester, {
    bool brokenActiveConfig = true,
  }) async {
    final container = ProviderContainer(overrides: [
      // 各后端配置读取同样依赖平台存储：测试里直接给 null，避免碰插件通道
      supabaseConfigProvider.overrideWith((ref) async => null),
      webdavConfigProvider.overrideWith((ref) async => null),
      s3ConfigProvider.overrideWith((ref) async => null),
      if (brokenActiveConfig)
        // 读取失败：无历史值的纯 AsyncError
        activeCloudConfigProvider
            .overrideWith((ref) => Future<CloudServiceConfig>.error(broken)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const CloudServicePage(),
      ),
    ));
    await tester.pumpAndSettle();
    // 真实链路下 `loadActive()` 的失败要在下一帧才反映到 UI（
    // 且 loading 分支的 DelayedSkeleton 有自己的延时），补一帧再断言
    await tester.pump(const Duration(milliseconds: 700));
  }

  Future<void> pumpWithBrokenConfig(WidgetTester tester) => pumpPage(tester);

  testWidgets('配置读取失败：给出说明、重试、离线兜底与错误详情', (tester) async {
    await pumpWithBrokenConfig(tester);

    // 不再把平台异常原样当正文
    expect(tester.takeException(), isNull);
    expect(find.text('无法读取云服务配置'), findsOneWidget);
    expect(find.textContaining("Instance of 'JObject'"), findsNothing,
        reason: '原始异常默认收起，不能直接怼在页面上');

    expect(find.text('重试'), findsOneWidget);
    expect(find.text('先使用离线模式'), findsOneWidget);
    expect(find.text('清除本机设置并修复'), findsOneWidget);

    // 错误详情默认折叠，点开后可见原始异常
    await tester.tap(find.text('查看错误详情'));
    await tester.pumpAndSettle();
    expect(find.textContaining("Instance of 'JObject'"), findsOneWidget);

    // 收尾：错误态写日志留下 2s 节流 Timer，必须在测试体内清掉
    LoggerService().resetForTesting();
  });

  testWidgets('重试后仍失败：保持在可操作错误态（不白屏、不红屏）', (tester) async {
    await pumpWithBrokenConfig(tester);
    await tester.tap(find.text('重试'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('无法读取云服务配置'), findsOneWidget);
    expect(find.text('重试'), findsOneWidget);

    LoggerService().resetForTesting();
  });

  // 走真实链路（不覆盖 activeCloudConfigProvider）：偏好存储整体不可读 →
  // 清空 → 重读成功 → 页面回到离线态。这是坏数据下唯一能自救的路径。
  testWidgets('清除本机设置后自愈：偏好存储恢复可读，页面回到离线态', (tester) async {
    final store = _PoisonedPrefsStore();
    SharedPreferencesStorePlatform.instance = store;
    SharedPreferences.resetStatic();
    addTearDown(() => SharedPreferences.setMockInitialValues({}));

    await pumpPage(tester, brokenActiveConfig: false);
    expect(tester.takeException(), isNull);
    expect(find.text('无法读取云服务配置'), findsOneWidget);
    expect(store.cleared, isFalse);

    // 第一次确认
    await tester.tap(find.text('清除本机设置并修复'));
    await tester.pumpAndSettle();
    expect(find.text('清除本机设置'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3)); // 倒计时归零
    await tester.pump();
    await tester.tap(find.text('清除本机设置并修复').last);
    await tester.pumpAndSettle();

    // 第二次确认
    await tester.pump(const Duration(seconds: 3));
    await tester.pump();
    await tester.tap(find.text('清除本机设置并修复').last);
    await tester.pumpAndSettle();

    expect(store.cleared, isTrue, reason: '必须真的从平台层清掉坏数据');
    expect(tester.takeException(), isNull);
    expect(find.text('无法读取云服务配置'), findsNothing, reason: '清空后重读应恢复，不能继续停在错误态');
    // 回到离线模式（默认 local）的可见证据
    expect(find.text('离线模式'), findsWidgets);

    LoggerService().resetForTesting();
  });
}
