import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' show Random;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 's3_object_info.dart';
import 's3_signature.dart';
import 's3_exceptions.dart';

export 's3_object_info.dart';

/// S3 REST API 客户端
///
/// 实现基础的 S3 操作：
/// - PutObject: 上传对象
/// - GetObject: 下载对象
/// - DeleteObject: 删除对象
/// - HeadObject: 检查对象是否存在
/// - ListObjectsV2 / ListObjects: 列出对象
///
/// 支持两种寻址方式：
/// - path-style（默认）:      `https://endpoint[:port]/bucket/key`
/// - virtual-hosted-style:   `https://bucket.endpoint[:port]/key`
///
/// 通过 [forcePathStyle] 控制：托管云（AWS/OSS/COS/R2 等）应使用
/// virtual-hosted-style；自托管（MinIO 等）通常使用 path-style。
class S3Client {
  final String endpoint;
  final String region;
  final String accessKey;
  final String secretKey;
  final bool useSSL;
  final int? port;

  /// true 使用 path-style（`/bucket/...`）；false 使用 virtual-hosted-style（`bucket.endpoint/...`）
  final bool forcePathStyle;

  late final S3SignatureV4 _signer;
  late final http.Client _httpClient;

  /// 审计 S22 测试口：暴露签名器以断言时钟偏移写入。
  S3SignatureV4 get signerForTest => _signer;

  /// HTTP 请求超时时间（M-02 修复）
  ///
  /// 所有 S3 API 请求（put/get/delete/head/list）均受此限制，
  /// 防止服务器无响应时同步 UI 无限挂起。超时后抛 [S3NetworkException]。
  final Duration timeout;

  /// dispose 标志：避免释放后继续使用导致状态错误
  bool _disposed = false;

  /// P5：重试延迟随机数发生器（jitter 用）。实例级，生命周期与 client 一致。
  final Random _random = Random();

  S3Client({
    required this.endpoint,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.useSSL = true,
    this.port,
    this.forcePathStyle = true,
    this.timeout = const Duration(seconds: 30),
    http.Client? httpClient,
  }) {
    _signer = S3SignatureV4(
      accessKey: accessKey,
      secretKey: secretKey,
      region: region,
    );

    _httpClient = httpClient ?? http.Client();
  }

