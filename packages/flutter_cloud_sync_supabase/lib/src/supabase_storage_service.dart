library;

import 'dart:async' show TimeoutException;
import 'dart:convert';
import 'dart:developer' as dev;
import 'dart:io' show HttpException, SocketException;
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

/// Supabase implementation of [CloudStorageService].
///
/// P1-4（2026-09-09）：实现 [BinaryCapableStorage] —— Supabase SDK 的
/// uploadBinary/download 本身就是字节接口，此前未实现可选能力接口导致
/// 附件/ZIP 备份恒走 base64 文本兜底（流量 +33%、云端文件非原生格式）。
/// 实现后 [CloudStorageBinaryExt] 自动分派到真字节路径，与 S3/WebDAV
/// 归一；旧行为（base64 文本对象）由 downloadBinary 的嗅探兜底兼容读取。
///
/// 2026-09-11 归一化批次（对照 docs/sync-comprehensive-audit-2026-09-10.md）：
/// - P0-1：list() 改走 listPaginated 游标翻页 —— 旧 list() 不传
///   SearchOptions，SDK 默认 limit:100 静默截断；目录超 100 对象后
///   exists()/getMetadata()（当时依赖同一 list）把第 101+ 个对象误判
///   不存在，触发重复上传/覆盖、发现流程漏账本。exists() 同步改为
///   游标翻页全量判定。
/// - P1-8：幂等读重试（download/downloadBinary/list/getMetadata/exists/
///   delete），对齐 WebDAV `_retryIdempotent` 参数（2 次、400/800ms ±50%
///   真随机 jitter）；非幂等写（upload/upsert 覆盖语义）不重试。
/// - P1-1：实现 [ConditionalWriteStorage] 读后比对近似（对齐 WebDAV
///   模式：探测 updatedAt/lastModified 锚点 → 比对 → upsert，窗口收窄
///   非原子，写后校验兜底），Supabase Storage 无 If-Match 语义。
/// - P1-1b：CloudFile.path 口径修正 —— 旧实现返回带 users/{uid}/ 前缀的
///   fullPath，与其他包「相对路径可回传」契约分裂（回传 delete/exists
///   会双拼前缀）；现统一返回调用方视角的相对路径（name=basename、
///   path=与入参同目录的相对路径）。
/// - P1-1c（2026-09-11）→ N-2 修订（2026-09-12）：_storeMetadata 失败
///   从「静默降级」（P1-1c 曾改为上抛 MetadataPersistFailedException，
///   实测使整个 upload 记 failed 且缺表环境 100% 硬失败）修订为「留痕
///   不上抛」—— 指纹缺失由 manager 写后校验以 verified=false 上浮
///   （softFail），消除「指纹永久缺失 → getStatus 反复全量下载」的
///   无痕退化，同时不引入缺表环境的可用性回归。
class SupabaseStorageService
    implements CloudStorageService, BinaryCapableStorage, ConditionalWriteStorage {
  final supabase.SupabaseClient _client;
  final String _bucketName;
  final String? _pathPrefix;

  /// LOG-01（Supabase 侧收编，对齐 WebDAV storageLogger / S3 downgradeLogger
  /// 模式）：metadata DB 表读写失败等「继续工作但环境异常」的关键告警，
  /// 此前走 dev.log 只到 console，release 构建用户排查时线索丢失。
  /// 由 provider 装配处注入；未注入时静默（测试无感）。
  static CloudSyncLogger? storageLogger;

  SupabaseStorageService(this._client, this._bucketName, [this._pathPrefix]);

  /// P0-3：单次操作超时。Supabase SDK 未暴露底层 http client 超时配置，
  /// 服务器无响应时 future 永不完成会让同步 UI 永久挂起（S3/WebDAV/iCloud
  /// 均已有超时护栏，此处对齐）。60s 与 WebDAV _opTimeout 同档。
  static const _opTimeout = Duration(seconds: 60);

  /// P1-8：幂等读重试参数，对齐 WebDAV `_retryIdempotent`（2 次重试、
  /// 400ms/800ms 基数 ±50% 真随机 jitter）。真随机源与 WebDAV/S3 同款
  /// （P1-1 修复：时间戳取模同相会让整点重试风暴，jitter 失效）。
  static const _maxRetries = 2;
  final Random _retryRandom = Random();

  /// P0-1：单页对象数。listPaginated 服务器端默认 1000；显式传值便于
  /// 测试与未来调参，且与翻页终止条件（不足一页）解耦。
  static const _pageLimit = 1000;

  /// P0-1：翻页安全护栏 —— 游标异常（服务端 bug/异常目录）时防无限翻页。
  static const _maxPages = 100;

  /// P0-3：统一错误分类器。
  ///
  /// ① 404 判定收敛为 `statusCode == '404'` 精确匹配 —— 旧实现
  /// `e.message.contains('not found')` 在错误消息内嵌对象路径（路径含
  /// "not found" 子串的合法文件名）时误判为「不存在」，进而
  /// exists()=false → 触发覆盖上传等危险操作（与 iCloud P0-2 同款
  /// 子串误判模式）。statusCode 是 SDK 结构化字段，精确可信；仅当
  /// statusCode 为 null（SDK 某些路径不填）时才回退措辞匹配，且
  /// 匹配串收紧为 `Object not found`（Storage API 的标准错误文案）。
  /// ② 401/403 翻译为 [CloudAuthException] —— 认证失败与网络故障的
  /// 处置动作完全不同（改凭据 vs 查网络），上层（enableFromCloud 探测、
  /// 启动检查器）依赖异常类型引导用户，误报为存储故障会误导排查方向
  /// （对齐 S3/WebDAV 的 CloudAuthException 语义）。
  CloudSyncException _classify(String op, supabase.StorageException e) {
    final code = e.statusCode;
    if (code == '401' || code == '403') {
      return CloudAuthException(
        code == '403' ? 'Supabase 访问被拒绝（权限不足）：请检查 bucket 策略或 anonKey 权限' : 'Supabase 认证失败（anonKey 无效或已过期）',
        e,
      );
    }
    return CloudStorageException('$op failed: ${e.message}', e);
  }

  /// P0-3：404 精确判定（见 [_classify] 注释：statusCode 精确匹配，
  /// 无结构化码时才回退标准措辞，不做子串数字匹配）。
  bool _isNotFound(supabase.StorageException e) {
    final code = e.statusCode;
    if (code != null) return code == '404';
    return e.message.contains('Object not found') ||
        e.message.contains('not found');
  }

  /// P0-3：超时包装（对齐 WebDAV _op 策略）。
  Future<T> _op<T>(String opName, Future<T> Function() op) {
    return op().timeout(_opTimeout, onTimeout: () {
      throw CloudStorageException(
          'Supabase $opName 超时（${_opTimeout.inSeconds}s），请检查网络或服务器');
    });
  }

  /// P1-8：幂等操作组合入口 —— [_op] 超时 + 自动重试。
  ///
  /// 可重试判定（对齐 WebDAV）：异常无状态码（连接层故障/超时包装后的
  /// CloudStorageException）或 Postgrest/Storage 5xx 类瞬时故障。认证类
  /// 与 4xx 确定性失败立即上抛，不消耗重试预算。
  Future<T> _opRetryable<T>(String opName, Future<T> Function() op) async {
    var attempt = 0;
    while (true) {
      try {
        return await _op(opName, op);
      } catch (e) {
        if (e is CloudNotAuthenticatedException || e is CloudAuthException) {
          rethrow; // 改凭据才能解决，重试无意义
        }
        if (e is MetadataPersistFailedException) rethrow;
        final retriable = attempt < _maxRetries && _isTransient(e);
        if (!retriable) rethrow;
        attempt++;
        storageLogger?.info(
            '[Supabase] $opName 瞬时故障，第 $attempt/$_maxRetries 次重试: $e');
        // 指数退避 + 真随机抖动：400ms、800ms（各 ±50% 区间均匀分布），
        // 与 WebDAV _retryIdempotent 同参数表（sync-reliability-params.md）
        final baseMs = 400 * (1 << (attempt - 1));
        final jitter = _retryRandom.nextInt(baseMs ~/ 2 + 1);
        await Future<void>.delayed(
            Duration(milliseconds: baseMs ~/ 2 + jitter));
      }
    }
  }

  /// 瞬时故障判定：超时包装（CloudStorageException 且 originalError 为空）
  /// 或底层 SocketException/TimeoutException；Supabase SDK 的 5xx 经
  /// StorageException.statusCode 字符串判（'5xx' 前缀）。
  ///
  /// N-8 修复（2026-09-12）：无结构化码时的文本兜底从 toString 子串
  /// （曾含 'network'/'connection'/'timeout' 宽词——确定性 4xx 的错误
  /// 文案含这些词即被误判可重试，浪费预算+延迟）收紧为**异常类型判定**
  /// （SocketException / TimeoutException / HttpException 的运行时类型），
  /// 与 S3 `_isTransient` 的类型化口径对齐。Web 平台无 dart:io 类型时
  /// 保留 'socketexception'/'timeoutexception' 两个类型名字符串兜底
  /// （对应 dart:html 抛出的同名字符串形态），不再匹配消息内容。
  bool _isTransient(Object e) {
    Object? root = e;
    // 解开 CloudStorageException 的 originalError 包装
    while (root is CloudStorageException && root.originalError != null) {
      root = root.originalError;
    }
    if (root is supabase.StorageException) {
      final code = root.statusCode;
      if (code == null) return true; // 无结构化码 → 连接层故障
      return code.startsWith('5');
    }
    if (root is SocketException) return true;
    if (root is TimeoutException) return true;
    if (root is HttpException) return true;
    // Web 平台兜底：dart:html 的网络层异常无 dart:io 类型，按类型名匹配
    final typeName = root.runtimeType.toString().toLowerCase();
    return typeName.contains('socketexception') ||
        typeName.contains('timeoutexception');
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    await _uploadBytes(
      opName: 'upload',
      path: path,
      bytes: utf8.encode(data),
      contentType: 'application/json',
      metadata: metadata,
    );
  }

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    await _uploadBytes(
      opName: 'uploadBinary',
      path: path,
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      contentType: 'application/octet-stream',
      metadata: metadata,
    );
  }

  /// upload/uploadBinary 共用核心（upsert 覆盖语义；P1-8：非幂等写不重试）。
  Future<void> _uploadBytes({
    required String opName,
    required String path,
    required Uint8List bytes,
    required String contentType,
    Map<String, String>? metadata,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);
      await _op(
        opName,
        () => _client.storage.from(_bucketName).uploadBinary(
              fullPath,
              bytes,
              fileOptions: supabase.FileOptions(
                upsert: true,
                contentType: contentType,
                cacheControl: '3600',
              ),
            ),
      );
      if (metadata != null && metadata.isNotEmpty) {
        // N-2（2026-09-12）：元数据持久化失败不再上抛 —— 上抛路径会让
        // 整个 upload 记 failed（manager 的 catch 按 CloudStorageException
        // 整体上抛，TSM 计硬失败），且 file_metadata 表未建的存量环境下
        // Supabase 上传会从「静默降级可工作」变为 100% 硬失败。改为
        // 返回失败信号：主对象已在云端，manager 写后校验读不到指纹会以
        // verified=false 上浮 softFail（数据在、未确认收敛），与
        // MetadataPersistFailedException 的原始设计声明对齐。判定失败的
        // warning 已在此留痕（含表未建/RSL 策略的排查指引）。
        await _storeMetadata(fullPath, metadata);
      }
    } on supabase.StorageException catch (e) {
      throw _classify(opName, e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('$opName failed: $e', e);
    }
  }

  /// P1-1：读后比对近似条件写（对齐 WebDAV 模式）。
  ///
  /// Supabase Storage 无 If-Match 语义（upsert 恒覆盖），本实现以
  /// 「重读远端锚点 → 比对 → upsert」收窄并发窗口：
  /// - [ifMatchEtag]：锚点取 getMetadata 透出的 eTag（updatedAt/
  ///   lastModified 归一化形态）。比对不一致（或锚点缺失于已存在对象）
  /// → 抛 [CloudPreconditionFailedException]，本次不落盘；
  /// - [ifNoneMatch]：探测对象存在即抛条件失败（create-only 语义）；
  /// - 窗口内（比对 → 落盘）他机写入仍可能被覆盖 —— 非原子，与
  ///   WebDAV 实现同款取舍，由 manager 层写后校验兜底（verified=false
  ///   → softFail，脏标记不清）。
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
    if (ifMatchEtag != null && ifNoneMatch) {
      throw ArgumentError('ifMatchEtag 与 ifNoneMatch 互斥');
    }
    final user = _client.auth.currentUser;
    if (user == null) {
      throw CloudNotAuthenticatedException('User not authenticated');
    }
    final fullPath = _buildUserPath(user.id, path);

    final current = await _opRetryable(
        'conditionalProbe', () => _probeRawMetadata(fullPath));

    if (ifNoneMatch) {
      if (current != null) {
        // N-13：双参构造（path, message）—— 单参会把整句消息当 path
        // 字段污染，与 S3/WebDAV 的构造口径分裂。
        throw CloudPreconditionFailedException(path,
            '远端对象已存在（create-only 条件失败）');
      }
    } else if (ifMatchEtag != null) {
      if (current == null) {
        // 远端不存在同样算条件失败（对齐接口契约：探测时存在、
        // 写入时消失 = 中途被并发改动/删除，按冲突处理）
        throw CloudPreconditionFailedException(path,
            '远端对象已不存在（条件锚点失效）');
      }
      final currentEtag = _etagOf(current);
      if (currentEtag == null || currentEtag != ifMatchEtag) {
        throw CloudPreconditionFailedException(path,
            '远端对象已被并发修改（锚点 $ifMatchEtag ≠ 当前 $currentEtag）');
      }
    }

    await _uploadBytes(
      opName: 'uploadBinaryConditional',
      path: path,
      bytes: bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
      contentType: 'application/octet-stream',
      metadata: metadata,
    );
  }

  /// 条件写探测：直接调 listPaginated 单页在对象父目录内定位（复用
  /// P0-1 翻页语义，小目录单页即命中）。返回原始条目或 null。
  Future<_RemoteEntry?> _probeRawMetadata(String fullPath) async {
    final dir = PathHelper.dirname(fullPath);
    final base = PathHelper.basename(fullPath);
    String? cursor;
    for (var page = 0; page < _maxPages; page++) {
      final result = await _client.storage.from(_bucketName).listPaginated(
            options: supabase.PaginatedSearchOptions(
              prefix: dir.isEmpty ? '' : '$dir/',
              limit: _pageLimit,
              cursor: cursor,
            ),
          );
      for (final obj in result.objects) {
        // 对象 name 为 basename；key 为完整对象键（兼容部分实现只回 name）
        final name = obj.name;
        final key = obj.key ?? (dir.isEmpty ? name : '$dir/$name');
        if (name == base || key == fullPath) {
          return _RemoteEntry(
            name: obj.name,
            size: _sizeOfMeta(obj.metadata),
            updatedAt: obj.updatedAt,
            etag: null, // PaginatedFile 无 etag 字段，eTag 由 _getMetadata 全量补
            metadata: obj.metadata,
          );
        }
      }
      if (!result.hasNext || result.nextCursor == null) break;
      cursor = result.nextCursor;
    }
    return null;
  }

  /// eTag 归一化：PaginatedFile 无 etag 字段，以 updatedAt（内容变更时间，
  /// 覆盖写必刷新）作为等价锚点 —— 比对语义与 S3 eTag 一致（探测时读到的
  /// 值 vs 写入时重读的值，任何他机覆盖都会刷新该值）。
  String? _etagOf(_RemoteEntry o) => o.updatedAt;

  /// FileObjectV2/PaginatedFile 的 metadata map 中取 size。
  int? _sizeOfMeta(Map<String, dynamic>? m) {
    final s = m?['size'];
    if (s is int) return s;
    if (s is num) return s.toInt();
    return null;
  }

  DateTime? _parseDate(String? raw) =>
      raw == null ? null : DateTime.tryParse(raw);

  @override
  Future<String?> download({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);
      final bytes = await _opRetryable(
          'download', () => _client.storage.from(_bucketName).download(fullPath));
      return utf8.decode(bytes);
    } on supabase.StorageException catch (e) {
      // Return null if file not found
      if (_isNotFound(e)) {
        return null;
      }
      throw _classify('Download', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('Download failed: $e', e);
    }
  }

  /// P1-4：原生字节下载。404 → null（对齐 [download] 幂等语义）；
  /// 旧行为遗留的 base64 文本对象（实现 BinaryCapableStorage 之前经
  /// 兜底路径写入的）由调用方嗅探（如备份恢复的 ZIP 魔数探测、附件的
  /// sha256 终审）保证兼容，本层不做形态猜测。
  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);
      final bytes = await _opRetryable(
          'downloadBinary', () => _client.storage.from(_bucketName).download(fullPath));
      return bytes;
    } on supabase.StorageException catch (e) {
      if (_isNotFound(e)) {
        return null;
      }
      throw _classify('DownloadBinary', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('DownloadBinary failed: $e', e);
    }
  }

  /// delete 是幂等操作（404 视为成功），纳入 P1-8 重试。
  @override
  Future<void> delete({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);
      await _opRetryable('remove', () async {
        try {
          return await _client.storage.from(_bucketName).remove([fullPath]);
        } on supabase.StorageException catch (e) {
          // 忽略 404（文件不存在），删除操作幂等
          if (!_isNotFound(e)) rethrow;
          return <dynamic>[];
        }
      });
      await _deleteMetadata(fullPath);
    } on supabase.StorageException catch (e) {
      throw _classify('Delete', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('Delete failed: $e', e);
    }
  }

  /// P0-1：list() 改走 listPaginated 游标翻页，取回目录下**全部**对象。
  ///
  /// 旧实现调 list() 不传 SearchOptions —— SDK 默认 limit:100 静默截断，
  /// 多账本+附件用户（对象数轻易破百）在发现/清理流程漏对象、
  /// exists() 把第 101+ 个对象误判不存在。
  ///
  /// path 口径（P1-1b）：返回的 CloudFile.path 是**调用方视角的相对路径**
  /// （与入参 path 同目录），不带 users/{uid}/ 前缀 —— 旧实现返回
  /// fullPath，调用方把 CloudFile.path 回传 delete/exists 时会双拼前缀。
  @override
  Future<List<CloudFile>> list({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);

      final objects = await _opRetryable(
          'list', () => _listAllObjects(fullPath));

      return objects
          .map((obj) {
            // 相对路径 = 入参目录 + basename；入参 path 本身可能带
            // 前缀（如 'attachments/'），保持与调用方入参一致
            final relPath = PathHelper.join([path, obj.name]);
            return CloudFile(
              name: obj.name,
              path: relPath,
              size: obj.size,
              lastModified: _parseDate(obj.updatedAt),
              metadata: obj.metadata,
              // 列表接口无 etag 字段；updatedAt 是「内容变更时间」的
              // 等价锚点（Supabase 覆盖写必刷新 updatedAt），供条件写
              // 比对（对齐 S3 eTag 的用途位）
              eTag: obj.updatedAt,
            );
          })
          .toList();
    } on supabase.StorageException catch (e) {
      // P1-9：空目录/前缀不存在时 Supabase 可能返回 404 —— 归一为
      // 空列表（对齐 WebDAV :627-634 与 iCloud :137-139 的收敛语义），
      // 调用方无需 catch 吞错。
      if (_isNotFound(e)) {
        return const <CloudFile>[];
      }
      throw _classify('List', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('List failed: $e', e);
    }
  }

  /// 游标翻页取回 prefix 下全部条目（P0-1）。
  ///
  /// - hasNext/nextCursor 驱动翻页；护栏 [_maxPages] 防游标异常死循环；
  /// - size 优先取 metadata['size']（PaginatedFile 携带），getMetadata
  ///   单对象探测路径会经 _getMetadata 补全 DB 侧自定义元数据；
  /// - 翻页参数必须含 prefix 尾斜杠（Supabase 按前缀匹配，'a' 会命中
  ///   'ab.txt'）—— 空目录（根列举）传 ''。
  ///
  /// N-3（2026-09-12）：护栏触达不再静默 —— 返回条目可能不完整
  /// （>10 万对象的异常目录），warning 留痕供健康排查发现，语义对齐
  /// S3 分页的畸形响应告警。
  Future<List<_RemoteEntry>> _listAllObjects(String prefix) async {
    final all = <_RemoteEntry>[];
    String? cursor;
    for (var page = 0; page < _maxPages; page++) {
      final result = await _client.storage.from(_bucketName).listPaginated(
            options: supabase.PaginatedSearchOptions(
              prefix: prefix.isEmpty ? '' : '$prefix/',
              limit: _pageLimit,
              cursor: cursor,
            ),
          );
      for (final obj in result.objects) {
        all.add(_RemoteEntry(
          name: obj.name,
          size: _sizeOfMeta(obj.metadata),
          updatedAt: obj.updatedAt,
          etag: null,
          metadata: obj.metadata,
        ));
      }
      if (!result.hasNext || result.nextCursor == null) break;
      cursor = result.nextCursor;
      if (page == _maxPages - 1) {
        storageLogger?.warning(
            '[Supabase] list 翻页护栏触达（${_maxPages} 页 × $_pageLimit 条），'
            '目录 $prefix 的返回可能不完整 —— 请检查是否存在异常目录堆积');
      }
    }
    return all;
  }

  /// P0-1：exists() 改走翻页全量判定（旧实现单次 list 100 条截断 →
  /// 第 101+ 个对象误判不存在 → 重复上传/覆盖）。
  @override
  Future<bool> exists({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);
      final found = await _opRetryable(
          'exists', () => _probeRawMetadata(fullPath));
      return found != null;
    } on supabase.StorageException catch (e) {
      if (_isNotFound(e)) {
        return false;
      }
      throw _classify('Exists check', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
        rethrow;
      }
      throw CloudStorageException('Exists check failed: $e', e);
    }
  }

  @override
  Future<CloudFile?> getMetadata({required String path}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) {
        throw CloudNotAuthenticatedException('User not authenticated');
      }
      final fullPath = _buildUserPath(user.id, path);

      // P0-1：翻页定位（不再单次 list 截断）
      final file = await _opRetryable(
          'getMetadata', () => _probeRawMetadata(fullPath));
      if (file == null) return null;

      // Get stored custom metadata
      final customMetadata = await _getMetadata(fullPath);

      return CloudFile(
        name: file.name,
        // P1-1b：调用方视角相对路径（可安全回传 delete/exists）
        path: path,
        size: file.size,
        lastModified: _parseDate(file.updatedAt),
        eTag: _etagOf(file),
        metadata: {
          ...?file.metadata,
          ...customMetadata,
        },
      );
    } on supabase.StorageException catch (e) {
      if (_isNotFound(e)) {
        return null;
      }
      throw _classify('Get metadata', e);
    } catch (e) {
      if (e is CloudNotAuthenticatedException ||
          e is CloudAuthException ||
          e is CloudStorageException) {
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
  /// P1-1c（2026-09-11）→ N-2 修订（2026-09-12）：幂等 upsert 重试 1 次
  /// 后仍失败**不再上抛** —— 上抛会让整个 upload 按存储异常整体失败
  /// （manager catch → TSM 记 failed），file_metadata 表未建的存量环境
  /// 下 Supabase 上传从「静默降级可工作」变为 100% 硬失败。改为：失败
  /// 只留 warning（含表未建/RSL 策略排查指引），指纹缺失由 manager 写后
  /// 校验自然发现（getMetadata 读不到 → verified=false → softFail），
  /// 与「数据在云端、未确认收敛」的语义对齐。表建好后下次上传自动补写
  /// 指纹，无需人工干预。
  Future<void> _storeMetadata(
      String path, Map<String, String> metadata) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await _client.from('file_metadata').upsert({
          'path': path,
          'metadata': metadata,
          'updated_at': DateTime.now().toIso8601String(),
        });
        return;
      } catch (e) {
        storageLogger?.warning(
            '[Supabase] metadata storage failed for $path (attempt $attempt/2): $e');
        if (attempt == 2) {
          // N-2：吞掉最终失败 —— 主对象已在云端，指纹缺失走写后校验
          // softFail 路径（见方法注释）。dev.log 保留 console 线索。
          dev.log('[Supabase] metadata storage failed for $path: $e', name: 'SupabaseStorage');
        }
      }
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
      storageLogger?.warning('[Supabase] getMetadata failed for $path: $e');
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
      storageLogger?.warning(
          '[Supabase] deleteMetadata Postgrest error for $path: ${e.message} (code: ${e.code})');
    } catch (e) {
      storageLogger?.warning('[Supabase] deleteMetadata failed for $path: $e');
    }
  }
}

