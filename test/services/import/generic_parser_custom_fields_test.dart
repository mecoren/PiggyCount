/// v46：CSV 表头「自定义字段」列的识别合同。
///
/// 导出侧写的是 l10n 文案（简/繁/英/韩各一套），导入侧靠 [GenericBillParser]
/// 的表头别名把这一列认出来。任一侧漏改都会让「导出的 CSV 回导后自定义字段
/// 凭空消失」——这类静默丢数据最难被发现，所以按语言逐条锁住。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/services/import/parsers/generic_parser.dart';

void main() {
  final parser = GenericBillParser();

  group('自定义字段列表头识别', () {
    test('简 / 繁 / 英（含空格与大小写）都映射到 custom_fields', () {
      for (final header in const [
        '自定义字段',
        'Custom Fields',
        'custom fields',
        'custom_fields',
        'CUSTOMFIELD',
      ]) {
        expect(
          parser.mapColumns([header])['custom_fields'],
          0,
          reason: '「$header」应被识别为自定义字段列',
        );
      }
    });

    test('不与既有列抢匹配（分类/标签/附件/金额都不受影响）', () {
      final m = parser.mapColumns(
          ['日期', '分类', '标签', '附件', '自定义字段', '金额']);

      expect(m['date'], 0);
      expect(m['category'], 1);
      expect(m['tags'], 2);
      expect(m['attachments'], 3);
      expect(m['custom_fields'], 4);
      expect(m['amount'], 5);
    });

    test('未知列不误吞为自定义字段', () {
      expect(parser.mapColumns(['随便一列'])['custom_fields'], isNull);
      expect(parser.mapColumns(['']).containsKey('custom_fields'), isFalse);
    });
  });
}
