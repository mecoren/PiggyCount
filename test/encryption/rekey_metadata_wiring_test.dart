// R1/R2 回归测试。
//
// R1（审计 S24 接线）：改密中途崩溃后检查点必须被自动恢复 —— 此前
// recoverPendingRekey 无任何生产调用方，云端永久停留在「部分新密钥」
// 状态。锁死语义：TransactionsSyncManager 初始化成功后自动尝试恢复，
// 恢复成功后重建加密装饰器。
//
// R2：密钥轮换后云端对象的 _encmeta 元数据信封必须随密钥一起轮换
//（旧钥解 → 新钥包），否则改密后所有 fingerprint 读取永久 miss
//（_unwrapMetadata 解不开旧信封 → 降级返回原始 map → 全量下载 + unknown
// 冲突循环）。附带锁死 enable 后首轮重加密（raw storage 直传）时明文
// 元数据包信封的审计 P1 语义。

import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/ciphertext_format.dart';
import 'package:piggycount/data/encryption/encrypted_cloud_storage.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart'
    show ReEncryptPartialFailureException;

/// 内存版 SecureKeyStorage（含审计 S24 崩溃注入位）
class _MemoryKeyStorage implements SecureKeyStorage {
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
  Future<String?> getRekeyCheckpoint() async =>
      _store['piggycount_enc_rekey_ckpt'];

  @override
  Future<void> clearRekeyCheckpoint() async {
    _store.remove('piggycount_enc_rekey_ckpt');
  }

  @override
  Future<void> clearAll() async => _store.clear();
}

