// cloud_recurring_sync:recurring 规则的 apply(命中/未命中/delete/延迟绑定)
// + 独立批推送(失败不阻塞主批)测试。
//
// 覆盖设计文档(design.md)的验收点:
// (1) upsert change → 规则落地,外键 syncId 解析为本地 int id
// (2) 外键 syncId 未命中 → 置 null + 规则行仍落地(容错不阻断)
// (3) delete change → 规则行删除,仍引用它的交易不被级联删
// (4) 延迟绑定:transaction 先到(规则未就绪)→ recurringId null + 暂存;
//     recurring 后到 → 回扫补齐交易 recurringId
// (5) 规则先到 → transaction 后到时 recurringId 即时解析
// (6) 独立批推送:旧 server 拒绝 recurring 批 → 主批照常成功,
//     recurring change 留在 local_changes 重试;server 就绪后追平

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '_fakes/fake_piggycount_cloud_provider.dart';

/// 模拟"未升级白名单的旧 server":拒收含 recurring 的批(整批 4xx)。
class _RejectRecurringProvider extends FakePiggyCountCloudProvider {
  bool rejectRecurring = false;

  @override
  Future<void> pushChanges({
    required List<Map<String, dynamic>> changes,
  }) async {
    if (rejectRecurring &&
        changes.any((c) => c['entity_type'] == 'recurring')) {
      throw Exception('old server rejects entity_type=recurring');
    }
    return super.pushChanges(changes: changes);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late ChangeTracker changeTracker;
  late LocalRepository repo;
  late _RejectRecurringProvider provider;
  late SyncEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    changeTracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: changeTracker);
    provider = _RejectRecurringProvider();
    engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: changeTracker,
      repo: repo,
    );
  });

  tearDown(() async => db.close());

  /// seed:本地账本(syncId=ledger-sync-1)+ 分类/账户(带 syncId)
  Future<int> seedLedgerWithRefs() async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            name: 'L1',
            syncId: const d.Value('ledger-sync-1'),
          ),
        );
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          name: 'Food',
          kind: 'expense',
          syncId: const d.Value('cat-sync-1'),
        ));
    await db.into(db.accounts).insert(AccountsCompanion.insert(
          ledgerId: ledgerId,
          name: 'Cash',
          syncId: const d.Value('acc-sync-1'),
        ));
    return ledgerId;
  }

  Map<String, dynamic> rulePayload({
    String? categorySyncId = 'cat-sync-1',
    String? accountSyncId = 'acc-sync-1',
    String? lastGeneratedDate = '2026-08-01T00:00:00Z',
  }) =>
      {
        'syncId': 'rule-1',
        'ledgerSyncId': 'ledger-sync-1',
        'type': 'expense',
        'amount': 25.0,
        'categorySyncId': categorySyncId,
        'accountSyncId': accountSyncId,
        'frequency': 'monthly',
        'interval': 1,
        'dayOfMonth': 1,
        'startDate': '2026-01-01T00:00:00Z',
        'enabled': true,
        if (lastGeneratedDate != null)
          'lastGeneratedDate': lastGeneratedDate,
      };

  group('_applyRecurringChange', () {
    test('(1) upsert → 规则落地,外键 syncId 解析为本地 int id', () async {
      await seedLedgerWithRefs();
      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        payload: rulePayload(),
      );

      await engine.pull('');

      final rows = await db.select(db.recurringTransactions).get();
      expect(rows, hasLength(1));
      final rule = rows.first;
      expect(rule.syncId, 'rule-1');
      expect(rule.ledgerId, 1);
      expect(rule.amount, 25.0);
      expect(rule.frequency, 'monthly');
      expect(rule.enabled, isTrue);
      expect(rule.lastGeneratedDate, isNotNull);

      // 外键按 syncId 反查命中本地行
      final cat = await (db.select(db.categories)
            ..where((c) => c.syncId.equals('cat-sync-1')))
          .getSingle();
      final acc = await (db.select(db.accounts)
            ..where((a) => a.syncId.equals('acc-sync-1')))
          .getSingle();
      expect(rule.categoryId, cat.id);
      expect(rule.accountId, acc.id);
    });

    test('(2) 外键 syncId 未命中 → 置 null,规则行仍落地', () async {
      await seedLedgerWithRefs();
      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        payload: rulePayload(
          categorySyncId: 'ghost-cat',
          accountSyncId: 'ghost-acc',
        ),
      );

      await engine.pull('');

      final rows = await db.select(db.recurringTransactions).get();
      expect(rows, hasLength(1), reason: '引用缺失不阻断同步,规则行照常落地');
      expect(rows.first.categoryId, isNull);
      expect(rows.first.accountId, isNull);
    });

    test('(3) delete → 规则行删除,引用它的交易不被级联删', () async {
      final ledgerId = await seedLedgerWithRefs();
      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        payload: rulePayload(),
      );
      await engine.pull('');

      final ruleId =
          (await db.select(db.recurringTransactions).get()).first.id;
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 25.0,
              recurringId: d.Value(ruleId),
              syncId: const d.Value('tx-uses-rule'),
            ),
          );
      expect(txId, greaterThan(0));

      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        action: 'delete',
      );
      await engine.pull('');

      expect(await db.select(db.recurringTransactions).get(), isEmpty,
          reason: '规则行被删');
      final txs = await db.select(db.transactions).get();
      expect(txs, hasLength(1), reason: '不级联删交易(防误删用户数据)');
    });

    test('(4) 延迟绑定:transaction 先到 → recurring 后到回扫补齐', () async {
      await seedLedgerWithRefs();
      // step1:交易先到,payload 带 recurringSyncId 但规则还没拉到
      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-1',
        ledgerId: 'ledger-sync-1',
        payload: {
          'type': 'expense',
          'amount': 25.0,
          'happenedAt': '2026-08-01T00:00:00Z',
          'recurringSyncId': 'rule-1',
        },
      );
      await engine.pull('');

      var tx = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-1')))
          .getSingle();
      expect(tx.recurringId, isNull, reason: '规则未就绪,先落 null');
      expect(engine.pendingRecurringBindings['tx-1'], 'rule-1',
          reason: '暂存待延迟绑定');

      // step2:规则后到 → 落地 + 回扫补齐
      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        payload: rulePayload(),
      );
      await engine.pull('');

      final rule = await (db.select(db.recurringTransactions)
            ..where((r) => r.syncId.equals('rule-1')))
          .getSingle();
      tx = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-1')))
          .getSingle();
      expect(tx.recurringId, rule.id, reason: '延迟绑定回扫补齐外键');
      expect(engine.pendingRecurringBindings, isEmpty,
          reason: '绑定完成后清除暂存');
    });

    test('(5) 规则先到 → transaction 后到即时解析 recurringId', () async {
      await seedLedgerWithRefs();
      provider.pushFakeChange(
        entityType: 'recurring',
        entitySyncId: 'rule-1',
        ledgerId: 'ledger-sync-1',
        payload: rulePayload(),
      );
      await engine.pull('');

      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-1',
        ledgerId: 'ledger-sync-1',
        payload: {
          'type': 'expense',
          'amount': 25.0,
          'happenedAt': '2026-08-01T00:00:00Z',
          'recurringSyncId': 'rule-1',
        },
      );
      await engine.pull('');

      final rule = await (db.select(db.recurringTransactions)
            ..where((r) => r.syncId.equals('rule-1')))
          .getSingle();
      final tx = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals('tx-1')))
          .getSingle();
      expect(tx.recurringId, rule.id, reason: '规则已就绪,即时绑定');
      expect(engine.pendingRecurringBindings, isEmpty);
    });
  });

  group('独立批推送(D10 模式)', () {
    test('(6) recurring 批被拒 → 主批照常成功,recurring 留待重试后追平',
        () async {
      final ledgerId = await seedLedgerWithRefs();

      // 本地造一条规则 + 一笔关联交易,各登记 change
      final ruleId = await db.into(db.recurringTransactions).insert(
            RecurringTransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 25.0,
              frequency: 'monthly',
              startDate: DateTime(2026, 1, 1),
              syncId: const d.Value('rule-1'),
            ),
          );
      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 25.0,
              recurringId: d.Value(ruleId),
              syncId: const d.Value('tx-1'),
            ),
          );
      await changeTracker.recordLedgerChange(
        entityType: 'transaction',
        entityId: 1,
        entitySyncId: 'tx-1',
        ledgerId: ledgerId,
        action: 'create',
      );
      await changeTracker.recordLedgerChange(
        entityType: 'recurring',
        entityId: ruleId,
        entitySyncId: 'rule-1',
        ledgerId: ledgerId,
        action: 'create',
      );

      // 旧 server:拒收 recurring
      provider.rejectRecurring = true;
      await engine.push('$ledgerId');

      // 主批成功(seed 的 account/category 会被 legacy backfill 补登成
      // user-global 批一起推,这里只断言关键行为):
      // - 已推批次里没有 recurring(独立批被拒,未到达 server)
      // - transaction 已推出去
      final flatPushed =
          provider.pushedBatches.expand((b) => b).map((c) => c['entity_type']);
      expect(flatPushed, isNot(contains('recurring')),
          reason: 'recurring 批被拒,不应出现在已推批次里');
      expect(flatPushed, contains('transaction'),
          reason: '主批照常成功,不受 recurring 批失败影响');
      var unpushed =
          await changeTracker.getUnpushedChangesForLedger(ledgerId);
      expect(unpushed, hasLength(1));
      expect(unpushed.first.entityType, 'recurring',
          reason: 'recurring change 未 markPushed,留在 local_changes');

      // server 升级后:同一批 change 重试成功
      provider.rejectRecurring = false;
      await engine.push('$ledgerId');
      final recurringBatch = provider.pushedBatches.last;
      expect(recurringBatch, hasLength(1));
      expect(recurringBatch.first['entity_type'], 'recurring');
      expect(
        (recurringBatch.first['payload'] as Map).containsKey('frequency'),
        isTrue,
        reason: 'recurring payload 带规则字段',
      );
      unpushed = await changeTracker.getUnpushedChangesForLedger(ledgerId);
      expect(unpushed, isEmpty, reason: '追平后无积压');
    });
  });
}
