// Path B 中/低风险修复回归（审计 M2 / L4）：
// - M2: _ensureLedgerSyncId 以入口旧值做 compare-and-swap —— 并发竞态下
//   未生效方采用并发方写入的身份，不再产生孤儿云端槽位
// - L4: pendingRecurringBindings 以 transactions 现存 syncId 修剪失效绑定

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
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
    provider = FakePiggyCountCloudProvider();
    engine = SyncEngine(
        db: db, provider: provider, changeTracker: tracker, repo: repo);
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
  });

  tearDown(() => db.close());

  bool isUuidLike(String s) =>
      s.length >= 32 && RegExp(r'^[0-9a-f-]+$').hasMatch(s);

  group('审计 M2：ledger 身份补生成的 CAS 守卫', () {
    test('NULL 身份 → 生成的 UUID 持久化且二次调用返回同值', () async {
      final id = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(name: 'no-id'),
          );
      final fresh =
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle();

      final first = await engine.debugEnsureLedgerSyncIdFromSnapshot(fresh);
      expect(isUuidLike(first), isTrue);

      final persisted =
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle();
      expect(persisted.syncId, first, reason: '生成值必须落库');

      // 二次调用读到已生效身份 → 原样返回，不重新生成
      final second = await engine.debugEnsureLedgerSyncIdFromSnapshot(
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle());
      expect(second, first);
    });

    test('legacy 短数字身份 → 重生成为 UUID 形态并落库', () async {
      final id = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(name: 'legacy', syncId: const d.Value('7')),
          );
      final stale =
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle();

      final got = await engine.debugEnsureLedgerSyncIdFromSnapshot(stale);

      expect(got, isNot('7'));
      expect(isUuidLike(got), isTrue);
      final persisted =
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle();
      expect(persisted.syncId, got);
    });

    test('CAS 失败（并发方已写入有效身份）→ 采用并发方身份而非覆盖', () async {
      final id = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(name: 'cas-race'),
          );
      // 构造「过期快照」：读出旧值（NULL）后，模拟并发方先行写入自己的 UUID。
      // 过期快照仍持 NULL → CAS 走 IS NULL 条件，因并发方已写非 NULL 而失败。
      final stale = await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
          .getSingle();
      const concurrentWinnerUuid = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
      await (db.update(db.ledgers)..where((l) => l.id.equals(id))).write(
          LedgersCompanion(syncId: const d.Value(concurrentWinnerUuid)));

      final loserResult =
          await engine.debugEnsureLedgerSyncIdFromSnapshot(stale);
      expect(loserResult, concurrentWinnerUuid,
          reason: 'CAS 失败方必须采用并发方写入的身份');

      final persisted =
          await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
              .getSingle();
      expect(persisted.syncId, concurrentWinnerUuid,
          reason: '不得用自己生成的新 UUID 覆盖并发方的值');
    });

    test('CAS 失败（legacy 短值被并发方替换为有效身份）→ 同样采用并发方值',
        () async {
      final id = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(name: 'cas-legacy', syncId: const d.Value('7')),
          );
      final stale = await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
          .getSingle();
      const winnerUuid = '11111111-2222-4333-8444-555555555555';
      await (db.update(db.ledgers)..where((l) => l.id.equals(id))).write(
          LedgersCompanion(syncId: const d.Value(winnerUuid)));

      final loserResult =
          await engine.debugEnsureLedgerSyncIdFromSnapshot(stale);
      expect(loserResult, winnerUuid);
    });
  });

  group('审计 L4：失效延迟绑定修剪', () {
    test('只清不存在的交易 key，存活绑定保留', () async {
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 1,
              happenedAt: d.Value(DateTime.parse('2026-05-01T10:00:00Z')),
              syncId: const d.Value('tx-alive'),
            ),
          );
      expect(txId, greaterThan(0));

      engine.pendingRecurringBindings
        ..['tx-alive'] = 'rec-keep'
        ..['tx-gone'] = 'rec-drop';

      await engine.debugPrunePendingRecurringBindings();

      expect(engine.pendingRecurringBindings,
          {'tx-alive': 'rec-keep'},
          reason: 'L4 前失效条目会话内永久累积');
    });

    test('空 map 零开销直接返回（不触发查询）', () async {
      expect(engine.pendingRecurringBindings, isEmpty);
      await engine.debugPrunePendingRecurringBindings(); // 不抛错即通过
      expect(engine.pendingRecurringBindings, isEmpty);
    });
  });
}
