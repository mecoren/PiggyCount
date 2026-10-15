/// 通用 CSV 编码构建器（prd/custom_field_stats_fullchain F4）。
///
/// 表头/行的**单元格构造**由各业务导出（如 `custom_field_stats_csv`）负责；
/// 本文件只管两件跨业务共用的事：
/// 1. **公式注入转义**（R3）：`=+-@` 开头的文本单元格前置 `'`；
/// 2. **编码封装**：UTF-8 BOM（Excel 中文兼容）+ `'\n'` 行尾（与
///    `export_page` 的既有导出一致）。
///
/// 为什么转义放在这一层：注入面是「任何被写进 CSV 的用户输入」，散在各业务
/// 里逐处转义必然漏一处；编码前统一过一道没有遗漏面。
/// 引号/分隔符的转义交给 `package:csv` 的 [Csv] 编码器，不重造。
library;

import 'package:csv/csv.dart';

/// 单元格公式注入转义（R3）。
///
/// 以 `=`/`+`/`-`/`@` 开头的**文本**单元格前置单引号（Excel 把它当文本而非
/// 公式求值）。**数字不转义**：'-12.30' / '+1' 这类可解析为数字的文本与
/// num 单元格原样返回 —— 转义会把数字列变成文本列，比注入风险更常见、
/// 对用户更伤。
Object? escapeCsvCell(Object? cell) {
  if (cell is String) {
    if (cell.isEmpty) return cell;
    if (num.tryParse(cell) != null) return cell;
    final first = cell[0];
    if (first == '=' || first == '+' || first == '-' || first == '@') {
      return "'$cell";
    }
    return cell;
  }
  return cell;
}

/// 行集 → CSV 文本：先逐单元格公式转义，再编码，最后前置 UTF-8 BOM。
String encodeCsvWithBom(List<List<dynamic>> rows) {
  final escaped = [
    for (final row in rows) [for (final cell in row) escapeCsvCell(cell)],
  ];
  return '﻿${Csv(lineDelimiter: '\n').encode(escaped)}';
}
