import 'dart:convert';

import 'package:meta/meta.dart';

import '../core/cloud_provider.dart';
import '../core/data_serializer.dart';
import '../core/exceptions.dart';
import '../core/storage_service.dart';
import '../core/sync_status.dart';
import '../utils/logger.dart';

/// 归一化云端 metadata 值：剥离存储层写入的 'b64:' base64 包装。
///
/// S3 存储层上传时统一对 metadata 值做 base64 编码并加 'b64:' 前缀
/// （RFC 7230 头值安全），读取端应在存储层解码；但部分 S3 兼容网关
/// 会原样返回编码值或剥离 padding 导致解码回退，使指纹比较变成
/// '386c...' vs 'b64:Mzg2...' 永不相等 → 永远 outOfSync → 每次启动
/// 都弹「云端有更新」。在消费点（getStatus）做防御性归一化，
/// 无论存储层解码是否生效都能收敛；无前缀的历史明文值原样返回。
String? _normalizeMetaValue(String? value) {
  if (value == null) return null;
  if (value.startsWith('b64:')) {
    final payload = value.substring(4);
    // 直接解码；padding 被网关剥离时补齐后重试（base64.decode 抛
    // FormatException，utf8.decode 可能抛 ArgumentError，统一兜底原样返回）
    for (final candidate in [
      payload,
      payload.padRight((payload.length + 3) ~/ 4 * 4, '='),
    ]) {
      try {
        return utf8.decode(base64.decode(candidate));
      } catch (_) {
        continue;
      }
    }
  }
  return value;
}

/// 大小写无关读取云端 metadata 并归一化。
///
/// HTTP 头名大小写不敏感：S3 链路 x-amz-meta-* 的键经传输层统一转为
/// 小写（dart:io / package:http 均如此），写入端的 'uploadedAt'/'count'
/// 在读取端实际是 'uploadedat'/'count'。直接 [] 读取对混合大小写键恒
/// miss → uploadedAt 解析失败、方向判定退化到 lastModified 兜底。
/// 按小写匹配对 S3 与 WebDAV sidecar（保留原始键名）都兼容。
String? _metaValue(Map<String, dynamic>? metadata, String key) {
  if (metadata == null) return null;
  final target = key.toLowerCase();
  for (final entry in metadata.entries) {
    if (entry.key.toLowerCase() == target) {
      return _normalizeMetaValue(entry.value as String?);
    }
  }
  return null;
}

/// 从序列化 payload（JSON 对象形态）提取顶层 'count' 数值。
///
/// 仅顶层键读取，非 JSON / 无 count 键 / 类型异常一律返回 null
/// （与旧内联逻辑的静默语义一致）。供 upload/getStatus 写 metadata
/// 使用；调用方已解析过 payload 时可经 [CloudSyncManager.upload] 的
/// preParsedCount / getStatus 的 localParsedCount 直接传入跳过解析。
int? _extractTopLevelCount(String payload) {
  try {
    final json = jsonDecode(payload) as Map<String, dynamic>?;
    if (json != null && json.containsKey('count')) {
      return (json['count'] as num?)?.toInt();
    }
  } catch (_) {
    // Not JSON or doesn't have count field, ignore
  }
  return null;
}

/// [CloudSyncManager.upload] 的写后校验结论（审计 C3）。
@immutable
class CloudUploadResult {
  /// true = 写后校验通过，或后端无法提供 metadata 而无从校验（降级放行）。
  ///
  /// false = 云端指纹与本次写入**确定性不一致**：内容已被其他设备并发
  /// 覆盖，或网关返回了陈旧副本。调用方不应视为上传失败（数据已在
  /// 云端），但也不应据此标记「已同步」/清除本地脏标记 —— 保持脏状态，
  /// 由下次 getStatus 探测真实差异并进入冲突/合并流程。
  final bool verified;

  const CloudUploadResult({required this.verified});
}


