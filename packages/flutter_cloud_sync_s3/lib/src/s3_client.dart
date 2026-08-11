import 'dart:async';
import 'dart:io';
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

  /// HTTP 请求超时时间（M-02 修复）
  ///
  /// 所有 S3 API 请求（put/get/delete/head/list）均受此限制，
  /// 防止服务器无响应时同步 UI 无限挂起。超时后抛 [S3NetworkException]。
  final Duration timeout;

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
    _httpClient.close();
  }

  /// PUT Object - 上传文件
  ///
  /// [metadata] 中的 key-value 对会作为 `x-amz-meta-{key}` 头发送，
  /// 供后续 HeadObject/GetMetadata 读取（C-01 修复）。
  Future<void> putObject({
    required String bucket,
    required String key,
    required Uint8List data,
    String? contentType,
    Map<String, String>? metadata,
  }) async {
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
      'Content-Type': contentType ?? 'application/octet-stream',
      'Content-Length': '${data.length}',
    };

    // C-01 修复：将自定义 metadata 转为 x-amz-meta-* 头
    if (metadata != null) {
      for (final entry in metadata.entries) {
        headers['x-amz-meta-${entry.key}'] = entry.value;
      }
    }

    // 签名请求（传递字节数组以正确计算 SHA256）
    headers = _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: headers,
      payloadBytes: data,
    );

    try {
      final response = await _httpClient
          .put(uri, headers: headers, body: data)
          .timeout(timeout);

      if (response.statusCode != 200 && response.statusCode != 204) {
        _handleError('PutObject', response);
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } on TimeoutException {
      throw S3NetworkException('PutObject timed out after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('PutObject failed: $e', originalException: e as Exception?);
    }
  }

  /// GET Object - 下载文件
  Future<Uint8List> getObject({
    required String bucket,
    required String key,
  }) async {
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
    };

    headers = _signer.sign(
      method: 'GET',
      uri: uri,
      headers: headers,
    );

    try {
      final response = await _httpClient
          .get(uri, headers: headers)
          .timeout(timeout);

      if (response.statusCode == 200) {
        return response.bodyBytes;
      } else if (response.statusCode == 404) {
        throw S3ObjectNotFoundException(key);
      } else {
        _handleError('GetObject', response);
        throw S3Exception('GetObject failed');
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } on TimeoutException {
      throw S3NetworkException('GetObject timed out after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('GetObject failed: $e', originalException: e as Exception?);
    }
  }

  /// DELETE Object - 删除文件
  Future<void> deleteObject({
    required String bucket,
    required String key,
  }) async {
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
    };

    headers = _signer.sign(
      method: 'DELETE',
      uri: uri,
      headers: headers,
    );

    try {
      final response = await _httpClient
          .delete(uri, headers: headers)
          .timeout(timeout);

      if (response.statusCode != 204 && response.statusCode != 200) {
        // 404 也算成功（对象已不存在）
        if (response.statusCode != 404) {
          _handleError('DeleteObject', response);
        }
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } on TimeoutException {
      throw S3NetworkException('DeleteObject timed out after ${timeout.inSeconds}s');
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('DeleteObject failed: $e', originalException: e as Exception?);
    }
  }

  /// HEAD Object - 检查文件是否存在
  ///
  /// 仅在对象存在（200）时返回 true，对象不存在（404）时返回 false。
  /// 其他状态码（403/500 等）和网络错误会抛出 [S3Exception]，避免
  /// 调用方把「权限不足」「网络中断」误判为「文件不存在」而触发
  /// 覆盖上传等危险操作。
  Future<bool> headObject({
    required String bucket,
    required String key,
  }) async {
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
    };

    headers = _signer.sign(
      method: 'HEAD',
      uri: uri,
      headers: headers,
    );

    try {
      final response = await _httpClient
          .head(uri, headers: headers)
          .timeout(timeout);
      if (response.statusCode == 200) return true;
      if (response.statusCode == 404) return false;
      // 其他状态码（403/500 等）是真实错误，不能误判为「不存在」
      _handleError('HeadObject', response);
      return false; // _handleError 一定会抛，此处仅为静态分析兜底
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } on TimeoutException {
      throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
    } on S3Exception {
      rethrow;
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('HeadObject failed: $e', originalException: e as Exception?);
    }
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
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
    };

    headers = _signer.sign(
      method: 'HEAD',
      uri: uri,
      headers: headers,
    );

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
        );
      }
      if (response.statusCode == 404) {
        return S3HeadInfo.notFound;
      }
      _handleError('HeadObject', response);
      return S3HeadInfo.notFound; // 不可达
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } on TimeoutException {
      throw S3NetworkException('HeadObject timed out after ${timeout.inSeconds}s');
    } on S3Exception {
      rethrow;
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('HeadObject failed: $e', originalException: e as Exception?);
    }
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
  Future<List<String>> listObjects({
    required String bucket,
    String? prefix,
  }) async {
    final infos = await listObjectsDetailed(bucket: bucket, prefix: prefix);
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
  }) async {
    try {
      return await _listObjectsV2Detailed(bucket: bucket, prefix: prefix);
    } on S3Exception catch (e) {
      if (e.statusCode == 400 || e.statusCode == 501) {
        return _listObjectsV1Detailed(bucket: bucket, prefix: prefix);
      }
      rethrow;
    }
  }

  /// ListObjectsV2（`?list-type=2`），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，S3 单次最多返回 1000 个对象，
  /// 当 IsTruncated=true 时用 continuation-token 继续请求，
  /// 直到所有对象都被获取。
  Future<List<S3ObjectInfo>> _listObjectsV2Detailed({
    required String bucket,
    String? prefix,
  }) async {
    final allObjects = <S3ObjectInfo>[];
    String? continuationToken;

    do {
      final queryParams = <String, String>{
        'list-type': '2', // ListObjectsV2
      };
      if (prefix != null && prefix.isNotEmpty) {
        queryParams['prefix'] = prefix;
      }
      if (continuationToken != null) {
        queryParams['continuation-token'] = continuationToken;
      }

      final uri = _buildUri(bucket, queryParameters: queryParams);
      final headers = _signedGetHeaders(uri);

      try {
        final response = await _httpClient
            .get(uri, headers: headers)
            .timeout(timeout);

        if (response.statusCode == 200) {
          final result = _parseListObjectsXml(response.body);
          allObjects.addAll(result.objects);
          continuationToken = result.isTruncated ? result.nextContinuationToken : null;
        } else if (response.statusCode == 404) {
          throw S3BucketNotFoundException(bucket);
        } else {
          _handleError('ListObjects', response);
          return allObjects;
        }
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
      } catch (e) {
        if (e is S3Exception) rethrow;
        throw S3Exception('ListObjects failed: $e', originalException: e as Exception?);
      }
    } while (continuationToken != null);

    return allObjects;
  }

  /// ListObjects V1（不带 `list-type` 参数），返回含元数据的对象列表
  ///
  /// M-01 修复：支持分页迭代，V1 用 marker 参数（上一页最后一个 key）
  /// 继续请求，直到 IsTruncated=false。
  Future<List<S3ObjectInfo>> _listObjectsV1Detailed({
    required String bucket,
    String? prefix,
  }) async {
    final allObjects = <S3ObjectInfo>[];
    String? marker;

    do {
      final queryParams = <String, String>{};
      if (prefix != null && prefix.isNotEmpty) {
        queryParams['prefix'] = prefix;
      }
      if (marker != null) {
        queryParams['marker'] = marker;
      }

      final uri = _buildUri(bucket, queryParameters: queryParams);
      final headers = _signedGetHeaders(uri);

      try {
        final response = await _httpClient
            .get(uri, headers: headers)
            .timeout(timeout);

        if (response.statusCode == 200) {
          final result = _parseListObjectsXml(response.body);
          allObjects.addAll(result.objects);
          // V1 分页：IsTruncated=true 时，用最后一条 key 作为下次请求的 marker
          marker = result.isTruncated ? result.lastKey : null;
        } else if (response.statusCode == 404) {
          throw S3BucketNotFoundException(bucket);
        } else {
          _handleError('ListObjects', response);
          return allObjects;
        }
      } on SocketException catch (e) {
        throw S3NetworkException('Network error: ${e.message}', originalException: e);
      } on TimeoutException {
        throw S3NetworkException('ListObjects timed out after ${timeout.inSeconds}s');
      } catch (e) {
        if (e is S3Exception) rethrow;
        throw S3Exception('ListObjects failed: $e', originalException: e as Exception?);
      }
    } while (marker != null);

    return allObjects;
  }

  /// 为 GET/HEAD 请求生成带签名的 headers
  Map<String, String> _signedGetHeaders(Uri uri) {
    return _signer.sign(
      method: 'GET',
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
      uri = uri.replace(queryParameters: queryParameters);
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
      // M-03 修复：XML 解析失败不再静默返回空列表，
      // 通过 stderr 输出警告便于排查，避免调用方误认为桶为空
      stderr.writeln('[S3] Warning: ListObjects XML parse failed: $e');
      return (objects: <S3ObjectInfo>[], isTruncated: false, nextContinuationToken: null, lastKey: null);
    }
  }

  /// C-01 修复：从 HTTP 响应头中提取 x-amz-meta-* 自定义元数据
  ///
  /// S3 将用户上传时通过 x-amz-meta-{key} 头设置的元数据原样返回，
  /// http 包将所有头名转为小写，因此用 'x-amz-meta-' 前缀匹配。
  Map<String, String>? _extractCustomMetadata(Map<String, String> headers) {
    const prefix = 'x-amz-meta-';
    final result = <String, String>{};
    for (final entry in headers.entries) {
      if (entry.key.startsWith(prefix)) {
        final metaKey = entry.key.substring(prefix.length);
        result[metaKey] = entry.value;
      }
    }
    return result.isEmpty ? null : result;
  }

  /// URL 编码 Key（保留 /）
  String _encodeKey(String key) {
    return key.split('/').map(Uri.encodeComponent).join('/');
  }

  /// 统一错误处理
  void _handleError(String operation, http.Response response) {
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

    if (statusCode == 403) {
      if (errorCode == 'InvalidAccessKeyId' || errorCode == 'SignatureDoesNotMatch') {
        throw S3AuthException('Authentication failed: $message');
      } else {
        throw S3PermissionDeniedException('Permission denied: $message');
      }
    } else if (statusCode == 404) {
      throw S3ObjectNotFoundException('Object not found');
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
}
