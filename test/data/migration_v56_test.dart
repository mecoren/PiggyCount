/// v56 迁移（F1-b 退款关联 + 报销状态）语义：
///
/// - 新增**可空自引用列** `refund_of_id`：收入行指向被冲正的支出行（同账本
///   1:1）。NULL = 非退款行，存量行零回填。
/// - 新增**三态列** `reimburse_status`（`none` / `pending` / `reimbursed`）：
///   NOT NULL + DEFAULT 'none'，SQLite ADD COLUMN 对存量行填默认值。
/// - 新增索引 `idx_transactions_refund_of_id`：服务预算回补查询
///   （`local_budget_repository` 的冲减 SQL 按 `refund_of_id IS NOT NULL`
///   过滤）与「某笔支出的退款行」反查。
/// - **两列都进快照 / 指纹 / diff**（同步契约格式版本 14，见
///   `prd/refund_reimbursement/design.md` 第二节；守门测试在
///   `test/cloud/sync_contract_refund_test.dart` 与 coverage 夹具）。
///
/// in-memory db 由 create_all 建出 v56 全 schema；「直升形态库」用例用 raw
/// sqlite3 手写 v55 形态库真跑 onUpgrade(55→56)。SQL **不另抄字面量**：
/// 直接引用 db.dart 顶部公开常量（同 v55 测试的理由）。
library;

import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite3;

import 'package:piggycount/data/db.dart';

