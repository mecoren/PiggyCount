import 'package:drift/drift.dart' show Value;
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

  late PiggyDatabase db;
  late FakePiggyCountCloudProvider provider;
  late SyncEngine engine;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    final ct = ChangeTracker(db);
    provider = FakePiggyCountCloudProvider();
    engine = SyncEngine(
        db: db,
        provider: provider,
        changeTracker: ct,
        repo: LocalRepository(db, changeTracker: ct));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: 'C', kind: 'expense', syncId: const Value('C')));
  });

  tearDown(() => db.close());

  Map<String, dynamic> payload(String syncId) => {
        'syncId': syncId,
        'type': 'expense',
        'amount': 7.0,
        'happenedAt': '2026-05-01T10:00:00Z',
        'categoryName': 'C',
        'categoryKind': 'expense',
        'categoryId': 'C',
      };

  test('引用不存在账本的交易：不产生 -1 幽灵行且游标不前进（S4）', () async {
    provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'ghost-tx',
        ledgerId: 'ghost-ledger',
        payload: payload('ghost-tx'));

    await engine.pull('');

    expect(await db.select(db.transactions).get(), isEmpty,
        reason: '禁止 ledgerId=-1 幽灵行');
    // 游标未前进：blocked 页不得 commit cursor
    expect(await engine.appCursor.read(), 0,
        reason: 'blocked 页不得 commit cursor');
  });

  test('priming 后重试：账本就绪则同批变更全部落地且无 -1', () async {
    provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'ghost-tx',
        ledgerId: 'ghost-ledger',
        payload: payload('ghost-tx'));
    provider.pushFakeLedger(ledgerId: 'ghost-ledger'); // server 端有此账本

    await engine.pull('');

    final txs = await db.select(db.transactions).get();
    expect(txs, hasLength(1));
    final ghostLedger = await (db.select(db.ledgers)
          ..where((l) => l.syncId.equals('ghost-ledger')))
        .getSingleOrNull();
    expect(ghostLedger, isNotNull, reason: 'priming 应已建账本');
    expect(txs.single.ledgerId, isNot(-1));
    expect(txs.single.ledgerId, ghostLedger!.id);
  });
}