/// 翻页条目的内部归一记录：隔离 SDK 类型（PaginatedFile / FileObjectV2
/// 字段集随版本演进），本文件内统一消费。
class _RemoteEntry {
  final String name;
  final int? size;
  final String? updatedAt;
  final String? etag;
  final Map<String, dynamic>? metadata;

  const _RemoteEntry({
    required this.name,
    this.size,
    this.updatedAt,
    this.etag,
    this.metadata,
  });
}

/// P1-1c（2026-09-11）→ N-2 修订（2026-09-12）：元数据持久化失败信号。
///
/// 历史上（P1-1c 批次）曾把该异常从 `_storeMetadata` 上抛以结束静默
/// 降级；实测上抛路径使整个 upload 记 failed，且 file_metadata 表未建
/// 的存量环境下 Supabase 上传 100% 硬失败（可用性回归）。N-2 修订后
/// `_storeMetadata` 失败只留 warning、不上抛 —— 指纹缺失由 manager
/// 写后校验发现（verified=false → softFail）。本异常类型保留导出：
/// 供未来调用方精确识别「内容在、元数据缺」场景（如维护页提示补建
/// file_metadata 表），当前生产代码不再依赖其上抛语义。
class MetadataPersistFailedException extends CloudStorageException {
  MetadataPersistFailedException(String message, [Object? cause])
      : super(message, cause);
}
