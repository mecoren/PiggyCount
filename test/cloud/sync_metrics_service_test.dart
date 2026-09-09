import 'package:drift/drift.dart' as drift show InsertMode, QueryExecutor;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_metrics_service.dart';
import 'package:piggycount/cloud/sync_service.dart' show CloudConflictException;
import 'package:piggycount/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late SyncMetricsService metrics;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    metrics = SyncMetricsService(db);
  });

  tearDown(() async {
    await db.close();
  });

  SyncOpRecord rec({
    required SyncOpOutcome outcome,
    SyncOpScenario scenario = SyncOpScenario.snapshotUpload,
    String backend = 's3',
    SyncErrorClass? errorClass,
    int? ledgerId = 1,
  }) =>
      SyncOpRecord(
        backend: backend,
        scenario: scenario,
        outcome: outcome,
        errorClass: errorClass,
        ledgerId: ledgerId,
      );

  group('SyncOpScenario / Outcome / ErrorClass 标签稳定', () {
    test('label 是落库字符串口径，变更即破坏历史数据可读性', () {
      expect(SyncOpScenario.snapshotUpload.label, 'snapshot_upload');
      expect(SyncOpScenario.attachmentFill.label, 'attachment_fill');
      expect(SyncOpOutcome.softFail.label, 'soft_fail');
      expect(SyncOpOutcome.conflict.label, 'conflict');
      expect(SyncErrorClass.networkTimeout.label, 'network_timeout');
    });
  });

  group('record + summarize', () {
    test('四态计数正确,成功率口径 = success/(success+failed+soft_fail)', () async {
      await metrics.record(rec(outcome: SyncOpOutcome.success));
      await metrics.record(rec(outcome: SyncOpOutcome.success, backend: 'webdav'));
      await metrics.record(rec(outcome: SyncOpOutcome.failed,
          errorClass: SyncErrorClass.networkTimeout));
      await metrics.record(rec(outcome: SyncOpOutcome.softFail,
          errorClass: SyncErrorClass.dataCorruption));
      await metrics.record(rec(outcome: SyncOpOutcome.conflict,
          errorClass: SyncErrorClass.precondition));

      final all = await metrics.summarize();
      expect(all.success, 2);
      expect(all.failed, 1);
      expect(all.softFail, 1);
      // conflict 计数但不入分母
      expect(all.conflict, 1);
      expect(all.totalMeasured, 4);
      expect(all.successRate, closeTo(2 / 4, 0.0001));
    });

    test('窗口为空时 successRate 为 null(而非 0%)', () async {
      final s = await metrics.summarize();
      expect(s.successRate, isNull);
      expect(s.totalMeasured, 0);
    });

    test('按后端过滤', () async {
      await metrics.record(rec(outcome: SyncOpOutcome.success, backend: 's3'));
      await metrics.record(
          rec(outcome: SyncOpOutcome.failed, backend: 'webdav'));
      final s3 = await metrics.summarize(backend: 's3');
      expect(s3.success, 1);
      expect(s3.failed, 0);
      final webdav = await metrics.summarize(backend: 'webdav');
      expect(webdav.failed, 1);
      expect(webdav.success, 0);
    });

    test('窗口过滤:只统计窗口内行', () async {
      await metrics.record(rec(outcome: SyncOpOutcome.success));
      // 手动插入一条 40 天前的旧行(绕过 ts 默认值)
      await db.customStatement(
          "INSERT INTO sync_op_log (ts, backend, scenario, outcome, attempts) "
          "VALUES (${DateTime.now().subtract(const Duration(days: 40)).millisecondsSinceEpoch ~/ 1000}, "
          "'s3', 'snapshot_upload', 'success', 1)");
      final month = await metrics.summarize(
          window: const Duration(days: 30));
      expect(month.success, 1);
      // 大窗口(60 天)包含旧行
      final twoMonths = await metrics.summarize(
          window: const Duration(days: 60));
      expect(twoMonths.success, 2);
    });
  });

  group('cleanupExpired + exportJson', () {
    test('清理窗口外行,保留窗口内行', () async {
      await metrics.record(rec(outcome: SyncOpOutcome.success));
      await db.customStatement(
          "INSERT INTO sync_op_log (ts, backend, scenario, outcome, attempts) "
          "VALUES (${DateTime.now().subtract(const Duration(days: 40)).millisecondsSinceEpoch ~/ 1000}, "
          "'s3', 'snapshot_upload', 'failed', 1)");
      final removed = await metrics.cleanupExpired();
      expect(removed, 1);
      final after = await metrics.summarize(
          window: const Duration(days: 60));
      expect(after.success, 1);
      expect(after.failed, 0);
    });

    test('导出为结构化映射(仅结构化字段,不含用户内容)', () async {
      await metrics.record(SyncOpRecord(
        backend: 'webdav',
        scenario: SyncOpScenario.cloudBackup,
        outcome: SyncOpOutcome.failed,
        errorClass: SyncErrorClass.auth,
        ledgerId: null,
        attempts: 3,
        duration: const Duration(seconds: 12),
      ));
      final rows = await metrics.exportJson();
      expect(rows.length, 1);
      final row = rows.first;
      expect(row['backend'], 'webdav');
      expect(row['scenario'], 'cloud_backup');
      expect(row['outcome'], 'failed');
      expect(row['errorClass'], 'auth');
      expect(row['attempts'], 3);
      expect(row['durationMs'], 12000);
      // 不含用户内容字段
      expect(row.containsKey('message'), isFalse);
      expect(row.containsKey('stackTrace'), isFalse);
    });
  });

  group('classifyError', () {
    test('条件写/冲突 → precondition', () {
      expect(
          SyncMetricsService.classifyError(
              fcs.CloudPreconditionFailedException('ledger_x.json')),
          SyncErrorClass.precondition);
      expect(
          SyncMetricsService.classifyError(
              CloudConflictException(direction: 'cloudNewer')),
          SyncErrorClass.precondition);
    });

    test('认证异常 → auth(优先于其他特征)', () {
      expect(SyncMetricsService.classifyError(fcs.CloudAuthException('401')),
          SyncErrorClass.auth);
    });

    test('超时措辞(中英) → networkTimeout', () {
      expect(SyncMetricsService.classifyError(
              fcs.CloudStorageException('PutObject timed out after 30s')),
          SyncErrorClass.networkTimeout);
      expect(SyncMetricsService.classifyError(
              fcs.CloudStorageException('WebDAV read 超时（60s）')),
          SyncErrorClass.networkTimeout);
    });

    test('网关特征 → gateway', () {
      expect(
          SyncMetricsService.classifyError(
              fcs.CloudStorageException('not implemented: If-Match')),
          SyncErrorClass.gateway);
      expect(
          SyncMetricsService.classifyError(
              fcs.CloudStorageException('Failed: HTTP 503')),
          SyncErrorClass.gateway);
    });

    test('数据损坏特征 → dataCorruption', () {
      expect(
          SyncMetricsService.classifyError(
              fcs.CloudStorageException('云端数据完整性校验失败（指纹不匹配）')),
          SyncErrorClass.dataCorruption);
    });

    test('裸存储异常无特征 → gateway;null → unknown', () {
      expect(SyncMetricsService.classifyError(fcs.CloudStorageException('x')),
          SyncErrorClass.gateway);
      expect(SyncMetricsService.classifyError(null),
          SyncErrorClass.unknown);
    });
  });

  group('v43 迁移可达性(onCreate 内存库)', () {
    test('stale_remote_slots 表可用:插入幂等 + 删除', () async {
      await db.into(db.staleRemoteSlots)
          .insert(StaleRemoteSlotsCompanion.insert(path: 'ledger_a.json'));
      // 主键冲突时 insertOrIgnore 幂等
      await db.into(db.staleRemoteSlots).insert(
          StaleRemoteSlotsCompanion.insert(path: 'ledger_a.json'),
          mode: drift.InsertMode.insertOrIgnore);
      final rows = await db.select(db.staleRemoteSlots).get();
      expect(rows.length, 1);
      await (db.delete(db.staleRemoteSlots)
            ..where((s) => s.path.equals('ledger_a.json')))
          .go();
      expect((await db.select(db.staleRemoteSlots).get()), isEmpty);
    });

    test('attempts 非法值(0/负)被归一为 1', () async {
      await metrics.record(SyncOpRecord(
        backend: 's3',
        scenario: SyncOpScenario.attachmentFill,
        outcome: SyncOpOutcome.success,
        attempts: 0,
      ));
      final rows = await db.select(db.syncOpLog).get();
      expect(rows.single.attempts, 1);
    });
  });
}
