/// 自然周周期工具(固定周一起始,周一~周日)。
///
/// 约定与 month_range.dart 一致:
/// - 全库统一半开区间 [start, end)
/// - [date] 必须是本地时间 DateTime
library;

import 'month_range.dart';

/// [date] 所在自然周的范围:[周一 00:00, 下周一 00:00)。
DateRange weekRangeFor(DateTime date) {
  final monday = DateTime(date.year, date.month, date.day)
      .subtract(Duration(days: date.weekday - DateTime.monday));
  return (start: monday, end: monday.add(const Duration(days: 7)));
}

/// [date] 所在周的「标签周一」,返回当周周一(仅作 key / 选中态)。
DateTime weekLabelFor(DateTime date) => weekRangeFor(date).start;

/// [weekStart] 偏移 [offset] 周后的周一。
DateTime weekAdd(DateTime weekStart, int offset) =>
    weekStart.add(Duration(days: 7 * offset));

/// UI 周期范围文案：
/// - 同年内（更紧凑）："08.03～08.09"
/// - 跨年（避免歧义）："2026.12.28～2027.01.03"
/// 头部年份省略后,洞察页周期导航行(两侧圆形箭头 + 右侧胶囊)能完整容纳文案。
String weekRangeText(DateRange range) {
  final s = range.start;
  // 日历日减一(非 Duration:DST 时区减 86400s 可能落到前一天 23:00)
  final e = range.end;
  final endIncl = DateTime(e.year, e.month, e.day - 1);
  String two(int v) => v.toString().padLeft(2, '0');
  String short(DateTime d) => '${two(d.month)}.${two(d.day)}';
  final tailShort = short(endIncl);
  final headShort = short(s);
  final tailFull = '${endIncl.year}.$tailShort';
  // 跨年:保留完整年份;同年:省掉头部年份,缩短 ~30% 宽度
  return endIncl.year == s.year
      ? '$headShort～$tailShort'
      : '${s.year}.$headShort～$tailFull';
}
