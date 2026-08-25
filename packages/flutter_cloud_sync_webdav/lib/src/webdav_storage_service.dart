library;

import 'dart:async';
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:typed_data';

import 'package:dio/dio.dart' show CancelToken;
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

  /// 审计 WD-1：降级交换流程的备份文件标记（`<name>.old.<毫秒>`）。
  /// 备份清理失败时 list() 据此过滤，避免孤儿备份被下游当有效文件。
  static const _backupFileMarker = '.old.';

  /// 包裹单次 WebDAV 操作，超时抛 [CloudStorageException]（带操作名），
  /// 与其他网络错误走同一异常通道，调用方无需新增捕获分支。
  ///
  /// F9：超时同时通过 [CancelToken] 主动中止底层 HTTP 请求。仅靠
  /// Future.timeout 放弃等待的话，请求仍在后台继续 —— PUT 可能在超时后
  /// 才完成，把临时文件留在远端（孤儿半成品）。取消让传输层尽快终止。
  /// 注意：rename(MOVE) 的上游 client.rename 声明了 cancelToken 形参但未
  /// 向下传递（webdav_client 1.2.2 已知问题），MOVE 无法被取消，维持
  /// timeout-only；其余操作全部可取消。
  Future<T> _op<T>(String opName, Future<T> Function(CancelToken token) op) {
    final token = CancelToken();
    final timer = Timer(_opTimeout, () {
      token.cancel('WebDAV $opName 超时');
    });
    return op(token).timeout(_opTimeout, onTimeout: () {
      throw CloudStorageException(
          'WebDAV $opName 超时（${_opTimeout.inSeconds}s），请检查网络或服务器');
    }).whenComplete(timer.cancel);
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
    // SYNC-09 修复：改为「先 rename(overwrite) 再按需降级」。
    // 此前先 remove(fullPath) 再 rename，若 rename 失败（网络中断等）旧文件
    // 已被删除 → 云端账本文件出现丢失窗口。
    //
    // 审计 WD-1 二次修复：SYNC-09 的降级分支对**任意** rename 错误都会先
    // remove(fullPath)，弱网下「删除成功、二次 rename 也失败」仍会把云端
    // 唯一备份彻底删没。现在：
    //   1. 只有错误明确指向「服务器不支持覆盖式 MOVE」（405/409/412）才降级，
    //      其余错误一律原样上抛 —— 此时旧文件完好；
    //   2. 降级本身改为无损交换：旧文件先挪到备份位 → 新文件落位 → 成功后
    //      删备份。任一步失败都尽力把备份挪回原位，全程不存在
    //      「目标已删、新未落位且无备份」的窗口。
    final tempPath = '$fullPath.tmp.${DateTime.now().millisecondsSinceEpoch}';
    try {
      // 确保父目录存在
      await _ensureDirectory(PathHelper.dirname(fullPath));

      // 1. 先写临时文件（webdav write 需要 Uint8List，避免多余拷贝）
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await _op('write', (t) => _client.write(tempPath, data, cancelToken: t));

      // 2. 直接覆盖 rename（overwrite=true），失败时旧文件保持原样
      try {
        await _op('rename', (_) => _client.rename(tempPath, fullPath, true));
      } catch (renameError) {
        // 3. 降级（仅限不支持覆盖 MOVE 的服务器）：交换式替换，见上方注释
        if (!_isOverwriteUnsupported(renameError)) {
          rethrow;
        }
        final backupPath =
            '$fullPath.old.${DateTime.now().millisecondsSinceEpoch}';
        // 旧文件挪到备份位。此步失败则旧文件仍在原位，直接向上抛
        // （外层 catch 清理临时文件即可，无数据风险）。
        await _op('rename', (_) => _client.rename(fullPath, backupPath, false));
        try {
          // 新文件落位
          await _op('rename', (_) => _client.rename(tempPath, fullPath, true));
        } catch (swapError) {
          // 落位失败：把备份挪回原位保住旧数据，再上抛原始错误
          try {
            await _op(
                'rename', (_) => _client.rename(backupPath, fullPath, false));
          } catch (restoreError) {
            dev.log(
                '[WebDAV] Error: failed to restore backup $backupPath -> $fullPath: $restoreError',
                name: 'WebDAVStorage');
          }
          rethrow;
        }
        // 落位成功，清理备份。失败仅遗留孤儿备份文件（list 已过滤 .old.
        // 标记，不会被下游当有效数据消费），不影响上传结果。
        try {
          await _op('remove', (t) => _client.remove(backupPath, t));
        } catch (cleanupError) {
          dev.log(
              '[WebDAV] Warning: backup cleanup failed for $backupPath: $cleanupError',
              name: 'WebDAVStorage');
        }
      }
    } catch (e) {
      // 清理临时文件，避免远端残留半成品
      try {
        await _op('remove', (t) => _client.remove(tempPath, t));
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
      final bytes = await _op('read', (t) => _client.read(fullPath, cancelToken: t));

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
      await _op('remove', (t) => _client.remove(fullPath, t));
    } catch (e) {
      if (_isNotFound(e)) {
        // 文件已不存在，删除幂等成功
      } else if (_isUnauthorized(e)) {
        // 审计 WD-M1：凭据失效必须抛认证异常（与 upload/download/list/
        // exists/getMetadata 及 S3 实现对齐），让上层引导用户改密码，
        // 而不是报成笼统的存储故障。
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
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
      final files = await _op('readDir', (t) => _client.readDir(fullPath, t));

      // Convert to CloudFile objects, excluding directories and metadata files
      return files
          .where((file) =>
              !(file.isDir ?? true) &&
              !(file.name?.endsWith('.metadata.json') ?? false) &&
              // M15：上传中断残留的临时文件（upload 用 `<name>.tmp.<毫秒>`，
              // PUT 后 MOVE 前崩溃即永久滞留）不得混进列表 —— 下游列举型
              // 消费者（备份/恢复候选）会把它当有效文件展示甚至恢复半截数据
              !(file.name?.contains(_tempFileMarker) ?? false) &&
              // 审计 WD-1：降级交换后清理失败的备份文件同理过滤
              !(file.name?.contains(_backupFileMarker) ?? false))
          .map((file) {
        final name = file.name ?? '';
        // 构造相对于 remotePath 的路径，供下游 _buildPath 重新拼接。
        // file.path 为 null 时回退到基于 name 的拼接，而非回退到目录路径，
        // 避免下游把目录路径当成文件路径处理。
        // 审计 WD-L2：入参带尾斜杠时归一化，避免产出 `backups//x.json`
        // 这类双斜杠脏路径直接暴露给消费方。
        final normalizedDir = path.endsWith('/') && path.length > 1
            ? path.substring(0, path.length - 1)
            : path;
        final relativePath =
            normalizedDir.isEmpty ? name : '$normalizedDir/$name';
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
          await _op('readDir', (t) => _client.readDir(parentDir, t));
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
          await _op('readDir', (t) => _client.readDir(parentDir, t));
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
        // 口径对齐其余方法（upload/download/delete/list）：返回**逻辑相对
        // 路径**（即调用方传入的 path），保证 getMetadata 的返回值可直接
        // 回传给 _buildPath 重新拼接而不产生双前缀。file.path 是 webdav_client
        // 返回的服务端绝对路径，混出去会让下游把目录前缀拼两遍。
        path: path,
        size: file.size,
        lastModified: file.mTime,
        metadata: customMetadata,
      );
    } catch (e) {
      // 审计 WD-M2：「确认不存在」必须最先判定 —— CloudFileNotFoundException
      // 由本方法内部抛出、不携带结构化状态码，若先走 _isUnauthorized 的
      // 字符串兜底，文件路径含 forbidden/401 等子串时（如 notes/forbidden.txt）
      // 普通的「文件不存在」会被误判成认证失败，UI 误导用户去改密码。
      if (_isNotFound(e) || e is CloudFileNotFoundException) {
        return null;
      }
      // 401/403 认证失败需原样抛出：下方其余异常上抛为通用存储故障，
      // 认证错误必须可区分以引导用户改凭据
      if (_isUnauthorized(e)) {
        throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
      }
      // 仅「确认不存在」收敛为 null（接口契约：getMetadata 缺失返回 null）；
      // 超时/网络等其余故障一律上抛，绝不静默变成「云端无元数据」
      throw CloudStorageException('Get metadata failed: $e', e);
    }
  }

  /// Builds the full path with remote path prefix.
  String _buildPath(String path) {
    return PathHelper.join([_remotePath, path]);
  }

  /// 提取异常携带的结构化 HTTP 状态码（dio 系异常），无则返回 null。
  ///
  /// webdav_client 内部抛出的是 dio 的 DioException（带 response.statusCode），
  /// 这里用 dynamic 访问 response 字段以避免引入 dio 直接依赖。
  int? _statusCodeOf(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        final dynamic code = response.statusCode;
        if (code is int) return code;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段
    }
    return null;
  }

  /// 统一判断 WebDAV 404 错误，优先使用结构化状态码，字符串匹配仅作兜底。
  ///
  /// M5：只要异常携带了结构化 response，就**只**按状态码判定 —— 字符串
  /// 兜底仅在完全无结构化信息时使用。之前「有 response 但非 404」也会
  /// 落到字符串匹配，而 DioException.toString() 内嵌完整 URL：文件名含
  /// "404"/"not found" 子串时（如 backup404.json），任何网络层错误都会
  /// 被误判为文件不存在 → exists()=false → 触发覆盖上传等危险操作。
  ///
  /// 审计 WD-M3：无结构化信息的异常（SocketException 等）消息常内嵌
  /// host:port（如 `10.0.40.35:8404`），**纯数字子串匹配必然误判**
  /// （8404 含 "404"、端口含 "401"/"403" 同理）。故兜底只做明确的措辞
  /// 匹配，彻底移除数字子串 —— 连接层失败本就不该被归类为任何 HTTP 状态。
  bool _isNotFound(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 404;
    }
    // 兜底：仅当确实无结构化信息时使用措辞匹配（不做数字子串匹配）
    final msg = e.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('no such file') ||
        msg.contains('no such resource');
  }

  /// 统一判断 WebDAV 401/403 认证失败，策略与 [_isNotFound] 一致：
  /// 有结构化状态码只看状态码；字符串兜底仅限无结构化信息时的措辞匹配，
  /// 不做纯数字子串匹配（WD-M3 同款理由）。
  ///
  /// 认证失败与网络故障对用户的处置动作完全不同（改凭据 vs 查网络），
  /// 必须区分抛出 [CloudAuthException]，避免上层统一报「请检查网络」。
  bool _isUnauthorized(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 401 || code == 403;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('unauthorized') ||
        msg.contains('forbidden');
  }

  /// 判断 rename(MOVE overwrite=true) 失败是否源于「服务器不支持覆盖式 MOVE」。
  ///
  /// 仅这类错误允许进入 uploadBinary 的交换式降级流程；网络中断、超时等
  /// 瞬时故障绝不能触发降级（审计 WD-1）。有结构化状态码只认 405/409/412；
  /// 字符串兜底只匹配方法/前置条件类明确措辞，不匹配纯数字（避免撞上
  /// 异常消息内嵌的 URL 端口等子串）。
  bool _isOverwriteUnsupported(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 405 || code == 409 || code == 412;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('method not allowed') ||
        msg.contains('precondition failed') ||
        msg.contains('conflict');
  }

  /// Ensures a directory exists, creating it if necessary.
  ///
  /// M-04 修复：仅在 404（目录不存在）时触发创建流程；
  /// 网络中断、403 权限不足、500 服务器错误等异常直接向上传播，
  /// 避免掩盖真实问题导致误导性的 mkdir 调用。
  Future<void> _ensureDirectory(String dirPath) async {
    try {
      await _op('readDir', (t) => _client.readDir(dirPath, t));
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
        await _op('readDir', (t) => _client.readDir(currentPath, t));
        // 目录已存在，继续下一级
      } catch (e) {
        // 目录可能不存在，尝试创建
        try {
          await _op('mkdir', (t) => _client.mkdir(currentPath, t));
        } catch (createError) {
          // mkdir 失败可能是并发创建（405/409），再验证一次
          final msg = createError.toString().toLowerCase();
          if (msg.contains('405') ||
              msg.contains('409') ||
              msg.contains('already exists') ||
              msg.contains('conflict')) {
            try {
              await _op('readDir', (t) => _client.readDir(currentPath, t));
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
  /// 元数据存储失败不影响主数据的完整性（主文件已上传成功），但必须尽力
  /// 作废可能残留的**陈旧** sidecar（F3）：旧指纹 + 新内容的组合会让读取端
  /// （CloudSyncManager.download 完整性自检）拿旧指纹比对新内容而硬失败，
  /// 把「一次性元数据写失败」放大成「该备份永久无法下载」，比
  /// 「无指纹 → 跳过校验」危险得多。返回是否写入成功。
  Future<bool> _storeMetadata(
      String filePath, Map<String, String> metadata) async {
    final metadataPath = '$filePath.metadata.json';
    try {
      final metadataJson = jsonEncode({
        'metadata': metadata,
        'updatedAt': DateTime.now().toIso8601String(),
      });
      final bytes = utf8.encode(metadataJson);
      await _op('write', (t) => _client.write(metadataPath, bytes, cancelToken: t));
      return true;
    } catch (e) {
      // 元数据是辅助功能（主数据已上传成功），失败不阻塞主流程，
      // 但记录 warning 便于排查，避免完全静默
      dev.log('[WebDAV] Warning: metadata storage failed for $filePath: $e', name: 'WebDAVStorage');
      // F3：尽力删除陈旧 sidecar。删除也失败（网络异常时的常见组合）时
      // 读取端仍会看到陈旧指纹 —— 该残余风险记录在案，属极端场景。
      try {
        await _op('remove', (t) => _client.remove(metadataPath, t));
      } catch (_) {}
      return false;
    }
  }

  /// Retrieves custom metadata from JSON file.
  Future<Map<String, dynamic>> _getMetadata(String filePath) async {
    try {
      final metadataPath = '$filePath.metadata.json';
      final bytes =
          await _op('read', (t) => _client.read(metadataPath, cancelToken: t));
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
      await _op('remove', (t) => _client.remove(metadataPath, t));
    } catch (e) {
      // 元数据是辅助数据，删除失败（如文件本就不存在）不阻塞主流程，
      // 但记录 warning 便于排查，与 _storeMetadata 的日志策略保持一致
      dev.log('[WebDAV] Warning: metadata delete failed for $filePath: $e',
          name: 'WebDAVStorage');
    }
  }
}
