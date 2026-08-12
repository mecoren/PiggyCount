library;

import 'dart:convert';
import 'dart:developer' as dev;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Supabase implementation of [CloudStorageService].
class SupabaseStorageService implements CloudStorageService {
  final supabase.SupabaseClient _client;
  final String _bucketName;
  final String? _pathPrefix;

  SupabaseStorageService(this._client, this._bucketName, [this._pathPrefix]);

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // Upload file with metadata
      // Use UTF-8 encoding to properly handle multi-byte characters (e.g., Chinese)
      final bytes = utf8.encode(data);
      await _client.storage.from(_bucketName).uploadBinary(
            fullPath,
            bytes,
            fileOptions: const supabase.FileOptions(
              upsert: true,
              contentType: 'application/json',
              cacheControl: '3600',
            ),
          );

      // Store metadata separately if provided
      if (metadata != null && metadata.isNotEmpty) {
        await _storeMetadata(fullPath, metadata);
      }
    } on supabase.StorageException catch (e) {
      throw CloudStorageException('Upload failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Upload failed: $e', e);
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // Download file
      final bytes = await _client.storage.from(_bucketName).download(fullPath);

      // Convert bytes to string using UTF-8 decoding
      return utf8.decode(bytes);
    } on supabase.StorageException catch (e) {
      // Return null if file not found
      if (e.statusCode == '404' || e.message.contains('not found')) {
        return null;
      }
      throw CloudStorageException('Download failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // Delete file
      try {
        await _client.storage.from(_bucketName).remove([fullPath]);
      } on supabase.StorageException catch (e) {
        // 忽略 404（文件不存在），删除操作幂等
        if (e.statusCode != '404' && !e.message.contains('not found')) {
          rethrow;
        }
      }

      // Delete metadata
      await _deleteMetadata(fullPath);
    } on supabase.StorageException catch (e) {
      throw CloudStorageException('Delete failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Delete failed: $e', e);
    }
  }

  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // List files
      final files = await _client.storage.from(_bucketName).list(
            path: fullPath,
          );

      // Convert to CloudFile objects
      return files
          .map((file) => CloudFile(
                name: file.name,
                path: '$fullPath/${file.name}',
                size: file.metadata?['size'] as int?,
                lastModified: file.updatedAt != null
                    ? DateTime.parse(file.updatedAt!)
                    : null,
                metadata: file.metadata,
              ))
          .toList();
    } on supabase.StorageException catch (e) {
      throw CloudStorageException('List failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // Try to get file info - if it doesn't throw, file exists
      final files = await _client.storage.from(_bucketName).list(
            path: PathHelper.dirname(fullPath),
          );

      final fileName = PathHelper.basename(fullPath);
      return files.any((file) => file.name == fileName);
    } on supabase.StorageException catch (e) {
      // If path not found, file doesn't exist
      if (e.statusCode == '404' || e.message.contains('not found')) {
        return false;
      }
      throw CloudStorageException('Exists check failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException) rethrow;
      throw CloudStorageException('Exists check failed: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      // Check if user is authenticated
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }

      // Build full path with user ID prefix
      final fullPath = _buildUserPath(user.id, path);

      // Get file list to retrieve metadata
      final files = await _client.storage.from(_bucketName).list(
            path: PathHelper.dirname(fullPath),
          );

      final fileName = PathHelper.basename(fullPath);
      // 文件不在列表中时通过私有标记异常跳出，由外层捕获后返回 null，
      // 避免抛出 CloudStorageException 导致调用方需 catch 字符串匹配（Minor）
      final file = files.firstWhere(
        (f) => f.name == fileName,
        orElse: () => throw _FileNotFoundInList(),
      );

      // Get stored custom metadata
      final customMetadata = await _getMetadata(fullPath);

      return CloudFile(
        name: file.name,
        path: fullPath,
        size: file.metadata?['size'] as int?,
        lastModified:
            file.updatedAt != null ? DateTime.parse(file.updatedAt!) : null,
        metadata: {
          ...?file.metadata,
          ...customMetadata,
        },
      );
    } on _FileNotFoundInList {
      // 文件不存在时返回 null 而非抛异常（Minor）
      return null;
    } on supabase.StorageException catch (e) {
      if (e.statusCode == '404' || e.message.contains('not found')) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: ${e.message}', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException || e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }

  /// Builds a user-specific path.
  ///
  /// If pathPrefix is provided, it will be used as the prefix (supports {userId} placeholder).
  /// Otherwise, defaults to 'users/{userId}/' for backward compatibility.
  String _buildUserPath(String userId, String path) {
    // If no prefix configured, use default 'users/{userId}/' pattern
    final prefix = _pathPrefix ?? 'users/{userId}';

    // Replace {userId} placeholder with actual user ID
    final expandedPrefix = prefix.replaceAll('{userId}', userId);

    // Join prefix with path
    return PathHelper.join([expandedPrefix, path]);
  }

  /// Stores custom metadata in a separate database table.
  /// Since Supabase Storage doesn't support custom metadata directly,
  /// we store it in a metadata table.
  ///
  /// 元数据存储失败不影响主数据的完整性（主文件已上传成功），
  /// 但需记录 warning 便于排查，而非完全静默吞掉。
  Future<void> _storeMetadata(
      String path, Map<String, String> metadata) async {
    try {
      await _client.from('file_metadata').upsert({
        'path': path,
        'metadata': metadata,
        'updated_at': DateTime.now().toIso8601String(),
      });
    } catch (e) {
      // 元数据是辅助功能（主数据已上传成功），失败不阻塞主流程，
      // 但记录 warning 便于排查（如 metadata 表未创建）
      dev.log('[Supabase] Warning: metadata storage failed for $path: $e', name: 'SupabaseStorage');
    }
  }

  /// Retrieves custom metadata from database.
  Future<Map<String, dynamic>> _getMetadata(String path) async {
    try {
      final response = await _client
          .from('file_metadata')
          .select('metadata')
          .eq('path', path)
          .maybeSingle();

      if (response == null) return {};

      return response['metadata'] as Map<String, dynamic>? ?? {};
    } catch (e) {
      // 元数据是辅助功能，失败不阻塞主流程，但记录 warning 便于排查
      // （如 metadata 表未创建）（P-M8）
      dev.log(
        '[Supabase] Warning: getMetadata failed for $path: $e',
        name: 'SupabaseStorage',
        level: 900,
      );
      return {};
    }
  }

  /// Deletes custom metadata from database.
  Future<void> _deleteMetadata(String path) async {
    try {
      await _client.from('file_metadata').delete().eq('path', path);
    } on supabase.PostgrestException catch (e) {
      // 区分表不存在的错误与其他错误：表不存在属于环境配置问题，降级为 warning；
      // 其他 Postgrest 错误同样记录 warning 但不阻塞删除主流程（P-M8）
      dev.log(
        '[Supabase] Warning: deleteMetadata Postgrest error for $path: ${e.message} (code: ${e.code})',
        name: 'SupabaseStorage',
        level: 900,
      );
    } catch (e) {
      dev.log(
        '[Supabase] Warning: deleteMetadata failed for $path: $e',
        name: 'SupabaseStorage',
        level: 900,
      );
    }
  }
}

/// 私有标记异常：用于 getMetadata 中 firstWhere 的 orElse 跳出，
/// 外层捕获后返回 null，避免文件不存在时抛出业务异常（Minor）
class _FileNotFoundInList implements Exception {}
