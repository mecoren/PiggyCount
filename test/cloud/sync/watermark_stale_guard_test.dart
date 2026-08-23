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
        db: db, provider: provider, changeTracker: changeTracker, repo: repo);
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const Value('L1')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: 'C', kind: 'expense', syncId: const Value('C1')));
  });

  tearDown(() => db.close());

  Map<String, dynamic> payload(String syncId, double amount) => {
        'syncId': syncId,
        'type': 'expense',
        'amount': amount,
        'happenedAt': '2026-05-01T10:00:00Z',
        'categoryName': 'C',
        'categoryKind': 'expense',
        'categoryId': 'C1',
      };

  test('存在未推送本地编辑时，更旧远端更新被拦（先推后拉窗口，S3 核心）', () async {
    // 本地已有 tx-X(amount=100) 且登记了未推送编辑（pushedAt IS NULL）
    final ledgerRow = await (db.select(db.ledgers)
          ..where((l) => l.syncId.equals('L1')))
        .getSingle();
    final cat = await db.select(db.categories).getSingle();
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerRow.id,
            type: 'expense',
            amount: 100,
            happenedAt: Value(DateTime.parse('2026-05-01T10:00:00Z')),
            categoryId: Value(cat.id),
            syncId: const Value('tx-X'),
          ),
        );
    await db.into(db.localChanges).insert(LocalChangesCompanion.insert(
      entityType: 'transaction',
      entityId: txId,
      entitySyncId: 'tx-X',
      ledgerId: ledgerRow.id,
      action: 'upsert',
    ));

    // pull 到他人较早的远端版本（amount=50）
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-X',
      ledgerId: 'L1',
      payload: payload('tx-X', 50),
    );

    final applied = await engine.pull('');
    expect(applied, 0, reason: '本地未推送编辑必须赢过更旧的远端值');
    expect((await db.select(db.transactions).get()).single.amount, 100);
  });

  test('回声记录水位：乱序到达的陈旧重放被拦', () async {
    // 回声(#101)先到、他人旧值(#100)后到 —— 模拟窗口内乱序。
    // 本地 deviceId 在 fake 下解析为 'unknown'。
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-Y',
      ledgerId: 'L1',
      updatedByDeviceId: 'unknown',
      changeId: 101,
      payload: payload('tx-Y', 100), // 回声不落库，但记录水位=101
    );
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-Y',
      ledgerId: 'L1',
      changeId: 100,
      payload: payload('tx-Y', 50),
    );

    final applied = await engine.pull('');
    expect(applied, 0);
    expect(await db.select(db.transactions).get(), isEmpty,
        reason: '#100 <= 水位101，不得插入旧值');
  });

  test('成功应用记录水位：同 id 重放被拦、更新 id 正常应用', () async {
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-Y',
      ledgerId: 'L1',
      payload: payload('tx-Y', 10),
    ); // changeId=1
    expect(await engine.pull(''), 1);

    // 重放同一 changeId（不同金额）→ 必须跳过
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-Y',
      ledgerId: 'L1',
      changeId: 1,
      payload: payload('tx-Y', 99),
    );
    expect(await engine.pull(''), 0);
    final rows = await db.select(db.transactions).get();
    expect(rows.single.amount, 10);

    // 更新的 changeId=2 → 正常应用
    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-Y',
      ledgerId: 'L1',
      changeId: 2,
      payload: payload('tx-Y', 20),
    );
    expect(await engine.pull(''), 1);
    expect((await db.select(db.transactions).get()).single.amount, 20);
  });
}
