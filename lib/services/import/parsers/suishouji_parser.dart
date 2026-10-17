import 'generic_parser.dart';

/// 随手记（Suishouji）CSV 导出预设。
///
/// 公开版导出表头通常为：
/// `日期, 账本, 分类, 子分类, 金额, 账户1, 账户2, 备注, 标签, 收支`
///
/// 与钱迹的区分点：日期列叫「日期」而不是「时间」，且通常带「账本」列。
/// 只做表头识别；列映射与取值复用 [GenericBillParser]。
class SuishoujiBillParser extends GenericBillParser {
  @override
  String get name => 'Suishouji';

  static const List<String> _signature = <String>['日期', '分类', '金额', '账户'];

  @override
  int findHeaderRow(List<List<String>> rows) {
    final index = findHeaderRowByKeywords(rows, _signature);
    return index ?? super.findHeaderRow(rows);
  }

  @override
  bool validateBillType(List<List<String>> rows) =>
      findHeaderRowByKeywords(rows, _signature) != null;
}
