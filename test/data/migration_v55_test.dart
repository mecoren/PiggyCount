/// v55 迁移（交易**录入时刻** `transactions.created_at`）语义：
///
/// - 新增**本地专有列** `created_at`：语义是「本设备把这一行写进库的时刻」，
///   与用户可改的 `happened_at`（发生时间）无关。仅「用户交互式单笔录入」
///   会写它；批量导入 / 云恢复 / 周期模板生成的行保持 NULL，天然不参与
///   「5 分钟内继承上一笔默认值」。
/// - **回填** `created_at = happened_at` 只针对存量行（`created_at IS NULL`）：
///   迁移前没有录入时刻信息，`happened_at` 是最好的可得近似；
///   加 `typeof(happened_at) IN ('integer','real')` 防止脏 TEXT 值被搬进
///   一个 Drift 按纪元秒整数读取的列。
/// - 新增复合索引 `idx_transactions_ledger_created`，服务
///   `ledger_id = ? AND created_at >= ?` 的范围裁剪（窗口查询）。
///
/// in-memory db 由 create_all 建出 v55 全 schema（列已存在），这里用
/// 「插行 + 执行 onUpgrade 里同一段 SQL」验证语义。SQL **不再另抄字面量**：
/// 直接引用 db.dart 顶部的公开常量（测试自己抄一份的话，改实现可以悄悄骗过测试）。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite3;

import 'package:piggycount/data/db.dart';

void main() {
  // 「直升形态库」用例会真跑 onUpgrade → 迁移块内的 logger 需要 binding 与
  // SharedPreferences mock（惯例同 migration_v51_test 等会走迁移的测试）。
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  /// 直读 SQL 而不走生成的数据类：列尚未生成时本文件仍能编译，
  /// 失败点落在断言（列 / 索引 / 回填缺失）而非编译错误。
  Future<Object?> readCreatedAt(int id) async {
    final row = await db
        .customSelect('SELECT created_at FROM transactions WHERE id = ?',
            variables: [Variable.withInt(id)])
        .getSingle();
    return row.data['created_at'];
  }

  test('迁移 SQL 常量形态：加可空 INTEGER 列 + 只回填 NULL 行 + 复合索引', () {
    expect(addTransactionCreatedAtSql, contains('created_at INTEGER'));
    // 不加 NOT NULL —— 批量导入 / 云恢复的行刻意保持 NULL（非继承源）。
    expect(addTransactionCreatedAtSql.toUpperCase(), isNot(contains('NOT NULL')));
    // WHERE IS NULL 守卫：重跑迁移绝不覆盖已有录入时刻。
    expect(backfillTransactionCreatedAtSql.toUpperCase(),
        contains('WHERE CREATED_AT IS NULL'));
    // 脏类型守卫：TEXT 形态的 happened_at 不得被搬进来。
    expect(backfillTransactionCreatedAtSql, contains("typeof(happened_at)"));
    expect(createTransactionsLedgerCreatedIndexSql, contains('created_at'));
    expect(createTransactionsLedgerCreatedIndexSql, contains('ledger_id'));
  });

  test('v55 schema：transactions 带可空 created_at 列', () async {
    final cols =
        await db.customSelect('PRAGMA table_info(transactions)').get();
    final byName = {for (final r in cols) r.read<String>('name'): r};

    expect(byName.keys, contains('created_at'));
    expect(byName['created_at']!.read<int>('notnull'), 0);
  });

  test('v55 schema：idx_transactions_ledger_created 索引存在', () async {
    final rows = await db.customSelect(
      "SELECT name FROM sqlite_master WHERE type='index' "
      "AND name='idx_transactions_ledger_created'",
    ).get();
    expect(rows, isNotEmpty,
        reason: 'v55 迁移应创建 idx_transactions_ledger_created 复合索引');
  });

  test('存量行回填后 created_at = happened_at', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at) "
        "VALUES (100, 1, 'expense', 12.0, 1700000000)");
    await db.customStatement(
        'UPDATE transactions SET created_at = NULL WHERE id = 100');

    await db.customStatement(backfillTransactionCreatedAtSql);

    expect(await readCreatedAt(100), 1700000000);
  });

  test('幂等重跑：已回填的行不被二次改写', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at) "
        "VALUES (101, 1, 'expense', 12.0, 1700000000)");
    await db.customStatement(backfillTransactionCreatedAtSql);
    final first = await readCreatedAt(101);

    // 模拟 partial state 重跑：happened_at 变了也不该动 created_at。
    await db.customStatement(
        'UPDATE transactions SET happened_at = 1800000000 WHERE id = 101');
    await db.customStatement(backfillTransactionCreatedAtSql);
    final second = await readCreatedAt(101);

    expect(second, first);
  });

  test('直升形态库（transactions 无 updated_at）也能完成回填', () async {
    // 背景（实测踩过）：v52 块会给**已存在**的 transactions 建
    // `trg_transactions_touch_updated_at`，触发器体引用 `NEW.updated_at`；
    // SQLite 在 CREATE TRIGGER 时不校验列是否存在，于是「user_version 直接跳到
    // ≥v40、v40 块从未跑过」的合成形态库里会留下一颗地雷 —— 之后**任何**对
    // transactions 的 UPDATE 都在 prepare 阶段报
    // `no such column: NEW.updated_at`。v55 的存量回填正是这条路径上的第一条
    // UPDATE 语句（由 migration_v51_test / holdings_migration_test 先抓到全红）。
    // 修法：v55 块在回填前先补齐自己依赖的 updated_at 列。
    final dir = await Directory.systemTemp.createTemp('piggy_v55_upgrade');
    addTearDown(() async {
      if (dir.existsSync()) await dir.delete(recursive: true);
    });
    final path = '${dir.path}/old_v50.db';
    final raw = raw_sqlite3.sqlite3.open(path);
    raw.execute('CREATE TABLE ledgers ('
        'id INTEGER PRIMARY KEY NOT NULL, name TEXT NOT NULL, '
        'currency TEXT NOT NULL, type TEXT NOT NULL, created_at INTEGER NOT NULL, '
        'sync_id TEXT, month_start_day INTEGER NOT NULL)');
    // 关键：**没有** updated_at 列（v40 块从未跑过）。
    raw.execute('CREATE TABLE transactions ('
        'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
        'type TEXT NOT NULL, amount REAL NOT NULL, happened_at INTEGER NOT NULL, '
        'sync_id TEXT)');
    raw.execute("INSERT INTO transactions "
        "(id, ledger_id, type, amount, happened_at) "
        "VALUES (1, 1, 'expense', 10.0, 1700000000)");
    raw.execute('PRAGMA user_version = 50');
    raw.close();

    final upgraded = PiggyDatabase.forTesting(NativeDatabase(File(path)));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get(); // 触发 open + onUpgrade(50→55)

    final row = await upgraded
        .customSelect('SELECT created_at FROM transactions WHERE id = 1')
        .getSingle();
    expect(row.data['created_at'], 1700000000,
        reason: '直升形态库上 v55 回填也必须成功（否则老库升级即报错、打不开）');
  });

  test('脏类型守护：happened_at 为 TEXT 时不回填（保持 NULL）', () async {
    await seedLedger();
    await db.customStatement(
        "INSERT INTO transactions (id, ledger_id, type, amount, happened_at) "
        "VALUES (102, 1, 'expense', 12.0, '2026-07-01')");

    await db.customStatement(backfillTransactionCreatedAtSql);

    expect(await readCreatedAt(102), isNull);
  });
}
