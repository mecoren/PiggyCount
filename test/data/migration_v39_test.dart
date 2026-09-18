/// v39 迁移: local_changes (ledger_id, pushed_at) 查询索引（审计 C7）。
///
/// push 前取队列（getUnpushedChangesForLedger）、方向仲裁证据
/// （TransactionsSyncManager._localChangeEvidence 的 unpushed 计数）、
/// 恢复清队列（_purgeStaleLocalChanges）都高频走
/// `WHERE ledger_id IN (?, 0) [AND pushed_at IS NULL]`。
/// v35 部分唯一索引列序 (entity_type, entity_sync_id, action) 对
/// ledger_id 过滤毫无帮助，长期运行设备上已推送行累积（保留 7 天）后
/// 每次同步前查询退化为全表扫描。
///
/// - 新装库（onCreate）同样创建该索引
/// - EXPLAIN QUERY PLAN 验证 unpushed 查询命中该索引
library;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('schemaVersion 已达 39 及以上', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(39),
        reason: 'db.dart schemaVersion 不应低于 39');
  });

  test('v39: idx_local_changes_ledger_pushed 索引已创建（onCreate 路径）',
      () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_local_changes_ledger_pushed'",
    ).get();
    expect(rows, isNotEmpty, reason: '缺少 idx_local_changes_ledger_pushed');
  });

  test('v39: unpushed 队列查询命中新索引（EXPLAIN QUERY PLAN）', () async {
    // 造一批数据让优化器有统计可用
    await db.customStatement(
      "INSERT INTO ledgers (name, currency, created_at) "
      "VALUES ('默认', 'CNY', 0)",
    );
    for (var i = 0; i < 50; i++) {
      await db.customStatement(
        "INSERT INTO local_changes (entity_type, entity_id, entity_sync_id, "
        "ledger_id, action, created_at) "
        "VALUES ('transaction', $i, 'sid-$i', 1, 'create', 0)",
      );
    }
    final plan = await db.customSelect(
      "EXPLAIN QUERY PLAN SELECT id FROM local_changes "
      "WHERE pushed_at IS NULL AND ledger_id IN (1, 0)",
    ).get();
    final planText =
        plan.map((r) => r.data['detail'].toString()).join('\n');
    expect(planText, contains('idx_local_changes_ledger_pushed'),
        reason: '查询计划应使用 v39 新索引:\n$planText');
  });
}
