// 审计 M23 回归：被踢出共享账本后的本地清理（_purgeLocalLedgerByExternalId）
//
// 修复前两个缺陷：
// 1. 先 DELETE budgets 再 SELECT 收集水位 syncId → 恒为空集，
//    budget 水位行永不清（L2 声称要清但实际失效）；
// 2. recurring_transactions 只收水位不删行 → 孤儿周期规则残留，
//    有被生成器复活成悬空 ledgerId 交易的风险。
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;
  late LocalRepository repo;
  late FakePiggyCountCloudProvider provider;
  late SyncEngine engine;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
    provider = FakePiggyCountCloudProvider(userId: 'purge-me');
    engine = SyncEngine(
        db: db, provider: provider, changeTracker: tracker, repo: repo);
  });

  tearDown(() async {
    engine.stopListeningRealtime();
    await db.close();
  });

  test('被踢后：budgets/recurrings 行删除，全部水位与 tag override 清理',
      () async {
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));

    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 10,
            happenedAt: d.Value(DateTime.parse('2026-05-01T10:00:00Z')),
            syncId: const d.Value('tx-1'),
          ),
        );
    await db.into(db.transactionTags).insert(
          TransactionTagsCompanion.insert(transactionId: txId, tagId: 1),
        );
    await db.into(db.transactionTagOverrides).insert(
          TransactionTagOverridesCompanion.insert(
            transactionSyncId: 'tx-1',
            tagSyncId: 'tag-owner-1',
            createdAt: DateTime.parse('2026-05-01T10:00:00Z'),
          ),
        );
    await db.into(db.budgets).insert(
          BudgetsCompanion.insert(
            ledgerId: 1,
            amount: 100,
            syncId: const d.Value('budget-1'),
          ),
        );
    await db.into(db.recurringTransactions).insert(
          RecurringTransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 1000,
            frequency: 'monthly',
            startDate: DateTime.parse('2026-05-01T00:00:00Z'),
            syncId: const d.Value('recurring-1'),
          ),
        );

    // 账户是 user-global（不删行），但水位按现存行收集 —— 种一行真实
    // 账户以覆盖「account 水位清理」路径
    await db.into(db.accounts).insert(
          AccountsCompanion.insert(
            ledgerId: 1,
            name: 'cash',
            syncId: const d.Value('acc-1'),
          ),
        );

    // 全量预置水位：账本 + tx + budget + recurring + account
    for (final sid in ['L1', 'tx-1', 'budget-1', 'recurring-1', 'acc-1']) {
      await db.into(db.entityChangeWatermarks)
          .insert(EntityChangeWatermarksCompanion.insert(syncId: sid, watermark: 42));
    }

    engine.startListeningRealtime();
    provider.emitRealtimeEvent(const PiggyCountCloudRealtimeEvent(
      type: 'member_change',
      ledgerId: 'L1',
      rawData: {'changeType': 'removed', 'userId': 'purge-me'},
    ));
    // member_change 处理是 unawaited 的异步任务
    await Future<void>.delayed(const Duration(milliseconds: 200));

    // 业务行：budgets / recurrings 已删（M23 前 recurrings 残留）
    expect(await db.select(db.budgets).get(), isEmpty);
    expect(await db.select(db.recurringTransactions).get(), isEmpty,
        reason: 'M23 前只收水位不删行 → 孤儿规则可被生成器复活');
    expect(await db.select(db.transactions).get(), isEmpty);

    // 辅助表：tag override 清理 + 全部水位清理
    expect(await db.select(db.transactionTagOverrides).get(), isEmpty);
    final remainingWatermarks =
        await (db.select(db.entityChangeWatermarks)
              ..where((w) => w.syncId.isIn(
                  ['L1', 'tx-1', 'budget-1', 'recurring-1', 'acc-1'])))
            .get();
    expect(remainingWatermarks, isEmpty,
        reason: 'M23 前先删 budgets 后收集 → budget 水位恒漏清');

    // 账本本体已清
    expect(await db.select(db.ledgers).get(), isEmpty);
  });
}
