import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 日志级别
enum LogLevel {
  debug,
  info,
  warning,
  error;

  String get displayName {
    switch (this) {
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.info:
        return 'INFO';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  String get emoji {
    switch (this) {
      case LogLevel.debug:
        return '🔍';
      case LogLevel.info:
        return 'ℹ️';
      case LogLevel.warning:
        return '⚠️';
      case LogLevel.error:
        return '❌';
    }
  }
}

/// 日志来源平台
enum LogPlatform {
  flutter,
  android,
  ios;

  String get displayName {
    switch (this) {
      case LogPlatform.flutter:
        return 'Flutter';
      case LogPlatform.android:
        return 'Android';
      case LogPlatform.ios:
        return 'iOS';
    }
  }
}

/// 日志条目
class LogEntry {
  final DateTime timestamp;
  final LogLevel level;
  final LogPlatform platform;
  final String tag;
  final String message;
  final Object? error;
  final StackTrace? stackTrace;

  const LogEntry({
    required this.timestamp,
    required this.level,
    required this.platform,
    required this.tag,
    required this.message,
    this.error,
    this.stackTrace,
  });

  /// 序列化为 JSON
  Map<String, dynamic> toJson() {
    return {
      'timestamp': timestamp.millisecondsSinceEpoch,
      'level': level.index,
      'platform': platform.index,
      'tag': tag,
      'message': message,
      'error': error?.toString(),
      'stackTrace': stackTrace?.toString(),
    };
  }

  /// 从 JSON 反序列化
  factory LogEntry.fromJson(Map<String, dynamic> json) {
    return LogEntry(
      timestamp: DateTime.fromMillisecondsSinceEpoch(json['timestamp'] as int),
      level: LogLevel.values[json['level'] as int],
      platform: LogPlatform.values[json['platform'] as int],
      tag: json['tag'] as String,
      message: json['message'] as String,
      error: json['error'],
      stackTrace: json['stackTrace'] != null
          ? StackTrace.fromString(json['stackTrace'] as String)
          : null,
    );
  }

  /// 格式化为文本
  String toFormattedString() {
    final buffer = StringBuffer();

    // 时间戳
    final time = '${_twoDigits(timestamp.hour)}:'
        '${_twoDigits(timestamp.minute)}:'
        '${_twoDigits(timestamp.second)}.'
        '${_threeDigits(timestamp.millisecond)}';

    buffer.write('[$time] ');
    buffer.write('[${level.displayName}] ');
    buffer.write('[${platform.displayName}] ');
    buffer.write('[$tag] ');
    buffer.writeln(message);

    if (error != null) {
      buffer.writeln('  Error: $error');
    }

    if (stackTrace != null) {
      buffer.writeln('  Stack Trace:');
      buffer.writeln('  ${stackTrace.toString().replaceAll('\n', '\n  ')}');
    }

    return buffer.toString();
  }

  static String _twoDigits(int n) => n.toString().padLeft(2, '0');
  static String _threeDigits(int n) => n.toString().padLeft(3, '0');
}

/// 日志脱敏（LOG-05）：日志明文落盘且可分享/导出，此前防泄漏完全依赖
/// 每处调用点自觉不写敏感值。这里是中央脱敏层——所有日志（含原生桥接
/// 与未来的新调用点）在进入内存队列/落盘前统一过滤，防线不再依赖人。
///
/// 策略（模式匹配，宁可多脱不可漏脱）：
/// - URL 内嵌凭据：`https://user:pass@host` → `https://***@host`
///   （WebDAV/Supabase 端点误带凭据的直接外泄面）；
/// - 键值对凭据：`password=X` / `passwd` / `secret` / `secretKey` /
///   `anonKey` / `apiKey` / `api_key` / `token` / `accessToken` /
///   `authorization`（大小写不敏感，值的边界为行尾/空白/引号/逗号/分号/
///   括号/`&`）→ `key=***`；
/// - JSON 字段凭据：`"password": "x"` 等同款 key 的 JSON 形态 → `***`
///   （值里已有引号边界，正则与键值对分开写）；
/// - Bearer 头：`Bearer xxx` → `Bearer ***`；
/// - Base64 Basic 头：`Basic xxx` → `Basic ***`。
///
/// 已知取舍（审计确认无泄漏，脱敏不针对这些形态）：
/// - 指纹哈希（sha256 十六进制）非凭据，保留用于排障对账；
/// - 账本名（seed/导入日志）不脱敏——业务语义量，且不构成凭据。
class LogSanitizer {
  LogSanitizer._();

  /// 键值对凭据：key 部分的大小写不敏感词表。组 1 = key+分隔符
  /// （`=` 或 `:`，含周围空白），组 2 = 值。值的边界为行尾/空白/
  /// 引号/逗号/分号/圆括号/&/方括号（字符类内逐个列举，避免嵌套转义）。
  /// 大小写不敏感经构造参数实现（Dart RegExp 不支持 (?i) 全局内联）。
  static final RegExp _kvCredential = RegExp(
    '\\b(password|passwd|secret|secretKey|secret_key|anonKey|anon_key|'
    'apiKey|api_key|token|accessToken|access_token|refreshToken|'
    'refresh_token|authorization)\\b(\\s*[=:]\\s*)'
    '([^\\s,;&)(\\[\\]+\'"]+)',
    caseSensitive: false,
  );

  /// JSON 字段凭据："password": "x" / "apiKey": "x"。
  static final RegExp _jsonCredential = RegExp(
    '("(?:password|passwd|secret|secretKey|secret_key|anonKey|anon_key|'
    'apiKey|api_key|token|accessToken|access_token|refreshToken|'
    'refresh_token|authorization)"\\s*:\\s*)"[^"]*"',
    caseSensitive: false,
  );

  /// URL 内嵌 userinfo：scheme://user:pass@ → scheme://***@。
  static final RegExp _urlUserInfo = RegExp(
    r'([a-zA-Z][a-zA-Z0-9+.\-]*://)([^/@:\s]+):([^@\s]+)@',
  );

  /// Bearer / Basic 认证头值。
  static final RegExp _authHeader = RegExp(
    r'\b(bearer|basic)\s+[A-Za-z0-9\-_.=+/]+',
    caseSensitive: false,
  );

  static const _masked = '***';

  /// 对单条日志文本做脱敏（幂等：`***` 不会被再次改写）。
  ///
  /// 顺序敏感：先脱 Bearer/Basic 头再脱键值对——`Authorization: Bearer xxx`
  /// 若键值对先行，会把 `Bearer` 误认作值脱成 `Authorization: *** xxx`，
  /// 留下 token 残值；头规则先行则整体命中一次脱净。
  static String sanitize(String input) {
    var out = input;
    out = out.replaceAllMapped(
        _urlUserInfo, (m) => '${m[1]}***@');
    out = out.replaceAllMapped(
        _authHeader, (m) => '${m[1]} $_masked');
    out = out.replaceAllMapped(_jsonCredential, (m) => '${m[1]}"$_masked"');
    out = out.replaceAllMapped(
        _kvCredential, (m) => '${m[1]}${m[2]}$_masked');
    return out;
  }
}

/// 日志服务
class LoggerService {
  static final LoggerService _instance = LoggerService._internal();
  factory LoggerService() => _instance;
  LoggerService._internal() {
    _setupNativeBridge();
  }

  static const _channel = MethodChannel('com.piggycount.logger');
  static const _storageKey = 'app_logs';
  static const _maxStorageHours = 48; // 保留48小时

  // 使用循环缓冲区存储日志，最多保留最近的 2000 条
  static const int _maxLogs = 2000;
  final _logs = Queue<LogEntry>();

  // 日志监听器
  final _listeners = <VoidCallback>[];

  bool _isLoaded = false;

  /// LOG-04：历史日志加载的 single-flight Future。
  ///
  /// 修复前 _loadLogs 是 fire-and-forget：_isLoaded 立即置 true，历史日志
  /// 在 SharedPreferences 回调里才入队——窗口期内的新日志直入内存队，
  /// 2s 节流保存把「只含新日志」的队列覆盖写盘，历史永久丢失；加载
  /// 完成后旧日志再追加队尾，时序颠倒。现在：加载未完成期间新日志进
  /// [_pendingLogs] 暂存（不入队、不触发保存），加载完成后按时间序
  /// （历史在前）并入；[_doSaveLogs] 写盘前先等加载完成，覆盖竞态归零。
  Future<void>? _loadFuture;

  /// LOG-04：加载竞态窗口期暂存的新日志（等历史日志入队后并入）。
  final _pendingLogs = Queue<LogEntry>();

  /// LOG-04：clear 的世代计数——加载在 flight 时用户清空日志，随后
  /// 完成的加载不得把历史日志再填回来（清空语义优先于加载）。
  int _logsGeneration = 0;

  Timer? _saveTimer;
  bool _isSaving = false;

  /// 获取所有日志（自动触发加载，返回当前内存视图 + 暂存日志）
  List<LogEntry> get logs {
    if (!_isLoaded) {
      _ensureLoaded();
    }
    if (_pendingLogs.isEmpty) return _logs.toList();
    return [..._logs, ..._pendingLogs];
  }

  /// 添加监听器
  void addListener(VoidCallback listener) {
    _listeners.add(listener);
  }

  /// 移除监听器
  void removeListener(VoidCallback listener) {
    _listeners.remove(listener);
  }

  /// 通知监听器
  void _notifyListeners() {
    for (final listener in _listeners) {
      listener();
    }
  }

  /// 添加日志
  void _addLog(LogEntry rawEntry) {
    // LOG-05：中央脱敏层——所有日志（Flutter/原生、新旧调用点）入队
    // 与落盘前统一过滤，凭据不再依赖每处调用点自觉不写
    final entry = LogEntry(
      timestamp: rawEntry.timestamp,
      level: rawEntry.level,
      platform: rawEntry.platform,
      tag: rawEntry.tag,
      message: LogSanitizer.sanitize(rawEntry.message),
      error: rawEntry.error == null
          ? null
          : LogSanitizer.sanitize(rawEntry.error.toString()),
      stackTrace: rawEntry.stackTrace,
    );

    // LOG-04：历史日志尚未加载完成（无论加载是否已触发）→ 暂存，
    // 等加载完成后按序并入。不触发监听器保存（保存前会等加载完成，
    // 暂存日志一并入盘）。注意首次写日志也要走这里——_addLog 自身
    // 触发的 _ensureLoaded 是异步的，本条日志若直接入队会先于历史
    // 落盘窗口出现（覆盖竞态的根源）。
    if (!_isLoaded) {
      _ensureLoaded(); // 幂等：已在 flight 则返回同一 Future
      _pendingLogs.add(entry);
      if (kDebugMode) {
        debugPrint(entry.toFormattedString());
      }
      return;
    }

    // 循环缓冲：如果超过最大数量，移除最旧的
    if (_logs.length >= _maxLogs) {
      _logs.removeFirst();
    }

    _logs.add(entry);

    // 同时打印到控制台（开发模式）
    if (kDebugMode) {
      debugPrint(entry.toFormattedString());
    }

    // 通知监听器
    _notifyListeners();

    // 异步保存到持久化存储
    _saveLogs();
  }

  /// LOG-04：single-flight 加载历史日志。
  ///
  /// 首个调用方执行实际 IO；窗口期内（_loadFuture 非 null）新日志全部
  /// 暂存进 [_pendingLogs]；加载完成后历史入队、暂存日志按时间序并入、
  /// 通知监听器并安排一次保存。进程内只有一个 LoggerService 单例，
  /// _loadFuture 的生命周期即「启动加载窗口」。
  Future<void> _ensureLoaded() {
    if (_isLoaded) return Future.value();
    return _loadFuture ??= _loadLogs();
  }

  /// 加载持久化的日志（幂等：并发调用共享同一 Future）
  Future<void> _loadLogs() async {
    final generation = _logsGeneration;
    try {
      final prefs = await SharedPreferences.getInstance();
      // 加载期间用户 clear 过 → 丢弃历史（清空语义优先于加载）
      if (generation != _logsGeneration) {
        debugPrint('加载完成前日志已被清空，丢弃历史日志');
        return;
      }
      final jsonStr = prefs.getString(_storageKey);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final List<dynamic> jsonList = jsonDecode(jsonStr);
        final now = DateTime.now();

        // 过滤掉超过48小时的日志
        for (final json in jsonList) {
          try {
            final entry = LogEntry.fromJson(json as Map<String, dynamic>);
            final age = now.difference(entry.timestamp);

            if (age.inHours < _maxStorageHours) {
              _logs.add(entry);
            }
          } catch (e) {
            debugPrint('加载日志条目失败: $e');
          }
        }

        debugPrint('从持久化存储加载了 ${_logs.length} 条日志');
      }
    } catch (e) {
      debugPrint('加载日志失败: $e');
    } finally {
      _isLoaded = true;

      // 暂存日志并入（历史在前，保持时间序）。暂存可能超出 _maxLogs，
      // 从队头挤出最旧的历史条目，语义与循环缓冲一致。
      while (_pendingLogs.isNotEmpty) {
        if (_logs.length >= _maxLogs) {
          _logs.removeFirst();
        }
        _logs.add(_pendingLogs.removeFirst());
      }

      _loadFuture = null;

      // 窗口期有暂存日志或有历史并入 → 通知 UI 并安排保存
      // （保存前 _doSaveLogs 会再等一次 _loadFuture——此刻为 null，
      // 直接落盘，历史 + 新日志一起写入）
      if (_listeners.isNotEmpty) {
        _notifyListeners();
      }
      _saveLogs();
    }
  }

  /// 保存日志到持久化存储（节流：最多每 2 秒写一次）
  void _saveLogs() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _doSaveLogs);
  }

  Future<void> _doSaveLogs() async {
    if (_isSaving) return;
    _isSaving = true;
    try {
      // LOG-04：写盘前等启动加载完成——否则会把「只含窗口期新日志」
      // 的队列覆盖写盘，历史日志永久丢失
      final loading = _loadFuture;
      if (loading != null) {
        await loading;
      }
      final now = DateTime.now();
      final validLogs = _logs.where((log) {
        final age = now.difference(log.timestamp);
        return age.inHours < _maxStorageHours;
      }).toList();

      final jsonList = validLogs.map((log) => log.toJson()).toList();
      final jsonStr = jsonEncode(jsonList);

      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_storageKey, jsonStr);
    } catch (e) {
      debugPrint('保存日志失败: $e');
    } finally {
      _isSaving = false;
    }
  }

  /// Debug 日志
  void debug(String tag, String message, [dynamic data]) {
    final msg = data != null ? '$message | Data: $data' : message;
    _addLog(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.debug,
      platform: LogPlatform.flutter,
      tag: tag,
      message: msg,
    ));
  }

  /// Info 日志
  void info(String tag, String message, [dynamic data]) {
    final msg = data != null ? '$message | Data: $data' : message;
    _addLog(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.info,
      platform: LogPlatform.flutter,
      tag: tag,
      message: msg,
    ));
  }

  /// Warning 日志
  void warning(String tag, String message, [dynamic data]) {
    final msg = data != null ? '$message | Data: $data' : message;
    _addLog(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.warning,
      platform: LogPlatform.flutter,
      tag: tag,
      message: msg,
    ));
  }

  /// Error 日志
  void error(String tag, String message, [dynamic error, StackTrace? stackTrace]) {
    _addLog(LogEntry(
      timestamp: DateTime.now(),
      level: LogLevel.error,
      platform: LogPlatform.flutter,
      tag: tag,
      message: message,
      error: error,
      stackTrace: stackTrace,
    ));
  }

  /// 清空日志
  void clear() {
    // LOG-04：世代计数 +1——若历史加载仍在 flight，加载完成时会
    // 检测到世代变化而丢弃历史，避免「刚清空又冒出旧日志」。
    _logsGeneration++;
    _logs.clear();
    _pendingLogs.clear();
    _notifyListeners();
  }

  /// 单测复位口（@visibleForTesting）：单例状态归零，隔离用例间
  /// 的加载标志/队列/世代残留。生产代码禁止调用。
  @visibleForTesting
  void resetForTesting() {
    _saveTimer?.cancel();
    _logs.clear();
    _pendingLogs.clear();
    _isLoaded = false;
    _loadFuture = null;
    _logsGeneration = 0;
    _isSaving = false;
  }

  /// 单测等待口（@visibleForTesting）：等历史日志加载完成。
  @visibleForTesting
  Future<void> ensureLoadedForTest() => _ensureLoaded();

  /// 单测保存口（@visibleForTesting）：立即执行一次落盘（绕过 2s 节流）。
  @visibleForTesting
  Future<void> doSaveLogsForTest() => _doSaveLogs();

  /// 导出所有日志为文本（LOG-04：含加载窗口期暂存的日志）
  String exportAsText() {
    if (!_isLoaded) {
      _ensureLoaded();
    }
    final all = _pendingLogs.isEmpty
        ? _logs.toList()
        : [..._logs, ..._pendingLogs];
    final buffer = StringBuffer();
    buffer.writeln('=== PiggyCount 日志导出 ===');
    buffer.writeln('导出时间: ${DateTime.now()}');
    buffer.writeln('日志数量: ${all.length}');
    buffer.writeln('=' * 50);
    buffer.writeln();

    for (final log in all) {
      buffer.write(log.toFormattedString());
      buffer.writeln();
    }

    return buffer.toString();
  }

  /// 设置原生日志桥接
  void _setupNativeBridge() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onNativeLog') {
        final args = call.arguments as Map;
        _handleNativeLog(args);
      }
    });
  }

  /// 处理原生日志
  void _handleNativeLog(Map args) {
    try {
      debugPrint('📱 收到原生日志: $args');

      final platformStr = args['platform'] as String;
      final levelStr = args['level'] as String;
      final tag = args['tag'] as String;
      final message = args['message'] as String;
      final timestamp = args['timestamp'] as int;

      // 解析平台
      final platform = platformStr == 'android'
          ? LogPlatform.android
          : platformStr == 'ios'
              ? LogPlatform.ios
              : LogPlatform.flutter;

      // 解析日志级别
      final level = _parseLogLevel(levelStr);

      debugPrint('📝 添加原生日志到队列: [$platformStr] [$levelStr] [$tag] $message');

      _addLog(LogEntry(
        timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
        level: level,
        platform: platform,
        tag: tag,
        message: message,
      ));
    } catch (e, stackTrace) {
      debugPrint('处理原生日志失败: $e');
      debugPrint('堆栈: $stackTrace');
    }
  }

  LogLevel _parseLogLevel(String levelStr) {
    switch (levelStr.toUpperCase()) {
      case 'DEBUG':
      case 'D':
        return LogLevel.debug;
      case 'INFO':
      case 'I':
        return LogLevel.info;
      case 'WARNING':
      case 'WARN':
      case 'W':
        return LogLevel.warning;
      case 'ERROR':
      case 'E':
        return LogLevel.error;
      default:
        return LogLevel.info;
    }
  }
}

/// 全局日志实例
final logger = LoggerService();

/// fire-and-forget 但异常必须落日志 —— 替代裸 `unawaited(future)`。
///
/// 全局 `PlatformDispatcher.onError` 能兜住未处理异常，但没有业务上下文，
/// 报障日志里只有一行孤零零的堆栈，定位不到是哪条链路。此封装给每条
/// 后台链一个可检索的 context；失败记 warning（后台链路失败通常不该
/// 打扰前台，故不弹 toast，需要用户感知的场景由调用方自行补 UI）。
void unawaitedLog(Future<void> future, String context) {
  unawaited(() async {
    try {
      await future;
    } catch (e, st) {
      logger.warning('Unawaited', '$context 失败（后台链路，不阻塞前台）: $e\n$st');
    }
  }());
}
