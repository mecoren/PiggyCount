import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/week_range.dart';

void main() {
  group('weekRangeFor', () {
    test('周中日期归到当周周一', () {
      // 2026-08-09 是周日
      final r = weekRangeFor(DateTime(2026, 8, 9));
      expect(r.start, DateTime(2026, 8, 3));
      expect(r.end, DateTime(2026, 8, 10));
    });

    test('周一当天不变', () {
      final r = weekRangeFor(DateTime(2026, 8, 3));
      expect(r.start, DateTime(2026, 8, 3));
      expect(r.end, DateTime(2026, 8, 10));
    });

    test('跨月:8月31日是周一', () {
      final r = weekRangeFor(DateTime(2026, 9, 2));
      expect(r.start, DateTime(2026, 8, 31));
      expect(r.end, DateTime(2026, 9, 7));
    });

    test('跨年:2026-12-28 是周一', () {
      final r = weekRangeFor(DateTime(2027, 1, 1));
      expect(r.start, DateTime(2026, 12, 28));
      expect(r.end, DateTime(2027, 1, 4));
    });

    test('带时分秒的日期归零到周一 00:00', () {
      final r = weekRangeFor(DateTime(2026, 8, 5, 23, 59, 59));
      expect(r.start, DateTime(2026, 8, 3));
    });
  });

  test('weekLabelFor 返回当周周一', () {
    expect(weekLabelFor(DateTime(2026, 8, 9)), DateTime(2026, 8, 3));
  });

  test('weekAdd 前后偏移', () {
    final monday = DateTime(2026, 8, 3);
    expect(weekAdd(monday, 1), DateTime(2026, 8, 10));
    expect(weekAdd(monday, -1), DateTime(2026, 7, 27));
  });

  group('weekRangeText', () {
    test('同年输出 MM.dd 短格式(省掉头部年份以适配窄宽导航行)', () {
      final r = weekRangeFor(DateTime(2026, 8, 9));
      expect(weekRangeText(r), '08.03～08.09');
    });

    test('跨年输出完整年份(避免歧义)', () {
      final r = weekRangeFor(DateTime(2027, 1, 1));
      expect(weekRangeText(r), '2026.12.28～2027.01.03');
    });
  });
}
