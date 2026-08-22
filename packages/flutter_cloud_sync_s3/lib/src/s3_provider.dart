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

  @override
  String get providerId => 's3';

  @override
  String get providerName => 'S3 Compatible Storage';

  @override
  CloudAuthService get auth {
    if (_authService == null) {
      throw StateError('S3Provider not initialized. Call initialize() first.');
    }
    return _authService!;
  }

  @override
  CloudStorageService get storage {
    if (_storageService == null) {
      throw StateError('S3Provider not initialized. Call initialize() first.');
    }
    return _storageService!;
  }

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    // 解析配置
    final rawEndpoint = config['endpoint'] as String? ?? '';
    final region = config['region'] as String? ?? 'us-east-1';
    final accessKey = config['accessKey'] as String? ?? '';
    final secretKey = config['secretKey'] as String? ?? '';
    final bucket = config['bucket'] as String? ?? '';
    final useSSL = config['useSSL'] as bool?;
    final port = config['port'] as int?;
    // key 前缀：用于在共享 bucket 中隔离应用数据，默认为空（不前缀）
    final keyPrefix = config['keyPrefix'] as String? ?? '';

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
    final forcePathStyle = config['forcePathStyle'] as bool? ??
        !isManagedCloudEndpoint(info.host);

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
    // 避免大 bucket 全量列举浪费带宽和时间
    try {
      await _client!.listObjects(bucket: bucket, maxKeys: 1);
    } on S3BucketNotFoundException catch (e) {
      throw CloudConfigurationException(
        'Bucket not found: ${e.bucket}. Please create the bucket first.',
      );
    } on S3AuthException catch (e) {
      throw CloudConfigurationException(
        'Authentication failed: ${e.message}. Please check your Access Key and Secret Key.',
      );
    } on S3NetworkException catch (e) {
      throw CloudConfigurationException(
        'Network error: ${e.message}. Please check your endpoint and network connection.',
      );
    } catch (e) {
      throw CloudConfigurationException(
        'Failed to initialize S3: $e',
      );
    }

    // 初始化服务
    _authService = S3AuthService(_client!, _bucket!);
    _storageService = S3StorageService(_client!, _bucket!, keyPrefix: keyPrefix);
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

    return endpoint != null && endpoint.isNotEmpty &&
           accessKey != null && accessKey.isNotEmpty &&
           secretKey != null && secretKey.isNotEmpty &&
           bucket != null && bucket.isNotEmpty;
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
