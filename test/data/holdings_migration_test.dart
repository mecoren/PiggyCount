/// v52 迁移：投资持仓表（含行情预留列）。
///
/// v52 新增 `holdings`（投资持仓），并一次性预留行情接入所需的字段：
/// - 可同步：`market`（行情市场标识）、`auto_quote`（该笔是否允许自动刷新）；
/// - **本地专有**：`quote_price` / `quote_fetched_at` / `quote_source_id`
///   （行情缓存，不进快照 / 不进指纹 / 不写 local_changes）。
///
/// 本文件覆盖三件事（沿用 migration_v51_test 的惯例）：
/// 1. 结构回归：新装库（onCreate createAll）里 holdings 的列/索引/触发器齐备；
/// 2. **升级路径真跑**：造一个 v51 形态库（只有 ledgers/accounts/transactions），
///    打开后 onUpgrade 的 v52 块必须建出表 + 两个索引；
/// 3. **幂等可重入**：把 user_version 退回 51 再开一次（模拟「上次迁移跑到一半
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

/// v52 建出的两个索引（与 db.dart 的 onUpgrade / onCreate 两处逐字对应）。
const _expectedIndexes = <String>[
  'idx_holdings_account',
  'uq_holdings_sync_id',
];

/// holdings 的**可同步列**（进快照 / 进指纹）。
const _syncedColumns = <String>[
  'id',
  'ledger_id',
  'account_id',
  'name',
  'symbol',
  'market',
  'asset_class',
  'currency',
  'quantity',
  'unit_cost',
  'unit_price',
  'auto_quote',
  'note',
  'sort_order',
  'sync_id',
  'created_at',
  'updated_at',
];

/// holdings 的**本地专有列**（行情缓存；绝不进快照 / 指纹 / local_changes）。
const _localOnlyColumns = <String>[
  'quote_price',
  'quote_fetched_at',
  'quote_source_id',
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

    test('holdings 表存在，可同步列与本地专有列齐备', () async {
      final cols = await tableColumns(db, 'holdings');
      for (final c in _syncedColumns) {
        expect(cols, contains(c), reason: 'holdings 缺可同步列 $c');
      }
      for (final c in _localOnlyColumns) {
        expect(cols, contains(c), reason: 'holdings 缺行情预留列 $c');
      }
      expect(db.schemaVersion, greaterThanOrEqualTo(52),
          reason: 'db.dart schemaVersion 不应低于 52');
    });

    test('两个索引与 updated_at 触碰触发器齐备', () async {
      final indexes = await indexNames(db);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i),
            reason: 'onCreate 漏建 $i —— 新装库会永久缺该索引（v48 教训）');
      }
      expect(await triggerNames(db), contains('trg_holdings_touch_updated_at'));
    });

    test('updated_at 触碰触发器生效：UPDATE 未显式写值时自动盖时间戳', () async {
      await db.into(db.accounts).insert(AccountsCompanion.insert(
            ledgerId: 0,
            name: '投资账户',
            type: const Value('investment'),
          ));
      final id = await db.into(db.holdings).insert(HoldingsCompanion.insert(
            accountId: 1,
            name: '贵州茅台',
            currency: const Value('CNY'),
          ));

      await db.customStatement(
          "UPDATE holdings SET quantity = 100 WHERE id = $id");

      final row = await (db.select(db.holdings)
            ..where((h) => h.id.equals(id)))
          .getSingle();
      expect(row.updatedAt, isNotNull, reason: '未显式写 updated_at 时应被触发器补齐');
    });
  });

  group('升级路径（onUpgrade 真跑）', () {
    /// 造一个「v51 形态」的库文件：只建 v52 块会碰到的表，其余交给
    /// `_createUpdatedAtTouchTriggers` 的缺表守卫跳过。
    Future<File> writeV51ShapedDb(Directory dir) async {
      final path = '${dir.path}/old_v51.db';
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
      raw.execute('PRAGMA user_version = 51');
      raw.close();
      return File(path);
    }

    test('v51 → v52：建出 holdings 表 + 两个索引，且不动既有表数据', () async {
      final dir = await Directory.systemTemp.createTemp('piggy_v52_upgrade');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final file = await writeV51ShapedDb(dir);

      final upgraded = PiggyDatabase.forTesting(NativeDatabase(file));
      addTearDown(upgraded.close);
      await upgraded.customSelect('SELECT 1').get(); // 触发 open + migration

      final cols = await tableColumns(upgraded, 'holdings');
      for (final c in [..._syncedColumns, ..._localOnlyColumns]) {
        expect(cols, contains(c), reason: '升级路径缺列 $c');
      }
      final indexes = await indexNames(upgraded);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i), reason: '升级路径漏建索引 $i');
      }
      expect(await triggerNames(upgraded),
          contains('trg_holdings_touch_updated_at'));
      expect(upgraded.schemaVersion, greaterThanOrEqualTo(52));

      // 迁移是纯新增：既有表必须原样健在（不得为了建新表而重建/丢数据）。
      final ledgerCols = await tableColumns(upgraded, 'ledgers');
      expect(ledgerCols, contains('month_start_day'));
      expect(ledgerCols, contains('sync_id'));
    });

    test('幂等可重入：user_version 退回 51 再开一次不报错、状态一致', () async {
      final dir = await Directory.systemTemp.createTemp('piggy_v52_reentrant');
      addTearDown(() async {
        if (dir.existsSync()) await dir.delete(recursive: true);
      });
      final file = await writeV51ShapedDb(dir);

      final first = PiggyDatabase.forTesting(NativeDatabase(file));
      await first.customSelect('SELECT 1').get();
      final colsAfterFirst = await tableColumns(first, 'holdings');
      await first.close();

      // 模拟「上次迁移跑到一半失败、user_version 未前进」：表与索引已建好，
      // 但版本号还在 51 → 下次启动同一段会重跑，必须靠 IF NOT EXISTS /
      // 存在性检查稳住（否则 'table holdings already exists' 直接把启动卡死）。
      final raw = raw_sqlite3.sqlite3.open(file.path);
      raw.execute('PRAGMA user_version = 51');
      raw.close();

      final second = PiggyDatabase.forTesting(NativeDatabase(file));
      addTearDown(second.close);
      await second.customSelect('SELECT 1').get(); // 重跑 v52 块

      expect(await tableColumns(second, 'holdings'), colsAfterFirst,
          reason: '重跑不得改变表结构');
      final indexes = await indexNames(second);
      for (final i in _expectedIndexes) {
        expect(indexes, contains(i), reason: '重跑后索引仍在');
      }
    });
  });
}
