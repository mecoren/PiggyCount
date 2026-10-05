/// SQLCipher 能力验证（`prd/sqlcipher_db_encryption/design.md` §7 的"实现期第一步"）。
///
/// 2026-10-05 实测结论（本文件就是证据，不用真机 —— native 库由 `sqlite3` 的
/// hook `source: sqlcipher` 提供，桌面测试即可验证）：
///
/// 1. **落盘即密文成立**：带 key 写入后文件头不再是明文 `SQLite format 3`，
///    且无 key / 错 key 都打不开（R1）；
/// 2. **raw key 语法可用**：`PRAGMA key = "x'<64位hex>'"` 被该构建接受（跳过 KDF）；
/// 3. **迁移只能走 `ATTACH` + `sqlcipher_export()`** —— `PRAGMA rekey` **不能**给
///    明文库加密，引擎明确报错并要求改用 `sqlcipher_export`（这条推翻了设计稿里
///    "rekey 为首选"的假设）；`rekey` 的正当用途是**已加密库换钥**（钥匙轮换），
///    也已实测可用。
///
/// 用裸 `package:sqlite3` 而不是 drift：这里验的是**引擎语义**，与 ORM 无关；
/// drift 的 `setup` 回调拿到的正是同一个 `sqlite3.Database`，等价。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart' as sq;

import '../support/sqlcipher_support.dart';

/// 32 字节 fixed key（测试可复现；生产用 `DatabaseKeyService.generateHexKey()`）。
const String _hex =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String _hex2 =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

String get _keyPragma => "PRAGMA key = \"x'$_hex'\"";
String get _key2Pragma => "PRAGMA key = \"x'$_hex2'\"";

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late String dbPath;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('pc_sqlcipher');
    dbPath = '${dir.path}/enc.sqlite';
  });
  tearDown(() async {
    // 失败路径上可能仍有句柄未 dispose（Windows 会锁文件）：清理失败不算测试失败。
    try {
      if (await dir.exists()) await dir.delete(recursive: true);
    } catch (_) {}
  });

  bool looksLikePlaintextSqlite(String path) {
    final f = File(path);
    if (!f.existsSync()) return false;
    final head = f.readAsBytesSync();
    if (head.length < 16) return false;
    return String.fromCharCodes(head.sublist(0, 16)) == 'SQLite format 3\u0000';
  }

  sqlCipherTest('R1：带 key 写入 → 落盘非明文；有 key 可读、无 key 打不开', () {
    // 1) 带 key 建库写入
    final w = sq.sqlite3.open(dbPath);
    w.execute(_keyPragma);
    w.execute('CREATE TABLE t (v TEXT)');
    w.execute("INSERT INTO t VALUES ('secret-note')");
    w.close();

    // 2) 文件头不是明文 SQLite
    expect(looksLikePlaintextSqlite(dbPath), isFalse,
        reason: '落盘必须是密文；header 仍是 SQLite format 3 说明 key 没生效');

    // 3) 有 key 可读（证明 raw key 语法被接受）
    final r = sq.sqlite3.open(dbPath);
    r.execute(_keyPragma);
    expect(r.select('SELECT v FROM t').first['v'], 'secret-note');
    r.close();

    // 4) 无 key 打不开（R1 的另一半：不持有密钥不可读）
    final noKey = sq.sqlite3.open(dbPath);
    expect(() => noKey.select('SELECT v FROM t'),
        throwsA(isA<sq.SqliteException>()),
        reason: '无 key 却能读 = 加密没生效');
    noKey.close();
  });

  sqlCipherTest('raw key：换个 key 打不开（证明 key 真的参与解密）', () {
    final w = sq.sqlite3.open(dbPath);
    w.execute(_keyPragma);
    w.execute('CREATE TABLE t (v TEXT)');
    w.close();

    final wrong = sq.sqlite3.open(dbPath);
    wrong.execute(_key2Pragma);
    expect(() => wrong.select('SELECT v FROM t'),
        throwsA(isA<sq.SqliteException>()));
    wrong.close();
  });

  sqlCipherTest('迁移路径：ATTACH + sqlcipher_export 把明文库转成可被 key 打开的密文库', () {
    // 源：明文
    final src = sq.sqlite3.open(dbPath);
    src.execute('CREATE TABLE t (v TEXT)');
    src.execute("INSERT INTO t VALUES ('exported')");
    expect(looksLikePlaintextSqlite(dbPath), isTrue, reason: '前置：源库是明文');

    final encPath = '${dir.path}/exported.sqlite';
    src.execute("ATTACH DATABASE '$encPath' AS enc KEY \"x'$_hex'\"");
    src.select("SELECT sqlcipher_export('enc')");
    src.execute('DETACH DATABASE enc');
    src.close();

    expect(File(encPath).existsSync(), isTrue, reason: '导出库应存在');
    expect(looksLikePlaintextSqlite(encPath), isFalse, reason: '导出库应为密文');

    final r = sq.sqlite3.open(encPath);
    r.execute(_keyPragma);
    expect(r.select('SELECT v FROM t').first['v'], 'exported');
    r.close();
  });

  sqlCipherTest('PRAGMA rekey 的边界（实测）：明文库会被拒，已加密库可换钥', () {
    // A) 明文库上 rekey → 引擎拒绝，并指路 sqlcipher_export + ATTACH。
    //    这条是"迁移不能用 rekey"的守门断言：SQLCipher 一旦放宽该限制，
    //    这里会红，届时可重新评估更简单的迁移实现。
    final plain = sq.sqlite3.open(dbPath);
    plain.execute('CREATE TABLE t (v TEXT)');
    expect(() => plain.execute("PRAGMA rekey = \"x'$_hex'\""),
        throwsA(isA<sq.SqliteException>()),
        reason: '明文库 rekey 应被拒（实测报错原文：rekey can only be run on an '
            'existing encrypted database）');
    plain.close();

    // B) 已加密库换钥：key → key2（钥匙轮换的真实用途）
    final encPath = '${dir.path}/rot.sqlite';
    final enc = sq.sqlite3.open(encPath);
    enc.execute(_keyPragma); // 新库 + key = 加密库
    enc.execute('CREATE TABLE t2 (v TEXT)');
    enc.execute("INSERT INTO t2 VALUES ('rot')");
    enc.execute("PRAGMA rekey = \"x'$_hex2'\"");
    enc.close();

    final withNew = sq.sqlite3.open(encPath);
    withNew.execute(_key2Pragma);
    expect(withNew.select('SELECT v FROM t2').first['v'], 'rot');
    withNew.close();

    final withOld = sq.sqlite3.open(encPath);
    withOld.execute(_keyPragma);
    expect(() => withOld.select('SELECT v FROM t2'),
        throwsA(isA<sq.SqliteException>()),
        reason: '换钥后旧 key 必须失效');
    withOld.close();
  });
}
