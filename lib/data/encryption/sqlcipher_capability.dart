import 'package:sqlite3/sqlite3.dart';

/// 当前 native SQLite **是否真的具备整库加密能力**（= 是不是 SQLCipher 构建）。
///
/// **为什么必须有这个探测**：`PRAGMA key` 在普通 SQLite 上是**未知 pragma，被
/// 静默忽略** —— 于是"密钥存好了、代码也老老实实调了 key，但落盘仍是明文"
/// 这种最坏状态完全无声无息。2026-10-05 在 Android 产物上实测确认过这个坑真实
/// 存在（APK 里根本没有 cipher 库，`PRAGMA key` 不报错也不生效）。
///
/// 因此：凡是要用密钥的地方，**先问这一句**；问不出能力就拒绝，不要往下走。
class SqlCipherCapability {
  const SqlCipherCapability();

  static bool? _cached;

  /// 仅供测试：清掉缓存，让下次调用重新探测。
  static void resetCacheForTesting() => _cached = null;

  /// SQLCipher 会返回形如 `4.6.1 community` 的 `PRAGMA cipher_version`；
  /// 普通 SQLite 对未知 pragma 回**空结果集**（不报错）。
  static bool get isSupported {
    final cached = _cached;
    if (cached != null) return cached;

    var supported = false;
    try {
      final db = sqlite3.openInMemory();
      try {
        final rows = db.select('PRAGMA cipher_version');
        supported = rows.isNotEmpty &&
            (rows.first.values.first?.toString().isNotEmpty ?? false);
      } finally {
        db.close();
      }
    } catch (_) {
      // 连库都开不起来：当作不支持（调用方会拒绝用密钥，属 fail-safe 方向）
      supported = false;
    }
    _cached = supported;
    return supported;
  }

  /// SQLCipher 版本串（不支持时为空串）。
  static String? get cipherVersion {
    try {
      final db = sqlite3.openInMemory();
      try {
        final rows = db.select('PRAGMA cipher_version');
        if (rows.isEmpty) return null;
        final v = rows.first.values.first?.toString();
        return (v == null || v.isEmpty) ? null : v;
      } finally {
        db.close();
      }
    } catch (_) {
      return null;
    }
  }

  /// 引擎自述，用于启动日志与诊断页：
  /// `SQLCipher 4.6.1 community (SQLite 3.50.2)` / `SQLite 3.50.2（无加密能力）`。
  ///
  /// 有了这一行，"这台设备到底跑的是哪个引擎"就不再靠猜 —— 这正是本次踩坑时
  /// 最缺的那条证据。
  static String describe() {
    String? sqliteVersion;
    try {
      final db = sqlite3.openInMemory();
      try {
        final rows = db.select('SELECT sqlite_version() AS v');
        sqliteVersion = rows.isEmpty ? null : rows.first['v']?.toString();
      } finally {
        db.close();
      }
    } catch (_) {
      sqliteVersion = null;
    }

    final base = sqliteVersion == null ? 'SQLite(版本未知)' : 'SQLite $sqliteVersion';
    final cipher = cipherVersion;
    return cipher == null ? '$base（无加密能力）' : 'SQLCipher $cipher ($base)';
  }
}
