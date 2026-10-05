/// 设备侧整库加密链路探针（端到端验证用，非 UI 入口）。
///
/// 用法：
/// ```bash
/// flutter build apk --debug -t tool/db_encryption_device_probe.dart
/// adb install -r build/app/outputs/flutter-apk/app-x86_64-dev-debug.apk
/// # 启动应用后看 logcat：
/// adb logcat -s flutter | Select-String DbProbe
/// ```
///
/// **为什么需要这么一个入口**：本机模拟器的图形栈渲染不出 Flutter 画面（窗口与
/// surface 都在、无锁屏、只出 3 帧、整屏纯黑），所以没法靠"点开关"验证。但本探针
/// 跑的是**生产代码**（同一个密钥层、同一个迁移服务、真实系统安全区、真实库文件），
/// 断言比点 UI 更强 —— 而且它**不依赖任何渲染**。
///
/// 安全设计：动手前先把库复制一份 `.probe-backup`，任何一步失败都留得下原件；
/// 全程只动本地库文件与安全区，不碰云端、不碰同步。
///
/// 依赖：`sqlite3` 是直接依赖（pubspec 已声明），故此处不必新增任何包。
library;

import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import 'package:piggycount/data/encryption/database_key_service.dart';
import 'package:piggycount/data/encryption/db_encryption_migration.dart';
import 'package:piggycount/data/encryption/db_encryption_settings.dart';
import 'package:piggycount/data/encryption/sqlcipher_capability.dart';

void _log(String message) => debugPrint('[DbProbe] $message');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _log('engine: ${SqlCipherCapability.describe()}');

  final dir = await getApplicationDocumentsDirectory();
  final dbPath = p.join(dir.path, 'piggycount.sqlite');
  final dbFile = File(dbPath);
  _log('db exists=${dbFile.existsSync()} '
      'size=${dbFile.existsSync() ? dbFile.lengthSync() : 0}');
  _log('header(before) = ${_header(dbFile)}');

  final backup = File('$dbPath.probe-backup');
  if (dbFile.existsSync()) {
    await dbFile.copy(backup.path);
    _log('safety copy -> ${p.basename(backup.path)}');
  }

  const keyService = DatabaseKeyService();
  const settings = DbEncryptionSettings();
  const migration = DbEncryptionMigration();

  try {
    // ── 1) 开启：写密钥进系统安全区 ──────────────────────────────
    await settings.clearDisableRequest();
    await keyService.createKey();
    await settings.markEverEnabled();
    final stored = await keyService.loadKey();
    _log('key stored: ${stored != null} (len=${stored?.length})');

    // ── 2) 明文 → 密文（真实库，计时）────────────────────────────
    final sw = Stopwatch()..start();
    final key = await migration.prepareKeyForOpen(dbPath: dbPath);
    _log('encrypt: key!=null=${key != null} '
        'elapsed=${sw.elapsedMilliseconds}ms');
    _log('header(after encrypt) = ${_header(dbFile)}');
    _log('plaintext header? ${DbEncryptionMigration.looksLikePlaintext(dbPath)}');

    // ── 3) 用密钥读（证明数据完好，不是把库换成了空壳）──────────
    _log('rows(with key) = ${_rows(dbPath: dbPath, key: key)}');

    // ── 4) 关闭：意图 → 解回明文 → 删钥 ──────────────────────────
    await settings.requestDisable();
    final keyAfterDisable = await migration.prepareKeyForOpen(dbPath: dbPath);
    _log('disable: returnedNull=${keyAfterDisable == null} '
        'keyDeleted=${await keyService.loadKey() == null}');
    _log('header(after decrypt) = ${_header(dbFile)}');
    _log('plaintext header? ${DbEncryptionMigration.looksLikePlaintext(dbPath)}');
    _log('rows(plain) = ${_rows(dbPath: dbPath, key: null)}');

    if (backup.existsSync()) await backup.delete();
    _log('PROBE DONE (ok)');
  } catch (e, st) {
    _log('PROBE FAILED: $e');
    _log('$st');
    // 失败不动安全区：密钥留着，库仍可被应用打开（宁可加密可用，也不留死库）
  }
}

/// 前 16 字节的 hex；读不到返回 `n/a`。
String _header(File file) {
  try {
    if (!file.existsSync()) return 'n/a';
    final raf = file.openSync();
    try {
      final bytes = raf.readSync(16);
      return bytes
          .map((b) => b.toRadixString(16).padLeft(2, '0'))
          .join(' ');
    } finally {
      raf.closeSync();
    }
  } catch (e) {
    return 'err:$e';
  }
}

/// 点几处真实表，确认数据真的在（`key == null` 走明文连接）。
String _rows({required String dbPath, required String? key}) {
  Database? db;
  try {
    db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    if (key != null) db.execute("PRAGMA key = \"x'$key'\"");
    final master =
        db.select('SELECT count(*) AS c FROM sqlite_master').first['c'];
    int? tx;
    try {
      tx = db.select('SELECT count(*) AS c FROM transactions').first['c'];
    } catch (_) {
      tx = -1; // 表名不符就只报 sqlite_master
    }
    return 'sqlite_master=$master transactions=$tx';
  } catch (e) {
    return 'ERR:$e';
  } finally {
    db?.close();
  }
}
