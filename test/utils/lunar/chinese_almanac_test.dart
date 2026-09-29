import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/lunar/chinese_almanac.dart';
import 'package:piggycount/utils/lunar/lunar_calendar.dart';

/// 历法副标签移植守门测试。
///
/// 用**已知事实**锚定压缩表，防止 201 项 hex 表 / 196 项节气表在移植时抄错：
/// 2026 春节 = 02-17（正月初一）、2026-10-01 = 国庆节、清明恒落 4/4–4/6、
/// 秋分恒落 9/22–9/24、2026 = 丙午马年。
void main() {
  group('LunarCalendar 换算', () {
    test('2026-02-17 是农历正月初一（春节）', () {
      final lunar = LunarCalendar.solarToLunar(DateTime(2026, 2, 17));
      expect(lunar, isNotNull);
      expect(lunar!.month, 1);
      expect(lunar.day, 1);
      expect(lunar.isLeapMonth, isFalse);
      expect(LunarCalendar.fullLabel(lunar), '正月初一');
    });

    test('农历 → 公历：2026 正月初一 = 2026-02-17', () {
      expect(
        LunarCalendar.lunarToSolar(2026, 1, 1),
        DateTime(2026, 2, 17),
      );
    });

    test('越界（早于基准日 / 超出上界）返回 null', () {
      expect(LunarCalendar.solarToLunar(DateTime(1899, 12, 31)), isNull);
      expect(LunarCalendar.lunarToSolar(2026, 13, 1), isNull);
      // 2026 无闰月时，标记为闰月即非法
      expect(LunarCalendar.lunarToSolar(2026, 6, 1, isLeapMonth: true), isNull);
    });

    test('月 / 日中文标签', () {
      expect(LunarCalendar.monthLabel(1), '正月');
      expect(LunarCalendar.monthLabel(12), '腊月');
      expect(LunarCalendar.monthLabel(6, leap: true), '闰六月');
      expect(LunarCalendar.dayLabel(1), '初一');
      expect(LunarCalendar.dayLabel(30), '三十');
    });
  });

  group('ChineseAlmanac 副标签优先级', () {
    test('公历节日优先（2026-10-01 → 国庆节）', () {
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 10, 1)), '国庆节');
    });

    test('农历节日优先于节气/农历日（2026-02-17 → 春节）', () {
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 2, 17)), '春节');
    });

    test('除夕（腊月最后一天）识别为 2026-02-16', () {
      expect(ChineseAlmanac.daySubLabel(DateTime(2026, 2, 16)), '除夕');
    });

    test('清明恒落 4/4–4/6 之间的某一天', () {
      final hits = [
        for (var d = 4; d <= 6; d++)
          ChineseAlmanac.solarTermLabel(DateTime(2026, 4, d)),
      ].where((e) => e == '清明');
      expect(hits.length, 1);
    });

    test('秋分恒落 9/22–9/24 之间的某一天', () {
      final hits = [
        for (var d = 22; d <= 24; d++)
          ChineseAlmanac.solarTermLabel(DateTime(2026, 9, d)),
      ].where((e) => e == '秋分');
      expect(hits.length, 1);
    });

    test('初一显示农历月名（二月十五回落农历日标签）', () {
      final firstDay = LunarCalendar.lunarToSolar(2026, 6, 1)!;
      expect(ChineseAlmanac.daySubLabel(firstDay), '六月');

      final midMonth = LunarCalendar.lunarToSolar(2026, 2, 15)!;
      expect(ChineseAlmanac.daySubLabel(midMonth), '十五');
    });

    test('干支生肖年标签：2026 → 丙午马年', () {
      expect(ChineseAlmanac.lunarYearLabel(2026), '丙午马年');
      expect(ChineseAlmanac.lunarYearLabel(2025), '乙巳蛇年');
    });
  });
}