/// P1：secure storage 写失败时必须硬失败，凭据绝不明文落 SharedPreferences。
///
/// SEC-03（2026-09-09）：明文迁移失败必须留下结构化痕迹（凭据仍残留
/// 明文 SharedPreferences，仅 debugPrint 用户不可见）——
/// lastMigrationErrorKey/Message 供 App 层 banner 呈现。
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// 模拟 keystore 损坏：write 永远抛异常、read 返回 null。
class _BrokenSecureStorage extends FlutterSecureStorage {
  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw Exception('keystore broken');
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      null;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('P1：secure 写失败 → saveOnly 抛 CloudStorageException 且 prefs 无明文',
      () async {
    final store = CloudServiceStore(secureStorage: _BrokenSecureStorage());
    const cfg = CloudServiceConfig(
      type: CloudBackendType.webdav,
      name: 'w',
      webdavUrl: 'https://dav.example.com',
      webdavUsername: 'u',
      webdavPassword: 'p',
    );

    await expectLater(
        store.saveOnly(cfg), throwsA(isA<CloudStorageException>()));
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('cloud_webdav_cfg'), isNull,
        reason: 'P1：凭据不得明文降级落盘 SharedPreferences');
  });

  test('P1：secure 写失败 → saveAndActivate 同样硬失败', () async {
    final store = CloudServiceStore(secureStorage: _BrokenSecureStorage());
    const cfg = CloudServiceConfig(
      type: CloudBackendType.webdav,
      name: 'w',
      webdavUrl: 'https://dav.example.com',
      webdavUsername: 'u',
      webdavPassword: 'p',
    );

    await expectLater(
        store.saveAndActivate(cfg), throwsA(isA<CloudStorageException>()));
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('cloud_webdav_cfg'), isNull);
  });

  test('P1：secure 写成功时仍清除历史明文残留', () async {
    // 预置一份旧明文（模拟老版本升级用户）
    SharedPreferences.setMockInitialValues({
      'cloud_webdav_cfg': '{"type":"webdav","name":"old","url":"https://old"}',
    });
    final store = CloudServiceStore(secureStorage: _NoopSecureStorage());
    const cfg = CloudServiceConfig(
      type: CloudBackendType.webdav,
      name: 'w',
      webdavUrl: 'https://dav.example.com',
      webdavUsername: 'u',
      webdavPassword: 'p',
    );

    await store.saveOnly(cfg);
    final sp = await SharedPreferences.getInstance();
    expect(sp.getString('cloud_webdav_cfg'), isNull,
        reason: 'P1：secure 写成功后必须清掉旧明文');
  });

  group('M16：secure 读失败显式报错（不再静默降级）', () {
    test('读失败且无明文兜底 → loadActive 抛 CloudStorageException 并留痕',
        () async {
      SharedPreferences.setMockInitialValues({'cloud_active_type': 'webdav'});
      final store =
          CloudServiceStore(secureStorage: _BrokenReadSecureStorage());

      await expectLater(
          store.loadActive(), throwsA(isA<CloudStorageException>()));
      // 结构化痕迹：供 App 层 banner 使用（activeCloudConfigProvider catch）
      expect(CloudServiceStore.lastLoadErrorBackend, 'webdav');
      expect(CloudServiceStore.lastLoadErrorMessage, isNotNull);
    });

    test('读失败但存在旧明文 → 迁移路径照常返回可用配置（数据可用即工作）',
        () async {
      SharedPreferences.setMockInitialValues({
        'cloud_active_type': 'webdav',
        'cloud_webdav_cfg':
            '{"type":"webdav","name":"old","webdavUrl":"https://old.example.com",'
            '"webdavUsername":"u","webdavPassword":"p"}',
      });
      final store =
          CloudServiceStore(secureStorage: _BrokenReadSecureStorage());

      final cfg = await store.loadActive();
      expect(cfg.type, CloudBackendType.webdav,
          reason: 'M16：旧明文可读时不算停摆，不抛错');
    });

    test('未配置（read 正常返回 null）→ 仍回退 localStorage，不误报', () async {
      SharedPreferences.setMockInitialValues({'cloud_active_type': 'webdav'});
      final store = CloudServiceStore(secureStorage: _NoopSecureStorage());

      final cfg = await store.loadActive();
      expect(cfg.type, CloudBackendType.local,
          reason: 'M16：只对「读失败」抛错，「未配置」保持原语义');
    });

    test('读失败 → activate 返回 false（bool 契约不变）', () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          CloudServiceStore(secureStorage: _BrokenReadSecureStorage());

      final ok = await store.activate(CloudBackendType.webdav);
      expect(ok, isFalse);
    });

    test('读失败 → loadWebdav 抛 CloudStorageException（配置页显式感知）',
        () async {
      SharedPreferences.setMockInitialValues({});
      final store =
          CloudServiceStore(secureStorage: _BrokenReadSecureStorage());

      await expectLater(
          store.loadWebdav(), throwsA(isA<CloudStorageException>()));
    });
  });

  group('SEC-03：明文迁移失败凭据残留告警', () {
    tearDown(() {
      // 静态痕迹是跨测试共享的进程级状态，逐用例复位
      CloudServiceStore.clearLoadError();
      CloudServiceStore.clearMigrationError();
      SharedPreferences.setMockInitialValues({});
    });

    test('迁移失败（write 抛异常）→ 结构化痕迹记录 key 与原因，明文仍在',
        () async {
      SharedPreferences.setMockInitialValues({
        'cloud_webdav_cfg':
            '{"type":"webdav","name":"old","webdavUrl":"https://old.example.com",'
            '"webdavUsername":"u","webdavPassword":"p"}',
      });
      // read 返回 null（安全存储无该 key）+ write 抛异常（迁移失败）
      final store = CloudServiceStore(secureStorage: _BrokenSecureStorage());

      final cfg = await store.loadWebdav();
      expect(cfg?.type, CloudBackendType.webdav,
          reason: '迁移失败不阻塞读取——数据可用即工作');
      expect(CloudServiceStore.lastMigrationErrorKey, 'cloud_webdav_cfg');
      expect(CloudServiceStore.lastMigrationErrorMessage, isNotNull);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('cloud_webdav_cfg'), isNotNull,
          reason: '迁移失败时明文不被误删（否则凭据丢失）');
    });

    test('迁移成功 → 痕迹清除 + 明文删除（自愈路径）', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_s3_cfg': '{"type":"s3","name":"old","s3Bucket":"b"}',
      });
      final store = CloudServiceStore(secureStorage: _NoopSecureStorage());

      await store.loadS3();
      expect(CloudServiceStore.lastMigrationErrorKey, isNull);
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('cloud_s3_cfg'), isNull,
          reason: '迁移成功后明文必须删除');
    });

    test('迁移失败后重新保存配置（_writeCfg 清掉明文）→ 痕迹清除', () async {
      SharedPreferences.setMockInitialValues({
        'cloud_webdav_cfg':
            '{"type":"webdav","name":"old","webdavUrl":"https://old.example.com",'
            '"webdavUsername":"u","webdavPassword":"p"}',
      });
      final store = CloudServiceStore(secureStorage: _NoopSecureStorage());
      // 直接注入上次迁移失败的痕迹（模拟历史失败后用户重新保存）
      CloudServiceStore.lastMigrationErrorKey = 'cloud_webdav_cfg';
      CloudServiceStore.lastMigrationErrorMessage = 'prev failure';

      const cfg = CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: 'w',
        webdavUrl: 'https://dav.example.com',
        webdavUsername: 'u',
        webdavPassword: 'p',
      );
      await store.saveOnly(cfg);

      expect(CloudServiceStore.lastMigrationErrorKey, isNull,
          reason: '写入成功清掉明文残留后，迁移失败痕迹随之失效');
      final sp = await SharedPreferences.getInstance();
      expect(sp.getString('cloud_webdav_cfg'), isNull);
    });
  });
}

/// M16：模拟 keystore 读路径损坏的假实现——read 永远抛异常，
/// write 正常（内存 Map），用于区分「读失败」与「未配置」。
class _BrokenReadSecureStorage extends FlutterSecureStorage {
  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    throw Exception('keystore broken (read)');
  }
}

/// 可正常工作的 secure storage 假实现（内存 Map）。
class _NoopSecureStorage extends FlutterSecureStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> write({
    required String key,
    required String? value,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async {
    if (value == null) {
      _store.remove(key);
    } else {
      _store[key] = value;
    }
  }

  @override
  Future<String?> read({
    required String key,
    IOSOptions? iOptions,
    AndroidOptions? aOptions,
    LinuxOptions? lOptions,
    WebOptions? webOptions,
    MacOsOptions? mOptions,
    WindowsOptions? wOptions,
  }) async =>
      _store[key];
}
