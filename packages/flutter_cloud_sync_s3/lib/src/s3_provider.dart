import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 's3_client.dart';
import 's3_auth_service.dart';
import 's3_storage_service.dart';
import 's3_exceptions.dart';
import 's3_endpoint.dart';

/// S3 Provider 实现
///
/// 支持所有 S3 兼容存储服务：
/// - AWS S3
/// - Cloudflare R2
/// - Backblaze B2
/// - MinIO (自托管)
/// - 阿里云 OSS
/// - 腾讯云 COS
/// - 七牛云 Kodo
class S3Provider implements CloudProvider {
  S3Client? _client;
  String? _bucket;
  S3AuthService? _authService;
  S3StorageService? _storageService;

  /// S3-W2：条件写降级日志注入口（静态，宿主 app 装配时设置）。
  ///
  /// [CloudProvider] 接口的 initialize 只收 config map，无法优雅传
  /// logger；S3Client 的 400+NotImplemented 降级需要 warning 线索
  /// （双后端实测暴露的静默降级问题），宿主在创建 provider 前设置
  /// 此静态字段即可。不设置时降级静默，但能力记忆（本会话后续直接
  /// 盲写）仍生效。
  static CloudSyncLogger? downgradeLogger;

  @override
  String get providerId => 's3';

  @override
  String get providerName => 'S3 Compatible Storage';

  @override
  CloudAuthService get auth {
    if (_authService == null) {
      // 与 WebDAVProvider 对齐：未初始化抛配置异常而非 StateError，
      // 上层可按统一类型捕获并提示「先完成云服务配置」
      throw CloudConfigurationException(
          'S3Provider not initialized. Call initialize() first.');
    }
    return _authService!;
  }

  @override
  CloudStorageService get storage {
    if (_storageService == null) {
      throw CloudConfigurationException(
          'S3Provider not initialized. Call initialize() first.');
    }
    return _storageService!;
  }

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    // 审计 S3-24：initialize 前置校验。此前空 bucket/AK/SK 一路走到连接
    // 探测，报出晦涩的服务端错误而非「配置缺失」。
    if (!validateConfig(config)) {
      throw CloudConfigurationException(
          'Invalid configuration. Required non-empty keys: '
          'endpoint, accessKey, secretKey, bucket');
    }

    // 解析配置
    final rawEndpoint = config['endpoint'] as String? ?? '';
    final region = config['region'] as String? ?? 'us-east-1';
    final accessKey = config['accessKey'] as String? ?? '';
    final secretKey = config['secretKey'] as String? ?? '';
    final bucket = config['bucket'] as String? ?? '';
    final useSSL = _optionalBool(config, 'useSSL');
    final port = _optionalInt(config, 'port');
    // key 前缀：用于在共享 bucket 中隔离应用数据，默认为空（不前缀）
    final keyPrefix = config['keyPrefix'] as String? ?? '';

    // SEC-04：bucket 名字符集校验。keyPrefix 有 _validatePrefix（S3-22）、
    // path 有 _assertNoTraversal（S3-21），bucket 此前只查非空 —— 含 `/`、
    // `..`、`@` 的值会直接拼进 URI（path-style 的 /bucket/key 路径或
    // virtual-hosted 的 bucket.endpoint authority），可构造畸形目标
    // （如 `user@evil.com` 形态的 userinfo 注入把请求与签名凭据定向到
    // 攻击者主机）。配置导入通道（config_export_service 重建配置）使
    // 非手动输入成为真实入口，构造期即按 S3 命名规范白名单拒绝。
    if (!RegExp(r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
        bucket.contains('..')) {
      throw CloudConfigurationException(
        'Invalid bucket name "$bucket": S3 bucket 命名规范为 3-63 个小写字母/'
        '数字/点/连字符，不能以点/连字符开头结尾，也不能包含连续点或 '
        '`..` 路径段',
      );
    }

    // 归一化 endpoint：
    // - 剥离 http(s):// 前缀并按协议自动推导 useSSL
    // - 剥离路径部分（endpoint 只保留 host[:port]）
    // - 解析 host 中自带的端口
    final info = parseS3Endpoint(rawEndpoint, useSSL: useSSL, port: port);

    // SYNC-04：默认拒绝明文 HTTP。http:// 显式协议会覆盖 useSSL 配置；
    // 明文链路上账本数据与 SigV4 凭据均可被窃听/中间人篡改。与 WebDAV
    // 后端强制 HTTPS 的安全策略对齐（webdav_provider P2-7）。
    if (!info.useSSL) {
      throw CloudConfigurationException(
        'S3 地址必须使用 HTTPS（检测到 http:// 前缀或 useSSL=false，'
        '账本数据与访问密钥将在链路上明文传输）',
      );
    }

    // 寻址方式：托管云（AWS/OSS/COS/R2 等）默认 virtual-hosted-style；
    // 自托管（MinIO 等）默认 path-style。可通过 forcePathStyle 显式覆盖。
    final forcePathStyle =
        _optionalBool(config, 'forcePathStyle') ?? !isManagedCloudEndpoint(info.host);

    // S-M2 修复：创建新 client 前先释放旧实例，
    // 避免 initialize 重复调用时旧 httpClient 泄漏连接资源
    _client?.dispose();
    _client = S3Client(
      endpoint: info.host,
      region: region,
      accessKey: accessKey,
      secretKey: secretKey,
      useSSL: info.useSSL,
      port: info.port,
      forcePathStyle: forcePathStyle,
    );

    _bucket = bucket;

    // 测试连接：仅请求 1 个 key 即可验证连接/认证/桶可访问性，
    // 避免大 bucket 全量列举浪费带宽和时间。
    //
    // 审计 S-E：探测必须带上 keyPrefix。此前列举的是**桶根** —— 使用
    // 前缀级最小权限凭据（仅授权 `prefix/piggycount/*` 的 List）时，
    // 桶根列举被拒 → 误判为「权限不足/配置错误」，无法完成接入；
    // 带上前缀后探测范围与实际使用范围一致。
    try {
      await _client!.listObjects(
        bucket: bucket,
        prefix: keyPrefix.isEmpty ? null : keyPrefix,
        maxKeys: 1,
      );
    } catch (e) {
      // 审计 S3-11：探测失败 = 半初始化状态，必须释放已创建的 client，
      // 否则调用方丢弃 provider 后 httpClient 连接池泄漏（重复 initialize
      // 的场景已由上方 S-M2 dispose 兜底，这里是首初始化失败路径）。
      _teardown();
      throw _classifyProbeFailure(e);
    }

    // 初始化服务
    _authService = S3AuthService(_client!, _bucket!);
    // S3-W2：降级 warning 注入（CloudSyncLogger 由宿主 app 装配时传入；
    // S3Provider 接口无 logger 参数，这里用 provider 级静态注入口，
    // 宿主 initialize 前设置即可，未设置时降级静默但能力记忆仍生效）
    _storageService = S3StorageService(_client!, _bucket!,
        keyPrefix: keyPrefix, logger: S3Provider.downgradeLogger);
  }