/// Cached sync status entry
class _CachedStatus {
  final SyncStatus status;
  final DateTime cachedAt;

  _CachedStatus(this.status, this.cachedAt);

  bool isExpired(Duration ttl) {
    return DateTime.now().difference(cachedAt) > ttl;
  }
}

/// Cloud sync manager
///
/// Orchestrates sync operations between local and cloud storage.
/// Generic type [T] represents the business data type (e.g., ledger ID).
///
/// Example:
/// ```dart
/// final manager = CloudSyncManager<int>(
///   provider: supabaseProvider,
///   serializer: LedgerDataSerializer(db),
///   logger: CloudSyncLogger(onLog: (level, msg) => print('[$level] $msg')),
/// );
///
/// // Upload local data to cloud
/// await manager.upload(ledgerId: 123, path: 'ledgers/123.json');
///
/// // Check sync status
/// final status = await manager.getStatus(ledgerId: 123, path: 'ledgers/123.json');
/// ```
class CloudSyncManager<T> {
  /// Cloud provider instance
  final CloudProvider provider;

  /// Data serializer for business logic
  final DataSerializer<T> serializer;

  /// Logger instance
  final CloudSyncLogger? logger;

  /// Cache TTL (Time To Live) for sync status
  final Duration cacheTTL;

  /// Internal cache for sync status
  final Map<String, _CachedStatus> _statusCache = {};

  /// Creates a cloud sync manager
  ///
  /// [provider] - Cloud provider (Supabase, WebDAV, etc.)
  /// [serializer] - Business data serializer
  /// [logger] - Optional logger for debugging
  /// [cacheTTL] - Cache duration for sync status (default: 30 seconds)
  CloudSyncManager({
    required this.provider,
    required this.serializer,
    this.logger,
    this.cacheTTL = const Duration(seconds: 30),
  });

