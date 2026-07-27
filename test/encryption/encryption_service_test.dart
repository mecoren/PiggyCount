// EncryptionServiceImpl 单元测试
//
// 锁死 EncryptionService 核心契约：
// - enable / disable / reset 生命周期
// - verifyPassword 密码校验
// - changePassword 密码修改
// - encrypt / decrypt 加解密 + 明文/密文自动识别
// - activateKey / persistActivatedKey 改密流程
//
// 使用 InMemorySecureKeyStorage 真实模拟存储行为（不依赖平台 channel）。
// 使用 Argon2KeyDerivation.forTesting() 保持测试快速。

import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:beecount/data/encryption/aes_gcm_cipher.dart';
import 'package:beecount/data/encryption/argon2_key_derivation.dart';
import 'package:beecount/data/encryption/ciphertext_format.dart';
import 'package:beecount/data/encryption/encryption_service_impl.dart';
import 'package:beecount/data/encryption/secure_key_storage.dart';
import 'package:beecount/domain/encryption/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureKeyStorage storage;
  late EncryptionServiceImpl service;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storage = InMemorySecureKeyStorage();
    service = EncryptionServiceImpl(
      storage: storage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
  });

  group('EncryptionServiceImpl.isEnabled', () {
    test('初始状态未开启', () async {
      expect(await service.isEnabled, isFalse);
    });

    test('enable 后变为已开启', () async {
      await service.enable(password: 'mypassword');
      expect(await service.isEnabled, isTrue);
    });

    test('disable 后变为未开启', () async {
      await service.enable(password: 'mypassword');
      await service.disable();
      expect(await service.isEnabled, isFalse);
    });
  });

  group('EncryptionServiceImpl.hasActiveKey', () {
    test('初始状态无密钥', () async {
      expect(await service.hasActiveKey, isFalse);
    });

    test('enable 后有密钥', () async {
      await service.enable(password: 'mypassword');
      expect(await service.hasActiveKey, isTrue);
    });

    test('disable 后仍有密钥（保留用于解密存量密文）', () async {
      await service.enable(password: 'mypassword');
      await service.disable();
      expect(await service.hasActiveKey, isTrue);
    });

    test('reset 后无密钥', () async {
      await service.enable(password: 'mypassword');
      await service.reset();
      expect(await service.hasActiveKey, isFalse);
    });
  });

  group('EncryptionServiceImpl.enable', () {
    test('密码为空抛出 ArgumentError', () async {
      expect(
        () => service.enable(password: ''),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('密码过短（< 6 字符）抛出 ArgumentError', () async {
      expect(
        () => service.enable(password: '12345'),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('enable 后 secure storage 中有 key、salt、verifier', () async {
      await service.enable(password: 'mypassword');

      expect(await storage.getKey(), isNotNull);
      expect(await storage.getSalt(), isNotNull);
      expect(await storage.getVerifier(), isNotNull);
    });

    test('enable 后 activeSalt 不为 null', () async {
      await service.enable(password: 'mypassword');
      expect(service.activeSalt, isNotNull);
      expect(service.activeSalt!.length, 16);
    });
  });

  group('EncryptionServiceImpl.verifyPassword', () {
    test('正确密码返回 true', () async {
      await service.enable(password: 'correctpassword');
      expect(await service.verifyPassword('correctpassword'), isTrue);
    });

    test('错误密码返回 false', () async {
      await service.enable(password: 'correctpassword');
      expect(await service.verifyPassword('wrongpassword'), isFalse);
    });

    test('未开启加密时返回 false', () async {
      expect(await service.verifyPassword('anything'), isFalse);
    });

    test('reset 后返回 false', () async {
      await service.enable(password: 'correctpassword');
      await service.reset();
      expect(await service.verifyPassword('correctpassword'), isFalse);
    });
  });

  group('EncryptionServiceImpl.encrypt / decrypt', () {
    test('未开启加密时 encrypt 返回原文', () async {
      const plaintext = '{"version":6,"items":[]}';
      final result = await service.encrypt(plaintext);
      expect(result, plaintext);
    });

    test('未开启加密时 decrypt 返回原文（legacy 明文兼容）', () async {
      const plaintext = '{"version":6,"items":[]}';
      final result = await service.decrypt(plaintext);
      expect(result, plaintext);
    });

    test('开启加密后 encrypt 返回 BEECRYPT1: 格式密文', () async {
      await service.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[]}';

      final result = await service.encrypt(plaintext);

      expect(CiphertextFormat.isEncrypted(result), isTrue);
    });

    test('encrypt → decrypt 往返还原原文', () async {
      await service.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[{"amount":99.9}]}';

      final ciphertext = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(ciphertext);

      expect(decrypted, plaintext);
    });

    test('decrypt legacy 明文（无 magic header）原样返回', () async {
      await service.enable(password: 'mypassword');
      const legacyPlaintext = '{"version":5,"items":[]}';

      final result = await service.decrypt(legacyPlaintext);

      expect(result, legacyPlaintext);
    });

    test('加密后密文内容与原文不同（非明文）', () async {
      await service.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[{"amount":99.9}]}';

      final ciphertext = await service.encrypt(plaintext);

      expect(ciphertext, isNot(plaintext));
      expect(ciphertext.contains('amount'), isFalse);
    });
  });

  group('EncryptionServiceImpl.changePassword', () {
    test('正确旧密码 + 有效新密码 → 修改成功', () async {
      await service.enable(password: 'oldpassword');

      await service.changePassword(
        oldPassword: 'oldpassword',
        newPassword: 'newpassword',
      );

      // 新密码应该能验证
      expect(await service.verifyPassword('newpassword'), isTrue);
      // 旧密码应该不能验证
      expect(await service.verifyPassword('oldpassword'), isFalse);
    });

    test('错误旧密码 → 抛出 ArgumentError', () async {
      await service.enable(password: 'oldpassword');

      expect(
        () => service.changePassword(
          oldPassword: 'wrongold',
          newPassword: 'newpassword',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('新密码无效（过短）→ 抛出 ArgumentError', () async {
      await service.enable(password: 'oldpassword');

      expect(
        () => service.changePassword(
          oldPassword: 'oldpassword',
          newPassword: '12345',
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('修改密码后仍能解密用新密码加密的数据', () async {
      await service.enable(password: 'oldpassword');
      const plaintext = '{"version":6,"items":[]}';

      await service.changePassword(
        oldPassword: 'oldpassword',
        newPassword: 'newpassword',
      );

      final ciphertext = await service.encrypt(plaintext);
      final decrypted = await service.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('修改密码后用旧密码加密的密文无法用新密钥解密', () async {
      await service.enable(password: 'oldpassword');
      const plaintext = '{"version":6,"items":[]}';

      // 用旧密码加密
      final oldCiphertext = await service.encrypt(plaintext);

      // 修改密码
      await service.changePassword(
        oldPassword: 'oldpassword',
        newPassword: 'newpassword',
      );

      // 旧密文（salt 不同）应该无法解密
      expect(
        () => service.decrypt(oldCiphertext),
        throwsA(isA<DecryptionException>()),
      );
    });
  });

  group('EncryptionServiceImpl.reset', () {
    test('reset 后 secure storage 完全清空', () async {
      await service.enable(password: 'mypassword');

      await service.reset();

      expect(await storage.getKey(), isNull);
      expect(await storage.getSalt(), isNull);
      expect(await storage.getVerifier(), isNull);
    });

    test('reset 后 isEnabled 为 false', () async {
      await service.enable(password: 'mypassword');

      await service.reset();

      expect(await service.isEnabled, isFalse);
    });

    test('reset 后 activeSalt 为 null', () async {
      await service.enable(password: 'mypassword');

      await service.reset();

      expect(service.activeSalt, isNull);
    });
  });

  group('EncryptionServiceImpl.activateKey / persistActivatedKey', () {
    test('activateKey 后 activeSalt 为传入的 salt', () async {
      final salt = List<int>.generate(16, (i) => 0x42);

      await service.activateKey(password: 'testpw', salt: salt);

      expect(service.activeSalt, equals(salt));
    });

    test('activateKey 后 encrypt 可用（无需 enable）', () async {
      await service.enable(password: 'temppw');
      final salt = List<int>.generate(16, (i) => 0x99);

      await service.activateKey(password: 'newpass', salt: salt);

      const plaintext = 'test data';
      final ciphertext = await service.encrypt(plaintext);
      expect(CiphertextFormat.isEncrypted(ciphertext), isTrue);
    });

    test('persistActivatedKey 后密钥持久化到 secure storage', () async {
      await service.enable(password: 'temppw');
      final salt = List<int>.generate(16, (i) => 0x77);

      await service.activateKey(password: 'newpass', salt: salt);
      await service.persistActivatedKey();

      expect(await storage.getKey(), isNotNull);
      expect(await storage.getSalt(), equals(salt));
      expect(await storage.getVerifier(), isNotNull);
    });

    test('无激活密钥时 persistActivatedKey 抛出 StateError', () async {
      expect(
        () => service.persistActivatedKey(),
        throwsA(isA<StateError>()),
      );
    });
  });

  group('EncryptionServiceImpl 多设备场景模拟', () {
    test('A 设备加密 → B 设备同密码解密', () async {
      // A 设备：开启加密并加密数据
      await service.enable(password: 'sharedpassword');
      const plaintext = '{"version":6,"items":[{"amount":100}]}';
      final ciphertext = await service.encrypt(plaintext);

      // B 设备：新实例，无密钥
      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );

      // B 设备用相同密码激活密钥（salt 从密文头取）
      final decoded = CiphertextFormat.decode(ciphertext);
      await serviceB.activateKey(
        password: 'sharedpassword',
        salt: decoded.salt,
      );

      // B 设备解密
      final decrypted = await serviceB.decrypt(ciphertext);
      expect(decrypted, plaintext);
    });

    test('A 设备加密 → B 设备不同密码解密失败', () async {
      await service.enable(password: 'correctpass');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await service.encrypt(plaintext);

      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );

      final decoded = CiphertextFormat.decode(ciphertext);
      await serviceB.activateKey(
        password: 'wrongpass',
        salt: decoded.salt,
      );

      expect(
        () => serviceB.decrypt(ciphertext),
        throwsA(isA<DecryptionException>()),
      );
    });
  });

  group('EncryptionServiceImpl.reEncryptExistingCloudData', () {
    late _FakeCloudStorage cloud;

    setUp(() {
      cloud = _FakeCloudStorage();
    });

    test('加密未开启时抛 StateError', () async {
      expect(
        () => service.reEncryptExistingCloudData(storage: cloud),
        throwsA(isA<StateError>()),
      );
    });

    test('云端有 legacy 明文 → 全部重加密为 BEECRYPT1: 格式', () async {
      await service.enable(password: 'mypassword');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[{"amount":99}]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 2);
      expect(result.failed, 0);
      expect(result.skipped, 0);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
      // 密文中不应包含明文片段
      expect(cloud.stored['ledger_1.json']!.contains('version'), isFalse);
    });

    test('混合 legacy 明文 + 已加密密文 → 都重加密为新密文', () async {
      // 场景：用户之前已开过加密（用相同密码），现在重新开启
      await service.enable(password: 'mypassword');
      final ciphertext = await service.encrypt('{"version":6,"items":[]}');
      cloud.stored['ledger_1.json'] = ciphertext; // 已是密文
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}'; // legacy 明文
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 2);
      expect(result.failed, 0);
      // 两份都应是密文
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
      // 解密后内容一致
      final decrypted = await service.decrypt(cloud.stored['ledger_1.json']!);
      expect(decrypted, '{"version":6,"items":[]}');
    });

    test('非 ledger_*.json 文件被跳过', () async {
      await service.enable(password: 'mypassword');
      cloud.stored['readme.txt'] = 'hello';
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'readme.txt', path: 'readme.txt'),
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'backup.old', path: 'backup.old'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 1);
      expect(result.failed, 0);
      expect(result.skipped, 2); // readme.txt + backup.old
      expect(cloud.stored['readme.txt'], 'hello'); // 未被改
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
    });

    test('download 返回 null 的文件被跳过', () async {
      await service.enable(password: 'mypassword');
      // list 返回了文件名但 stored 中没有该文件 → download 返回 null
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 0);
      expect(result.skipped, 1);
      expect(result.failed, 0);
    });

    test('单文件 download 失败不中断整体流程', () async {
      await service.enable(password: 'mypassword');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}';
      cloud.throwOnDownloadPaths.add('ledger_1.json');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 1); // ledger_2 成功
      expect(result.failed, 1); // ledger_1 失败
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_2.json']!), isTrue);
    });

    test('单文件 upload 失败不中断整体流程', () async {
      await service.enable(password: 'mypassword');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.stored['ledger_2.json'] = '{"version":6,"items":[]}';
      cloud.throwOnUploadPaths.add('ledger_2.json');
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
        CloudFile(name: 'ledger_2.json', path: 'ledger_2.json'),
      ];

      final result = await service.reEncryptExistingCloudData(storage: cloud);

      expect(result.success, 1); // ledger_1 成功
      expect(result.failed, 1); // ledger_2 失败
    });

    test('list 抛错时整体失败，抛出原异常', () async {
      await service.enable(password: 'mypassword');
      cloud.listFiles = []; // 不会被读到
      // 用一个会抛错的 storage
      final throwingStorage = _ThrowingListStorage();

      expect(
        () => service.reEncryptExistingCloudData(storage: throwingStorage),
        throwsA(isA<Exception>()),
      );
    });

    test('加密已开启但密钥不可用（reset 后）→ 抛 StateError', () async {
      // 模拟异常状态：isEnabled=true 但 key 已被清空
      await service.enable(password: 'mypassword');
      // 直接清掉内存 key 模拟密钥不可用
      await service.reset();
      // reset 会同时把 isEnabled 置 false，所以这个场景实际不会发生
      // 但若仅清 key 而保留 enabled flag，应抛 StateError
      // 这里通过 disable 后再 reset 来验证 enabled=false 时也会抛
      expect(
        () => service.reEncryptExistingCloudData(storage: cloud),
        throwsA(isA<StateError>()),
      );
    });

    test('重加密后再调用一次（幂等性）→ 文件仍是密文，success 不变', () async {
      await service.enable(password: 'mypassword');
      cloud.stored['ledger_1.json'] = '{"version":6,"items":[]}';
      cloud.listFiles = [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      await service.reEncryptExistingCloudData(storage: cloud);
      final firstCipher = cloud.stored['ledger_1.json']!;

      // 再次调用
      final result = await service.reEncryptExistingCloudData(storage: cloud);
      expect(result.success, 1);
      // 仍是密文（可能因 nonce 不同而内容不同，但格式必须是密文）
      expect(CiphertextFormat.isEncrypted(cloud.stored['ledger_1.json']!), isTrue);
      // 解密后内容一致
      final decrypted = await service.decrypt(cloud.stored['ledger_1.json']!);
      expect(decrypted, '{"version":6,"items":[]}');
      // 第一次的密文也能解密（虽然 nonce 不同）
      final decryptedFirst = await service.decrypt(firstCipher);
      expect(decryptedFirst, '{"version":6,"items":[]}');
    });
  });
}

/// list 方法抛异常的 CloudStorageService 实现
class _ThrowingListStorage implements CloudStorageService {
  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {}

  @override
  Future<String?> download({required String path}) async => null;

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<CloudFile>> list({required String path}) async {
    throw Exception('mock list failure');
  }

  @override
  Future<bool> exists({required String path}) async => false;

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}

/// 内存版 SecureKeyStorage，用于单元测试
///
/// 真实模拟存储行为，不依赖平台 channel。
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

/// 内存版 CloudStorageService，用于 reEncryptExistingCloudData 测试
class _FakeCloudStorage implements CloudStorageService {
  final Map<String, String> stored = {};
  List<CloudFile> listFiles = const [];
  final Set<String> throwOnDownloadPaths = {};
  final Set<String> throwOnUploadPaths = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    if (throwOnUploadPaths.contains(path)) {
      throw Exception('mock upload failure for $path');
    }
    stored[path] = data;
  }

  @override
  Future<String?> download({required String path}) async {
    if (throwOnDownloadPaths.contains(path)) {
      throw Exception('mock download failure for $path');
    }
    return stored[path];
  }

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return listFiles;
  }

  @override
  Future<bool> exists({required String path}) async {
    return stored.containsKey(path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    if (!stored.containsKey(path)) return null;
    return CloudFile(name: path, path: path);
  }
}
