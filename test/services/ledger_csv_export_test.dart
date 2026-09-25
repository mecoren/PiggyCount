/// 账本明细 CSV 导出（C1）回归：13 列的「表头 ↔ 行」对齐与单元格口径。
///
/// 此前这些列只存在于 `export_page` 的 UI 状态方法里，靠人工核对与 lint 守着
/// —— 增删列（如 v46 自定义字段列）时很容易只改表头或只改行，回导整列错位。
/// 抽成纯函数后本文件锁住：列数/列序一致、分类归位、币种兜底链、自定义字段
/// JSON（键=字段名、按定义顺序、野值不导出）。
library;

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/export/ledger_csv.dart';

final AppLocalizations zh = lookupAppLocalizations(const Locale('zh'));

Transaction tx({
  int id = 1,
  String type = 'expense',
  double amount = 12.3,
  int? categoryId,
  int? accountId,
  int? toAccountId,
  String? note,
  String? currencyCode,
  DateTime? happenedAt,
}) =>
    Transaction(
      id: id,
      ledgerId: 1,
      type: type,
      amount: amount,
      categoryId: categoryId,
      accountId: accountId,
      toAccountId: toAccountId,
      happenedAt: happenedAt ?? DateTime(2026, 6, 18, 9, 5, 3),
      note: note,
      currencyCode: currencyCode,
      excludeFromStats: false,
      excludeFromBudget: false,
    );

Category cat({
  required int id,
  required String name,
  int level = 1,
  int? parentId,
  String kind = 'expense',
}) =>
    Category(
      id: id,
      name: name,
      kind: kind,
      sortOrder: id,
      parentId: parentId,
      level: level,
      iconType: 'material',
    );

Account acc({required int id, required String name, String currency = 'CNY'}) =>
    Account(
      id: id,
      ledgerId: 0,
      name: name,
      type: 'cash',
      currency: currency,
      initialBalance: 0,
      sortOrder: id,
      hidden: false,
    );

CustomFieldDefinition field({
  required int id,
  required String name,
  String? syncId,
  String fieldType = 'text',
}) =>
    CustomFieldDefinition(
      id: id,
      ledgerId: 1,
      name: name,
      fieldType: fieldType,
      sortOrder: id,
      createdAt: DateTime(2026, 1, 1),
      syncId: syncId,
    );

/// 只关心少数几列时的默认参数：一笔挂在「现金」账户上的支出。
List<dynamic> row({
  Transaction? t,
  Category? category,
  Account? account,
  Account? toAccount,
  Map<int, Category> allCategories = const {},
  List<String> tagNames = const [],
  List<String> attachmentFileNames = const [],
  List<CustomFieldDefinition> customFieldDefinitions = const [],
  Map<String, dynamic>? customValues,
  String ledgerBaseCurrency = 'CNY',
}) =>
    buildLedgerCsvRow(
      l10n: zh,
      tx: t ?? tx(),
      category: category,
      account: account ?? acc(id: 5, name: '现金'),
      toAccount: toAccount,
      allCategories: allCategories,
      tagNames: tagNames,
      attachmentFileNames: attachmentFileNames,
      customFieldDefinitions: customFieldDefinitions,
      customValues: customValues,
      ledgerBaseCurrency: ledgerBaseCurrency,
    );

