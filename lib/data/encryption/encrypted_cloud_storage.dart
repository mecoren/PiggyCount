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
/// - [delete] / [list] / [exists]：完全透传，不接触加密。
/// - 元数据（审计 P1）：E2EE 开启时不允许业务元数据以明文上云
///   （S3 x-amz-meta-* / WebDAV sidecar 对存储服务商完全可见，
///   泄漏账本名/币种/余额/条数/指纹）。上传前把整个 metadata 序列化为
///   单个加密信封键 [_encMetaKey]；[getMetadata] 读到该键时解密还原。
///   - 未开启加密：行为与历史版本一致（明文透传，不包装）；
///   - 旧版写入的明文元数据（无信封键）：读取端原样返回（向后兼容）；
///   - 信封解密失败（密钥不匹配等）：降级返回原始 map，调用方按
///     「无指纹」走全量下载兜底，不抛异常阻断状态检查。
class EncryptedCloudStorageService
    implements CloudStorageService, BinaryCapableStorage {
  final CloudStorageService inner;
  final EncryptionService encryptionService;

  EncryptedCloudStorageService({
    required this.inner,
    required this.encryptionService,
  });

  /// 元数据加密信封键。
  ///
  /// S3 链路传输层会把 x-amz-meta-* 头名转小写、写入端也显式小写；
  /// WebDAV sidecar 保留原始键名。读取端一律大小写无关匹配以兼容两类后端。
  static const String _encMetaKey = '_encmeta';

  /// 上传前的元数据处理：
  /// - null/空 → 原样返回 null；
  /// - 加密未开启 → 原样透传（与历史行为一致）；
  /// - 加密开启 → 整包序列化加密进单个 [_encMetaKey] 信封。
  Future<Map<String, String>?> _wrapMetadata(Map<String, String>? metadata) async {
    if (metadata == null || metadata.isEmpty) return metadata;
    if (!await encryptionService.isEnabled) return metadata;
    final envelope = await encryptionService.encrypt(jsonEncode(metadata));
    return {_encMetaKey: envelope};
  }

  /// 读取端的元数据还原：
  /// - 无信封键（旧版明文元数据）→ 原样返回；
  /// - 有信封键且解密成功 → 返回解密后的原始键值对；
  /// - 解密失败（密钥不匹配/损坏）→ 降级返回原始 map，绝不抛异常
  ///   （getStatus 等调用方拿不到指纹会自动退回全量下载路径）。
  Future<Map<String, dynamic>?> _unwrapMetadata(
      Map<String, dynamic>? metadata) async {
    if (metadata == null || metadata.isEmpty) return metadata;

    String? envelope;
    for (final entry in metadata.entries) {
      if (entry.key.toLowerCase() == _encMetaKey) {
        envelope = entry.value?.toString();
        break;
      }
    }
    if (envelope == null) return metadata;

    try {
      // 密钥不可用时 decrypt 抛 EncryptionNotConfiguredException /
      // DecryptionException，统一落入下方降级分支
      final plain = await encryptionService.decrypt(envelope);
      final decoded = jsonDecode(plain);
      if (decoded is Map<String, dynamic>) {
        return decoded;
      }
      // 信封内容非对象（异常产物）：降级原样返回
      return metadata;
    } catch (_) {
      return metadata;
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    // 加密未开启时 encrypt 返回原文，等价于透传
    final payload = await encryptionService.encrypt(data);
    await inner.upload(
        path: path, data: payload, metadata: await _wrapMetadata(metadata));
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
    await inner.upload(
        path: path, data: payload, metadata: await _wrapMetadata(metadata));
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
    final file = await inner.getMetadata(path: path);
    if (file == null) return null;
    final unwrapped = await _unwrapMetadata(file.metadata);
    if (identical(unwrapped, file.metadata)) return file;
    return CloudFile(
      name: file.name,
      path: file.path,
      size: file.size,
      lastModified: file.lastModified,
      metadata: unwrapped,
    );
  }
}
