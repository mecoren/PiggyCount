/// M1/M2 回归测试：deleteLedger 数据清理对全部后端一致。
///
/// 背景：旧实现 `changeTracker == null` 提前 return —— 非 Cloud 后端
/// （S3/WebDAV/iCloud/Supabase 快照链路）删账本时 budgets /
/// transaction_tags / transaction_attachments / transaction_tag_overrides
/// 全部残留孤儿行；且 recurring_transactions 在**任何**模式都漏删。
///
/// 本文件覆盖快照链路（tracker == null，与 S3/WebDAV 模式同构）：
/// 删除账本后所有账本维度子表必须清空，且不影响其他账本。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    // 故意不注入 changeTracker —— 与 repositoryProvider 在非 Cloud 后端下
    // 的装配完全一致（database_providers.dart: tracker 仅 piggycountCloud 注入）
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> seedLedger(int id, String name) async {
    await db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            id: d.Value(id),
            name: name,
            syncId: d.Value('ledger-sync-$id'),
          ),
        );
    return id;
  }

  Future<int> seedTx(int ledgerId, String syncId) async {
    return db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 1,
            happenedAt: const d.Value.absent(),
            syncId: d.Value(syncId),
          ),
        );
  }

  test('无 tracker 模式删除账本：budgets/tags/attachments/overrides/'
      'recurrings 全部清理', () async {
    await seedLedger(2, '被删账本');

    final txA = await seedTx(2, 'tx-a');
    await seedTx(2, 'tx-b');
    final tag = await db.into(db.tags).insert(TagsCompanion.insert(
          name: 't',
          syncId: d.Value('tag-1'),
        ));
    await db.into(db.transactionTags).insert(
          TransactionTagsCompanion.insert(transactionId: txA, tagId: tag),
        );
    await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
            transactionId: txA,
            fileName: 'a.jpg',
            localSha256: d.Value('hash-a'),
          ),
        );
    await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
            transactionSyncId: 'tx-a',
            tagSyncId: 'owner-tag-1',
            createdAt: DateTime.utc(2026, 8, 1),
          ),
        );
    for (var i = 0; i < 2; i++) {
      await db.into(db.budgets).insert(BudgetsCompanion.insert(
            ledgerId: 2,
            amount: 100.0 + i,
            syncId: d.Value('budget-$i'),
          ));
    }
    await db.into(db.recurringTransactions).insert(
          RecurringTransactionsCompanion.insert(
            ledgerId: 2,
            type: 'expense',
            amount: 9,
            frequency: 'monthly',
            startDate: DateTime.utc(2026, 1, 1),
            syncId: d.Value('recurring-1'),
          ),
        );

    await repo.deleteLedger(2);

    // 账本本体与交易
    expect(await (db.select(db.ledgers)..where((l) => l.id.equals(2))).get(),
        isEmpty);
    expect(
        await (db.select(db.transactions)
              ..where((t) => t.ledgerId.equals(2)))
            .get(), isEmpty);
    // M1：此前 tracker==null 分支全部漏清的子表
    expect(await db.select(db.budgets).get(), isEmpty,
        reason: 'budgets 孤儿行在快照模式下也必须清（M1）');
    expect(await db.select(db.transactionTags).get(), isEmpty);
    expect(await db.select(db.transactionAttachments).get(), isEmpty);
    expect(await db.select(db.transactionTagOverrides).get(), isEmpty);
    // M2：任何模式此前都漏删的周期规则模板
    expect(await db.select(db.recurringTransactions).get(), isEmpty,
        reason: '孤儿周期模板有被生成器复活成悬空 ledgerId 交易的风险（M2）');
  });

  test('删除账本不影响其他账本的数据', () async {
    await seedLedger(2, '被删账本');
    await seedLedger(3, '保留账本');

    final keptTx = await seedTx(3, 'tx-keep');
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
          ledgerId: 3,
          amount: 50.0,
        ));

    await seedTx(2, 'tx-drop');
    await repo.deleteLedger(2);

    expect(
        await (db.select(db.transactions)
              ..where((t) => t.id.equals(keptTx)))
            .get(),
        hasLength(1));
    expect(await (db.select(db.budgets)..where((b) => b.ledgerId.equals(3)))
        .get(), hasLength(1));
  });
}
