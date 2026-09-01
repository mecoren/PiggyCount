// 审计 M22 回归：LookupCache miss 必须回源 DB（cache 是加速器，不是事实源）。
//
// 场景：pull 入口 prime 全表缓存之后、某页 apply 之前，有事务外并发写入
// （用户编辑 / 另一路 restore）插入了同 syncId 的行。修复前：
// - upsert 分支：existingId=null 直接 INSERT → 撞 uq_transactions_sync_id
//   唯一索引 → 整页 rollback、游标停在该页反复重放直至进程重启；
// - delete 分支：existingId=null 直接 return → 远端删除被静默吞掉。
// 修复后：miss 回源单次 SELECT，命中则回填 cache 并走 UPDATE/删除。
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
  late ChangeTracker changeTracker;
  late LocalRepository repo;
  late FakePiggyCountCloudProvider provider;
  late SyncEngine engine;

  setUp(() async {
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
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
  });

  tearDown(() async => db.close());

  Map<String, dynamic> payload(String syncId, double amount) => {
        'syncId': syncId,
        'type': 'expense',
        'amount': amount,
        'happenedAt': '2026-05-01T10:00:00Z',
      };

  test('M22-upsert：prime 后并发插入同 syncId 行 → 走 UPDATE 不撞唯一索引',
      () async {
    // 页1：普通变更（占位，保证 probe 非空以触发 prime）
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-A',
      ledgerId: 'L1',
      changeId: 1,
      payload: payload('tx-A', 11),
    );
    // 页2：tx-M 的 upsert —— 应用时该行已在 DB 但不在 cache
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-M',
      ledgerId: 'L1',
      changeId: 2,
      payload: payload('tx-M', 22),
    );

    provider.pullResultTransformer = (callIndex, result) {
      if (callIndex == 1) {
        // 探测页切片为仅 tx-A，并强制 hasMore → 引擎 prime 后再取第二页
        return PiggyCountCloudPullResult(
          changes:
              result.changes.where((c) => c.entitySyncId == 'tx-A').toList(),
          serverCursor: 1,
          hasMore: true,
        );
      }
      if (callIndex == 2) {
        // 此刻 cache 已 prime（不含 tx-M）—— 模拟事务外并发写入
        // ignore: discarded_futures
        db.into(db.transactions).insert(TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 99,
              happenedAt: d.Value(DateTime.parse('2026-05-01T09:00:00Z')),
              syncId: const d.Value('tx-M'),
            ));
      }
      return result;
    };

    final applied = await engine.pull('');

    expect(applied, 2, reason: '两页全部应用（M22 前 page2 撞唯一索引整页回滚）');
    final rows = await (db.select(db.transactions)
          ..where((t) => t.syncId.equals('tx-M')))
        .get();
    expect(rows, hasLength(1), reason: '不产生重复行');
    expect(rows.single.amount, 22, reason: '走 UPDATE 吸收远端值而非 INSERT 崩溃');
  });

  test('M22-delete：prime 后并发插入的行也能被远端 delete 正确删除', () async {
    // 页1：占位变更
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-B',
      ledgerId: 'L1',
      changeId: 4,
      payload: payload('tx-B', 5),
    );
    // 页2：对 tx-D 的远端删除
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-D',
      ledgerId: 'L1',
      changeId: 5,
      action: 'delete',
    );

    provider.pullResultTransformer = (callIndex, result) {
      if (callIndex == 1) {
        return PiggyCountCloudPullResult(
          changes:
              result.changes.where((c) => c.entitySyncId == 'tx-B').toList(),
          serverCursor: 4,
          hasMore: true,
        );
      }
      if (callIndex == 2) {
        // cache prime 之后该行才出现 —— cache 必然 miss
        // ignore: discarded_futures
        db.into(db.transactions).insert(TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 50,
              happenedAt: d.Value(DateTime.parse('2026-05-01T09:00:00Z')),
              syncId: const d.Value('tx-D'),
            ));
      }
      return result;
    };

    final applied = await engine.pull('');

    expect(applied, 2);
    final rows = await (db.select(db.transactions)
          ..where((t) => t.syncId.equals('tx-D')))
        .get();
    expect(rows, isEmpty, reason: 'M22 前删除被静默吞掉，本地残留已删交易');
  });
}
