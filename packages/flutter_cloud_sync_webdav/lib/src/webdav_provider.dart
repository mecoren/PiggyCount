library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'webdav_auth_service.dart';
import 'webdav_storage_service.dart';

/// WebDAV implementation of [CloudProvider].
///
/// This provider uses WebDAV protocol for cloud storage.
/// WebDAV uses Basic Auth for authentication.
///
/// Required configuration keys:
/// - `url`: WebDAV server URL
/// - `username`: Username for authentication
/// - `password`: Password for authentication
/// - `remotePath`: Remote path prefix (optional, defaults to '/')
///
/// Example:
/// ```dart
/// final provider = WebDAVProvider();
/// await provider.initialize({
///   'url': 'https://webdav.example.com',
///   'username': 'your-username',
///   'password': 'your-password',
///   'remotePath': '/sync/', // optional
/// });
/// ```
class WebDAVProvider implements CloudProvider {
  webdav.Client? _client;
  WebDAVAuthService? _authService;
  WebDAVStorageService? _storageService;

  @override
  String get providerId => 'webdav';

  @override
  String get providerName => 'WebDAV';

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

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    if (!validateConfig(config)) {
      throw CloudConfigurationException(
          'Invalid configuration. Required keys: url, username, password');
    }

    final url = config['url'] as String;
    final username = config['username'] as String;
    final password = config['password'] as String;
    final remotePath = config['remotePath'] as String? ?? '/';

    // P2-7：WebDAV 使用 HTTP Basic Auth，用户名密码以 Base64（可逆）
    // 随每个请求明文传输。强制 https，避免 http 链路上凭据被窃取。
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (scheme != 'https' && scheme != 'davs') {
      throw CloudConfigurationException(
          'WebDAV 地址必须使用 HTTPS（当前为 $scheme://，'
          'Basic Auth 凭据将在链路上明文传输）');
    }

    try {
      // Create WebDAV client
      _client = webdav.newClient(
        url,
        user: username,
        password: password,
        debug: false,
      );

      // Verify connection by reading the remote path
      try {
        // P3：60s 超时防服务器无响应导致初始化永久挂起
        await _client!.readDir(remotePath).timeout(
            const Duration(seconds: 60),
            onTimeout: () => throw CloudStorageException(
                'WebDAV 连接超时（60s），请检查网络或服务器'));
      } catch (e) {
        // 仅在 404（远端路径不存在）时触发创建；其他错误（网络中断、
        // 403 权限不足等）直接抛出，避免掩盖真实问题导致误导性的 mkdir。
        if (_isNotFound(e)) {
          await _client!.mkdir(remotePath).timeout(
              const Duration(seconds: 60),
              onTimeout: () => throw CloudStorageException(
                  'WebDAV 创建目录超时（60s），请检查网络或服务器'));
        } else if (_isUnauthorized(e)) {
          // 401/403 凭据错误：抛专属认证异常，上层（如 ensureInitialized
          // 调用方）据此引导用户重新配置，而非误报网络/配置格式问题
          throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
        } else {
          rethrow;
        }
      }

      // Create service instances
      _authService = WebDAVAuthService(username);

      _storageService = WebDAVStorageService(_client!, remotePath);
    } on CloudAuthException {
      // 保真透传：认证失败不能被包装成 CloudConfigurationException，
      // 否则调用方无法区分「密码错误」与「配置格式错误」
      rethrow;
    } catch (e) {
      throw CloudConfigurationException(
          'Failed to initialize WebDAV: $e', e);
    }
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    if (!config.containsKey('url') || config['url'] is! String) {
      return false;
    }
    if (!config.containsKey('username') || config['username'] is! String) {
      return false;
    }
    if (!config.containsKey('password') || config['password'] is! String) {
      return false;
    }
    // remotePath is optional
    if (config.containsKey('remotePath') &&
        config['remotePath'] is! String) {
      return false;
    }
    return true;
  }

  @override
  Future<void> dispose() async {
    _authService?.dispose();
    _authService = null;
    _storageService = null;
    // 关闭底层 dio 客户端，释放 HTTP 连接资源
    _client?.c.close(force: true);
    _client = null;
  }

  /// 统一判断 WebDAV 404 错误，优先使用结构化状态码，字符串匹配仅作兜底。
  ///
  /// 与 WebDAVStorageService._isNotFound 逻辑保持一致：优先读取 dio 异常
  /// 携带的 response.statusCode，无结构化信息时退化为字符串匹配。
  bool _isNotFound(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null && response.statusCode == 404) {
        return true;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段，进入字符串兜底
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('404') ||
        msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('no such');
  }

  /// 统一判断 WebDAV 401/403 认证失败，策略与 [_isNotFound] 一致：
  /// 优先读取 dio 异常携带的 response.statusCode，无结构化信息时退化为
  /// 字符串匹配。与 WebDAVStorageService._isUnauthorized 逻辑保持一致。
  bool _isUnauthorized(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null &&
          (response.statusCode == 401 || response.statusCode == 403)) {
        return true;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段，进入字符串兜底
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('401') ||
        msg.contains('403') ||
        msg.contains('unauthorized') ||
        msg.contains('forbidden');
  }
}
