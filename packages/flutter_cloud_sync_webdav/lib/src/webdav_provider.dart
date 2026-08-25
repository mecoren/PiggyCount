library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'webdav_auth_service.dart';
import 'webdav_storage_service.dart';

/// WebDAV 状态码过滤：仅拒绝 3xx（重定向），其余一律放行。
///
/// 返回 true 表示 dio 把该响应当作正常结果返回给上游；返回 false 则抛
/// DioException。详见 [WebDAVProvider.initialize] 内 W1 修复注释。
bool webdavValidateStatus(int? status) =>
    status == null || status < 300 || status >= 400;

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
      // 审计 WD-M7：创建前先释放旧实例（重复 initialize 场景），
      // 避免旧 dio client 连接池泄漏。
      await _disposeQuietly();

      // Create WebDAV client
      _client = webdav.newClient(
        url,
        user: username,
        password: password,
        debug: false,
      );

      // 审计 S23：禁用自动重定向。dart:io 对 301/302/303 会把 PUT/MOVE/
      // DELETE 改写成 GET 并丢弃 body——「上传成功」假象但什么都没写；
      // 且 Basic Auth 凭据会原样重放到重定向目标，https→http 302 即可
      // 让凭据明文过网，绕开上面的 HTTPS 强制。改为显式拒绝 3xx，
      // 引导用户直接填写最终地址。
      //
      // W1 修复：validateStatus 只拒 3xx，4xx/5xx 一律放行给上游处理。
      // 上游 webdav_client 的设计是「响应作为返回值」：首个请求不带凭据
      // （NoAuth），收到 401 后由上游读 WWW-Authenticate 协商升级
      // Basic/Digest 并重试；404/403 等也由上层各操作显式检查状态码抛错。
      // 之前把阈值设为 <300，401 直接变成 DioException，认证协商成死代码，
      // 正确密码也会被报「认证失败」。只拦 3xx 可同时保住两个目标：
      // 认证协商正常工作 + 重定向绝不跟随（含上游的手工 302 跟随路径）。
      _client!.c.options.followRedirects = false;
      _client!.c.options.maxRedirects = 0;
      _client!.c.options.validateStatus = webdavValidateStatus;

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
        if (_isRedirect(e)) {
          throw CloudConfigurationException(
              'WebDAV 服务器返回了重定向（3xx）。请直接填写重定向后的最终地址，'
              '避免凭据被转发到第三方域名');
        } else if (_isNotFound(e)) {
          // F4：远端路径不存在 → 递归创建全部缺失层级。此前单级 mkdir 遇到
          // 嵌套 remotePath（如 /a/b/PiggyCount 且 /a 不存在）时，MKCOL 因
          // 缺父目录返回 409 → 直接初始化失败。mkdirAll 在 409 时逐级补建
          // （webdav_client client.mkdirAll），与 uploadBinary 内
          // _createDirectoryRecursively 的逐级语义一致。
          await _client!.mkdirAll(remotePath).timeout(
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
      await _disposeQuietly();
      rethrow;
    } on CloudStorageException {
      // 审计 WD-M8：连接超时等存储层异常由内层显式抛出（带「请检查网络」
      // 指引），不能再被下方 catch-all 包装成「配置无效」—— 网络问题
      // 改配置无用，语义错位会误导排查方向。
      await _disposeQuietly();
      rethrow;
    } catch (e) {
      // 审计 WD-M7：初始化失败必须释放已创建的 client，否则调用方丢弃
      // provider 后 dio 连接池泄漏。
      await _disposeQuietly();
      throw CloudConfigurationException(
          'Failed to initialize WebDAV: $e', e);
    }
  }

  /// 释放当前持有的底层资源（dio client + 服务实例），错误静默忽略。
  ///
  /// 供 dispose 与 initialize 失败/重复调用路径复用（审计 WD-M7）。
  Future<void> _disposeQuietly() async {
    _authService?.dispose();
    _authService = null;
    _storageService = null;
    final client = _client;
    _client = null;
    if (client != null) {
      try {
        client.c.close(force: true);
      } catch (_) {
        // 关闭失败不影响主流程
      }
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
    await _disposeQuietly();
  }

  /// 提取异常携带的结构化 HTTP 状态码（dio 系异常），无则返回 null。
  int? _statusCodeOf(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        final dynamic code = response.statusCode;
        if (code is int) return code;
      }
    } catch (_) {
      // 非 dio 异常类型，无 response 字段
    }
    return null;
  }

  /// 统一判断 WebDAV 404 错误，优先使用结构化状态码，字符串匹配仅作兜底。
  ///
  /// 与 WebDAVStorageService._isNotFound 逻辑保持一致（M5）：只要异常
  /// 携带结构化 response 就只按状态码判定。字符串兜底不做纯数字子串
  /// 匹配（审计 WD-M3：无结构化信息的异常消息常内嵌 host:port，
  /// `:8404` 会撞出 "404"），仅做明确措辞匹配。
  bool _isNotFound(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 404;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('not found') ||
        msg.contains('does not exist') ||
        msg.contains('no such file') ||
        msg.contains('no such resource');
  }

  /// 统一判断 WebDAV 401/403 认证失败，策略与 [_isNotFound] 一致：
  /// 有结构化状态码只看状态码；字符串兜底仅限无结构化信息时的措辞匹配
  /// （WD-M3 同款理由）。
  bool _isUnauthorized(Object e) {
    final code = _statusCodeOf(e);
    if (code != null) {
      return code == 401 || code == 403;
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('unauthorized') || msg.contains('forbidden');
  }

  /// 审计 S23：识别重定向（3xx）。followRedirects=false 后 dio 会把
  /// 3xx 响应按异常抛出（validateStatus 拦截），此处统一判定。
  /// M5 同款：有结构化 response 只看状态码。
  bool _isRedirect(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        final code = response.statusCode as int?;
        return code != null && code >= 300 && code < 400;
      }
    } catch (_) {
      // 非 dio 异常类型
    }
    final msg = e.toString().toLowerCase();
    return msg.contains('302 found') ||
        msg.contains('301 moved') ||
        msg.contains('307 temporary') ||
        msg.contains('308 permanent') ||
        msg.contains('redirect');
  }
}
