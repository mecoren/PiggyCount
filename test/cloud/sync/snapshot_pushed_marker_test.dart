// ChangeTracker.markSnapshotPushed 单元测试（审计 F2 修复）。
//
// 契约：快照上传成功后，该账本作用域（ledger_id = 目标账本）+ user-global
// （ledger_id = 0）的全部未推送行被标记 pushedAt；
// 其他账本的行不受影响；已推送行保持原 pushedAt 不被覆盖。
//
// 背景：此前 Path A（S3/WebDAV 快照同步）永不 markPushed，未推送行只增
// 不清，导致 local_changes 无限膨胀 + _localChangeEvidence「仅未推送行
// 存在才可信」门禁失真。

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';

Future<int> _insertChange(
  PiggyDatabase db, {
  required String entitySyncId,
  required int ledgerId,
  String entityType = 'transaction',
  String action = 'create',
}) {
  return db.into(db.localChanges).insert(
        LocalChangesCompanion.insert(
          entityType: entityType,
          entityId: 1,
          entitySyncId: entitySyncId,
          ledgerId: ledgerId,
          action: action,
        ),
      );
}

Future<List<LocalChange>> _unpushed(PiggyDatabase db) {
  return (db.select(db.localChanges)
        ..where((c) => c.pushedAt.isNull()))
      .get();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // LoggerService 惰性读取 SharedPreferences（插件通道），测试环境需 mock
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('标记目标账本 + user-global(0) 的未推送行，其他账本不动', () async {
    await _insertChange(db, entitySyncId: 'tx-l1', ledgerId: 1);
    await _insertChange(db, entitySyncId: 'tx-l2', ledgerId: 2);
    await _insertChange(db, entitySyncId: 'acc-global',
        ledgerId: 0, entityType: 'account');

    final marked = await tracker.markSnapshotPushed(ledgerId: 1);
    expect(marked, 2, reason: 'ledger=1 与 ledger=0 各 1 条');

    final remaining = await _unpushed(db);
    expect(remaining.length, 1);
    expect(remaining.single.entitySyncId, 'tx-l2');
    expect(remaining.single.ledgerId, 2);
  });

  test('已推送行不被二次覆盖，返回计数只含新标记行', () async {
    await _insertChange(db, entitySyncId: 'tx-a', ledgerId: 1);

    expect(await tracker.markSnapshotPushed(ledgerId: 1), 1);
    // 第二次调用：没有未推送行可标，幂等返回 0
    expect(await tracker.markSnapshotPushed(ledgerId: 1), 0);
  });

  test('与 recordLedgerChange 协作：上传后新编辑重新产生未推送行', () async {
    await _insertChange(db, entitySyncId: 'tx-old', ledgerId: 1);
    await tracker.markSnapshotPushed(ledgerId: 1);
    expect(await _unpushed(db), isEmpty);

    // 上传后用户再次编辑 → 新的未推送行正常入队（部分唯一索引不阻挡：
    // 已推送行退出索引）
    await tracker.recordLedgerChange(
      entityType: 'transaction',
      entityId: 9,
      entitySyncId: 'tx-new-edit',
      ledgerId: 1,
      action: 'update',
    );
    final unpushed = await _unpushed(db);
    expect(unpushed.length, 1);
    expect(unpushed.single.entitySyncId, 'tx-new-edit');
  });

  test('同实体同 action 未推送重复插入仍被索引去重（既有 F2 行为不回归）', () async {
    await _insertChange(db, entitySyncId: 'tx-dup', ledgerId: 1);
    // 同 (entity_type, entity_sync_id, action) 且未推送 → 撞 v35 部分唯一
    // 索引 idx_local_changes_unpushed_dedup，直接 insert 抛约束错误
    await expectLater(
      _insertChange(db, entitySyncId: 'tx-dup', ledgerId: 1),
      throwsA(anything),
    );
  });
}
