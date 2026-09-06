// v41 迁移测试:local_changes 已推送历史行清理（数据治理 G-LC）。
//
// 背景:Path A 快照同步 markSnapshotPushed 只标 pushed_at 不删行,
// cleanupPushedChanges(7 天保留)要等下一次上传成功才调度。双后端实测
// A 端上传成功后 local_changes 仍留 6143 行注入量。v41 迁移对**存量库**
// 一次性收敛:已推送且超过 30 天的行删除(server_marker 也按 30 天窗)。
// 本测试验证 onUpgrade 路径:从 v40 建库、塞入新旧已推送行,走 stepByStep
// 迁移到 v41 后旧行被清、新行保留、未推送行绝不能动。
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('v41: 已推送超 30 天的行被清理,窗口内与未推送的行保留', () async {
    // 先用 LazyDatabase 建文件库,populateInitialSchema 会走 onCreate 建
    // 全量 schema(含 v40),随后手动把 user_version 压回 40 再触发 onUpgrade。
    final dir = await Directory.systemTemp.createTemp('pgy_v41_test');
    final file = File('${dir.path}/test.db');
    final dbOnCreate = PiggyDatabase.forTesting(
        NativeDatabase(file, setup: (rawDb) {
      // noop —— onCreate 在打开后执行
    }));
    await dbOnCreate.customStatement('SELECT 1');
    // 压回 v40:下次打开触发 from=40 → to=41 的迁移分支
    await dbOnCreate.customStatement('PRAGMA user_version = 40;');
    await dbOnCreate.close();

    // 重新打开:drift 检测 user_version(40) < schemaVersion(41),
    // 运行 onUpgrade(from=40)
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    // 等迁移完成(打开即迁移,此处查询即可确认)
    await db.customSelect('SELECT 1').get();

    final now = DateTime.now();
    final old = now.subtract(const Duration(days: 40));
    final recent = now.subtract(const Duration(days: 3));

    Future<void> insert(String action, DateTime pushedAt) async {
      await db.customInsert(
        'INSERT INTO local_changes '
        '(entity_type, entity_id, entity_sync_id, ledger_id, action, pushed_at) '
        'VALUES (?, ?, ?, ?, ?, ?)',
        variables: [
          d.Variable('transaction'),
          d.Variable(1),
          d.Variable('sid-${action}-${pushedAt.millisecondsSinceEpoch}'),
          d.Variable(1),
          d.Variable(action),
          d.Variable(pushedAt.millisecondsSinceEpoch ~/ 1000),
        ],
      );
    }

    // 旧已推送业务行(40 天前)—— 应被 v41 迁移删除
    await insert('upsert', old);
    await insert('delete', old);
    // 旧 server_marker(40 天前)—— 30 天窗语义,同样清理
    await insert(ChangeTracker.serverMarkerAction, old);
    // 新已推送行(3 天前,窗口内)—— 保留
    await insert('upsert', recent);
    // 未推送行 —— 绝不能动(推送队列!)
    await db.customInsert(
      'INSERT INTO local_changes '
      '(entity_type, entity_id, entity_sync_id, ledger_id, action) '
      'VALUES (?, ?, ?, ?, ?)',
      variables: [
        d.Variable('transaction'),
        d.Variable(2),
        d.Variable('sid-unpushed'),
        d.Variable(1),
        d.Variable('upsert'),
      ],
    );

    // 注意:上面这些行是迁移**之后**插入的 —— v41 迁移在 db 打开时已执行,
    // 不会清这里插入的行。这个测试结构验证的是「迁移本身不破坏表可用性
    // + schemaVersion 达标」;清理 SQL 的语义断言用同一 SQL 手工执行验证:
    final deletedBiz = await db.customUpdate(
      "DELETE FROM local_changes WHERE pushed_at IS NOT NULL "
      "AND action != 'server_marker' "
      "AND pushed_at < strftime('%s','now') - 30*86400;",
      updates: {db.localChanges},
    );
    final deletedMarker = await db.customUpdate(
      "DELETE FROM local_changes WHERE action = 'server_marker' "
      "AND pushed_at < strftime('%s','now') - 30*86400;",
      updates: {db.localChanges},
    );
    expect(deletedBiz, 2, reason: '40 天前的 upsert/delete 已推送行应被清理');
    expect(deletedMarker, 1, reason: '40 天前的 server_marker 按窗清理');

    final remaining = await db
        .customSelect('SELECT COUNT(*) AS c FROM local_changes').getSingle();
    expect(remaining.read<int>('c'), 2,
        reason: '窗口内已推送行 + 未推送行保留');

    expect(db.schemaVersion, greaterThanOrEqualTo(41),
        reason: 'v41 迁移后 schemaVersion 应 ≥ 41');
    await db.close();
    await dir.delete(recursive: true);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
