/// v36 迁移（审计 S3）：entity_change_watermarks 表。
///
/// - 表存在（fresh schema 由 Table 定义建表；升级库由 onUpgrade createTable）
/// - 主键为 sync_id
/// - schemaVersion ≥ 36
///
/// 升级路径验证说明同 migration_v33_test.dart：onUpgrade 不会在 create-all
/// 内存库上运行，此处只做结构回归（新装/测试库走 onCreate → createAll）。
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

  test('v36: entity_change_watermarks 表存在', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' "
      "AND name='entity_change_watermarks'",
    ).get();
    expect(rows, isNotEmpty, reason: '审计 S3：实体水位表必须存在');
  });

  test('v36: entity_change_watermarks 主键为 sync_id 且可写', () async {
    await db.customStatement(
      "INSERT INTO entity_change_watermarks (sync_id, watermark) "
      "VALUES ('tx-1', 42)",
    );
    // 同主键覆盖写（insertOnConflictUpdate 的 DB 层前提）
    await db.customStatement(
      "INSERT OR REPLACE INTO entity_change_watermarks (sync_id, watermark) "
      "VALUES ('tx-1', 43)",
    );
    final row = await db.customSelect(
      "SELECT watermark FROM entity_change_watermarks WHERE sync_id = 'tx-1'",
    ).get();
    expect(row.single.read<int>('watermark'), 43,
        reason: 'sync_id 必须是主键，重复插入应覆盖而非新增');

    final pkCols = await db.customSelect(
      "SELECT name FROM pragma_table_info('entity_change_watermarks') "
      "WHERE pk > 0",
    ).get();
    expect(pkCols.map((r) => r.read<String>('name')), ['sync_id']);
  });

  test('schemaVersion 已达 36 及以上', () async {
    expect(db.schemaVersion, greaterThanOrEqualTo(36),
        reason: 'db.dart schemaVersion 不应低于 36');
  });
}
