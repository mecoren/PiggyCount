// LocalRepository 变更记录补全契约测试（审计 C1-C4 回归）。
//
// 锁死以下此前裸委托、漏记 local_changes 的写路径：
//   C1: addTagToTransaction / removeTagFromTransaction / updateTransactionTags
//       → 必须给父交易登记 transaction:update change（tx payload 序列化
//         携带 tags/tagSyncIds，漏记则「只改标签」的编辑永不传播）
//   C2: updateCategorySortOrders / updateTagSortOrders / updateAccountSortOrders
//       / updateAccountValuation → 必须登记对应实体的 update change
//   C3: createLedger → 就地生成 syncId + 登记 ledger:upsert；
//       updateLedgerName → 登记 ledger:update
//   C4: upsertCategory（新建分支）→ 登记 category:upsert；
//       batchInsertRecurringTransactions → 预填 syncId + 登记 recurring:create
//
// 用 in-memory Drift DB + 真实 ChangeTracker 跑端到端断言。

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
  });

  tearDown(() async {
    await db.close();
  });

  Future<int> createLedgerWithTx() async {
    final ledgerId = await repo.createLedger(name: 'L-${DateTime.now().microsecondsSinceEpoch}');
    await repo.insertTransactionsBatch([
      TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: 'expense',
        amount: 10,
      ),
    ]);
    return ledgerId;
  }

  group('C1: 标签关联写路径', () {
    test('addTagToTransaction 给父交易登记 update change', () async {
      final ledgerId = await createLedgerWithTx();
      final tx = (await repo.getTransactionsByLedger(ledgerId)).first;
      final tagId = await repo.createTag(name: 't-${tx.id}');

      // 清掉此前的 create change，只看标签操作产生的
      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.addTagToTransaction(transactionId: tx.id, tagId: tagId);

      final changes = await tracker.getUnpushedChangesForLedger(ledgerId);
      expect(
        changes.where((c) =>
            c.entityType == 'transaction' &&
            c.entityId == tx.id &&
            c.action == 'upsert'),
        isNotEmpty,
        reason: '只改标签必须给父交易登记 update，否则永不传播',
      );
    });

    test('updateTransactionTags 给父交易登记 update change', () async {
      final ledgerId = await createLedgerWithTx();
      final tx = (await repo.getTransactionsByLedger(ledgerId)).first;
      final tagA = await repo.createTag(name: 'a-${tx.id}');
      final tagB = await repo.createTag(name: 'b-${tx.id}');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.updateTransactionTags(
          transactionId: tx.id, tagIds: [tagA, tagB]);

      final changes = await tracker.getUnpushedChangesForLedger(ledgerId);
      expect(
        changes.where((c) =>
            c.entityType == 'transaction' &&
            c.entityId == tx.id &&
            c.action == 'upsert'),
        isNotEmpty,
      );
    });

    test('removeAllTagsFromTransaction 给父交易登记 update change', () async {
      final ledgerId = await createLedgerWithTx();
      final tx = (await repo.getTransactionsByLedger(ledgerId)).first;
      final tagId = await repo.createTag(name: 'r-${tx.id}');
      await repo.addTagToTransaction(transactionId: tx.id, tagId: tagId);

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.removeAllTagsFromTransaction(tx.id);

      final changes = await tracker.getUnpushedChangesForLedger(ledgerId);
      expect(
        changes.where((c) =>
            c.entityType == 'transaction' && c.action == 'upsert'),
        isNotEmpty,
      );
    });
  });

  group('C2: 排序/估值写路径', () {
    test('updateCategorySortOrders 登记每个分类的 update', () async {
      final id1 = await repo.upsertCategory(name: 'c1', kind: 'expense');
      final id2 = await repo.upsertCategory(name: 'c2', kind: 'expense');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.updateCategorySortOrders([
        (id: id1, sortOrder: 9),
        (id: id2, sortOrder: 8),
      ]);

      final changes =
          (await tracker.getUnpushedChangesForLedger(0))
              .where((c) => c.entityType == 'category' && c.action == 'upsert')
              .toList();
      expect(changes.map((c) => c.entityId), containsAll([id1, id2]));
    });

    test('updateAccountSortOrders / updateAccountValuation 登记 account:update',
        () async {
      final ledgerId = await repo.createLedger(name: 'acc-ledger');
      final accId = await repo.createAccount(
        ledgerId: ledgerId,
        name: '现金',
      );

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      // 注意：v35 部分唯一索引对「同实体同 action 未推送行」去重
      // （insertOrIgnore），两次连续 update 只会留一条 —— 这正是系统契约。
      // 分别验证两条路径各自能登记：中间先 markPushed 清场。
      await repo.updateAccountSortOrders([(id: accId, sortOrder: 5)]);
      var changes =
          (await tracker.getUnpushedChangesForLedger(0))
              .where((c) => c.entityType == 'account' && c.action == 'upsert')
              .toList();
      expect(changes, isNotEmpty, reason: '排序漏记则另一端永远收不到');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());
      await repo.updateAccountValuation(accId, 123.45);
      changes =
          (await tracker.getUnpushedChangesForLedger(0))
              .where((c) => c.entityType == 'account' && c.action == 'upsert')
              .toList();
      expect(changes, isNotEmpty, reason: '估值调整参与指纹，漏记不传播');
    });

    test('updateTagSortOrders 登记 tag:update', () async {
      final ledgerId = await repo.createLedger(name: 'tag-sort');
      final tagId = await repo.createTag(name: 'sort-tag');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.updateTagSortOrders([(id: tagId, sortOrder: 7)]);

      final changes =
          (await tracker.getUnpushedChangesForLedger(0))
              .where((c) => c.entityType == 'tag' && c.action == 'upsert')
              .toList();
      expect(changes.map((c) => c.entityId), contains(tagId));
    });
  });

  group('C3: 账本级写路径', () {
    test('createLedger 就地生成 syncId 并登记 ledger:upsert', () async {
      final ledgerId = await repo.createLedger(name: 'identity');

      final row = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerId)))
          .getSingle();
      expect(row.syncId, isNotNull, reason: '创建时即获得跨设备稳定身份');
      expect(row.syncId!.length, greaterThanOrEqualTo(32), reason: 'UUID 形态');

      final changes = await tracker.getUnpushedChangesForLedger(ledgerId);
      expect(
        changes.where((c) =>
            c.entityType == 'ledger' &&
            c.action == 'upsert' &&
            c.entitySyncId == row.syncId),
        isNotEmpty,
      );
    });

    test('updateLedgerName 登记 ledger:update', () async {
      final ledgerId = await repo.createLedger(name: 'before');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.updateLedgerName(id: ledgerId, name: 'after');

      final changes = await tracker.getUnpushedChangesForLedger(ledgerId);
      expect(
        changes.where((c) =>
            c.entityType == 'ledger' &&
            c.action == 'upsert' &&
            c.entitySyncId.isNotEmpty),
        isNotEmpty,
        reason: '账本名参与快照指纹，改名必须可被增量证据感知',
      );
    });
  });

  group('C4: 分类/周期规则批量写路径', () {
    test('upsertCategory 新建分支登记 category:upsert（复用分支不重复登记）',
        () async {
      final id = await repo.upsertCategory(name: 'new-cat', kind: 'expense');

      var changes = (await tracker.getUnpushedChangesForLedger(0))
          .where((c) => c.entityType == 'category')
          .toList();
      expect(
        changes.where((c) => c.entityId == id && c.action == 'upsert'),
        isNotEmpty,
        reason: '底层生成了 syncId 却无推送机会的问题已被修复',
      );

      // get-or-create 复用：不再新增 upsert 登记
      final countBefore = changes.length;
      await repo.upsertCategory(name: 'new-cat', kind: 'expense');
      changes = (await tracker.getUnpushedChangesForLedger(0))
          .where((c) => c.entityType == 'category')
          .toList();
      expect(changes.length, countBefore, reason: '复用已有分类是幂等无操作');
    });

    test('batchInsertRecurringTransactions 预填 syncId 并登记 create', () async {
      final ledgerId = await repo.createLedger(name: 'rec-batch');

      await tracker
          .markPushed((await tracker.getUnpushedChanges()).map((c) => c.id).toList());

      await repo.batchInsertRecurringTransactions([
        RecurringTransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 30,
          frequency: 'monthly',
          startDate: DateTime.utc(2026, 1, 1),
        ),
        RecurringTransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: 'income',
          amount: 40,
          frequency: 'weekly',
          startDate: DateTime.utc(2026, 1, 2),
        ),
      ]);

      final rows = await (db.select(db.recurringTransactions)
            ..where((r) => r.ledgerId.equals(ledgerId)))
          .get();
      expect(rows.length, 2);
      for (final r in rows) {
        expect(r.syncId, isNotNull, reason: '批量插入必须预填身份，否则永无推送机会');
      }

      final creates = (await tracker.getUnpushedChangesForLedger(ledgerId))
          .where((c) => c.entityType == 'recurring' && c.action == 'upsert')
          .toList();
      expect(creates.length, 2);
    });

    test('changeTracker 为 null 时批量插入不抛错', () async {
      final repoNoTracker = LocalRepository(db);
      final ledgerId = await repoNoTracker.createLedger(name: 'no-track-rec');

      await repoNoTracker.batchInsertRecurringTransactions([
        RecurringTransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: 'expense',
          amount: 1,
          frequency: 'daily',
          startDate: DateTime.utc(2026, 1, 1),
        ),
      ]);
      expect(await tracker.getUnpushedChanges(), isEmpty);
    });
  });
}
