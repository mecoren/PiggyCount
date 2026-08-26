import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 's3_client.dart';
import 's3_exceptions.dart';

/// S3 存储服务实现
class S3StorageService
    implements CloudStorageService, BinaryCapableStorage, ConditionalWriteStorage {
  final S3Client client;
  final String bucket;

  /// 所有 S3 key 的统一前缀（例如 `'piggycount/'`）。
  ///
  /// 业务层用于在共享 bucket 中隔离应用数据：所有 key 会自动前置该前缀，
  /// [listFiles] 返回值会剥离前缀，使调用方始终看到逻辑路径，避免双前缀。
  /// 为空时行为与无前缀一致（向后兼容）。
  final String keyPrefix;

  S3StorageService(this.client, this.bucket, {String keyPrefix = ''})
      : keyPrefix = _normalizePrefix(_validatePrefix(keyPrefix));

  /// 认证/权限类异常转 [CloudAuthException]，保持语义保真（与 WebDAV 修复同款）
  ///
  /// S3AuthException（AK/SK 无效）与 S3PermissionDeniedException（403 无权限）
  /// 都是凭据配置问题，重试无效，需引导用户到云服务页修正配置；
  /// 若包装成通用 CloudStorageException，上层（enableFromCloud 探测、
  /// 启动检查器）会把认证失败误报为网络错误，误导排查方向。
  /// 消息携带「认证失败」关键字，供下游文本兜底识别。
  CloudAuthException _authException(S3Exception e) {
    return CloudAuthException('S3 认证失败（凭据错误或无权限）：${e.message}', e);
  }

  /// 规范化前缀：非空时确保以 `/` 结尾，避免 `piggycount` 与 `ledger.json`
  /// 直接拼接为 `piggycountledger.json`。
  static String _normalizePrefix(String prefix) {
    if (prefix.isEmpty) return '';
    return prefix.endsWith('/') ? prefix : '$prefix/';
  }

  /// 审计 S3-22：前缀自身校验。含 `..` 段可逃逸前缀隔离访问其他应用对象；
  /// 前导 `/` 会拼出 `//xxx` 双斜杠 key 使对象名错乱。构造期即拒绝，
  /// 不等到首个请求才以晦涩的服务端错误暴露。
  static String _validatePrefix(String prefix) {
    if (prefix.isEmpty) return prefix;
    if (prefix.startsWith('/')) {
      throw ArgumentError.value(
          prefix, 'keyPrefix', 'must not start with "/"');
    }
    _assertNoTraversal(prefix, 'keyPrefix');
    return prefix;
  }

  /// 审计 S3-12：进程内自增计数器，参与下载临时文件名构造。此前固定使用
  /// `$localPath.tmp`，同一目标的并发下载会互相覆盖对方写了一半的 tmp，
  /// 先完成者 rename 发布的可能是对方截断的数据。时间戳 + 序号保证
  /// 同进程内每次下载独占自己的 tmp 文件。
  static int _tempSeq = 0;

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
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
      // 导致目标文件被截断/损坏，使原有可用数据丢失。
      // 审计 S3-12：tmp 文件名加入时间戳+序号，并发下载同一目标时
      // 各自独立，不再互相覆盖半成品。
      final file = File(localPath);
      await file.parent.create(recursive: true);
      final tempPath =
          '$localPath.tmp.${DateTime.now().microsecondsSinceEpoch}_${_tempSeq++}';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsBytes(bytes);
        await tempFile.rename(localPath);
      } catch (_) {
        // rename 失败时尽力清理本次的 tmp，避免残留垃圾文件
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
    } on S3ObjectNotFoundException catch (e) {
      throw CloudStorageException('File not found: ${e.key}');
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
      // 过滤目录占位对象（控制台建目录产生的零字节 key，形如
      // `piggycount/` 或 `piggycount/attachments/`）：剥离后为空串或以
      // `/` 结尾，不是真实文件，不应进入调用方的文件列表。
      String stripPrefix(String k) => k.startsWith(keyPrefix)
          ? k.substring(keyPrefix.length)
          : k;
      return keys.map(stripPrefix).where((k) => k.isNotEmpty && !k.endsWith('/')).toList();
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
    // 字符串上传统一委托字节路径，utf8 编码与历史行为一致
    await uploadBinary(
        path: path, bytes: utf8.encode(data), metadata: metadata);
  }

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    try {
      // 上传到 S3，C-01 修复：传递 metadata 作为 x-amz-meta-* 头
      // （putObject 需要 Uint8List，已是 Uint8List 时避免拷贝）
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await client.putObject(
        bucket: bucket,
        key: _buildKey(path),
        data: data,
        metadata: metadata,
      );
    } on CloudAuthException {
      // 认证异常原样透传，避免被通用 catch 降级（与 download 同理）
      rethrow;
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to upload file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to upload file: $e');
    }
  }

  @override
  bool get supportsConditionalWrite => true;

  @override
  Future<void> uploadBinaryConditional({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
    String? ifMatchEtag,
    bool ifNoneMatch = false,
  }) async {
    try {
      final data = bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
      await client.putObject(
        bucket: bucket,
        key: _buildKey(path),
        data: data,
        metadata: metadata,
        ifMatch: ifMatchEtag,
        ifNoneMatch: ifNoneMatch,
      );
    } on S3PreconditionFailedException catch (e) {
      // 方案C：412 翻译为跨后端统一语义，上层据此走冲突流程
      throw CloudPreconditionFailedException(path, e.message);
    } on CloudAuthException {
      rethrow;
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to upload file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to upload file: $e');
    }
  }

  @override
  Future<String?> download({required String path}) async {
    try {
      final bytes = await downloadBinary(path: path);
      if (bytes == null) return null;
      return utf8.decode(bytes);
    } on CloudAuthException {
      // downloadBinary 已把 401/403 转成认证异常，这里必须原样透传，
      // 否则落入通用 catch 被降级为 CloudStorageException，上层无法
      // 依据异常类型引导用户修正凭据
      rethrow;
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to download file: ${e.message}');
    } catch (e) {
      throw CloudStorageException('Failed to download file: $e');
    }
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    try {
      // 从 S3 下载原始字节
      final bytes = await client.getObject(
        bucket: bucket,
        key: _buildKey(path),
      );
      return bytes;
    } on S3ObjectNotFoundException {
      return null;
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
      // 剥离 keyPrefix 后返回逻辑路径，与 listFiles 行为一致。
      // 过滤目录占位对象与空名（见 listFiles 内注释）。
      String stripPrefix(String k) => k.startsWith(keyPrefix)
          ? k.substring(keyPrefix.length)
          : k;
      return infos
          .map((info) => (name: stripPrefix(info.key), info: info))
          .where((e) => e.name.isNotEmpty && !e.name.endsWith('/'))
          .map((e) => CloudFile(
                name: e.name,
                path: e.name,
                size: e.info.size,
                lastModified: e.info.lastModified,
              ))
          .toList();
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
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
        eTag: info.eTag,
      );
    } on S3AuthException catch (e) {
      throw _authException(e);
    } on S3PermissionDeniedException catch (e) {
      throw _authException(e);
    } on S3Exception catch (e) {
      throw CloudStorageException('Failed to get metadata: ${e.message}');
    }
  }

  /// 构造实际 S3 key：剥离开头斜杠后前置 [keyPrefix]。
  ///
  /// S3 的 Key 不应该以 / 开头；前置前缀实现 bucket 内目录隔离。
  String _buildKey(String path) {
    var key = path.startsWith('/') ? path.substring(1) : path;
    // 拒绝路径遍历尝试：`..` 段可能逃逸 keyPrefix 隔离，访问到其他
    // 应用/前缀下的对象，造成越权读写
    _assertNoTraversal(key, 'path');
    return keyPrefix.isEmpty ? key : '$keyPrefix$key';
  }

  /// 审计 S3-21：按 `/` 分段后存在恰为 `..` 的段才拒绝。此前对整条路径做
  /// `contains('..')` 子串匹配，会误伤 `ledger..backup.json` 等合法文件名。
  static void _assertNoTraversal(String value, String field) {
    for (final seg in value.split('/')) {
      if (seg == '..') {
        throw CloudStorageException(
            'Invalid $field containing ".." path segment: $value');
      }
    }
  }
}
