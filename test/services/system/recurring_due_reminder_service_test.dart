// 周期账单到期提醒：调度时间 / 跳过窗口 / 取消 / 开关 / 孤儿清理 / 段隔离。
//
// 时间口径由 nextDueDateAfter 决定（其自身口径见
// test/services/data/recurring_next_due_date_test.dart），本文件钉住「提醒这一层」
// 的接线：ID 段、提前 3 天 10:00、开关短路、只动 3000..3999。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/system/recurring_due_reminder_service.dart';

import '../../support/fake_notification_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late FakeNotificationUtil notifications;

  /// 固定「现在」：2026-10-08 09:00。
  final now = DateTime(2026, 10, 8, 9);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    notifications = FakeNotificationUtil();
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '账本',
          currency: const d.Value('CNY'),
          syncId: const d.Value('ledger-1'),
        ));
  });

  tearDown(() async => db.close());

  RecurringDueReminderService service() => RecurringDueReminderService(
        repository: repo,
        notificationUtil: notifications,
        now: () => now,
      );

  Future<void> enableSwitch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kRecurringDueReminderEnabledKey, enabled);
  }

  Future<int> seedTemplate({
    String type = 'expense',
    bool enabled = true,
    String frequency = 'monthly',
    int? dayOfMonth,
    String? note,
    DateTime? startDate,
    DateTime? endDate,
    String? currencyCode,
  }) {
    return repo.addRecurringTransaction(
      ledgerId: 1,
      type: type,
      amount: 100,
      categoryId: null,
      note: note,
      frequency: frequency,
      interval: 1,
      dayOfMonth: dayOfMonth,
      startDate: startDate ?? DateTime(2026, 1, 20),
      endDate: endDate,
      enabled: enabled,
      currencyCode: currencyCode,
    );
  }

  group('reminderTimeFor', () {
    test('扣款日前 3 天 10:00', () {
      expect(
        RecurringDueReminderService.reminderTimeFor(
          DateTime(2026, 10, 20),
          now: DateTime(2026, 10, 8, 9),
        ),
        DateTime(2026, 10, 17, 10),
      );
    });

    test('提前窗口已过 → null（不补发）', () {
      expect(
        RecurringDueReminderService.reminderTimeFor(
          DateTime(2026, 10, 10),
          now: DateTime(2026, 10, 8, 9),
        ),
        isNull,
      );
    });
  });

  group('ownsNotificationId', () {
    test('只认 3000..3999', () {
      expect(RecurringDueReminderService.ownsNotificationId(1001), isFalse);
      expect(RecurringDueReminderService.ownsNotificationId(2000), isFalse);
      expect(RecurringDueReminderService.ownsNotificationId(2999), isFalse);
      expect(RecurringDueReminderService.ownsNotificationId(3000), isTrue);
      expect(RecurringDueReminderService.ownsNotificationId(3999), isTrue);
      expect(RecurringDueReminderService.ownsNotificationId(4000), isFalse);
    });
  });

  group('调度', () {
    test('开关关闭 → 一次都不调度、不读库', () async {
      await seedTemplate(dayOfMonth: 20, note: '视频会员');
      await service().rescheduleAll();

      expect(notifications.scheduled, isEmpty);
      expect(notifications.cancelled, isEmpty);
    });

    test('开关开启 → 按扣款日前 3 天 10:00 调度，ID = 3000 + recurringId', () async {
      await enableSwitch(true);
      final id = await seedTemplate(dayOfMonth: 20, note: '视频会员');

      await service().rescheduleAll();

      expect(notifications.scheduled, hasLength(1));
      final entry = notifications.scheduled.single;
      expect(entry.id, RecurringDueReminderService.notificationIdFor(id));
      expect(entry.at, DateTime(2026, 10, 17, 10));
      expect(entry.title, contains('视频会员'));
      expect(entry.body, isNotEmpty);
    });

    test('提前窗口已过 → 不调度（跳过本次）', () async {
      await enableSwitch(true);
      await seedTemplate(dayOfMonth: 10, note: '窗口已过');

      await service().rescheduleAll();

      expect(notifications.scheduled, isEmpty);
    });

    test('收入型与已停用模板不调度，且既有调度被清掉', () async {
      await enableSwitch(true);
      await seedTemplate(dayOfMonth: 20, note: '工资', type: 'income');
      final disabledId =
          await seedTemplate(dayOfMonth: 20, note: '已停用', enabled: false);
      notifications.pending = [
        pendingNotification(
            RecurringDueReminderService.notificationIdFor(disabledId)),
      ];

      await service().rescheduleAll();

      expect(notifications.scheduled, isEmpty);
      expect(
        notifications.cancelled,
        contains(RecurringDueReminderService.notificationIdFor(disabledId)),
        reason: '模板被停用后，它既有的待发提醒必须撤掉',
      );
    });

    test('endDate 已过 → 不调度且取消既有调度', () async {
      await enableSwitch(true);
      final id = await seedTemplate(
        dayOfMonth: 20,
        note: '已结束',
        endDate: DateTime(2026, 9, 30),
      );

      await service().rescheduleAll();

      expect(notifications.scheduled, isEmpty);
      expect(
        notifications.cancelled,
        contains(RecurringDueReminderService.notificationIdFor(id)),
      );
    });

    test('rescheduleAll 清理管辖段内的孤儿调度，不动其它段', () async {
      await enableSwitch(true);
      final activeId = await seedTemplate(dayOfMonth: 20, note: '视频会员');
      notifications.pending = [
        pendingNotification(1001),
        pendingNotification(2001),
        pendingNotification(3999), // 无对应模板 → 孤儿
        pendingNotification(4001),
      ];

      await service().rescheduleAll();

      expect(notifications.cancelled, [3999]);
      expect(
        notifications.scheduled.map((e) => e.id),
        contains(RecurringDueReminderService.notificationIdFor(activeId)),
      );
    });
  });

  group('取消', () {
    test('cancelForTemplate 精确取消该模板的 ID', () async {
      await service().cancelForTemplate(42);
      expect(
        notifications.cancelled,
        [RecurringDueReminderService.notificationIdFor(42)],
      );
    });

    test('cancelAllPending 只取消 3000..3999 段', () async {
      notifications.pending = [
        pendingNotification(1001),
        pendingNotification(1002),
        pendingNotification(2001),
        pendingNotification(3001),
        pendingNotification(3002),
        pendingNotification(4001),
      ];

      await service().cancelAllPending();

      expect(notifications.cancelled, [3001, 3002]);
    });
  });

  test('外币模板 -> 提醒金额用模板币种（与订阅列表同口径）', () async {
    await enableSwitch(true);
    final id = await seedTemplate(
      dayOfMonth: 20,
      note: 'Netflix',
      currencyCode: 'USD',
    );

    await service().rescheduleAll();

    expect(notifications.scheduled, hasLength(1));
    final entry = notifications.scheduled.single;
    expect(entry.id, RecurringDueReminderService.notificationIdFor(id));
    // formatBalance 会把币种符号前置：USD -> '$'
    expect(entry.body, contains(r'$'));
  });
}
