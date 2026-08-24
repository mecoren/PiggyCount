/// v37 迁移:DROP 死表 sync_state。
///
/// sync_state 是 Supabase 增量同步时代的服务端游标表(deviceId /
/// providerType / serverCursor),全仓库零读写方 —— 游标现由 SyncEngine
/// 内存 + entity_change_watermarks 承载。本迁移统一 DROP。
///
/// - 新装库(onCreate createAll)不应再有该表
/// - schemaVersion ≥ 37
///
/// 升级路径(旧库带 sync_state → onUpgrade DROP)无法用 create-all 内存库
/// 直接验证 —— onUpgrade 不会跑;DROP TABLE IF EXISTS 本身幂等,partial
/// state 重跑安全,此处只做结构回归(惯例同 migration_v33_test)。
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';

void main() {
  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  test('v37: 新 schema 不再创建 sync_state 表', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='sync_state'",
    ).get();
    expect(rows, isEmpty,
        reason: 'sync_state 是零读写方的死表,v37 起 DROP;onCreate/createAll '
            '不得再创建它');
  });

  test('v37: 核心同步表仍然健在(迁移误删防护)', () async {
    for (final table in [
      'local_changes',
      'entity_change_watermarks',
      'sync_pull_errors',
    ]) {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'",
      ).get();
      expect(rows, isNotEmpty, reason: '$table 是在用的同步表,不得被误删');
    }
  });

  test('schemaVersion 已达 37 及以上', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(37),
        reason: 'db.dart schemaVersion 不应低于 37');
  });
}
