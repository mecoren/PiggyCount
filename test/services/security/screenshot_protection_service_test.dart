import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/services/security/screenshot_protection_service.dart';
import 'package:piggycount/utils/platform_info.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('com.wait.piggycount/security');
  final calls = <MethodCall>[];

  void mockNative({bool throwError = false}) {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (throwError) throw PlatformException(code: 'boom');
      return true;
    });
  }

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    calls.clear();
    mockNative();
  });

  tearDown(() {
    PlatformInfo.debugOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('未设置过时默认开启保护', () async {
    expect(await ScreenshotProtectionService.isEnabled(), isTrue);
  });

  test('关闭后落库，重启读取仍为关闭', () async {
    PlatformInfo.debugOverride = PlatformFamily.android;

    await ScreenshotProtectionService.setEnabled(false);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool(ScreenshotProtectionService.keyEnabled), isFalse);
    expect(await ScreenshotProtectionService.isEnabled(), isFalse);
  });

  test('Android 上切换会下发原生调用且带 enabled 参数', () async {
    PlatformInfo.debugOverride = PlatformFamily.android;

    await ScreenshotProtectionService.setEnabled(false);

    expect(calls, hasLength(1));
    expect(calls.single.method, 'setScreenshotProtection');
    expect(calls.single.arguments, {'enabled': false});
  });

  test('非 Android 只落库、不下发原生调用', () async {
    PlatformInfo.debugOverride = PlatformFamily.ios;

    await ScreenshotProtectionService.setEnabled(false);

    expect(calls, isEmpty);
    expect(await ScreenshotProtectionService.isEnabled(), isFalse);
  });

  test('原生通道异常只记日志，不向调用方抛出', () async {
    PlatformInfo.debugOverride = PlatformFamily.android;
    mockNative(throwError: true);

    await expectLater(
      ScreenshotProtectionService.setEnabled(false),
      completes,
    );
  });
}
