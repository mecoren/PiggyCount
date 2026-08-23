// 审计 S10：同步产生的重名分类不得让 apply 崩溃（Too many elements），
// 也不得盲插出重复行——按 (name,kind) 收编既有行。
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
    await db.into(db.ledgers).insert(
        LedgersCompanion.insert(name: 'L', syncId: const Value('L1')));
  });

  tearDown(() => db.close);

  Map<String, dynamic> txPayload(String syncId, String categoryName) => {
        'syncId': syncId,
        'type': 'expense',
        'amount': 5,
        'happenedAt': '2026-05-01T10:00:00Z',
        'categoryName': categoryName,
        'categoryKind': 'expense',
      };

  test('存在重名分类时，交易 apply 按名解析不抛 Too many elements（S10）', () async {
    // 人为制造重名分类（历史脏数据场景）
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          name: '餐饮',
          kind: 'expense',
          syncId: const Value('cat-dup-a'),
        ));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          name: '餐饮',
          kind: 'expense',
          syncId: const Value('cat-dup-b'),
        ));

    provider.pushFakeChange(
      entityType: 'transaction',
      entitySyncId: 'tx-s10',
      ledgerId: 'L1',
      payload: txPayload('tx-s10', '餐饮'),
    );

    final applied = await engine.pull('');
    expect(applied, 1, reason: '重名分类不应让交易 apply 抛异常卡死');
  });

  test('pull 不同 syncId 的同名分类 → 收编既有行而非插入重复行（S10）', () async {
    // 本地已有「购物」(syncId=cat-local)
    await db.into(db.categories).insert(CategoriesCompanion.insert(
          name: '购物',
          kind: 'expense',
          syncId: const Value('cat-local'),
        ));

    // 远端推一个不同 syncId 的同名分类
    provider.pushFakeChange(
      entityType: 'category',
      entitySyncId: 'cat-remote-x',
      payload: {
        'syncId': 'cat-remote-x',
        'name': '购物',
        'kind': 'expense',
        'level': 1,
      },
    );

    await engine.pull('');

    final rows = await (db.select(db.categories)
          ..where((c) => c.name.equals('购物')))
        .get();
    expect(rows, hasLength(1), reason: 'S10：不得产生同名重复行');
    expect(rows.single.syncId, 'cat-remote-x',
        reason: '远端权威 syncId 应收编到既有行上');
  });
}
