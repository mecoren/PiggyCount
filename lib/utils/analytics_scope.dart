/// 洞察时间维度纯函数层（枚举 + 周期计算）。
///
/// 从 `analytics_page.dart` 的内嵌 if-else 收拢而来，**行为冻结**：
/// 各档位的现状口径（含不一致处）逐值保留，见
/// prd/analytics_scope_enum_refactor/design.md §四。原则：
/// - 全库统一半开区间 [start, end)
/// - `now` / `startDay` 由调用方注入，不依赖 BuildContext / Provider → 可单测
/// - 导航步进只算新锚点，状态写回（_selWeek / selectedMonthProvider）留在页面
library;

import 'month_range.dart';
import 'week_range.dart';

export 'month_range.dart' show DateRange;

/// 洞察时间档位。分支一律用穷尽 switch（不写 default）：新增档位时
/// 编译器强制指出每一处需要补的分支，杜绝静默落错分支。
enum AnalyticsScope { week, month, year, all }

/// 取数序列粒度（决定调 repo 的哪个聚合）。
enum AnalyticsSeriesKind { day, month, yearSeries }

/// 一次周期解析结果：本期半开区间 + 上期窗口（可空）。
typedef AnalyticsPeriodRange = ({
  DateTime start,
  DateTime end,
  DateTime? prevStart,
  DateTime? prevEnd,
});

extension AnalyticsScopeSeries on AnalyticsScope {
  /// week/month 走日序列、year 走月序列、all 走年序列（与重构前
  /// `totalsByDay / totalsByMonth / totalsByYearSeries` 三路路由一致）。
  AnalyticsSeriesKind get seriesKind => switch (this) {
        AnalyticsScope.week || AnalyticsScope.month => AnalyticsSeriesKind.day,
        AnalyticsScope.year => AnalyticsSeriesKind.month,
        AnalyticsScope.all => AnalyticsSeriesKind.yearSeries,
      };
}

/// 档位 + 锚点 → 本期 `(start, end)` 与上期窗口。
///
/// [anchor]：week=周标签周一（`weekLabelFor`）；month=周期标签月
/// （`DateTime(y, m, 1)`）；year=任意该年日期（只取 `.year`）；all=忽略。
///
/// 现状口径（行为冻结，勿"顺手统一"）：
/// - 「当前周期」判定：month 用**周期标签相等**（`labelForDate`，startDay=10 时
///   10-05 属 9 月周期）；week/year 用**区间包含**。
/// - 当前周期 `end` 截断到「今天+1 天」（半开右端），历史周期到周期末。
/// - 上期：week=紧邻上周 `[anchor-7d, 本周一)`；month=去年同周期标签月；
///   year=去年周期；all=无上期（null）。
AnalyticsPeriodRange resolveAnalyticsPeriod(
  AnalyticsScope scope, {
  required DateTime anchor,
  required int startDay,
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final todayEnd = today.add(const Duration(days: 1));
  return switch (scope) {
    AnalyticsScope.week => () {
        final range = weekRangeFor(anchor);
        final isCurrent =
            !now.isBefore(range.start) && now.isBefore(range.end);
        return (
          start: range.start,
          end: isCurrent ? todayEnd : range.end,
          prevStart: weekAdd(anchor, -1),
          prevEnd: range.start,
        );
      }(),
    AnalyticsScope.month => () {
        final range = periodForLabel(anchor.year, anchor.month, startDay);
        final nowLabel = labelForDate(now, startDay);
        final isCurrent =
            anchor.year == nowLabel.year && anchor.month == nowLabel.month;
        final prev = periodForLabel(anchor.year - 1, anchor.month, startDay);
        return (
          start: range.start,
          end: isCurrent ? todayEnd : range.end,
          prevStart: prev.start,
          prevEnd: prev.end,
        );
      }(),
    AnalyticsScope.year => () {
        final range = yearRangeFor(anchor.year, startDay);
        final isCurrent =
            !now.isBefore(range.start) && now.isBefore(range.end);
        final prev = yearRangeFor(anchor.year - 1, startDay);
        return (
          start: range.start,
          end: isCurrent ? todayEnd : range.end,
          prevStart: prev.start,
          prevEnd: prev.end,
        );
      }(),
    AnalyticsScope.all => (
        start: DateTime(1970, 1, 1),
        end: todayEnd,
        prevStart: null,
        prevEnd: null,
      ),
  };
}

/// 下一周期锚点；null = 不前进（all 档位或已被钳制）。
///
/// 前进钳制口径三档不一致（现状保留）：week=**周标签**比较、month=**自然年月**
/// 比较（不看周期标签）、year=**自然年**比较。
DateTime? nextAnchor(AnalyticsScope scope, DateTime anchor, DateTime now) =>
    switch (scope) {
      AnalyticsScope.week => () {
          final next = weekAdd(anchor, 1);
          return next.isAfter(weekLabelFor(now)) ? null : next;
        }(),
      AnalyticsScope.month => () {
          final next = DateTime(anchor.year, anchor.month + 1, 1);
          final ok = next.year < now.year ||
              (next.year == now.year && next.month <= now.month);
          return ok ? next : null;
        }(),
      AnalyticsScope.year => () {
          final next = DateTime(anchor.year + 1, 1, 1);
          return next.year <= now.year ? next : null;
        }(),
      AnalyticsScope.all => null,
    };

/// 上一周期锚点；null = 无操作（all 档位）。后退不钳制。
DateTime? prevAnchor(AnalyticsScope scope, DateTime anchor) => switch (scope) {
      AnalyticsScope.week => weekAdd(anchor, -1),
      AnalyticsScope.month => DateTime(anchor.year, anchor.month - 1, 1),
      AnalyticsScope.year => DateTime(anchor.year - 1, 1, 1),
      AnalyticsScope.all => null,
    };

/// 图表 6 桶窗口（本期 + 前 5 期）；year/all 走年序列，返回 null。
///
/// week=[本周前推 5 周的周一, 本周一+7d)；month=[本期标签前推 5 个周期月的起点,
/// 本期周期末)（月份借位由 DateTime 自动进位）。
DateRange? chartSeriesWindow(
  AnalyticsScope scope, {
  required DateTime anchor,
  required int startDay,
}) =>
    switch (scope) {
      AnalyticsScope.week => (
          start: weekAdd(anchor, -5),
          end: weekRangeFor(anchor).end,
        ),
      AnalyticsScope.month => (
          start: periodForLabel(anchor.year, anchor.month - 5, startDay).start,
          end: periodForLabel(anchor.year, anchor.month, startDay).end,
        ),
      AnalyticsScope.year || AnalyticsScope.all => null,
    };
