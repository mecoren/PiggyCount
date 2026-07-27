// EncryptedCloudProvider 装饰器单元测试
//
// 锁死装饰器契约：
// - storage getter 返回加密版（EncryptedCloudStorageService 行为）
// - providerId / providerName / auth / initialize / validateConfig / dispose 全部透传
//
// 使用 FakeCloudProvider 真实模拟 CloudProvider 行为，验证 storage 经过加密装饰器。

import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/encryption/aes_gcm_cipher.dart';
import 'package:beecount/data/encryption/argon2_key_derivation.dart';
import 'package:beecount/data/encryption/ciphertext_format.dart';
import 'package:beecount/data/encryption/encrypted_cloud_provider.dart';
import 'package:beecount/data/encryption/encryption_service_impl.dart';
import 'package:beecount/data/encryption/secure_key_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureKeyStorage keyStorage;
  late EncryptionServiceImpl encryptionService;
  late FakeCloudProvider innerProvider;
  late FakeCloudStorageService innerStorage;
  late EncryptedCloudProvider decoratedProvider;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keyStorage = InMemorySecureKeyStorage();
    encryptionService = EncryptionServiceImpl(
      storage: keyStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    innerStorage = FakeCloudStorageService();
    innerProvider = FakeCloudProvider(storage: innerStorage);
    decoratedProvider = EncryptedCloudProvider(
      inner: innerProvider,
      encryptionService: encryptionService,
    );
  });

  group('EncryptedCloudProvider 透传 getter', () {
    test('providerId 透传', () {
      expect(decoratedProvider.providerId, 'fake_provider');
    });

    test('providerName 透传', () {
      expect(decoratedProvider.providerName, 'Fake Provider');
    });

    test('auth 透传同一实例', () {
      expect(decoratedProvider.auth, same(innerProvider.auth));
    });
  });

  group('EncryptedCloudProvider.storage', () {
    test('storage 不等于 inner 的 storage（被装饰）', () {
      expect(decoratedProvider.storage, isNot(same(innerProvider.storage)));
    });

    test('加密未开启时 upload 透传原文', () async {
      const plaintext = '{"version":6,"items":[]}';
      await decoratedProvider.storage.upload(
        path: 'ledger_1.json',
        data: plaintext,
      );

      expect(innerStorage.uploaded['ledger_1.json'], plaintext);
    });

    test('加密已开启时 upload 写入密文', () async {
      await encryptionService.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[]}';

      await decoratedProvider.storage.upload(
        path: 'ledger_1.json',
        data: plaintext,
      );

      final stored = innerStorage.uploaded['ledger_1.json'];
      expect(stored, isNotNull);
      expect(CiphertextFormat.isEncrypted(stored!), isTrue);
    });

    test('download 走解密路径', () async {
      await encryptionService.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[{"amount":1}]}';

      await decoratedProvider.storage.upload(
        path: 'ledger_1.json',
        data: plaintext,
      );
      final result = await decoratedProvider.storage.download(
        path: 'ledger_1.json',
      );

      expect(result, plaintext);
    });
  });

  group('EncryptedCloudProvider 透传方法', () {
    test('initialize 透传 config 到 inner', () async {
      const config = {'url': 'http://example.com', 'token': 'abc'};

      await decoratedProvider.initialize(config);

      expect(innerProvider.initializedConfig, config);
    });

    test('validateConfig 透传并返回 inner 结果', () {
      const config = {'valid': true};

      final result = decoratedProvider.validateConfig(config);

      expect(result, isTrue);
      expect(innerProvider.validatedConfig, config);
    });

    test('dispose 透传到 inner', () async {
      await decoratedProvider.dispose();

      expect(innerProvider.disposed, isTrue);
    });
  });
}

/// 内存版 CloudProvider，用于装饰器测试
class FakeCloudProvider implements CloudProvider {
  final CloudStorageService storage;
  final CloudAuthService auth;

  FakeCloudProvider({
    CloudStorageService? storage,
    CloudAuthService? auth,
  })  : storage = storage ?? FakeCloudStorageService(),
        auth = auth ?? NoopAuthService();

  Map<String, dynamic>? initializedConfig;
  Map<String, dynamic>? validatedConfig;
  bool disposed = false;

  @override
  String get providerId => 'fake_provider';

  @override
  String get providerName => 'Fake Provider';

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    initializedConfig = config;
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    validatedConfig = config;
    return true;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

/// 内存版 CloudStorageService
class FakeCloudStorageService implements CloudStorageService {
  final Map<String, String> stored = {};
  final Map<String, String> uploaded = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    stored[path] = data;
    uploaded[path] = data;
  }

  @override
  Future<String?> download({required String path}) async {
    return stored[path];
  }

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return const [];
  }

  @override
  Future<bool> exists({required String path}) async => stored.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}

/// 内存版 SecureKeyStorage
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> saveKey(List<int> key) async {
    _store['beecount_enc_key'] = base64.encode(key);
  }

  @override
  Future<List<int>?> getKey() async {
    final value = _store['beecount_enc_key'];
    if (value == null) return null;
    return base64.decode(value);
  }

  @override
  Future<void> saveVerifier(List<int> verifier) async {
    _store['beecount_enc_verifier'] = base64.encode(verifier);
  }

  @override
  Future<List<int>?> getVerifier() async {
    final value = _store['beecount_enc_verifier'];
    if (value == null) return null;
    return base64.decode(value);
  }

  @override
  Future<void> saveSalt(List<int> salt) async {
    _store['beecount_enc_salt'] = base64.encode(salt);
  }

  @override
  Future<List<int>?> getSalt() async {
    final value = _store['beecount_enc_salt'];
    if (value == null) return null;
    return base64.decode(value);
  }

  @override
  Future<void> clearAll() async {
    _store.clear();
  }
}
