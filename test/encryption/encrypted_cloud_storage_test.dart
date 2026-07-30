// EncryptedCloudStorageService 装饰器单元测试
//
// 锁死装饰器契约：
// - upload: 加密已开启 → 加密 data 后传给 inner；未开启 → 透传原文
// - download: inner 返回 null → 返回 null；返回密文 → 解密；返回 legacy 明文 → 原样透传
// - delete / list / exists / getMetadata: 完全透传，不接触加密
//
// 使用 FakeCloudStorageService 真实模拟存储行为（不依赖平台 channel）。
// 使用 EncryptionServiceImpl + InMemorySecureKeyStorage 跑真实加解密链路，
// 避免只测 mock 行为。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/ciphertext_format.dart';
import 'package:piggycount/data/encryption/encrypted_cloud_storage.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late InMemorySecureKeyStorage keyStorage;
  late EncryptionServiceImpl encryptionService;
  late FakeCloudStorageService inner;
  late EncryptedCloudStorageService decorated;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    keyStorage = InMemorySecureKeyStorage();
    encryptionService = EncryptionServiceImpl(
      storage: keyStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    inner = FakeCloudStorageService();
    decorated = EncryptedCloudStorageService(
      inner: inner,
      encryptionService: encryptionService,
    );
  });

  group('EncryptedCloudStorageService.upload', () {
    test('加密未开启时透传原文给 inner', () async {
      const plaintext = '{"version":6,"items":[]}';

      await decorated.upload(path: 'ledger_1.json', data: plaintext);

      expect(inner.uploaded['ledger_1.json'], plaintext);
    });

    test('加密已开启时上传密文格式（BEECRYPT1:）给 inner', () async {
      await encryptionService.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[]}';

      await decorated.upload(path: 'ledger_1.json', data: plaintext);

      final stored = inner.uploaded['ledger_1.json'];
      expect(stored, isNotNull);
      expect(CiphertextFormat.isEncrypted(stored!), isTrue);
      // 密文中不应包含明文片段
      expect(stored.contains('version'), isFalse);
      expect(stored.contains('items'), isFalse);
    });

    test('加密已开启时上传后 inner 中存的是密文（非原文）', () async {
      await encryptionService.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[{"amount":99.9}]}';

      await decorated.upload(path: 'ledger_1.json', data: plaintext);

      expect(inner.uploaded['ledger_1.json'], isNot(plaintext));
    });

    test('metadata 透传给 inner', () async {
      const metadata = {'fingerprint': 'abc123'};

      await decorated.upload(
        path: 'ledger_1.json',
        data: '{}',
        metadata: metadata,
      );

      expect(inner.uploadedMetadata['ledger_1.json'], metadata);
    });
  });

  group('EncryptedCloudStorageService.download (加密未开启)', () {
    test('inner 返回 null → 返回 null', () async {
      final result = await decorated.download(path: 'ledger_1.json');
      expect(result, isNull);
    });

    test('inner 返回明文 → 原样返回', () async {
      inner.stored['ledger_1.json'] = '{"version":6,"items":[]}';

      final result = await decorated.download(path: 'ledger_1.json');

      expect(result, '{"version":6,"items":[]}');
    });
  });

  group('EncryptedCloudStorageService.download (加密已开启)', () {
    setUp(() async {
      await encryptionService.enable(password: 'mypassword');
    });

    test('inner 返回 null → 返回 null', () async {
      final result = await decorated.download(path: 'ledger_1.json');
      expect(result, isNull);
    });

    test('inner 返回密文 → 解密返回原文', () async {
      const plaintext = '{"version":6,"items":[{"amount":42.5}]}';
      final ciphertext = await encryptionService.encrypt(plaintext);
      inner.stored['ledger_1.json'] = ciphertext;

      final result = await decorated.download(path: 'ledger_1.json');

      expect(result, plaintext);
    });

    test('inner 返回 legacy 明文（无 magic header）→ 原样返回', () async {
      const legacyPlaintext = '{"version":5,"items":[]}';
      inner.stored['ledger_1.json'] = legacyPlaintext;

      final result = await decorated.download(path: 'ledger_1.json');

      expect(result, legacyPlaintext);
    });

    test('解密失败抛出 DecryptionException', () async {
      // 用错误密码加密一段数据，然后切换密码，使其无法解密
      await encryptionService.enable(password: 'firstpassword');
      final ciphertext = await encryptionService.encrypt('{"v":1}');

      // 修改密码（生成新 salt），旧密文 salt 不匹配
      await encryptionService.changePassword(
        oldPassword: 'firstpassword',
        newPassword: 'secondpassword',
      );

      inner.stored['ledger_1.json'] = ciphertext;

      expect(
        () => decorated.download(path: 'ledger_1.json'),
        throwsA(isA<DecryptionException>()),
      );
    });

    test('US-2: salt 不匹配时 download 抛出 SaltMismatchException（可被 UI 单独捕获）',
        () async {
      // 设备 A 加密
      await encryptionService.enable(password: 'passwordA');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await encryptionService.encrypt(plaintext);

      // 设备 B：不同密码 enable（生成不同 salt）
      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await serviceB.enable(password: 'passwordB');

      final decoratedB = EncryptedCloudStorageService(
        inner: inner,
        encryptionService: serviceB,
      );
      inner.stored['ledger_1.json'] = ciphertext;

      // download 应抛 SaltMismatchException，UI 层可 catch 此异常引导重输密码
      expect(
        () => decoratedB.download(path: 'ledger_1.json'),
        throwsA(isA<SaltMismatchException>()),
      );
    });
  });

  group('EncryptedCloudStorageService 往返测试', () {
    test('upload → download 还原原文（加密已开启）', () async {
      await encryptionService.enable(password: 'mypassword');
      const plaintext = '{"version":6,"items":[{"amount":1},{"amount":2}]}';

      await decorated.upload(path: 'ledger_1.json', data: plaintext);
      final result = await decorated.download(path: 'ledger_1.json');

      expect(result, plaintext);
    });

    test('upload → download 还原原文（加密未开启）', () async {
      const plaintext = '{"version":6,"items":[]}';

      await decorated.upload(path: 'ledger_1.json', data: plaintext);
      final result = await decorated.download(path: 'ledger_1.json');

      expect(result, plaintext);
    });
  });

  group('EncryptedCloudStorageService 透传方法', () {
    test('delete 透传到 inner', () async {
      await decorated.delete(path: 'ledger_1.json');
      expect(inner.deletedPaths, contains('ledger_1.json'));
    });

    test('list 透传到 inner', () async {
      inner.listFiles = const [
        CloudFile(name: 'ledger_1.json', path: 'ledger_1.json'),
      ];

      final result = await decorated.list(path: '');

      expect(result.length, 1);
      expect(result.first.path, 'ledger_1.json');
    });

    test('exists 透传到 inner', () async {
      inner.existsMap['ledger_1.json'] = true;

      final result = await decorated.exists(path: 'ledger_1.json');

      expect(result, isTrue);
    });

    test('getMetadata 透传到 inner', () async {
      final meta = CloudFile(
        name: 'ledger_1.json',
        path: 'ledger_1.json',
        size: 1024,
      );
      inner.metadataMap['ledger_1.json'] = meta;

      final result = await decorated.getMetadata(path: 'ledger_1.json');

      expect(result, isNotNull);
      expect(result!.size, 1024);
    });
  });

  group('EncryptedCloudStorageService 装饰器边界', () {
    test('加密已开启但密钥不可用（reset 后）→ upload 抛出', () async {
      await encryptionService.enable(password: 'mypassword');
      await encryptionService.reset();
      // 此时 isEnabled 为 false，但若代码错误地认为还该加密会怎样？
      // 实际：isEnabled=false，upload 透传原文（不抛错）
      // 这个测试锁死：reset 后 upload 行为与「未开启」一致
      const plaintext = '{"version":6,"items":[]}';
      await decorated.upload(path: 'ledger_1.json', data: plaintext);
      expect(inner.uploaded['ledger_1.json'], plaintext);
    });
  });
}