  /// Upload local data to cloud
  ///
  /// [data] - Business data to upload (e.g., ledger ID)
  /// [path] - Cloud storage path (e.g., 'ledgers/123.json')
  /// [metadata] - Optional metadata to attach
  /// [ifMatchEtag] - 方案C 乐观并发锚点：非空且后端支持条件写时，
  ///   仅当远端 ETag 仍等于该值才写入；远端已被其他设备修改则抛
  ///   [CloudPreconditionFailedException]（本次写入未落盘）。
  ///   后端不支持条件写时静默退化为盲上传（由写后校验兜底）。
  ///
  /// Throws [CloudNotAuthenticatedException] if user not authenticated.
  /// Throws [CloudStorageException] if upload fails.
  ///
  /// 审计 C3：返回写后校验结论。`verified=false` 表示上传后重读云端
  /// 指纹与本次写入不一致 —— 内容已被并发覆盖或网关返回陈旧副本。
  /// 调用方**不得**把它当上传失败（数据确实已在云端，硬抛会诱发盲目
  /// 重传覆盖他机新版本），但也**不得**据此标记「已同步」/清除本地脏
  /// 标记 —— 应保持脏状态，让下次 getStatus 探测到真实差异并走冲突/
  /// 合并流程。旧代码此场景只记日志，调用方无感知地清了脏标记，
  /// 并发覆盖被双重掩盖。
  ///
  /// Example:
  /// ```dart
  /// await manager.upload(
  ///   ledgerId: 123,
  ///   path: 'ledgers/123.json',
  ///   metadata: {'version': '1.0'},
  /// );
  /// ```
  Future<CloudUploadResult> upload({
    required T data,
    required String path,
    Map<String, String>? metadata,
    String? serializedData,
    String? fingerprint,
    String? ifMatchEtag,
    int? preParsedCount,
  }) async {
    logger?.info('Starting upload: $path');

    // 1. Check authentication
    final user = await provider.auth.currentUser;
    if (user == null) {
      logger?.error('Upload failed: User not authenticated');
      throw CloudNotAuthenticatedException();
    }

    try {
      // 2. Serialize business data
      //
      // F6：支持调用方注入预计算的序列化结果与指纹。业务层（如快照上传）
      // 往往刚导出过同一份数据用于本地指纹计算，复用可省一次全量导出，
      // 并消除两次导出之间 DB 再变化导致的「缓存指纹 ≠ 云端 metadata
      // 指纹」错位。二者须配套传入（指纹必须对应同一份序列化结果）。
      final payload = serializedData ?? await serializer.serialize(data);
      final actualFingerprint = fingerprint ?? serializer.fingerprint(payload);
      logger?.debug('Data serialized: ${payload.length} bytes');

      // 3. Calculate fingerprint
      logger?.debug('Fingerprint: $actualFingerprint');

      // 3.5 尝试从序列化数据中提取 count，写入 metadata 供 getStatus
      // 直接读取（无需下载全量文件）。
      //
      // preParsedCount：调用方（如 TransactionsSyncManager）往往已经
      // jsonDecode 过同一份 payload 提取元信息，这里允许直接传入已解析
      // 的 count，跳过对大快照的第二次 jsonDecode + 全树遍历。
      final count = preParsedCount ?? _extractTopLevelCount(payload);
      final countStr = count?.toString();

      // 4. Prepare metadata
      // 用户 metadata 放在前面，保留字段（fingerprint/uploadedAt/userId/count）
      // 在后覆盖，防止用户值污染关键字段导致 getStatus 指纹比对失效
      final fullMetadata = <String, String>{
        ...?metadata, // 用户值在前
        'fingerprint': actualFingerprint,
        // M4 跨时区一致性：uploadedAt 必须是 UTC（带 Z 后缀）。
        // 调用方（如 transactions_sync_manager）传入的 UTC 值原样保留，
        // 不得用本地 naive 时间覆盖 —— 否则跨时区设备 uploadedAt 解析
        // 偏移导致方向判断退化到 lastModified 兜底。
        'uploadedAt':
            metadata?['uploadedAt'] ?? DateTime.now().toUtc().toIso8601String(),
        'userId': user.id,
        if (countStr != null) 'count': countStr,
      };

      // 5. Upload to cloud storage
      //
      // 方案C：调用方传入乐观并发锚点（冲突探测时读到的云端 eTag）且
      // 后端支持条件写时，走条件上传 —— 远端在探测后被其他设备先行修改
      // 会抛 [CloudPreconditionFailedException]，本次写入不落盘，从
      // 「静默覆盖他机数据」变为显式冲突。不支持时退化为盲上传，
      // 由步骤 5.5 的写后校验兜底。
      final conditional = provider.storage.conditionalOrNull;
      if (ifMatchEtag != null && conditional != null) {
        await conditional.uploadBinaryConditional(
          path: path,
          bytes: utf8.encode(payload),
          metadata: fullMetadata,
          ifMatchEtag: ifMatchEtag,
        );
      } else {
        if (ifMatchEtag != null) {
          logger?.warning(
              'Conditional write requested but backend lacks support; '
              'falling back to blind upload: $path');
        }
        await provider.storage.upload(
          path: path,
          data: payload,
          metadata: fullMetadata,
        );
      }

      // 5.5 写后校验（defense-in-depth）：重新读取云端指纹，与我们写入的
      // 比对。不一致说明「写入被并发覆盖」或「网关返回了陈旧副本」。
      // 不硬抛 —— 部分网关（R2/OSS 边缘缓存）存在读写短暂不一致窗口，
      // 硬抛会把成功上传误报为失败；强一致保证由条件写承担。此处把
      // 结论经返回值上浮（审计 C3），并失效状态缓存让下次 getStatus
      // 强制重查真实指纹。
      final verified = await _verifyAfterUpload(path, actualFingerprint);

      // 6. Invalidate cache
      _statusCache.remove(path);

      logger?.info('Upload completed: $path');
      return CloudUploadResult(verified: verified);
    } catch (e) {
      logger?.error('Upload failed: $e');
      if (e is CloudSyncException) {
        rethrow;
      }
      throw CloudStorageException('Upload failed', e);
    }
  }

