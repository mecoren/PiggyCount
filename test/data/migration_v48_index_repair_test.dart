// v48 索引修复型迁移：补建 6 个「只在 onUpgrade 历史分支建过、onCreate
// 从未建」的索引。
//
// 缺陷背景（2026-09-26 双端同步回归实测发现）：
// `idx_transaction_tags_transaction` / `idx_transaction_tags_tag`（v10）、
// `idx_budgets_ledger` / `idx_budgets_category` / `idx_budgets_ledger_type`
// （v11）、`idx_attachments_transaction`（v12）只在对应 onUpgrade 分支创建。
// 任何**新装**（走 onCreate）或版本已越过 v12 的用户都永久缺失这些索引：
// 全新安装库实测只有 23 个索引，EXPLAIN QUERY PLAN 对
// `WHERE transaction_id IN (...)` 报 `SCAN transaction_tags` —— 合并路径每
// 账本 tag 批量读因此有 ~0.3~0.6 s 固定成本（6 个 id 与 102 个 id 耗时几乎
// 相同，代价由全表扫描决定）。
//
// 本测试锁死三件事：
// 1. onCreate（新装路径）必须建齐这 6 个索引；
// 2. onUpgrade（存量库路径）必须补建，且是幂等可重入的；
// 3. 关键查询必须命中索引而非全表扫描（环境无关的 EXPLAIN 断言）。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

/// onCreate 与 onUpgrade v48 必须一致建齐的索引（与
/// `PiggyDatabase._v48RepairIndexes` 同名同集）。
const _v48Indexes = <String>[
  'idx_transaction_tags_transaction',
  'idx_transaction_tags_tag',
  'idx_budgets_ledger',
  'idx_budgets_category',
  'idx_budgets_ledger_type',
  'idx_attachments_transaction',
];

/// 与 `PiggyDatabase._v48RepairIndexes` 等价的 DDL（幂等测试用）。
const _v48Ddl = <String>[
  'CREATE INDEX IF NOT EXISTS idx_transaction_tags_transaction '
      'ON transaction_tags(transaction_id);',
  'CREATE INDEX IF NOT EXISTS idx_transaction_tags_tag '
      'ON transaction_tags(tag_id);',
  'CREATE INDEX IF NOT EXISTS idx_budgets_ledger ON budgets(ledger_id);',
  'CREATE INDEX IF NOT EXISTS idx_budgets_category ON budgets(category_id);',
  'CREATE INDEX IF NOT EXISTS idx_budgets_ledger_type '
      'ON budgets(ledger_id, type);',
  'CREATE INDEX IF NOT EXISTS idx_attachments_transaction '
      'ON transaction_attachments(transaction_id);',
];

Future<Set<String>> _indexNames(PiggyDatabase db) async {
  final rows = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type='index' "
          "AND sql IS NOT NULL")
      .get();
  return rows.map((r) => r.read<String>('name')).toSet();
}

Future<String> _planOf(PiggyDatabase db, String sql) async {
  final rows = await db.customSelect('EXPLAIN QUERY PLAN $sql').get();
  return rows.map((r) => r.read<String>('detail')).join('\n');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('v48 onCreate: 全新安装库具备全部 6 个修复索引', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    final names = await _indexNames(db);
    for (final idx in _v48Indexes) {
      expect(names, contains(idx),
          reason: 'onCreate 必须建 $idx —— 新装用户走 onCreate 而非 onUpgrade，'
              '漏建即该索引永久缺失');
    }
  });

  test('v48 onUpgrade: 存量库（v47 且索引被删）升级后索引补齐', () async {
    final dir = await Directory.systemTemp.createTemp('pgy_v48_test');
    final file = File('${dir.path}/test.db');

    // 1. 用当前版本建全量 schema，然后**模拟存量库**：
    //    删掉这 6 个索引（真实存量库从来就没有它们），并把 user_version 压回 47。
    final seed = PiggyDatabase.forTesting(NativeDatabase(file));
    await seed.customSelect('SELECT 1').get();
    for (final idx in _v48Indexes) {
      await seed.customStatement('DROP INDEX IF EXISTS $idx');
    }
    final afterDrop = await _indexNames(seed);
    for (final idx in _v48Indexes) {
      expect(afterDrop, isNot(contains(idx)),
          reason: '前置条件：模拟存量库时 $idx 应已不存在');
    }
    await seed.customStatement('PRAGMA user_version = 47;');
    await seed.close();

    // 2. 重新打开 → drift 检测 user_version(47) < schemaVersion(48) →
    //    跑 onUpgrade(from=47, to=48) 的 v48 分支
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    expect(db.schemaVersion, greaterThanOrEqualTo(48),
        reason: 'v48 迁移后 schemaVersion 应 ≥ 48');

    final names = await _indexNames(db);
    for (final idx in _v48Indexes) {
      expect(names, contains(idx),
          reason: '存量库升级后必须补建 $idx（版本已越过 v12，'
              'from < 10/11/12 分支永不执行）');
    }
  });

  test('v48 迁移幂等：重复执行等价 DDL 不报错且索引集合不变', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    final before = await _indexNames(db);
    // 再跑一遍等价 DDL（IF NOT EXISTS 幂等，模拟 onUpgrade partial state 重跑）
    for (final ddl in _v48Ddl) {
      await db.customStatement(ddl);
    }
    expect(await _indexNames(db), before);
  });

  test('v48 索引生效：tag 关联与附件查询走索引而非全表扫描', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customSelect('SELECT 1').get();
    addTearDown(() => db.close());

    // 造一点数据，保证 planner 有成本模型可依据
    await db.batch((b) {
      for (var i = 1; i <= 200; i++) {
        b.insert(db.transactionTags,
            TransactionTagsCompanion.insert(transactionId: i, tagId: i % 5 + 1));
        b.insert(
            db.transactionAttachments,
            TransactionAttachmentsCompanion.insert(
              transactionId: i,
              fileName: 'f$i.jpg',
            ));
      }
    });

    final tagPlan = await _planOf(
        db, 'SELECT * FROM transaction_tags WHERE transaction_id IN (1,2,3)');
    expect(tagPlan, contains('idx_transaction_tags_transaction'),
        reason: '按 transaction_id 取 tag 必须命中索引（此前实测 SCAN 全表）。'
            '实际计划:\n$tagPlan');

    final tagIdPlan = await _planOf(
        db, 'SELECT * FROM transaction_tags WHERE tag_id = 1');
    expect(tagIdPlan, contains('idx_transaction_tags_tag'),
        reason: '按 tag_id 反查交易必须命中索引。实际计划:\n$tagIdPlan');

    final attPlan = await _planOf(db,
        'SELECT * FROM transaction_attachments WHERE transaction_id = 1');
    expect(attPlan, contains('idx_attachments_transaction'),
        reason: '按 transaction_id 取附件必须命中索引。实际计划:\n$attPlan');

    final budgetPlan = await _planOf(
        db, 'SELECT * FROM budgets WHERE ledger_id = 1');
    expect(budgetPlan, contains('idx_budgets_ledger'),
        reason: '按 ledger_id 取预算必须命中索引。实际计划:\n$budgetPlan');
  });
}
