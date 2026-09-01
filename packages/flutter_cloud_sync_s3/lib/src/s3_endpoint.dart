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
/// - host 中带 `:port` 时解析该内嵌端口
///
/// 审计 S3-M1（双端口校验）：
/// - [port] 与 endpoint 内嵌端口同时存在且**相等** → 视为冗余但一致，放行
/// - 同时存在且**不等** → 配置期即抛 [ArgumentError]。旧行为是显式 [port]
///   直接生效、内嵌端口滞留 host，构造出 `host:9000:9001` 这类非法
///   authority，SigV4 的 Host 头随之错乱，首个请求才以晦涩错误爆发
/// - [port] 自身越界（不在 1-65535）→ 同样配置期即抛
///
/// [useSSL]：调用方配置（可空）。仅当 endpoint 未显式携带协议时作为默认值。
S3EndpointInfo parseS3Endpoint(String endpoint, {bool? useSSL, int? port}) {
  var value = endpoint.trim();
  var ssl = useSSL ?? true;

  // S3-M1：显式 port 参数自身先做范围校验。此前仅校验 endpoint 内嵌端口
  // （S3-5），显式 port=0/70000 会直接流入 URI 构造出非法目标。
  if (port != null && !_isValidPort(port)) {
    throw ArgumentError.value(
      endpoint,
      'port',
      'invalid port $port (expected an integer in 1-65535)',
    );
  }

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

  // 4. 解析 host 与端口（内嵌端口始终解析，与显式 [port] 做冲突判定）
  //
  // 审计 S3-M1：旧逻辑在「显式 port 已指定」时跳过内嵌端口解析，导致
  // `minio.local:9000` + port=9001 静默产出 host='minio.local:9000'、
  // port=9001 的组合 —— 下游 URI 变成 `https://minio.local:9000:9001/...`
  // （S3Client._buildUri 直接字符串拼接 authority），SigV4 Host 头错乱，
  // 全部请求失败且报错误导排查方向。现在双端口同时出现时配置期即裁决。
  var host = value;
  var finalPort = port;
  if (value.startsWith('[')) {
    // F8：IPv6 字面量（RFC 3986：IP-literal 需方括号）。`]` 前整体视作
    // host（保留方括号 —— Uri 拼接 `scheme://[::1]:9000/...` 必须带括号
    // 才合法，SigV4 的 Host 头取 uri.authority 也天然一致）；端口取
    // `]` 后的 :n。多个冒号不得再触发 host:port 切分。
    final close = value.indexOf(']');
    if (close != -1) {
      host = value.substring(0, close + 1);
      final rest = value.substring(close + 1);
      if (rest.startsWith(':')) {
        final embedded = int.tryParse(rest.substring(1));
        if (embedded == null || !_isValidPort(embedded)) {
          throw ArgumentError.value(
            endpoint,
            'endpoint',
            'invalid embedded port "${rest.substring(1)}" '
                '(expected an integer in 1-65535)',
          );
        }
        if (port != null && port != embedded) {
          throw ArgumentError.value(
            endpoint,
            'endpoint',
            'dual port specified: endpoint URL carries :$embedded '
                'while port parameter is $port; keep only one',
          );
        }
        finalPort = embedded;
      }
    }
    // 无 `]`：畸形输入，host 原样保留，交由上层 URI 构造暴露问题
  } else if (value.contains(':')) {
    final lastColon = value.lastIndexOf(':');
    // 校验端口范围（1-65535）：0 不是合法的连接目标端口，拒绝越界值
    // 避免构造非法 URI（F8）。
    // 审计 S3-5：非法端口此前被静默忽略（滞留 host），延迟到首个请求才以
    // 裸 FormatException 爆发。配置期即给出明确错误。
    // 审计 S3-M1：内嵌端口现在无条件解析并与显式 port 比对，不再因
    // 显式 port 存在而跳过（跳过即双端口静默并存）。
    final embedded = int.tryParse(value.substring(lastColon + 1));
    if (embedded == null || !_isValidPort(embedded)) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'invalid port "${value.substring(lastColon + 1)}" '
            '(expected an integer in 1-65535)',
      );
    }
    if (port != null && port != embedded) {
      throw ArgumentError.value(
        endpoint,
        'endpoint',
        'dual port specified: endpoint URL carries :$embedded '
            'while port parameter is $port; keep only one',
      );
    }
    host = value.substring(0, lastColon);
    finalPort = embedded;
  }

  return S3EndpointInfo(host: host, port: finalPort, useSSL: ssl);
}

/// 合法连接端口范围：0 是 OS 的通配保留值，不能作为请求目标。
bool _isValidPort(int p) => p >= 1 && p <= 65535;

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
