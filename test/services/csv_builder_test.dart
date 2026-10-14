/// 通用 CSV 编码构建器（prd/custom_field_stats_fullchain F4，阶段 4 RED）。
///
/// 保护四件事：
/// 1. **UTF-8 BOM + '\n' 行尾**：Excel 打开中文不乱码（与 export_page 同款）；
/// 2. **公式注入转义**（R3）：`=+-@` 开头的**文本**单元格前置 `'`；
/// 3. **负数不受转义误伤**：'-12.30' / 数值型单元格原样输出（转义破坏数字
///    列会让 Excel 变文本列，比注入风险更常见）；
/// 4. **引号/分隔符**交给 csv 包的既有转义（本层只做公式前缀，不重造编码）。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/services/export/csv_builder.dart';

void main() {
  group('escapeCsvCell', () {
    test('=+-@ 开头的文本 → 前置单引号（R3 公式注入）', () {
      expect(escapeCsvCell('=SUM(A1)'), "'=SUM(A1)");
      expect(escapeCsvCell('+cmd'), "'+cmd");
      expect(escapeCsvCell('-drop table'), "'-drop table");
      expect(escapeCsvCell('@import'), "'@import");
    });

    test('负数与正数文本不转义（数字列保持可计算）', () {
      expect(escapeCsvCell('-12.30'), '-12.30');
      expect(escapeCsvCell('+1'), '+1');
      expect(escapeCsvCell('12'), '12');
    });

    test('数值型单元格与普通文本原样返回', () {
      expect(escapeCsvCell(12.3), 12.3);
      expect(escapeCsvCell(-5), -5);
      expect(escapeCsvCell('普通文本'), '普通文本');
      expect(escapeCsvCell(''), '');
    });
  });

  group('encodeCsvWithBom', () {
    test('BOM 前缀 + \\n 行尾（Excel 中文兼容）', () {
      final out = encodeCsvWithBom([
        ['字段名', '数值'],
        ['押金', 300],
      ]);
      expect(out, startsWith('﻿'));
      expect(out, '﻿字段名,数值\n押金,300');
    });

    test('空行集 → 只有 BOM', () {
      expect(encodeCsvWithBom(const []), '﻿');
    });

    test('含逗号/引号单元格走 csv 包转义', () {
      final out = encodeCsvWithBom([
        ['a,b', 'he said "hi"'],
      ]);
      expect(out, '﻿"a,b","he said ""hi"""');
    });

    test('公式注入在整串编码后仍被转义', () {
      final out = encodeCsvWithBom([
        ['=HYPERLINK("http://x")'],
      ]);
      expect(out, contains("'=HYPERLINK"));
    });
  });
}
