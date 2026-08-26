import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'exceptions.dart';

/// Represents a file in cloud storage
@immutable
class CloudFile {
  /// File name
  final String name;

  /// Full file path
  final String path;

  /// File size in bytes (optional)
  final int? size;

  /// Last modified timestamp (optional)
  final DateTime? lastModified;

  /// Custom metadata (optional)
  ///
  /// Used to store fingerprint, version, etc.
  final Map<String, dynamic>? metadata;

  /// Entity tag (optional)
  ///
  /// 方案C（并发全面加固）：后端能提供 ETag 时透出（S3 来自
  /// PUT/GET/HEAD 响应头；WebDAV 来自 PROPFIND 的 getetag 属性），
  /// 供 [ConditionalWriteStorage] 做乐观并发控制。
  /// 无法获取 ETag 的后端为 null，调用方必须容忍 null 并退化为
  /// "读指纹比对 + 写后校验"的弱一致路径。
  final String? eTag;

  const CloudFile({
    required this.name,
    required this.path,
    this.size,
    this.lastModified,
    this.metadata,
    this.eTag,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CloudFile &&
          runtimeType == other.runtimeType &&
          path == other.path;

  @override
  int get hashCode => path.hashCode;

  @override
  String toString() => 'CloudFile(name: $name, path: $path, size: $size)';
}

/// Abstract interface for cloud storage services
abstract class CloudStorageService {
  /// Upload data to cloud storage
  ///
  /// [path] - File path (e.g., 'users/123/data.json')
  /// [data] - File content as string
  /// [metadata] - Optional metadata map
  ///
  /// Throws [CloudStorageException] if upload fails.
  /// If file exists, it will be overwritten (upsert semantics).
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  });

  /// Download data from cloud storage
  ///
  /// [path] - File path
  ///
  /// Returns file content as string, or null if file doesn't exist.
  /// Throws [CloudStorageException] if download fails (except 404).
  Future<String?> download({required String path});

  /// Delete file from cloud storage
  ///
  /// [path] - File path
  ///
  /// Throws [CloudStorageException] if deletion fails.
  /// Should be idempotent (no error if file doesn't exist).
  Future<void> delete({required String path});

  /// List files in a directory
  ///
  /// [path] - Directory path (e.g., 'users/123/')
  ///
  /// Returns list of files in the directory.
  /// Throws [CloudStorageException] if listing fails.
  ///
  /// ⚠️ 后端语义差异（调用方必须知晓，勿依赖跨后端一致的递归行为）：
  /// - S3：ListObjectsV2 无 delimiter —— 返回前缀下**所有层级**的 key
  ///   （递归扁平化），嵌套子目录中的文件也会出现；
  /// - WebDAV：PROPFIND Depth 1 —— 仅返回该目录**直接子项**，
  ///   子目录内容不会出现。
  /// 当前业务约定快照/附件/备份均存放于扁平路径（如
  /// `ledger_<id>.json`、`attachments/<sha>.bin` 一级目录），
  /// 两后端在该约定下行为一致；若未来引入更深层级，须逐调用方复核。
  Future<List<CloudFile>> list({required String path});

  /// Check if file exists
  ///
  /// [path] - File path
  ///
  /// Returns true if file exists, false otherwise.
  /// Throws [CloudStorageException] if check fails.
  Future<bool> exists({required String path});

  /// Get file metadata
  ///
  /// [path] - File path
  ///
  /// Returns file metadata, or null if file doesn't exist.
  /// Throws [CloudStorageException] if operation fails.
  Future<CloudFile?> getMetadata({required String path});
}

