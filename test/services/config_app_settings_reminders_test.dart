// 两个新提醒开关的配置迁移契约（见
// prd/subscription_and_overspend_alerts/requirements.md §4.5）：
// 开关必须随配置导出/导入往返，否则换机后设置丢失（用户以为开了提醒却收不到）。

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/services/export/config_export_service.dart';

void main() {
  group('AppSettingsConfig 提醒开关往返', () {
    test('toMap 写出两个新开关', () {
      final map = const AppSettingsConfig(
        budgetOverspendReminderEnabled: true,
        recurringDueReminderEnabled: false,
      ).toMap();
      expect(map['budget_overspend_reminder_enabled'], isTrue);
      expect(map['recurring_due_reminder_enabled'], isFalse);
    });

    test('fromMap 读回两个新开关', () {
      final cfg = AppSettingsConfig.fromMap({
        'budget_overspend_reminder_enabled': true,
        'recurring_due_reminder_enabled': true,
      });
      expect(cfg.budgetOverspendReminderEnabled, isTrue);
      expect(cfg.recurringDueReminderEnabled, isTrue);
    });

    test('未设置时 toMap 不含这两个键（老版本导出包不受影响）', () {
      final map = const AppSettingsConfig().toMap();
      expect(map.containsKey('budget_overspend_reminder_enabled'), isFalse);
      expect(map.containsKey('recurring_due_reminder_enabled'), isFalse);
    });

    test('缺键的老导出包 → 解析为 null（按「不修改」处理，不覆写成本地关闭）', () {
      final cfg = AppSettingsConfig.fromMap({'reminder_enabled': true});
      expect(cfg.budgetOverspendReminderEnabled, isNull);
      expect(cfg.recurringDueReminderEnabled, isNull);
    });
  });
}
