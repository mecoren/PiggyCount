import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'database_providers.dart' show repositoryProvider;
import '../services/system/budget_overspend_notifier.dart';
import '../services/system/recurring_due_reminder_service.dart';
import '../utils/notification_factory.dart';

/// 记账提醒设置
class ReminderSettings {
  final bool isEnabled;
  final int hour;  // 0-23
  final int minute; // 0-59

  /// 预算超支提醒（只推 100% 超支，记账后实时检测）。
  final bool budgetOverspendEnabled;

  /// 周期账单到期提醒（扣款前 3 天）。
  final bool recurringDueEnabled;

  const ReminderSettings({
    required this.isEnabled,
    required this.hour,
    required this.minute,
    this.budgetOverspendEnabled = false,
    this.recurringDueEnabled = false,
  });

  factory ReminderSettings.defaultSettings() {
    return const ReminderSettings(
      isEnabled: false,
      hour: 21, // 默认晚上9点
      minute: 0,
    );
  }

  ReminderSettings copyWith({
    bool? isEnabled,
    int? hour,
    int? minute,
    bool? budgetOverspendEnabled,
    bool? recurringDueEnabled,
  }) {
    return ReminderSettings(
      isEnabled: isEnabled ?? this.isEnabled,
      hour: hour ?? this.hour,
      minute: minute ?? this.minute,
      budgetOverspendEnabled:
          budgetOverspendEnabled ?? this.budgetOverspendEnabled,
      recurringDueEnabled: recurringDueEnabled ?? this.recurringDueEnabled,
    );
  }

  String get timeString {
    final h = hour.toString().padLeft(2, '0');
    final m = minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ReminderSettings &&
          runtimeType == other.runtimeType &&
          isEnabled == other.isEnabled &&
          hour == other.hour &&
          minute == other.minute &&
          budgetOverspendEnabled == other.budgetOverspendEnabled &&
          recurringDueEnabled == other.recurringDueEnabled;

  @override
  int get hashCode =>
      isEnabled.hashCode ^
      hour.hashCode ^
      minute.hashCode ^
      budgetOverspendEnabled.hashCode ^
      recurringDueEnabled.hashCode;
}

/// 记账提醒设置的StateNotifier
class ReminderSettingsNotifier extends StateNotifier<ReminderSettings> {
  /// 只读仓储：周期账单到期提醒开关变化时用它重调度/取消调度。
  final dynamic _repository;

  ReminderSettingsNotifier({dynamic repository})
      : _repository = repository,
        super(ReminderSettings.defaultSettings()) {
    _loadSettings();
  }

  static const String _keyEnabled = 'reminder_enabled';
  static const String _keyHour = 'reminder_hour';
  static const String _keyMinute = 'reminder_minute';

  /// 加载设置
  Future<void> _loadSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final isEnabled = prefs.getBool(_keyEnabled) ?? false;
      final hour = prefs.getInt(_keyHour) ?? 21;
      final minute = prefs.getInt(_keyMinute) ?? 0;

      state = ReminderSettings(
        isEnabled: isEnabled,
        hour: hour,
        minute: minute,
        budgetOverspendEnabled:
            prefs.getBool(kBudgetOverspendReminderEnabledKey) ?? false,
        recurringDueEnabled:
            prefs.getBool(kRecurringDueReminderEnabledKey) ?? false,
      );
    } catch (e) {
      // 保持默认设置
    }
  }

  /// 保存设置
  Future<void> _saveSettings() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_keyEnabled, state.isEnabled);
      await prefs.setInt(_keyHour, state.hour);
      await prefs.setInt(_keyMinute, state.minute);
      await prefs.setBool(
          kBudgetOverspendReminderEnabledKey, state.budgetOverspendEnabled);
      await prefs.setBool(
          kRecurringDueReminderEnabledKey, state.recurringDueEnabled);
    } catch (e) {
      // 忽略保存错误
    }
  }

  /// 周期账单到期提醒的调度收敛（开关开启 → 全量重调度；关闭 → 取消全段）。
  ///
  /// 服务内部自带 try-catch 与开关短路：仓储未注入时直接跳过（测试场景）。
  Future<void> _syncRecurringDueReminders() async {
    if (_repository == null) return;
    final service = RecurringDueReminderService(repository: _repository);
    if (state.recurringDueEnabled) {
      await service.rescheduleAll();
    } else {
      await service.cancelAllPending();
    }
  }

  /// 更新「预算超支提醒」开关（被动检测，无需调度，纯持久化）。
  Future<void> updateBudgetOverspendEnabled(bool enabled) async {
    state = state.copyWith(budgetOverspendEnabled: enabled);
    await _saveSettings();
  }

  /// 更新「周期账单到期提醒」开关：开启即全量重调度，关闭即取消全部待发。
  Future<void> updateRecurringDueEnabled(bool enabled) async {
    state = state.copyWith(recurringDueEnabled: enabled);
    await _saveSettings();
    await _syncRecurringDueReminders();
  }

  /// 更新启用状态
  Future<void> updateEnabled(bool enabled) async {
    state = state.copyWith(isEnabled: enabled);
    await _saveSettings();

    final notificationUtil = NotificationFactory.getInstance();
    if (enabled) {
      await notificationUtil.scheduleDailyReminder(
        id: 1001,
        title: '记账提醒',
        body: '别忘了记录今天的收支哦 💰',
        hour: state.hour,
        minute: state.minute,
      );
    } else {
      await notificationUtil.cancelNotification(1001);
    }
  }

  /// 更新提醒时间
  Future<void> updateTime(int hour, int minute) async {
    state = state.copyWith(hour: hour, minute: minute);
    await _saveSettings();

    // 如果提醒已启用，重新设置通知
    if (state.isEnabled) {
      final notificationUtil = NotificationFactory.getInstance();
      await notificationUtil.scheduleDailyReminder(
        id: 1001,
        title: '记账提醒',
        body: '别忘了记录今天的收支哦 💰',
        hour: hour,
        minute: minute,
      );
    }
  }

  /// 更新完整设置
  Future<void> updateSettings(ReminderSettings settings) async {
    state = settings;
    await _saveSettings();

    final notificationUtil = NotificationFactory.getInstance();
    if (settings.isEnabled) {
      await notificationUtil.scheduleDailyReminder(
        id: 1001,
        title: '记账提醒',
        body: '别忘了记录今天的收支哦 💰',
        hour: settings.hour,
        minute: settings.minute,
      );
    } else {
      await notificationUtil.cancelNotification(1001);
    }
    // 配置整体替换（导入/恢复）后周期账单到期提醒也要收敛
    await _syncRecurringDueReminders();
  }
}

/// 记账提醒设置Provider
final reminderSettingsProvider =
    StateNotifierProvider<ReminderSettingsNotifier, ReminderSettings>((ref) {
  return ReminderSettingsNotifier(repository: ref.watch(repositoryProvider));
});