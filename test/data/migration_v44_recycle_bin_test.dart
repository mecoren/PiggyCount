// v44 迁移测试：deleted_transactions（F1 回收站）。
//
// 验证两条建表路径：
// 1. onUpgrade —— v43 存量库（表尚不存在）压回 user_version=43 后重新打开，
//    触发 from=43 → to=44 分支，表可读写且 idx_deleted_transactions_ledger 存在；
// 2. onCreate —— 全新装库同样具备表与索引（新装库不会跑任何 onUpgrade 分支，
//    所以索引必须在 onCreate 里也建一份，这是本仓既有约定）。
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Future<void> expectTableUsable(PiggyDatabase db) async {
    final now = DateTime.utc(2026, 9, 19, 12);
    await db.into(db.deletedTransactions).insert(DeletedTransactionsCompanion(
          txId: const d.Value(101),
          ledgerId: const d.Value(7),
          syncId: const d.Value('tx-101'),
          happenedAt: d.Value(now),
          deletedAt: d.Value(now),
          payload: const d.Value('{"id":101}'),
        ));
    final rows = await db.select(db.deletedTransactions).get();
    expect(rows.single.txId, 101);
    expect(rows.single.ledgerId, 7);
    expect(rows.single.payload, '{"id":101}');

    final idx = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
            "AND name='idx_deleted_transactions_ledger'")
        .get();
    expect(idx, isNotEmpty, reason: '回收站按账本清理走 ledger_id 过滤，缺索引就是全表扫');
  }

  test('v44 onUpgrade: v43 存量库升级后 deleted_transactions 可用 + 索引存在', () async {
    final dir = await Directory.systemTemp.createTemp('pgy_v44_test');
    final file = File('${dir.path}/test.db');

    // 1. onCreate 建全量 schema（当前版本），随后压回 v43
    final dbOnCreate = PiggyDatabase.forTesting(NativeDatabase(file));
    await dbOnCreate.customStatement('SELECT 1');
    await dbOnCreate.customStatement('PRAGMA user_version = 43;');
    await dbOnCreate.close();

    // 2. 重新打开 → onUpgrade(from=43) 跑 v44 分支
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    await expectTableUsable(db);
    final version = await db.customSelect('PRAGMA user_version').getSingle();
    expect(version.read<int>('user_version'), 44);
  });

  test('v44 onCreate: 全新装库直接具备表与索引（新装路径）', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    await expectTableUsable(db);
  });
}
