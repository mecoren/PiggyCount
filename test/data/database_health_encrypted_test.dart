/// 整库加密下的健康探测（`requirements.md` 验收 7）。
///
/// 命门：加密库若被探测判成 `unreadable`，启动链会弹出「数据可能已损坏」并把
/// 恢复引导（含"隔离损坏库"）推给**健康**用户 —— 一旦点了隔离，数据就被搬走。
/// 所以这里逐条钉住四种组合的判定。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../support/sqlcipher_support.dart';

import 'package:piggycount/data/database_health_service.dart';
import 'package:piggycount/data/encryption/database_key_service.dart';

const String keyA =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String keyB =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String dbPath;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dbhealth_enc');
    dbPath = p.join(tmp.path, 'x.sqlite');
    // 置空 = "本机没有密钥"，避免走平台通道
    DatabaseKeyService.testSecureStore = <String, String>{};
  });
  tearDown(() async {
    DatabaseKeyService.testSecureStore = null;
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  void makeDb({String? key}) {
    final db = sqlite3.open(dbPath);
    if (key != null) db.execute("PRAGMA key = \"x'$key'\"");
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    db.execute("INSERT INTO t (v) VALUES ('x')");
    db.close();
  }

  sqlCipherTest('加密库 + 正确密钥 → ok（验收 7 的正例）', () async {
    makeDb(key: keyA);
    final r = await DatabaseHealthService.check(
        path: dbPath, encryptionKey: keyA);
    expect(r.health, DbHealth.ok,
        reason: '加密库被判 ${r.health}，detail=${r.detail}');
  });

  sqlCipherTest('加密库 + 错误密钥 → 不判定损坏（只留痕，不弹恢复引导）', () async {
    makeDb(key: keyA);
    final r = await DatabaseHealthService.check(
        path: dbPath, encryptionKey: keyB);
    expect(r.health, DbHealth.ok,
        reason: '密钥不匹配不是库损坏的正面证据；误报会把健康库推给隔离流程');
    expect(r.detail, isNotNull, reason: '仍要留下可诊断的线索');
  });

  sqlCipherTest('加密库 + 本机无密钥 → unreadable（真读不了），但不删除也不搬移', () async {
    makeDb(key: keyA);
    final r = await DatabaseHealthService.check(path: dbPath);
    // 与"非 SQLite 内容 → unreadable"同判定：对**本机**而言它确实打不开。
    // 生产路径上更早一步就会由 DbEncryptionMigration 抛
    // DbEncryptionKeyMissingException（R5 引导），不会走到恢复引导。
    expect(r.health, DbHealth.unreadable);
    expect(File(dbPath).existsSync(), isTrue, reason: '探测绝不改动用户数据');
  });

  sqlCipherTest('明文库 + 本机有密钥（启用加密、迁移尚未跑）→ ok，不得误报 corrupted',
      () async {
    // 这是最危险的组合：用户刚开启加密，明文→密文迁移还没执行，启动探测先跑。
    // 若给明文库注入 key，SQLCipher 会拿它当密文库读 → 误报"页级损坏"。
    makeDb();
    final r = await DatabaseHealthService.check(
        path: dbPath, encryptionKey: keyA);
    expect(r.health, DbHealth.ok,
        reason: '明文健康库被误判成 ${r.health}，会把用户推向隔离数据');
  });

  sqlCipherTest('明文库 + 无密钥 → ok（回归：加密改动不得影响未加密用户）', () async {
    makeDb();
    final r = await DatabaseHealthService.check(path: dbPath);
    expect(r.health, DbHealth.ok);
  });

  sqlCipherTest('加密库探测定理：探测本身不修改文件', () async {
    makeDb(key: keyA);
    final before = File(dbPath).readAsBytesSync();
    await DatabaseHealthService.check(path: dbPath, encryptionKey: keyA);
    expect(File(dbPath).readAsBytesSync(), before);
  });
}
