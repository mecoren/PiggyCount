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

  /// P2-4/SEC-08：两次自动尝试的最小间隔（失败补试的退避间隔）。
  ///
  /// 备份失败不再占用当日名额（P2-4），弱网日按此时长自动补试，
  /// 直到当日成功或跨日；同时也是失败后的防抖——调度器每分钟 tick，
  /// 无间隔会分钟级连打云端。
  static const Duration minAttemptInterval = Duration(minutes: 30);

  /// SEC-08：时钟回拨判定容差。当前时刻比上次尝试记录早于该值视为
  /// 回拨（NTP 小幅修正不误伤），回拨期间不再触发自动备份。
  static const Duration clockRollbackTolerance = Duration(minutes: 5);

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

  /// P2-4/SEC-08：失败补试的当次尝试是否放行（纯函数，可单测）。
  ///
  /// [lastAttemptMillis] 为上次自动尝试的 epoch 毫秒（可能成功可能失败，
  /// 无记录为 null）。放行条件：
  /// 1. 与上次尝试间隔 ≥ [minAttemptInterval]（失败退避：调度器分钟级
  ///    tick，弱网失败日每 30 分钟补试一次，直到成功或跨日）；
  /// 2. 未发生时钟回拨（now 早于上次尝试减 [clockRollbackTolerance]）——
  ///    时钟回拨到当日窗口起点会重复触发备份，重复上传同内容对象虽
  ///    幂等（内容寻址/当日文件名覆盖），但会打满云端请求与流量；
  ///    小幅 NTP 修正（≤容差）不误伤。
  ///
  /// 上次尝试已是「今日之前」（跨日残留）→ 间隔条件必然满足，放行。
  static bool attemptAllowed({
    required int? lastAttemptMillis,
    required DateTime now,
  }) {
    if (lastAttemptMillis == null) return true;
    final lastAttempt = DateTime.fromMillisecondsSinceEpoch(lastAttemptMillis);
    final elapsed = now.difference(lastAttempt);
    if (elapsed < clockRollbackTolerance) {
      // 负值 = 时钟早于上次尝试（回拨）；正值小于容差 = 回拨后小幅爬回，
      // 两者一律按回拨处理，等真实时钟追平或跨日。
      return false;
    }
    return elapsed >= minAttemptInterval;
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
