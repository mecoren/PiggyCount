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
///
/// quarter/custom 为自定义时间档位扩展（prd/custom_time_scope_extension/）：
/// quarter=账期口径季度（同 year 吃 startDay）；custom=显式 [start, end) 区间，
/// 锚点走 [resolveAnalyticsPeriod] 的 `range` 参数而非 [anchor]。
enum AnalyticsScope { week, month, quarter, year, custom, all }

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
  /// week/month/quarter/custom 走日序列、year 走月序列、all 走年序列
  /// （与重构前 `totalsByDay / totalsByMonth / totalsByYearSeries` 三路路由一致；
  /// quarter/custom 走日序列后在内存按季/按月滚桶，零数据层改动）。
  AnalyticsSeriesKind get seriesKind => switch (this) {
        AnalyticsScope.week ||
        AnalyticsScope.month ||
        AnalyticsScope.quarter ||
        AnalyticsScope.custom =>
          AnalyticsSeriesKind.day,
        AnalyticsScope.year => AnalyticsSeriesKind.month,
        AnalyticsScope.all => AnalyticsSeriesKind.yearSeries,
      };
}

/// 档位 + 锚点 → 本期 `(start, end)` 与上期窗口。
///
/// [anchor]：week=周标签周一（`weekLabelFor`）；month=周期标签月
/// （`DateTime(y, m, 1)`）；quarter=季度首月标签月（`DateTime(y, 3k+1, 1)`，
/// 由标签月直接解码、**不得**过 `labelForDate`——标签当日期喂 containing 逻辑
/// 会整体偏移一个周期，见 month_range.dart D111）；year=任意该年日期（只取 `.year`）；
/// all=忽略；custom=忽略（走 [range]）。
/// [range]：custom 档位的显式区间 `[start, end)`，其余档位忽略。
///
/// 现状口径（行为冻结，勿"顺手统一"）：
/// - 「当前周期」判定：month 用**周期标签相等**（`labelForDate`，startDay=10 时
///   10-05 属 9 月周期）；week/year 用**区间包含**。
/// - 当前周期 `end` 截断到「今天+1 天」（半开右端），历史周期到周期末。
/// - 上期：week=紧邻上周 `[anchor-7d, 本周一)`；month=去年同周期标签月；
///   year=去年周期；all=无上期（null）。
///
/// quarter/custom 新口径（prd/custom_time_scope_extension/design.md D6）：
/// - quarter=区间包含判定 + 截断（同 week/year）；上期=**去年同季度**（同比，Q2）。
/// - custom=**不截断**（用户显式选择，Q6）；上期=**等长环比**前置区间（Q4）。
AnalyticsPeriodRange resolveAnalyticsPeriod(
  AnalyticsScope scope, {
  required DateTime anchor,
  DateRange? range,
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
    AnalyticsScope.quarter => () {
        final q = quarterOf(anchor);
        final cur = quarterRangeFor(anchor.year, q, startDay);
        final isCurrent = !now.isBefore(cur.start) && now.isBefore(cur.end);
        final prev = quarterRangeFor(anchor.year - 1, q, startDay);
        return (
          start: cur.start,
          end: isCurrent ? todayEnd : cur.end,
          prevStart: prev.start,
          prevEnd: prev.end,
        );
      }(),
    AnalyticsScope.custom => () {
        assert(range != null, 'custom 档位必须携带显式区间 range');
        final r = range!;
        // 等长环比（同 RangeReportPage.momWindow 语义）：长度用 Duration 保持精确
        final len = r.end.difference(r.start);
        return (
          start: r.start,
          end: r.end,
          prevStart: r.start.subtract(len),
          prevEnd: r.start,
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

/// 下一周期锚点；null = 不前进（all/custom 档位或已被钳制）。
///
/// 前进钳制口径三档不一致（现状保留）：week=**周标签**比较、month=**自然年月**
/// 比较（不看周期标签）、year=**自然年**比较。
/// quarter（新档位）=**季度标签**比较、吃 [startDay]（与自身「当前季」判定同口径）；
/// custom 不走本函数（平移见 [shiftCustomRange]），恒 null。
DateTime? nextAnchor(AnalyticsScope scope, DateTime anchor, DateTime now,
        {int startDay = 1}) =>
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
      AnalyticsScope.quarter => () {
          final next = DateTime(anchor.year, anchor.month + 3, 1);
          final nq = (year: next.year, quarter: quarterOf(next));
          final nowQ = quarterLabelFor(now, startDay);
          final ok = nq.year < nowQ.year ||
              (nq.year == nowQ.year && nq.quarter <= nowQ.quarter);
          return ok ? next : null;
        }(),
      AnalyticsScope.year => () {
          final next = DateTime(anchor.year + 1, 1, 1);
          return next.year <= now.year ? next : null;
        }(),
      AnalyticsScope.custom || AnalyticsScope.all => null,
    };

/// 上一周期锚点；null = 无操作（all/custom 档位）。后退不钳制。
DateTime? prevAnchor(AnalyticsScope scope, DateTime anchor) => switch (scope) {
      AnalyticsScope.week => weekAdd(anchor, -1),
      AnalyticsScope.month => DateTime(anchor.year, anchor.month - 1, 1),
      AnalyticsScope.quarter => DateTime(anchor.year, anchor.month - 3, 1),
      AnalyticsScope.year => DateTime(anchor.year - 1, 1, 1),
      AnalyticsScope.custom || AnalyticsScope.all => null,
    };

/// 图表 6 桶窗口（本期 + 前 5 期）；year/all 走年序列，返回 null。
///
/// week=[本周前推 5 周的周一, 本周一+7d)；month=[本期标签前推 5 个周期月的起点,
/// 本期周期末)（月份借位由 DateTime 自动进位）；quarter=[本季前推 5 季的起点,
/// 本期季度末)；custom=区间本身（图表桶数不固定，由页面按天/月自适应）。
DateRange? chartSeriesWindow(
  AnalyticsScope scope, {
  required DateTime anchor,
  DateRange? range,
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
      AnalyticsScope.quarter => () {
          // 前推 5 季 = 首月标签月 - 15 个月（借位由 DateTime 自动进位）
          final first = DateTime(anchor.year, anchor.month - 15, 1);
          return (
            start: quarterRangeFor(first.year, quarterOf(first), startDay).start,
            end: quarterRangeFor(anchor.year, quarterOf(anchor), startDay).end,
          );
        }(),
      AnalyticsScope.custom => () {
          assert(range != null, 'custom 档位必须携带显式区间 range');
          return range!;
        }(),
      AnalyticsScope.year || AnalyticsScope.all => null,
    };

/// 标签月（`DateTime(y, m, 1)`）所在季度 1-4。仅由**标签月**调用
/// （任意日期先过 [quarterLabelFor]，不得直接喂本函数——D11 语义隔离）。
int quarterOf(DateTime labelMonth) => (labelMonth.month - 1) ~/ 3 + 1;

/// 任意日期所属季度标签 `(year, quarter)`（账期口径：date.day >= startDay 归当季，
/// 否则归上一季，与 [labelForDate] 同规则）。
({int year, int quarter}) quarterLabelFor(DateTime date, int startDay) {
  final label = labelForDate(date, startDay);
  return (year: label.year, quarter: quarterOf(label));
}

/// 季度标签 `(year, 1-4)` → 周期范围 `[起始月-startDay, 起始月+3-startDay)`。
/// startDay=1 时退化为自然季度；startDay≠1 时为账期口径（同 year 的
/// [yearRangeFor] 哲学）。月份借位由 DateTime 自动进位（Q4 → 次年 1 月）。
DateRange quarterRangeFor(int year, int quarter, int startDay) {
  final firstMonth = (quarter - 1) * 3 + 1; // Q1→1 … Q4→10
  return (
    start: periodForLabel(year, firstMonth, startDay).start,
    end: periodForLabel(year, firstMonth + 3, startDay).start,
  );
}

/// custom 档位左右滑：等长平移整个区间（direction>0 前移、<0 后移）。
/// 长度用 Duration 保持精确（同 RangeReportPage 的平移交互语义）。
DateRange shiftCustomRange(DateRange range, int direction) {
  final len = range.end.difference(range.start);
  return (
    start: range.start.add(len * direction),
    end: range.end.add(len * direction),
  );
}

/// 「天」序列聚合为 6 个季度桶（本季 + 前 5 季），桶键 = 季度首月标签月
/// （复用 `({DateTime month, double total})` 形状，图表提取代码与月桶共用）。
/// 空桶补 0（与 analytics_page 的 _aggregateToMonths 同口径）。
List<({DateTime month, double total})> aggregateToQuarters(
  List<({DateTime day, double total})> days, {
  required DateTime firstQuarterLabel,
  required int startDay,
}) {
  final map = <({int year, int quarter}), double>{};
  for (final e in days) {
    final label = quarterLabelFor(e.day, startDay);
    map.update(label, (v) => v + e.total, ifAbsent: () => e.total);
  }
  final out = <({DateTime month, double total})>[];
  for (int i = 0; i < 6; i++) {
    final m = DateTime(firstQuarterLabel.year, firstQuarterLabel.month + i * 3, 1);
    final q = (year: m.year, quarter: quarterOf(m));
    out.add((month: m, total: map[q] ?? 0));
  }
  return out;
}
