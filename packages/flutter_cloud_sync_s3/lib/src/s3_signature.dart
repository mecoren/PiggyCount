import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:convert/convert.dart';

/// 参与签名的 header 名称集合（**唯一口径**，小写、已排序）。
///
/// SigV4 要求两处逐字一致：canonical request 的 `CanonicalHeaders` 区块与
/// Authorization 头里的 `SignedHeaders=` 列表。历史上这两处各自内联了一份
/// 相同的 key 过滤表达式，任何一处被单独改动都会造成服务端重算签名不匹配
/// 的恒定 403 —— 收敛为单一函数后从结构上杜绝漂移。
///
/// 收录：`host`、`content-type`、`x-amz-*`
/// （含 `x-amz-date` / `x-amz-content-sha256` / `x-amz-meta-*`）。
///
/// **有意不收录**（非遗漏，勿随手加回）：
/// - `content-length`（审计 S-A）：AWS 官方 SDK 同样不签 CL。传输层一旦
///   改用 chunked 编码、或中间代理改写 CL，签了 CL 就恒定
///   403 SignatureDoesNotMatch。CL 由传输层在签名**之后**附加。
/// - `if-match` / `if-none-match`（审计 L-01）：条件头由服务端在收到请求后
///   求值，不进入 SignedHeaders 不改变其语义（条件写仍然严格生效，
///   412/404 照常返回）；传输完整性由强制 HTTPS + 禁重定向保证。把它
///   纳入签名需先实测各家兼容网关对额外 SignedHeaders 的容忍度，
///   故本轮只固化口径与注释，不改变签名集合。
List<String> resolveSignedHeaderKeys(Map<String, String> headers) {
  return headers.keys
      .where((k) =>
          k.toLowerCase().startsWith('x-amz-') ||
          k.toLowerCase() == 'host' ||
          k.toLowerCase() == 'content-type')
      .map((k) => k.toLowerCase())
      .toList()
    ..sort();
}

/// AWS Signature Version 4 签名算法实现
///
/// 用于对 S3 REST API 请求进行签名认证
/// 参考：https://docs.aws.amazon.com/general/latest/gr/signature-version-4.html
class S3SignatureV4 {
  final String accessKey;
  final String secretKey;
  final String region;
  final String service;

  /// 审计 S22：时钟偏差补偿。收到 RequestTimeTooSkewed 后由 client
  /// 按「服务器时间 − 本地时间」写入，签名取 now + offset。
  Duration clockOffset = Duration.zero;

  S3SignatureV4({
    required this.accessKey,
    required this.secretKey,
    required this.region,
    this.service = 's3',
  });

  /// 生成签名的 Authorization Header 和其他必需 headers
  ///
  /// [method] HTTP 方法（GET, PUT, DELETE等）
  /// [uri] 请求的完整 URI
  /// [headers] 原始请求 headers
  /// [payloadBytes] 请求体字节数组（可选）
  /// [at] 签名时间（仅测试注入用，省略时取当前 UTC 时间）
  /// [payloadHashOverride] M4：显式覆盖 payload hash。
  /// 流式上传无法预知完整 body 的 SHA-256，传入 `'UNSIGNED-PAYLOAD'`
  /// 时只签头部、不签 body（AWS 及 MinIO/OSS/COS/R2 等主流 S3 兼容
  /// 服务均支持）。canonical request 末行的 payload hash 同样使用该值。
  ///
  /// 返回包含签名的完整 headers
  Map<String, String> sign({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    List<int>? payloadBytes,
    DateTime? at,
    String? payloadHashOverride,
  }) {
    // 审计 S22：叠加时钟偏差补偿，设备时钟不准时仍可产出服务端
    // 容忍窗口（±15min）内的签名时间。
    final now = (at ?? DateTime.now()).toUtc().add(clockOffset);
    final dateStamp = _formatDateStamp(now);
    final amzDate = _formatAmzDate(now);

    // 1. 准备 headers
    final mutableHeaders = Map<String, String>.from(headers);
    final payloadHash =
        payloadHashOverride ?? _sha256HashBytes(payloadBytes ?? []);
    mutableHeaders['x-amz-date'] = amzDate;
    mutableHeaders['x-amz-content-sha256'] = payloadHash;

    // 2. 创建 Canonical Request
    final canonicalRequest = _createCanonicalRequest(
      method: method,
      uri: uri,
      headers: mutableHeaders,
      payloadHash: payloadHash,
    );

    // 3. 创建 String to Sign
    final credentialScope = '$dateStamp/$region/$service/aws4_request';
    final stringToSign = _createStringToSign(
      amzDate: amzDate,
      credentialScope: credentialScope,
      canonicalRequest: canonicalRequest,
    );

    // 4. 计算签名
    final signature = _calculateSignature(
      secretKey: secretKey,
      dateStamp: dateStamp,
      region: region,
      service: service,
      stringToSign: stringToSign,
    );

    // 5. 添加 Authorization Header
    final signedHeaders = resolveSignedHeaderKeys(mutableHeaders);

    mutableHeaders['Authorization'] = 'AWS4-HMAC-SHA256 '
        'Credential=$accessKey/$credentialScope, '
        'SignedHeaders=${signedHeaders.join(';')}, '
        'Signature=$signature';

    return mutableHeaders;
  }

