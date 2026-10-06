import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'notification_util.dart' as util;
import '../services/system/logger_service.dart';

/// iOS 特定的通知实现
class IOSNotificationUtil implements util.NotificationUtil {
  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  IOSNotificationUtil(this._plugin);

  @override
  Future<void> initialize() async {
    if (_initialized) return;

    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(iOS: iosSettings);

    await _plugin.initialize(settings: initSettings);

    // 初始化后立即请求权限
    await requestPermissions();

    _initialized = true;

    logger.info('Notification', '[iOS] 通知服务初始化完成');
  }

  @override
  Future<bool> requestPermissions() async {
    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

    if (iosPlugin == null) return false;

    final granted = await iosPlugin.requestPermissions(
      alert: true,
      badge: true,
      sound: true,
    );

    logger.info('Notification', '[iOS] 通知权限请求结果: ${granted ?? false}');
    return granted ?? false;
  }

  @override
  Future<void> scheduleDailyReminder({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {
    if (!_initialized) await initialize();

    final scheduledDate = util.calculateNextReminderTime(hour, minute);
    final tzScheduledDate = util.convertToTZDateTime(scheduledDate);

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
      badgeNumber: 1,
    );

    const notificationDetails = NotificationDetails(iOS: iosDetails);

    try {
      // fln 22 起顶层 zonedSchedule 强制要求 androidScheduleMode；iOS 侧不消费它，
      // 仅 Android 用来决定精确/非精确闹钟。
      await _plugin.zonedSchedule(
        id: id,
        title: title,
        body: body,
        scheduledDate: tzScheduledDate,
        notificationDetails: notificationDetails,
        androidScheduleMode: AndroidScheduleMode.exact,
        matchDateTimeComponents: DateTimeComponents.time, // 每天重复
      );

      logger.info('Notification', '[iOS] 每日提醒设置成功: $hour:$minute (下次: $scheduledDate)');
    } catch (e) {
      logger.warning('Notification', '[iOS] 设置每日提醒失败: $e');
      rethrow;
    }
  }

  @override
  Future<void> scheduleOnceReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    if (!_initialized) await initialize();

    final tzScheduledDate = util.convertToTZDateTime(scheduledDate);

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
      sound: 'default',
    );

    const notificationDetails = NotificationDetails(iOS: iosDetails);

    // 同上：iOS 不消费 androidScheduleMode，仅为满足 fln 22 的必填签名。
    await _plugin.zonedSchedule(
      id: id,
      title: title,
      body: body,
      scheduledDate: tzScheduledDate,
      notificationDetails: notificationDetails,
      androidScheduleMode: AndroidScheduleMode.exact,
    );

    logger.info('Notification', '[iOS] 单次提醒设置成功: $scheduledDate');
  }

  @override
  Future<void> cancelNotification(int id) async {
    if (!_initialized) await initialize();
    await _plugin.cancel(id: id);
    logger.info('Notification', '[iOS] 通知已取消: $id');
  }

  @override
  Future<void> cancelAllNotifications() async {
    if (!_initialized) await initialize();
    await _plugin.cancelAll();
    logger.info('Notification', '[iOS] 所有通知已取消');
  }

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    if (!_initialized) await initialize();

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const notificationDetails = NotificationDetails(iOS: iosDetails);

    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: notificationDetails,
    );
    logger.info('Notification', '[iOS] 即时通知已显示: $title');
  }

  @override
  Future<List<PendingNotificationRequest>> getPendingNotifications() async {
    if (!_initialized) await initialize();
    return await _plugin.pendingNotificationRequests();
  }

  @override
  Future<bool> checkPermissionStatus() async {
    final iosPlugin = _plugin
        .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>();

    if (iosPlugin == null) return false;

    // iOS 需要实际请求一次才能知道状态
    // 或者可以检查之前是否授权过
    return true; // iOS 没有直接检查的 API，需要通过实际调用判断
  }
}
