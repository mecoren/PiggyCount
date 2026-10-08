/// v51 迁移:共享账本残留整体移除。
///
/// 共享账本协作(PiggyCount Cloud)已整体下线且项目无老用户,v51 统一 DROP:
/// - 四张死表:`shared_ledger_categories` / `shared_ledger_accounts` /
///   `shared_ledger_tags`(镜像表,已无写入方恒空)、`transaction_tag_overrides`;
/// - `ledgers` 四列:`my_role` / `member_count` / `is_shared` / `owner_user_id`;
/// - `transactions` 四列:`category_sync_id_override` /
///   `account_sync_id_override` / `to_account_sync_id_override` /
///   `tag_sync_ids_override`(死列)。
///
/// - 新装库(onCreate createAll)不应再有上述表/列
/// - schemaVersion ≥ 51
///
/// 升级路径(旧库带这些表/列 → onUpgrade DROP)无法用 create-all 内存库直接验证
/// —— onUpgrade 不会跑。这里补三件事:
/// 1. 结构回归(新 schema 无这些表/列),惯例同 migration_v37/v50;
/// 2. **保留列防护**:`created_by_user_id` / `last_edited_by_user_id`(CSV 导入
///    导出仍在写)、`month_start_day`、`transaction_tags` / `tags`(快照
///    `tagSyncIds` 契约依赖)必须健在;
/// 3. **引擎能力回归**:v51 依赖 `ALTER TABLE ... DROP COLUMN`(SQLite 3.35+),
///    本机跑的是 sqlcipher 引擎 —— 真跑一次 DROP 证明该能力可用,否则老库升级
///    会在迁移中途抛错、user_version 不前进(应用永久打不开)。
library;
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite3;

import 'package:piggycount/data/db.dart';

/// v51 要删的四张表。
const droppedTables = [
  'shared_ledger_categories',
  'shared_ledger_accounts',
  'shared_ledger_tags',
  'transaction_tag_overrides',
];

/// v51 要删的共享专属列(与 db.dart `if (from < 51)` 块逐一对应)。
const droppedColumns = {
  'ledgers': ['my_role', 'member_count', 'is_shared', 'owner_user_id'],
  'transactions': [
    'category_sync_id_override',
    'account_sync_id_override',
    'to_account_sync_id_override',
    'tag_sync_ids_override',
  ],
};

