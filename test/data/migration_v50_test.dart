/// v50 迁移:DROP 死表 ledger_members。
///
/// ledger_members 是 PiggyCount Cloud 协作时代的账本成员镜像表(server
/// `LedgerMember` 的本地副本),全仓库零读写方 —— 仅 v24 建表,从未有写入方或
/// 读取方。云端协同下线且项目尚无老用户,本迁移统一 DROP。
///
/// - 新装库(onCreate createAll)不应再有该表
/// - schemaVersion ≥ 50
///
/// 升级路径(旧库带 ledger_members → onUpgrade DROP)无法用 create-all 内存库
/// 直接验证 —— onUpgrade 不会跑;DROP TABLE IF EXISTS 本身幂等,partial state
/// 重跑安全,此处只做结构回归(惯例同 migration_v37_test)。
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

  test('v50: 新 schema 不再创建 ledger_members 表', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='table' AND name='ledger_members'",
    ).get();
    expect(rows, isEmpty,
        reason: 'ledger_members 是零读写方的死表,v50 起 DROP;onCreate/createAll '
            '不得再创建它');
  });

  test('v50: 共享账本其余表仍健在(迁移误删防护)', () async {
    // 本轮只删 ledger_members;三张镜像表与 override 表按计划暂留。
    for (final table in [
      'shared_ledger_categories',
      'shared_ledger_accounts',
      'shared_ledger_tags',
      'transaction_tag_overrides',
    ]) {
      final rows = await db.customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' AND name='$table'",
      ).get();
      expect(rows, isNotEmpty, reason: '$table 按计划暂留,不得被误删');
    }
  });

  test('schemaVersion 已达 50 及以上', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(50),
        reason: 'db.dart schemaVersion 不应低于 50');
  });
}
