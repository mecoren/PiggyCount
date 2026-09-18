/// E3 回归测试:`DataImportService.importTransactions` 在 ImportTransaction
/// 未提供 syncId 时,必须主动生成 UUID 写入,而不是把 null 透传到仓储层。
///
/// 背景:DataImportService 是上层服务,不应依赖仓储实现细节来保证 syncId。
/// 若 syncId 漏生成,ChangeTracker 会在登记 local_changes 时静默跳过该笔
/// (local_repository.dart `if (tx.syncId == null) continue;`),导致该笔
/// 永远不会被推送到云端,且 SyncEngine 没有 transaction backfill 兜底。
library;
import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late DataImportService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = DataImportService();
  });

  tearDown(() async => db.close());

  Future<List<Transaction>> allTx() =>
      (db.select(db.transactions)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  test('导入未提供 syncId 时:每笔交易必须自动生成非空 syncId', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    final result = await service.importTransactions(
      repo,
      1,
      [
        ImportTransaction(
            type: 'expense', amount: 100, happenedAt: DateTime(2026, 7, 1)),
        ImportTransaction(
            type: 'income', amount: 50, happenedAt: DateTime(2026, 7, 2)),
      ],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
    );
    expect(result.inserted, 2);

    final txs = await allTx();
    expect(txs.length, 2);
    expect(txs[0].syncId, isNotNull,
        reason: 'DataImportService 必须为无 syncId 的导入交易生成 UUID');
    expect(txs[0].syncId, isNotEmpty);
    expect(txs[1].syncId, isNotNull);
    expect(txs[1].syncId, isNotEmpty);
    // 两笔交易的 syncId 必须互不相同
    expect(txs[0].syncId != txs[1].syncId, isTrue,
        reason: '每笔交易的 syncId 必须独立生成,不能重复');
  });

  test('导入显式提供 syncId 时:必须原样保留,不被覆盖', () async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

    const presetSyncId = 'preset-uuid-from-csv-1234';
    await service.importTransactions(
      repo,
      1,
      [
        ImportTransaction(
          type: 'expense',
          amount: 100,
          happenedAt: DateTime(2026, 7, 1),
          syncId: presetSyncId,
        ),
      ],
      accountNameToId: {},
      categoryCache: {},
      tagNameToId: {},
    );

    final txs = await allTx();
    expect(txs[0].syncId, presetSyncId,
        reason: '显式提供的 syncId 必须保留,不得被覆盖');
  });
}
