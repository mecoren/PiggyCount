library;

import 'dart:async';
import 'dart:io' show HttpClient;

import 'package:dio/dio.dart' show CancelToken;
import 'package:dio/io.dart' show IOHttpClientAdapter;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

import 'webdav_auth_service.dart';
import 'webdav_storage_service.dart';

/// WebDAV 状态码过滤：拒绝 3xx（重定向）与无状态码响应，其余放行。
///
/// 返回 true 表示 dio 把该响应当作正常结果返回给上游；返回 false 则抛
/// DioException。详见 [WebDAVProvider.initialize] 内 W1 修复注释。
///
/// WDP-05：status == null（无状态响应，极罕见的传输层异常形态）不再
/// 当成功放行 —— 放行后 _statusCodeOf 拿不到结构化码，错误分类退化到
/// 字符串匹配（本包明确要避免的路径），异常响应可能被当正常数据流
/// 下发。null 视为失败，交由 dio 异常通道统一处理。
bool webdavValidateStatus(int? status) =>
    status != null && status < 300 || status != null && status >= 400;

/// dev 测试基础设施：模拟器内网自签 WebDAV 服务器豁免。
///
/// 仅当 (a) debug 构建 (kDebugMode) 且 (b) URL 命中 Android 模拟器
/// 宿主别名 10.0.2.2 的 8443 端口（scripts/webdav_test/webdav_server.py
/// 搭的自签 HTTPS 测试服务器）时，对 dart:io HttpClient 放宽证书校验。
/// 生产/坚果云/自建 NAS 等任何其他 URL 完全不受影响——证书链校验保持
/// 严格。服务器端 Basic Auth 仍然生效，仅豁免链路证书可信性。
bool _isDevTestServer(Uri uri) =>
    kDebugMode &&
    ((uri.host == '10.0.2.2' || uri.host == '127.0.0.1') &&
        uri.port == 8443);

