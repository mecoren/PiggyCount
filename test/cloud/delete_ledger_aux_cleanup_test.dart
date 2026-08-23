// 审计 S9：删除账本时同步辅助表（transaction_tags / transaction_attachments /
// sync_pull_errors / entity_change_watermarks）必须一并清理，不留孤儿行。
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('deleteLedger 清理 tags/attachments/pullErrors/watermarks 残留', () async {
    SharedPreferences.setMockInitialValues({});
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final ct = ChangeTracker(db);
    final repo = LocalRepository(db, changeTracker: ct);

    final ledgerId = await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const Value('L-del')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: 'C', kind: 'expense'));
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 9,
            happenedAt: Value(DateTime.parse('2026-05-01T00:00:00Z')),
            syncId: const Value('tx-del-1'),
          ),
        );
    await db.customStatement(
      "INSERT INTO transaction_attachments (transaction_id, file_name) "
      "VALUES (?, ?)",
      [txId, 'a.jpg'],
    );
    await db.into(db.transactionTags).insert(
        TransactionTagsCompanion.insert(transactionId: txId, tagId: 1));
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: ledgerId,
          amount: 100,
          syncId: const Value('budget-del-1'),
        ));

    // 水位行 + pull 错误行
    await db.into(db.entityChangeWatermarks).insert(
        EntityChangeWatermarksCompanion.insert(
            syncId: 'tx-del-1', watermark: 7));
    await db.into(db.entityChangeWatermarks).insert(
        EntityChangeWatermarksCompanion.insert(
            syncId: 'L-del', watermark: 8));
    await db.into(db.syncPullErrors).insert(SyncPullErrorsCompanion.insert(
      changeId: 99,
      ledgerExternalId: const Value('L-del'),
      entityType: 'transaction',
      entitySyncId: 'tx-del-1',
      action: 'upsert',
      rawChangeJson: '{}',
      errorClass: const Value('X'),
      errorMessage: const Value('boom'),
      firstSeenAt: DateTime.now(),
      lastAttemptAt: DateTime.now(),
    ));

    await repo.deleteLedger(ledgerId);

    expect(await (db.select(db.transactionTags)).get(), isEmpty,
        reason: 'S9：transaction_tags 孤儿行应清理');
    expect(await (db.select(db.transactionAttachments)).get(), isEmpty,
        reason: 'S9：transaction_attachments 孤儿行应清理');
    expect(await (db.select(db.budgets)).get(), isEmpty);
    expect(await (db.select(db.syncPullErrors)).get(), isEmpty,
        reason: 'S9：被删账本的 pull 错误悬挂应清理');
    expect(await (db.select(db.entityChangeWatermarks)).get(), isEmpty,
        reason: 'S9：被删实体水位行应清理');
  });
}