  /// RFC 3986 严格编码单个路径段/查询分量：仅保留 unreserved 字符
  /// （A-Za-z0-9 - . _ ~），其余字节一律转义为 %XX（大写十六进制）。
  ///
  /// 审计 S3-1：此前签名端取 [Uri.path]（解码形态）、请求端用
  /// Uri.encodeComponent（不转义 ! ' ( ) * 等子定界符），两侧口径不一致
  /// —— key 含子定界符/空格/非 ASCII 时，服务端按线上原始路径复算的
  /// canonical request 与本地签名不符，恒报 403 SignatureDoesNotMatch。
  /// 统一为严格编码后「线上所发 = 签名所见」，且 unreserved 化的路径
  /// 不给服务端任何归一化空间（S3 对 SigV4 不做路径规范化）。
  static String encodePathComponentRfc3986(String component) {
    const unreserved =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~';
    final out = StringBuffer();
    for (final b in utf8.encode(component)) {
      final ch = String.fromCharCode(b);
      out.write(unreserved.contains(ch)
          ? ch
          : '%${b.toRadixString(16).toUpperCase().padLeft(2, '0')}');
    }
    return out.toString();
  }

  /// 编码整条对象键：按 / 分段各自编码，分隔符原样保留。
  ///
  /// 签名端（[_createCanonicalRequest]）与请求端（S3Client._buildUri）
  /// 必须使用同一函数，保证 canonical URI 与线上路径逐字节一致。
  static String encodeKeyRfc3986(String key) =>
      key.split('/').map(encodePathComponentRfc3986).join('/');

  /// 创建规范请求（Canonical Request）
  String _createCanonicalRequest({
    required String method,
    required Uri uri,
    required Map<String, String> headers,
    required String payloadHash,
  }) {
    // Canonical URI
    //
    // S3P-01 修复（实证）：Dart 的 [Uri.path] 返回**已编码**形态
    // （`Uri.parse('https://h/b/My%20x.json').path` 保留 `%20` 不解码），
    // 此前注释「uri.path 是已解码形态」为误判，对它再跑
    // [encodeKeyRfc3986] 会把 `%` 编成 `%25`（`%20` → `%2520`），
    // 签名所用 canonical URI 与线上实际路径逐字节不一致 →
    // 含空格/中文/子定界符的 key 恒 403 SignatureDoesNotMatch（且被
    // _handleError 误报为「凭据错误」误导排查方向）。
    // 请求 URL 由 S3Client._buildUri 用 encodeKeyRfc3986 构造（线上
    // 所发 = uri.path），签名端直接取 uri.path 即两侧逐字节一致。
    // 纯 unreserved 字符的 key（UUID/sha256 等当前业务路径）重编码为
    // 恒等变换，不触发——这也是既有测试全绿的原因。
    final canonicalUri = uri.path.isEmpty ? '/' : uri.path;

    // Canonical Query String
    // 同样用严格编码器（encodeComponent 会保留子定界符，造成口径分裂）。
    final sortedParams = uri.queryParameters.entries.toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    final canonicalQuery = sortedParams
        .map((e) => '${encodePathComponentRfc3986(e.key)}='
                    '${encodePathComponentRfc3986(e.value)}')
        .join('&');

    // Canonical Headers (只包含签名相关的 headers)
    final signedHeaderKeys = resolveSignedHeaderKeys(headers);

    final canonicalHeaders = signedHeaderKeys
        .map((key) {
          final originalKey = headers.keys.firstWhere(
            (k) => k.toLowerCase() == key,
          );
          return '$key:${headers[originalKey]!.trim()}\n';
        })
        .join();

    // Signed Headers
    final signedHeaders = signedHeaderKeys.join(';');

    return '$method\n'
        '$canonicalUri\n'
        '$canonicalQuery\n'
        '$canonicalHeaders\n'
        '$signedHeaders\n'
        '$payloadHash';
  }

  /// 创建待签名字符串（String to Sign）
  String _createStringToSign({
    required String amzDate,
    required String credentialScope,
    required String canonicalRequest,
  }) {
    final hashedRequest = _sha256Hash(canonicalRequest);
    return 'AWS4-HMAC-SHA256\n'
        '$amzDate\n'
        '$credentialScope\n'
        '$hashedRequest';
  }

  /// 计算最终签名
  String _calculateSignature({
    required String secretKey,
    required String dateStamp,
    required String region,
    required String service,
    required String stringToSign,
  }) {
    final kDate = _hmacSha256('AWS4$secretKey', dateStamp);
    final kRegion = _hmacSha256Bytes(kDate, region);
    final kService = _hmacSha256Bytes(kRegion, service);
    final kSigning = _hmacSha256Bytes(kService, 'aws4_request');
    final signature = _hmacSha256Bytes(kSigning, stringToSign);
    return hex.encode(signature);
  }

  /// SHA256 哈希（字符串输入）
  String _sha256Hash(String data) {
    return hex.encode(sha256.convert(utf8.encode(data)).bytes);
  }

  /// SHA256 哈希（字节数组输入）
  String _sha256HashBytes(List<int> data) {
    return hex.encode(sha256.convert(data).bytes);
  }

  /// HMAC-SHA256（字符串密钥）
  List<int> _hmacSha256(String key, String data) {
    final hmac = Hmac(sha256, utf8.encode(key));
    return hmac.convert(utf8.encode(data)).bytes;
  }

  /// HMAC-SHA256（字节数组密钥）
  List<int> _hmacSha256Bytes(List<int> key, String data) {
    final hmac = Hmac(sha256, key);
    return hmac.convert(utf8.encode(data)).bytes;
  }

  /// 格式化为 AMZ 日期时间格式（20230101T120000Z）
  String _formatAmzDate(DateTime dt) {
    final iso = dt.toIso8601String();
    return '${iso.replaceAll(RegExp(r'[-:]'), '').split('.')[0]}Z';
  }

  /// 格式化为日期戳格式（20230101）
  String _formatDateStamp(DateTime dt) {
    return dt.toIso8601String().split('T')[0].replaceAll('-', '');
  }
}
