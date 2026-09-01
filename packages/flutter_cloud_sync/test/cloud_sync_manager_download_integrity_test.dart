import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 审计 M14：下载完整性校验的 TOCTOU 收窄回归。
///
/// 「下载内容」与「读元数据」是两次独立请求，两请求之间被并发上传时，
/// 旧实现会把合法新内容误判为损坏并硬失败。修复后首次不一致会重下内容
/// + 重读元数据再判一次：竞态自愈放行，真实脱钩仍硬失败。
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
      Map<String, dynamic>? metadata}) async {
    return _User.test;
  }

  @override
  Future<void> signOut() async {}
  @override
  Future<void> sendPasswordResetEmail({required String email}) async {}
  @override
  Future<void> resendEmailVerification({required String email}) async {}
}

/// 按「响应脚本」回放的存储假件：
/// - downloadResponses：每次 download 依次弹出；耗尽后重复最后一项。
/// - metadataFingerprints：每次 getMetadata 依次弹出（null = 无指纹字段）。
class _ScriptedStorage implements CloudStorageService {
  final List<String> downloadResponses;
  final List<String?> metadataFingerprints;
  int downloadCalls = 0;
  int metadataCalls = 0;

  _ScriptedStorage({
    required this.downloadResponses,
    required this.metadataFingerprints,
  });

  T _pick<T>(List<T> list) => list.length > 1 ? list.removeAt(0) : list.first;

  @override
  Future<String?> download({required String path}) async {
    downloadCalls++;
    return _pick(downloadResponses);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    metadataCalls++;
    final fp = _pick(metadataFingerprints);
    if (fp == null) return null;
    return CloudFile(name: path, path: path, metadata: {'fingerprint': fp});
  }

  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {}

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<CloudFile>> list({required String path}) async => const [];

  @override
  Future<bool> exists({required String path}) async => true;
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
  test('M14：首读不一致但重读自洽（并发上传竞态）→ 自愈放行新内容', () async {
    const oldContent = '{"id":1}';
    const newContent = '{"id":2}';
    final newFp = _Ser().fingerprint(newContent);

    // 时序：download#1 给旧内容 → metadata#1 已是新指纹（竞态窗口）
    //      → 重试 download#2 拿到新内容 → metadata#2 新指纹 → 自洽
    final storage = _ScriptedStorage(
      downloadResponses: [oldContent, newContent],
      metadataFingerprints: [newFp, newFp],
    );
    final manager = CloudSyncManager<int>(
        provider: _Provider(_Auth(), storage), serializer: _Ser());

    final result = await manager.download(path: 'a.json');

    expect(result, 2, reason: 'M14 前直接抛完整性失败，把合法新内容当损坏拒收');
    expect(storage.downloadCalls, 2);
  });

  test('M14：重读仍不一致（真实脱钩）→ 维持硬失败', () async {
    const staleContent = '{"id":1}';
    final unrelatedFp = _Ser().fingerprint('{"id":999}');
    // 内容恒为旧值、指纹恒为无关值 → 竞态重试也无法自洽
    final storage = _ScriptedStorage(
      downloadResponses: [staleContent],
      metadataFingerprints: [unrelatedFp],
    );
    final manager = CloudSyncManager<int>(
        provider: _Provider(_Auth(), storage), serializer: _Ser());

    await expectLater(
      manager.download(path: 'a.json'),
      throwsA(isA<CloudStorageException>()),
    );
    expect(storage.downloadCalls, 2, reason: '恰好重试一次');
  });

  test('M14 对照：元数据无指纹字段 → 不校验直接通过', () async {
    final storage = _ScriptedStorage(
      downloadResponses: ['{"id":7}'],
      metadataFingerprints: [null],
    );
    final manager = CloudSyncManager<int>(
        provider: _Provider(_Auth(), storage), serializer: _Ser());

    expect(await manager.download(path: 'a.json'), 7);
    expect(storage.metadataCalls, 1, reason: '无指纹时不触发重试');
  });
}
