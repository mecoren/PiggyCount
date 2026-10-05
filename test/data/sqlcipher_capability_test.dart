/// 引擎加密能力探测的契约，以及**最关键的一条护栏**：
/// "有密钥 + 引擎不支持加密 → 拒绝打开"。
///
/// 为什么这条护栏重要到要单独立个文件：`PRAGMA key` 在普通 SQLite 上是未知
/// pragma，**静默忽略**。没有这条护栏时，开启加密的用户会得到一个"看起来一切
/// 正常、实际全是明文"的库 —— 而用户是冲着"落盘即密文"来的。2026-10-05 在
/// Android 产物上实测确认过这个状态真实存在。
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:piggycount/data/encryption/database_key_service.dart';
import 'package:piggycount/data/encryption/db_encryption_migration.dart';
import 'package:piggycount/data/encryption/sqlcipher_capability.dart';

const String keyA =
    '000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tmp;

  setUp(() async {
    tmp = await Directory.systemTemp.createTemp('sqlcipher_cap');
    DatabaseKeyService.testSecureStore = <String, String>{};
    // 开库路径会读"待关闭"意图（DbEncryptionSettings），测试里得有 prefs。
    SharedPreferences.setMockInitialValues({});
    SqlCipherCapability.resetCacheForTesting();
  });
  tearDown(() async {
    DatabaseKeyService.testSecureStore = null;
    try {
      if (tmp.existsSync()) await tmp.delete(recursive: true);
    } catch (_) {}
  });

  group('探测本身', () {
    test('describe() 给出可读的引擎自述（日志/诊断靠它）', () {
      final d = SqlCipherCapability.describe();
      expect(d, contains('SQLite'));
      if (SqlCipherCapability.isSupported) {
        expect(d, startsWith('SQLCipher '));
        expect(SqlCipherCapability.cipherVersion, isNotNull);
      } else {
        expect(d, contains('无加密能力'));
        expect(SqlCipherCapability.cipherVersion, isNull);
      }
    });

    test('isSupported 与 cipherVersion 判据一致', () {
      expect(SqlCipherCapability.isSupported,
          SqlCipherCapability.cipherVersion != null);
    });
  });

  group('静默忽略的危害（这条解释了护栏为什么必须存在）', () {
    test('普通 SQLite 上 PRAGMA key 不报错、库也不加密', () {
      if (SqlCipherCapability.isSupported) {
        // SQLCipher 构建上这条不适用（key 会真的生效）
        return;
      }
      final path = p.join(tmp.path, 'plain.sqlite');
      final db = sqlite3.open(path);
      db.execute("PRAGMA key = \"x'$keyA'\""); // 不报错
      db.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      db.execute('INSERT INTO t DEFAULT VALUES');
      db.close();

      // 关键断言：文件头仍是明文 SQLite
      final head = File(path).readAsBytesSync().sublist(0, 15);
      expect(String.fromCharCodes(head), 'SQLite format 3',
          reason: '引擎不支持时库就是明文 —— 所以绝不能让流程走到这里还以为安全');
    });
  });

  group('护栏：有密钥 + 引擎不支持 → 响亮拒绝', () {
    test('prepareKeyForOpen 抛 DbEncryptionUnsupportedException 且不碰库文件',
        () async {
      final path = p.join(tmp.path, 'guard.sqlite');
      // 先造一个明文库，确认护栏不会把它删掉/改写
      final seed = sqlite3.open(path);
      seed.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      seed.close();
      final before = File(path).readAsBytesSync();

      const migration = DbEncryptionMigration();
      if (SqlCipherCapability.isSupported) {
        // 支持加密的构建（如配了 source: sqlcipher 的 Windows）→ 正常返回密钥
        final key =
            await migration.prepareKeyForOpen(dbPath: path, keyOverride: keyA);
        expect(key, keyA);
      } else {
        await expectLater(
          () => migration.prepareKeyForOpen(dbPath: path, keyOverride: keyA),
          throwsA(isA<DbEncryptionUnsupportedException>()),
        );
        expect(File(path).readAsBytesSync(), before,
            reason: '拒绝打开不得顺手动用户的库');
      }
    });

    test('无密钥时不做能力检查（未启用加密的用户行为不受影响）', () async {
      final path = p.join(tmp.path, 'nokey.sqlite');
      final seed = sqlite3.open(path);
      seed.execute('CREATE TABLE t (id INTEGER PRIMARY KEY)');
      seed.close();

      final key = await const DbEncryptionMigration().prepareKeyForOpen(
          dbPath: path, keyOverride: null);
      expect(key, isNull);
      expect(File(path).existsSync(), isTrue);
    });
  });
}
