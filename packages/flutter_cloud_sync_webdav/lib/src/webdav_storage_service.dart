library;

import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

/// WebDAV implementation of [CloudStorageService].
class WebDAVStorageService implements CloudStorageService, BinaryCapableStorage {
  final webdav.Client _client;
  final String _remotePath;

  WebDAVStorageService(this._client, this._remotePath);

  /// P3：WebDAV 单次操作 60s 超时。webdav_client 未暴露 dio 超时配置，
  /// 服务器无响应时 future 永不完成会让同步 UI 永久挂起，
  /// 在服务层统一包 .timeout 兜底。
  static const _opTimeout = Duration(seconds: 60);

  /// M15：上传临时文件标记（`<name>.tmp.<毫秒>`，见 [uploadBinary]）。
  /// list() 据此过滤上传中断残留的半成品，避免被下游当有效文件消费。
  static const _tempFileMarker = '.tmp.';

  /// 包裹单次 WebDAV 操作，超时抛 [CloudStorageException]（带操作名），
  /// 与其他网络错误走同一异常通道，调用方无需新增捕获分支。
  Future<T> _op<T>(String opName, Future<T> Function() op) {
    return op().timeout(_opTimeout, onTimeout: () {
      throw CloudStorageException(
          'WebDAV $opName 超时（${_opTimeout.inSeconds}s），请检查网络或服务器');
    });
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    // 字符串上传统一委托字节路径（原子写逻辑唯一），utf8 编码与历史行为一致
    await uploadBinary(
        path: path, bytes: utf8.encode(data), metadata: metadata);
  }

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    final fullPath = _buildPath(path);
    // 临时文件 + rename 实现原子写入，避免网络中断在远端留下损坏的半截文件。
    //
    // SYNC-09 修复：改为「先 rename(overwrite) 再按需 remove」。
    // 此前先 remove(fullPath) 再 rename，若 rename 失败（网络中断等）旧文件
    // 已被删除 → 云端账本文件出现丢失窗口。现在优先直接覆盖 rename：
    // rename 失败时旧文件仍在；仅当服务器不支持 MOVE 覆盖（409/412 等）
    // 时才降级为先删目标再重试一次 —— 此时丢失窗口收窄到「怪异服务器 +
    // 第二次 rename 也失败」的组合场景。
    final tempPath = '$fullPath.tmp.${DateTime.now().millisecondsSinceEpoch}';
    try {
      // 确保父目录存在
      await _ensureDirectory(PathHelper.dirname(fullPath));

      // 1. 先写临时文件（webdav write 需要 Uint8List，避免多余拷贝）
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await _op('write', () => _client.write(tempPath, data));

      // 2. 直接覆盖 rename（overwrite=true），失败时旧文件保持原样
      try {
        await _op('rename', () => _client.rename(tempPath, fullPath, true));
      } catch (renameError) {
        // 3. 降级：部分 WebDAV 服务器 MOVE 不支持覆盖，此时才先删目标
        //    再重试一次。remove 失败（如目标本不存在）可忽略。
        try {
          await _op('remove', () => _client.remove(fullPath));
        } catch (_) {
          // 目标不存在或删除失败均可忽略，交由 rename 处理
        }
        await _op('rename', () => _client.rename(tempPath, fullPath, true));
      }
    } catch (e) {
      // 清理临时文件，避免远端残留半成品
      try {
        await _op('remove', () => _client.remove(tempPath));
      } catch (cleanupError) {
        // 临时文件清理失败记录日志，便于排查远端残留半成品
        dev.log('[WebDAV] Warning: temp file cleanup failed for $tempPath: $cleanupError', name: 'WebDAVStorage');
      }
      // 401/403 认证失败：抛专属异常供上层引导用户修正凭据
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      throw CloudStorageException('Upload failed: $e', e);
    }

