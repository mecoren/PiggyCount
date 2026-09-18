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
      await encryptionService.enable(password: 'MyPassw0rd');
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
      await encryptionService.enable(password: 'MyPassw0rd');
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
      await encryptionService.enable(password: 'MyPassw0rd');
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
      await encryptionService.enable(password: 'FirstPass1');
      final ciphertext = await encryptionService.encrypt('{"v":1}');

      // 修改密码（生成新 salt），旧密文 salt 不匹配
      await encryptionService.changePassword(
        oldPassword: 'FirstPass1',
        newPassword: 'SecondPass2',
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
      await encryptionService.enable(password: 'PasswordA1');
      const plaintext = '{"version":6,"items":[]}';
      final ciphertext = await encryptionService.encrypt(plaintext);

      // 设备 B：不同密码 enable（生成不同 salt）
      final storageB = InMemorySecureKeyStorage();
      final serviceB = EncryptionServiceImpl(
        storage: storageB,
        keyDerivation: Argon2KeyDerivation.forTesting(),
        cipher: AesGcmCipher(),
      );
      await serviceB.enable(password: 'PasswordB2');

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
      await encryptionService.enable(password: 'MyPassw0rd');
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
      await encryptionService.enable(password: 'MyPassw0rd');
      await encryptionService.reset();
      // 此时 isEnabled 为 false，但若代码错误地认为还该加密会怎样？
      // 实际：isEnabled=false，upload 透传原文（不抛错）
      // 这个测试锁死：reset 后 upload 行为与「未开启」一致
      const plaintext = '{"version":6,"items":[]}';
      await decorated.upload(path: 'ledger_1.json', data: plaintext);
      expect(inner.uploaded['ledger_1.json'], plaintext);
    });
  });

  group('EncryptedCloudStorageService.downloadBinary（审计 A1 回归）', () {
    late FakeBinaryCloudStorageService binInner;
    late EncryptedCloudStorageService binDecorated;

    setUp(() {
      // 注意：keyStorage/encryptionService 复用外层 setUp 的实例，
      // 保证 decorated / binDecorated 包装的是同一个已 enable 的服务。
      binInner = FakeBinaryCloudStorageService();
      binDecorated = EncryptedCloudStorageService(
        inner: binInner,
        encryptionService: encryptionService,
      );
    });

    test('E2EE 开启：inner 存有原生二进制旧附件 → 原样字节返回（不再抛 utf8 异常）',
        () async {
      await encryptionService.enable(password: 'MyPassw0rd');
      // JPEG 魔数开头的真实二进制（非合法 UTF-8，文本下载必炸）
      final jpegBytes = Uint8List.fromList(
          [0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x10, 0x4A, 0x46, 0x49, 0x46, 0x00]);
      binInner.storedBytes['attachments/abc.bin'] = jpegBytes;

      final result = await binDecorated.downloadBinary(path: 'attachments/abc.bin');

      expect(result, isNotNull);
      expect(result, jpegBytes);
    });

    test('E2EE 开启：装饰器 uploadBinary 写入的信封 → downloadBinary 字节往返',
        () async {
      await encryptionService.enable(password: 'MyPassw0rd');
      final pngBytes =
          Uint8List.fromList([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      await binDecorated.uploadBinary(path: 'attachments/x.bin', bytes: pngBytes);
      // 云端产物必须是密文信封
      expect(CiphertextFormat.isEncrypted(binInner.storedText['attachments/x.bin']!),
          isTrue);

      final result = await binDecorated.downloadBinary(path: 'attachments/x.bin');
      expect(result, pngBytes);
    });

    test('E2EE 开启：legacy 明文 base64 文本对象 → 解码为字节', () async {
      await encryptionService.enable(password: 'MyPassw0rd');
      final raw = Uint8List.fromList(utf8.encode('legacy attachment'));
      binInner.storedText['attachments/old.bin'] = base64Encode(raw);

      final result = await binDecorated.downloadBinary(path: 'attachments/old.bin');
      expect(result, raw);
    });

    test('E2EE 开启：对象不存在 → 返回 null', () async {
      await encryptionService.enable(password: 'MyPassw0rd');
      final result =
          await binDecorated.downloadBinary(path: 'attachments/none.bin');
      expect(result, isNull);
    });

    test('非 BinaryCapable inner + 密文信封（字符串存储）→ downloadBinary 正确解码',
        () async {
      // 复用顶部既有的字符串版 fake：模拟不支持真字节路径的后端
      await encryptionService.enable(password: 'MyPassw0rd');
      final payload = Uint8List.fromList(utf8.encode('text-backend bytes'));
      await decorated.uploadBinary(path: 'attachments/t.bin', bytes: payload);

      final result = await decorated.downloadBinary(path: 'attachments/t.bin');
      expect(result, payload);
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
  @override
  Future<void> saveRekeyCheckpoint(String ciphertextB64) async {
    _store['piggycount_enc_rekey_ckpt'] = ciphertextB64;
  }

  @override
  Future<String?> getRekeyCheckpoint() async {
    return _store['piggycount_enc_rekey_ckpt'];
  }

  @override
  Future<void> clearRekeyCheckpoint() async {
    _store.remove('piggycount_enc_rekey_ckpt');
  }
  @override
  Future<void> clearAll() async {
    _store.clear();
  }
}

/// 内存版 BinaryCapableStorage：模拟 S3/WebDAV 的真字节后端。
///
/// 关键行为：download()（文本路径）对非 UTF-8 字节抛 FormatException ——
/// 与真实 S3/WebDAV 存储层 utf8.decode 原生二进制对象的行为一致，
/// 用于锁死审计 A1 的「原生二进制旧附件在 E2EE 下可读」回归。
class FakeBinaryCloudStorageService
    implements CloudStorageService, BinaryCapableStorage {
  /// 真字节存储（path → bytes）
  final Map<String, Uint8List> storedBytes = {};

  /// 文本存储（path → text），与 storedBytes 互斥使用
  final Map<String, String> storedText = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    storedText[path] = data;
  }

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    storedBytes[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<String?> download({required String path}) async {
    final bytes = storedBytes[path];
    if (bytes != null) {
      // 与 S3StorageService.download 一致：非文本内容直接炸
      return utf8.decode(bytes);
    }
    return storedText[path];
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    final bytes = storedBytes[path];
    if (bytes != null) return bytes;
    final text = storedText[path];
    return text == null ? null : Uint8List.fromList(utf8.encode(text));
  }

  @override
  Future<void> delete({required String path}) async {
    storedBytes.remove(path);
    storedText.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async =>
      storedBytes.containsKey(path) || storedText.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}