void main() {
  group('表头与数据行对齐', () {
    test('13 列，自定义字段列在末位', () {
      final headers = ledgerCsvHeaders(zh);
      expect(headers.length, 13);
      expect(headers.last, zh.exportCsvHeaderCustomFields);
      // 顺序即列序，回导按表头匹配：挪列等于改协议，必须显式改这里
      expect(headers, [
        zh.exportCsvHeaderType,
        zh.exportCsvHeaderCategory,
        zh.exportCsvHeaderSubCategory,
        zh.exportCsvHeaderAmount,
        zh.exportCsvHeaderCurrency,
        zh.exportCsvHeaderAccount,
        zh.exportCsvHeaderFromAccount,
        zh.exportCsvHeaderToAccount,
        zh.exportCsvHeaderNote,
        zh.exportCsvHeaderTime,
        zh.exportCsvHeaderTags,
        zh.exportCsvHeaderAttachments,
        zh.exportCsvHeaderCustomFields,
      ]);
    });

    test('行的列数必须等于表头列数（表头/行同源，防止只改一边）', () {
      final headers = ledgerCsvHeaders(zh);
      expect(row().length, headers.length);
      expect(
        row(
          t: tx(type: 'transfer', amount: 100, accountId: 5, toAccountId: 6),
          toAccount: acc(id: 6, name: '支付宝'),
          category: cat(id: 2, name: '早餐', level: 2, parentId: 1),
          customFieldDefinitions: [field(id: 1, name: '发票号', syncId: 'cf_a')],
          customValues: {'cf_a': 'X-1'},
        ).length,
        headers.length,
      );
    });
  });

  group('支出行', () {
    test('二级分类归位：分类列取父分类，二级列取本身', () {
      final parent = cat(id: 1, name: '餐饮');
      final child = cat(id: 2, name: '早餐', level: 2, parentId: 1);
      final r = row(
        t: tx(amount: 12.3, categoryId: 2, currencyCode: 'CNY'),
        category: child,
        allCategories: {1: parent, 2: child},
      );

      expect(r[0], zh.exportTypeExpense);
      expect(r[1], '餐饮');
      expect(r[2], '早餐');
      expect(r[3], '12.30'); // 金额固定两位小数（回导按数字解析）
      expect(r[4], 'CNY');
      expect(r[5], '现金');
      expect(r[6], ''); // 转出账户
      expect(r[7], ''); // 转入账户
      expect(r[8], ''); // 备注 null → 空串
      expect(r[9], '  2026-06-18 09:05:03  ');
      expect(r[12], '');
    });

    test('一级分类只填分类列；未分类两列皆空', () {
      expect(row(category: cat(id: 1, name: '餐饮'))[2], '');
      expect(row(category: cat(id: 1, name: '餐饮'))[1], '餐饮');
      expect(row(category: null)[1], '');
      expect(row(category: null)[2], '');
    });

    test('标签/附件按逗号拼接；备注原样输出', () {
      final r = row(
        t: tx(note: '两行\n备注'),
        tagNames: const ['出差', '报销'],
        attachmentFileNames: const ['a.jpg', 'b.png'],
      );
      expect(r[8], '两行\n备注');
      expect(r[10], '出差,报销');
      expect(r[11], 'a.jpg,b.png');
    });
  });

  group('转账行', () {
    test('账户列留空，转出/转入分列；分类两列空', () {
      final r = row(
        t: tx(
          type: 'transfer',
          amount: 100,
          accountId: 5,
          toAccountId: 6,
          categoryId: 2, // 脏数据：转账不该有分类，导出必须忽略
        ),
        account: acc(id: 5, name: '招行'),
        toAccount: acc(id: 6, name: '支付宝'),
        category: cat(id: 2, name: '早餐', level: 2, parentId: 1),
      );

      expect(r[0], zh.exportTypeTransfer);
      expect(r[1], '');
      expect(r[2], '');
      expect(r[5], '');
      expect(r[6], '招行');
      expect(r[7], '支付宝');
    });
  });

  group('币种列兜底链（交易 → 账户 → 账本本位币）', () {
    test('交易币种优先，且统一大写', () {
      final r = row(
        t: tx(currencyCode: 'usd'),
        account: acc(id: 5, name: '现金', currency: 'JPY'),
        ledgerBaseCurrency: 'EUR',
      );
      expect(r[4], 'USD');
    });

    test('交易币种缺失 → 账户币种', () {
      final r = row(
        account: acc(id: 5, name: '现金', currency: 'eur'),
        ledgerBaseCurrency: 'CNY',
      );
      expect(r[4], 'EUR');
    });

    test('账户币种为空串 → 账本本位币', () {
      final r = row(
        account: acc(id: 5, name: '现金', currency: ''),
        ledgerBaseCurrency: 'jpy',
      );
      expect(r[4], 'JPY');
    });

    test('无账户 → 账本本位币', () {
      final r = buildLedgerCsvRow(
        l10n: zh,
        tx: tx(accountId: null),
        category: null,
        account: null,
        toAccount: null,
        allCategories: const {},
        tagNames: const [],
        attachmentFileNames: const [],
        customFieldDefinitions: const [],
        customValues: null,
        ledgerBaseCurrency: 'usd',
      );
      expect(r[4], 'USD');
      expect(r[5], ''); // 账户列留空
    });
  });

  group('v46 自定义字段列', () {
    test('按定义顺序输出 {字段名: 值}，键不是 syncId', () {
      final r = row(
        customFieldDefinitions: [
          field(id: 1, name: '发票号', syncId: 'cf_a'),
          field(id: 2, name: '含税金额', syncId: 'cf_b', fieldType: 'amount'),
        ],
        customValues: const {'cf_b': 120.0, 'cf_a': 'X-1'},
      );

      expect(jsonDecode(r[12] as String), {'发票号': 'X-1', '含税金额': 120.0});
      // 定义顺序决定键顺序（定义按 sortOrder 查询，导出结果稳定可比）
      expect(r[12] as String, '{"发票号":"X-1","含税金额":120.0}');
    });

    test('无值 / 空值 → 空串（不留 {} 噪音列）', () {
      final defs = [field(id: 1, name: '发票号', syncId: 'cf_a')];
      expect(row(customFieldDefinitions: defs)[12], '');
      expect(row(customFieldDefinitions: defs, customValues: const {})[12], '');
    });

    test('定义已被删除的野值不导出（UI 上不可见的值不进 CSV）', () {
      final r = row(
        customFieldDefinitions: [field(id: 1, name: '发票号', syncId: 'cf_a')],
        customValues: const {'cf_orphan': 'X-9'},
      );
      expect(r[12], '');
    });

    test('定义缺 syncId（异常数据）不产生键，也不崩', () {
      final r = row(
        customFieldDefinitions: [field(id: 1, name: '发票号')],
        customValues: const {'cf_a': 'X-1'},
      );
      expect(r[12], '');
    });
  });

  group('类型列', () {
    test('已知类型走 l10n，未知类型（含 adjustment）原样输出', () {
      expect(ledgerCsvTypeLabel(zh, 'income'), zh.exportTypeIncome);
      expect(ledgerCsvTypeLabel(zh, 'expense'), zh.exportTypeExpense);
      expect(ledgerCsvTypeLabel(zh, 'transfer'), zh.exportTypeTransfer);
      expect(ledgerCsvTypeLabel(zh, 'adjustment'), 'adjustment');
    });
  });
}