  /// 释放半初始化状态的资源（探测失败路径）
  void _teardown() {
    _client?.dispose();
    _client = null;
    _bucket = null;
    _authService = null;
    _storageService = null;
  }

  /// 把连接探测异常分类为面向用户的 [CloudConfigurationException]。
  ///
  /// 审计 S3-11：此前 ClockSkew（设备时钟偏差超 ±15min）落入通用分支被
  /// 报成「配置错误」，用户排查方向完全被误导 —— 时钟问题改配置无用，
  /// 必须提示校时。
  static CloudConfigurationException _classifyProbeFailure(Object e) {
    if (e is S3BucketNotFoundException) {
      return CloudConfigurationException(
        'Bucket not found: ${e.bucket}. Please create the bucket first.',
      );
    }
    if (e is S3AuthException) {
      return CloudConfigurationException(
        'Authentication failed: ${e.message}. Please check your Access Key and Secret Key.',
      );
    }
    if (e is S3ClockSkewException) {
      return CloudConfigurationException(
        'Device clock skew detected: ${e.message}. '
        '请校准设备系统时间后重试（S3 要求客户端与服务端时钟偏差在 ±15 分钟内）。',
      );
    }
    if (e is S3NetworkException) {
      return CloudConfigurationException(
        'Network error: ${e.message}. Please check your endpoint and network connection.',
      );
    }
    if (e is S3PermissionDeniedException) {
      return CloudConfigurationException(
        'Permission denied: ${e.message}. '
        '请确认 Access Key 对该 bucket 有读写权限（ListObjects 被拒）。',
      );
    }
    return CloudConfigurationException('Failed to initialize S3: $e');
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    // 必需字段验证
    if (!config.containsKey('endpoint') ||
        !config.containsKey('accessKey') ||
        !config.containsKey('secretKey') ||
        !config.containsKey('bucket')) {
      return false;
    }

    // 非空验证
    final endpoint = config['endpoint'] as String?;
    final accessKey = config['accessKey'] as String?;
    final secretKey = config['secretKey'] as String?;
    final bucket = config['bucket'] as String?;

    return endpoint != null && endpoint.trim().isNotEmpty &&
           accessKey != null && accessKey.isNotEmpty &&
           secretKey != null && secretKey.isNotEmpty &&
           bucket != null && bucket.isNotEmpty;
  }

  /// 可选 bool 配置的安全解析（审计 S-F）：此前 `as bool?` 强转在传入
  /// 字符串（'true'/'false'）时抛裸 TypeError 而非配置异常，报错面目全非。
  /// 现兼容 bool 与常见字符串形态；类型非法抛 [CloudConfigurationException]。
  static bool? _optionalBool(Map<String, dynamic> config, String key) {
    final v = config[key];
    if (v == null) return null;
    if (v is bool) return v;
    if (v is String) {
      final s = v.toLowerCase();
      if (s == 'true') return true;
      if (s == 'false') return false;
    }
    throw CloudConfigurationException(
        "Invalid '$key' config value: expected bool, got ${v.runtimeType}");
  }

  /// 可选 int 配置的安全解析（审计 S-F 同款）
  static int? _optionalInt(Map<String, dynamic> config, String key) {
    final v = config[key];
    if (v == null) return null;
    if (v is int) return v;
    if (v is String) {
      final parsed = int.tryParse(v);
      if (parsed != null) return parsed;
    }
    throw CloudConfigurationException(
        "Invalid '$key' config value: expected int, got ${v.runtimeType}");
  }

  @override
  Future<void> dispose() async {
    _client?.dispose();
    _client = null;
    _bucket = null;
    _authService = null;
    _storageService = null;
  }
}
