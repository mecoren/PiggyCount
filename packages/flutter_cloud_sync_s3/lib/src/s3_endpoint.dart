/// S3 端点解析与判定工具
///
/// 纯函数实现，便于单元测试。
library;

/// 顶层预编译正则，避免每次调用 [parseS3Endpoint] 时重复编译
final RegExp _schemePattern = RegExp(r'^(https?)://', caseSensitive: false);
final RegExp _trailingSlashOrDotPattern = RegExp(r'[/.]+$');

/// 解析后的 S3 端点信息
class S3EndpointInfo {
  /// 主机名（不含协议与路径）
  final String host;

  /// 端口（null 表示使用协议默认端口）
  final int? port;

  /// 是否使用 HTTPS
  final bool useSSL;

  const S3EndpointInfo({
    required this.host,
    this.port,
    required this.useSSL,
  });
}

/// 解析 S3 endpoint 配置。
///
/// 规则：
/// - 自动剥离 `http://` / `https://` 协议前缀，并按协议覆盖 [useSSL] 默认值
/// - 自动剥离路径部分（endpoint 只保留 host[:port]）
/// - 若未单独指定 [port] 且 host 中带 `:port`，则从 host 中解析端口
///
/// [useSSL]：调用方配置（可空）。仅当 endpoint 未显式携带协议时作为默认值。
S3EndpointInfo parseS3Endpoint(String endpoint, {bool? useSSL, int? port}) {
  var value = endpoint.trim();
  var ssl = useSSL ?? true;

  // 1. 协议前缀 → 覆盖 useSSL（显式协议优先于配置；大小写不敏感以兼容 HTTPS:// 等写法）
  final schemeMatch = _schemePattern.firstMatch(value);
  if (schemeMatch != null) {
    ssl = schemeMatch.group(1)!.toLowerCase() == 'https';
    value = value.substring(schemeMatch.end);
  }

  // 2. 去掉路径部分（endpoint 只保留 host[:port]）
  final slashIndex = value.indexOf('/');
  if (slashIndex != -1) {
    value = value.substring(0, slashIndex);
  }

  // 3. 去掉尾部斜杠/点
  value = value.replaceFirst(_trailingSlashOrDotPattern, '');

  // 4. 解析 host 与端口（若 host 自带端口且调用方未单独指定）
  var host = value;
  var finalPort = port;
  if (value.contains(':') && port == null) {
    final lastColon = value.lastIndexOf(':');
    final candidatePort = int.tryParse(value.substring(lastColon + 1));
    if (candidatePort != null) {
      host = value.substring(0, lastColon);
      finalPort = candidatePort;
    }
  }

  return S3EndpointInfo(host: host, port: finalPort, useSSL: ssl);
}

/// 判断是否为托管云服务端点（通常要求 virtual-hosted-style 寻址）。
///
/// 自托管存储（MinIO、Ceph 等）默认使用 path-style 寻址。
bool isManagedCloudEndpoint(String host) {
  final h = host.toLowerCase();
  return h == 's3.amazonaws.com' ||
      h.endsWith('.amazonaws.com') || // AWS S3
      h.endsWith('.aliyuncs.com') || // 阿里云 OSS
      h.endsWith('.myqcloud.com') || // 腾讯云 COS
      h.endsWith('.cloudflarestorage.com') || // Cloudflare R2
      h.endsWith('.backblazeb2.com') || // Backblaze B2
      h.endsWith('.wasabisys.com') || // Wasabi
      h.endsWith('.digitaloceanspaces.com') || // DigitalOcean Spaces
      h.endsWith('.qiniucs.com'); // 七牛云 Kodo
}
