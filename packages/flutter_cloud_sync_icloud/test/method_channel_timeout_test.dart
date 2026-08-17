/// P3：iCloud method-channel 调用必须有超时，防原生侧挂起让同步永久卡死。
library;

import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cloud_sync_icloud/src/icloud_method_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('P3：原生不回复时 invokeWithTimeout 在指定时限内抛 TimeoutException',
      () async {
    final channel = const MethodChannel('com.piggycount.app/icloud');
    // 拦截 method call 但永不回复（模拟原生挂起）
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) {
      return Completer<ByteData?>().future;
    });

    await expectLater(
      ICloudMethodChannel.invokeWithTimeout<String>(channel, 'downloadFile', {
        'path': 'x.json',
      }, timeout: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('P3：原生正常回复时透传结果', () async {
    final channel = const MethodChannel('com.piggycount.app/icloud');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      return 'ok';
    });

    final result = await ICloudMethodChannel.invokeWithTimeout<String>(
        channel, 'downloadFile', {'path': 'x.json'},
        timeout: const Duration(seconds: 1));
    expect(result, 'ok');

    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });
}
