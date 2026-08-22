import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/format_utils.dart';

void main() {
  group('stripCurrencySymbolPrefix', () {
    test('正数：剥离开头币种符', () {
      expect(stripCurrencySymbolPrefix('¥15万', '¥'), '15万');
    });
    test('负数：保留负号并剥离币种符（审计 U2 核心场景）', () {
      expect(stripCurrencySymbolPrefix('-¥15万', '¥'), '-15万');
    });
    test('无币种符前缀：原样返回', () {
      expect(stripCurrencySymbolPrefix('-1234.56', '¥'), '-1234.56');
    });
    test('symbol 为空：原样返回', () {
      expect(stripCurrencySymbolPrefix('-¥15万', ''), '-¥15万');
    });
    test('多字符符号：一并剥离', () {
      expect(stripCurrencySymbolPrefix(r'-HK$1.2万', r'HK$'), '-1.2万');
    });
  });
}