    // 元数据写入失败仅记日志，不影响主文件上传成功
    if (metadata != null && metadata.isNotEmpty) {
      await _storeMetadata(fullPath, metadata);
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final bytes = await downloadBinary(path: path);
      if (bytes == null) return null;
      return utf8.decode(bytes);
    } on CloudAuthException {
      // downloadBinary 已识别的认证失败原样透传（不依赖字符串兜底）
      rethrow;
    } catch (e) {
      // 统一用 _isNotFound 判断 404，优先结构化状态码、字符串匹配仅兜底
      if (_isNotFound(e)) {
        return null;
      }
      // 401/403 认证失败需与网络错误区分：上层（如 enableFromCloud 探测）
      // 依赖异常类型引导用户重新配置凭据，误报为网络错误会误导排查方向
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    try {
      // Build full path
      final fullPath = _buildPath(path);

      // Download file
      final bytes = await _op('read', () => _client.read(fullPath));

      return Uint8List.fromList(bytes);
    } catch (e) {
      if (_isNotFound(e)) {
        return null;
      }
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  @override
  Future<void> delete({required String path}) async {
    final fullPath = _buildPath(path);

    // C-02 修复：删除操作应幂等，404（文件不存在）视为成功
    try {
      await _op('remove', () => _client.remove(fullPath));
    } catch (e) {
      if (_isNotFound(e)) {
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
      final files = await _op('readDir', () => _client.readDir(fullPath));

      // Convert to CloudFile objects, excluding directories and metadata files
      return files
          .where((file) =>
              !(file.isDir ?? true) &&
              !(file.name?.endsWith('.metadata.json') ?? false) &&
              // M15：上传中断残留的临时文件（upload 用 `<name>.tmp.<毫秒>`，
              // PUT 后 MOVE 前崩溃即永久滞留）不得混进列表 —— 下游列举型
              // 消费者（备份/恢复候选）会把它当有效文件展示甚至恢复半截数据
              !(file.name?.contains(_tempFileMarker) ?? false))
          .map((file) {
        final name = file.name ?? '';
        // 构造相对于 remotePath 的路径，供下游 _buildPath 重新拼接。
        // file.path 为 null 时回退到基于 name 的拼接，而非回退到目录路径，
        // 避免下游把目录路径当成文件路径处理。
        final relativePath = path.isEmpty ? name : '$path/$name';
        return CloudFile(
          name: name,
          path: relativePath,
          size: file.size,
          lastModified: file.mTime,
          metadata: const {},
        );
      }).toList();
    } catch (e) {
      // 401/403 认证失败：抛专属异常供上层引导用户修正凭据
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  @override
  Future<bool> exists({required String path}) async {
    final fullPath = _buildPath(path);
    final parentDir = PathHelper.dirname(fullPath);
    final fileName = PathHelper.basename(fullPath);

    try {
      final files =
          await _op('readDir', () => _client.readDir(parentDir));
      return files.any((f) => f.name == fileName);
    } catch (e) {
      // 仅在目录不存在（404）时返回 false；其他错误（网络中断、
      // 403 权限不足等）必须抛出，避免调用方误判文件不存在而触发
      // 覆盖上传等危险操作。
      if (_isNotFound(e)) {
        return false;
      }
      // 401/403 认证失败必须抛出：误判为「不存在」会触发覆盖上传等危险操作
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
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

      final files =
          await _op('readDir', () => _client.readDir(parentDir));
      // W2：用类型化异常表达「文件不存在」，与超时/网络等通用存储故障区分。
      // 之前 orElse 抛通用 CloudStorageException，下方 `e is
      // CloudStorageException` 分支把 _op 超时抛的同类异常一并吞成 null，
      // 上层（getStatus）据此误判「云端无备份」→ 放行覆盖上传，弱网环境
      // 下可能拿旧数据盖掉云端新备份。
      final file = files.firstWhere(
        (f) => f.name == fileName,
        orElse: () => throw CloudFileNotFoundException(path),
      );

      // Try to load custom metadata
      final customMetadata = await _getMetadata(fullPath);

      return CloudFile(
        name: file.name ?? '',
        path: file.path ?? fullPath,
        size: file.size,
        lastModified: file.mTime,
        metadata: customMetadata,
      );
    } catch (e) {
      // 401/403 认证失败需原样抛出：下方 not-found 分支会把其余异常
      // 上抛为通用存储故障，认证错误必须可区分以引导用户改凭据
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      // 仅「确认不存在」收敛为 null（接口契约：getMetadata 缺失返回 null）；
      // 超时/网络等其余故障一律上抛，绝不静默变成「云端无元数据」
      if (_isNotFound(e) || e is CloudFileNotFoundException) {
        return null;
      }
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }

  /// Builds the full path with remote path prefix.
  String _buildPath(String path) {
    return PathHelper.join([_remotePath, path]);
  }

  /// 统一判断 WebDAV 404 错误，优先使用结构化状态码，字符串匹配仅作兜底。
  ///
  /// webdav_client 内部抛出的是 dio 的 DioException（带 response.statusCode），
  /// 这里用 dynamic 访问 response 字段以避免引入 dio 直接依赖。
  ///
  /// M5：只要异常携带了结构化 response，就**只**按状态码判定 —— 字符串
  /// 兜底仅在完全无结构化信息时使用。之前「有 response 但非 404」也会
  /// 落到字符串匹配，而 DioException.toString() 内嵌完整 URL：文件名含
  /// "404"/"not found" 子串时（如 backup404.json），任何网络层错误都会
  /// 被误判为文件不存在 → exists()=false → 触发覆盖上传等危险操作。
  bool _isNotFound(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        return response.statusCode == 404;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段，进入字符串兜底
    }
    // 兜底：仅当确实无结构化信息时使用字符串匹配
    final msg = e.toString().toLowerCase();
    return msg.contains('404') ||
        msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('no such');
  }

  /// 统一判断 WebDAV 401/403 认证失败，策略与 [_isNotFound] 一致：
  /// 有结构化状态码只看状态码；字符串兜底仅限无结构化信息时（M5 同款）。
  ///
  /// 认证失败与网络故障对用户的处置动作完全不同（改凭据 vs 查网络），
  /// 必须区分抛出 [CloudAuthException]，避免上层统一报「请检查网络」。
  bool _isUnauthorized(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        return response.statusCode == 401 || response.statusCode == 403;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段，进入字符串兜底
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden');
  }

  /// Ensures a directory exists, creating it if necessary.
  ///
  /// M-04 修复：仅在 404（目录不存在）时触发创建流程；
  /// 网络中断、403 权限不足、500 服务器错误等异常直接向上传播，
  /// 避免掩盖真实问题导致误导性的 mkdir 调用。
  Future<void> _ensureDirectory(String dirPath) async {
    try {
      await _op('readDir', () => _client.readDir(dirPath));
      // readDir 成功，目录已存在
      return;
    } catch (e) {
      if (_isNotFound(e)) {
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
        await _op('readDir', () => _client.readDir(currentPath));
        // 目录已存在，继续下一级
      } catch (e) {
        // 目录可能不存在，尝试创建
        try {
          await _op('mkdir', () => _client.mkdir(currentPath));
        } catch (createError) {
          // mkdir 失败可能是并发创建（405/409），再验证一次
          final msg = createError.toString().toLowerCase();
          if (msg.contains('405') ||
              msg.contains('409') ||
              msg.contains('already exists') ||
              msg.contains('conflict')) {
            try {
              await _op('readDir', () => _client.readDir(currentPath));
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
      await _op('write', () => _client.write(metadataPath, bytes));
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
      final bytes =
          await _op('read', () => _client.read(metadataPath));
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
      await _op('remove', () => _client.remove(metadataPath));
    } catch (e) {
      // 元数据是辅助数据，删除失败（如文件本就不存在）不阻塞主流程，
      // 但记录 warning 便于排查，与 _storeMetadata 的日志策略保持一致
      dev.log('[WebDAV] Warning: metadata delete failed for $filePath: $e',
          name: 'WebDAVStorage');
    }
  }
}
