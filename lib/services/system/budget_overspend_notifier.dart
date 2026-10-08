import 'dart:ui';

import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/budget_repository.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/format_utils.dart';
import '../../utils/notification_factory.dart';
import '../../utils/notification_util.dart';
import 'logger_service.dart';

/// 「预算超支提醒」开关的偏好键（默认关闭：升级后不突然打扰用户）。
const String kBudgetOverspendReminderEnabledKey =
    'budget_overspend_reminder_enabled';

/// 预算超支实时推送。
///
/// 口径（见 prd/subscription_and_overspend_alerts/requirements.md §4.3）：
/// - 每笔支出落库后（`PostProcessor` 统一出口）检测该账本的总预算与各分类预算；
/// - **只推 100% 超支**（`BudgetUsage.rate >= 1.0`），不做 80% 预警档；
/// - **同一预算同一预算周期只推一次**，跨周期（账本 `monthStartDay` 定义的周期）
///   后水位 key 变化 → 自然恢复可推；
/// - 开关关闭时只花一次偏好读即短路，不做预算聚合查询；
/// - 任何异常只记日志，绝不影响记账主流程。
///
/// 构造注入 [NotificationUtil] 以便单测塞入 fake（同
/// `RecurringDueReminderService` 的形状，见 design.md §4）。
class BudgetOverspendNotifier {
  static const _tag = 'BudgetOverspend';

  /// 通知 ID 段：`4000 + budgetId`（4000..4999）。
  /// 与 1001 每日提醒 / 1000~1999 自动记账 / 2000 信用卡 / 3000 到期提醒互不重叠。
  static const int notificationIdBase = 4000;

  /// 水位 key 前缀。
  static const String watermarkPrefix = 'budget_overspend_notified_';

  /// 只读仓储（`PiggyRepository`）：本服务不写库。
  final dynamic repository;

  final NotificationUtil? _injectedNotifications;

  BudgetOverspendNotifier({
    required this.repository,
    NotificationUtil? notificationUtil,
  }) : _injectedNotifications = notificationUtil;

  NotificationUtil get _notifications =>
      _injectedNotifications ?? NotificationFactory.getInstance();

  /// 段容量前提：`budgetId < 1000`（4000..4999 共 1000 个槽位）。单客户端的
  /// 预算数（1 条总预算 + 若干分类预算）远小于此，不做事后钳制 —— 钳制会把两条
  /// 提醒静默合并成一条，更难查。
  static int notificationIdFor(int budgetId) => notificationIdBase + budgetId;

  /// 水位 key：预算 id + 周期起始日（跨周期自动失效）。
  static String watermarkKey(int budgetId, DateTime periodStart) =>
      '$watermarkPrefix${budgetId}_${periodStart.toIso8601String()}';

  /// 记账（或任何数据变更）后的检测入口。
  Future<void> checkAfterWrite({required int ledgerId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      // 开关前置短路：关闭时不做任何预算查询
      if (!(prefs.getBool(kBudgetOverspendReminderEnabledKey) ?? false)) {
        return;
      }

      final now = DateTime.now();
      final overview =
          await repository.getBudgetOverview(ledgerId, now) as BudgetOverview;
      // periodStart 由 repo 按账本 monthStartDay 填充；缺失（异常/旧路径）时按自然月兜底，
      // 只影响水位 key 的唯一性粒度，不影响推送正确性。
      final periodStart =
          overview.periodStart ?? DateTime(now.year, now.month, 1);

      final targets = <_OverspendTarget>[];

      // 总预算：BudgetOverview 只带 usage，id 需另取（水位键要按预算 id 区分）
      final totalBudget = await repository.getTotalBudget(ledgerId);
      if (totalBudget != null) {
        final totalUsage = overview.totalBudget ?? await repository
            .getBudgetUsage(totalBudget.id, now) as BudgetUsage;
        if (totalUsage.rate >= 1.0) {
          targets.add(_OverspendTarget(
            budgetId: totalBudget.id,
            isTotal: true,
            nameKey: null,
            usage: totalUsage,
          ));
        }
      }

      for (final categoryBudget in overview.categoryBudgets) {
        if (categoryBudget.usage.rate < 1.0) continue;
        targets.add(_OverspendTarget(
          budgetId: categoryBudget.budgetId,
          isTotal: false,
          nameKey: categoryBudget.categoryName,
          usage: categoryBudget.usage,
        ));
      }

      if (targets.isEmpty) return;

      final locale = PlatformDispatcher.instance.locale;
      final l10n = lookupAppLocalizations(locale);
      final isZh = locale.languageCode == 'zh';
      final currency = await _baseCurrencyOf(ledgerId);

      for (final target in targets) {
        final key = watermarkKey(target.budgetId, periodStart);
        if (prefs.getBool(key) ?? false) {
          logger.info(_tag, '预算 id=${target.budgetId} 本周期已推送过，跳过');
          continue;
        }

        final name = target.isTotal
            ? l10n.budgetOverspendTotalBudgetName
            : (target.nameKey ?? l10n.budgetOverspendTotalBudgetName);

        await _notifications.showNotification(
          id: notificationIdFor(target.budgetId),
          title: l10n.budgetOverspendNotifyTitle,
          body: l10n.budgetOverspendNotifyBody(
            name,
            formatBalance(target.usage.used, currency, isChineseLocale: isZh),
            formatBalance(target.usage.budget, currency, isChineseLocale: isZh),
          ),
        );

        await prefs.setBool(key, true);
        await _cleanupStaleWatermarks(prefs, target.budgetId, key);
        logger.info(_tag,
            '预算 id=${target.budgetId} 超支(rate=${target.usage.rate.toStringAsFixed(2)})，已推送');
      }
    } catch (e, stack) {
      logger.warning(_tag, '预算超支检测失败: $e', stack);
    }
  }

  /// 清掉该预算下非当前周期的旧水位 key，避免偏好文件无限膨胀。
  ///
  /// 只在实际推送时清理（不是每次检测），把 O(#keys) 扫描压到最低频路径。
  Future<void> _cleanupStaleWatermarks(
    SharedPreferences prefs,
    int budgetId,
    String keepKey,
  ) async {
    final prefix = '$watermarkPrefix${budgetId}_';
    final stale = prefs
        .getKeys()
        .where((k) => k != keepKey && k.startsWith(prefix))
        .toList();
    for (final key in stale) {
      await prefs.remove(key);
    }
  }

  Future<String> _baseCurrencyOf(int ledgerId) async {
    try {
      final ledger = await repository.getLedgerById(ledgerId);
      final currency = ledger?.currency as String?;
      return (currency ?? 'CNY').trim().toUpperCase();
    } catch (_) {
      return 'CNY';
    }
  }
}

/// 内部传输对象：待推送项。
class _OverspendTarget {
  final int budgetId;
  final bool isTotal;
  final String? nameKey;
  final BudgetUsage usage;

  const _OverspendTarget({
    required this.budgetId,
    required this.isTotal,
    required this.nameKey,
    required this.usage,
  });
}
