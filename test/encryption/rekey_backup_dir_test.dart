// 审计 BKV-2 回归测试：rekey（改密）与 enable 后首轮全量重加密的目标
// 集合必须覆盖云端备份目录 piggycount-bak/。
//
// 根因：两处 targets 集合此前只收 ledger_*.json + attachments/*，备份
// ZIP（E2EE 下为旧钥密文）在改密后永久不可解密、enable 后保持明文——
// 灾难恢复能力静默失效，且报错形态与网络故障难区分。
//
// 锁死语义：
// 1. rekey 后备份 ZIP 用新钥可解、解密产物与原 ZIP 逐字节一致；
// 2. enable 后明文备份 ZIP 被加密且可解回原内容；
// 3. 备份走 base64 信封口径（原生二进制不是合法 UTF-8），恢复链路
//    downloadBinaryOrFallback 读回的明文字节即原 ZIP。

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/encryption/aes_gcm_cipher.dart';
import 'package:piggycount/data/encryption/argon2_key_derivation.dart';
import 'package:piggycount/data/encryption/ciphertext_format.dart';
import 'package:piggycount/data/encryption/encryption_service_impl.dart';
import 'package:piggycount/data/encryption/secure_key_storage.dart';

/// 内存版 SecureKeyStorage（对齐 rekey_checkpoint_recovery_test）
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

/// 模拟「备份 ZIP 以二进制密文上云」的 storage：downloadBinary 返回
/// 装饰器 uploadBinary 写入的 utf8(密文信封) 字节（S3/WebDAV 真字节
/// 路径的云端形态），download 返回同一信封的字符串形态。
class _BinaryFakeStorage implements CloudStorageService, BinaryCapableStorage {
  /// 字节保真存储（对齐真实后端）：文本 upload 存 utf8(data) 字节，
  /// 二进制 uploadBinary 存原始字节。download/downloadBinary 返回同一
  /// 字节的不同形态视图。
  final Map<String, List<int>> _bytes = {};

