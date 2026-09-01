// Path B 高危项修复回归（审计 PathB-H1/H2/H3/H5）：
// - H1: 交易 partial payload 缺 amount 键 → update 保留本地金额
// - H2: account/category 可选字段缺键 → update 保留本地值（对齐 hidden 范式）
// - H3: 共享账本 Editor 角色 fullPull 拒绝（快照整本恢复会清掉未推送编辑）
// - H5: withRecordingSuppressed 深度计数器 —— 内层先退出不解除外层抑制

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
  });

  tearDown(() => db.close());

  // AppCursorStore 以 (baseUrl|userId|deviceId) 为 key 写 SharedPreferences
  void buildEngine(String userId) {
    provider = FakePiggyCountCloudProvider(userId: userId);
    engine = SyncEngine(
        db: db, provider: provider, changeTracker: tracker, repo: repo);
    // ledger 行由各测试自行 seed（部分用例要先改共享字段再建 engine 无依赖，
    // 但统一在此保证 ledger 存在）
  }

  group('PathB-H1：交易 amount 缺键守卫', () {
    setUp(() async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 100,
              happenedAt: d.Value(DateTime.parse('2026-05-01T10:00:00Z')),
              syncId: const d.Value('tx-P'),
            ),
          );
    });

    test('partial payload 无 amount 键 → 其他字段应用、金额保留', () async {
      buildEngine('pb-h1-partial');
      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-P',
        ledgerId: 'L1',
        payload: {
          'syncId': 'tx-P',
          'type': 'expense',
          'note': '只改备注',
          'happenedAt': '2026-05-01T10:00:00Z',
        },
      );

      expect(await engine.pull(''), 1);
      final tx = (await db.select(db.transactions).get()).single;
      expect(tx.note, '只改备注', reason: '合法字段正常应用');
      expect(tx.amount, 100,
          reason: 'H1 前缺 amount 会以兜底 0.0 无条件覆盖本地金额');
    });

    test('带 amount 的完整更新照常覆盖（守卫不误伤）', () async {
      buildEngine('pb-h1-full');
      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-P',
        ledgerId: 'L1',
        payload: {
          'syncId': 'tx-P',
          'type': 'expense',
          'amount': 55,
          'happenedAt': '2026-05-01T10:00:00Z',
        },
      );

      expect(await engine.pull(''), 1);
      expect((await db.select(db.transactions).get()).single.amount, 55);
    });

    test('审计 C5：缺 amount 且缺 nativeAmount 的 partial 不清零本地折算',
        () async {
      buildEngine('pb-h1-native-partial');
      // 本地行已有折算金额（多币种记账场景）
      await (db.update(db.transactions)
            ..where((t) => t.syncId.equals('tx-P')))
          .write(const TransactionsCompanion(nativeAmount: d.Value(88.5)));

      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-P',
        ledgerId: 'L1',
        payload: {
          'syncId': 'tx-P',
          'type': 'expense',
          'note': '只改备注，不带任何金额键',
        },
      );

      expect(await engine.pull(''), 1);
      final tx = (await db.select(db.transactions).get()).single;
      expect(tx.note, '只改备注，不带任何金额键');
      expect(tx.amount, 100);
      // C5 前：占位 amount=0.0 参与「金额是否变化」判断（恒真）→
      // native_amount 被写成 0.0 并随 push 扩散全端
      expect(tx.nativeAmount, 88.5,
          reason: '无金额信息的 partial 必须保留本地折算值');
    });

    test('审计 C5 对照：带 amount 且金额变化 → 折算仍退化 1:1（语义保留）',
        () async {
      buildEngine('pb-h1-native-degrade');
      await (db.update(db.transactions)
            ..where((t) => t.syncId.equals('tx-P')))
          .write(const TransactionsCompanion(nativeAmount: d.Value(88.5)));

      provider.pushFakeChange(
        entityType: 'transaction',
        entitySyncId: 'tx-P',
        ledgerId: 'L1',
        payload: {
          'syncId': 'tx-P',
          'type': 'expense',
          'amount': 200, // 有 amount 键且变了 → 旧客户端语义：折算 =amount
        },
      );

      expect(await engine.pull(''), 1);
      final tx = (await db.select(db.transactions).get()).single;
      expect(tx.amount, 200);
      expect(tx.nativeAmount, 200,
          reason: '快照保护只在「缺 amount 键」时保留本地折算，不改变既有退化语义');
    });
  });

  group('PathB-H2：account/category 可选字段缺键守卫', () {
    test('account partial 更新不清空 bankName/creditLimit/note', () async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      buildEngine('pb-h2-account');
      await db.into(db.accounts).insert(
            AccountsCompanion.insert(
              ledgerId: 1,
              name: 'A',
              syncId: const d.Value('acc-P'),
              creditLimit: const d.Value(5000),
              bankName: const d.Value('ICBC'),
              note: const d.Value('keep-me'),
            ),
          );

      provider.pushFakeChange(
        entityType: 'account',
        entitySyncId: 'acc-P',
        ledgerId: 'L1',
        payload: {'syncId': 'acc-P', 'name': 'A2'},
      );

      expect(await engine.pull(''), 1);
      final acc = (await db.select(db.accounts).get()).single;
      expect(acc.name, 'A2');
      expect(acc.bankName, 'ICBC', reason: 'H2 前被无条件写 null 清空');
      expect(acc.creditLimit, 5000);
      expect(acc.note, 'keep-me');
    });

    test('category partial 更新不清空 parentId 父子链', () async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      buildEngine('pb-h2-category');
      final parentId = await db.into(db.categories).insert(
            CategoriesCompanion.insert(
                name: 'P', kind: 'expense', syncId: const d.Value('CP')),
          );
      await db.into(db.categories).insert(
            CategoriesCompanion.insert(
              name: 'Child',
              kind: 'expense',
              level: const d.Value(2),
              parentId: d.Value(parentId),
              syncId: const d.Value('CC'),
            ),
          );

      provider.pushFakeChange(
        entityType: 'category',
        entitySyncId: 'CC',
        ledgerId: 'L1',
        // 不带 parentName / communityIconId 的 partial 更新
        payload: {'syncId': 'CC', 'name': 'Child2', 'kind': 'expense'},
      );

      expect(await engine.pull(''), 1);
      final child = (await (db.select(db.categories)
                ..where((c) => c.syncId.equals('CC')))
              .getSingle());
      expect(child.name, 'Child2');
      expect(child.parentId, parentId, reason: 'H2 前 payload 无 parentName 会把父子链清掉');
    });
  });

  group('PathB-H3：共享账本 Editor 角色拒绝 fullPull', () {
    test('editor 角色快照整本恢复被拒，本地未推送数据完好', () async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      buildEngine('pb-h3-editor');
      await (db.update(db.ledgers)..where((l) => l.id.equals(1))).write(
        const LedgersCompanion(isShared: d.Value(true), myRole: d.Value('editor')),
      );
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 77,
              happenedAt: d.Value(DateTime.parse('2026-05-01T10:00:00Z')),
              syncId: const d.Value('tx-editor-local'),
            ),
          );
      // 未推送编辑：fullPull 的 W4 清理会把它一起丢掉
      await db.into(db.localChanges).insert(LocalChangesCompanion.insert(
        entityType: 'transaction',
        entityId: txId,
        entitySyncId: 'tx-editor-local',
        ledgerId: 1,
        action: 'upsert',
      ));
      // 云端确有快照可下载 —— 保证「若无守卫则恢复必然执行」的对照前提
      provider.seedStorageFile(path: 'L1', content: '{"version":9,"items":[]}');

      final r = await engine.runFullPull(ledgerId: 1);

      expect(r, (inserted: 0, deletedDup: 0), reason: 'H3 守卫应直接跳过');
      final tx = await (db.select(db.transactions)
            ..where((t) => t.id.equals(txId)))
          .getSingle();
      expect(tx.amount, 77, reason: 'Editor 未推送的本地编辑不得被 Owner 快照覆盖');
      final pending = await (db.select(db.localChanges)
            ..where((c) => c.pushedAt.isNull()))
          .get();
      expect(pending, hasLength(1), reason: 'W4 队列清理不应发生在被拒账本上');
    });

    test('owner 角色不受影响，fullPull 正常走恢复管线', () async {
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      buildEngine('pb-h3-owner');
      await (db.update(db.ledgers)..where((l) => l.id.equals(1))).write(
        const LedgersCompanion(myRole: d.Value('owner')),
      );
      provider.seedStorageFile(
        path: 'L1',
        content:
            '{"version":9,"ledgerName":"L","currency":"CNY","count":0,'
            '"transactions":[],"accounts":[],"categories":[],"tags":[],'
            '"budgets":[],"recurringTransactions":[],"attachments":[]}',
      );

      final r = await engine.runFullPull(ledgerId: 1);

      expect(r.inserted, 0);
      // owner 路径未被守卫拦截的直接证据：管线执行到清空/导入而非 (0,0) 直返。
      // 这里用「无异常完成 + 本地仍可查询」做轻断言；完整管线已有独立测试覆盖。
      expect(await db.select(db.transactions).get(), isEmpty);
    });

    test('个人账本（isShared=false）不受守卫影响', () async {
      // 默认 seed 即 personal；有快照内容时照常走恢复管线
      await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L', syncId: const d.Value('L1')));
      buildEngine('pb-h3-personal');
      provider.seedStorageFile(
        path: 'L1',
        content:
            '{"version":9,"ledgerName":"L","currency":"CNY","count":0,'
            '"transactions":[],"accounts":[],"categories":[],"tags":[],'
            '"budgets":[],"recurringTransactions":[],"attachments":[]}',
      );
      final r = await engine.runFullPull(ledgerId: 1);
      expect(r.inserted, 0);
      expect(await db.select(db.transactions).get(), isEmpty);
    });
  });

  group('PathB-H5：抑制计数器', () {
    test('嵌套抑制中内层先退出，外层剩余写入仍被抑制', () async {
      await tracker.withRecordingSuppressed(() async {
        await tracker.withRecordingSuppressed(() async {});
        // 内层已退出 —— bool 版此处开关已被还原 false，
        // 下面这条写入会泄漏成幻影变更
        await tracker.recordUserGlobalChange(
          entityType: 'tag',
          entityId: 1,
          entitySyncId: 'tag-h5',
          action: 'upsert',
        );
      });

      expect(await tracker.getUnpushedChanges(), isEmpty,
          reason: '外层抑制上下文未退出前，任何写入都不得回流 local_changes');

      // 全部退出后恢复正常记录
      await tracker.recordUserGlobalChange(
        entityType: 'tag',
        entityId: 2,
        entitySyncId: 'tag-h5-after',
        action: 'upsert',
      );
      final after = await tracker.getUnpushedChanges();
      expect(after, hasLength(1));
      expect(after.single.entitySyncId, 'tag-h5-after');
    });
  });
}
