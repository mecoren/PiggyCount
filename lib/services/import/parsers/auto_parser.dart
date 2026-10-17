import '../bill_parser.dart';
import 'alipay_parser.dart';
import 'generic_parser.dart';
import 'qianji_parser.dart';
import 'suishouji_parser.dart';
import 'wechat_parser.dart';

/// 自动识别账单来源（F6）。
///
/// 按「越具体越优先」的顺序试各 preset：支付宝 → 微信 → 钱迹 → 随手记，
/// 全部不匹配时回落到 [GenericBillParser]。识别结果只会影响**表头行选择**；
/// 列映射与行解析委托给命中的 preset（当前各 preset 都继承通用实现，
/// 未来某个 preset 若覆写 mapColumns/parseRow，这里会自动跟随）。
class AutoBillParser extends GenericBillParser {
  AutoBillParser({List<BillParser>? candidates})
      : _candidates = candidates ??
            <BillParser>[
              AlipayBillParser(),
              WechatBillParser(),
              QianjiBillParser(),
              SuishoujiBillParser(),
            ];

  final List<BillParser> _candidates;

  /// [findHeaderRow] 命中的 preset；null 表示回落到通用解析器。
  BillParser? _matched;

  @override
  String get name => 'Auto';

  @override
  int findHeaderRow(List<List<String>> rows) {
    for (final candidate in _candidates) {
      if (!candidate.validateBillType(rows)) continue;
      final index = candidate.findHeaderRow(rows);
      if (index >= 0) {
        _matched = candidate;
        return index;
      }
    }
    _matched = null;
    return super.findHeaderRow(rows);
  }

  @override
  Map<String, int> mapColumns(List<String> headerRow) {
    final matched = _matched;
    return matched == null
        ? super.mapColumns(headerRow)
        : matched.mapColumns(headerRow);
  }

  @override
  Map<String, dynamic>? parseRow(
    List<String> row,
    Map<String, int> columnMapping,
  ) {
    final matched = _matched;
    return matched == null
        ? super.parseRow(row, columnMapping)
        : matched.parseRow(row, columnMapping);
  }

  @override
  bool validateBillType(List<List<String>> rows) => true;
}
