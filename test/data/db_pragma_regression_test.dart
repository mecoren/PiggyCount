// M18（B10）PRAGMA 显式化的回归：证明 `migration.beforeOpen` 里那两条
// 真的抵达了**实际打开数据库的那条连接**，而不是"以为设了其实没设"。
//
// 为什么必须实测而不是读代码：库在生产里跑在 `createInBackground` 起的第二个
// isolate，PRAGMA 又是 per-connection 的 —— 挂错地方（比如给 `NativeDatabase`
// 传 setup 而它被 background 忽略）会静默无效，源码上看不出来。
//
// 断言三件事：journal_mode 回读 wal、journal_size_limit 回读等于常量、
// 重新打开（新连接）后设置依旧生效（beforeOpen 每次 open 都跑）。
// synchronous 只断"不许低于 FULL"：默认值随 sqlite3 编译选项变（FULL/EXTRA），
// 硬编码 2 会因平台差异恒红。
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Future<(Directory, File)> tempDb() async {
    final dir = await Directory.systemTemp.createTemp('pgy_pragma_test');
    addTearDown(() => dir.delete(recursive: true));
    return (dir, File('${dir.path}/test.db'));
  }

  Future<String> journalMode(PiggyDatabase db) async {
    final row = await db.customSelect('PRAGMA journal_mode').getSingle();
    return row.read<String>('journal_mode');
  }

  test('beforeOpen 的 PRAGMA 落到真实连接上（文件库，非 :memory:）', () async {
    final (_, file) = await tempDb();
    final db = PiggyDatabase.forTesting(NativeDatabase(file));
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();

    // :memory: 库上 journal_mode 只会回 "memory"，所以这条必须用文件库跑
    expect(await journalMode(db), 'wal');
    final limit =
        await db.customSelect('PRAGMA journal_size_limit').getSingle();
    expect(limit.read<int>('journal_size_limit'), PiggyDatabase.walRetainBytes);

    final sync = await db.customSelect('PRAGMA synchronous').getSingle();
    expect(sync.read<int>('synchronous'), greaterThanOrEqualTo(2),
        reason: '一个记账 app 不许把提交持久性降到 NORMAL(1)/OFF(0)');

    // WAL 生效的物理证据：写入后主库旁边要有 -wal
    await db.into(db.ledgers).insert(LedgersCompanion.insert(name: 'W'));
    expect(File('${file.path}-wal').existsSync(), isTrue,
        reason: '没有 -wal 说明 journal_mode 实际没切过去');
  });

  test('重新打开（新连接）依旧带 PRAGMA —— beforeOpen 每次 open 都跑', () async {
    final (_, file) = await tempDb();
    final first = PiggyDatabase.forTesting(NativeDatabase(file));
    await first.customSelect('SELECT 1').get();
    await first.close();

    final again = PiggyDatabase.forTesting(NativeDatabase(file));
    addTearDown(again.close);
    await again.customSelect('SELECT 1').get();
    // 库文件已经停在 WAL 模式，这条断言真正要证明的是新连接上 beforeOpen 也跑了
    // （journal_size_limit 不落盘，只有被重新设置才可能读到非 0）
    expect(await journalMode(again), 'wal');
    final limit =
        await again.customSelect('PRAGMA journal_size_limit').getSingle();
    expect(limit.read<int>('journal_size_limit'), PiggyDatabase.walRetainBytes);
  });

  test('内存库路径不受影响（drift 测试基座仍可用）', () async {
    // beforeOpen 里那两条语句在 :memory: 上不能报错，否则 test/ 下几百个用例连坐
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.customSelect('SELECT 1').get();
    expect(await journalMode(db), isNot('wal'),
        reason: ':memory: 不支持 WAL，回读 memory 即可，只要不抛');
  });
}
