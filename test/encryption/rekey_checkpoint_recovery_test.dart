// 审计 S24：改密原子检查点。
//
// 模拟 W1 崩溃窗口：云端重加密完成后、本地持久化新钥前进程崩溃
// （saveKey 抛错）→ 检查点已落盘 → 重启后 recoverPendingRekey 幂等续跑，
// 本地切到新密码，云端密文可解。无检查点时返回 false。
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/ciphertext_format.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';

import '../cloud/sync/_fakes/fake_piggycount_cloud_provider.dart'
    show FakePiggyCountCloudStorageService;

/// 内存版存储（含审计 S24 检查点位）
class MemoryKeyStorage implements SecureKeyStorage {
  final Map<String, String> _store = {};
  bool failSaveKey = false;

  @override
  Future<void> saveKey(List<int> key) async {
    if (failSaveKey) throw StateError('simulated crash before persist');
    _store['piggycount_enc_key'] = base64.encode(key);
  }

  @override
  Future<Uint8List?> getKey() async {
    final v = _store['piggycount_enc_key'];
    return v == null ? null : Uint8List.fromList(base64.decode(v));
  }

  @override
  Future<void> saveVerifier(List<int> verifier) async {
    _store['piggycount_enc_verifier'] = base64.encode(verifier);
  }

  @override
  Future<Uint8List?> getVerifier() async {
    final v = _store['piggycount_enc_verifier'];
    return v == null ? null : Uint8List.fromList(base64.decode(v));
  }

  @override
  Future<void> saveSalt(List<int> salt) async {
    _store['piggycount_enc_salt'] = base64.encode(salt);
  }

  @override
  Future<Uint8List?> getSalt() async {
    final v = _store['piggycount_enc_salt'];
    return v == null ? null : Uint8List.fromList(base64.decode(v));
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
  Future<void> clearAll() async => _store.clear();
}

EncryptionServiceImpl makeService(SecureKeyStorage storage) =>
    EncryptionServiceImpl(
      storage: storage,
      keyDerivation: const Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('S24: 崩溃窗口后检查点可恢复——续跑完成本地切换且云端可解', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = MemoryKeyStorage();
    final enc = makeService(storage);
    await enc.enable(password: 'OldPass123');

    // 云端一份旧钥密文快照
    final cloud = FakePiggyCountCloudStorageService();
    await cloud.upload(
      path: 'ledger_1.json',
      data: await enc.encrypt('{"version":6,"items":[]}'),
    );

    // 触发崩溃窗口：云端迁移完成、saveKey 抛错
    storage.failSaveKey = true;
    await expectLater(
      enc.changePasswordWithCloudReEncryption(
        oldPassword: 'OldPass123',
        newPassword: 'NewPass456',
        cloudStorage: cloud,
      ),
      throwsA(isA<StateError>()),
    );
    storage.failSaveKey = false;

    // 检查点必须已落盘（W1 窗口的唯一救命稻草）
    expect(await storage.getRekeyCheckpoint(), isNotNull);

    // 模拟重启：新实例读同一份存储；本地未切换，旧密码 verifier 仍匹配
    final enc2 = makeService(storage);
    expect(await enc2.verifyPassword('OldPass123'), isTrue);

    // 恢复：幂等续跑 + 本地持久化补齐
    final recovered = await enc2.recoverPendingRekey(cloudStorage: cloud);
    expect(recovered, isTrue);

    // 新密码在本地生效、旧密码失效
    expect(await enc2.verifyPassword('NewPass456'), isTrue);
    expect(await enc2.verifyPassword('OldPass123'), isFalse);

    // 检查点清除；云端密文可用新密码解开
    expect(await storage.getRekeyCheckpoint(), isNull);
    final raw = await cloud.download(path: 'ledger_1.json');
    expect(raw, isNotNull);
    expect(CiphertextFormat.isEncrypted(raw!), isTrue);
  });

  test('S24: 无检查点时 recoverPendingRekey 返回 false', () async {
    SharedPreferences.setMockInitialValues({});
    final enc = makeService(MemoryKeyStorage());
    final cloud = FakePiggyCountCloudStorageService();
    expect(await enc.recoverPendingRekey(cloudStorage: cloud), isFalse);
  });
}