  /// 写后校验（方案C，defense-in-depth）。
  ///
  /// 上传成功后重读云端指纹与我们写入的比对。返回 false = 确定性不一致
  /// （云端已被并发覆盖）；true = 一致，或 metadata 不可用/无指纹字段
  /// 而无法校验（降级放行，绝不阻断已成功的上传）。审计 C3：结论不再
  /// 只进日志 —— 经 upload() 返回值上浮给调用方。
  Future<bool> _verifyAfterUpload(String path, String expectedFingerprint) async {
    try {
      final file = await provider.storage.getMetadata(path: path);
      final actual = _metaValue(file?.metadata, 'fingerprint');
      if (actual != null && actual != expectedFingerprint) {
        logger?.error('Post-upload verify FAILED (cloud fingerprint mismatch): '
            '$path (expected=$expectedFingerprint, actual=$actual)。'
            '云端内容可能已被并发覆盖或网关返回陈旧副本');
        // 失效缓存：下次 getStatus 强制重查，UI 会据真实指纹给出
        // outOfSync/conflict 判定
        _statusCache.remove(path);
        return false;
      }
      logger?.debug('Post-upload verify passed: $path');
      return true;
    } catch (e) {
      logger?.warning('Post-upload verify skipped (metadata unavailable): $e');
      return true;
    }
  }

  /// Download data from cloud
  ///
  /// [path] - Cloud storage path
  ///
  /// Returns deserialized business data, or null if file doesn't exist.
  /// Throws [CloudNotAuthenticatedException] if user not authenticated.
  /// Throws [CloudStorageException] if download fails.
  ///
  /// Example:
  /// ```dart
  /// final ledgerId = await manager.download(path: 'ledgers/123.json');
  /// if (ledgerId != null) {
  ///   // Process downloaded data
  /// }
  /// ```
  Future<T?> download({required String path}) async {
    logger?.info('Starting download: $path');

    // 1. Check authentication
    final user = await provider.auth.currentUser;
    if (user == null) {
      logger?.error('Download failed: User not authenticated');
      throw CloudNotAuthenticatedException();
    }

    try {
      // 2. Download from cloud storage
      //
      // 审计 M14：非 final —— 完整性校验的竞态重试会替换为重下的新内容，
      // 反序列化必须使用校验通过的最终版本。
      var serializedData = await provider.storage.download(path: path);

      if (serializedData == null) {
        logger?.info('Download completed: File not found');
        return null;
      }

      logger?.debug('Data downloaded: ${serializedData.length} bytes');

      // P4 完整性校验：metadata 带指纹时对下载内容重算指纹比对，防止
      // metadata 指纹与实际内容脱钩（S3 控制台改写/CDN 陈旧副本）把脏
      // 数据交给恢复流程。校验失败硬失败；metadata 读取失败不阻断
      // （部分后端旁路元数据缺失属自愈降级）。
      //
      // 审计 M14：「下载内容」与「读元数据」是两次独立请求，两请求之间
      // 被其他设备并发上传时会把合法新内容误判为损坏。故首次不一致时
      // 重试一次（重下内容 + 重读元数据）：并发竞态 → 第二次两者自洽，
      // 放行；真实脱钩（控制台改写 / 持久性陈旧副本）→ 仍不一致，硬失败。
      Future<bool> integrityOk() async {
        final cloudFile = await provider.storage.getMetadata(path: path);
        // metadata 值经 _metaValue 归一化：剥离存储层可能的 'b64:' 包装
        // （S3 兼容网关原样返回编码值），否则指纹永不相等；键按大小写
        // 无关匹配（S3 传输层会把头名转小写）。
        final expected = _metaValue(cloudFile?.metadata, 'fingerprint');
        if (expected == null) return true; // 无指纹可校验 → 放行
        return serializer.fingerprint(serializedData!) == expected;
      }

      try {
        var ok = await integrityOk();
        if (!ok) {
          logger?.warning('Integrity mismatch on first read '
              '(possible concurrent-update race), re-checking: $path');
          final retried = await provider.storage.download(path: path);
          if (retried != null) {
            serializedData = retried;
            ok = await integrityOk();
          } else {
            // 并发删除窗口：文件已不存在。沿用「元数据不可用」降级语义，
            // 不阻断本次返回；getStatus 后续探测会给出真实状态。
            logger?.warning('Integrity re-check skipped: file disappeared '
                'mid-verification (concurrent delete?): $path');
            ok = true;
          }
        }
        if (!ok) {
          logger?.error('Integrity check failed: $path '
              '(fingerprint mismatch persisted across re-read)');
          throw CloudStorageException(
              '云端数据完整性校验失败（指纹不匹配）: $path');
        }
        logger?.debug('Integrity check passed: $path');
      } on CloudSyncException {
        rethrow;
      } catch (e) {
        logger?.warning('Integrity check skipped (metadata unavailable): $e');
      }

      // 3. Deserialize business data（M14：使用校验通过的最终内容）
      final data = await serializer.deserialize(serializedData!);

      // 4. Invalidate cache
      _statusCache.remove(path);

      logger?.info('Download completed: $path');
      return data;
    } catch (e) {
      logger?.error('Download failed: $e');
      if (e is CloudSyncException) {
        rethrow;
      }
      throw CloudStorageException('Download failed', e);
    }
  }

