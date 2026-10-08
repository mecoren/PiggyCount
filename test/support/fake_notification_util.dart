// 通知层的测试替身：记录调度/取消，避免触碰平台通道与单例工厂
// （`NotificationFactory.getInstance()` 在非 Android/iOS 宿主上会抛
// UnsupportedError，测试必须构造注入）。

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'package:piggycount/utils/notification_util.dart';

/// 记录所有调度/立即推送/取消调用，并允许注入待处理通知列表。
class FakeNotificationUtil implements NotificationUtil {
  /// 单次调度记录。
  final List<({int id, String title, String body, DateTime at})> scheduled = [];

  /// 立即推送记录。
  final List<({int id, String title, String body})> shown = [];

  /// 取消记录（按调用顺序）。
  final List<int> cancelled = [];

  /// [getPendingNotifications] 的返回值。
  List<PendingNotificationRequest> pending = [];

  @override
  Future<void> scheduleOnceReminder({
    required int id,
    required String title,
    required String body,
    required DateTime scheduledDate,
  }) async {
    scheduled.add((id: id, title: title, body: body, at: scheduledDate));
  }

  @override
  Future<void> showNotification({
    required int id,
    required String title,
    required String body,
  }) async {
    shown.add((id: id, title: title, body: body));
  }

  @override
  Future<void> cancelNotification(int id) async {
    cancelled.add(id);
  }

  @override
  Future<List<PendingNotificationRequest>> getPendingNotifications() async =>
      pending;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> requestPermissions() async => true;

  @override
  Future<void> scheduleDailyReminder({
    required int id,
    required String title,
    required String body,
    required int hour,
    required int minute,
  }) async {}

  @override
  Future<void> cancelAllNotifications() async {}

  @override
  Future<bool> checkPermissionStatus() async => true;
}

/// 造一条待处理通知（`PendingNotificationRequest` 是 4 个位置参数）。
PendingNotificationRequest pendingNotification(int id) =>
    PendingNotificationRequest(id, 'title-$id', 'body-$id', '');
