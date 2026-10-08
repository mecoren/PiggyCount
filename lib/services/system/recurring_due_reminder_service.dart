import 'dart:ui';

import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/format_utils.dart';
import '../../utils/notification_factory.dart';
import '../../utils/notification_util.dart';
import '../data/recurring_transaction_service.dart';
import 'logger_service.dart';

/// 「周期账单到期提醒」开关的偏好键。
///
/// 与 [kBudgetOverspendReminderEnabledKey] 一样，开关只存本地偏好：不新增表、
/// 不进快照、不参与同步契约（见 prd/subscription_and_overspend_alerts）。
const String kRecurringDueReminderEnabledKey = 'recurring_due_reminder_enabled';

/// 周期账单到期提醒编排。
///
/// 口径（requirements.md §4.2）：**支出型 + 启用中**的周期账单，在扣款日前
/// [daysBefore] 天的 [notifyHour]:[notifyMinute] 发一条单次本地通知；提前窗口
/// 已过则跳过本次（不补发、不提前到今刻）。
///
/// 三条路径都走本服务：模板变更（[scheduleForTemplate] / [cancelForTemplate]）、
/// 应用启动恢复（[rescheduleAll]）、前台恢复补种（[rescheduleAll]）。
///
/// 设计取舍见 design.md §4：构造注入 [NotificationUtil]，便于单测塞入 fake；
/// 所有调度/取消都自带 try-catch，异常只记日志，绝不影响记账与启动。
class RecurringDueReminderService {
  static const _tag = 'RecurringDueReminder';

  /// 扣款日前几天提醒。
  static const int daysBefore = 3;

  /// 提醒当天的时刻。
  static const int notifyHour = 10;
  static const int notifyMinute = 0;

  /// 通知 ID 段基址：`3000 + recurringId`（3000..3999）。
  /// 与 1001 每日提醒 / 1000~1999 自动记账 / 2000 信用卡 / 4000 预算超支互不重叠。
  static const int notificationIdBase = 3000;
  static const int _notificationIdEnd = 4000;

  /// 只读仓储（`PiggyRepository`）：本服务不写库。
  final dynamic repository;

  final NotificationUtil? _injectedNotifications;
  final DateTime Function() _now;

  RecurringDueReminderService({
    required this.repository,
    NotificationUtil? notificationUtil,
    DateTime Function()? now,
  })  : _injectedNotifications = notificationUtil,
        _now = now ?? DateTime.now;

  NotificationUtil get _notifications =>
      _injectedNotifications ?? NotificationFactory.getInstance();

  /// 通知 ID 是否属于本服务管辖段（3000..3999）。
  static bool ownsNotificationId(int id) =>
      id >= notificationIdBase && id < _notificationIdEnd;

  /// 段容量前提：`recurringId < 1000`（3000..3999 共 1000 个槽位）。
  /// 单客户端的周期账单模板数远小于此；真撞上也是「通知 ID 复用」而非崩溃，
  /// 故不做事后钳制（钳制会静默把两条提醒合并成一条，更难查）。
  static int notificationIdFor(int recurringId) =>
      notificationIdBase + recurringId;

  /// 扣款日 → 提醒时刻（纯函数）。
  ///
  /// 返回 null = 「本次不提醒」：提醒时刻已过（提前窗口错过，不补发）。
  static DateTime? reminderTimeFor(DateTime dueDate, {required DateTime now}) {
    final reminder = DateTime(
      dueDate.year,
      dueDate.month,
      dueDate.day - daysBefore,
      notifyHour,
      notifyMinute,
    );
    if (!reminder.isAfter(now)) return null;
    return reminder;
  }

  /// 取消单条模板的提醒（模板被删除时调用）。
  Future<void> cancelForTemplate(int recurringId) async {
    try {
      await _notifications.cancelNotification(notificationIdFor(recurringId));
    } catch (e, stack) {
      logger.warning(_tag, '取消周期账单提醒失败(id=$recurringId): $e', stack);
    }
  }