/// No-op implementation for local-only mode
class NoopStorageService implements CloudStorageService {
  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<String?> download({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<void> delete({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<bool> exists({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    throw UnsupportedError('Storage is not configured');
  }
}

/// 可选能力接口：支持原生二进制读写的存储后端。
///
/// [CloudStorageService.upload] 只接受 String，二进制内容（如 ZIP 备份）
/// 传统上需 base64 为文本传输，导致云端文件无法被外部工具直接识别。
/// 后端实现本接口后，[CloudStorageBinaryExt] 会自动改走真字节路径；
/// 未实现的后端无感知，继续走 base64 兜底（行为与历史版本一致）。
abstract class BinaryCapableStorage {
  /// 以原始字节上传（同 upsert 语义：存在即覆盖）
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  });

  /// 下载原始字节；文件不存在返回 null。
  /// 返回内容约定为 uploadBinary 上传的原始字节（不做任何文本编码）。
  Future<Uint8List?> downloadBinary({required String path});
}

/// 可选能力接口：支持条件写（乐观并发控制）的存储后端。
///
/// 方案C（并发全面加固）：普通 [upload] 是盲覆盖（last-writer-wins），
/// 两台设备并发「读指纹 → 写」会静默丢失一方更新。实现本接口的后端
/// 可把「读到的远端状态」作为前置条件原子地下推到写请求：
///
/// - S3：`If-Match: <etag>` / `If-None-Match: *`，服务器端原子判定，
///   失败返回 412 → 抛 [CloudPreconditionFailedException]
/// - WebDAV：无标准条件 PUT（webdav_client 不透传 If-Match），实现方
///   以「上传前重取 eTag 比对」近似，窗口显著缩小但非原子 —— 调用方
///   仍需配合 manager 层的写后校验兜底
abstract class ConditionalWriteStorage {
  /// 是否真正支持条件写。
  ///
  /// 装饰器（如端到端加密层）必须按 inner 的能力**如实**申报：
  /// inner 不支持时返回 false，调用方据此退化为盲上传 + 写后校验。
  /// 直接后端（S3/WebDAV）恒为 true。
  bool get supportsConditionalWrite;

  /// 带前置条件的字节上传。
  ///
  /// - [ifMatchEtag] 非空时：仅当远端当前 ETag 与之相等才写入，
  ///   否则抛 [CloudPreconditionFailedException]（远端不存在同样算
  ///   条件失败）
  /// - [ifNoneMatch] 为 true 时：仅当远端**不存在**该对象才写入
  ///   （create-only），已存在抛 [CloudPreconditionFailedException]；
  ///   与 [ifMatchEtag] 互斥，同时传入抛 ArgumentError
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  });
}

/// 条件写能力解析：穿透常见装饰器形态直接问实例本身。
///
/// 调用方（manager/应用层）统一用它判定，而不是裸 `is` 检查 ——
/// 加密装饰器实现了接口但能力取决于 inner，靠 [ConditionalWriteStorage.supportsConditionalWrite]
/// 如实申报。
extension CloudStorageConditionalExt on CloudStorageService {
  ConditionalWriteStorage? get conditionalOrNull {
    if (this is ConditionalWriteStorage) {
      final c = this as ConditionalWriteStorage;
      return c.supportsConditionalWrite ? c : null;
    }
    return null;
  }
}

/// 二进制读写入口：按后端能力自动分派。
///
/// - `is BinaryCapableStorage` → 后端原生字节路径（云端文件为真实二进制）
/// - 否则 → base64 文本兜底（与既有字符串传输行为完全一致）
extension CloudStorageBinaryExt on CloudStorageService {
  Future<void> uploadBinaryOrFallback({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    // 显式 cast：extension receiver 上的 is 检查不触发局部类型提升
    if (this is BinaryCapableStorage) {
      final bin = this as BinaryCapableStorage;
      await bin.uploadBinary(path: path, bytes: bytes, metadata: metadata);
      return;
    }
    await upload(path: path, data: base64Encode(bytes), metadata: metadata);
  }

  Future<Uint8List?> downloadBinaryOrFallback({required String path}) async {
    if (this is BinaryCapableStorage) {
      final bin = this as BinaryCapableStorage;
      return bin.downloadBinary(path: path);
    }
    final text = await download(path: path);
    if (text == null) return null;
    // 非法 base64 统一包装为存储异常：上层（如备份恢复）依赖捕获后
    // 转译为「文件损坏」语义，裸 FormatException 会穿透错误处理边界
    try {
      return Uint8List.fromList(base64Decode(text));
    } catch (e) {
      throw CloudStorageException('Invalid base64 payload: $path', e);
    }
  }
}