  /// 释放资源
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _httpClient.close();
  }

  /// 校验未释放：所有公开方法入口调用，防止 dispose 后误用导致
  /// 请求发送到已关闭的 httpClient 或状态混乱
  void _checkDisposed() {
    if (_disposed) {
      throw StateError('S3Client has been disposed');
    }
  }

  /// 对幂等操作执行指数退避重试，避免瞬时网络故障导致同步失败
  ///
  /// 仅重试 [S3NetworkException]（瞬时网络故障）和 5xx 服务端错误；
  /// 4xx 客户端错误（认证失败、权限不足、参数错误等）立即抛出，
  /// 避免无意义重试浪费时间和请求配额。
  /// putObject 非幂等（重复写入可能造成数据覆盖语义问题），不使用此方法。
  Future<T> _retry<T>(Future<T> Function() operation, {int maxRetries = 3}) async {
    int attempt = 0;
    while (true) {
      try {
        return await operation();
      } on S3ClockSkewException {
        // 审计 S22：时钟偏差——_handleError 已按服务器时间写入签名偏移，
        // 立即用新偏移重试一次。计入 maxRetries 预算（attempt++）：
        // 偏差持续存在时终止循环，避免无限重试。
        await Future.delayed(const Duration(milliseconds: 200));
        attempt++;
        if (attempt >= maxRetries) rethrow;
      } on S3NetworkException {
        // 网络瞬时故障（SocketException/Timeout）可安全重试
        attempt++;
        if (attempt >= maxRetries) rethrow;
        // P5：指数退避 + jitter（1s/2s/4s 的 50%~100% 区间）
        await Future.delayed(retryDelayForTest(attempt));
      } on S3Exception catch (e) {
        // 5xx 状态码表示服务端临时错误，可重试
        if (e.statusCode != null && e.statusCode! >= 500 && e.statusCode! < 600) {
          attempt++;
          if (attempt >= maxRetries) rethrow;
          await Future.delayed(retryDelayForTest(attempt));
        } else {
          rethrow;
        }
      }
    }
  }

  /// P5：指数退避 + jitter（base 的 50%~100%），防止多设备在瞬时故障
  /// 后同一时刻集中重试形成 thundering herd（同步重试风暴）。
  /// attempt 从 1 起：base = 2^(attempt-1) 秒，返回 [base/2, base] 区间。
  ///
  /// 注：putObject 维持不重试——非幂等 + A-1 覆盖竞态未修，重试旧快照
  /// 会覆盖新数据，故此方法只供幂等 GET/HEAD/DELETE/LIST 用。
  /// 方法名 ForTest 后缀为测试专用约定（不依赖 @visibleForTesting 注解，
  /// 避免引入 foundation/meta 包级依赖）。
  Duration retryDelayForTest(int attempt, [Random? rng]) {
    final random = rng ?? _random;
    final baseMs = (1 << (attempt - 1)) * 1000;
    return Duration(
        milliseconds: baseMs ~/ 2 + random.nextInt(baseMs ~/ 2 + 1));
  }

  /// PUT Object - 上传文件
  ///
  /// [metadata] 中的 key-value 对会作为 `x-amz-meta-{key}` 头发送，
  /// 供后续 HeadObject/GetMetadata 读取（C-01 修复）。
  ///
  /// 方案C（并发全面加固）条件写：
  /// - [ifMatch] 非空时携带 `If-Match: <etag>`，仅当远端当前对象 ETag
  ///   与之相等才写入；不匹配返回 412 → 抛 [S3PreconditionFailedException]
  /// - [ifNoneMatch] 为 true 时携带 `If-None-Match: *`（create-only），
  ///   远端已存在同 key 对象时同样 412。与 [ifMatch] 互斥。
  ///
  /// 返回服务端响应的 ETag（网关未返回时为 null），供写后校验使用。
  ///
  /// 非幂等操作（重复写入可能覆盖最新版本），不进行自动重试；
  /// 条件写失败（412）更不可重试 —— 重试必然再次失败或造成覆盖。
  Future<String?> putObject({
    required String bucket,
    required String key,
    required Uint8List data,
    String? contentType,
    Map<String, String>? metadata,
    String? ifMatch,
    bool ifNoneMatch = false,
  }) async {
    _checkDisposed();
    if (ifMatch != null && ifNoneMatch) {
      throw ArgumentError('ifMatch 与 ifNoneMatch 互斥，不能同时传入');
    }
    final uri = _buildUri(bucket, key: key);

    var headers = _signedPutHeaders(uri, data, contentType, metadata,
        ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);

    // M9：时钟偏差（RequestTimeTooSkewed）时服务器**没有处理本次请求**
    // （403 拒签），与「超时但服务端已写入」的 A-1 覆盖竞态本质不同 ——
    // _handleError 已按服务器时间写入签名偏移，立即用新偏移重发是安全的，
    // 不违反 putObject 的不重试纪律。偏差最多重试 2 次，持续偏差向上抛。
    var skewRetries = 0;
    while (true) {
      try {
        final response = await _httpClient
            .put(uri, headers: headers, body: data)
            .timeout(timeout);

        if (response.statusCode != 200 && response.statusCode != 204) {
          // 方案C：条件写失败（远端已被其他设备先行修改/创建），
          // 本次写入未落盘，翻译为专属异常供上层走冲突流程
          if (response.statusCode == 412) {
            throw S3PreconditionFailedException(key,
                message: '条件写失败（远端已被其他设备修改）: $key');
          }
          // 审计 A5：PUT 路径的桶级 404（NoSuchBucket）也要区分出来，
          // 不能落进 _handleError 的通用 404 分支丢失语义
          if (response.statusCode == 404) {
            _throwIfNoSuchBucket('PutObject', response, bucket);
          }
          _handleError('PutObject', response);
        }
        return _normalizeEtag(response.headers['etag']);
      } on S3PreconditionFailedException {
        rethrow;
      } on S3ClockSkewException {
        skewRetries++;
        if (skewRetries > 2) rethrow;
        await Future.delayed(const Duration(milliseconds: 200));
        // 用更新后的偏移重新签名再发
        headers = _signedPutHeaders(uri, data, contentType, metadata,
            ifMatch: ifMatch, ifNoneMatch: ifNoneMatch);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}',
            originalException: e);
      } on TimeoutException {
        throw S3NetworkException(
            'PutObject timed out after ${timeout.inSeconds}s');
      } catch (e) {
        if (e is S3Exception) rethrow;
        throw S3Exception('PutObject failed: $e',
            originalException: _asException(e));
      }
    }
  }

  /// 构造并签名 PUT 请求头（M9：时钟偏差重试需用新偏移重签）。
  ///
  /// C-01 修复：将自定义 metadata 转为 x-amz-meta-* 头。
  /// 非 ASCII 值（如中文账本名）直接作为 HTTP 头值会触发 RFC 7230
  /// 校验异常（FormatException: Invalid HTTP header field value），
  /// 请求根本发不出去。故统一 base64 编码并加 'b64:' 前缀标记，
  /// 读取端 [_decodeMetaValue] 自动还原，对所有 S3 兼容服务通用。
  ///
  /// metadata 键统一小写：HTTP 头名大小写不敏感，传输层（dart:io /
  /// package:http）会把响应头名转小写，读取端拿到的键恒为小写形态。
  /// 写入端显式小写使键的存储形态确定，避免依赖各网关对大小写的
  /// 保留行为。
  ///
  /// 审计 S-A 修复：Content-Length 不再参与签名。AWS 官方 SDK 不签 CL，
  /// 一旦传输层改用 chunked 编码或代理改写 CL，签了 CL 就恒定
  /// 403 SignatureDoesNotMatch。Host/Content-Type/x-amz-* 保持参与。
  Map<String, String> _signedPutHeaders(Uri uri, Uint8List data,
      String? contentType, Map<String, String>? metadata,
      {String? ifMatch, bool ifNoneMatch = false}) {
    final headers = <String, String>{
      'Host': uri.authority,
      'Content-Type': contentType ?? 'application/octet-stream',
    };
    if (ifMatch != null) {
      headers['If-Match'] = ifMatch;
    }
    if (ifNoneMatch) {
      headers['If-None-Match'] = '*';
    }
    if (metadata != null) {
      for (final entry in metadata.entries) {
        headers['x-amz-meta-${entry.key.toLowerCase()}'] =
            _encodeMetaValue(entry.value);
      }
    }
    return _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: headers,
      payloadBytes: data,
    );
  }

  /// GET Object - 下载文件（幂等，自动重试瞬时网络故障）
  Future<Uint8List> getObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试都重新签名：时钟偏差补偿（_handleError 已把服务器时间差
      // 写入 signer.clockOffset）后，重试请求必须携带新 x-amz-date 的签名。
      // 若复用外层旧签名，真实服务端会再次 403 RequestTimeTooSkewed，
      // 补偿形同虚设（与 listObjectsV2/V1 在闭包内重建 headers 同理）。
      final headers = _signedHeaders(uri, 'GET');
      try {
        final response = await _httpClient
            .get(uri, headers: headers)
            .timeout(timeout);

        if (response.statusCode == 200) {
          return response.bodyBytes;
        } else if (response.statusCode == 404) {
          // 审计 A5：404 需区分「对象不存在」与「桶不存在」——
          // 桶配错时抛 S3ObjectNotFoundException 会误导上层按
          // 「云端无备份」处理，排查方向完全错误。
          _throwIfNoSuchBucket('GetObject', response, bucket);
          throw S3ObjectNotFoundException(key);
        }
        _handleError('GetObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('GetObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('GetObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// DELETE Object - 删除文件（幂等，自动重试瞬时网络故障）
  Future<void> deleteObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    await _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'DELETE');
      try {
        final response = await _httpClient
            .delete(uri, headers: headers)
            .timeout(timeout);

        if (response.statusCode != 204 && response.statusCode != 200) {
          // 404 也算成功（对象已不存在）；但桶级 404（NoSuchBucket）是
          // 配置错误，不能静默当成功吞掉（审计 A5）
          if (response.statusCode != 404) {
            _handleError('DeleteObject', response);
          } else {
            _throwIfNoSuchBucket('DeleteObject', response, bucket);
          }
        }
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('DeleteObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('DeleteObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// HEAD Object - 检查文件是否存在（幂等，自动重试瞬时网络故障）
  ///
  /// 仅在对象存在（200）时返回 true，对象不存在（404）时返回 false。
  /// 其他状态码（403/500 等）和网络错误会抛出 [S3Exception]，避免
  /// 调用方把「权限不足」「网络中断」误判为「文件不存在」而触发
  /// 覆盖上传等危险操作。
  Future<bool> headObject({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'HEAD');
      try {
        final response = await _httpClient
            .head(uri, headers: headers)
            .timeout(timeout);
        if (response.statusCode == 200) return true;
        if (response.statusCode == 404) return false;
        // 其他状态码（403/500 等）是真实错误，不能误判为「不存在」
        _handleError('HeadObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('HeadObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// HEAD Object 并返回完整元信息（size / lastModified / contentType / metadata）
  ///
  /// 与 [headObject] 的区别：返回 [S3HeadInfo] 携带 Content-Length、
  /// Last-Modified、自定义元数据（x-amz-meta-*）等响应头，
  /// 供 [S3StorageService.getMetadata] 使用。
  ///
  /// C-01 修复：解析 x-amz-meta-* 响应头，使 CloudSyncManager 能通过
  /// metadata 中的 fingerprint 直接判断同步状态，避免全量下载。
  ///
  /// 对象不存在（404）返回 [S3HeadInfo.notFound]（exists=false）。
  /// 其他错误抛 [S3Exception]。
  Future<S3HeadInfo> headObjectWithMetadata({
    required String bucket,
    required String key,
  }) async {
    _checkDisposed();
    final uri = _buildUri(bucket, key: key);

    return _retry(() async {
      // 每次尝试重新签名（时钟偏差补偿后旧签名必然再次 403，见 getObject）
      final headers = _signedHeaders(uri, 'HEAD');
      try {
        final response = await _httpClient
            .head(uri, headers: headers)
            .timeout(timeout);
        if (response.statusCode == 200) {
          return S3HeadInfo(
            exists: true,
            size: int.tryParse(response.headers['content-length'] ?? ''),
            lastModified: _parseHttpDate(response.headers['last-modified']),
            contentType: response.headers['content-type'],
            metadata: _extractCustomMetadata(response.headers),
            eTag: _normalizeEtag(response.headers['etag']),
          );
        }
        if (response.statusCode == 404) {
          return S3HeadInfo.notFound;
        }
        _handleError('HeadObject', response);
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
      } on S3Exception {
        rethrow;
      } catch (e) {
        throw S3Exception('HeadObject failed: $e', originalException: _asException(e));
      }
    });
  }

  /// 解析 HTTP 日期头（RFC 1123 格式，如 "Wed, 21 Oct 2015 07:28:00 GMT"）
  DateTime? _parseHttpDate(String? dateStr) {
    if (dateStr == null || dateStr.isEmpty) return null;
    try {
      return HttpDate.parse(dateStr);
    } catch (_) {
      return null;
    }
  }

  /// LIST Objects - 列出对象
  ///
  /// 优先使用 ListObjectsV2（`?list-type=2`）；部分 S3 兼容网关
  /// （如阿里云 OSS S3 兼容层）不支持 V2，返回 HTTP 400/501 时
  /// 自动回退到 ListObjects V1。
  ///
  /// [maxKeys] 限制单次返回对象数量（S3 上限 1000），主要用于
  /// 连接探测等场景，避免全量列举浪费带宽。
  Future<List<String>> listObjects({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) async {
    _checkDisposed();
    final infos = await listObjectsDetailed(
      bucket: bucket,
      prefix: prefix,
      maxKeys: maxKeys,
    );
    return infos.map((e) => e.key).toList();
  }

  /// LIST Objects（含元数据）
  ///
  /// 与 [listObjects] 相同，但返回 [S3ObjectInfo] 列表，携带 size 和
  /// lastModified。供 [S3StorageService.list] 使用，避免返回硬编码的
  /// size=0 / lastModified=DateTime.now()。
  Future<List<S3ObjectInfo>> listObjectsDetailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) async {
    _checkDisposed();
    try {
      return await _listObjectsV2Detailed(
        bucket: bucket,
        prefix: prefix,
        maxKeys: maxKeys,
      );
    } on S3Exception catch (e) {
      if (e.statusCode == 400 || e.statusCode == 501) {
        return _listObjectsV1Detailed(
          bucket: bucket,
          prefix: prefix,
          maxKeys: maxKeys,
        );
      }
      rethrow;
    }
  }

  /// ListObjectsV2（`?list-type=2`），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，S3 单次最多返回 1000 个对象，
  /// 当 IsTruncated=true 时用 continuation-token 继续请求，
  /// 直到所有对象都被获取。
  ///
  /// W3 修复：[maxKeys] 是**结果总数上限**而非单页大小。之前只把它作为
  /// 每页 max-keys 参数下发，do-while 只看 continuationToken，导致
  /// `listObjects(maxKeys: 1)` 连接探测实际翻页拉取全桶对象
  /// （大桶浪费流量/费用，故障网关恒返回 IsTruncated=true 时死循环）。
  Future<List<S3ObjectInfo>> _listObjectsV2Detailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) {
    return _retry(() async {
      final allObjects = <S3ObjectInfo>[];
      String? continuationToken;

      do {
        final queryParams = <String, String>{
          'list-type': '2', // ListObjectsV2
        };
        if (prefix != null && prefix.isNotEmpty) {
          queryParams['prefix'] = prefix;
        }
        // 每页请求「还缺多少条」，由服务端钳制到其单页上限
        if (maxKeys != null) {
          queryParams['max-keys'] = '${maxKeys - allObjects.length}';
        }
        if (continuationToken != null) {
          queryParams['continuation-token'] = continuationToken;
        }

        final uri = _buildUri(bucket, queryParameters: queryParams);
        final headers = _signedHeaders(uri, 'GET');

        try {
          final response = await _httpClient
              .get(uri, headers: headers)
              .timeout(timeout);

          if (response.statusCode == 200) {
            final result = _parseListObjectsXml(response.body);
            final remaining =
                maxKeys == null ? null : maxKeys - allObjects.length;
            if (remaining != null && result.objects.length > remaining) {
              // 服务端可能无视 max-keys 下发超量，截断到上限
              allObjects.addAll(result.objects.take(remaining));
              break; // 已达上限，无需继续翻页
            }
            allObjects.addAll(result.objects);
            continuationToken = result.isTruncated ? result.nextContinuationToken : null;
          } else if (response.statusCode == 404) {
            throw S3BucketNotFoundException(bucket);
          } else {
            _handleError('ListObjects', response);
          }
        } on SocketException catch (e) {
          throw S3NetworkException('Network error: ${e.message}', originalException: e);
        } on TimeoutException {
          throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
        } catch (e) {
          if (e is S3Exception) rethrow;
          throw S3Exception('ListObjects failed: $e', originalException: _asException(e));
        }
        // 达到 maxKeys 上限即停，绝不继续翻页
      } while (continuationToken != null &&
          (maxKeys == null || allObjects.length < maxKeys));

      return allObjects;
    });
  }

  /// ListObjects V1（不带 `list-type` 参数），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，V1 用 marker 参数（上一页最后一个 key）
  /// 继续请求，直到 IsTruncated=false。
  ///
  /// W3：maxKeys 语义同 V2 路径 —— 结果总数上限，达到即停。
  Future<List<S3ObjectInfo>> _listObjectsV1Detailed({
    required String bucket,
    String? prefix,
    int? maxKeys,
  }) {
    return _retry(() async {
      final allObjects = <S3ObjectInfo>[];
      String? marker;

      do {
        final queryParams = <String, String>{};
        if (prefix != null && prefix.isNotEmpty) {
          queryParams['prefix'] = prefix;
        }
        if (maxKeys != null) {
          queryParams['max-keys'] = '${maxKeys - allObjects.length}';
        }
        if (marker != null) {
          queryParams['marker'] = marker;
        }

        final uri = _buildUri(bucket, queryParameters: queryParams);
        final headers = _signedHeaders(uri, 'GET');

        try {
          final response = await _httpClient
              .get(uri, headers: headers)
              .timeout(timeout);

          if (response.statusCode == 200) {
            final result = _parseListObjectsXml(response.body);
            final remaining =
                maxKeys == null ? null : maxKeys - allObjects.length;
            if (remaining != null && result.objects.length > remaining) {
              allObjects.addAll(result.objects.take(remaining));
              break; // 已达上限，无需继续翻页
            }
            allObjects.addAll(result.objects);
            // V1 分页：IsTruncated=true 时，用最后一条 key 作为下次请求的 marker
            marker = result.isTruncated ? result.lastKey : null;
          } else if (response.statusCode == 404) {
            throw S3BucketNotFoundException(bucket);
          } else {
            _handleError('ListObjects', response);
          }
        } on SocketException catch (e) {
          throw S3NetworkException('Network error: ${e.message}', originalException: e);
        } on TimeoutException {
          throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
        } catch (e) {
          if (e is S3Exception) rethrow;
          throw S3Exception('ListObjects failed: $e', originalException: _asException(e));
        }
        // 达到 maxKeys 上限即停，绝不继续翻页
      } while (marker != null &&
          (maxKeys == null || allObjects.length < maxKeys));

      return allObjects;
    });
  }

  /// 为请求生成带签名的 headers
  ///
  /// [method] 必须与实际发送的 HTTP method 完全一致：SigV4 规范请求首行
  /// 即 HTTP method，服务端按收到的请求行重算签名，签名 method 与实际
  /// method 不一致必然 SignatureDoesNotMatch(403)。此前 HEAD/DELETE 复用
  /// GET 签名正是该错误（审计 P0）。
  Map<String, String> _signedHeaders(Uri uri, String method) {
    return _signer.sign(
      method: method,
      uri: uri,
      headers: {'Host': uri.authority},
    );
  }

  /// 构建请求 URI
  ///
  /// - path-style:      `https://endpoint[:port]/bucket/key`
  /// - virtual-hosted:  `https://bucket.endpoint[:port]/key`
  ///
  /// 返回的 [Uri.authority] 即为应签名、应发送的 Host 值（非默认端口时携带端口）。
  Uri _buildUri(String bucket, {String? key, Map<String, String>? queryParameters}) {
    final scheme = useSSL ? 'https' : 'http';
    final portStr = port != null ? ':$port' : '';
    final encodedKey = (key == null || key.isEmpty) ? '' : '/${_encodeKey(key)}';
    final host = forcePathStyle ? endpoint : '$bucket.$endpoint';
    final path = forcePathStyle ? '/$bucket$encodedKey' : encodedKey;

    var uri = Uri.parse('$scheme://$host$portStr$path');
    if (queryParameters != null && queryParameters.isNotEmpty) {
      // 与 s3_signature._createCanonicalRequest 保持逐字节一致（审计 S3-1）：
      // 使用同一严格 RFC 3986 编码器，而不是 uri.replace(queryParameters:)
      // 的 x-www-form-urlencoded 编码（空格 -> '+'）。否则带空格/子定界符
      // 的查询值会使「落网查询串」与「签名查询串」不一致，S3 SigV4 校验
      // 返回 403；字面 '+'（如 base64 continuation-token）也会被错误解码
      // 为空格。uri.replace(query:) 接收已编码串，不会二次编码。
      final encodedQuery = queryParameters.entries
          .map((e) =>
              '${S3SignatureV4.encodePathComponentRfc3986(e.key)}='
              '${S3SignatureV4.encodePathComponentRfc3986(e.value)}')
          .join('&');
      uri = uri.replace(query: encodedQuery);
    }
    return uri;
  }

  /// 解析 ListObjects 响应（XML），返回对象列表 + 分页信息
  ///
  /// M-01 修复：增加分页支持，返回 IsTruncated、NextContinuationToken（V2）
  /// 和最后一个对象的 key（V1 的 Marker），使调用方能够迭代获取全部对象。
  /// S3 ListObjects 单次最多返回 1000 个对象，不处理分页会导致多账本用户
  /// 只能看到前 1000 个文件。
  ({List<S3ObjectInfo> objects, bool isTruncated, String? nextContinuationToken, String? lastKey})
      _parseListObjectsXml(String xmlBody) {
    try {
      final document = XmlDocument.parse(xmlBody);

      final objects = document.findAllElements('Contents').map((element) {
        final keyElement = element.findElements('Key').firstOrNull;
        final sizeElement = element.findElements('Size').firstOrNull;
        final modifiedElement = element.findElements('LastModified').firstOrNull;

        final key = keyElement?.innerText;
        if (key == null) return null;

        final sizeStr = sizeElement?.innerText;
        final size = sizeStr != null ? int.tryParse(sizeStr) : null;

        final modifiedStr = modifiedElement?.innerText;
        final lastModified = modifiedStr != null ? DateTime.tryParse(modifiedStr) : null;

        return S3ObjectInfo(key: key, size: size, lastModified: lastModified);
      }).whereType<S3ObjectInfo>().toList();

      // 分页信息
      final isTruncated = document.findAllElements('IsTruncated').firstOrNull?.innerText.toLowerCase() == 'true';
      final nextContinuationToken = document.findAllElements('NextContinuationToken').firstOrNull?.innerText;
      final lastKey = objects.isNotEmpty ? objects.last.key : null;

      return (
        objects: objects,
        isTruncated: isTruncated,
        nextContinuationToken: nextContinuationToken,
        lastKey: lastKey,
      );
    } catch (e) {
      // S-M1 修复：XML 解析失败不再静默返回空列表，
      // 而是抛出异常，避免调用方误认为桶为空导致数据丢失判断错误
      throw S3Exception(
        'ListObjects XML parse failed: $e',
        originalException: e is Exception ? e : null,
      );
    }
  }

  /// C-01 修复：从 HTTP 响应头中提取 x-amz-meta-* 自定义元数据
  ///
  /// S3 将用户上传时通过 x-amz-meta-{key} 头设置的元数据原样返回，
  /// http 包将所有头名转为小写，因此用 'x-amz-meta-' 前缀匹配。
  /// 写入端已对非 ASCII 值做 base64 编码（见 [_encodeMetaValue]），
  /// 此处自动还原；不带 'b64:' 前缀的旧值原样返回以保持向后兼容。
  Map<String, String>? _extractCustomMetadata(Map<String, String> headers) {
    const prefix = 'x-amz-meta-';
    final result = <String, String>{};
    for (final entry in headers.entries) {
      if (entry.key.startsWith(prefix)) {
        final metaKey = entry.key.substring(prefix.length);
        result[metaKey] = _decodeMetaValue(entry.value);
      }
    }
    return result.isEmpty ? null : result;
  }

  /// 将 metadata 值编码为 HTTP 头安全形式。
  ///
  /// 非 ASCII 字符（如中文账本名）直接作为头值会触发 RFC 7230 校验异常，
  /// 故统一 base64 编码并加 'b64:' 前缀标记；读取端 [_decodeMetaValue]
  /// 自动还原。编码发生在签名之前，故服务端收到的也是编码值、签名一致。
  static String _encodeMetaValue(String value) {
    return 'b64:${base64.encode(utf8.encode(value))}';
  }

  /// 还原 [_encodeMetaValue] 编码的 metadata 值。
  ///
  /// 带 'b64:' 前缀的做 base64 解码；不带前缀视为历史明文值原样返回，
  /// 避免破坏旧版写入的数据。解码异常时回退原值，保证不丢数据。
  ///
  /// M8：部分网关/代理会剥掉响应头值的尾部 `=` padding。Dart 的
  /// `base64.decode` 对缺 padding 输入直接抛 FormatException，回退分支
  /// 会把「b64:密文」整串当值返回 → 指纹恒不匹配、反复全量下载。
  /// 先经 [base64.normalize] 补齐 padding 再解码即可还原。
  static String _decodeMetaValue(String value) {
    if (value.startsWith('b64:')) {
      // 'b64:' 前缀长度为 4，payload 从下标 4 开始（此前误写 substring(5)
      // 会削掉 payload 首字符导致解码永远失败、恒回退原始包装串）。
      final payload = value.substring(4);
      try {
        return utf8.decode(base64.decode(payload));
      } on FormatException {
        // 可能只是被网关剥了 padding，补齐后重试
        try {
          return utf8.decode(base64.decode(base64.normalize(payload)));
        } on FormatException {
          return value; // 真损坏：回退原值，不丢数据
        }
      }
    }
    return value;
  }

  /// 归一化 ETag：剥掉引号包装（"abc"/W/"abc" → abc），供条件写
  /// If-Match 回传与写后校验比较。缺失/空值返回 null。
  static String? _normalizeEtag(String? raw) {
    if (raw == null) return null;
    var v = raw.trim();
    if (v.startsWith('W/')) v = v.substring(2);
    if (v.length >= 2 && v.startsWith('"') && v.endsWith('"')) {
      v = v.substring(1, v.length - 1);
    }
    return v.isEmpty ? null : v;
  }

  /// URL 编码 Key（保留 /）
  ///
  /// 审计 S3-1：委托签名端的严格 RFC 3986 编码器，保证请求路径与
  /// canonical URI 逐字节一致（Uri.encodeComponent 不转义子定界符，
  /// 与签名端口径分裂会导致 403 SignatureDoesNotMatch）。
  String _encodeKey(String key) => S3SignatureV4.encodeKeyRfc3986(key);

  /// 404 响应体中 errorCode 为 NoSuchBucket 时抛 [S3BucketNotFoundException]。
  ///
  /// 审计 A5：桶级 404 是配置错误，与「对象不存在」语义完全不同；
  /// 混同会让上层把「桶配错」当「云端无备份/文件已删」处理。
  /// 注意：HEAD 响应无 body，协议上无法区分（headObject/headObjectWithMetadata
  /// 保持「404 = 不存在」语义，桶级错误由初始化探测的 listObjects 兜底发现）。
  void _throwIfNoSuchBucket(String operation, http.Response response,
      String bucket) {
    if (response.body.isEmpty) return;
    try {
      final document = XmlDocument.parse(response.body);
      final errorCode =
          document.findAllElements('Code').firstOrNull?.innerText;
      if (errorCode == 'NoSuchBucket') {
        throw S3BucketNotFoundException(bucket);
      }
    } on S3BucketNotFoundException {
      rethrow;
    } catch (_) {
      // XML 解析失败：按对象级 404 处理（调用方决定后续语义）
    }
  }

  /// 统一错误处理
  ///
  /// 返回类型为 [Never]：此方法永远抛出异常，不会正常返回。
  /// 调用后的代码在编译器看来不可达，便于静态分析消除死代码。
  Never _handleError(String operation, http.Response response) {
    final statusCode = response.statusCode;
    final body = response.body;

    // 尝试解析 XML 错误信息
    String? errorCode;
    String? errorMessage;
    try {
      final document = XmlDocument.parse(body);
      errorCode = document.findAllElements('Code').firstOrNull?.innerText;
      errorMessage = document.findAllElements('Message').firstOrNull?.innerText;
    } catch (_) {
      // XML 解析失败，使用原始 body
    }

    final message = errorMessage ?? _sanitizeHtmlBody(body);

    // 审计 S22：时钟偏差检测。AWS 默认容忍 ±15min，超窗后所有请求
    // 403 RequestTimeTooSkewed——旧逻辑误报成「权限不足」且不重试，
    // 同步彻底瘫痪。此处解析服务器时间写入签名偏移并抛专属异常，
    // _retry 捕获后用新偏移立即重试一次。
    if (errorCode == 'RequestTimeTooSkewed') {
      DateTime? serverTime;
      try {
        final dateHeader = response.headers['date'];
        if (dateHeader != null) {
          serverTime = HttpDate.parse(dateHeader).toUtc();
        }
      } catch (_) {
        // Date 头缺失或格式异常，无法自动补偿
      }
      if (serverTime != null) {
        _signer.clockOffset = serverTime.difference(DateTime.now().toUtc());
      }
      throw S3ClockSkewException(
        '设备时钟与服务器偏差过大，已尝试校准（服务器时间: '
        '${serverTime?.toIso8601String() ?? '未知'}）。'
        '若持续失败请校准系统时间后重试',
        serverTime: serverTime,
      );
    }

    if (statusCode == 403) {
      if (errorCode == 'InvalidAccessKeyId' || errorCode == 'SignatureDoesNotMatch') {
        throw S3AuthException('Authentication failed: $message');
      } else {
        throw S3PermissionDeniedException('Permission denied: $message');
      }
    } else if (statusCode == 404) {
      // _handleError 不持有 key 信息，无法构造语义正确的
      // S3ObjectNotFoundException（需要 key），故抛通用 S3Exception。
      // 具体对象的 404 由调用方在状态码判断后自行抛出 S3ObjectNotFoundException。
      throw S3Exception('Object not found (404)', statusCode: 404);
    } else if (statusCode == 400) {
      throw S3Exception(
        '$operation failed (HTTP 400): $message. '
        'Check endpoint, useSSL, addressing style (path/virtual-hosted), '
        'or the server may not support ListObjectsV2.',
        statusCode: statusCode,
      );
    } else if (statusCode == 501) {
      throw S3Exception(
        '$operation failed (HTTP 501): $message. '
        'The server may not support this API version.',
        statusCode: statusCode,
      );
    } else {
      throw S3Exception(
        '$operation failed (HTTP $statusCode): $message',
        statusCode: statusCode,
      );
    }
  }

  /// 去除 HTML 标签并压缩空白，避免把原始 HTML 错误页直接抛给用户
  String _sanitizeHtmlBody(String body) {
    final cleaned = body
        .replaceAll(RegExp(r'<[^>]*>'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (cleaned.isEmpty) return body.trim();
    return cleaned.length > 300 ? '${cleaned.substring(0, 300)}…' : cleaned;
  }

  /// 审计修复：安全提取原始异常。通用 catch (e) 捕获的可能是 Error
  /// （如 ArgumentError/RangeError），此前 `e as Exception?` 强转在遇到
  /// Error 时自身抛 TypeError、掩盖真正的错误；非 Exception 一律置 null。
  static Exception? _asException(Object e) => e is Exception ? e : null;
}
