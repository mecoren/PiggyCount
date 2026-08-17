/// H1：远端/损坏 JSON 单字段类型不符时跳过该条目，不中断整账本导入。
library;

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  Map<String, dynamic> baseSnapshot() => {
        'version': 8,
        'ledgerName': 'L',
        'currency': 'CNY',
        'accounts': [
          {'name': '现金', 'type': 'cash'},
        ],
        'items': [
          {
            'type': 'expense',
            'amount': 12.5,
            'categoryName': '餐饮',
            'happenedAt': '2026-08-01T10:00:00.000Z',
            'syncId': 'tx-ok',
          },
        ],
      };

  test('amount 为字符串的损坏交易被跳过，其余交易正常解析', () {
    final map = baseSnapshot();
    (map['items'] as List).add({
      'type': 'expense',
      'amount': 'abc', // 损坏字段（应为 num）
      'happenedAt': '2026-08-02T10:00:00.000Z',
    });
    final data = parseJsonToImportData(jsonEncode(map));

    expect(data.transactions.length, 1);
    expect(data.transactions.first.syncId, 'tx-ok');
    expect(data.skippedItems['transactions'], 1);
  });

  test('happenedAt 非法的交易被跳过', () {
    final map = baseSnapshot();
    (map['items'] as List).add({
      'type': 'expense',
      'amount': 5,
      'happenedAt': 'not-a-date',
    });
    final data = parseJsonToImportData(jsonEncode(map));
    expect(data.transactions.length, 1);
    expect(data.skippedItems['transactions'], 1);
  });

  test('type 非白名单的交易被跳过', () {
    final map = baseSnapshot();
    (map['items'] as List).add({
      'type': 'unknown-type',
      'amount': 5,
      'happenedAt': '2026-08-02T10:00:00.000Z',
    });
    final data = parseJsonToImportData(jsonEncode(map));
    expect(data.transactions.length, 1);
    expect(data.skippedItems['transactions'], 1);
  });

  test('条目不是 Map 的交易被跳过', () {
    final map = baseSnapshot();
    // 用展开重建 List<dynamic>，绕过原列表强元素类型约束
    map['items'] = [...(map['items'] as List), 'corrupt-entry'];
    final data = parseJsonToImportData(jsonEncode(map));
    expect(data.transactions.length, 1);
    expect(data.skippedItems['transactions'], 1);
  });

  test('损坏账户/分类/周期条目被跳过且计数', () {
    final map = baseSnapshot();
    (map['accounts'] as List).add({'type': 'cash'}); // 缺 name
    map['categories'] = (map['categories'] as List?) ?? [];
    (map['categories'] as List).add({'kind': 'expense'}); // 缺 name
    map['recurring'] = (map['recurring'] as List?) ?? [];
    (map['recurring'] as List).add({
      'type': 'expense',
      'amount': 'x', // 损坏
      'frequency': 'monthly',
      'startDate': '2026-01-01T00:00:00.000Z',
    });
    final data = parseJsonToImportData(jsonEncode(map));
    expect(data.accounts.length, 1);
    expect(data.skippedItems['accounts'], 1);
    expect(data.skippedItems['categories'], 1);
    expect(data.skippedItems['recurring'], 1);
  });

  test('顶层不是 JSON 对象时抛出可读 FormatException', () {
    expect(() => parseJsonToImportData('[1,2,3]'),
        throwsA(isA<FormatException>()));
  });

  test('version 字段进入 ImportData', () {
    final data = parseJsonToImportData(jsonEncode(baseSnapshot()));
    expect(data.version, 8);
  });
}
