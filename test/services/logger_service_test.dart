/// LoggerService 单元测试
///
/// LOG-04（2026-09-09）：启动加载竞态修复——
/// 修复前 _loadLogs fire-and-forget + _isLoaded 立即置 true，窗口期内
/// 新日志先入队，2s 节流保存把「只含新日志」的队列覆盖写盘（历史丢失），
/// 加载完成后旧日志又追加队尾（时序颠倒）。修复后：single-flight 加载 +
/// pending 暂存 + 写盘前等加载 + clear 世代计数。
///
/// LOG-05（2026-09-09）：中央脱敏层——所有日志入队/落盘前统一过滤
/// URL userinfo / 键值对凭据 / JSON 凭据字段 / Bearer·Basic 头。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/services/system/logger_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late LoggerService logger;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    logger = LoggerService()..resetForTesting();
  });

  group('LOG-04：启动加载竞态', () {
    test('加载窗口期的新日志不丢失，且时序在历史之后', () async {
      // 预置历史日志（模拟上次会话落盘）
      final historyTime =
          DateTime.now().subtract(const Duration(hours: 1)).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'app_logs':
            '[{"timestamp":$historyTime,"level":1,"platform":0,"tag":"History",'
                '"message":"old entry","error":null,"stackTrace":null}]',
      });
      logger = LoggerService()..resetForTesting();

      // 触发加载（异步未完成）后立即写新日志 —— 修复前此窗口内的
      // 新日志会先入队并在 2s 后把只含自己的队列覆盖写盘
      logger.info('Window', 'new entry during load');
      // 等待加载完成（pending 并入）
      await logger.ensureLoadedForTest();

      final all = logger.logs;
      expect(all.length, 2, reason: '历史与新日志都在，窗口期新日志不丢失');
      expect(all.first.tag, 'History', reason: '历史日志在前（时序保持）');
      expect(all.last.message, 'new entry during load',
          reason: '窗口期新日志按序并入历史之后');
    });

    test('写盘前等加载完成——历史日志不被窗口期保存覆盖', () async {
      final historyTime =
          DateTime.now().subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'app_logs':
            '[{"timestamp":$historyTime,"level":1,"platform":0,"tag":"History",'
                '"message":"precious old entry","error":null,"stackTrace":null}]',
      });
      logger = LoggerService()..resetForTesting();

      // 加载触发 + 立刻写新日志（进 pending）→ 触发保存
      logger.warning('Window', 'entry while loading');
      // 手动执行一次保存逻辑（绕过 2s 节流定时器）
      await logger.doSaveLogsForTest();

      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString('app_logs')!;
      expect(saved.contains('precious old entry'), isTrue,
          reason: '保存必须包含历史日志（等加载完成后才写盘）');
      expect(saved.contains('entry while loading'), isTrue,
          reason: '窗口期新日志一并落盘');
    });

    test('加载期间 clear → 加载完成后历史不回填（清空语义优先）', () async {
      final historyTime =
          DateTime.now().subtract(const Duration(minutes: 30)).millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'app_logs':
            '[{"timestamp":$historyTime,"level":1,"platform":0,"tag":"History",'
                '"message":"should be discarded","error":null,"stackTrace":null}]',
      });
      logger = LoggerService()..resetForTesting();

      // 触发加载（未完成）→ 立刻 clear
      logger.logs; // 触发 _ensureLoaded
      logger.clear();
      await logger.ensureLoadedForTest();

      expect(logger.logs, isEmpty,
          reason: '加载在 flight 时清空，完成的历史加载不得回填');
    });

    test('正常路径：加载完成后新日志直接入队', () async {
      logger.info('Normal', 'first');
      await logger.ensureLoadedForTest();
      logger.info('Normal', 'second');

      final all = logger.logs;
      expect(all.length, 2);
      expect(all.first.message, 'first');
      expect(all.last.message, 'second');
    });
  });

  group('LOG-05：中央脱敏层（LogSanitizer）', () {
    test('URL 内嵌凭据脱敏', () {
      expect(
        LogSanitizer.sanitize('connect https://user:secret123@dav.example.com/failed'),
        'connect https://***@dav.example.com/failed',
      );
    });

    test('键值对凭据脱敏（k=v 与 k:v 两种形态）', () {
      expect(
        LogSanitizer.sanitize('登录失败 password=hunter2'),
        '登录失败 password=***',
      );
      expect(
        LogSanitizer.sanitize('config: apiKey: sk-abc123, retry'),
        'config: apiKey: ***, retry',
      );
      expect(
        LogSanitizer.sanitize('supabase anonKey=A1b2C3d4E5 endpoint ok'),
        'supabase anonKey=*** endpoint ok',
      );
    });

    test('审计：后端配置真实字段名（s3SecretKey/s3AccessKey/webdavPassword/'
        'supabaseAnonKey/supabasePassword）也脱敏', () {
      // CloudServiceConfig.toJson 的真实键名：由于 \b 词边界不切分
      // s3SecretKey 内的 secretKey，旧词表对这些键完全失效。
      expect(
        LogSanitizer.sanitize(
            'cfg {"s3SecretKey":"AKIAxxxx","s3AccessKey":"AKIAyyyy"}'),
        'cfg {"s3SecretKey":"***","s3AccessKey":"***"}',
      );
      expect(
        LogSanitizer.sanitize('webdavPassword=hunter2 supabaseAnonKey=anon-x'),
        'webdavPassword=*** supabaseAnonKey=***',
      );
      expect(
        LogSanitizer.sanitize('{"supabasePassword":"pw"}'),
        '{"supabasePassword":"***"}',
      );
    });

    test('JSON 字段凭据脱敏', () {
      expect(
        LogSanitizer.sanitize('cfg {"password":"hunter2","url":"https://x"}'),
        'cfg {"password":"***","url":"https://x"}',
      );
    });

    test('Bearer / Basic 认证头脱敏', () {
      expect(
        LogSanitizer.sanitize('header Bearer eyJhbGciOiJIUzI1NiJ9.payload'),
        'header Bearer ***',
      );
      expect(
        LogSanitizer.sanitize('auth Basic dXNlcjpwYXNz'),
        'auth Basic ***',
      );
    });

    test('大小写不敏感 + 多处同时脱敏', () {
      expect(
        LogSanitizer.sanitize('PASSWORD=abc TOKEN=xyz'),
        'PASSWORD=*** TOKEN=***',
      );
    });

    test('非敏感内容不受影响（指纹哈希/账本名保留）', () {
      const keep = 'sha256=9f86d081884c7d65 full ledger myWallet synced';
      expect(LogSanitizer.sanitize(keep), keep);
    });

    test('幂等：已脱敏文本再过一遍不变', () {
      const once = '登录失败 password=***';
      expect(LogSanitizer.sanitize(once), once);
    });

    test('日志入口统一过脱敏层（message 与 error）', () async {
      logger.error(
        'Sync',
        '连接失败 endpoint https://admin:pw@webdav.x.com/',
        Exception('Authorization: Bearer leaked-token-value'),
      );
      await logger.ensureLoadedForTest();

      final entry = logger.logs.single;
      expect(entry.message, '连接失败 endpoint https://***@webdav.x.com/');
      // authorization 键值对与 Bearer 头任一模式命中都算脱敏成功——
      // 断言只要求泄漏值不出现、脱敏标记出现
      final errText = entry.error.toString();
      expect(errText.contains('leaked-token-value'), isFalse,
          reason: 'token 值不得出现在日志中');
      expect(errText.contains('***'), isTrue);
    });
  });
}
