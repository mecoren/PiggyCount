import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

import '../services/system/logger_service.dart';

/// 本地 SQLite 库健康状态。
enum DbHealth {
  /// 可正常打开且 `PRAGMA quick_check` 通过；或库文件尚不存在（首次安装）。
  ok,

  /// 能打开、但快速校验报错：页级损坏 / 索引不一致 / 页校验和不匹配。
  corrupted,

  /// 连「是一个数据库」都不成立：非 SQLite 文件、被截断、IO/权限错误、
  /// 或被其他进程独占。
  unreadable,
}

/// 健康探测结果。面向开发者诊断，不含用户内容。
class DbHealthResult {
  final DbHealth health;

  /// 被探测的库文件绝对路径。
  final String? dbPath;

  /// `quick_check` 的首条非 `ok` 输出，或打开失败的原始原因。
  final String? detail;

  const DbHealthResult(this.health, {this.dbPath, this.detail});

  bool get isHealthy => health == DbHealth.ok;
}

const DbHealthResult _healthy = DbHealthResult(DbHealth.ok);

/// 本地 SQLite 库的健康探测与损坏恢复（审计 P1-6）。
///
/// **为什么需要**：此前 [PiggyDatabase] 的打开路径对损坏库没有任何检测，
/// 而 `main()` 的启动链各自吞掉自身异常。于是损坏库的后果不是崩溃，而是
/// 「每条查询都失败」——用户看到的是一个数据全空、且没有任何解释的界面。
/// 这是最坏的失败形态：静默，且不可自我解释。
///
/// **为什么探测用只读连接、而不是复用 `PiggyDatabase`**：复用主库实例会跑
/// 迁移，对已损坏的库存在写入并**扩大损坏面**的风险。只读连接在文件层面就
/// 不具备写入能力，是探测应有的最小权限。
///
/// **绝不自动删除或搬移用户数据**：[quarantine] 只在用户显式确认后调用，
/// 且语义是「移到保留目录」而非删除——损坏库往往仍可被专业工具部分恢复。
class DatabaseHealthService {
  static const String dbFileName = 'piggycount.sqlite';

  /// SQLite 在 WAL 模式下与主库配套的两个旁路文件。
  static const List<String> _sidecarSuffixes = ['', '-wal', '-shm'];

  /// 解析数据库文件绝对路径（与应用实际使用的路径同源）。
  static Future<String> resolveDbPath() async {
    final dir = await getApplicationDocumentsDirectory();
    return p.join(dir.path, dbFileName);
  }

  /// 只读探测。**不修改**数据库文件。
  ///
  /// [path] 仅用于测试注入；生产调用不带参数。
  static Future<DbHealthResult> check({String? path}) async {
    final String dbPath;
    try {
      dbPath = path ?? await resolveDbPath();
    } catch (e) {
      // 连路径都拿不到（平台通道不可用）——不能据此判定库损坏，
      // 否则会在不支持的平台上误报，故按健康处理并留痕。
      logger.warning('DbHealth', '无法解析数据库路径，跳过健康探测: $e');
      return _healthy;
    }

    if (!File(dbPath).existsSync()) {
      // 首次安装：库还不存在，由正常打开路径去创建。这不是异常。
      return DbHealthResult(DbHealth.ok, dbPath: dbPath);
    }

    Database? db;
    try {
      db = sqlite3.open(dbPath, mode: OpenMode.readOnly);
      final rows = db.select('PRAGMA quick_check');
      if (rows.isEmpty) {
        return DbHealthResult(DbHealth.corrupted,
            dbPath: dbPath, detail: 'quick_check returned no rows');
      }
      final first = rows.first.values.first?.toString().toLowerCase();
      if (first == 'ok') {
        return DbHealthResult(DbHealth.ok, dbPath: dbPath);
      }
      return DbHealthResult(DbHealth.corrupted, dbPath: dbPath, detail: first);
    } on SqliteException catch (e) {
      // 打开成功但语句失败：SQLite 对「不是数据库」这类错误是延迟到
      // 首次语句执行时才报的（SQLITE_NOTADB）。
      return DbHealthResult(DbHealth.unreadable,
          dbPath: dbPath, detail: e.message);
    } catch (e) {
      return DbHealthResult(DbHealth.unreadable, dbPath: dbPath, detail: '$e');
    } finally {
      db?.close();
    }
  }

  /// 把损坏的库连同 `-wal`/`-shm` 一起移入保留目录。
  ///
  /// **移动而非删除**，返回保留目录路径；调用方应把该路径告知用户，
  /// 使其可自行留存/提交分析。目录为空（库文件本身不存在）时返回 null。
  ///
  /// 目录名按秒取时间戳，再叠加自增后缀直到不存在——否则同一秒内连续两次
  /// 保留会命中同一目录，第二次的 `rename` 会因目标已存在而失败（Windows 上
  /// 直接抛 FileSystemException）。
  static Future<String?> quarantine({String? path}) async {
    final dbPath = path ?? await resolveDbPath();
    if (!File(dbPath).existsSync()) return null;

    var targetDir = Directory('$dbPath.corrupt-${_stamp()}');
    var suffix = 1;
    while (targetDir.existsSync()) {
      targetDir = Directory('$dbPath.corrupt-${_stamp()}-$suffix');
      suffix++;
    }
    await targetDir.create(recursive: true);

    for (final s in _sidecarSuffixes) {
      final src = File('$dbPath$s');
      if (src.existsSync()) {
        await src.rename(p.join(targetDir.path, p.basename(src.path)));
      }
    }
    logger.warning('DbHealth', '损坏数据库已移入保留目录: ${targetDir.path}');
    return targetDir.path;
  }

  /// 把损坏的库复制一份并返回其路径，供用户经分享面板导出。
  ///
  /// **复制而非移动**：导出是只读诉求，不应改变本机状态。
  /// [destDir] 缺省为系统临时目录；允许覆盖以便测试与调用方自定义落点。
  static Future<String?> exportCopy({String? path, String? destDir}) async {
    final dbPath = path ?? await resolveDbPath();
    final src = File(dbPath);
    if (!src.existsSync()) return null;

    final dir = destDir ?? (await getTemporaryDirectory()).path;
    final dest = File(p.join(dir, 'piggycount-corrupt-${_stamp()}.sqlite'));
    await src.copy(dest.path);
    logger.info('DbHealth', '损坏数据库副本已导出: ${dest.path}');
    return dest.path;
  }

  /// 文件名安全的时间戳（不含 `:` 等在 Windows 上非法的字符）。
  static String _stamp() {
    final now = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${now.year}${two(now.month)}${two(now.day)}'
        '-${two(now.hour)}${two(now.minute)}${two(now.second)}';
  }
}
