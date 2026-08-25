/// H1（audit S5 修复）：无 syncId 本地交易的业务键兜底配对与身份认领。
///
/// 修复前：computeDiff 的 localBySyncId 只收录有 syncId 的本地行，
/// 云端同业务内容版本被误判 added → 恢复合并时重复插入。
/// 修复后：
/// - 业务键 (happenedAt秒, amount, note) 在本地位唯一时配对为 modified；
/// - 内容一致也产出一条「绑定云端身份」的 modified（否则伪差异每轮重现）；
/// - apply 阶段先认领 syncId 再走按 syncId 的批量更新；
/// - 认领失败（已有身份/身份被占用）整条放弃，不新增不覆盖。
library;

import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;
  final at = DateTime(2026, 8, 25, 10, 30, 0);

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  Future<void> addLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  Future<int> addLocalTx({
    String? syncId,
    double amount = 10.0,
    String? note,
    DateTime? happenedAt,
  }) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: amount,
            note: drift.Value(note),
            happenedAt: drift.Value(happenedAt ?? at),
            syncId: drift.Value(syncId),
          ));

  ImportTransaction cloudTx({
    String? syncId,
    double amount = 10.0,
    String? note,
    bool excludeFromStats = false,
  }) =>
      ImportTransaction(
        type: 'expense',
        amount: amount,
        happenedAt: at,
        note: note,
        syncId: syncId,
        excludeFromStats: excludeFromStats,
      );

  Future<Transaction> getTx(int id) async =>
      (await (db.select(db.transactions)..where((t) => t.id.equals(id)))
              .get())
          .single;

  test('业务键唯一匹配 + 内容一致 → 单条 modified 认领，apply 后无重复行且获得 syncId',
      () async {
    await addLedger();
    final localId = await addLocalTx(note: '午餐');

    final preview = await service.computeDiff(
        repo: repo, ledgerId: 1, cloudTransactions: [cloudTx(syncId: 'c-1', note: '午餐')]);

    expect(preview, isNotNull);
    expect(preview!.addedCount, 0, reason: 'H1：不得把同内容云端版本判为 added');
    expect(preview.modifiedCount, 1);
    expect(preview.changes.single.localTransaction!.id, localId);

    await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: preview.changes,
      importData: const ImportData(),
    );

    final rows = await db.select(db.transactions).get();
    expect(rows.length, 1, reason: '认领合并不得产生重复交易');
    expect(rows.single.syncId, 'c-1');
    expect((await getTx(localId)).id, localId);
  });

  test('业务键唯一匹配 + 非键字段不同 → modified（非重复 added），apply 更新并认领',
      () async {
    await addLedger();
    final localId = await addLocalTx(note: '午餐');

    // 键字段（时间/金额/note）一致，仅账单标记不同 → 应配对为 modified
    final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [
          cloudTx(syncId: 'c-2', note: '午餐', excludeFromStats: true)
        ]);

    expect(preview!.addedCount, 0);
    final change = preview.changes.single;
    expect(change.type, SyncChangeType.modified);
    expect(change.diffDetails.join(), contains('不计入统计'));

    final result = await service.applySyncChanges(
      repo: repo,
      ledgerId: 1,
      selectedChanges: [change],
      importData: const ImportData(),
    );

    expect(result.modifiedCount, 1);
    final rows = await db.select(db.transactions).get();
    expect(rows.length, 1);
    expect(rows.single.syncId, 'c-2');
    expect(rows.single.excludeFromStats, isTrue);
    expect((await getTx(localId)).id, localId);
  });

  test('键字段本身不同（note 差异）→ 保守回退 added，不强行配对', () async {
    // 已知限制（刻意取舍）：业务键含 note，note 不同的行无法经键配对，
    // 维持旧行为判为 added —— 强行按「时间+金额」宽松配对会把同秒同额、
    // 备注不同的两笔合法交易误合并（覆盖备注），风险大于重复插入。
    await addLedger();
    await addLocalTx(note: '午餐');

    final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: [cloudTx(syncId: 'c-4', note: '晚餐')]);

    expect(preview!.addedCount, 1);
    expect(preview.modifiedCount, 0);
  });

  test('业务键歧义（两条本地同键）→ 回退旧行为判为 added，不强行配对', () async {
    await addLedger();
    await addLocalTx(note: '午餐');
    await addLocalTx(note: '午餐');

    final preview = await service.computeDiff(
        repo: repo, ledgerId: 1, cloudTransactions: [cloudTx(syncId: 'c-3', note: '午餐')]);

    expect(preview!.addedCount, 1);
    expect(preview.modifiedCount, 0);
  });

  test('认领失败（syncId 已被其他行占用）→ 放弃该变更，不覆盖不新增', () async {
    await addLedger();
    final holderId = await addLocalTx(syncId: 'occupied', note: '午餐');
    await addLocalTx(note: '午餐');

    final preview = await service.computeDiff(
        repo: repo, ledgerId: 1, cloudTransactions: [cloudTx(syncId: 'occupied', note: '午餐')]);
    // 本地已存在同 syncId 行 → 走正常 syncId 匹配，与本用例无关
    expect(preview!.changes.where((c) => c.type == SyncChangeType.added), isEmpty);

    // 直接验证 adopt 守卫：目标行无身份但 syncId 已被占用 → false
    final orphanId = await addLocalTx(note: '孤儿');
    final ok =
        await repo.adoptTransactionSyncId(orphanId, 'occupied');
    expect(ok, isFalse);
    expect((await getTx(orphanId)).syncId, isNull);
    expect((await getTx(holderId)).syncId, 'occupied');
  });

  test('adoptTransactionSyncId：目标行已有身份时拒绝覆盖', () async {
    await addLedger();
    final id = await addLocalTx(syncId: 'keep-me');

    final ok = await repo.adoptTransactionSyncId(id, 'new-id');
    expect(ok, isFalse);
    expect((await getTx(id)).syncId, 'keep-me');
  });
}
