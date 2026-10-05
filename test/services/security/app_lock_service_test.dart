import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/services/security/app_lock_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AppLockService.testSecureStore = {};
  });

  tearDown(() {
    AppLockService.testSecureStore = null;
  });

  test('设置 PIN 后哈希进安全存储，prefs 无明文残留', () async {
    await AppLockService.setPin('1234');

    expect(AppLockService.testSecureStore!['app_lock_pin_hash'], isNotNull);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('app_lock_pin_hash'), isNull);
    expect(await AppLockService.hasPin(), isTrue);
  });

  test('正确 PIN 通过并清零失败计数', () async {
    await AppLockService.setPin('1234');
    expect(await AppLockService.verifyPin('1234'), isTrue);
    expect(await AppLockService.getFailedAttempts(), 0);
    expect(await AppLockService.isLockedOut(), isFalse);
  });

  test('旧明文 PIN 读时迁移到安全存储', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('app_lock_pin_hash', 'legacy-hash');
    // 直接读 hasPin 触发迁移路径（verify 会因格式不对失败，但迁移已发生）
    await AppLockService.hasPin();
    expect(AppLockService.testSecureStore!['app_lock_pin_hash'], 'legacy-hash');
    expect(prefs.getString('app_lock_pin_hash'), isNull);
  });

  test('5 次失败后锁定 30 秒，成功后解锁', () async {
    await AppLockService.setPin('1234');
    final prefs = await SharedPreferences.getInstance();
    // 预置 4 次失败，下一次错误即达阈值，仅需 1 次 Argon2 运算
    await prefs.setInt('app_lock_failed_count', 4);

    expect(await AppLockService.verifyPin('0000'), isFalse);
    expect(await AppLockService.getFailedAttempts(), 5);
    expect(await AppLockService.isLockedOut(), isTrue);
    final remaining = await AppLockService.getLockoutRemaining();
    expect(remaining.inSeconds, greaterThan(0));
    expect(remaining.inSeconds, lessThanOrEqualTo(30));

    // 锁定期内正确 PIN 也被拒绝
    expect(await AppLockService.verifyPin('1234'), isFalse);

    // 模拟锁定期结束，正确 PIN 通过并清零
    await prefs.setInt(
      'app_lock_lockout_until_ms',
      DateTime.now().millisecondsSinceEpoch - 1,
    );
    expect(await AppLockService.isLockedOut(), isFalse);
    expect(await AppLockService.verifyPin('1234'), isTrue);
    expect(await AppLockService.getFailedAttempts(), 0);
  });

  test('10 次失败后锁定 5 分钟', () async {
    await AppLockService.setPin('1234');
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_lock_failed_count', 9);

    expect(await AppLockService.verifyPin('0000'), isFalse);
    expect(await AppLockService.getFailedAttempts(), 10);
    final remaining = await AppLockService.getLockoutRemaining();
    expect(remaining.inMinutes, greaterThanOrEqualTo(4));
  });

  test('清除 PIN 同时清理安全存储与失败计数', () async {
    await AppLockService.setPin('1234');
    await AppLockService.clearPin();
    expect(AppLockService.testSecureStore!.containsKey('app_lock_pin_hash'),
        isFalse);
    expect(await AppLockService.hasPin(), isFalse);
    expect(await AppLockService.isLockedOut(), isFalse);
  });

  test('wipe 开关默认关闭，未达 20 次不触发', () async {
    expect(await AppLockService.isWipeEnabled(), isFalse);
    expect(await AppLockService.shouldWipe(), isFalse);

    await AppLockService.setWipeEnabled(true);
    expect(await AppLockService.isWipeEnabled(), isTrue);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_lock_failed_count', 19);
    expect(await AppLockService.shouldWipe(), isFalse);
  });

  test('开关开且失败达 20 次触发 wipe，关闭则不触发', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('app_lock_failed_count', 20);

    expect(await AppLockService.shouldWipe(), isFalse);

    await AppLockService.setWipeEnabled(true);
    expect(await AppLockService.shouldWipe(), isTrue);
  });

  test('wipeAllData 删除库文件/附件/prefs/安全存储', () async {
    final tempDir = await Directory.systemTemp.createTemp('wipe_test');
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
    try {
      for (final name in [
        'piggycount.sqlite',
        'piggycount.sqlite-wal',
        'piggycount.sqlite-shm',
      ]) {
        await File('${tempDir.path}/$name').writeAsString('data');
      }
      final attFile = File('${tempDir.path}/attachments/a.bin');
      await attFile.create(recursive: true);
      await attFile.writeAsBytes([1, 2, 3]);

      await AppLockService.setPin('1234');
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('some_key', 'some_value');

      expect(await AppLockService.wipeAllData(), isTrue);
      expect(await File('${tempDir.path}/piggycount.sqlite').exists(), isFalse);
      expect(await File('${tempDir.path}/piggycount.sqlite-wal').exists(),
          isFalse);
      expect(await Directory('${tempDir.path}/attachments').exists(), isFalse);
      expect(prefs.getString('some_key'), isNull);
      expect(AppLockService.testSecureStore, isEmpty);
      expect(await AppLockService.hasPin(), isFalse);
    } finally {
      await tempDir.delete(recursive: true);
    }
  });
}

class _FakePathProvider extends PathProviderPlatform {
  final String documentsPath;
  _FakePathProvider(this.documentsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