  /// 全量重调度：启动恢复 / 前台补种 / 开关打开 / 模板变更后调用。
  ///
  /// 语义是**全库收敛**（不只是当前账本）：先按活跃模板排程，再清掉管辖段内
  /// 已不再对应活跃模板的陈旧调度（覆盖「模板被删除 / 被停用 / 改为收入」）。
  /// 因此不做「只处理某账本」的分支 —— 那样孤儿清理会把其它账本的调度全误删。
  Future<void> rescheduleAll() async {
    try {
      if (!await isEnabled()) {
        logger.info(_tag, '到期提醒开关关闭，跳过重调度');
        return;
      }

      final allTemplates =
          await repository.getAllRecurringTransactions() as List;
      final ledgers = await repository.getAllLedgers() as List;
      final baseCurrencyById = <int, String>{
        for (final ledger in ledgers)
          ledger.id as int: ((ledger.currency as String?) ?? 'CNY'),
      };

      final activeIds = <int>{};
      for (final raw in allTemplates) {
        final recurring = raw as RecurringTransaction;
        if (recurring.type != 'expense' || !recurring.enabled) continue;
        activeIds.add(recurring.id);
        await _schedule(
          recurring,
          baseCurrency: baseCurrencyById[recurring.ledgerId],
        );
      }

      // 清掉管辖段里的孤儿调度（模板已删除 / 已停用 / 已不是支出型）
      final pending = await _notifications.getPendingNotifications();
      for (final entry in pending) {
        if (!ownsNotificationId(entry.id)) continue;
        final recurringId = entry.id - notificationIdBase;
        if (activeIds.contains(recurringId)) continue;
        await _notifications.cancelNotification(entry.id);
      }

      logger.info(_tag, '到期提醒重调度完成：活跃模板 ${activeIds.length} 个');
    } catch (e, stack) {
      logger.warning(_tag, '重调度周期账单提醒失败: $e', stack);
    }
  }

  /// 取消全部到期提醒（开关关闭时调用）。只动 3000..3999 段。
  Future<void> cancelAllPending() async {
    try {
      final pending = await _notifications.getPendingNotifications();
      var cancelled = 0;
      for (final entry in pending) {
        if (!ownsNotificationId(entry.id)) continue;
        await _notifications.cancelNotification(entry.id);
        cancelled++;
      }
      logger.info(_tag, '已取消 $cancelled 条周期账单提醒');
    } catch (e, stack) {
      logger.warning(_tag, '取消全部周期账单提醒失败: $e', stack);
    }
  }

  /// 开关当前是否开启（默认关闭：升级后不突然打扰用户）。
  Future<bool> isEnabled() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return prefs.getBool(kRecurringDueReminderEnabledKey) ?? false;
    } catch (_) {
      return false;
    }
  }

  // ============ 内部实现 ============

  Future<void> _schedule(
    RecurringTransaction recurring, {
    String? baseCurrency,
  }) async {
    if (recurring.type != 'expense' || !recurring.enabled) {
      await cancelForTemplate(recurring.id);
      return;
    }

    final now = _now();
    final recurringService = RecurringTransactionService(repository);
    final dueDate = recurringService.nextDueDateAfter(recurring, now: now);
    if (dueDate == null) {
      // 已过 endDate / 算不出下一次 → 不再提醒
      await cancelForTemplate(recurring.id);
      return;
    }

    final reminderAt = reminderTimeFor(dueDate, now: now);
    if (reminderAt == null) {
      // 提前窗口已过:本次不提醒(不补发),同时清掉可能存在的陈旧调度
      await cancelForTemplate(recurring.id);
      logger.info(_tag,
          'id=${recurring.id} 扣款日 $dueDate 的提前窗口已过,本次不提醒');
      return;
    }

    final locale = PlatformDispatcher.instance.locale;
    final l10n = lookupAppLocalizations(locale);
    final name = await _displayName(recurring, l10n);
    // 币种优先取**模板币种**（金额就记在它名下，与订阅列表的 ISO 码同口径）；
    // 模板未设币种（null = 账本本位币）才回落到账本币种。
    final currency = ((recurring.currencyCode ?? baseCurrency) ?? 'CNY')
        .trim()
        .toUpperCase();
    final amountText = formatBalance(
      recurring.amount,
      currency,
      isChineseLocale: locale.languageCode == 'zh',
    );

    await _notifications.scheduleOnceReminder(
      id: notificationIdFor(recurring.id),
      title: l10n.recurringDueNotifyTitle(name),
      body: l10n.recurringDueNotifyBody(
        amountText,
        DateFormat.Md().format(dueDate),
      ),
      scheduledDate: reminderAt,
    );
    logger.info(_tag,
        'id=${recurring.id} 已调度提醒: 扣款日=$dueDate 提醒时间=$reminderAt');
  }

  /// 展示名：备注 → 分类名 → 通用兜底。
  Future<String> _displayName(
    RecurringTransaction recurring,
    AppLocalizations l10n,
  ) async {
    final note = recurring.note?.trim();
    if (note != null && note.isNotEmpty) return note;

    final categoryId = recurring.categoryId;
    if (categoryId != null) {
      try {
        final category = await repository.getCategoryById(categoryId) as Category?;
        final name = category?.name.trim();
        if (name != null && name.isNotEmpty) return name;
      } catch (_) {
        // 分类查不到就走兜底文案
      }
    }
    return l10n.subscriptionUnknownName;
  }
}
