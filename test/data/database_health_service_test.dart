import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:piggycount/data/database_health_service.dart';

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

    test('探测不修改文件(只读连接)', () async {
      final path = makeHealthyDb();
      final before = File(path).readAsBytesSync();
      final beforeMtime = File(path).lastModifiedSync();
      await DatabaseHealthService.check(path: path);
      expect(File(path).readAsBytesSync(), before);
      expect(File(path).lastModifiedSync(), beforeMtime);
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
