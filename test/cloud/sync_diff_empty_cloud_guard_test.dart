/// M1：computeDiff 空快照守卫。
///
/// 云端 items 为空（文件缺失/损坏/被清空）无法区分「云端合法清空」与
/// 「快照异常」，必须拒绝 diff（返回 null），否则全部本地交易被误标
/// deleted，一键应用即全量误删。
library;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  Future<void> addLocalTx(int ledgerId, String syncId) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 10,
          syncId: drift.Value(syncId)));

  test('M1：云端空列表 + 本地非空 → 返回 null，不生成全量 deleted', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await addLocalTx(1, 'tx-1');
    await addLocalTx(1, 'tx-2');

    final preview = await service.computeDiff(
        repo: repo, ledgerId: 1, cloudTransactions: []);

    expect(preview, isNull,
        reason: 'M1：云端空快照无法区分合法清空与异常，必须拒绝 diff 防误删');
  });

  test('M1：云端与本地均为空 → 正常返回空 preview', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final preview = await service.computeDiff(
        repo: repo, ledgerId: 1, cloudTransactions: []);

    expect(preview, isNotNull);
    expect(preview!.changes, isEmpty);
  });
}
