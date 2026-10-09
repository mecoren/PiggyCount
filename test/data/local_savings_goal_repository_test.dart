/// v53 储蓄目标仓储契约（SavingsGoalRepository / LocalRepository 委托层）。
///
/// 重点保护四件事：
/// 1. **ledger-scoped 作用域**：所有变更必须记到 `local_changes.ledger_id =
///    所属账本`（**不是 0**）—— 记错作用域会让变更卡在本地永不推送；
/// 2. **删除前预读 syncId**：删完读不到，漏了就对端删不掉；
/// 3. **账户删除是置空引用**（目标降级为手动模式）而非级联删除，且要记一条
///    update —— 否则对端仍按已被删除的账户算进度；
/// 4. tracker 为 null 时优雅跳过、不抛。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  /// 清空已产生的变更，只观察被测动作。
  Future<void> clearChanges() async {
    await tracker.markPushed(
      (await tracker.getUnpushedChanges()).map((c) => c.id).toList(),
    );
  }

  /// 取目标的 syncId（删除类用例必须在动手前先取）。
  Future<String> syncIdOf(int id) async {
    final row = await repo.getSavingsGoal(id);
    expect(row, isNotNull, reason: '取 syncId 前目标应存在');
    return row!.syncId!;
  }

  /// 断言某目标有一条未推送变更，且在 **ledger-scoped** 通道。
  Future<void> expectGoalChange(String syncId, String action) async {
    final changes = await tracker.getUnpushedChangesForLedger(1);
    final hit = changes.where((c) =>
        c.entityType == 'savings_goal' &&
        c.entitySyncId == syncId &&
        c.action == action);
    expect(
      hit,
      isNotEmpty,
      reason: 'savings_goal($syncId) 必须登记 $action 变更到所属账本通道，'
          '实际未推送变更: '
          '${changes.map((c) => '${c.entityType}/${c.action}@${c.ledgerId}').toList()}',
    );
    expect(hit.first.ledgerId, 1,
        reason: '储蓄目标是 ledger-scoped 实体，ledger_id 必须是所属账本（不是 0）');
  }

  group('创建 / 读取', () {
    test('创建：自动补 syncId 与默认值，可按账本读回', () async {
      final id = await repo.createSavingsGoal(
        ledgerId: 1,
        name: '日本旅行',
        targetAmount: 20000,
      );

      final row = await repo.getSavingsGoal(id);
      expect(row, isNotNull);
      expect(row!.ledgerId, 1);
      expect(row.name, '日本旅行');
      expect(row.targetAmount, 20000);
      expect(row.currency, 'CNY', reason: '未指定币种时的兜底默认');
      expect(row.accountId, isNull, reason: '默认手动模式');
      expect(row.savedAmount, 0);
      expect(row.startDate, isNotNull, reason: '起算日默认 now');
      expect(row.targetDate, isNull);
      expect(row.sortOrder, 0);
      expect(row.syncId, isNotNull);
      expect(row.syncId!.isNotEmpty, isTrue);
    });

    test('创建登记 upsert 变更（ledger-scoped 通道）', () async {
      final id = await repo.createSavingsGoal(
        ledgerId: 1,
        name: '换相机',
        targetAmount: 8000,
      );

      await expectGoalChange(await syncIdOf(id), 'upsert');
    });

    test('按账本读取只返回本账本的目标，按 sortOrder / id 排序', () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (2, 'L2', 'CNY')");
      final b2 = await repo.createSavingsGoal(
          ledgerId: 1, name: 'B-2', targetAmount: 1, sortOrder: 2);
      final a1 = await repo.createSavingsGoal(
          ledgerId: 1, name: 'A-1', targetAmount: 1, sortOrder: 1);
      final other = await repo.createSavingsGoal(
          ledgerId: 2, name: '别的账本', targetAmount: 1);

      final list = await repo.getSavingsGoalsByLedger(1);
      expect(list.map((g) => g.id).toList(), [a1, b2]);
      expect(list.map((g) => g.id), isNot(contains(other)));
    });

    test('watchSavingsGoalsByLedger 随写库自动刷新', () async {
      final stream = repo.watchSavingsGoalsByLedger(1);
      expect(await stream.first, isEmpty);

      await repo.createSavingsGoal(
          ledgerId: 1, name: '应急金', targetAmount: 30000);

      final after = await stream.first;
      expect(after, hasLength(1));
      expect(after.single.name, '应急金');
    });
  });

  group('更新', () {
    test('update 登记 upsert 变更', () async {
      final id = await repo.createSavingsGoal(
          ledgerId: 1, name: '日本旅行', targetAmount: 20000);
      final syncId = await syncIdOf(id);
      await clearChanges();

      await repo.updateSavingsGoal(id, name: '日本旅行（含机票）', targetAmount: 25000);

      final row = await repo.getSavingsGoal(id);
      expect(row!.name, '日本旅行（含机票）');
      expect(row.targetAmount, 25000);
      await expectGoalChange(syncId, 'upsert');
    });

    test('存入 / 取出（updateSavedAmount）登记 upsert 变更', () async {
      final id = await repo.createSavingsGoal(
          ledgerId: 1, name: '换相机', targetAmount: 8000);
      final syncId = await syncIdOf(id);
      await clearChanges();

      await repo.updateSavingsGoalSavedAmount(id, 1500);

      expect((await repo.getSavingsGoal(id))!.savedAmount, 1500);
      await expectGoalChange(syncId, 'upsert');
    });

    test('clearAccount 显式把 accountId 置空（切回手动模式）', () async {
      final accountId = await repo.createAccount(
          ledgerId: 1, name: '储蓄账户', type: 'bank');
      final id = await repo.createSavingsGoal(
          ledgerId: 1, name: '日本旅行', targetAmount: 20000, accountId: accountId);
      expect((await repo.getSavingsGoal(id))!.accountId, accountId);

      await repo.updateSavingsGoal(id, clearAccount: true);

      expect((await repo.getSavingsGoal(id))!.accountId, isNull);
    });

    test('不传的字段保持原值（null = 不改，不是清空）', () async {
      final id = await repo.createSavingsGoal(
        ledgerId: 1,
        name: '日本旅行',
        targetAmount: 20000,
        targetDate: DateTime(2027, 1, 1),
        note: '一家三口',
      );

      await repo.updateSavingsGoal(id, targetAmount: 25000);

      final row = await repo.getSavingsGoal(id);
      expect(row!.name, '日本旅行');
      expect(row.note, '一家三口');
      expect(row.targetDate, DateTime(2027, 1, 1));
    });
  });

  group('删除', () {
    test('delete 删除前预读 syncId 并登记 delete', () async {
      final id = await repo.createSavingsGoal(
          ledgerId: 1, name: '日本旅行', targetAmount: 20000);
      final syncId = await syncIdOf(id);
      await clearChanges();

      await repo.deleteSavingsGoal(id);

      expect(await repo.getSavingsGoal(id), isNull);
      await expectGoalChange(syncId, 'delete');
    });
  });

  group('账户删除的引用处理', () {
    test('删除账户 → 目标置空 accountId 并登记 update（不级联删除）', () async {
      final accountId = await repo.createAccount(
          ledgerId: 1, name: '储蓄账户', type: 'bank');
      final id = await repo.createSavingsGoal(
        ledgerId: 1,
        name: '日本旅行',
        targetAmount: 20000,
        accountId: accountId,
        savedAmount: 1200,
      );
      final syncId = await syncIdOf(id);
      await clearChanges();

      await repo.deleteAccount(accountId);

      final row = await repo.getSavingsGoal(id);
      expect(row, isNotNull, reason: '目标必须保留（降级为手动模式）');
      expect(row!.accountId, isNull);
      expect(row.savedAmount, 1200, reason: '手动累计额不受影响');
      await expectGoalChange(syncId, 'upsert');
    });

    test('clearSavingsGoalAccountRefs 只影响该账户的目标', () async {
      final a = await repo.createAccount(ledgerId: 1, name: 'A', type: 'bank');
      final b = await repo.createAccount(ledgerId: 1, name: 'B', type: 'bank');
      final ga = await repo.createSavingsGoal(
          ledgerId: 1, name: 'A 的目标', targetAmount: 1, accountId: a);
      final gb = await repo.createSavingsGoal(
          ledgerId: 1, name: 'B 的目标', targetAmount: 1, accountId: b);

      expect(await repo.clearSavingsGoalAccountRefs(a), 1);

      expect((await repo.getSavingsGoal(ga))!.accountId, isNull);
      expect((await repo.getSavingsGoal(gb))!.accountId, b);
    });
  });

  group('无 tracker', () {
    test('CRUD 全部正常，不抛异常（快照链路正常装配即无 tracker）', () async {
      final plain = LocalRepository(db);
      final id = await plain.createSavingsGoal(
          ledgerId: 1, name: '应急金', targetAmount: 30000);
      await plain.updateSavingsGoal(id, targetAmount: 35000);
      await plain.updateSavingsGoalSavedAmount(id, 5000);
      await plain.deleteSavingsGoal(id);
      expect(await plain.getSavingsGoal(id), isNull);
    });
  });
}
