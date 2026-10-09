/// v53 迁移：储蓄目标表（ledger-scoped，同步快照 v12 的 `savingsGoals` 段）。
///
/// 本文件覆盖四件事（沿用 holdings_migration_test 的惯例）：
/// 1. 结构回归：新装库（onCreate createAll）里 savings_goals 的列/索引/触发器齐备；
/// 2. **升级路径真跑**：造一个 v52 形态库（含 v52 的 holdings），打开后 onUpgrade
///    的 v53 块必须建出表 + 两个索引；
/// 3. **幂等可重入**：把 user_version 退回 52 再开一次（模拟「上次迁移跑到一半
///    失败、user_version 没前进」），必须不报错、状态一致；
/// 4. 触碰触发器：UPDATE 未显式写 updated_at 时自动盖时间戳。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite3;

import 'package:piggycount/data/db.dart';

/// v53 建出的两个索引（与 db.dart 的 onUpgrade / onCreate 两处逐字对应）。
const _expectedIndexes = <String>[
  'idx_savings_goals_ledger',
  'uq_savings_goals_sync_id',
];

/// savings_goals 的全部列（含本地审计列；同步字段的白名单由
/// `test/cloud/sync_contract_savings_goal_test.dart` 单独守门）。
const _expectedColumns = <String>[
  'id',
  'sync_id',
  'ledger_id',
  'name',
  'target_amount',
  'currency',
  'account_id',
  'saved_amount',
  'start_date',
  'target_date',
  'note',
  'sort_order',
  'created_at',
  'updated_at',
];

