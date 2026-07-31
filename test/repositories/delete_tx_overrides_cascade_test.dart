// C 组回归测试:删除交易时必须级联清理 transaction_tag_overrides。
//
// TransactionTagOverrides 表用 transactionSyncId(text) 作主键,而三处删除路径
// 历史上只按 int id 删 transactionTags + transactionAttachments + 主表,
// 漏删 overrides → 共享账本 Editor 视角 _hydrateSharedOverridesFull LEFT JOIN
// 挂载幽灵标签。本测试覆盖三条路径:
//   1. LocalTransactionRepository.deleteTransaction(id)  — 单条
//   2. LocalTransactionRepository.deleteTransactionsBatchBySyncIds — 批量
//   3. SyncEngine.applyRemoteChange delete — 远端推送
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '../cloud/sync/_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
  });

  tearDown(() async => db.close());

  /// 构造一条带 syncId 的交易 + 一条 transaction_tag_overrides 孤儿候选。
  Future<int> seedTxWithOverride({
    required String txSyncId,
    required String tagSyncId,
  }) async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: Value('L-$txSyncId')),
        );
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 1.0,
            syncId: Value(txSyncId),
          ),
        );
    await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
            transactionSyncId: txSyncId,
            tagSyncId: tagSyncId,
            createdAt: DateTime(2026, 7, 1),
          ),
        );
    return txId;
  }

  Future<int> countOverrides() async {
    final rows = await db.select(db.transactionTagOverrides).get();
    return rows.length;
  }

  group('deleteTransaction 单条路径', () {
    test('删除交易后 transaction_tag_overrides 无残留', () async {
      final txId = await seedTxWithOverride(
        txSyncId: 'tx-1',
        tagSyncId: 'tag-1',
      );
      expect(await countOverrides(), 1);

      await repo.deleteTransaction(txId);

      expect(await countOverrides(), 0,
          reason: 'deleteTransaction 必须级联清理 transaction_tag_overrides');
    });
  });

  group('deleteTransactionsBatchBySyncIds 批量路径', () {
    test('批量删除后所有相关 overrides 被清理', () async {
      await seedTxWithOverride(txSyncId: 'tx-a', tagSyncId: 'tag-a');
      await seedTxWithOverride(txSyncId: 'tx-b', tagSyncId: 'tag-b');
      // 另一笔不删,验证只删指定 syncId
      await seedTxWithOverride(txSyncId: 'tx-keep', tagSyncId: 'tag-keep');
      expect(await countOverrides(), 3);

      await repo.deleteTransactionsBatchBySyncIds(['tx-a', 'tx-b']);

      expect(await countOverrides(), 1,
          reason: '批量删除只清理被删 tx 的 overrides,保留未删的');
    });
  });

  group('SyncEngine.applyRemoteChange delete 路径', () {
    test('远端推 delete → 本地 overrides 同步清理', () async {
      final provider = FakePiggyCountCloudProvider();
      final engine = SyncEngine(
        db: db,
        provider: provider,
        changeTracker: ChangeTracker(db),
        repo: repo,
      );

      await seedTxWithOverride(txSyncId: 'tx-remote', tagSyncId: 'tag-remote');
      expect(await countOverrides(), 1);

      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-remote',
        ledgerId: 'L-tx-remote',
        action: 'delete',
      );

      await engine.pull('');

      expect(await countOverrides(), 0,
          reason: 'sync apply delete 必须级联清理 transaction_tag_overrides');
    });
  });
}
