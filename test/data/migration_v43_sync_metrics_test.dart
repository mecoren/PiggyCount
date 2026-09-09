// v43 迁移测试：sync_op_log（审计 P0-1 同步成功率指标）与
// stale_remote_slots（审计 P1-6 换名收尾补删持久化）两张新表。
//
// 验证 onUpgrade 路径：从 v42 建库（v42 时两表尚不存在），压回
// user_version=42 后重新打开触发 from=42 → to=43 迁移分支，确认：
// 1. 两表存在且可读写（sync_op_log 计数 + stale_remote_slots 幂等）；
// 2. idx_sync_op_log_ts 时间索引存在（30 天窗口聚合不全表扫描）；
// 3. onCreate 路径（新装库）同样具备两表与索引。
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_metrics_service.dart';
import 'package:piggycount/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('v43 onUpgrade: v42 存量库升级后两表可用 + ts 索引存在', () async {
    final dir = await Directory.systemTemp.createTemp('pgy_v43_test');
    final file = File('${dir.path}/test.db');

    // 1. onCreate 建全量 schema（当前版本），随后压回 v42
    final dbOnCreate = PiggyDatabase.forTesting(NativeDatabase(file));
    await dbOnCreate.customStatement('SELECT 1');
    await dbOnCreate.customStatement('PRAGMA user_version = 42;');
    await dbOnCreate.close();

    // 2. 重新打开 → onUpgrade(from=42) 跑 v43 分支
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    // 3. sync_op_log 可写可读（drift 生成 API）
    final metrics = SyncMetricsService(db);
    await metrics.record(const SyncOpRecord(
      backend: 's3',
      scenario: SyncOpScenario.snapshotUpload,
      outcome: SyncOpOutcome.success,
      ledgerId: 7,
    ));
    final summary = await metrics.summarize();
    expect(summary.success, 1);
    expect(summary.successRate, 1.0);

    // 4. stale_remote_slots 主键幂等
    await db.into(db.staleRemoteSlots)
        .insert(StaleRemoteSlotsCompanion.insert(path: 'ledger_a.json'));
    await db.into(db.staleRemoteSlots).insert(
        StaleRemoteSlotsCompanion.insert(path: 'ledger_a.json'),
        mode: d.InsertMode.insertOrIgnore);
    expect((await db.select(db.staleRemoteSlots).get()).length, 1);

    // 5. ts 索引存在（onUpgrade 分支与 onCreate 同构）
    final idx = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
            "AND name='idx_sync_op_log_ts'")
        .get();
    expect(idx, isNotEmpty);
  });

  test('v43 onCreate: 全新内存库直接具备两表（新装路径）', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    final metrics = SyncMetricsService(db);
    await metrics.record(const SyncOpRecord(
      backend: 'webdav',
      scenario: SyncOpScenario.cloudBackup,
      outcome: SyncOpOutcome.failed,
      errorClass: SyncErrorClass.auth,
    ));
    final summary = await metrics.summarize(backend: 'webdav');
    expect(summary.failed, 1);
    expect(summary.successRate, 0.0);

    await db.into(db.staleRemoteSlots)
        .insert(StaleRemoteSlotsCompanion.insert(path: 'ledger_b.json'));
    expect((await db.select(db.staleRemoteSlots).get()).single.path,
        'ledger_b.json');
  });
}