  /// Get sync status
  ///
  /// [data] - Local business data (optional, for fingerprint comparison)
  /// [path] - Cloud storage path
  /// [localUpdatedAt] - Local data update timestamp (optional, for direction determination)
  /// [forceRefresh] - Bypass cache and fetch fresh status
  ///
  /// Returns [SyncStatus] with current sync state, direction, and timestamps.
  ///
  /// Example:
  /// ```dart
  /// final status = await manager.getStatus(
  ///   data: 123,
  ///   path: 'ledgers/123.json',
  ///   localUpdatedAt: DateTime.now(),
  /// );
  ///
  /// if (status.isLocalNewer) {
  ///   // Show "Upload" button
  /// } else if (status.isCloudNewer) {
  ///   // Show "Download" button
  /// }
  /// ```
  Future<SyncStatus> getStatus({
    T? data,
    required String path,
    DateTime? localUpdatedAt,
    bool forceRefresh = false,
    String? localSerializedData,
    int? localParsedCount,
  }) async {
    logger?.debug('Getting sync status: $path (forceRefresh: $forceRefresh)');

    // 1. Check cache
    if (!forceRefresh) {
      final cached = _statusCache[path];
      if (cached != null && !cached.isExpired(cacheTTL)) {
        logger?.debug('Returning cached status: $path');
        return cached.status;
      }
    }

    try {
      // 2. Check authentication
      final user = await provider.auth.currentUser;
      if (user == null) {
        const status = SyncStatus(
          state: SyncState.notAuthenticated,
          message: 'User not authenticated',
        );
        _cacheStatus(path, status);
        return status;
      }

      // 3. Calculate local fingerprint and extract metadata if data provided
      String? localFingerprint;
      int? localCount;
      String? localData;

      if (data != null) {
        // F6：调用方已持有序列化结果时直接复用，避免同一次状态检查内
        // 对同一账本做第二次全量导出（快照导出在大账本上代价可观）。
        localData = localSerializedData ?? await serializer.serialize(data);
        localFingerprint = serializer.fingerprint(localData);

        // localParsedCount：调用方（TSM.getStatus）已 jsonDecode 过同一份
        // payload 提取 count 时直接复用，跳过对大快照的第二次解析。
        localCount = localParsedCount ?? _extractTopLevelCount(localData);

        logger?.debug('Local fingerprint: $localFingerprint, count: $localCount');
      }

      // 4. Check if cloud file exists
      final cloudFile = await provider.storage.getMetadata(path: path);

      if (cloudFile == null) {
        final status = SyncStatus(
          state: SyncState.localOnly,
          localFingerprint: localFingerprint,
          message: 'No cloud backup found',
        );
        _cacheStatus(path, status);
        return status;
      }

      // 5. 提取云端指纹：优先从 metadata 读取（upload 时写入），避免
      // 每次 getStatus 都下载全量文件计算指纹（Major-08 修复）。
      // 仅当 metadata 中无 fingerprint 时，才回退到下载全量文件计算。
      String? cloudFingerprint;
      int? cloudCount;
      DateTime? cloudUpdatedAt;

      // metadata 值经 _metaValue 归一化：剥离存储层可能的 'b64:' 包装
      // （见其文档注释），否则指纹永不相等、count/uploadedAt 解析失败
      // （方向判断退化到 lastModified 兜底）；键大小写无关匹配（S3
      // 传输层会把 x-amz-meta-* 头名转小写）
      final metaFingerprint = _metaValue(cloudFile.metadata, 'fingerprint');
      final metaCountStr = _metaValue(cloudFile.metadata, 'count');
      final metaCount = metaCountStr != null ? int.tryParse(metaCountStr) : null;

      if (metaFingerprint != null) {
        // metadata 中有指纹，直接使用，无需下载全量文件
        cloudFingerprint = metaFingerprint;
        cloudCount = metaCount;

        // 尝试从 metadata 提取时间戳
        final uploadedAtStr = _metaValue(cloudFile.metadata, 'uploadedAt');
        if (uploadedAtStr != null) {
          cloudUpdatedAt = DateTime.tryParse(uploadedAtStr);
        }
        // 也尝试用文件的 lastModified 作为兜底
        cloudUpdatedAt ??= cloudFile.lastModified;

        logger?.debug(
            'Cloud fingerprint from metadata: $cloudFingerprint, count: $cloudCount (skipped full download)');
      } else {
        // metadata 中无指纹（旧格式或 provider 不支持 metadata），
        // 回退到下载全量文件计算指纹
        final cloudData = await provider.storage.download(path: path);

        if (cloudData != null) {
          cloudFingerprint = serializer.fingerprint(cloudData);

          // Try to extract metadata from cloud JSON
          try {
            final cloudJson = jsonDecode(cloudData) as Map<String, dynamic>?;
            if (cloudJson != null) {
              // Extract count
              if (cloudJson.containsKey('count')) {
                cloudCount = (cloudJson['count'] as num?)?.toInt();
              }

              // Extract exportedAt timestamp
              if (cloudJson.containsKey('exportedAt')) {
                final exportedAtStr = cloudJson['exportedAt'] as String?;
                if (exportedAtStr != null) {
                  cloudUpdatedAt = DateTime.tryParse(exportedAtStr);
                }
              }
            }
          } catch (_) {
            // Not JSON or missing fields, ignore
          }
        }

        logger?.debug(
            'Cloud fingerprint from full download: $cloudFingerprint, count: $cloudCount');
      }

      logger?.debug(
          'Cloud fingerprint: $cloudFingerprint, count: $cloudCount, updatedAt: $cloudUpdatedAt');

      // 6. Get last sync timestamp from metadata
      final lastSyncedAtStr = _metaValue(cloudFile.metadata, 'uploadedAt');
      final lastSyncedAt = lastSyncedAtStr != null
          ? DateTime.tryParse(lastSyncedAtStr)
          : cloudFile.lastModified;

      // 7. Compare fingerprints and determine state/direction
      SyncState state;
      SyncDirection? direction;
      String? message;

      if (localFingerprint == null) {
        // No local data to compare, just report cloud state
        state = SyncState.synced;
        message = 'Cloud backup exists';
      } else if (cloudFingerprint == null) {
        // No cloud data found
        state = SyncState.localOnly;
        direction = SyncDirection.localNewer;
        message = 'No cloud backup';
      } else if (localFingerprint == cloudFingerprint) {
        // Fingerprints match - data is synced
        state = SyncState.synced;
        message = 'Local and cloud data match';
      } else {
        // Fingerprints differ - data is out of sync
        state = SyncState.outOfSync;

        // Determine direction using timestamps or counts
        if (localUpdatedAt != null && cloudUpdatedAt != null) {
          // Use timestamps if available
          if (localUpdatedAt.isAfter(cloudUpdatedAt)) {
            direction = SyncDirection.localNewer;
            message = 'Local data is newer (timestamp)';
          } else if (cloudUpdatedAt.isAfter(localUpdatedAt)) {
            direction = SyncDirection.cloudNewer;
            message = 'Cloud data is newer (timestamp)';
          } else {
            direction = SyncDirection.unknown;
            message = 'Data differs but same timestamp';
          }
        } else if (localCount != null && cloudCount != null) {
          // Fallback to count comparison
          if (localCount > cloudCount) {
            direction = SyncDirection.localNewer;
            message = 'Local has more items ($localCount vs $cloudCount)';
          } else if (cloudCount > localCount) {
            direction = SyncDirection.cloudNewer;
            message = 'Cloud has more items ($cloudCount vs $localCount)';
          } else {
            direction = SyncDirection.unknown;
            message = 'Data differs but same count';
          }
        } else {
          // Cannot determine direction
          direction = SyncDirection.unknown;
          message = 'Local and cloud data differ';
        }
      }

      final status = SyncStatus(
        state: state,
        localFingerprint: localFingerprint,
        cloudFingerprint: cloudFingerprint,
        lastSyncedAt: lastSyncedAt,
        localUpdatedAt: localUpdatedAt,
        cloudUpdatedAt: cloudUpdatedAt,
        direction: direction,
        localCount: localCount,
        cloudCount: cloudCount,
        message: message,
      );

      _cacheStatus(path, status);
      logger?.info('Sync status: $state');
      return status;
    } catch (e) {
      logger?.error('Get status failed: $e');
      // Major-12 修复：错误状态不写入缓存，避免瞬时错误（网络抖动、
      // 临时 401、salt 错配）在 cacheTTL 期间持续阻挡，下次调用应
      // 重新走完整流程。
      final status = SyncStatus(
        state: SyncState.error,
        message: 'Failed to get sync status: $e',
      );
      return status;
    }
  }