void main() {
  // 升级路径用例会真跑 onUpgrade → 迁移块内的 logger 需要 binding 与
  // SharedPreferences mock（惯例同其它会走迁移的测试）。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<List<String>> tableNames() async {
    final rows = await db
        .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
        .get();
    return rows.map((r) => r.read<String>('name')).toList();
  }

  Future<Set<String>> columnNames(String table) async {
    final rows = await db.customSelect('PRAGMA table_info($table)').get();
    return rows.map((r) => r.read<String>('name')).toSet();
  }

  test('v51: 新 schema 不再创建四张共享账本残留表', () async {
    final names = await tableNames();
    for (final table in droppedTables) {
      expect(names, isNot(contains(table)),
          reason: '$table 是共享账本残留死表,v51 起 DROP;onCreate/createAll 不得再创建');
    }
  });

  test('v51: ledgers / transactions 不再有共享专属列', () async {
    for (final entry in droppedColumns.entries) {
      final cols = await columnNames(entry.key);
      for (final col in entry.value) {
        expect(cols, isNot(contains(col)),
            reason: '${entry.key}.$col 是共享专属残留列,v51 起 DROP');
      }
    }
  });

  test('v51: 仍在用的列/表必须健在(迁移误删防护)', () async {
    // CSV 导入导出仍在写这两列 —— 共享账本时代引入但语义与协作无关。
    final txCols = await columnNames('transactions');
    expect(txCols, contains('created_by_user_id'));
    expect(txCols, contains('last_edited_by_user_id'));
    // 账本周期起始日、以及快照 tagSyncIds 契约依赖的主表。
    final ledgerCols = await columnNames('ledgers');
    expect(ledgerCols, contains('month_start_day'));
    final names = await tableNames();
    expect(names, contains('transaction_tags'));
    expect(names, contains('tags'));
  });

  test('v51: 迁移所依赖的 ALTER TABLE DROP COLUMN 在本机引擎可用', () async {
    // 造一张与旧 schema 同形的临时表，验证 DROP COLUMN 能力与守卫前提。
    await db.customStatement(
        'CREATE TABLE tmp_v51_probe (id INTEGER PRIMARY KEY, my_role TEXT, keep_me TEXT)');
    expect(await columnNames('tmp_v51_probe'), contains('my_role'));

    // 与 db.dart `_dropColumnIfPresent` 产生的 DDL 同形。
    await db.customStatement('ALTER TABLE tmp_v51_probe DROP COLUMN my_role');

    final cols = await columnNames('tmp_v51_probe');
    expect(cols, isNot(contains('my_role')), reason: 'DROP COLUMN 必须真的生效');
    expect(cols, contains('keep_me'), reason: 'DROP COLUMN 不得波及其它列');
    await db.customStatement('DROP TABLE tmp_v51_probe');
  });

  test('schemaVersion 已达 51 及以上', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(51),
        reason: 'db.dart schemaVersion 不应低于 51');
  });

  // ───────────────────────── 升级路径（onUpgrade 真跑） ─────────────────────────

  /// 造一个「v50 形态」的库文件：只建 v51 块会碰到的表/列，
  /// 残留列与残留表齐备 —— 模拟老用户升级到 v51 的真实输入。
  Future<File> writeV50ShapedDb(Directory dir, {required bool withResidue}) async {
    final path = '${dir.path}/old_v50.db';
    final raw = raw_sqlite3.sqlite3.open(path);
    raw.execute('CREATE TABLE ledgers ('
        'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, currency TEXT NOT NULL, '
        'type TEXT NOT NULL, created_at INTEGER NOT NULL, sync_id TEXT, '
        '${withResidue ? 'my_role TEXT, member_count INTEGER, is_shared INTEGER, owner_user_id TEXT,' : ''} '
        'month_start_day INTEGER NOT NULL, updated_at INTEGER)');
    raw.execute('CREATE TABLE transactions ('
        'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, type TEXT NOT NULL, '
        'amount REAL NOT NULL, happened_at INTEGER NOT NULL, sync_id TEXT, '
        'created_by_user_id TEXT, last_edited_by_user_id TEXT'
        '${withResidue ? ', category_sync_id_override TEXT, account_sync_id_override TEXT, to_account_sync_id_override TEXT, tag_sync_ids_override TEXT' : ''})');
    if (withResidue) {
      for (final t in [
        'shared_ledger_categories',
        'shared_ledger_accounts',
        'shared_ledger_tags',
      ]) {
        raw.execute('CREATE TABLE $t (ledger_sync_id TEXT NOT NULL, '
            'sync_id TEXT NOT NULL, PRIMARY KEY (ledger_sync_id, sync_id))');
      }
      raw.execute('CREATE TABLE transaction_tag_overrides ('
          'transaction_sync_id TEXT NOT NULL, tag_sync_id TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, PRIMARY KEY (transaction_sync_id, tag_sync_id))');
    }
    raw.execute("INSERT INTO transactions "
        "(id, ledger_id, type, amount, happened_at, created_by_user_id) "
        "VALUES (1, 1, 'expense', 10.0, 1, 'user-A')");
    raw.execute('PRAGMA user_version = 50');
    raw.close();
    return File(path);
  }

  test('v51: 从 v50 形态库升级 —— 残留表/列被 DROP,保留列数据不丢', () async {
    final dir = await Directory.systemTemp.createTemp('piggy_v51_upgrade');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final file = await writeV50ShapedDb(dir, withResidue: true);

    // 打开同一文件：user_version(50) < schemaVersion(51) → onUpgrade 跑 v51 块。
    final upgraded = PiggyDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get(); // 触发 open + migration

    final tables = (await upgraded
            .customSelect("SELECT name FROM sqlite_master WHERE type='table'")
            .get())
        .map((r) => r.read<String>('name'))
        .toSet();
    for (final table in droppedTables) {
      expect(tables, isNot(contains(table)), reason: '升级路径必须 DROP $table');
    }
    for (final entry in droppedColumns.entries) {
      final cols =
          (await upgraded.customSelect('PRAGMA table_info(${entry.key})').get())
              .map((r) => r.read<String>('name'))
              .toSet();
      for (final col in entry.value) {
        expect(cols, isNot(contains(col)),
            reason: '升级路径必须 DROP ${entry.key}.$col');
      }
    }

    // DROP COLUMN 不得波及保留列，也不得丢数据。
    final kept = await upgraded
        .customSelect('SELECT created_by_user_id FROM transactions WHERE id = 1')
        .getSingle();
    expect(kept.read<String?>('created_by_user_id'), 'user-A',
        reason: 'DROP COLUMN 后保留列的原值必须完好');
  });

  test('v51: 残留列/表本就不存在的旧库(from<24 直升形态)升级不报错', () async {
    final dir = await Directory.systemTemp.createTemp('piggy_v51_upgrade_clean');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final file = await writeV50ShapedDb(dir, withResidue: false);

    // 守卫前提：这些列从未创建过时，`_dropColumnIfPresent` 必须跳过而非抛错
    // （老库 from<24 直升 v51 的真实形态）。
    final upgraded = PiggyDatabase.forTesting(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get();

    final txCols = (await upgraded.customSelect('PRAGMA table_info(transactions)').get())
        .map((r) => r.read<String>('name'))
        .toSet();
    expect(txCols, contains('created_by_user_id'));
  });
}
