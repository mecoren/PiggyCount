import 'generic_parser.dart';

/// 钱迹（Qianji）CSV 导出预设。
///
/// 公开版导出表头通常为：
/// `时间, 类型, 金额, 分类, 子分类, 账户, 标签, 备注`
///
/// 与支付宝/微信的区分点：时间是「时间」而不是「交易时间」，且必有「分类」
/// 列。这里只做**表头识别**，列映射与取值仍复用 [GenericBillParser]；
/// 若实际样本列名不同，自动识别会安全回落到通用解析器。
class QianjiBillParser extends GenericBillParser {
  @override
  String get name => 'Qianji';

  static const List<String> _signature = <String>['时间', '类型', '金额', '分类'];

  @override
  int findHeaderRow(List<List<String>> rows) {
    final index = findHeaderRowByKeywords(rows, _signature);
    return index ?? super.findHeaderRow(rows);
  }

  @override
  bool validateBillType(List<List<String>> rows) =>
      findHeaderRowByKeywords(rows, _signature) != null;
}