  /// Delete remote file
  ///
  /// [path] - Cloud storage path
  ///
  /// Throws [CloudNotAuthenticatedException] if user not authenticated.
  /// Throws [CloudStorageException] if deletion fails.
  ///
  /// Example:
  /// ```dart
  /// await manager.deleteRemote(path: 'ledgers/123.json');
  /// ```
  Future<void> deleteRemote({required String path}) async {
    logger?.info('Deleting remote file: $path');

    // 1. Check authentication
    final user = await provider.auth.currentUser;
    if (user == null) {
      logger?.error('Delete failed: User not authenticated');
      throw CloudNotAuthenticatedException();
    }

    try {
      // 2. Delete from cloud storage
      await provider.storage.delete(path: path);

      // 3. Invalidate cache
      _statusCache.remove(path);

      logger?.info('Delete completed: $path');
    } catch (e) {
      logger?.error('Delete failed: $e');
      if (e is CloudSyncException) {
        rethrow;
      }
      throw CloudStorageException('Delete failed', e);
    }
  }

  /// Clear all cached status
  void clearCache() {
    logger?.debug('Clearing status cache');
    _statusCache.clear();
  }

  /// Cache sync status
  void _cacheStatus(String path, SyncStatus status) {
    _statusCache[path] = _CachedStatus(status, DateTime.now());
  }
}
