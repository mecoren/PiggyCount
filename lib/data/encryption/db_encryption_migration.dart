import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../../services/system/logger_service.dart';
import 'database_key_service.dart';
import 'db_encryption_settings.dart';
import 'sqlcipher_capability.dart';

/// 密文库存在、但本机拿不到密钥时抛出。
///
/// **绝不**在此时静默建新库或删除旧库：密钥丢失 = 本地数据不可读（见
/// `prd/sqlcipher_db_encryption/requirements.md` R5），必须让上层能识别出
/// 「这是密钥问题」而不是「库损坏」，再走引导（不要引导用户去"隔离损坏库"，
/// 那会把还能恢复的数据搬走）。
class DbEncryptionKeyMissingException implements Exception {
  const DbEncryptionKeyMissingException();

  @override
  String toString() =>
      'DbEncryptionKeyMissingException: 库已加密但本机无可用密钥（R5 引导路径）';
}

/// 引擎不支持加密、却要用密钥打开时抛出。
///
/// **必须响亮拒绝**：`PRAGMA key` 在普通 SQLite 上是被静默忽略的未知 pragma，
/// 继续走完流程只会得到"以为加密了、其实明文落盘"（2026-10-05 在 Android 产物上
/// 实测确认过这个坑真实存在）。
class DbEncryptionUnsupportedException implements Exception {
  const DbEncryptionUnsupportedException();

  @override
  String toString() => 'DbEncryptionUnsupportedException: 当前 SQLite 引擎无加密能力'
      '（PRAGMA cipher_version 为空），拒绝以密钥打开，避免明文落盘';
}

/// 明文 ⇄ 密文的**文件级**迁移与开库前准备。
///
/// 只在库**还没被打开**时运行（`_openConnection` 的 `LazyDatabase` 里），因此
/// 可以独占操作文件，不会与 drift 的连接打架。
///
/// 迁移路径由实测决定（`test/data/db_encryption_sqlcipher_test.dart`）：
/// `PRAGMA rekey` **不能**给明文库加密（引擎明确指路），必须走
/// `ATTACH … AS enc KEY …` + `sqlcipher_export('enc')`。所以这里就是那套流程，
/// 外加"临时文件 + 校验 + 原子替换 + 回退 + 中断恢复"——**这是唯一会丢数据的
/// 一段**，每一步失败都必须让用户回到「原库完好」的状态。
class DbEncryptionMigration {
  const DbEncryptionMigration({
    DatabaseKeyService keyService = const DatabaseKeyService(),
    DbEncryptionSettings settings = const DbEncryptionSettings(),
  })  : _keyService = keyService,
        _settings = settings;

  final DatabaseKeyService _keyService;
  final DbEncryptionSettings _settings;

  /// 迁移中间产物后缀（**不可改**：老版本中断留下的残留靠它识别）。
  static const String tempSuffix = '.enc-tmp';

  /// 迁移前的明文库留底后缀。
  static const String backupSuffix = '.pre-enc';

