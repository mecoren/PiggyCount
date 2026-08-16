import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../domain/encryption/encryption_service.dart';

/// 加密版 [CloudStorageService] 装饰器
///
/// 包装任意 [CloudStorageService] 实现（S3 / WebDAV / Supabase / iCloud），
/// 在上传/下载时自动加解密，对上层完全透明。
///
/// 行为契约：
/// - [upload]：调用 [EncryptionService.encrypt] 加密后传给 inner；
///   加密未开启时 encrypt 返回原文，等价于透传。
/// - [download]：从 inner 取回数据；为 null 时返回 null；
///   否则调用 [EncryptionService.decrypt]，按 magic header 自动识别密文/legacy 明文。
/// - [delete] / [list] / [exists] / [getMetadata]：完全透传，不接触加密。
///
/// 加密失败时（如密钥不可用）抛出 [EncryptionNotConfiguredException]；
/// 解密失败时（如密码错误、密文损坏）抛出 [DecryptionException]，
/// 由上层捕获后处理（弹密码错误对话框、引导重置等）。
class EncryptedCloudStorageService
    implements CloudStorageService, BinaryCapableStorage {
  final CloudStorageService inner;
  final EncryptionService encryptionService;

  EncryptedCloudStorageService({
    required this.inner,
    required this.encryptionService,
  });

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    // 加密未开启时 encrypt 返回原文，等价于透传
    final payload = await encryptionService.encrypt(data);
    await inner.upload(path: path, data: payload, metadata: metadata);
  }

  /// 二进制加密口径：字节 base64 封入文本信封后走既有字符串加密路径，
  /// 云端产物与现有同步文件同格式（BEECRYPT1: 密文 / 未开启时 base64 文本）。
  /// 注意：实现本接口后 CloudStorageBinaryExt 会分派到这里而非穿透 inner
  /// 的真字节路径 —— 加密场景下云端必然是密文，符合端到端加密预期。
  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    final payload = await encryptionService.encrypt(base64Encode(bytes));
    await inner.upload(path: path, data: payload, metadata: metadata);
  }

  @override
  Future<String?> download({required String path}) async {
    final data = await inner.download(path: path);
    if (data == null) return null;
    // decrypt 自动识别 BEECRYPT1: 密文和 legacy 明文
    return encryptionService.decrypt(data);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    final data = await inner.download(path: path);
    if (data == null) return null;
    final plain = await encryptionService.decrypt(data);
    return Uint8List.fromList(base64Decode(plain));
  }

  @override
  Future<void> delete({required String path}) async {
    await inner.delete(path: path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    return inner.list(path: path);
  }

  @override
  Future<bool> exists({required String path}) async {
    return inner.exists(path: path);
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    return inner.getMetadata(path: path);
  }
}
