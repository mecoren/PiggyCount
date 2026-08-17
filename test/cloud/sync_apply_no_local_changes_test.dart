/// M3：applySyncChanges（云→本地合并，Path A）不得写入 local_changes。
///
/// 云端拉下来的数据如果反向登记为「本地编辑」，会污染推送队列：
/// Cloud 引擎把幻影变更推回服务端 / Path A 触发无意义的重复上传。
library;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    // 带 ChangeTracker 复现生产配置：没有抑制机制时合并路径会写 local_changes
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  ImportTransaction cloudTx(String syncId, {double amount = 20}) =>
      ImportTransaction(
        type: 'expense',
        amount: amount,
        happenedAt: DateTime(2026, 8, 1),
        syncId: syncId,
      );

  test('M3：added/modified/deleted 合并后 local_changes 为空', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 本地一笔（供 modified + deleted 用例）
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
        ledgerId: 1, type: 'expense', amount: 10,
        syncId: const drift.Value('tx-mod')));
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
        ledgerId: 1, type: 'expense', amount: 30,
        syncId: const drift.Value('tx-del')));
    final localRows = await db.select(db.transactions).get();
    final modRow = localRows.firstWhere((t) => t.syncId == 'tx-mod');
    final delRow = localRows.firstWhere((t) => t.syncId == 'tx-del');

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: [
        SyncChange(
            type: SyncChangeType.added,
            cloudTransaction: cloudTx('tx-add')),
        SyncChange(
            type: SyncChangeType.modified,
            cloudTransaction: cloudTx('tx-mod', amount: 99)),
        SyncChange(
            type: SyncChangeType.deleted,
            localTransaction: delRow == modRow ? modRow : delRow),
      ],
      importData: const ImportData(
        accounts: [ImportAccount(name: '云端账户', syncId: 'acc-1')],
        categories: [ImportCategory(name: '餐饮', kind: 'expense')],
      ),
    );

    expect(result.totalCount, 3);
    final changes = await db.select(db.localChanges).get();
    expect(changes, isEmpty,
        reason: 'M3：云→本地合并不得写 local_changes（含交易与元数据路径），'
            '防污染 Cloud 引擎推送队列');
  });
}
