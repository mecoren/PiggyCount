import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/widgets/biz/transaction_list_item.dart';

void main() {
  group('nativeConversionVisible 与 AmountText 隐藏口径一致', () {
    test('显式 hide=true → 不可见', () {
      expect(nativeConversionVisible(hide: true, globalHide: true), isFalse);
      expect(nativeConversionVisible(hide: true, globalHide: false), isFalse);
    });
    test('未传 hide 回落全局开关（calendar 未传 hide 的缺陷场景）', () {
      expect(nativeConversionVisible(hide: null, globalHide: true), isFalse);
    });
    test('全局关闭且未显式隐藏 → 可见', () {
      expect(nativeConversionVisible(hide: null, globalHide: false), isTrue);
    });
  });
}
