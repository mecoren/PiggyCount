import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../utils/notification_factory.dart';
import '../../services/system/logger_service.dart';
import 'recurring_due_reminder_service.dart';

/// 记账提醒监控服务
///
/// 功能：
/// 1. 监听应用生命周期
/// 2. 应用从后台恢复到前台时，检查提醒是否仍然有效
/// 3. 如果提醒丢失，自动重新设置
///
/// 覆盖两类提醒（通知 ID 段互不冲突）：
/// - `1001` 每日记账提醒（[reminder_enabled]）
/// - `3000+recurringId` 周期账单到期提醒（[kRecurringDueReminderEnabledKey]，
///   需要经 [attachRepository] 注入只读仓储后才能补种）
///
/// 两个开关独立：任一类关闭只跳过自己那条，不影响另一类。
class ReminderMonitorService with WidgetsBindingObserver {
  static final ReminderMonitorService _instance = ReminderMonitorService._internal();
  factory ReminderMonitorService() => _instance;
  ReminderMonitorService._internal();

  DateTime? _lastCheckTime;
  static const _checkInterval = Duration(hours: 6); // 最多6小时检查一次

  /// 只读仓储（`PiggyRepository`）。为 null 时跳过周期账单提醒补种，
  /// 每日提醒不受影响（老调用方未注入也能正常工作）。
  dynamic _repository;

  /// 注入仓储（`main.dart` 启动时调用一次）。
  void attachRepository(dynamic repository) {
    _repository = repository;
  }

  /// 开始监控
  void startMonitoring() {
    WidgetsBinding.instance.addObserver(this);
    logger.info('Reminder', '✅ 记账提醒监控服务已启动');
  }

  /// 停止监控
  void stopMonitoring() {
    WidgetsBinding.instance.removeObserver(this);
    logger.info('Reminder', '🛑 记账提醒监控服务已停止');
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    logger.info('Reminder', '📱 应用生命周期变化: $state');

    if (state == AppLifecycleState.resumed) {
      // 应用从后台恢复到前台
      _checkAndRestoreReminder();
    }
  }

  /// 检查并恢复提醒
  Future<void> _checkAndRestoreReminder() async {
    try {
      // 避免频繁检查
      if (_lastCheckTime != null &&
          DateTime.now().difference(_lastCheckTime!) < _checkInterval) {
        logger.info('Reminder', 'ℹ️  距离上次检查时间过短，跳过本次检查');
        return;
      }

      logger.info('Reminder', '🔍 开始检查提醒状态...');
      _lastCheckTime = DateTime.now();

      final prefs = await SharedPreferences.getInstance();

      List<PendingNotificationRequest> pending;
      try {
        pending =
            await NotificationFactory.getInstance().getPendingNotifications();
      } catch (e) {
        logger.warning('Reminder', '❌ 读取待处理通知失败: $e');
        return;
      }

      await _checkDailyReminder(prefs, pending);
      await _checkRecurringDueReminders(prefs, pending);
    } catch (e) {
      logger.warning('Reminder', '❌ 检查提醒状态失败: $e');
    }
  }

  /// 每日记账提醒（1001）：开关开启但通知丢失 → 按用户设定时间重设。
  Future<void> _checkDailyReminder(
    SharedPreferences prefs,
    List<PendingNotificationRequest> pending,
  ) async {
    final isEnabled = prefs.getBool('reminder_enabled') ?? false;
    if (!isEnabled) {
      logger.info('Reminder', 'ℹ️  用户未启用记账提醒');
      return;
    }

    final hasMainReminder = pending.any((n) => n.id == 1001);
    if (hasMainReminder) {
      logger.info('Reminder', '✅ 记账提醒状态正常 (待处理通知数: ${pending.length})');
      return;
    }

    logger.warning('Reminder', '⚠️  警告：检测到记账提醒丢失，正在重新设置...');
    final hour = prefs.getInt('reminder_hour') ?? 21;
    final minute = prefs.getInt('reminder_minute') ?? 0;

    await NotificationFactory.getInstance().scheduleDailyReminder(
      id: 1001,
      title: '记账提醒',
      body: '别忘了记录今天的收支哦 💰',
      hour: hour,
      minute: minute,
    );

    logger.info('Reminder', '✅ 记账提醒已重新设置');
  }

  /// 周期账单到期提醒（3000..3999）：开关开启但整段调度都丢了 → 全量重调度。
  ///
  /// 只在「一条都不剩」时补种：部分丢失无法区分「模板被停用/删除」与「调度
  /// 真的丢了」，全量重调度会顺带清掉孤儿调度，故整段缺失才是可靠信号。
  Future<void> _checkRecurringDueReminders(
    SharedPreferences prefs,
    List<PendingNotificationRequest> pending,
  ) async {
    final enabled = prefs.getBool(kRecurringDueReminderEnabledKey) ?? false;
    if (!enabled) {
      logger.info('Reminder', 'ℹ️  用户未启用周期账单到期提醒');
      return;
    }

    final repository = _repository;
    if (repository == null) {
      logger.info('Reminder', 'ℹ️  未注入仓储，跳过周期账单到期提醒补种');
      return;
    }

    final hasAny =
        pending.any((n) => RecurringDueReminderService.ownsNotificationId(n.id));
    if (hasAny) {
      logger.info('Reminder', '✅ 周期账单到期提醒状态正常');
      return;
    }

    logger.warning('Reminder', '⚠️  检测到周期账单到期提醒丢失，正在重新调度...');
    await RecurringDueReminderService(repository: repository).rescheduleAll();
    logger.info('Reminder', '✅ 周期账单到期提醒已重新调度');
  }
}
