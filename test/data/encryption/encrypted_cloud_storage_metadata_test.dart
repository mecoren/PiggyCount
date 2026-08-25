import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/encryption/encrypted_cloud_storage.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';

/// 捕获型假存储：记录 upload 的 metadata，getMetadata 回放已存内容。
class _CapturingStorage implements CloudStorageService {
  final uploaded = <String, ({String data, Map<String, String>? metadata})>{};

  /// getMetadata 回放时对键名施加的变换（模拟传输层小写化等）
  String Function(String key)? keyTransform;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    uploaded[path] = (data: data, metadata: metadata);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    final entry = uploaded[path];
    if (entry == null) return null;
    Map<String, dynamic>? meta;
    if (entry.metadata != null) {
      meta = {
        for (final e in entry.metadata!.entries)
          keyTransform != null ? keyTransform!(e.key) : e.key: e.value,
      };
    }
    return CloudFile(name: path, path: path, size: 1, metadata: meta);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 可逆假加密（开启态）：`XENC:<base64>` 信封；非信封输入解密时抛异常。
class _EnabledEncryption implements EncryptionService {
  @override
  Future<bool> get isEnabled => Future.value(true);

  @override
  Future<String> encrypt(String plaintext) =>
      Future.value('XENC:${base64Encode(utf8.encode(plaintext))}');

  @override
  Future<String> decrypt(String ciphertext) {
    if (!ciphertext.startsWith('XENC:')) {
      throw const DecryptionException('not an XENC payload');
    }
    return Future.value(
        utf8.decode(base64Decode(ciphertext.substring('XENC:'.length))));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 关闭态假加密：encrypt/decrypt 原样透传（与真实实现的历史行为一致）。
class _DisabledEncryption implements EncryptionService {
  @override
  Future<bool> get isEnabled => Future.value(false);

  @override
  Future<String> encrypt(String plaintext) => Future.value(plaintext);

  @override
  Future<String> decrypt(String ciphertext) => Future.value(ciphertext);

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  const sampleMetadata = {
    'fingerprint': 'abc123',
    'ledgerName': '现金账本',
    'currency': 'CNY',
    'count': '42',
    'balance': '1234.56',
    'uploadedAt': '2026-08-25T00:00:00Z',
  };

  group('EncryptedCloudStorageService 元数据加密（审计 P1）', () {
    test('E2EE 开启：上传时元数据整包加密为单个信封键，明文键不再上云', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await svc.upload(path: 'ledger_x.json', data: '{}', metadata: sampleMetadata);

      final sent = storage.uploaded['ledger_x.json']!.metadata!;
      expect(sent.keys, ['_encmeta']);
      // 信封值是密文，不含任何明文键值对痕迹
      expect(sent['_encmeta'], startsWith('XENC:'));
      for (final plain in sampleMetadata.values) {
        expect(sent.values.join(), isNot(contains(plain)));
      }
    });

    test('E2EE 开启：getMetadata 解封信封还原原始键值对', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await svc.upload(path: 'ledger_x.json', data: '{}', metadata: sampleMetadata);
      final cf = await svc.getMetadata(path: 'ledger_x.json');

      expect(cf!.metadata, sampleMetadata);
    });

    test('E2EE 开启：读取端大小写无关匹配信封键（兼容网关改写头名大小写）', () async {
      final storage = _CapturingStorage()..keyTransform = (k) => k.toUpperCase();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await svc.upload(path: 'ledger_x.json', data: '{}', metadata: sampleMetadata);
      final cf = await svc.getMetadata(path: 'ledger_x.json');

      expect(cf!.metadata, sampleMetadata);
    });

    test('uploadBinary 与 upload 同口径包装元数据', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await svc.uploadBinary(
          path: 'attachments/a.bin',
          bytes: [1, 2, 3],
          metadata: {'fingerprint': 'zzz'});

      final sent = storage.uploaded['attachments/a.bin']!.metadata!;
      expect(sent.keys, ['_encmeta']);
    });

    test('E2EE 关闭：元数据明文透传（历史行为不变）', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _DisabledEncryption());

      await svc.upload(path: 'ledger_x.json', data: '{}', metadata: sampleMetadata);

      final sent = storage.uploaded['ledger_x.json']!.metadata;
      expect(sent, sampleMetadata);
      expect(sent!.containsKey('_encmeta'), isFalse);
    });

    test('旧版明文元数据（无信封键）：getMetadata 原样返回，不破坏向后兼容', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      // 直接注入旧版写入的明文数据
      await storage.upload(path: 'legacy.json', data: '{}', metadata: sampleMetadata);

      final cf = await svc.getMetadata(path: 'legacy.json');
      expect(cf!.metadata, sampleMetadata);
    });

    test('信封损坏（密钥不匹配等）：getMetadata 降级返回原始 map，不抛异常', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await storage.upload(path: 'broken.json', data: '{}',
          metadata: {'_encmeta': 'XENC:not-valid-base64!!'});

      final cf = await svc.getMetadata(path: 'broken.json');
      expect(cf, isNotNull);
      expect(cf!.metadata, {'_encmeta': 'XENC:not-valid-base64!!'});
    });

    test('无元数据上传不受影响', () async {
      final storage = _CapturingStorage();
      final svc = EncryptedCloudStorageService(
          inner: storage, encryptionService: _EnabledEncryption());

      await svc.upload(path: 'plain.json', data: '{}');

      expect(storage.uploaded['plain.json']!.metadata, isNull);
    });
  });
}
