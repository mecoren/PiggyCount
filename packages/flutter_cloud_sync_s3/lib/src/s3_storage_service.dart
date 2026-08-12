import 'dart:convert';
import 'dart:io';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 's3_client.dart';
import 's3_exceptions.dart';

/// S3 存储服务实现
class S3StorageService implements CloudStorageService {
  final S3Client client;
  final String bucket;

  /// 所有 S3 key 的统一前缀（例如 `'piggycount/'`）。
  ///
  /// 业务层用于在共享 bucket 中隔离应用数据：所有 key 会自动前置该前缀，
  /// [listFiles] 返回值会剥离前缀，使调用方始终看到逻辑路径，避免双前缀。
  /// 为空时行为与无前缀一致（向后兼容）。
  final String keyPrefix;

  S3StorageService(this.client, this.bucket, {String keyPrefix = ''})
      : keyPrefix = _normalizePrefix(keyPrefix);

  /// 规范化前缀：非空时确保以 `/` 结尾，避免 `piggycount` 与 `ledger.json`
  /// 直接拼接为 `piggycountledger.json`。
  static String _normalizePrefix(String prefix) {
    if (prefix.isEmpty) return '';
    return prefix.endsWith('/') ? prefix : '$prefix/';
  }

  Future<void> uploadFile(String localPath, String remotePath) async {
    try {
      final file = File(localPath);
      if (!await file.exists()) {
        throw CloudStorageException('File not found: $localPath');
      }

      // 读取文件
      final bytes = await file.readAsBytes();

      // 上传到 S3
      await client.putObject(
        bucket: bucket,
        key: _buildKey(remotePath),
        data: bytes,
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to upload file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to upload file: $e');
    }
  }

  Future<void> downloadFile(String remotePath, String localPath) async {
    try {
      // 从 S3 下载
      final bytes = await client.getObject(
        bucket: bucket,
        key: _buildKey(remotePath),
      );

      // 原子写入：先写临时文件再 rename 替换，避免下载中途异常
      // 导致目标文件被截断/损坏，使原有可用数据丢失
      final file = File(localPath);
      await file.parent.create(recursive: true);
      final tempPath = '$localPath.tmp';
      final tempFile = File(tempPath);
      await tempFile.writeAsBytes(bytes);
      await tempFile.rename(localPath);
    } on S3ObjectNotFoundException catch (e) {
      throw CloudStorageException('File not found: ${e.key}');
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to download file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to download file: $e');
    }
  }

  Future<void> deleteFile(String remotePath) async {
    try {
      await client.deleteObject(
        bucket: bucket,
        key: _buildKey(remotePath),
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to delete file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to delete file: $e');
    }
  }

  Future<bool> fileExists(String remotePath) async {
    try {
      return await client.headObject(
        bucket: bucket,
        key: _buildKey(remotePath),
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to check file existence: ${e.message}');
    }
  }

  Future<List<String>> listFiles(String remotePath) async {
    try {
      final prefix = _buildKey(remotePath);
      final keys = await client.listObjects(
        bucket: bucket,
        prefix: prefix.isEmpty ? null : prefix,
      );
      // 剥离 keyPrefix 后返回逻辑路径，调用方拿到的 key 可直接传回
      // upload/download/delete，由 _buildKey 再次前置前缀，避免双前缀。
      return keyPrefix.isEmpty
          ? keys
          : keys
              .map((k) => k.startsWith(keyPrefix)
                  ? k.substring(keyPrefix.length)
                  : k)
              .toList();
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to list files: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to list files: $e');
    }
  }

  Future<int> getFileSize(String remotePath) async {
    try {
      final info = await client.headObjectWithMetadata(
        bucket: bucket,
        key: _buildKey(remotePath),
      );
      if (!info.exists) {
        throw CloudStorageException('File not found: $remotePath');
      }
      return info.size ?? 0;
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to get file size: ${e.message}');
    }
  }

  Future<DateTime?> getLastModified(String remotePath) async {
    try {
      final info = await client.headObjectWithMetadata(
        bucket: bucket,
        key: _buildKey(remotePath),
      );
      if (!info.exists) return null;
      return info.lastModified;
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to get last modified: ${e.message}');
    }
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // 将字符串数据转为字节
      final bytes = utf8.encode(data);

      // 上传到 S3，C-01 修复：传递 metadata 作为 x-amz-meta-* 头
      await client.putObject(
        bucket: bucket,
        key: _buildKey(path),
        data: bytes,
        metadata: metadata,
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to upload file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to upload file: $e');
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      // 从 S3 下载
      final bytes = await client.getObject(
        bucket: bucket,
        key: _buildKey(path),
      );

      // 将字节转为字符串
      return utf8.decode(bytes);
    } on S3ObjectNotFoundException {
      return null;
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to download file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to download file: $e');
    }
  }

  @override
  Future<void> delete({required String path}) async {
    return deleteFile(path);
  }

  @override
  Future<bool> exists({required String path}) async {
    return fileExists(path);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      final prefix = _buildKey(path);
      final infos = await client.listObjectsDetailed(
        bucket: bucket,
        prefix: prefix.isEmpty ? null : prefix,
      );
      // 剥离 keyPrefix 后返回逻辑路径，与 listFiles 行为一致
      return infos
          .map((info) {
            final name = keyPrefix.isEmpty
                ? info.key
                : (info.key.startsWith(keyPrefix)
                    ? info.key.substring(keyPrefix.length)
                    : info.key);
            return CloudFile(
              name: name,
              path: name,
              size: info.size,
              lastModified: info.lastModified,
            );
          })
          .toList();
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to list files: ${e.message}');
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final info = await client.headObjectWithMetadata(
        bucket: bucket,
        key: _buildKey(path),
      );
      if (!info.exists) return null;

      // C-01 修复：返回 x-amz-meta-* 自定义元数据，
      // 使 CloudSyncManager 能通过 fingerprint 直接判断同步状态
      // 先去除末尾斜杠再提取文件名，避免目录路径返回空名
      final trimmed = path.endsWith('/') ? path.substring(0, path.length - 1) : path;
      final name = trimmed.isEmpty ? path : trimmed.split('/').last;
      return CloudFile(
        name: name,
        path: path,
        size: info.size,
        lastModified: info.lastModified,
        metadata: info.metadata,
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to get metadata: ${e.message}');
    }
  }

  /// 构造实际 S3 key：剥离开头斜杠后前置 [keyPrefix]。
  ///
  /// S3 的 Key 不应该以 / 开头；前置前缀实现 bucket 内目录隔离。
  String _buildKey(String path) {
    var key = path.startsWith('/') ? path.substring(1) : path;
    // 拒绝路径遍历尝试：含 .. 的路径可能逃逸 keyPrefix 隔离，
    // 访问到其他应用/前缀下的对象，造成越权读写
    if (key.contains('..')) {
      throw CloudStorageException('Invalid path containing ..: $path');
    }
    return keyPrefix.isEmpty ? key : '$keyPrefix$key';
  }
}
