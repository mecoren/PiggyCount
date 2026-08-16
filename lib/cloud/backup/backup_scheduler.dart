import 'dart:async';

/// 每日定时备份调度器（/prd/cloud_backup/design.md §3.4）
///
/// 职责刻意收窄：只做周期 tick + 互斥；触发条件判定是纯静态函数
/// [shouldTriggerNow]（可单测），业务编排在 app.dart 注入的 onCheck 里。
class BackupScheduler {
  BackupScheduler({required this.onCheck});

  /// 每分钟检查一次（App 运行期间；无后台常驻能力为已声明的非目标）
  static const Duration checkInterval = Duration(minutes: 1);

  /// 每日默认触发时间（HH:mm）
  static const String defaultBackupTime = '22:00';

  final Future<void> Function() onCheck;

  Timer? _timer;
  bool _checking = false;

  void start() {
    _timer ??= Timer.periodic(checkInterval, (_) => _tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 互斥：上一次检查（含备份执行）未完成时跳过本次 tick
    if (_checking) return;
    _checking = true;
    try {
      await onCheck();
    } catch (e) {
      // 调度层吞异常：业务层已自行记录成败状态
    } finally {
      _checking = false;
    }
  }

  /// 触发条件（全部满足才触发）：
  /// 1. 开关开启
  /// 2. 当前时刻 ≥ 今日设定时间（含「启动时已过窗口」的补触发）
  /// 3. 当日尚未触发过（backup_last_date ≠ 今天，成败均算）
  static bool shouldTriggerNow({
    required bool enabled,
    required int scheduledMinutes,
    required String? lastDate,
    required DateTime now,
  }) {
    if (!enabled) return false;
    if (lastDate == formatDate(now)) return false;
    return _minutesOfDay(now) >= scheduledMinutes;
  }

  /// 解析 "HH:mm" 为当日分钟数；非法输入回落 0 点（当日必触发兜底）
  static int parseHhMm(String value) {
    final parts = value.split(':');
    final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return h.clamp(0, 23) * 60 + m.clamp(0, 59);
  }

  /// 分钟数格式化为 "HH:mm"
  static String formatHhMm(int minutes) {
    final h = (minutes ~/ 60).clamp(0, 23);
    final m = (minutes % 60).clamp(0, 59);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// 本地时区日期 → "yyyy-MM-dd"（备份文件名与 last_date 共用）
  static String formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static int _minutesOfDay(DateTime now) => now.hour * 60 + now.minute;
}

/// 日期工具别名（CloudBackupService 文件名生成共用同一实现）
class BackupDateUtils {
  static String formatDate(DateTime d) => BackupScheduler.formatDate(d);
}
