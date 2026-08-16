/// Task 1（/prd/cloud_backup/execution_plan.md）：
/// 公共账本整体恢复函数 restoreLedgerFromJson 的行为契约。
///
/// 抽取自 TransactionsSyncManager.downloadAndRestoreToCurrentLedger，
/// 供云同步恢复与云端备份恢复共用同一语义：
/// 1. 快照整体覆盖（清空后导入，事务原子）
/// 2. P1-1 守卫：空快照拒绝覆盖非空本地账本
library;

import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> addLedger(String name) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: name));

  Future<void> addTx(int ledgerId, {double amount = 10}) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId, type: 'expense', amount: amount));

  test('快照整体覆盖：清空本地后导入快照内容', () async {
    final id = await addLedger('Main');
    await addTx(id, amount: 10);
    final snapshot = await exportTransactionsJson(db, id);

    // 快照后再新增一笔，恢复应回到快照时点
    await addTx(id, amount: 99);
    var rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 2);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);
    rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1);
    expect(rows.first.amount, 10);
  });

  test('P1-1 守卫：空快照拒绝覆盖非空本地账本，返回 null', () async {
    final id = await addLedger('Main');
    await addTx(id);
    // 手工构造空交易快照（复用 export 再清空 items）
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    (map['items'] as List).clear();
    final emptySnapshot = jsonEncode(map);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: emptySnapshot);
    expect(result, isNull);
    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1); // 本地数据未被清空
  });
}

/// 测试辅助：解码 JSON 为 Map（避免每个测试文件重复写）
Map<String, dynamic> jsonDecodeMap(String s) =>
    (jsonDecode(s) as Map).cast<String, dynamic>();