  /// 便捷视图：text 形态（仅当对象字节是合法 UTF-8，对齐真实后端
  /// 文本 download 的行为——密文信封恒为合法 UTF-8）。
  String? get(String path) {
    final b = _bytes[path];
    if (b == null) return null;
    try {
      return utf8.decode(b);
    } catch (_) {
      return null;
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    _bytes[path] = utf8.encode(data);
  }

  @override
  Future<String?> download({required String path}) async => get(path);

  @override
  Future<void> delete({required String path}) async => _bytes.remove(path);

  @override
  Future<List<CloudFile>> list({required String path}) async {
    // 目录语义 list：返回该目录一级之下的条目名（不带目录前缀），
    // 前缀 '' 表示根目录。对齐 WebDAV readDir depth 1 / S3 CommonPrefix。
    // path 归一化:入参可能带也可能不带尾斜杠(S3 传 'dir/' 形态)
    final normalized = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
    final prefix = normalized.isEmpty ? '' : '$normalized/';
    final names = <String>[];
    for (final k in _bytes.keys) {
      if (!k.startsWith(prefix)) continue;
      final rest = k.substring(prefix.length);
      if (rest.isEmpty) continue;
      final slash = rest.indexOf('/');
      names.add(slash == -1 ? rest : rest.substring(0, slash + 1));
    }
    final uniq = names.toSet().toList();
    return List.unmodifiable(
        [for (final n in uniq) CloudFile(name: n, path: '$prefix$n')]);
  }

  @override
  Future<bool> exists({required String path}) async => _bytes.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async =>
      _bytes.containsKey(path) ? CloudFile(name: path, path: path) : null;

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    _bytes[path] = List<int>.from(bytes);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async =>
      _bytes.containsKey(path) ? Uint8List.fromList(_bytes[path]!) : null;
}

/// 构造一份「不可 UTF-8 解码」的原生 ZIP 字节（含 0xFF/0x00 高位字节
/// 序列），保证测试对象与真实备份 ZIP 同形态：走 base64 信封口径。
Uint8List _fakeZipBytes() => Uint8List.fromList(<int>[
      0x50, 0x4B, 0x03, 0x04, // ZIP magic
      0xFF, 0xFE, 0x00, 0xD8, 0xFF, 0xE0, // 非文本二进制载荷
      0x00, 0x01, 0x02, 0x7F, 0x80,
    ]);

EncryptionServiceImpl _buildService(_MemoryKeyStorage storage) =>
    EncryptionServiceImpl(
      storage: storage,
      keyDerivation: Argon2KeyDerivation.forTesting(),
      cipher: AesGcmCipher(),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('BKV-2：rekey（改密）目标集合覆盖 piggycount-bak/', () {
    test('改密后备份 ZIP 换新钥密文，解密产物与原 ZIP 逐字节一致', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _MemoryKeyStorage();
      final svc = _buildService(storage);
      await svc.enable(password: 'oldPassword1');
      final cloud = _BinaryFakeStorage();

      // E2EE 期间上传的备份 ZIP：装饰器 uploadBinary 口径
      // encrypt(base64(zipBytes)) 的密文信封，走真字节通道
      final zipBytes = _fakeZipBytes();
      await cloud.upload(
        path: 'piggycount-bak/PiggyCount-2026-09-14.zip',
        data: await svc.encrypt(base64Encode(zipBytes)));
      // 一份普通账本快照（保证 rekey 主链路也在跑）
      await cloud.upload(
        path: 'ledger_1.json',
        data: await svc.encrypt('{"version":9,"items":[]}'));

      await svc.changePasswordWithCloudReEncryption(
        oldPassword: 'oldPassword1',
        newPassword: 'newPassword1!',
        cloudStorage: cloud,
      );

      // 同一 svc 实例的内存态密钥已切到新钥
      expect(await svc.verifyPassword('newPassword1!'), isTrue);

      // 账本快照仍可用新密码解开
      final ledgerRaw = (await cloud.download(path: 'ledger_1.json'))!;
      expect(CiphertextFormat.isEncrypted(ledgerRaw), isTrue);
      expect(await svc.decrypt(ledgerRaw), '{"version":9,"items":[]}');

      // 核心断言：备份 ZIP 已换新钥密文（salt 必然轮换），且解密产物
      // 为 base64 明文 → 解码后与原 ZIP 逐字节一致
      final bakPath = 'piggycount-bak/PiggyCount-2026-09-14.zip';
      final bakCipher = (await cloud.download(path: bakPath))!;
      expect(CiphertextFormat.isEncrypted(bakCipher), isTrue,
          reason: 'BKV-2 根因：rekey 不覆盖备份目录，'
              '改密后历史备份永久不可解密');
      final decodedPlain = await svc.decrypt(bakCipher);
      expect(Uint8List.fromList(base64Decode(decodedPlain)), zipBytes,
          reason: '备份内容必须经 rekey 无损迁移');
    });

    test('续跑恢复（recoverPendingRekey）同样覆盖备份目录', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _MemoryKeyStorage();
      final svc = _buildService(storage);
      await svc.enable(password: 'oldPassword1');
      final cloud = _BinaryFakeStorage();

      final zipBytes = _fakeZipBytes();
      await cloud.upload(
        path: 'piggycount-bak/PiggyCount-2026-09-13.zip',
        data: await svc.encrypt(base64Encode(zipBytes)));

      // 制造真实崩溃窗口：saveKey 抛错 → 云端已换新钥、本地仍旧钥、
      // 检查点滞留 → recoverPendingRekey 幂等续跑
      storage.failSaveKey = true;
      await expectLater(
        svc.changePasswordWithCloudReEncryption(
          oldPassword: 'oldPassword1',
          newPassword: 'newPassword1!',
          cloudStorage: cloud,
        ),
        throwsA(isA<StateError>()),
      );
      storage.failSaveKey = false;
      expect(await storage.getRekeyCheckpoint(), isNotNull);

      // 重启模拟：同一 secure storage 新实例，旧密码仍可用
      final svc2 = _buildService(storage);
      expect(await svc2.verifyPassword('oldPassword1'), isTrue);

      // 恢复：备份目录同样被续跑覆盖
      final recovered = await svc2.recoverPendingRekey(cloudStorage: cloud);
      expect(recovered, isTrue);
      expect(await storage.getRekeyCheckpoint(), isNull);

      // 新密码生效，备份 ZIP 新钥可解、内容无损
      expect(await svc2.verifyPassword('newPassword1!'), isTrue);
      final bakCipher = (await cloud.download(
          path: 'piggycount-bak/PiggyCount-2026-09-13.zip'))!;
      final plain = await svc2.decrypt(bakCipher);
      expect(Uint8List.fromList(base64Decode(plain)), zipBytes);
    });
  });

  group('BKV-2：enable 后首轮全量重加密覆盖 piggycount-bak/', () {
    test('明文备份 ZIP 被加密且可解回原内容', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _MemoryKeyStorage();
      final svc = _buildService(storage);
      final cloud = _BinaryFakeStorage();

      // E2EE 开启前的云端状态：明文账本 + 明文 base64 形态的备份 ZIP
      // （非 BinaryCapable 时代的 uploadBinaryOrFallback 走文本 upload）
      final zipBytes = _fakeZipBytes();
      await cloud.upload(path: 'ledger_1.json', data: '{"version":9,"items":[]}');
      await cloud.upload(
        path: 'piggycount-bak/PiggyCount-2026-09-14.zip',
        data: base64Encode(zipBytes));

      await svc.enable(password: 'enablePassword1');
      final result = await svc.reEncryptExistingCloudData(
        cloudStorage: cloud,
      );

      expect(result.failed, 0, reason: '重加密不应有失败项');

      // 账本快照：密文且可解
      final ledgerRaw = (await cloud.download(path: 'ledger_1.json'))!;
      expect(CiphertextFormat.isEncrypted(ledgerRaw), isTrue);
      expect(await svc.decrypt(ledgerRaw), '{"version":9,"items":[]}');

      // 备份 ZIP：密文、可解、内容无损
      final bakPath = 'piggycount-bak/PiggyCount-2026-09-14.zip';
      final bakCipher = (await cloud.download(path: bakPath))!;
      expect(CiphertextFormat.isEncrypted(bakCipher), isTrue,
          reason: 'BKV-2 根因：enable 后明文备份不上密，'
              'E2EE 承诺对备份内容不成立');
      final plain = await svc.decrypt(bakCipher);
      expect(Uint8List.fromList(base64Decode(plain)), zipBytes);
    });

    test('原生二进制形态的明文备份 ZIP（非 base64 文本）同样被纳入', () async {
      SharedPreferences.setMockInitialValues({});
      final storage = _MemoryKeyStorage();
      final svc = _buildService(storage);
      final cloud = _BinaryFakeStorage();

      // E2EE 开启前经 BinaryCapable 后端直接上传的原生字节
      final zipBytes = _fakeZipBytes();
      await cloud.uploadBinary(
          path: 'piggycount-bak/PiggyCount-2026-09-12.zip', bytes: zipBytes);

      await svc.enable(password: 'enablePassword1');
      final result = await svc.reEncryptExistingCloudData(
        cloudStorage: cloud,
      );

      expect(result.failed, 0);
      final bakPath = 'piggycount-bak/PiggyCount-2026-09-12.zip';
      final bakCipher = (await cloud.download(path: bakPath))!;
      expect(CiphertextFormat.isEncrypted(bakCipher), isTrue);
      final plain = await svc.decrypt(bakCipher);
      expect(Uint8List.fromList(base64Decode(plain)), zipBytes,
          reason: '原生二进制按 uploadBinary 信封口径 base64 化后加密，'
              '装饰器 downloadBinary 读回原字节');
    });
  });
}
