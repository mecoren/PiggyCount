// P0-2 回归：E2EE 装饰器条件写的密文形态必须与 upload（文本形态）对齐。
//
// 背景（审计发现）：EncryptedCloudStorageService.uploadBinaryConditional
// 旧实现按 uploadBinary 口径存 encrypt(base64(bytes))，而唯一调用方
// CloudSyncManager.upload(ifMatchEtag) 传入的 bytes 是明文 JSON 的 utf8
// 字节 —— 存储形态变成 encrypt(base64(明文))。download() 对密文 decrypt
// 后直接返回，读到的是 base64 文本而非 JSON：E2EE + 条件写后端（S3 恒走
// 条件写路径）下，该账本所有 download / 恢复 / 完整性校验全部损坏。
//
// 本测试锁死：
// 1. 条件写上传的文本内容 → download 能还原出原始明文（往返一致）；
// 2. 云端存储的形态与 upload（非条件）写入的形态同构（同一明文 →
//    两条路径产生相同密文）；
// 3. 非文本字节（防御路径）→ 仍能经 downloadBinary 还原。

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

/// 内存版 SecureKeyStorage（与 encrypted_cloud_storage_test 同款，跑真实
/// 加解密链路而不用 mock）
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('E2EE 开启：条件写文本内容 → download 往返还原明文', () async {
    final keyStorage = InMemorySecureKeyStorage();
    final encryptionService = EncryptionServiceImpl(
      storage: keyStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    await encryptionService.enable(password: 'MyPassw0rd');

    final inner = _ConditionalFakeStorage();
    final decorated = EncryptedCloudStorageService(
      inner: inner,
      encryptionService: encryptionService,
    );

    const plaintext = '{"version":9,"items":[{"amount":42.0}]}';
    // 与 CloudSyncManager.upload 的调用口径一致：明文 JSON 的 utf8 字节
    await decorated.uploadBinaryConditional(
      path: 'ledger_1.json',
      bytes: utf8.encode(plaintext),
      metadata: const {'fingerprint': 'abc'},
      ifMatchEtag: 'etag-1',
    );

    expect(inner.conditionalWriteCount, 1, reason: '必须走 inner 条件写路径');
    expect(inner.eTagGuard, 'etag-1', reason: '乐观并发锚点必须透传 inner');

    // 往返：download 拿到的必须是原始明文 JSON，而非 base64 包装文本
    final downloaded = await decorated.download(path: 'ledger_1.json');
    expect(downloaded, plaintext,
        reason: 'P0-1 根因：条件写存成 encrypt(base64(明文)) 时，'
            'download 返回 base64 文本，所有恢复/完整性校验损坏');
    // 且可被 jsonDecode 正常解析（调用方的实际消费形态）
    expect(jsonDecode(downloaded!), isA<Map<String, dynamic>>());
  });

  test('E2EE 开启：条件写与普通 upload 产生相同密文形态（同明文互覆无损）', () async {
    final keyStorage = InMemorySecureKeyStorage();
    final encryptionService = EncryptionServiceImpl(
      storage: keyStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    await encryptionService.enable(password: 'MyPassw0rd');

    final inner = _ConditionalFakeStorage();
    final decorated = EncryptedCloudStorageService(
      inner: inner,
      encryptionService: encryptionService,
    );

    const plaintext = '{"k":"v"}';
    await decorated.upload(path: 'a.json', data: plaintext);
    final viaUpload = inner.stored['a.json'];

    await decorated.uploadBinaryConditional(
      path: 'b.json',
      bytes: utf8.encode(plaintext),
    );
    final viaConditional = inner.stored['b.json'];

    // 同明文经两条路径上云，密文应同构（加密含随机 IV 时密文不同，
    // 但解密后必须同原文 —— 以解密等价性断言）
    final decryptedA = await decorated.download(path: 'a.json');
    final decryptedB = await decorated.download(path: 'b.json');
    expect(decryptedA, plaintext);
    expect(decryptedB, plaintext, reason: '两条上传路径的存储形态必须互逆于同一下载路径');
    expect(CiphertextFormat.isEncrypted(viaUpload!), isTrue);
    expect(CiphertextFormat.isEncrypted(viaConditional!), isTrue);
  });

  test('E2EE 开启：非文本字节（防御路径）→ downloadBinary 还原', () async {
    final keyStorage = InMemorySecureKeyStorage();
    final encryptionService = EncryptionServiceImpl(
      storage: keyStorage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );
    await encryptionService.enable(password: 'MyPassw0rd');

    final inner = _ConditionalFakeStorage();
    final decorated = EncryptedCloudStorageService(
      inner: inner,
      encryptionService: encryptionService,
    );

    // 二进制附件内容（非合法 UTF-8，模拟 ZIP 头等）
    final bytes =
        Uint8List.fromList([0x50, 0x4B, 0x03, 0x04, 0xFF, 0xFE, 0x00]);
    await decorated.uploadBinaryConditional(
      path: 'attachments/x.bin',
      bytes: bytes,
    );

    final downloaded =
        await decorated.downloadBinary(path: 'attachments/x.bin');
    expect(downloaded, bytes,
        reason: '非文本字节维持 uploadBinary 的 base64 密文形态，'
            'downloadBinary 解密+解码后必须还原');
  });
}

/// 支持条件写的 fake storage：记录条件写调用并模拟对象存储。
class _ConditionalFakeStorage
    implements
        CloudStorageService,
        BinaryCapableStorage,
        ConditionalWriteStorage {
  final Map<String, String> stored = {};
  int conditionalWriteCount = 0;
  String? eTagGuard;

  @override
  bool get supportsConditionalWrite => true;

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    stored[path] = utf8.decode(bytes);
  }

  @override
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  }) async {
    conditionalWriteCount++;
    eTagGuard = ifMatchEtag;
    stored[path] = utf8.decode(bytes); // 还原 S3 侧「密文字节」的文本形态
    // metadata 忽略：本测试聚焦内容往返
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    stored[path] = data;
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    final s = stored[path];
    return s == null ? null : utf8.encode(s);
  }

  @override
  Future<String?> download({required String path}) async => stored[path];

  @override
  Future<void> delete({required String path}) async {
    stored.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async => stored.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async => null;
}