/// 支持 metadata 的内存 storage（list/getMetadata 按文件名返回）
class _MetaFakeStorage implements CloudStorageService {
  final Map<String, String> files = {};
  final Map<String, Map<String, String>> meta = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    files[path] = data;
    if (metadata != null) meta[path] = Map.of(metadata);
  }

  @override
  Future<String?> download({required String path}) async => files[path];

  @override
  Future<void> delete({required String path}) async {
    files.remove(path);
    meta.remove(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async => [
        for (final k in files.keys)
          CloudFile(
            name: k,
            path: k,
            metadata:
                meta[k] == null ? null : Map<String, dynamic>.from(meta[k]!),
          ),
      ];

  @override
  Future<bool> exists({required String path}) async => files.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async =>
      files.containsKey(path)
          ? CloudFile(
              name: path,
              path: path,
              metadata: meta[path] == null
                  ? null
                  : Map<String, dynamic>.from(meta[path]!),
            )
          : null;
}

EncryptionServiceImpl _buildService(_MemoryKeyStorage storage) =>
    EncryptionServiceImpl(
      storage: storage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('R2：密钥轮换后 _encmeta 信封可用新密钥解开且内容不变', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryKeyStorage();
    final svc = _buildService(storage);
    await svc.enable(password: 'oldPassword1');
    final cloud = _MetaFakeStorage();

    // 模拟 E2EE 期间上传的文件：密文体 + _encmeta 信封元数据
    const plainJson = '{"version":9,"items":[]}';
    cloud.files['ledger_x.json'] = await svc.encrypt(plainJson);
    cloud.meta['ledger_x.json'] = {
      EncryptedCloudStorageService.encMetaKey: await svc.encrypt(jsonEncode({
        'fingerprint': 'fp-1',
        'uploadedAt': '2026-09-01T00:00:00Z',
      })),
    };

    await svc.changePasswordWithCloudReEncryption(
      oldPassword: 'oldPassword1',
      newPassword: 'newPassword1!',
      cloudStorage: cloud,
    );

    // 文件体已换新密钥且明文一致
    final newCiphertext = cloud.files['ledger_x.json']!;
    expect(CiphertextFormat.isEncrypted(newCiphertext), isTrue);
    expect(await svc.decrypt(newCiphertext), plainJson);

    // R2 核心：元数据信封随密钥轮换 —— 新钥可解、内容不变
    final newEnvelope =
        cloud.meta['ledger_x.json']![EncryptedCloudStorageService.encMetaKey]!;
    final unwrapped = await svc.decrypt(newEnvelope);
    final m = jsonDecode(unwrapped) as Map<String, dynamic>;
    expect(m['fingerprint'], 'fp-1',
        reason: 'R2 根因：信封未轮换时旧钥密文永久不可解，'
            'fingerprint 读取永久 miss → getStatus 退化为全量下载 + '
            'unknown 冲突循环');
  });

  test('R2：enable 后首轮重加密把明文元数据包成 _encmeta 信封', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryKeyStorage();
    final svc = _buildService(storage);
    final cloud = _MetaFakeStorage();

    // E2EE 开启前的 legacy 明文快照 + 明文元数据
    cloud.files['ledger_y.json'] = '{"version":6,"items":[]}';
    cloud.meta['ledger_y.json'] = {
      'fingerprint': 'fp-2',
      'uploadedAt': '2026-09-01T00:00:00Z',
    };

    await svc.enable(password: 'firstDevice1');
    final result = await svc.reEncryptExistingCloudData(cloudStorage: cloud);

    expect(result.failed, 0);
    expect(result.success, 1);
    expect(CiphertextFormat.isEncrypted(cloud.files['ledger_y.json']!), isTrue);

    // 审计 P1：raw storage 直传的重加密路径必须包信封，明文指纹不得驻留
    final m = cloud.meta['ledger_y.json']!;
    expect(m.containsKey(EncryptedCloudStorageService.encMetaKey), isTrue,
        reason: 'R2：不包信封则账本名/指纹/条数以明文驻留 '
            'S3 x-amz-meta-* / WebDAV sidecar');
    final unwrapped =
        await svc.decrypt(m[EncryptedCloudStorageService.encMetaKey]!);
    expect(
        (jsonDecode(unwrapped) as Map<String, dynamic>)['fingerprint'], 'fp-2');
  });

  test('R1：TSM 初始化成功后自动恢复滞留的改密检查点', () async {
    SharedPreferences.setMockInitialValues({});
    final storage = _MemoryKeyStorage();
    final svc = _buildService(storage);
    await svc.enable(password: 'oldPassword1');
    final cloud = _MetaFakeStorage();

    // 云端一份旧钥密文快照
    cloud.files['ledger_z.json'] =
        await svc.encrypt('{"version":6,"items":[]}');

    // 制造崩溃窗口：云端重加密完成、saveKey 抛错 → 检查点落盘滞留。
    // 注：SYNC-13 在 saveKey 失败时回滚云端并抛 ReEncryptPartialFailure-
    // Exception / StateError（版本按实现），两形态都构成「检查点滞留」
    // 前提，这里只需断言抛错而非具体类型。
    storage.failSaveKey = true;
    await expectLater(
      svc.changePasswordWithCloudReEncryption(
        oldPassword: 'oldPassword1',
        newPassword: 'newPassword1!',
        cloudStorage: cloud,
      ),
      throwsA(
          anyOf(isA<ReEncryptPartialFailureException>(), isA<StateError>())),
    );
    storage.failSaveKey = false;
    expect(await storage.getRekeyCheckpoint(), isNotNull,
        reason: '崩溃窗口必须留下检查点（S24 前提）');

    // R1 核心：TSM 初始化后自动恢复（此前零生产调用方）
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final manager = TransactionsSyncManager(
      config: const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 'test',
      ),
      db: db,
      repo: _DummyRepo(),
      encryptionService: svc,
    );
    manager.setSyncManagerForTesting(
      syncManager: CloudSyncManager<int>(
        provider: _FakeProvider(cloud),
        serializer: _NoopSerializer(),
      ),
      provider: _FakeProvider(cloud),
    );

    await manager.ensureInitialized();
    // 恢复为 fire-and-forget，等它落地
    await Future<void>.delayed(const Duration(milliseconds: 300));

    expect(await storage.getRekeyCheckpoint(), isNull,
        reason: 'R1 根因：检查点无人恢复时永久滞留，'
            '云端停在部分新密钥状态，下次改密/解密全部失败');
    expect(await svc.decrypt(cloud.files['ledger_z.json']!),
        '{"version":6,"items":[]}',
        reason: '恢复后云端密文应可用（已切到）新密钥解密');
  });
}

class _FakeProvider implements CloudProvider {
  @override
  final CloudStorageService storage;
  _FakeProvider(this.storage);

  @override
  String get providerId => 'fake';
  @override
  String get providerName => 'Fake';
  @override
  CloudAuthService get auth => _FakeAuth();
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
}

class _FakeAuth implements CloudAuthService {
  @override
  Future<CloudUser?> get currentUser async => const CloudUser(id: 'u');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopSerializer implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async => '';
  @override
  Future<int> deserialize(String data) async => 0;
  @override
  String fingerprint(String data) => '';
}

class _DummyRepo implements BaseRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
