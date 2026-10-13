import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/analytics_scope.dart';

/// 洞察时间维度纯函数层的特征测试：钉住重构前 `analytics_page.dart`
/// 内嵌 if-else 的**现状口径**（含口径不一致处，见
/// prd/analytics_scope_enum_refactor/design.md §四行为冻结清单）。
void main() {
  // 固定「今天」：2026-10-13（周二），其所在周标签周一 = 2026-10-12。
  final now = DateTime(2026, 10, 13);
  final today = DateTime(2026, 10, 14); // end 截断 = today+1d

  group('resolveAnalyticsPeriod', () {
    test('week 当前周：截断到今天+1天，上期=紧邻上周', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.week,
          anchor: DateTime(2026, 10, 12), startDay: 1, now: now);
      expect(r.start, DateTime(2026, 10, 12));
      expect(r.end, today);
      expect(r.prevStart, DateTime(2026, 10, 5));
      expect(r.prevEnd, DateTime(2026, 10, 12));
    });

    test('week 历史周：到周末而非今天', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.week,
          anchor: DateTime(2026, 10, 5), startDay: 1, now: now);
      expect(r.start, DateTime(2026, 10, 5));
      expect(r.end, DateTime(2026, 10, 12));
      expect(r.prevStart, DateTime(2026, 9, 28));
      expect(r.prevEnd, DateTime(2026, 10, 5));
    });

    test('month 当前周期：截断到今天+1天，上期=去年同周期标签月', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.month,
          anchor: DateTime(2026, 10, 1), startDay: 1, now: now);
      expect(r.start, DateTime(2026, 10, 1));
      expect(r.end, today);
      expect(r.prevStart, DateTime(2025, 10, 1));
      expect(r.prevEnd, DateTime(2025, 11, 1));
    });

    test('month 历史周期：到周期末', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.month,
          anchor: DateTime(2026, 9, 1), startDay: 1, now: now);
      expect(r.start, DateTime(2026, 9, 1));
      expect(r.end, DateTime(2026, 10, 1));
    });

    test('month startDay=10 当前周期：范围按起始日', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.month,
          anchor: DateTime(2026, 10, 1), startDay: 10, now: now);
      expect(r.start, DateTime(2026, 10, 10));
      expect(r.end, today);
      expect(r.prevStart, DateTime(2025, 10, 10));
      expect(r.prevEnd, DateTime(2025, 11, 10));
    });

    test('month 当前判定用周期标签而非区间包含（口径不一致原样钉住）', () {
      // now=10-05 且 startDay=10：今天属 9 月周期，10 月周期是「未来周期」，
      // 现状按标签相等判定 → 不截断、到 11-10。
      final r = resolveAnalyticsPeriod(AnalyticsScope.month,
          anchor: DateTime(2026, 10, 1),
          startDay: 10,
          now: DateTime(2026, 10, 5));
      expect(r.start, DateTime(2026, 10, 10));
      expect(r.end, DateTime(2026, 11, 10));
    });

    test('year 当前年：截断到今天+1天，上期=去年周期', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.year,
          anchor: DateTime(2026, 1, 1), startDay: 1, now: now);
      expect(r.start, DateTime(2026, 1, 1));
      expect(r.end, today);
      expect(r.prevStart, DateTime(2025, 1, 1));
      expect(r.prevEnd, DateTime(2026, 1, 1));
    });

    test('year startDay=10：年度周期边界按起始日', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.year,
          anchor: DateTime(2026, 1, 1), startDay: 10, now: now);
      expect(r.start, DateTime(2026, 1, 10));
      expect(r.end, today);
    });

    test('year 历史年：到年度周期末', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.year,
          anchor: DateTime(2025, 1, 1), startDay: 1, now: now);
      expect(r.start, DateTime(2025, 1, 1));
      expect(r.end, DateTime(2026, 1, 1));
    });

    test('all：[1970-01-01, 今天+1天)，无上期', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.all,
          anchor: DateTime(2026, 10, 1), startDay: 1, now: now);
      expect(r.start, DateTime(1970, 1, 1));
      expect(r.end, today);
      expect(r.prevStart, isNull);
      expect(r.prevEnd, isNull);
    });

    test('闰年 2 月周期与非闰年上期逐值钉住', () {
      final r = resolveAnalyticsPeriod(AnalyticsScope.month,
          anchor: DateTime(2024, 2, 1), startDay: 1, now: now);
      expect(r.start, DateTime(2024, 2, 1));
      expect(r.end, DateTime(2024, 3, 1)); // 含 2/29
      expect(r.prevStart, DateTime(2023, 2, 1));
      expect(r.prevEnd, DateTime(2023, 3, 1));
    });
  });

  group('nextAnchor（前进钳制口径不一致原样钉住）', () {
    test('week：周标签比较，可到当前周', () {
      expect(nextAnchor(AnalyticsScope.week, DateTime(2026, 10, 5), now),
          DateTime(2026, 10, 12));
      expect(
          nextAnchor(AnalyticsScope.week, DateTime(2026, 10, 12), now), isNull);
    });

    test('month：自然年月比较（非周期标签）', () {
      expect(nextAnchor(AnalyticsScope.month, DateTime(2026, 9, 1), now),
          DateTime(2026, 10, 1));
      expect(nextAnchor(AnalyticsScope.month, DateTime(2026, 10, 1), now),
          isNull);
      // now=10-05(startDay=10 时属 9 月周期)仍允许前进到 10 月标签——
      // 钳制不看周期标签，与「当前周期」判定口径不同。
      expect(
          nextAnchor(AnalyticsScope.month, DateTime(2026, 9, 1),
              DateTime(2026, 10, 5)),
          DateTime(2026, 10, 1));
    });

    test('year：自然年比较', () {
      expect(nextAnchor(AnalyticsScope.year, DateTime(2025, 1, 1), now),
          DateTime(2026, 1, 1));
      expect(nextAnchor(AnalyticsScope.year, DateTime(2026, 1, 1), now), isNull);
    });

    test('all：no-op', () {
      expect(nextAnchor(AnalyticsScope.all, DateTime(2026, 1, 1), now), isNull);
    });
  });

  group('prevAnchor', () {
    test('week/month/year 后退一步，all no-op', () {
      expect(prevAnchor(AnalyticsScope.week, DateTime(2026, 10, 12)),
          DateTime(2026, 10, 5));
      expect(prevAnchor(AnalyticsScope.month, DateTime(2026, 10, 1)),
          DateTime(2026, 9, 1));
      expect(prevAnchor(AnalyticsScope.year, DateTime(2026, 1, 1)),
          DateTime(2025, 1, 1));
      expect(prevAnchor(AnalyticsScope.all, DateTime(2026, 1, 1)), isNull);
    });

    test('month 1 月借位到上年 12 月', () {
      expect(prevAnchor(AnalyticsScope.month, DateTime(2026, 1, 1)),
          DateTime(2025, 12, 1));
    });
  });

  group('seriesKind', () {
    test('week/month=day、year=month、all=yearSeries', () {
      expect(AnalyticsScope.week.seriesKind, AnalyticsSeriesKind.day);
      expect(AnalyticsScope.month.seriesKind, AnalyticsSeriesKind.day);
      expect(AnalyticsScope.year.seriesKind, AnalyticsSeriesKind.month);
      expect(AnalyticsScope.all.seriesKind, AnalyticsSeriesKind.yearSeries);
    });
  });

  group('chartSeriesWindow（图表 6 桶窗口）', () {
    test('week：本周+前 5 周', () {
      final w = chartSeriesWindow(AnalyticsScope.week,
          anchor: DateTime(2026, 10, 12), startDay: 1)!;
      expect(w.start, DateTime(2026, 9, 7));
      expect(w.end, DateTime(2026, 10, 19));
    });

    test('month：本月+前 5 周期月', () {
      final w = chartSeriesWindow(AnalyticsScope.month,
          anchor: DateTime(2026, 10, 1), startDay: 1)!;
      expect(w.start, DateTime(2026, 5, 1));
      expect(w.end, DateTime(2026, 11, 1));
    });

    test('month 借位：3 月-5 → 上年 10 月周期', () {
      final w = chartSeriesWindow(AnalyticsScope.month,
          anchor: DateTime(2026, 3, 1), startDay: 10)!;
      expect(w.start, DateTime(2025, 10, 10));
      expect(w.end, DateTime(2026, 4, 10));
    });

    test('year/all：年序列无窗口', () {
      expect(
          chartSeriesWindow(AnalyticsScope.year,
              anchor: DateTime(2026, 1, 1), startDay: 1),
          isNull);
      expect(
          chartSeriesWindow(AnalyticsScope.all,
              anchor: DateTime(2026, 1, 1), startDay: 1),
          isNull);
    });
  });
}
