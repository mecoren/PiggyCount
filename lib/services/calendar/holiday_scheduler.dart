import 'dart:async';

import 'holiday_service.dart';

/// 节假日更新调度器（prd/calendar_holiday/design.md 决策 4；2026-09-29 修订为
/// **每月一次**口径 —— 判定在 [HolidayService.shouldUpdateNow]，本层只管 tick）。
///
/// 结构刻意对齐既有 [BackupScheduler]：只做周期 tick + 互斥，触发条件交给
/// 静态纯函数（可单测），业务编排在 app.dart 注入的 onCheck 里。
/// 无后台常驻能力，仅在 App 运行期间生效（与备份调度同口径）。
class HolidayScheduler {
  HolidayScheduler({required this.onCheck});

  /// 每分钟检查一次（与 BackupScheduler 同频）
  static const Duration checkInterval = Duration(minutes: 1);

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
    // 互斥：上一次检查（含网络拉取，最坏 20s×2 年）未完成时跳过本次 tick
    if (_checking) return;
    _checking = true;
    try {
      await onCheck();
    } catch (_) {
      // 调度层吞异常：Service 已自行记录成败（updateNow 抛出的仅影响调用方）
    } finally {
      _checking = false;
    }
  }

  /// 触发条件：开关开启 + [HolidayService.shouldUpdateNow] 判定为「该更新」。
  ///
  /// 判定口径**单一来源**在 Service（时钟语义只此一处），本函数只补开关项，
  /// 避免两处日期数学各自漂移。
  static bool shouldTriggerNow({
    required bool enabled,
    required int lastUpdateMs,
    required DateTime now,
  }) =>
      enabled &&
      HolidayService.shouldUpdateNow(
        lastUpdateMs: lastUpdateMs,
        now: now,
      );
}
