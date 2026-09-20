/// M17（B9）：日志队列的三处收口。
///
/// 1. release 下 debug 级不入队（`levelAccepted`）——抽成静态口才测得到，
///    单测里 `kDebugMode` 恒为 true；
/// 2. `toJson` 对 error/stackTrace 截断（整份队列每 2s jsonEncode 落盘一次，
///    一条全栈 2~20KB 就能把常驻的 prefs 字符串顶到 MB 级）；
/// 3. `logs` getter 返回缓存快照（此前每次 build 现场复制 2000 条）。
library;

import 'dart:convert';

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

  group('release 级别门控', () {
    test('debugMode=false 只挡 debug，info/warn/error 全放行', () {
      expect(LoggerService.levelAccepted(LogLevel.debug, debugMode: false),
          isFalse);
      for (final level in [LogLevel.info, LogLevel.warning, LogLevel.error]) {
        expect(LoggerService.levelAccepted(level, debugMode: false), isTrue,
            reason: '$level 是线上排障的主体，不能挡');
      }
    });

    test('debugMode=true 全放行（开发包仍能看到 debug）', () {
      for (final level in LogLevel.values) {
        expect(LoggerService.levelAccepted(level, debugMode: true), isTrue);
      }
    });

    test('单测环境（debugMode=true）下 debug 仍入队，门控没误伤', () async {
      logger.debug('Gate', 'still visible in debug builds');
      await logger.ensureLoadedForTest();
      expect(logger.logs.map((e) => e.message),
          contains('still visible in debug builds'));
    });
  });

  group('落盘截断', () {
    test('超长 stackTrace/error 截断并标注原长，短文本原样保留', () {
      final frame = '#0 a (x.dart:1:2)\n';
      final entry = LogEntry(
        timestamp: DateTime(2026, 9, 19),
        level: LogLevel.error,
        platform: LogPlatform.flutter,
        tag: 'Clip',
        message: '炸了',
        error: 'E' * 5000,
        stackTrace: StackTrace.fromString(frame * 400),
      );
      final json = entry.toJson();

      final trace = json['stackTrace'] as String;
      final err = json['error'] as String;
      expect(trace.length, lessThan(2200), reason: '落盘串必须被钳住');
      expect(trace, endsWith('(已截断，原长 ${frame.length * 400} 字符)'));
      expect(err.length, lessThan(1100));
      expect(err, startsWith('E' * 1000));
      expect(entry.toJson()['message'], '炸了', reason: 'message 不截断');

      // 截断后仍是可反序列化的合法 JSON（丢了这个就是日志中心打不开）
      final roundTrip = LogEntry.fromJson(jsonDecode(jsonEncode({
        'timestamp': entry.timestamp.millisecondsSinceEpoch,
        'level': 3,
        'platform': 0,
        'tag': 'Clip',
        'message': '炸了',
        'error': err,
        'stackTrace': trace
      })) as Map<String, dynamic>);
      expect(roundTrip.stackTrace.toString(), trace);
    });

    test('短 error/无堆栈不被改写', () {
      final json = LogEntry(
        timestamp: DateTime(2026, 9, 19),
        level: LogLevel.warning,
        platform: LogPlatform.flutter,
        tag: 'Clip',
        message: 'm',
        error: 'boom',
      ).toJson();
      expect(json['error'], 'boom');
      expect(json['stackTrace'], isNull);
    });
  });

  group('logs 快照', () {
    test('没有新日志时返回同一实例（build 期不再每次复制 2000 条）', () async {
      logger.info('Snap', 'a');
      await logger.ensureLoadedForTest();
      expect(identical(logger.logs, logger.logs), isTrue);
    });

    test('入队 / 清空 / 加载并入都会让快照失效', () async {
      final historyTime = DateTime.now()
          .subtract(const Duration(minutes: 5))
          .millisecondsSinceEpoch;
      SharedPreferences.setMockInitialValues({
        'app_logs':
            '[{"timestamp":$historyTime,"level":1,"platform":0,"tag":"History",'
                '"message":"h","error":null,"stackTrace":null}]',
      });
      logger = LoggerService()..resetForTesting();

      final before = logger.logs; // 触发加载
      expect(before, isEmpty);
      await logger.ensureLoadedForTest();
      final afterLoad = logger.logs;
      expect(afterLoad.map((e) => e.message), contains('h'),
          reason: '加载完的快照要刷新');

      logger.info('Snap', 'b');
      expect(logger.logs.length, afterLoad.length + 1);
      final withB = logger.logs;
      expect(identical(logger.logs, withB), isTrue, reason: '只读不该换掉快照');

      logger.clear();
      expect(logger.logs, isEmpty);
    });

    test('快照不可变：外部改不动队列', () async {
      logger.info('Snap', 'x');
      await logger.ensureLoadedForTest();
      expect(() => logger.logs.clear(), throwsUnsupportedError);
    });
  });
}
