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

  const CloudFile({
    required this.name,
    required this.path,
    this.size,
    this.lastModified,
    this.metadata,
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
