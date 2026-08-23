// v30 交易同步的多币种语义(02 §七):
//
//   1. serializer:payload 带 currencyCode/nativeAmount(有值才发)
//   2. apply 快照保护:旧 payload(缺两键)+ 本地已有折算:
//      - amount 未变(旧 App 只改备注)→ 保留本地 nativeAmount/currencyCode
//      - amount 变了 → nativeAmount 退化 =amount(1:1,L11 可捞回)
//   3. apply 新 payload(带两键)→ 原样写入
//   4. insert 旧 payload(无两键)→ nativeAmount=amount(与迁移回填同口径)
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:drift/drift.dart' show Value;

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync/entity_serializer.dart';
import 'package:piggycount/cloud/sync/sync_engine.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

import '../cloud/sync/_fakes/fake_piggycount_cloud_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late ChangeTracker changeTracker;
  late LocalRepository repo;
  late FakePiggyCountCloudProvider provider;
  late SyncEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    changeTracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: changeTracker);
    provider = FakePiggyCountCloudProvider();
    engine = SyncEngine(
      db: db,
      provider: provider,
      changeTracker: changeTracker,
      repo: repo,
    );
  });

  tearDown(() async => db.close());

  Future<int> seedLedger() {
    return db.into(db.ledgers).insert(LedgersCompanion.insert(
          name: '测试账本',
          monthStartDay: const Value(1),
        ));
  }

  /// 审计 S3b：本文件验证的是 apply 层字段级合并语义（D6/快照保护），
  /// 与「未推送本地编辑跳过远端更新」守卫无关——先把种子产生的
  /// local_changes 标记为已推送，模拟 push 已完成的稳态。
  Future<void> markAllLocalChangesPushed() async {
    await db.update(db.localChanges).write(
          LocalChangesCompanion(pushedAt: Value(DateTime.now())),
        );
  }

  Future<Transaction> txBySyncId(String syncId) async {
    return (db.select(db.transactions)..where((t) => t.syncId.equals(syncId)))
        .getSingle();
  }

  test('serializeTransaction:有折算的交易 payload 带两字段;无折算不带', () {
    final tx = Transaction(
      id: 1,
      ledgerId: 1,
      type: 'expense',
      amount: 12.0,
      happenedAt: DateTime.utc(2026, 7, 12),
      excludeFromStats: false,
      excludeFromBudget: false,
      currencyCode: 'USD',
      nativeAmount: 86.4,
    );
    final payload = EntitySerializer.serializeTransaction(tx);
    expect(payload['currencyCode'], 'USD');
    expect(payload['nativeAmount'], 86.4);

    final legacy = Transaction(
      id: 2,
      ledgerId: 1,
      type: 'expense',
      amount: 5.0,
      happenedAt: DateTime.utc(2026, 7, 12),
      excludeFromStats: false,
      excludeFromBudget: false,
    );
    final legacyPayload = EntitySerializer.serializeTransaction(legacy);
    expect(legacyPayload.containsKey('currencyCode'), isFalse);
    expect(legacyPayload.containsKey('nativeAmount'), isFalse);
  });

  test('快照保护:旧 payload 只改备注(amount 未变)→ 本地折算保留', () async {
    final lid = await seedLedger();
    const txSyncId = 'tx-mc-1';
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 12,
      happenedAt: DateTime(2026, 7, 12),
      syncId: txSyncId,
      currencyCode: 'USD',
      nativeAmount: 86.4,
    );

    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: txSyncId,
      ledgerId: '$lid',
      payload: {
        'syncId': txSyncId,
        'type': 'expense',
        'amount': 12,
        'note': '旧 App 改的备注',
        'happenedAt': '2026-07-12T00:00:00Z',
      },
    );
    await markAllLocalChangesPushed();
    await engine.pull('');

    final tx = await txBySyncId(txSyncId);
    expect(tx.note, '旧 App 改的备注');
    expect(tx.currencyCode, 'USD', reason: '缺键不得抹掉本地币种');
    expect(tx.nativeAmount, 86.4, reason: 'amount 未变必须保留折算快照');
  });

  test('快照保护:旧 payload 改了金额 → nativeAmount 退化 =新 amount(L11 可捞)', () async {
    final lid = await seedLedger();
    const txSyncId = 'tx-mc-2';
    await repo.addTransaction(
      ledgerId: lid,
      type: 'expense',
      amount: 12,
      happenedAt: DateTime(2026, 7, 12),
      syncId: txSyncId,
      currencyCode: 'USD',
      nativeAmount: 86.4,
    );

    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: txSyncId,
      ledgerId: '$lid',
      payload: {
        'syncId': txSyncId,
        'type': 'expense',
        'amount': 24,
        'happenedAt': '2026-07-12T00:00:00Z',
      },
    );
    await markAllLocalChangesPushed();
    await engine.pull('');

    final tx = await txBySyncId(txSyncId);
    expect(tx.amount, 24);
    expect(tx.nativeAmount, 24, reason: '旧折算对新金额失效,退化 1:1');
    expect(tx.currencyCode, 'USD', reason: '本地币种保留 → L11 检测能命中');
    expect(await repo.countUnconvertedForeignTx(lid), 1);
  });

  test('新 payload 带两字段 → 原样写入(update 与 insert)', () async {
    final lid = await seedLedger();
    // insert 路径
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-mc-3',
      ledgerId: '$lid',
      payload: {
        'syncId': 'tx-mc-3',
        'type': 'expense',
        'amount': 12,
        'currencyCode': 'USD',
        'nativeAmount': 86.4,
        'happenedAt': '2026-07-12T00:00:00Z',
      },
    );
    await engine.pull('');
    var tx = await txBySyncId('tx-mc-3');
    expect(tx.currencyCode, 'USD');
    expect(tx.nativeAmount, 86.4);

    // update 路径(新 App 改金额,payload 已带联动后的折算)
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-mc-3',
      ledgerId: '$lid',
      payload: {
        'syncId': 'tx-mc-3',
        'type': 'expense',
        'amount': 24,
        'currencyCode': 'USD',
        'nativeAmount': 172.8,
        'happenedAt': '2026-07-12T00:00:00Z',
      },
    );
    await engine.pull('');
    tx = await txBySyncId('tx-mc-3');
    expect(tx.nativeAmount, 172.8);
  });

  test('insert 旧 payload(无两键)→ nativeAmount=amount(迁移回填同口径)', () async {
    final lid = await seedLedger();
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-mc-4',
      ledgerId: '$lid',
      payload: {
        'syncId': 'tx-mc-4',
        'type': 'expense',
        'amount': 5,
        'happenedAt': '2026-07-12T00:00:00Z',
      },
    );
    await engine.pull('');
    final tx = await txBySyncId('tx-mc-4');
    expect(tx.currencyCode, isNull);
    expect(tx.nativeAmount, 5.0);
  });
}
