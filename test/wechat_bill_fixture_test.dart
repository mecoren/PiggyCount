import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/services/import/csv_parser.dart';
import 'package:piggycount/services/import/parsers/wechat_parser.dart';
import 'package:piggycount/utils/date_parser.dart';

/// 校验 scripts/gen_wechat_bill_2024_2026.py 生成的账单能被
/// 微信导入链路（CsvParser -> WechatBillParser -> 列映射 -> 类型/金额解析）
/// 完整、无跳过地解析。
void main() {
  for (final year in [2024, 2025, 2026]) {
    test('wechat_bill_$year.csv 可被微信导入链路正确解析', () {
      final file = File('demo/wechat_bill_$year.csv');
      expect(file.existsSync(), isTrue, reason: '账单文件不存在，请先运行生成脚本');

      final rows = CsvParser.parse(file.readAsStringSync());
      final parser = WechatBillParser();

      // 1. 账单类型识别 + 表头定位
      expect(parser.validateBillType(rows), isTrue);
      final headerRow = parser.findHeaderRow(rows);
      expect(headerRow, greaterThanOrEqualTo(0));

      final headers = rows[headerRow].map((e) => e.trim()).toList();
      expect(headers.first, '交易时间');

      // 2. 列映射必须命中关键字段
      final mapping = parser.mapColumns(headers);
      for (final key in ['date', 'type', 'amount', 'category', 'note']) {
        expect(mapping.containsKey(key), isTrue, reason: '$key 列未映射');
      }

      // 3. 逐行解析，统计收支
      double income = 0, expense = 0;
      int skipped = 0;
      final days = <String>{};

      for (int i = headerRow + 1; i < rows.length; i++) {
        final r = rows[i];
        String? cell(String key) {
          final idx = mapping[key];
          if (idx == null || idx < 0 || idx >= r.length) return null;
          final v = r[idx].trim();
          return v.isEmpty ? null : v;
        }

        final typeRaw = (cell('type') ?? '').trim();
        final amount = double.tryParse(
                (cell('amount') ?? '0').replaceAll(RegExp(r'[¥$,+-]'), '')) ??
            0.0;
        final dt = DateParser.tryParse(cell('date'));

        expect(dt, isNotNull, reason: '第 ${i + 1} 行日期解析失败');
        expect(dt!.year, year, reason: '第 ${i + 1} 行年份不匹配');
        expect(amount, greaterThan(0), reason: '第 ${i + 1} 行金额异常');
        expect(cell('category'), isNotNull);
        expect(cell('note'), isNotNull);

        days.add('${dt.month}-${dt.day}');

        if (typeRaw == '收入') {
          income += amount;
        } else if (typeRaw == '支出') {
          expense += amount;
        } else {
          skipped++;
        }
      }

      // 4. 无跳过行
      expect(skipped, 0, reason: '存在无法识别收/支类型的行');

      // 5. 每天都有数据
      final expectedDays =
          DateTime(year, 12, 31).difference(DateTime(year, 1, 1)).inDays + 1;
      expect(days.length, expectedDays, reason: '存在没有交易记录的日期');

      // 6. 金额区间符合要求
      expect(expense, inInclusiveRange(1000000, 2000000),
          reason: '年支出应在 100-200 万');
      expect(income, inInclusiveRange(4500000, 5500000),
          reason: '年收入应在 500 万左右');

      // ignore: avoid_print
      print('$year -> 记录 ${rows.length - headerRow - 1} 条, '
          '收入 ${income.toStringAsFixed(2)}, 支出 ${expense.toStringAsFixed(2)}');
    });
  }
}