  /// 文件头是否 `SQLite format 3\0`。
  ///
  /// 读不了时返回 false —— **不确定不当作明文**，避免对未知文件动手迁移。
  static bool looksLikePlaintext(String path) {
    const magic = 'SQLite format 3\u0000';
    try {
      final raf = File(path).openSync();
      try {
        final head = raf.readSync(magic.length);
        if (head.length < magic.length) return false;
        for (var i = 0; i < magic.length; i++) {
          if (head[i] != magic.codeUnitAt(i)) return false;
        }
        return true;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 打开库之前调用：返回本次连接要用的密钥（`null` = 明文库，保持现状）。
  ///
  /// - 无密钥 + 明文库（或库不存在）→ `null`（与今天行为逐字一致）；
  /// - 无密钥 + **密文库** → 抛 [DbEncryptionKeyMissingException]（R5）；
  /// - 有密钥 + 库不存在 → 直接返回密钥（新库即密文）；
  /// - 有密钥 + 库已密文 → 直接返回密钥（幂等，且顺手清掉遗留留底）；
  /// - 有密钥 + 库是明文 → 先迁移（见 [migratePlaintextToEncrypted]），再返回密钥；
  /// - 有密钥 + **已登记关闭**（R6）→ 解回明文并删钥，返回 `null`（见 [_runDisable]）。
  ///
  /// [keyOverride] 仅供测试注入。
  Future<String?> prepareKeyForOpen({
    required String dbPath,
    String? keyOverride,
  }) async {
    final key = keyOverride ?? await _keyService.loadKey();
    final dbFile = File(dbPath);

    // 有密钥就先确认引擎真能加密 —— 否则 PRAGMA key 被静默忽略，用户以为加密了
    // 却全是明文。这里**优先于一切文件操作**：宁可拒绝启动，也不产生假安全。
    if (key != null && !SqlCipherCapability.isSupported) {
      logger.error('DbEncryption',
          '本机 SQLite 无加密能力（${SqlCipherCapability.describe()}），拒绝以密钥打开；'
          'PRAGMA key 会被静默忽略，数据将以明文落盘');
      throw const DbEncryptionUnsupportedException();
    }

    // 中断恢复：上一次替换"主库已改名、临时库还没就位"会留下这种组合，
    // 此时主库不存在但留底在 —— 先把它复名回主库（回滚成明文），再正常走一遍。
    await _rollbackIfMainMissing(dbPath);

    final exists = dbFile.existsSync();
    final disableRequested = await _settings.isDisableRequested();

    if (key == null) {
      // 无密钥就谈不上"关闭加密"：密文库的唯一出路是 R5 引导。顺手把过期的关闭
      // 意图清掉，免得将来密钥又回来了，被一条陈旧意图莫名其妙地解密一次。
      if (disableRequested) await _settings.clearDisableRequest();
      if (exists && !looksLikePlaintext(dbPath)) {
        // 措辞如实：文件层面"密文库"与"根本不是库"长得一样，这里分不出，
        // 也不该在这里分（谁来决定"是缺钥还是坏了"由健康探测负责，见
        // DbHealth.keyUnavailable —— 它才是决定"要不要给隔离出口"的那一层）。
        // 这里统一抛一个**可识别**的异常，好过让 drift 抛出"not a database"
        // 那种既看不出原因、又到处冒的错。
        logger.error('DbEncryption',
            '库非明文且本机无可用密钥，拒绝以无钥方式打开（不猜、不清空、不隔离）');
        throw const DbEncryptionKeyMissingException();
      }
      return null;
    }

    // R6：用户已登记"关闭加密"→ 在开库之前把文件解回明文（成功后删钥）。
    if (disableRequested) {
      return _runDisable(dbPath: dbPath, key: key, exists: exists);
    }

    if (!exists || !looksLikePlaintext(dbPath)) {
      // 新库，或已是密文。已密文时顺手确认留底是否需要清（见下）。
      if (exists && File('$dbPath$backupSuffix').existsSync()) {
        await _dropStaleBackupIfEncryptedOpens(dbPath, key);
      }
      return key;
    }

    await migratePlaintextToEncrypted(dbPath: dbPath, key: key);
    return key;
  }

  /// 明文 → 密文：`ATTACH` + `sqlcipher_export` + 校验 + 原子替换。
  ///
  /// 步骤（任何一步失败都保持/恢复「原明文库完好」）：
  /// 1. 清掉可能残留的临时库；
  /// 2. 明文连接上 `wal_checkpoint(TRUNCATE)`，把 `-wal` 并回主文件
  ///    （否则只搬主文件会丢 WAL 里的页）；
  /// 3. 导出到 `<db>.enc-tmp`（带 key 的 ATTACH）；
  /// 4. 用 key 打开临时库跑 `PRAGMA integrity_check`，非 `ok` 即中止；
  /// 5. 原子替换：主库 → `<db>.pre-enc`，临时库 → 主库，删 `-wal`/`-shm`；
  /// 6. 用 key 复核主库可读，通过后删留底；失败则回滚（留底复名回主库）。
  Future<void> migratePlaintextToEncrypted({
    required String dbPath,
    required String key,
  }) async {
    final tempPath = '$dbPath$tempSuffix';
    final backupPath = '$dbPath$backupSuffix';

    // 1) 残留临时库一律丢弃：它只可能是上次失败/中断的半成品
    final staleTemp = File(tempPath);
    if (staleTemp.existsSync()) {
      await staleTemp.delete();
    }
    if (File(backupPath).existsSync()) {
      await File(backupPath).delete();
    }

    // 2) 合并 WAL（明文档）
    final plain = sqlite3.open(dbPath);
    try {
      plain.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    } finally {
      plain.close();
    }

    // 3) 导出到临时库
    final src = sqlite3.open(dbPath);
    try {
      src.execute("ATTACH DATABASE '$tempPath' AS enc KEY \"x'$key'\"");
      src.select("SELECT sqlcipher_export('enc')");
      src.execute('DETACH DATABASE enc');
    } finally {
      src.close();
    }

    // 4) 校验临时库（打不开或 integrity_check 非 ok 就不要替换主库）
    final enc = sqlite3.open(tempPath);
    try {
      enc.execute("PRAGMA key = \"x'$key'\"");
      final rows = enc.select('PRAGMA integrity_check');
      final verdict = rows.isEmpty
          ? 'no rows'
          : rows.first.values.first?.toString().toLowerCase();
      if (verdict != 'ok') {
        throw StateError('加密库完整性校验未通过: $verdict');
      }
    } catch (e) {
      // 校验失败：删掉半成品，主库原样不动
      enc.close();
      final bad = File(tempPath);
      if (bad.existsSync()) await bad.delete();
      logger.error('DbEncryption', '明文→密文迁移中止（原库未改动）: $e');
      rethrow;
    }
    enc.close();

    // 5) 原子替换
    await File(dbPath).rename(backupPath);
    await File(tempPath).rename(dbPath);
    // 明文库的 WAL 旁路必须删：留着会被当成新库的一部分（页格式不同）
    for (final s in const ['-wal', '-shm']) {
      final f = File('$dbPath$s');
      if (f.existsSync()) await f.delete();
    }

    // 6) 复核；失败回滚
    try {
      _verifyReadable(dbPath: dbPath, key: key);
    } catch (e) {
      logger.error('DbEncryption', '迁移后复核失败，回滚到明文库: $e');
      await File(dbPath).delete();
      await File(backupPath).rename(dbPath);
      rethrow;
    }

    await File(backupPath).delete();
    logger.info('DbEncryption', '明文→密文迁移完成（留底已删）');
  }

  /// 兑现"关闭加密"意图（R6）：库已是明文就只清理；否则解回明文后**才**删钥。
  ///
  /// 失败一律回退到「保持加密可用」：清掉意图、留住密钥、返回 key 继续开库。
  /// 因为此时用户数据完好、应用可用，只是"关闭"没成 —— 这比让应用打不开好得多
  /// （密钥还在，下次还能再点一次关闭）。
  Future<String?> _runDisable({
    required String dbPath,
    required String key,
    required bool exists,
  }) async {
    if (!exists || looksLikePlaintext(dbPath)) {
      await _settings.clearDisableRequest();
      await _keyService.deleteKey();
      // 库已是明文：本机不再有加密数据，"曾启用"标记也该撤（它决定将来的
      // 故障引导走哪条路）。
      await _settings.clearEverEnabled();
      logger.info('DbEncryption', '库本为明文，关闭加密只需清理密钥与意图');
      return null;
    }

    try {
      await migrateEncryptedToPlaintext(dbPath: dbPath, key: key);
    } catch (e) {
      logger.error('DbEncryption', '密文→明文迁移失败，保持加密并放弃本次关闭: $e');
      await _settings.clearDisableRequest();
      return key;
    }

    await _settings.clearDisableRequest();
    await _keyService.deleteKey();
    // 只有**解密成功**之后才撤"曾启用"标记：失败路径上库仍是密文、钥还在，
    // 标记必须留着（否则将来缺钥时会被当成垃圾文件处理）。
    await _settings.clearEverEnabled();
    logger.info('DbEncryption', '整库加密已关闭（库回到明文，密钥已删）');
    return null;
  }

  /// 密文 → 明文（R6 关闭路径），与 [migratePlaintextToEncrypted] 严格对称：
  /// 临时库/主库的角色互换，WAL 合并与原子替换/回退的骨架一致。
  ///
  /// 步骤：
  /// 1. 清残留临时库与留底；
  /// 2. **带 key** 打开并 `wal_checkpoint(TRUNCATE)` —— WAL 里的页只认带 key 的
  ///    连接，不带 key 合并会丢数据；
  /// 3. `ATTACH <db>.enc-tmp AS plain KEY ''`（空 key = 目标不加密）+
  ///    `sqlcipher_export('plain')`；
  /// 4. 校验临时库**确实是明文**且 `integrity_check = ok`；
  /// 5. 原子替换：主库 → 留底，临时库 → 主库，删 `-wal`/`-shm`；
  /// 6. 复核"**无密钥**也能读"，失败则回滚（留底复名回主库）。
  ///
  /// 调用方负责在成功后删钥（见 [_runDisable]）—— 本方法不碰密钥。
  Future<void> migrateEncryptedToPlaintext({
    required String dbPath,
    required String key,
  }) async {
    final tempPath = '$dbPath$tempSuffix';
    final backupPath = '$dbPath$backupSuffix';

    // 1) 残留一律丢弃（只可能是上次失败/中断的半成品）
    if (File(tempPath).existsSync()) await File(tempPath).delete();
    if (File(backupPath).existsSync()) await File(backupPath).delete();

    // 2) 带 key 合并 WAL + 3) 导出到明文临时库
    final enc = sqlite3.open(dbPath);
    try {
      enc.execute("PRAGMA key = \"x'$key'\"");
      enc.execute('PRAGMA wal_checkpoint(TRUNCATE)');
      enc.execute("ATTACH DATABASE '$tempPath' AS plain KEY ''");
      enc.select("SELECT sqlcipher_export('plain')");
      enc.execute('DETACH DATABASE plain');
    } finally {
      enc.close();
    }

    // 4) 校验临时库：必须**真是明文**且结构完好
    try {
      if (!looksLikePlaintext(tempPath)) {
        throw StateError('导出的临时库不是明文 SQLite（关闭未生效）');
      }
      final plain = sqlite3.open(tempPath);
      try {
        final rows = plain.select('PRAGMA integrity_check');
        final verdict = rows.isEmpty
            ? 'no rows'
            : rows.first.values.first?.toString().toLowerCase();
        if (verdict != 'ok') {
          throw StateError('明文库完整性校验未通过: $verdict');
        }
      } finally {
        plain.close();
      }
    } catch (e) {
      final bad = File(tempPath);
      if (bad.existsSync()) await bad.delete();
      logger.error('DbEncryption', '密文→明文迁移中止（原库未改动）: $e');
      rethrow;
    }

    // 5) 原子替换
    await File(dbPath).rename(backupPath);
    await File(tempPath).rename(dbPath);
    for (final s in const ['-wal', '-shm']) {
      final f = File('$dbPath$s');
      if (f.existsSync()) await f.delete();
    }

    // 6) 复核"无密钥可读"（这正是关闭要达成的效果），失败回滚回加密库
    try {
      if (!looksLikePlaintext(dbPath)) {
        throw StateError('替换后的主库仍非明文');
      }
      final check = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      try {
        check.select('SELECT count(*) FROM sqlite_master');
      } finally {
        check.close();
      }
    } catch (e) {
      logger.error('DbEncryption', '关闭加密后复核失败，回滚到加密库: $e');
      await File(dbPath).delete();
      await File(backupPath).rename(dbPath);
      rethrow;
    }

    await File(backupPath).delete();
    logger.info('DbEncryption', '密文→明文迁移完成（无密钥可读，留底已删）');
  }

  /// 用密钥复核主库「能读」。
  void _verifyReadable({required String dbPath, required String key}) {
    final db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
    try {
      db.execute("PRAGMA key = \"x'$key'\"");
      db.select('SELECT count(*) FROM sqlite_master');
    } finally {
      db.close();
    }
  }

  /// 主库缺失但留底在 → 上一次替换中断，回滚成明文库。
  ///
  /// 不这么做的话，「主库不存在」会被当成"新库"直接用密钥建库，**留底里的
  /// 用户数据就被永久遗忘了**。
  Future<void> _rollbackIfMainMissing(String dbPath) async {
    final main = File(dbPath);
    final backup = File('$dbPath$backupSuffix');
    if (main.existsSync() || !backup.existsSync()) return;

    logger.warning('DbEncryption', '检测到上次迁移中断（主库缺失、留底在），回滚成明文库');
    await backup.rename(dbPath);
    final temp = File('$dbPath$tempSuffix');
    if (temp.existsSync()) await temp.delete();
  }

  /// 已密文 + 留底残留：确认主库确实能用密钥打开后再删留底。
  ///
  /// 不无条件删：万一那次替换其实没成功（留底才是唯一完好的那份），
  /// 直接删就是把用户数据删了。
  Future<void> _dropStaleBackupIfEncryptedOpens(
      String dbPath, String key) async {
    final backup = File('$dbPath$backupSuffix');
    try {
      _verifyReadable(dbPath: dbPath, key: key);
    } catch (e) {
      logger.error('DbEncryption',
          '主库可用密钥复核失败，保留留底 ${p.basename(backup.path)} 以便恢复: $e');
      return;
    }
    await backup.delete();
    logger.info('DbEncryption', '主库已密文可读，清理上次迁移的残留留底');
  }
}
