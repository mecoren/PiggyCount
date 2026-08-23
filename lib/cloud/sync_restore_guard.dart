/// 同步恢复临界区守卫（审计 S6）。
///
/// 定时备份必须让位于启动恢复/手动全量流程：恢复进行到一半时触发备份，
/// 会把「半恢复态 DB」打包上传并覆盖当日好备份，破坏灾难恢复能力。
/// 用法：
/// - 恢复侧：`await SyncRestoreGuard.run(() => checker.runIfNeeded(...))`
/// - 备份侧 onCheck 开头：`if (SyncRestoreGuard.isBusy) return;`
class SyncRestoreGuard {
  SyncRestoreGuard._();

  static int _depth = 0;

  static bool get isBusy => _depth > 0;

  static void begin() => _depth++;

  static void end() {
    if (_depth > 0) _depth--;
  }

  static Future<T> run<T>(Future<T> Function() body) async {
    begin();
    try {
      return await body();
    } finally {
      end();
    }
  }
}
