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

  @override
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

  @override
  Future<void> downloadFile(String remotePath, String localPath) async {
    try {
      // 从 S3 下载
      final bytes = await client.getObject(
        bucket: bucket,
        key: _buildKey(remotePath),
      );

      // 写入本地文件
      final file = File(localPath);
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes);
    } on S3ObjectNotFoundException catch (e) {
      throw CloudStorageException('File not found: ${e.key}');
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to download file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to download file: $e');
    }
  }

  @override
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

  @override
  Future<bool> fileExists(String remotePath) async {
    try {
      return await client.headObject(
        bucket: bucket,
        key: _buildKey(remotePath),
      );
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to check file existence: ${e.message}');
    } catch (e) {
      // 其他错误返回 false
      return false;
    }
  }

  @override
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

  @override
  Future<int> getFileSize(String remotePath) async {
    // S3 HeadObject 可以返回 Content-Length
    // 但当前 S3Client 实现中未解析，暂时不支持
    throw UnimplementedError('getFileSize not implemented for S3');
  }

  @override
  Future<DateTime?> getLastModified(String remotePath) async {
    // S3 HeadObject 可以返回 Last-Modified
    // 但当前 S3Client 实现中未解析，暂时不支持
    throw UnimplementedError('getLastModified not implemented for S3');
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

      // 上传到 S3
      await client.putObject(
        bucket: bucket,
        key: _buildKey(path),
        data: bytes,
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
    final files = await listFiles(path);
    return files.map((name) => CloudFile(
      name: name,
      path: name,
      size: 0, // Size not available in list operation
      lastModified: DateTime.now(), // Not available
    )).toList();
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final exists = await fileExists(path);
      if (!exists) return null;

      return CloudFile(
        name: path.split('/').last,
        path: path,
        size: 0, // Not implemented yet
        lastModified: DateTime.now(), // Not implemented yet
      );
    } catch (e) {
      return null;
    }
  }

  /// 构造实际 S3 key：剥离开头斜杠后前置 [keyPrefix]。
  ///
  /// S3 的 Key 不应该以 / 开头；前置前缀实现 bucket 内目录隔离。
  String _buildKey(String path) {
    var key = path;
    if (key.startsWith('/')) {
      key = key.substring(1);
    }
    return keyPrefix.isEmpty ? key : '$keyPrefix$key';
  }
}
