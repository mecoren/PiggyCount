/// F6 更多解析器：列名别名 + 钱迹/随手记 preset + 自动识别。
///
/// 这些 preset 只影响**表头行选择**，列映射/取值仍走通用实现；因此测试
/// 重点守「签名不互相误判」和「识别失败能安全回落通用」。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/services/import/parsers/auto_parser.dart';
import 'package:piggycount/services/import/parsers/generic_parser.dart';
import 'package:piggycount/services/import/parsers/qianji_parser.dart';
import 'package:piggycount/services/import/parsers/suishouji_parser.dart';

void main() {
  group('通用解析器列名别名（F6）', () {
    final parser = GenericBillParser();

    test('账户转入 / 账户转出 识别为 to_account / from_account', () {
      final mapping = parser.mapColumns(['日期', '账户转出', '账户转入', '金额']);
      expect(mapping['from_account'], 1);
      expect(mapping['to_account'], 2);
      expect(mapping['account'], isNull, reason: '不能被通用「账户」抢先映射');
    });

    test('付款方 / 收款方 / 交易对象 / 商户名称 / 交易描述 进 note', () {
      for (final header in <String>[
        '付款方',
        '收款方',
        '交易对象',
        '商户名称',
        '交易描述',
      ]) {
        expect(parser.mapColumns(<String>[header])['note'], 0, reason: header);
      }
    });

    test('账目 识别为 category', () {
      expect(parser.mapColumns(<String>['账目'])['category'], 0);
    });
  });

  group('preset 签名识别', () {
    test('钱迹：时间 + 类型 + 金额 + 分类 命中', () {
      final parser = QianjiBillParser();
      expect(
        parser.validateBillType(<List<String>>[
          <String>['时间', '类型', '金额', '分类', '账户', '备注'],
        ]),
        isTrue,
      );
      // 支付宝（交易时间/收 支，无「分类」列）不能误判成钱迹。
      expect(
        parser.validateBillType(<List<String>>[
          <String>['交易时间', '交易类型', '交易对方', '商品说明', '收/支', '金额'],
        ]),
        isFalse,
      );
      // 随手记用「日期」而不是「时间」。
      expect(
        parser.validateBillType(<List<String>>[
          <String>['日期', '分类', '金额', '账户'],
        ]),
        isFalse,
      );
    });

    test('随手记：日期 + 分类 + 金额 + 账户 命中', () {
      final parser = SuishoujiBillParser();
      expect(
        parser.validateBillType(<List<String>>[
          <String>['日期', '账本', '分类', '子分类', '金额', '账户1'],
        ]),
        isTrue,
      );
      expect(
        parser.validateBillType(<List<String>>[
          <String>['时间', '类型', '金额', '分类'],
        ]),
        isFalse,
      );
    });
  });

  group('自动识别（AutoBillParser）', () {
    test('支付宝前导说明 + 交易时间/商品说明 → 命中支付宝表头', () {
      final rows = <List<String>>[
        <String>['支付宝账单'],
        <String>['导出时间：2026-10-01'],
        <String>[],
        <String>['交易时间', '交易分类', '交易对方', '商品说明', '收/支', '金额'],
        <String>['2026-10-01 12:00', '餐饮', '某店', '午饭', '支出', '30.00'],
      ];
      expect(AutoBillParser().findHeaderRow(rows), 3);
    });

    test('微信表头 → 命中微信表头', () {
      final rows = <List<String>>[
        <String>['微信支付账单明细'],
        <String>['交易时间', '交易类型', '交易对方', '商品', '收/支', '金额'],
        <String>['2026-10-01 12:00', '商户消费', '某店', '午饭', '支出', '30.00'],
      ];
      expect(AutoBillParser().findHeaderRow(rows), 1);
    });

    test('钱迹表头 → 命中钱迹表头，列映射跟随通用实现', () {
      final rows = <List<String>>[
        <String>['钱迹导出'],
        <String>['时间', '类型', '金额', '分类', '账户', '备注'],
        <String>['2026-10-01 12:00', '支出', '30.00', '餐饮', '现金', '午饭'],
      ];
      final parser = AutoBillParser();
      expect(parser.findHeaderRow(rows), 1);
      final mapping = parser.mapColumns(rows[1]);
      expect(mapping['date'], 0);
      expect(mapping['type'], 1);
      expect(mapping['amount'], 2);
      expect(mapping['category'], 3);
    });

    test('随手记表头 → 命中随手记表头', () {
      final rows = <List<String>>[
        <String>['随手记导出'],
        <String>['日期', '账本', '分类', '子分类', '金额', '账户1', '账户2'],
        <String>['2026-10-01', '日常', '餐饮', '午餐', '30.00', '现金', ''],
      ];
      expect(AutoBillParser().findHeaderRow(rows), 1);
    });

    test('无特征表头 → 安全回落通用解析器', () {
      final rows = <List<String>>[
        <String>['A', 'B', 'C', 'D'],
        <String>['1', '2', '3', '4'],
        <String>['1', '2', '3', '4'],
        <String>['1', '2', '3', '4'],
        <String>['1', '2', '3', '4'],
        <String>['1', '2', '3', '4'],
      ];
      final parser = AutoBillParser();
      expect(parser.findHeaderRow(rows), isNonNegative);
      expect(parser.findHeaderRow(<List<String>>[]), -1);
    });
  });
}