void main() {
  // 直升形态库用例会真跑 onUpgrade → 迁移块内的 logger 需要 binding 与
  // SharedPreferences mock（惯例同 migration_v51/v55_test）。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  test('迁移 SQL 常量形态：可空 INTEGER 关联列 + 三态 NOT NULL DEFAULT + 索引', () {
    expect(addTransactionRefundOfIdSql, contains('refund_of_id INTEGER'));
    // 不加 NOT NULL：非退款行（存量行 / 普通新行）必须是 NULL。
    expect(addTransactionRefundOfIdSql.toUpperCase(),
        isNot(contains('NOT NULL')));
    // 三态列：NOT NULL + DEFAULT 'none'，存量行零回填即正确默认态。
    expect(addTransactionReimburseStatusSql,
        contains("reimburse_status TEXT NOT NULL DEFAULT 'none'"));
    expect(createTransactionsRefundOfIndexSql,
        contains('idx_transactions_refund_of_id'));
    expect(createTransactionsRefundOfIndexSql, contains('refund_of_id'));
  });

  test('v56 schema：refund_of_id 可空、reimburse_status NOT NULL DEFAULT none', () async {
    final cols =
        await db.customSelect('PRAGMA table_info(transactions)').get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('refund_of_id'));
    expect(byName.keys, contains('reimburse_status'));

    expect(byName['refund_of_id']!.read<int>('notnull'), 0,
        reason: '非退款行必须是 NULL，不能给默认值 0（0 不是合法交易 id）');
    expect(byName['reimburse_status']!.read<int>('notnull'), 1);
    expect(byName['reimburse_status']!.read<String?>('dflt_value'), "'none'");
  });

  test('v56 schema：idx_transactions_refund_of_id 索引存在', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_transactions_refund_of_id'",
    ).get();
    expect(rows, isNotEmpty,
        reason: 'v56 迁移应创建 idx_transactions_refund_of_id（回补查询依赖）');
  });

  test('直升形态库（v55，无两列）升级后存量行得默认态', () async {
    final dir = await Directory.systemTemp.createTemp('piggy_v56_upgrade');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final path = '${dir.path}/old_v55.db';
    final raw = raw_sqlite3.sqlite3.open(path);
    raw.execute('CREATE TABLE ledgers ('
        'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, '
        'currency TEXT NOT NULL, type TEXT NOT NULL, created_at INTEGER NOT NULL, '
        'sync_id TEXT, month_start_day INTEGER NOT NULL)');
    // v55 形态：有 updated_at / created_at（v40/v55 已跑过），无两新列。
    raw.execute('CREATE TABLE transactions ('
        'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
        'type TEXT NOT NULL, amount REAL NOT NULL, happened_at INTEGER NOT NULL, '
        'note TEXT, recurring_id INTEGER, sync_id TEXT, '
        'exclude_from_stats INTEGER NOT NULL DEFAULT 0, '
        'exclude_from_budget INTEGER NOT NULL DEFAULT 0, '
        'updated_at INTEGER, created_at INTEGER, '
        'currency_code TEXT, native_amount REAL, original_amount REAL, '
        'custom_values_json TEXT)');
    raw.execute("INSERT INTO transactions "
        "(id, ledger_id, type, amount, happened_at) "
        "VALUES (1, 1, 'expense', 10.0, 1700000000)");
    raw.execute('PRAGMA user_version = 55');
    raw.close();

    final upgraded = PiggyDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get(); // 触发 open + onUpgrade(55→56)

    final row = await upgraded.customSelect(
      'SELECT refund_of_id, reimburse_status FROM transactions WHERE id = 1',
    ).getSingle();
    expect(row.data['refund_of_id'], isNull,
        reason: '存量行不得被回填出退款关联');
    expect(row.data['reimburse_status'], 'none',
        reason: '存量行报销状态必须是三态默认值 none');

    final idx = await upgraded.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_transactions_refund_of_id'",
    ).get();
    expect(idx, isNotEmpty, reason: '直升路径也必须建索引');
  });

  test('partial state 重跑：列已加过时 _addColumnIfMissing 不报 duplicate column',
      () async {
    // 模拟「上次迁移加了 refund_of_id 列、没来得及加另一列与索引就崩了」的
    // 中间态：直接手跑一次公开 SQL，再以 user_version=55 打开触发完整 onUpgrade。
    final dir = await Directory.systemTemp.createTemp('piggy_v56_partial');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final path = '${dir.path}/partial_v55.db';
    final raw = raw_sqlite3.sqlite3.open(path);
    raw.execute('CREATE TABLE ledgers ('
        'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, '
        'currency TEXT NOT NULL, type TEXT NOT NULL, created_at INTEGER NOT NULL, '
        'sync_id TEXT, month_start_day INTEGER NOT NULL)');
    raw.execute('CREATE TABLE transactions ('
        'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
        'type TEXT NOT NULL, amount REAL NOT NULL, happened_at INTEGER NOT NULL, '
        'note TEXT, recurring_id INTEGER, sync_id TEXT, '
        'exclude_from_stats INTEGER NOT NULL DEFAULT 0, '
        'exclude_from_budget INTEGER NOT NULL DEFAULT 0, '
        'updated_at INTEGER, created_at INTEGER, '
        'currency_code TEXT, native_amount REAL, original_amount REAL, '
        'custom_values_json TEXT)');
    raw.execute("INSERT INTO transactions "
        "(id, ledger_id, type, amount, happened_at) "
        "VALUES (1, 1, 'expense', 10.0, 1700000000)");
    // 中间态：refund_of_id 已存在（上次崩前加过），另一列与索引缺失。
    raw.execute('ALTER TABLE transactions ADD COLUMN refund_of_id INTEGER');
    raw.execute('PRAGMA user_version = 55');
    raw.close();

    final upgraded = PiggyDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(upgraded.close);
    // 不炸 = _addColumnIfMissing 的幂等守护生效；且补齐了缺失的另一半。
    await upgraded.customSelect('SELECT 1').get();

    final cols = await upgraded
        .customSelect('PRAGMA table_info(transactions)')
        .get();
    final names = cols.map((r) => r.read<String>('name')).toSet();
    expect(names, contains('refund_of_id'));
    expect(names, contains('reimburse_status'),
        reason: 'partial state 重跑必须补齐缺失的 reimburse_status 列');

    final row = await upgraded.customSelect(
      'SELECT reimburse_status FROM transactions WHERE id = 1',
    ).getSingle();
    expect(row.data['reimburse_status'], 'none');
  });

  test('新写入行走完整默认链路：插入不带两列也得 none / NULL', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at) "
        "VALUES (200, 1, 'income', 5.0, 1700000000)");
    final row = await db.customSelect(
      'SELECT refund_of_id, reimburse_status FROM transactions WHERE id = 200',
      variables: const [],
    ).getSingle();
    expect(row.data['refund_of_id'], isNull);
    expect(row.data['reimburse_status'], 'none');
  });

  test('直读助手：Variable.withInt 可绑定 refund_of_id 查询', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at) "
        "VALUES (201, 1, 'expense', 10.0, 1700000000)");
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, refund_of_id) "
        "VALUES (202, 1, 'income', 4.0, 1700000000, 201)");
    final rows = await db.customSelect(
      'SELECT id FROM transactions WHERE refund_of_id = ?',
      variables: [Variable.withInt(201)],
    ).get();
    expect(rows.single.data['id'], 202,
        reason: '退款反查（某笔支出的退款行）按 refund_of_id 过滤');
  });
}
