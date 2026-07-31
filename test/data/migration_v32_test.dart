// B 组迁移测试:v32 新增 idx_transactions_ledger_happened 复合索引。
//
// forTesting(NativeDatabase.memory()) 会跑到最新 schema,迁移完成后索引应存在。
// RED 状态:当前 schemaVersion=31,无该索引 → 测试失败。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('v32: transactions(ledger_id, happened_at) 复合索引存在', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_transactions_ledger_happened'",
    ).get();
    expect(rows, isNotEmpty,
        reason: 'v32 迁移应创建 idx_transactions_ledger_happened 复合索引');
  });

  test('schemaVersion 已升至 32', () async {
    expect(db.schemaVersion, 32,
        reason: 'db.dart schemaVersion 应为 32');
  });
}
