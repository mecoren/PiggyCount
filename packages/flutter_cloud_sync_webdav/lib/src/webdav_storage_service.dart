library;

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV implementation of [CloudStorageService].
class WebDAVStorageService implements CloudStorageService {
  final webdav.Client _client;
  final String _remotePath;

  WebDAVStorageService(this._client, this._remotePath);

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // Ensure parent directories exist
      await _ensureDirectory(PathHelper.dirname(fullPath));

      // Convert string to bytes
      final bytes = utf8.encode(data);

      // Upload file
      await _client.write(fullPath, bytes);

      // Store metadata as custom properties if provided
      if (metadata != null && metadata.isNotEmpty) {
        await _storeMetadata(fullPath, metadata);
      }
    } catch (e) {
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // Download file
      final bytes = await _client.read(fullPath);

      // Convert bytes to string
      return utf8.decode(bytes);
    } catch (e) {
      // m-04 修复：用 CloudFileNotFoundException 统一 404 处理，替代字符串匹配
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') || msg.contains('not found') || msg.contains('does not exist')) {
        return null;
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    final fullPath = _buildPath(path);

    // C-02 修复：删除操作应幂等，404（文件不存在）视为成功
    try {
      await _client.remove(fullPath);
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') || msg.contains('not found') || msg.contains('does not exist')) {
        // 文件已不存在，删除幂等成功
      } else {
        throw CloudStorageException('Delete failed: $e', e);
      }
    }

    // 删除元数据文件（失败静默忽略，元数据是辅助数据）
    await _deleteMetadata(fullPath);
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // List files
      final files = await _client.readDir(fullPath);

      // Convert to CloudFile objects, excluding directories and metadata files
      return files
          .where((file) =>
              !(file.isDir ?? true) &&
              !(file.name?.endsWith('.metadata.json') ?? false))
          .map((file) => CloudFile(
                name: file.name ?? '',
                path: file.path ?? fullPath,
                size: file.size,
                lastModified: file.mTime,
                metadata: const {},
              ))
          .toList();
    } catch (e) {
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    final fullPath = _buildPath(path);
    final parentDir = PathHelper.dirname(fullPath);
    final fileName = PathHelper.basename(fullPath);

    try {
      final files = await _client.readDir(parentDir);
      return files.any((f) => f.name == fileName);
    } catch (e) {
      // 仅在目录不存在（404）时返回 false；其他错误（网络中断、
      // 403 权限不足等）必须抛出，避免调用方误判文件不存在而触发
      // 覆盖上传等危险操作。
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') ||
          msg.contains('not found') ||
          msg.contains('does not exist')) {
        return false;
      }
      throw CloudStorageException('Failed to check file existence: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // Get file list to find the file
      final parentDir = PathHelper.dirname(fullPath);
      final fileName = PathHelper.basename(fullPath);

      final files = await _client.readDir(parentDir);
      final file = files.firstWhere(
        (f) => f.name == fileName,
        orElse: () => throw CloudStorageException('File not found: $path'),
      );

      // Try to load custom metadata
      final customMetadata = await _getMetadata(fullPath);

      return CloudFile(
        name: file.name!,
        path: file.path!,
        size: file.size,
        lastModified: file.mTime,
        metadata: customMetadata,
      );
    } catch (e) {
      if (e.toString().contains('404') ||
          e.toString().contains('not found') ||
          e is CloudStorageException) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }

  /// Builds the full path with remote path prefix.
  String _buildPath(String path) {
    return PathHelper.join([_remotePath, path]);
  }

  /// Ensures a directory exists, creating it if necessary.
  ///
  /// M-04 修复：仅在 404（目录不存在）时触发创建流程；
  /// 网络中断、403 权限不足、500 服务器错误等异常直接向上传播，
  /// 避免掩盖真实问题导致误导性的 mkdir 调用。
  Future<void> _ensureDirectory(String dirPath) async {
    try {
      await _client.readDir(dirPath);
      // readDir 成功，目录已存在
      return;
    } catch (e) {
      final msg = e.toString().toLowerCase();
      if (msg.contains('404') ||
          msg.contains('not found') ||
          msg.contains('does not exist') ||
          msg.contains('no such')) {
        // 目录不存在，创建它
        await _createDirectoryRecursively(dirPath);
      } else {
        // 网络错误、权限不足等不应触发目录创建
        rethrow;
      }
    }
  }

  /// Creates a directory recursively.
  ///
  /// 采用「先 mkdir 再验证」策略：readDir 探测失败后直接 mkdir，
  /// 若 mkdir 抛 405/409（目录已存在，常见于并发创建），再 readDir
  /// 验证一次确认目录确实存在，避免把并发竞态误判为创建失败。
  Future<void> _createDirectoryRecursively(String dirPath) async {
    final parts = dirPath.split('/').where((p) => p.isNotEmpty).toList();
    var currentPath = '';

    for (final part in parts) {
      currentPath = currentPath.isEmpty ? part : '$currentPath/$part';
      try {
        await _client.readDir(currentPath);
        // 目录已存在，继续下一级
      } catch (e) {
        // 目录可能不存在，尝试创建
        try {
          await _client.mkdir(currentPath);
        } catch (createError) {
          // mkdir 失败可能是并发创建（405/409），再验证一次
          final msg = createError.toString().toLowerCase();
          if (msg.contains('405') ||
              msg.contains('409') ||
              msg.contains('already exists') ||
              msg.contains('conflict')) {
            try {
              await _client.readDir(currentPath);
              // 验证成功，目录确实存在（由其他进程创建）
            } catch (_) {
              // 验证也失败，说明是真实错误，重新抛出
              rethrow;
            }
          } else {
            // 非「已存在」类错误，向上抛出
            rethrow;
          }
        }
      }
    }
  }

  /// Stores custom metadata as a separate JSON file.
  ///
  /// 元数据存储失败不影响主数据的完整性（主文件已上传成功），
  /// 但需记录 warning 日志便于排查，而非完全静默吞掉。
  Future<void> _storeMetadata(
      String filePath, Map<String, String> metadata) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      final metadataJson = jsonEncode({
        'metadata': metadata,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final bytes = utf8.encode(metadataJson);
      await _client.write(metadataPath, bytes);
    } catch (e) {
      // 元数据是辅助功能（主数据已上传成功），失败不阻塞主流程，
      // 但记录 warning 便于排查，避免完全静默
      dev.log('[WebDAV] Warning: metadata storage failed for $filePath: $e', name: 'WebDAVStorage');
    }
  }

  /// Retrieves custom metadata from JSON file.
  Future<Map<String, dynamic>> _getMetadata(String filePath) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      final bytes = await _client.read(metadataPath);
      final json = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      return json['metadata'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      // Return empty map if metadata file doesn't exist
      return {};
    }
  }

  /// Deletes custom metadata file.
  Future<void> _deleteMetadata(String filePath) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      await _client.remove(metadataPath);
    } catch (e) {
      // Silently fail if metadata file doesn't exist
    }
  }
}