/// 为 dev 测试服务器构造信任其自签证书的 HttpClient。
HttpClient _createDevTestHttpClient() {
  final client = HttpClient();
  client.badCertificateCallback =
      (cert, host, port) => host == '10.0.2.2' || host == '127.0.0.1';
  return client;
}

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

  /// LOG-01（对齐 S3 的 downgradeLogger 注入模式）：存储层关键告警
  /// （降级交换备份还原失败/临时文件清理失败/元数据读取失败）此前走
  /// `dart:developer` 的 dev.log —— 只在 `flutter run` 控制台可见，
  /// 不进应用日志系统（LoggerService），release 构建完全无痕迹。
  /// 这些恰是「数据半落地」的高危场景，线上排障需要留痕。宿主 app
  /// 在创建 provider 前设置此静态字段即可把告警接入应用日志管线；
  /// 不设置时退回 dev.log（行为与旧版一致，测试无感）。
  static CloudSyncLogger? storageLogger;

  /// W5 测试口：initialize 后底层 client 的 auth 模式。
  /// null = 未初始化；否则为 webdav_client 的 AuthType（预置 BasicAuth
  /// 后应为 BasicAuth；Digest 服务器兜底升级后为 DigestAuth）。
  webdav.AuthType? get authTypeForTest =>
      _client == null ? null : _client!.auth.type;

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

    // SEC-07（W-D 修复面的互补配置入口）：_buildPath 已拒绝**相对 path**
    // 的 `..` 段，但 remotePath 前缀本身（用户配置，亦来自配置导入通道）
    // 此前全程无分段校验 —— `remotePath = '/piggy/../../shared'` 会把
    // 应用全部对象重定向到前缀之外的目录（依赖服务器 ACL 兜底）。此处
    // 与 _assertNoTraversal 同口径：按 `/` 分段后存在恰为 `..` 的段
    // 即拒绝。
    for (final seg in remotePath.split('/')) {
      if (seg == '..') {
        throw CloudConfigurationException(
            'Invalid remotePath containing ".." segment: $remotePath');
      }
    }

    // P2-7：WebDAV 使用 HTTP Basic Auth，用户名密码以 Base64（可逆）
    // 随每个请求明文传输。强制 https，避免 http 链路上凭据被窃取。
    //
    // 审计 W-K：`davs://` 是部分客户端自造的 scheme，标准 WebDAV over TLS
    // 就是 https://。dio/http 不支持 davs，放行只会在首个请求时以晦涩的
    // 「Unsupported scheme」失败 —— 校验阶段直接拒绝并给出可执行的指引。
    final scheme = Uri.tryParse(url)?.scheme.toLowerCase() ?? '';
    if (scheme == 'davs') {
      throw CloudConfigurationException(
          '不支持 davs:// 地址（dio 无法处理该协议）。'
          'WebDAV over TLS 请直接填写 https:// 形式地址');
    }
    if (scheme != 'https') {
      throw CloudConfigurationException(
          'WebDAV 地址必须使用 HTTPS（当前为 ${scheme.isEmpty ? '(无协议)' : '$scheme://'}，'
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

      // W5 预置 BasicAuth：webdav_client 初始 Auth 为 NoAuth —— 每个操作
      // 都先无凭据发一次请求、吃 401、再由上游按 WWW-Authenticate 升级
      // Basic 重试，一倍额外往返。App 明知配置的是 Basic 凭据，直接预置
      // BasicAuth 省掉协商；也顺带绕开了「401 + 同连接 keep-alive 重试」
      // 的边缘场景（自签测试服务器实测踩坑点）。Digest 服务器兜底见下方
      // 探测后的 401 处理。
      _client!.auth = webdav.BasicAuth(user: username, pwd: password);

      // 审计 S23：禁用自动重定向。dart:io 对 301/302/303 会把 PUT/MOVE/
      // DELETE 改写成 GET 并丢弃 body——「上传成功」假象但什么都没写；
      // 且 Basic Auth 凭据会原样重放到重定向目标，https→http 302 即可
      // 让凭据明文过网，绕开上面的 HTTPS 强制。改为显式拒绝 3xx，
      // 引导用户直接填写最终地址。
      //
      // W1 修复：validateStatus 只拒 3xx，4xx/5xx 一律放行给上游处理。
      // 上游 webdav_client 的设计是「响应作为返回值」：404/403 等由上层
      // 各操作显式检查状态码抛错。只拦 3xx 可同时保住两个目标：
      // 错误状态码正常交给上层语义判断 + 重定向绝不跟随。
      _client!.c.options.followRedirects = false;
      _client!.c.options.maxRedirects = 0;
      _client!.c.options.validateStatus = webdavValidateStatus;

      // dev 测试基础设施：见 _isDevTestServer 注释。仅对模拟器宿主的
      // 自签测试服务器放宽 dart:io 证书校验，其余 URL 保持严格校验。
      final parsedUri = Uri.tryParse(url);
      if (parsedUri != null && _isDevTestServer(parsedUri)) {
        final adapter = IOHttpClientAdapter();
        adapter.createHttpClient = _createDevTestHttpClient;
        _client!.c.httpClientAdapter = adapter;
      }

      // Verify connection by reading the remote path
      try {
        // 审计 W-J：探测超时同时取消底层请求（对齐存储层 _op 策略）。
        // 此前仅 Future.timeout 放弃等待，PROPFIND/MKCOL 仍在后台飞行，
        // 迟到的响应会与后续 mkdirAll 竞态。
        await _probeWithTimeout(
            'readDir', (t) => _client!.readDir(remotePath, t));
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
          await _probeWithTimeout(
              'mkdirAll', (t) => _client!.mkdirAll(remotePath, t));
        } else if (_isUnauthorized(e)) {
          // W5 Digest 兜底：预置 BasicAuth 后，Digest-only 服务器的 401
          // 不会被上游协商分支处理（该分支仅在 NoAuth 起态可达）。这里读
          // WWW-Authenticate challenge：Digest → 升级 DigestAuth 后重探测
          // 一次；否则按凭据错误处理。
          final challenge = _wwwAuthenticateOf(e);
          if (challenge != null &&
              challenge.toLowerCase().contains('digest')) {
            _client!.auth = webdav.DigestAuth(
              user: username,
              pwd: password,
              dParts: webdav.DigestParts(challenge),
            );
            try {
              await _probeWithTimeout(
                  'readDir(digest)', (t) => _client!.readDir(remotePath, t));
              // Digest 探测成功：继续正常初始化流程
            } catch (e2) {
              if (_isUnauthorized(e2)) {
                throw CloudAuthException('WebDAV 认证失败（账号或密码错误）', e2);
              }
              rethrow;
            }
          } else {
            // 401/403 凭据错误：抛专属认证异常，上层（如 ensureInitialized
            // 调用方）据此引导用户重新配置，而非误报网络/配置格式问题。
            // 审计 W-X：401 与 403 分开表述（403 多为权限不足而非密码错误）
            final code = _statusCodeOf(e);
            throw code == 403
                ? CloudAuthException(
                    'WebDAV 访问被拒绝（权限不足）：请检查账号对该目录的读写权限或服务器配额',
                    e)
                : CloudAuthException('WebDAV 认证失败（账号或密码错误）', e);
          }
        } else {
          rethrow;
        }
      }

      // Create service instances
      _authService = WebDAVAuthService(username);

      // LOG-01：注入应用日志（宿主经 WebDAVProvider.storageLogger 设置），
      // 存储层关键告警不再只走 dev.log（release 无痕迹）。
      _storageService = WebDAVStorageService(_client!, remotePath,
          logger: WebDAVProvider.storageLogger);
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

  /// 初始化探测的统一超时包装（P3 + 审计 W-J）：
  /// 超时先取消底层 HTTP 请求再抛 [CloudStorageException]，
  /// 避免放弃等待后请求仍在后台飞行、迟到响应与后续操作竞态。
  static const _probeTimeout = Duration(seconds: 60);

  Future<T> _probeWithTimeout<T>(
      String opName, Future<T> Function(CancelToken token) op) {
    final token = CancelToken();
    final timer = Timer(_probeTimeout, () => token.cancel('WebDAV $opName 超时'));
    return op(token).timeout(_probeTimeout, onTimeout: () {
      throw CloudStorageException(
          'WebDAV $opName 超时（${_probeTimeout.inSeconds}s），请检查网络或服务器');
    }).whenComplete(timer.cancel);
  }

  /// 提取异常携带的结构化 HTTP 状态码（dio 系异常），无则返回 null。
  int? _statusCodeOf(Object e) {    try {
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

  /// W5：提取 401 响应的 WWW-Authenticate challenge 头（dio 系异常）。
  /// 判定 Digest 兜底升级用；非 dio 异常/无头返回 null。
  String? _wwwAuthenticateOf(Object e) {
    try {
      final dynamic dyn = e;
      final dynamic response = dyn.response;
      if (response != null) {
        final dynamic headers = response.headers;
        final dynamic value =
            headers.value?.call('www-authenticate') as String?;
        if (value != null && value.isNotEmpty) return value;
      }
    } catch (_) {
      // 非 dio 异常类型
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