/// 内存版 CloudStorageService，用于装饰器测试
class FakeCloudStorageService implements CloudStorageService {
  /// 模拟云端存储的文件（path → content）
  final Map<String, String> stored = {};

  /// upload 时记录的数据（path → content）
  final Map<String, String> uploaded = {};

  /// upload 时记录的 metadata（path → metadata）
  final Map<String, Map<String, String>> uploadedMetadata = {};

  /// delete 调用记录的路径列表
  final List<String> deletedPaths = [];

  /// list 返回的文件列表
  List<CloudFile> listFiles = const [];

  /// exists 返回值的映射（path → bool）
  final Map<String, bool> existsMap = {};

  /// getMetadata 返回值的映射（path → CloudFile）
  final Map<String, CloudFile> metadataMap = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    stored[path] = data;
    uploaded[path] = data;
    if (metadata != null) {
      uploadedMetadata[path] = metadata;
    }
  }

  @override
  Future<String?> download({required String path}) async {
    return stored[path];
  }

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
    deletedPaths.add(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return listFiles;
  }

  @override
  Future<bool> exists({required String path}) async {
    return existsMap[path] ?? false;
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    return metadataMap[path];
  }
}

/// 内存版 SecureKeyStorage，用于单元测试
class InMemorySecureKeyStorage implements SecureKeyStorage {
  final Map<String, String> _store = {};

  @override
  Future<void> saveKey(List<int> key) async {
    _store['piggycount_enc_key'] = base64.encode(key);
  }

  @override
  Future<Uint8List?> getKey() async {
    final value = _store['piggycount_enc_key'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  Future<void> saveVerifier(List<int> verifier) async {
    _store['piggycount_enc_verifier'] = base64.encode(verifier);
  }

  @override
  Future<Uint8List?> getVerifier() async {
    final value = _store['piggycount_enc_verifier'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  Future<void> saveSalt(List<int> salt) async {
    _store['piggycount_enc_salt'] = base64.encode(salt);
  }

  @override
  Future<Uint8List?> getSalt() async {
    final value = _store['piggycount_enc_salt'];
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  @override
  Future<void> clearAll() async {
    _store.clear();
  }
}
