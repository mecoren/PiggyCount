library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

import 'supabase_auth_service.dart';
import 'supabase_storage_service.dart';
import 'supabase_database_service.dart';
import 'supabase_realtime_service.dart';

/// Supabase implementation of [CloudProvider].
///
/// This provider uses Supabase for cloud storage and authentication.
///
/// Required configuration keys:
/// - `url`: Supabase project URL
/// - `anonKey`: Supabase anonymous key
/// - `bucket`: Storage bucket name (optional, defaults to 'storage')
///
/// Example:
/// ```dart
/// final provider = SupabaseProvider();
/// await provider.initialize({
///   'url': 'https://your-project.supabase.co',
///   'anonKey': 'your-anon-key',
///   'bucket': 'user-data',
/// });
/// ```
class SupabaseProvider implements CloudProvider {
  supabase.SupabaseClient? _client;
  SupabaseAuthService? _authService;
  SupabaseStorageService? _storageService;
  SupabaseDatabaseService? _databaseService;
  SupabaseRealtimeService? _realtimeService;
  String _bucketName = 'storage';
  String? _pathPrefix;

  // Track current configuration to detect changes
  static String? _currentUrl;
  static String? _currentAnonKey;
  static bool _isInitialized = false;

  @override
  String get providerId => 'supabase';

  @override
  String get providerName => 'Supabase';

  @override
  CloudAuthService get auth {
    if (_authService == null) {
      throw CloudConfigurationException(
          'Provider not initialized. Call initialize() first.');
    }
    return _authService!;
  }

  @override
  CloudStorageService get storage {
    if (_storageService == null) {
      throw CloudConfigurationException(
          'Provider not initialized. Call initialize() first.');
    }
    return _storageService!;
  }

  /// Database service for direct database operations
  ///
  /// P2-10：懒装配 —— PiggyCount 的同步链只用 auth+storage（记录级
  /// 同步未启用，App 层零消费），旧实现在 initialize 时无条件实例化
  /// database+realtime 两个服务（realtime 还持有 channel 资源，dispose
  /// 要多跑 disconnect/dispose）。作为独立发布的包公开契约不变，
  /// 首次访问才创建。
  CloudDatabaseService? get databaseService =>
      _databaseService ??= _client == null ? null : SupabaseDatabaseService(_client!);

  /// Realtime service for WebSocket-based subscriptions（懒装配，见上）
  CloudRealtimeService? get realtimeService =>
      _realtimeService ??= _client == null ? null : SupabaseRealtimeService(_client!);

  /// Supabase client instance
  supabase.SupabaseClient? get client => _client;

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    if (!validateConfig(config)) {
      throw CloudConfigurationException(
          'Invalid configuration. Required keys: url, anonKey');
    }

    final url = config['url'] as String;
    final anonKey = config['anonKey'] as String;
    _bucketName = config['bucket'] as String? ?? 'storage';
    _pathPrefix = config['pathPrefix'] as String?;

    // SEC-01（对齐 WebDAV P2-7 / S3 SYNC-04 的 HTTPS 强制）：
    // anonKey 是具备 Storage 读写能力的长效凭据，随每个请求以
    // apikey/Authorization 头发送；http:// 链路上可被嗅探获得，
    // 进而在网外持续访问该 bucket（未开 E2EE 时即明文账本备份）。
    // 自托管 Supabase 用户按局域网地址填 http:// 是真实场景，
    // 必须在配置期显式拒绝并给出可执行指引。
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (scheme != 'https') {
      throw CloudConfigurationException(
        'Supabase 地址必须使用 HTTPS（当前为 '
        '${scheme.isEmpty ? '(无协议)' : '$scheme://'}，'
        'anonKey 将随每个请求在该链路上明文传输）。'
        '本地开发请通过代理或内网 HTTPS 网关暴露 Supabase',
      );
    }

    try {
      // 审计 S21：Supabase SDK 是进程级单例，initialize 不支持原地换
      // url/anonKey。旧实现配置变更时仅 signOut 旧 client 再靠异常字符串
      // 匹配兜底——兜底后拿到的仍是旧项目 client，数据会静默写错后端；
      // 且异常文案随 SDK 版本变化，匹配失败直接抛错。改为显式 dispose
      // 整个实例（内部会重置 SDK 初始化标志），再干净地重新 initialize。
      final configChanged = _currentUrl != url || _currentAnonKey != anonKey;

      if (_isInitialized && configChanged) {
        await supabase.Supabase.instance.dispose();
        _isInitialized = false;
      }

      if (!_isInitialized) {
        // Initialize Supabase client
        await supabase.Supabase.initialize(
          url: url,
          anonKey: anonKey,
          authOptions: const supabase.FlutterAuthClientOptions(
            authFlowType: supabase.AuthFlowType.pkce,
          ),
        );
        _isInitialized = true;
        _currentUrl = url;
        _currentAnonKey = anonKey;
      }

      _client = supabase.Supabase.instance.client;

      // Create service instances
      _authService = SupabaseAuthService(_client!);
      _storageService = SupabaseStorageService(_client!, _bucketName, _pathPrefix);
      // P2-10：database/realtime 不在此实例化（懒装配，见 getter 注释）
    } catch (e) {
      // 同配置重复 initialize（SDK 抛 already initialized）→ 复用现有实例。
      // 注意：仅在「配置未变」时才允许兜底，防止静默错连旧项目（审计 S21）。
      final sameConfig = _currentUrl == url && _currentAnonKey == anonKey;
      if (sameConfig &&
          (e.toString().contains('already initialized') ||
              e.toString().contains('LateInitializationError'))) {
        _client = supabase.Supabase.instance.client;
        _authService = SupabaseAuthService(_client!);
        _storageService = SupabaseStorageService(_client!, _bucketName, _pathPrefix);
        _isInitialized = true;
      } else {
        throw CloudConfigurationException(
            'Failed to initialize Supabase: $e', e);
      }
    }
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    if (!config.containsKey('url') || config['url'] is! String) {
      return false;
    }
    if (!config.containsKey('anonKey') || config['anonKey'] is! String) {
      return false;
    }
    // bucket is optional
    if (config.containsKey('bucket') && config['bucket'] is! String) {
      return false;
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    // 先断开 realtime 连接并释放资源，避免遗留订阅导致资源泄漏（C8）
    await _realtimeService?.disconnect();
    await _realtimeService?.dispose();
    _authService = null;
    _storageService = null;
    _databaseService = null;
    _realtimeService = null;
    _client = null;
    // 重置静态配置标记，使后续 initialize 可用新配置重新初始化（P-M1）
    _isInitialized = false;
    _currentUrl = null;
    _currentAnonKey = null;
  }
}
