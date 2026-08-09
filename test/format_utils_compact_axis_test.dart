import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/format_utils.dart';

void main() {
  group('formatCompactAxis 中文', () {
    test('大于等于 1 万用万缩写', () {
      expect(formatCompactAxis(31000), '3.1万');
      expect(formatCompactAxis(10000), '1万');
      expect(formatCompactAxis(45864.08), '4.6万');
      expect(formatCompactAxis(100000), '10万');
    });

    test('小于 1 万用千分位整数', () {
      expect(formatCompactAxis(8769.81), '8,770');
      expect(formatCompactAxis(1316), '1,316');
      expect(formatCompactAxis(999), '999');
      expect(formatCompactAxis(0), '0');
    });

    test('负数', () {
      expect(formatCompactAxis(-23953.35), '-2.4万');
      expect(formatCompactAxis(-1316), '-1,316');
    });
  });

  group('formatCompactAxis 英文', () {
    test('k/M/B 缩写', () {
      expect(formatCompactAxis(31000, isChinese: false), '31k');
      expect(formatCompactAxis(1500, isChinese: false), '1.5k');
      expect(formatCompactAxis(2400000, isChinese: false), '2.4M');
      expect(formatCompactAxis(3200000000, isChinese: false), '3.2B');
      expect(formatCompactAxis(999, isChinese: false), '999');
    });

    test('负数', () {
      expect(formatCompactAxis(-45864.08, isChinese: false), '-45.9k');
    });
  });
}
