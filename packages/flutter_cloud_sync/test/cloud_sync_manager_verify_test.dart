import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 方案C（并发全面加固）：CloudSyncManager 条件写分派与写后校验回归
class _User {
  static CloudUser get test => const CloudUser(id: 'u1', email: null);
}

class _Ser implements DataSerializer<int> {
  @override
  Future<String> serialize(int data) async => jsonEncode({'id': data});
  @override
  Future<int> deserialize(String data) async =>
      (jsonDecode(data) as Map<String, dynamic>)['id'] as int;
  @override
  String fingerprint(String data) =>
      sha256.convert(utf8.encode(data)).toString();
}

class _Auth implements CloudAuthService {
  @override
  Future<CloudUser?> get currentUser async => _User.test;
  @override
  Stream<CloudUser?> get authStateChanges => Stream.value(_User.test);
  @override
  Future<CloudUser> signInWithEmail(
      {required String email, required String password}) async =>
      _User.test;
  @override
  Future<CloudUser> signUpWithEmail(
      {required String email,
      required String password,
      Map<String, dynamic>? metadata}) async =>
      _User.test;
  @override
  Future<void> signOut() async {}
  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}
  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

class _File {
  _File(this.data, this.metadata, [this.eTag]);
  String data;
  Map<String, dynamic>? metadata;
  final String? eTag;
}

/// 普通存储（无条件写能力）
class _PlainStorage implements CloudStorageService {
  final files = <String, _File>{};
  int uploadCount = 0;

  /// 模拟「上传后云端被并发改写」：upload 完成后立刻替换云端内容
  void Function(_PlainStorage storage, String path)? afterUpload;

  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {
    uploadCount++;
    files[path] = _File(data, metadata);
    afterUpload?.call(this, path);
  }

  @override
  Future<String?> download({required String path}) async =>
      files[path]?.data;

  @override
  Future<void> delete({required String path}) async => files.remove(path);

  @override
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async =>
      files.containsKey(path);

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    final f = files[path];
    if (f == null) return null;
    return CloudFile(
        name: path, path: path, metadata: f.metadata, eTag: f.eTag);
  }
}

/// 支持条件写的存储
class _ConditionalStorage extends _PlainStorage
    implements BinaryCapableStorage, ConditionalWriteStorage {
  final conditionalCalls = <String?>[];

  /// 非 null 时模拟远端 ETag 已变化 → 抛前置条件失败（写入未落盘）
  String? failIfMatchNotEqual;

  @override
  bool get supportsConditionalWrite => true;

  @override
  Future<void> uploadBinaryConditional(
      {required String path,
      required List<int> bytes,
      Map<String, String>? metadata,
      String? ifMatchEtag,
      bool ifNoneMatch = false}) async {
    conditionalCalls.add(ifMatchEtag);
    if (failIfMatchNotEqual != null && ifMatchEtag != failIfMatchNotEqual) {
      throw CloudPreconditionFailedException(path);
    }
    await upload(path: path, data: utf8.decode(bytes), metadata: metadata);
  }

  @override
  Future<void> uploadBinary(
      {required String path,
      required List<int> bytes,
      Map<String, String>? metadata}) async {
    await upload(path: path, data: utf8.decode(bytes), metadata: metadata);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async =>
      files[path] == null ? null : utf8.encode(files[path]!.data) as Uint8List;
}

class _Provider implements CloudProvider {
  _Provider(this._auth, this._storage);
  final CloudAuthService _auth;
  final CloudStorageService _storage;
  @override
  CloudAuthService get auth => _auth;
  @override
  CloudStorageService get storage => _storage;
  @override
  String get providerId => 'test';
  @override
  String get providerName => 'Test';
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
}

void main() {
  group('方案C：manager.upload 条件写分派', () {
    test('后端支持条件写时 ifMatchEtag 走条件上传路径', () async {
      final storage = _ConditionalStorage();
      final manager = CloudSyncManager<int>(
          provider: _Provider(_Auth(), storage), serializer: _Ser());

      await manager.upload(data: 1, path: 'a.json', ifMatchEtag: 'etag-1');

      expect(storage.conditionalCalls, ['etag-1']);
      expect(storage.files.containsKey('a.json'), isTrue);
    });

    test('条件不满足（412）→ CloudPreconditionFailedException 原样上抛',
        () async {
      final storage = _ConditionalStorage()
        ..failIfMatchNotEqual = 'current-etag';
      final manager = CloudSyncManager<int>(
          provider: _Provider(_Auth(), storage), serializer: _Ser());

      await expectLater(
        manager.upload(data: 1, path: 'a.json', ifMatchEtag: 'stale'),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('后端不支持条件写时退化为盲上传（不抛错）', () async {
      final storage = _PlainStorage();
      final manager = CloudSyncManager<int>(
          provider: _Provider(_Auth(), storage), serializer: _Ser());

      await manager.upload(data: 1, path: 'a.json', ifMatchEtag: 'etag-1');

      expect(storage.uploadCount, 1);
      expect(storage.files.containsKey('a.json'), isTrue);
    });
  });

  group('方案C：manager.upload 写后校验', () {
    test('上传后指纹一致 → 正常完成', () async {
      final storage = _PlainStorage();
      final manager = CloudSyncManager<int>(
          provider: _Provider(_Auth(), storage), serializer: _Ser());

      await manager.upload(data: 1, path: 'a.json');
      expect(storage.files['a.json'], isNotNull);
    });

    test('上传后内容被并发覆盖 → 不硬失败但状态缓存失效（下次 getStatus 重查）',
        () async {
      final storage = _PlainStorage();
      // 模拟网关在 PUT 落盘后、写后校验读取前，云端被其他设备覆盖
      storage.afterUpload = (s, path) {
        final f = s.files[path]!;
        s.files[path] = _File('{"id":999}', f.metadata);
      };
      final manager = CloudSyncManager<int>(
          provider: _Provider(_Auth(), storage), serializer: _Ser());

      // 不应抛出（可用性优先），但内部已记录错误并失效缓存
      await manager.upload(data: 1, path: 'a.json');

      // 缓存失效的直接可观测效果：getStatus 强制走真实探测路径而非缓存
      final status = await manager.getStatus(path: 'a.json');
      expect(status.cloudFingerprint, isNotNull);
    });
  });
}
