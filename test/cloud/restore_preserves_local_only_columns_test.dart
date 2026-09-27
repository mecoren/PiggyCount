/// P1-5 回归：全量恢复必须保留「本机专属列」。
///
/// 【问题】
/// `created_by_user_id` / `last_edited_by_user_id` 从不出现在云快照里
/// （`transactions_json.dart` 的 item map 没有这两个键），而全量恢复
/// （`restoreLedgerFromJson`）是**清空后重建行**：先
/// `clearLedgerTransactions`（DELETE）再 `importTransactionsJson`（INSERT），
/// 重建用的 `TransactionsCompanion.insert` 不含这两列 → 本机值被静默清空。
///
/// 2026-09-27 设备端实测：A 端「全量下载」后 `created_by` 非空行 **5075 → 0**
/// （对照组：走增量合并的「下载同步」是 5075 → 5075 不变，因为
/// `TransactionUpdateBySyncIdData` 里根本没有这两列）。
///
/// 语义上这属于"本机专属信息被远端覆盖"：**云端从未对这两列表达过意见**
/// —— 快照不携带它们 —— 恢复不应让它们丢失。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart'
    show restoreLedgerFromJson;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });
  tearDown(() async => db.close());

  Future<void> seed() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    // 有 syncId 且带本机列（应被保留）
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, sync_id, "
        "created_by_user_id, last_edited_by_user_id) "
        "VALUES (1, 1, 'expense', 100.0, 'tx-a', 'user-A', 'user-A')");
    // 有 syncId 但本机列为 NULL（无需回填）
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, sync_id) "
        "VALUES (2, 1, 'expense', 50.0, 'tx-b')");
    // 无 syncId（没有稳定身份，无法回填；行为与改动前一致）
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, "
        "created_by_user_id) VALUES (3, 1, 'expense', 10.0, 'user-C')");
  }

  test('恢复后 created_by / last_edited_by 按 syncId 保留', () async {
    await seed();
    // 快照来自同一库 —— 关键是它**不携带**这两列（导出侧本就不写）
    final exported = await exportTransactionsJson(db, 1);
    expect(exported.jsonStr.contains('createdByUserId'), isFalse,
        reason: '前置条件：云快照从不携带本机专属列');

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: 1, jsonStr: exported.jsonStr);
    expect(result, isNotNull, reason: '快照非空，不应被守卫拒绝');

    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(1)))
        .get();

    final a = rows.firstWhere((r) => r.syncId == 'tx-a');
    expect(a.createdByUserId, 'user-A',
        reason: '有 syncId 的行必须按 syncId 回填本机创建人，'
            '否则「全量下载」会把本机专属信息抹掉（实测 5075 → 0）');
    expect(a.lastEditedByUserId, 'user-A');

    final b = rows.firstWhere((r) => r.syncId == 'tx-b');
    expect(b.createdByUserId, isNull);

    // 无 syncId 的行：身份不稳定，无法匹配（与改动前行为一致）
    final c = rows.firstWhere((r) => r.amount == 10.0);
    expect(c.createdByUserId, isNull,
        reason: '无 syncId 的行不参与回填（无法可靠配对），属已知边界');
  });

  test('幂等：连续恢复两次结果一致', () async {
    await seed();
    final exported = await exportTransactionsJson(db, 1);
    for (var i = 0; i < 2; i++) {
      await restoreLedgerFromJson(
          db: db, repo: repo, ledgerId: 1, jsonStr: exported.jsonStr);
    }
    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(1)))
        .get();
    // 3 行：前两行带快照里的 syncId；第三行本地无 syncId、快照亦未写该键，
    // 恢复时按 importTransactionsJson 的约定生成新 UUID（既有行为，每次恢复
    // 都重建一次，但下一轮导出后即稳定）。
    expect(rows.length, 3, reason: '恢复=清空+重建，行数取决于快照条目数');
    expect(rows.firstWhere((r) => r.syncId == 'tx-a').createdByUserId, 'user-A',
        reason: '连续恢复两次也必须保留本机专属列（回填是幂等的）');
  });

}
