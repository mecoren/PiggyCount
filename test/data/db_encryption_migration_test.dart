/// 明文 ⇄ 密文迁移的**文件级**契约（`prd/sqlcipher_db_encryption/design.md` §5.1）。
///
/// 这是整条加密链路里唯一会丢数据的一段，所以用真实文件 + 真实 SQLCipher 测
/// 「成功路径」和**三种中断态**：
///   A. 主库已改名、临时库还没就位（读作"主库缺失"）
///   B. 主库已替换成功、留底没删成
///   C. 只留下临时库半成品
/// 三种都必须收敛到「数据完好」，不允许出现"留底被遗忘 = 数据永久丢"。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:piggycount/data/encryption/db_encryption_settings.dart';

import '../support/sqlcipher_support.dart';

import 'package:piggycount/data/encryption/database_key_service.dart';
import 'package:piggycount/data/encryption/db_encryption_migration.dart';

const String keyA =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';
const String keyB =
    'ffeeddccbbaa99887766554433221100ffeeddccbbaa99887766554433221100';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;
  late String dbPath;
  const migration = DbEncryptionMigration();

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('dbenc_migration');
    dbPath = p.join(tmp.path, 'x.sqlite');
    DatabaseKeyService.testSecureStore = <String, String>{};
    SharedPreferences.setMockInitialValues({});
  });
  tearDown(() async {
    DatabaseKeyService.testSecureStore = null;
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  /// 造一个明文库：一张表 + [rows] 行。
  void makePlainDb({int rows = 3}) {
    final db = sqlite3.open(dbPath);
    db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY, v TEXT)');
    for (var i = 0; i < rows; i++) {
      db.execute("INSERT INTO t (v) VALUES ('row-$i')");
    }
    db.close();
  }

  /// 用密钥读行数；打不开会抛（调用方按需断言）。
  int countWithKey(String path, String key) {
    final db = sqlite3.open(path, mode: OpenMode.readOnly);
    try {
      db.execute("PRAGMA key = \"x'$key'\"");
      return db.select('SELECT count(*) AS c FROM t').first['c'] as int;
    } finally {
      db.close();
    }
  }

  bool isPlain(String path) => DbEncryptionMigration.looksLikePlaintext(path);
  bool exists(String path) => File(path).existsSync();

  group('开库前准备（密钥决策）', () {
    sqlCipherTest('无密钥 + 明文库 → null 且不动文件', () async {
      makePlainDb();
      final before = File(dbPath).readAsBytesSync();

      final key = await migration.prepareKeyForOpen(dbPath: dbPath);

      expect(key, isNull, reason: '未启用加密必须保持与加密前逐字一致的行为');
      expect(File(dbPath).readAsBytesSync(), before);
      expect(exists('$dbPath${DbEncryptionMigration.backupSuffix}'), isFalse);
    });

    sqlCipherTest('无密钥 + 密文库 → 抛 DbEncryptionKeyMissingException（不清空、不隔离）',
        () async {
      makePlainDb();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      expect(isPlain(dbPath), isFalse);

      expect(
        () => migration.prepareKeyForOpen(dbPath: dbPath),
        throwsA(isA<DbEncryptionKeyMissingException>()),
      );
      // 关键：拒绝打开不得顺手删库
      expect(exists(dbPath), isTrue);
    });

    sqlCipherTest('有密钥 + 库不存在 → 直接返回密钥（新库即密文）', () async {
      final key = await migration.prepareKeyForOpen(
          dbPath: p.join(tmp.path, 'fresh.sqlite'), keyOverride: keyA);
      expect(key, keyA);
      expect(exists(p.join(tmp.path, 'fresh.sqlite')), isFalse,
          reason: '准备阶段不应凭空建库，交给 drift 打开时创建');
    });
  });

  group('明文 → 密文', () {
    sqlCipherTest('迁移成功：主库变密文、数据完好、无临时/留底残留', () async {
      makePlainDb(rows: 5);
      expect(isPlain(dbPath), isTrue);

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(isPlain(dbPath), isFalse, reason: '主库必须已加密');
      expect(countWithKey(dbPath, keyA), 5, reason: '一行都不能少');
      expect(exists('$dbPath${DbEncryptionMigration.tempSuffix}'), isFalse);
      expect(exists('$dbPath${DbEncryptionMigration.backupSuffix}'), isFalse,
          reason: '复核通过后留底必须删掉');
      expect(exists('$dbPath-wal'), isFalse);
      expect(exists('$dbPath-shm'), isFalse);
    });

    sqlCipherTest('幂等：已密文时第二次调用不改动库', () async {
      makePlainDb();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      final afterFirst = File(dbPath).readAsBytesSync();

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(File(dbPath).readAsBytesSync(), afterFirst,
          reason: '重复调用若又迁移一次，密文（含随机 IV）必然与上次不同');
      expect(countWithKey(dbPath, keyA), 3);
    });

    sqlCipherTest('换一把密钥读不到原库（证明迁移产物真的被这把钥匙加密）', () async {
      makePlainDb();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      expect(() => countWithKey(dbPath, keyB), throwsA(isA<SqliteException>()));
    });
  });

  group('中断恢复', () {
    sqlCipherTest('A：主库已改名、临时库未就位 → 回滚成明文再迁移，数据不丢', () async {
      makePlainDb(rows: 4);
      // 模拟中断点：主库 → 留底，主库位置空缺
      await File(dbPath)
          .rename('$dbPath${DbEncryptionMigration.backupSuffix}');
      expect(exists(dbPath), isFalse);

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(isPlain(dbPath), isFalse);
      expect(countWithKey(dbPath, keyA), 4,
          reason: '留底里的数据必须被找回，而不是当成"新库"重新建');
      expect(exists('$dbPath${DbEncryptionMigration.backupSuffix}'), isFalse);
    });

    sqlCipherTest('B：主库已密文 + 留底残留 → 复用主库并清掉残留', () async {
      makePlainDb();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      final encrypted = File(dbPath).readAsBytesSync();
      // 模拟中断点：替换成功但留底没删成
      File('$dbPath${DbEncryptionMigration.backupSuffix}')
          .writeAsBytesSync(encrypted);

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(File(dbPath).readAsBytesSync(), encrypted, reason: '主库不该被动过');
      expect(exists('$dbPath${DbEncryptionMigration.backupSuffix}'), isFalse);
      expect(countWithKey(dbPath, keyA), 3);
    });

    sqlCipherTest('C：临时库半成品残留 → 丢弃后正常迁移', () async {
      makePlainDb(rows: 2);
      File('$dbPath${DbEncryptionMigration.tempSuffix}')
          .writeAsStringSync('half-written-junk');

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(isPlain(dbPath), isFalse);
      expect(countWithKey(dbPath, keyA), 2);
      expect(exists('$dbPath${DbEncryptionMigration.tempSuffix}'), isFalse);
    });
  });

  group('关闭加密（R6：密文 → 明文）', () {
    /// 造一个密文库（先明文再迁移过去）+ 备好密钥与"待关闭"意图。
    Future<void> setUpEncryptedWithDisableIntent() async {
      makePlainDb(rows: 4);
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      expect(isPlain(dbPath), isFalse);
      DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey] = keyA;
      // 与生产一致：开启加密时会留下"曾启用"标记（健康探测靠它区分 R5 与损坏）
      await const DbEncryptionSettings().markEverEnabled();
      await const DbEncryptionSettings().requestDisable();
    }

    sqlCipherTest('关闭成功：库回到明文、数据完好、密钥与意图都被清掉', () async {
      await setUpEncryptedWithDisableIntent();

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, isNull, reason: '关闭后应返回 null（明文连接）');
      expect(isPlain(dbPath), isTrue, reason: '落盘必须回到明文 SQLite 头');
      expect(DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey],
          isNull, reason: '解密成功后才允许删钥');
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse);
      expect(await const DbEncryptionSettings().wasEverEnabled(), isFalse,
          reason: '解密成功后要撤掉"曾启用"标记，否则将来出问题会被误判成 R5');
      // 明文可直接读，且一行不少
      final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        expect(db.select('SELECT count(*) AS c FROM t').first['c'], 4);
      } finally {
        db.close();
      }
      expect(exists('$dbPath${DbEncryptionMigration.tempSuffix}'), isFalse);
      expect(exists('$dbPath${DbEncryptionMigration.backupSuffix}'), isFalse);
    });

    sqlCipherTest('关闭后再次开启仍然生效（验收 6 的往返）', () async {
      await setUpEncryptedWithDisableIntent();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      expect(isPlain(dbPath), isTrue);

      // 再开一次：密钥回来了 + 库是明文 → 应重新迁成密文
      DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey] = keyA;
      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA);
      expect(isPlain(dbPath), isFalse);
      expect(countWithKey(dbPath, keyA), 4, reason: '往返两趟都不能丢数据');
    });

    sqlCipherTest('库已是明文时关闭 → 只清理密钥与意图，不报错', () async {
      makePlainDb();
      DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey] = keyA;
      await const DbEncryptionSettings().requestDisable();

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, isNull);
      expect(DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey],
          isNull);
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse);
    });

    sqlCipherTest('关闭失败 → 保持加密可用（库完好、钥还在、意图清掉）', () async {
      await setUpEncryptedWithDisableIntent();
      final before = File(dbPath).readAsBytesSync();
      // 制造失败：把临时库路径占成目录，EXPORT 必然写不进去
      Directory('$dbPath${DbEncryptionMigration.tempSuffix}').createSync();

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, keyA, reason: '关闭失败要继续以密文打开，应用不能因此打不开');
      expect(File(dbPath).readAsBytesSync(), before, reason: '主库不得被改动');
      expect(DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey],
          keyA, reason: '密钥必须留着（数据仍靠它读）');
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse,
          reason: '失败要放弃本次意图，否则每次启动都重试同一失败');
      expect(await const DbEncryptionSettings().wasEverEnabled(), isTrue,
          reason: '库仍是密文，标记必须留着（否则将来缺钥会被当成垃圾文件）');
    });

    sqlCipherTest('中断恢复：主库已改名、临时库未就位 → 回滚后仍能完成关闭', () async {
      makePlainDb(rows: 2);
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      DatabaseKeyService.testSecureStore![DatabaseKeyService.storageKey] = keyA;
      await const DbEncryptionSettings().requestDisable();
      // 模拟关闭迁移的中断点（留底=当时的密文主库）
      await File(dbPath)
          .rename('$dbPath${DbEncryptionMigration.backupSuffix}');

      final key = await migration.prepareKeyForOpen(
          dbPath: dbPath, keyOverride: keyA);

      expect(key, isNull);
      expect(isPlain(dbPath), isTrue);
      final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        expect(db.select('SELECT count(*) AS c FROM t').first['c'], 2);
      } finally {
        db.close();
      }
    });

    sqlCipherTest('无密钥 + 关闭意图 + 密文库 → 清意图并走 R5（不静默清库）',
        () async {
      makePlainDb();
      await migration.prepareKeyForOpen(dbPath: dbPath, keyOverride: keyA);
      await const DbEncryptionSettings().requestDisable();

      await expectLater(
        () => migration.prepareKeyForOpen(dbPath: dbPath),
        throwsA(isA<DbEncryptionKeyMissingException>()),
      );
      expect(exists(dbPath), isTrue, reason: '拒绝打开不得删库');
      expect(await const DbEncryptionSettings().isDisableRequested(), isFalse,
          reason: '没有密钥就谈不上关闭，陈旧意图要清掉');
    });
  });

  group('接线契约（防"工具写好了但没人调用"）', () {
    // 这两条是纯源码契约（不依赖 SQLCipher），因此不跳过：加密链路一旦被
    // 接上/摘掉，它们必须始终能报警。
    test('db.dart 在开库前调用迁移并注入 PRAGMA key', () {
      final src = File('lib/data/db.dart').readAsStringSync();
      expect(src.contains('DbEncryptionMigration'), isTrue);
      expect(src.contains('prepareKeyForOpen'), isTrue,
          reason: '迁移必须在建立连接之前跑（连接开了就晚了）');
      expect(src.contains('setup:'), isTrue,
          reason: 'PRAGMA key 必须落在每条连接第一条语句的位置');
      expect(src.contains('PRAGMA key'), isTrue);
    });

    test('健康探测带钥匙（否则加密库会被判 unreadable）', () {
      final src = File('lib/data/database_health_service.dart').readAsStringSync();
      expect(src.contains('encryptionKey'), isTrue);
      expect(src.contains('PRAGMA key'), isTrue);
    });
  });
}
