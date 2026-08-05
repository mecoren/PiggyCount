import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:xml/xml.dart';

import 's3_signature.dart';
import 's3_exceptions.dart';

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

  S3Client({
    required this.endpoint,
    required this.region,
    required this.accessKey,
    required this.secretKey,
    this.useSSL = true,
    this.port,
    this.forcePathStyle = true,
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
  Future<void> putObject({
    required String bucket,
    required String key,
    required Uint8List data,
    String? contentType,
  }) async {
    final uri = _buildUri(bucket, key: key);

    var headers = <String, String>{
      'Host': uri.authority,
      'Content-Type': contentType ?? 'application/octet-stream',
      'Content-Length': '${data.length}',
    };

    // 签名请求（传递字节数组以正确计算 SHA256）
    headers = _signer.sign(
      method: 'PUT',
      uri: uri,
      headers: headers,
      payloadBytes: data,
    );

    try {
      final response = await _httpClient.put(uri, headers: headers, body: data);

      if (response.statusCode != 200 && response.statusCode != 204) {
        _handleError('PutObject', response);
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
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
      final response = await _httpClient.get(uri, headers: headers);

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
      final response = await _httpClient.delete(uri, headers: headers);

      if (response.statusCode != 204 && response.statusCode != 200) {
        // 404 也算成功（对象已不存在）
        if (response.statusCode != 404) {
          _handleError('DeleteObject', response);
        }
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('DeleteObject failed: $e', originalException: e as Exception?);
    }
  }

  /// HEAD Object - 检查文件是否存在
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
      final response = await _httpClient.head(uri, headers: headers);
      return response.statusCode == 200;
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } catch (e) {
      // HEAD 请求失败返回 false 而不抛出异常
      return false;
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
    try {
      return await _listObjectsV2(bucket: bucket, prefix: prefix);
    } on S3Exception catch (e) {
      if (e.statusCode == 400 || e.statusCode == 501) {
        return _listObjectsV1(bucket: bucket, prefix: prefix);
      }
      rethrow;
    }
  }

  /// ListObjectsV2（`?list-type=2`）
  Future<List<String>> _listObjectsV2({
    required String bucket,
    String? prefix,
  }) async {
    final queryParams = <String, String>{
      'list-type': '2', // ListObjectsV2
    };
    if (prefix != null && prefix.isNotEmpty) {
      queryParams['prefix'] = prefix;
    }

    final uri = _buildUri(bucket, queryParameters: queryParams);
    final headers = _signedGetHeaders(uri);

    try {
      final response = await _httpClient.get(uri, headers: headers);

      if (response.statusCode == 200) {
        return _parseListObjectsResponse(response.body);
      } else if (response.statusCode == 404) {
        throw S3BucketNotFoundException(bucket);
      } else {
        _handleError('ListObjects', response);
        return [];
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('ListObjects failed: $e', originalException: e as Exception?);
    }
  }

  /// ListObjects V1（不带 `list-type` 参数）
  Future<List<String>> _listObjectsV1({
    required String bucket,
    String? prefix,
  }) async {
    final queryParams = <String, String>{};
    if (prefix != null && prefix.isNotEmpty) {
      queryParams['prefix'] = prefix;
    }

    final uri = _buildUri(bucket, queryParameters: queryParams);
    final headers = _signedGetHeaders(uri);

    try {
      final response = await _httpClient.get(uri, headers: headers);

      if (response.statusCode == 200) {
        return _parseListObjectsResponse(response.body);
      } else if (response.statusCode == 404) {
        throw S3BucketNotFoundException(bucket);
      } else {
        _handleError('ListObjects', response);
        return [];
      }
    } on SocketException catch (e) {
      throw S3NetworkException('Network error: ${e.message}', originalException: e);
    } catch (e) {
      if (e is S3Exception) rethrow;
      throw S3Exception('ListObjects failed: $e', originalException: e as Exception?);
    }
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

  /// 解析 ListObjects 响应（XML）
  List<String> _parseListObjectsResponse(String xmlBody) {
    try {
      final document = XmlDocument.parse(xmlBody);
      final contents = document.findAllElements('Contents');

      return contents
          .map((element) {
            final keyElement = element.findElements('Key').firstOrNull;
            return keyElement?.innerText;
          })
          .whereType<String>()
          .toList();
    } catch (e) {
      // XML 解析失败，返回空列表
      return [];
    }
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