void main() {
  // 升级路径会真跑 onUpgrade → 迁移块内的 logger 需要 binding 与
  // SharedPreferences mock（惯例同其它会走迁移的测试）。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Future<Set<String>> tableColumns(PiggyDatabase db, String table) async {
    final cols = await db.customSelect('PRAGMA table_info($table)').get();
    return cols.map((r) => r.read<String>('name')).toSet();
  }

  Future<Set<String>> indexNames(PiggyDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='index'")
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  Future<Set<String>> triggerNames(PiggyDatabase db) async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='trigger'")
        .get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  group('新装库（onCreate）', () {
    late PiggyDatabase db;

    setUp(() {
      db = PiggyDatabase.forTesting(NativeDatabase.memory());
    });

    tearDown(() async => db.close());

    test('savings_goals 表存在且列齐备', () async {
      final cols = await tableColumns(db, 'savings_goals');
      for (final c in _expectedColumns) {
        expect(cols, contains(c), reason: 'savings_goals 缺列 $c');
      }
      expect(db.schemaVersion, greaterThanOrEqualTo(53),
          reason: 'db.dart schemaVersion 不应低于 53');
    });

    test('两个索引与 updated_at 触碰触发器齐备', () async {
      final indexes = await indexNames(db);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i),
            reason: 'onCreate 漏建 $i —— 新装库会永久缺该索引（v48 教训）');
      }
      expect(
          await triggerNames(db), contains('trg_savings_goals_touch_updated_at'));
    });

    test('updated_at 触碰触发器生效：UPDATE 未显式写值时自动盖时间戳', () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      final id = await db.into(db.savingsGoals).insert(
            SavingsGoalsCompanion.insert(
              ledgerId: 1,
              name: '日本旅行',
              targetAmount: 20000,
            ),
          );

      await db.customStatement(
          'UPDATE savings_goals SET saved_amount = 3500 WHERE id = $id');

      final row = await (db.select(db.savingsGoals)
            ..where((g) => g.id.equals(id)))
          .getSingle();
      expect(row.savedAmount, 3500);
      expect(row.updatedAt, isNotNull, reason: '未显式写 updated_at 时应被触发器补齐');
    });

    test('sync_id 唯一索引生效：同一 syncId 插两次被拒', () async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
      Future<void> insertWith(String syncId) => db
          .into(db.savingsGoals)
          .insert(SavingsGoalsCompanion.insert(
            ledgerId: 1,
            name: 'x',
            targetAmount: 1,
            syncId: Value(syncId),
          ));

      await insertWith('dup-1');
      await expectLater(insertWith('dup-1'), throwsA(anything));
    });
  });

  group('升级路径（onUpgrade 真跑）', () {
    /// 造一个「v52 形态」的库文件：只建 v53 块会碰到的表（含 v52 的 holdings），
    /// 其余交给 `_createUpdatedAtTouchTriggers` 的缺表守卫跳过。
    Future<File> writeV52ShapedDb(Directory dir) async {
      final path = '${dir.path}/old_v52.db';
      final raw = raw_sqlite3.sqlite3.open(path);
      raw.execute('CREATE TABLE ledgers ('
          'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, '
          'currency TEXT NOT NULL, type TEXT NOT NULL, created_at INTEGER NOT NULL, '
          'sync_id TEXT, month_start_day INTEGER NOT NULL, updated_at INTEGER)');
      raw.execute('CREATE TABLE accounts ('
          'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
          'name TEXT NOT NULL, type TEXT NOT NULL, currency TEXT NOT NULL, '
          'initial_balance REAL NOT NULL, created_at INTEGER, updated_at INTEGER, '
          'sort_order INTEGER NOT NULL, sync_id TEXT, hidden INTEGER NOT NULL)');
      raw.execute('CREATE TABLE transactions ('
          'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
          'type TEXT NOT NULL, amount REAL NOT NULL, happened_at INTEGER NOT NULL, '
          'sync_id TEXT)');
      raw.execute('CREATE TABLE holdings ('
          'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL DEFAULT 0, '
          'account_id INTEGER NOT NULL, name TEXT NOT NULL, quantity REAL NOT NULL DEFAULT 0, '
          'unit_cost REAL NOT NULL DEFAULT 0, unit_price REAL NOT NULL DEFAULT 0, '
          'currency TEXT NOT NULL DEFAULT \'CNY\', sync_id TEXT, updated_at INTEGER)');
      raw.execute('PRAGMA user_version = 52');
      raw.close();
      return File(path);
    }

    test('v52 → v53：建出 savings_goals 表 + 两个索引，且不动既有表', () async {
      final dir = await Directory.systemTemp.createTemp('piggy_v53_upgrade');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final file = await writeV52ShapedDb(dir);

      final upgraded = PiggyDatabase.forTesting(NativeDatabase(file));
      addTearDown(upgraded.close);
      await upgraded.customSelect('SELECT 1').get(); // 触发 open + migration

      final cols = await tableColumns(upgraded, 'savings_goals');
      for (final c in _expectedColumns) {
        expect(cols, contains(c), reason: '升级路径缺列 $c');
      }
      final indexes = await indexNames(upgraded);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i), reason: '升级路径漏建索引 $i');
      }
      expect(await triggerNames(upgraded),
          contains('trg_savings_goals_touch_updated_at'));
      expect(upgraded.schemaVersion, greaterThanOrEqualTo(53));

      // 迁移是纯新增：既有表必须原样健在（不得为了建新表而重建/丢数据）。
      expect(await tableColumns(upgraded, 'holdings'), contains('account_id'));
      final ledgerCols = await tableColumns(upgraded, 'ledgers');
      expect(ledgerCols, contains('month_start_day'));
    });

    test('幂等可重入：user_version 退回 52 再开一次不报错、状态一致', () async {
      final dir = await Directory.systemTemp.createTemp('piggy_v53_reentrant');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final file = await writeV52ShapedDb(dir);

      final first = PiggyDatabase.forTesting(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      final colsAfterFirst = await tableColumns(first, 'savings_goals');
      await first.close();

      // 模拟「上次迁移跑到一半失败、user_version 未前进」：表与索引已建好，
      // 但版本号还在 52 → 下次启动同一段会重跑，必须靠 IF NOT EXISTS /
      // 存在性检查稳住（否则 'table savings_goals already exists' 直接把启动卡死）。
      final raw = raw_sqlite3.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 52');
      raw.close();

      final second = PiggyDatabase.forTesting(NativeDatabase(file));
      addTearDown(second.close);
      await second.customSelect('SELECT 1').get(); // 重跑 v53 块

      expect(await tableColumns(second, 'savings_goals'), colsAfterFirst,
          reason: '重跑不得改变表结构');
      final indexes = await indexNames(second);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i), reason: '重跑后索引仍在');
      }
    });
  });
}
