import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/database_health_service.dart';
import 'package:piggycount/data/encryption/database_key_service.dart';
import 'package:piggycount/data/encryption/db_encryption_settings.dart';

/// DatabaseHealthService 的探测与保留语义（审计 P1-6）。
///
/// 全部用临时目录里的真实文件，不 mock 文件系统——本服务的风险点恰恰是
/// 「对真实文件做了什么」，用内存 fake 测不到。
void main() {
  // 必须：本服务经全局 logger 落日志，而 LoggerService 构造时会挂
  // MethodChannel，未初始化 binding 会直接断言失败（不是被吞掉的异常）。
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dbhealth_test');
    SharedPreferences.setMockInitialValues({});
    DatabaseKeyService.testSecureStore = <String, String>{};
  });

  tearDown(() {
    DatabaseKeyService.testSecureStore = null;
  });

  tearDown(() async {
    if (tmp.existsSync()) await tmp.delete(recursive: true);
  });

  /// 造一个健康的 SQLite 库（含一张表，确保 quick_check 真在检查内容）。
  String makeHealthyDb() {
    final path = p.join(tmp.path, 'healthy.sqlite');
    final db = sqlite3.open(path);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db.execute("INSERT INTO t (v) VALUES ('x')");
    db.close();
    return path;
  }

  group('check', () {
    test('健康库 → ok', () async {
      final path = makeHealthyDb();
      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, DbHealth.ok);
      expect(r.isHealthy, isTrue);
      expect(r.dbPath, path);
    });

    test('文件不存在 → ok(首装,不算异常)', () async {
      final path = p.join(tmp.path, 'not_yet.sqlite');
      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, DbHealth.ok);
    });

    test('非 SQLite 内容 → unreadable(不是「页损坏」)', () async {
      final path = p.join(tmp.path, 'garbage.sqlite');
      File(path).writeAsStringSync('this is definitely not a sqlite file');
      final r = await DatabaseHealthService.check(path: path);
      // SQLite 对非库文件是延迟报错(SQLITE_NOTADB)，归 unreadable 而非
      // corrupted——两者给用户的处置动作不同，不能混为一谈。
      expect(r.health, DbHealth.unreadable);
      expect(r.detail, isNotNull);
    });

    test('有合法文件头但内容是垃圾 → 不得判为 ok（正面证据不可放过）', () async {
      // 这条与上一条互补：头合法就不能靠「头不对」脱身，必须仍然报警。
      // 否则「头对了但库废了」会漏报，用户看到空数据却没有任何提示。
      final path = p.join(tmp.path, 'bogus.sqlite');
      final magic = 'SQLite format 3\u0000'.codeUnits;
      File(path).writeAsBytesSync([...magic, ...List.filled(8192, 0xAB)]);
      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, isNot(DbHealth.ok),
          reason: '正头 + 垃圾内容被判为健康，等于回到静默失败');
    });

    test('空文件(0 字节) → ok：SQLite 视其为合法的空库', () async {
      // 这不是「损坏」：0 字节文件在 SQLite 里是合法的空数据库，
      // quick_check 也会返回 ok。语义上等同首装——drift 随后走 onCreate
      // 建全表。若在此处报损坏，会把「库还没建」误报成「库坏了」。
      final path = p.join(tmp.path, 'empty.sqlite');
      File(path).writeAsBytesSync(const []);
      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, DbHealth.ok);
    });

    test('探测不修改文件(只读连接)', () async {
      final path = makeHealthyDb();
      final before = File(path).readAsBytesSync();
      final beforeMtime = File(path).lastModifiedSync();
      await DatabaseHealthService.check(path: path);
      expect(File(path).readAsBytesSync(), before);
      expect(File(path).lastModifiedSync(), beforeMtime);
    });

    test('WAL 模式 + 主连接仍打开 → 必须 ok（只读探测不得误报）', () async {
      // 这是本服务最危险的失败模式：健康库被判 unreadable，会把全屏恢复
      // 引导推给所有用户。SQLite 对**只读方式打开 WAL 库**有额外约束
      //（需要 -shm 的写权限/存在性），因此必须显式覆盖这个场景。
      final path = p.join(tmp.path, 'wal.sqlite');
      final holder = sqlite3.open(path);
      holder.execute('PRAGMA journal_mode=WAL');
      holder.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      holder.execute("INSERT INTO t (v) VALUES ('x')");
      // 刻意不关闭 holder —— 模拟 app 正持有主库连接（真实运行态）

      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, DbHealth.ok,
          reason: 'WAL 库被误判：health=${r.health} detail=${r.detail}');

      holder.close();
    });

    test('WAL 库关闭后仅剩 -wal/-shm 残留 → 仍 ok', () async {
      final path = p.join(tmp.path, 'wal2.sqlite');
      final d = sqlite3.open(path);
      d.execute('PRAGMA journal_mode=WAL');
      d.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
      d.execute("INSERT INTO t (v) VALUES ('x')");
      d.close();

      final r = await DatabaseHealthService.check(path: path);
      expect(r.health, DbHealth.ok,
          reason: 'health=${r.health} detail=${r.detail}');
    });
  });

  group('密钥不可得（R5，2026-10-05）', () {
    // 判据是"**本机曾启用过加密**"，而不是"非明文就一律算加密"：
    // 后者会把真正的垃圾文件误报成加密问题，而前者不会。
    test('非明文 + 无密钥 + 曾启用过 → keyUnavailable（不判损坏）', () async {
      final path = p.join(tmp.path, 'enc.sqlite');
      // 密文库在文件层面就是"非明文 SQLite 头"的随机字节
      File(path).writeAsBytesSync(List<int>.filled(8192, 0x2A));
      await const DbEncryptionSettings().markEverEnabled();

      final r = await DatabaseHealthService.check(path: path);

      expect(r.health, DbHealth.keyUnavailable);
      expect(r.isHealthy, isFalse, reason: '不可读就不是"健康"，只是原因不同');
      expect(r.dbPath, path);
    });

    test('非明文 + 无密钥 + 没启用过 → 仍是 unreadable（审计 P1-6 语义原样保留）',
        () async {
      final path = p.join(tmp.path, 'garbage_r5.sqlite');
      File(path).writeAsStringSync('this is definitely not a sqlite file');

      final r = await DatabaseHealthService.check(path: path);

      expect(r.health, DbHealth.unreadable,
          reason: '没有加密史的"非明文"就是垃圾文件，不能解释成加密问题');
    });

    test('曾启用过但库是明文 → 照常 ok（标记本身不该影响健康判定）', () async {
      final path = makeHealthyDb();
      await const DbEncryptionSettings().markEverEnabled();

      final r = await DatabaseHealthService.check(path: path);

      expect(r.health, DbHealth.ok);
    });

    test('关闭加密成功后会撤掉标记 → 再出问题回到损坏口径', () async {
      final path = p.join(tmp.path, 'enc2.sqlite');
      File(path).writeAsBytesSync(List<int>.filled(8192, 0x2A));
      await const DbEncryptionSettings().markEverEnabled();
      expect((await DatabaseHealthService.check(path: path)).health,
          DbHealth.keyUnavailable);

      await const DbEncryptionSettings().clearEverEnabled();

      expect((await DatabaseHealthService.check(path: path)).health,
          DbHealth.unreadable);
    });
  });

  group('quarantine', () {
    test('移动主库与 -wal/-shm 到保留目录,且都能在目录里找到', () async {
      final path = makeHealthyDb();
      // 造两个旁路文件（内容不重要，验证搬迁语义）
      File('$path-wal').writeAsStringSync('wal');
      File('$path-shm').writeAsStringSync('shm');

      final dir = await DatabaseHealthService.quarantine(path: path);
      expect(dir, isNotNull);

      // 原位置已清空
      expect(File(path).existsSync(), isFalse);
      expect(File('$path-wal').existsSync(), isFalse);
      expect(File('$path-shm').existsSync(), isFalse);

      // 保留目录里三件套齐备 —— 「移动而非删除」是硬契约
      final kept = Directory(dir!).listSync().map((e) => p.basename(e.path)).toList()
        ..sort();
      expect(kept, containsAll(['healthy.sqlite', 'healthy.sqlite-wal', 'healthy.sqlite-shm']));

      // 且仍是可打开的合法库（数据未被破坏）
      final db = sqlite3.open(p.join(dir, 'healthy.sqlite'));
      expect(db.select('SELECT v FROM t').first['v'], 'x');
      db.close();
    });

    test('库文件不存在 → 返回 null 且不创建目录', () async {
      final path = p.join(tmp.path, 'absent.sqlite');
      final dir = await DatabaseHealthService.quarantine(path: path);
      expect(dir, isNull);
      expect(Directory(tmp.path).listSync(), isEmpty);
    });

    test('两次保留产生不同目录名(时间戳),不互相覆盖', () async {
      final a = makeHealthyDb();
      final d1 = await DatabaseHealthService.quarantine(path: a);
      expect(d1, isNotNull);
      // 重新造一个再保留一次
      final b = makeHealthyDb();
      final d2 = await DatabaseHealthService.quarantine(path: b);
      expect(d2, isNotNull);
      expect(d1, isNot(equals(d2)));
    });
  });

  group('exportCopy', () {
    test('复制而非移动:原文件保留,副本存在且内容一致', () async {
      final path = makeHealthyDb();
      final copy = await DatabaseHealthService.exportCopy(
          path: path, destDir: tmp.path);
      expect(copy, isNotNull);
      expect(File(path).existsSync(), isTrue, reason: '导出不得改变本机状态');
      expect(File(copy!).readAsBytesSync(), File(path).readAsBytesSync());
    });

    test('库文件不存在 → null', () async {
      final copy = await DatabaseHealthService.exportCopy(
          path: p.join(tmp.path, 'absent.sqlite'), destDir: tmp.path);
      expect(copy, isNull);
    });
  });
}
