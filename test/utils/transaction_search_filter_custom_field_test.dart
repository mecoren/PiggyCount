// 字段值筛选条件（prd/custom_field_stats_fullchain F3）命中判定。
//
// 与既有 `transaction_search_filter_test.dart`（断言零改动）正交：
// 新维度 customFieldConditions 并入同一 filter 对象，eq（值等值）/
// between（金额区间，按 abs 比较、半开区间，与分布分档同源）。

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/utils/transaction_search_filter.dart';

void main() {
  Transaction tx({String? customValuesJson}) {
    return Transaction(
      id: 1,
      ledgerId: 1,
      type: 'expense',
      amount: 100,
      categoryId: null,
      accountId: null,
      toAccountId: null,
      happenedAt: DateTime(2026, 9, 15, 12),
      note: null,
      excludeFromStats: false,
      excludeFromBudget: false,
      currencyCode: null,
      reimburseStatus: 'none',
      customValuesJson: customValuesJson,
    );
  }

  group('isEmpty', () {
    test('字段值条件落地即非空', () {
      expect(
        const TransactionSearchFilter(customFieldConditions: [
          CustomFieldCondition.eq(
              fieldSyncId: 'f1',
              fieldName: '渠道',
              fieldType: 'singleSelect',
              value: '微信'),
        ]).isNotEmpty,
        isTrue,
      );
    });

    test('空条件列表视为空', () {
      expect(
        const TransactionSearchFilter(customFieldConditions: []).isEmpty,
        isTrue,
      );
    });
  });

  group('eq 值等值', () {
    const cond = CustomFieldCondition.eq(
        fieldSyncId: 'f1',
        fieldName: '渠道',
        fieldType: 'singleSelect',
        value: '微信');

    test('命中：标量值等值', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(
          filter.matches(
              t: tx(customValuesJson: '{"f1":"微信"}')),
          isTrue);
    });

    test('不命中：值不同', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(
          filter.matches(t: tx(customValuesJson: '{"f1":"支付宝"}')),
          isFalse);
    });

    test('不命中：字段未填 / 值为空', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(filter.matches(t: tx(customValuesJson: null)), isFalse);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":null}')), isFalse);
      expect(filter.matches(t: tx(customValuesJson: '{"f2":"微信"}')), isFalse);
    });

    test('多选列表：含该值即命中（与拆桶语义同源）', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(
          filter.matches(
              t: tx(customValuesJson: '{"f1":["微信","支付宝"]}')),
          isTrue);
      expect(
          filter.matches(t: tx(customValuesJson: '{"f1":["支付宝"]}')),
          isFalse);
    });

    test('规范化比较：数值标签 100 与 100.0 同桶', () {
      const filter = TransactionSearchFilter(customFieldConditions: [
        CustomFieldCondition.eq(
            fieldSyncId: 'f1',
            fieldName: '金额档',
            fieldType: 'amount',
            value: '100'),
      ]);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":100.0}')), isTrue);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":100}')), isTrue);
    });
  });

  group('between 区间（半开 [lower, upper)，按 abs 比较，与分布分档同源）', () {
    const cond = CustomFieldCondition.between(
        fieldSyncId: 'f1',
        fieldName: '押金',
        fieldType: 'amount',
        lower: 10,
        upper: 100);

    test('命中：边界含下不含上', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":10}')), isTrue);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":99.5}')), isTrue);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":100}')), isFalse);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":9.9}')), isFalse);
    });

    test('按绝对值比较：负值同档', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":-50}')), isTrue);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":-500}')), isFalse);
    });

    test('开区间上界（最高档）', () {
      const filter = TransactionSearchFilter(customFieldConditions: [
        CustomFieldCondition.between(
            fieldSyncId: 'f1',
            fieldName: '押金',
            fieldType: 'amount',
            lower: 10000),
      ]);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":20000}')), isTrue);
      expect(filter.matches(t: tx(customValuesJson: '{"f1":9999}')), isFalse);
    });

    test('脏值（非数值）不命中区间', () {
      const filter = TransactionSearchFilter(customFieldConditions: [cond]);
      expect(
          filter.matches(t: tx(customValuesJson: '{"f1":"abc"}')), isFalse);
      expect(
          filter.matches(t: tx(customValuesJson: '{"f1":["10","200"]}')),
          isFalse);
    });
  });

  group('contains / anyOf（洞察筛选）', () {
    test('文本包含忽略大小写，多选任一命中', () {
      const text = CustomFieldCondition.contains(
        fieldSyncId: 'f1',
        fieldName: '商户',
        fieldType: 'text',
        value: 'STAR',
      );
      const any = CustomFieldCondition.anyOf(
        fieldSyncId: 'f2',
        fieldName: '标签',
        fieldType: 'multiSelect',
        values: {'A', 'B'},
      );
      const filter =
          TransactionSearchFilter(customFieldConditions: [text, any]);
      expect(
        filter.matches(
            t: tx(customValuesJson: '{"f1":"Starbucks","f2":["C","B"]}')),
        isTrue,
      );
      expect(
        filter.matches(
            t: tx(customValuesJson: '{"f1":"Starbucks","f2":["C"]}')),
        isFalse,
      );
    });
  });

  group('与既有条件正交', () {
    test('字段值 + 金额条件同时生效（都命中才过）', () {
      const filter = TransactionSearchFilter(
        minAmount: 50,
        maxAmount: 150,
        customFieldConditions: [
          CustomFieldCondition.eq(
              fieldSyncId: 'f1',
              fieldName: '渠道',
              fieldType: 'singleSelect',
              value: '微信'),
        ],
      );
      expect(filter.matches(t: tx(customValuesJson: '{"f1":"微信"}')), isTrue);
      // 字段值不命中 → 整体不命中
      expect(filter.matches(t: tx(customValuesJson: '{"f1":"现金"}')), isFalse);
    });

    test('多字段条件：全部命中才过', () {
      const filter = TransactionSearchFilter(customFieldConditions: [
        CustomFieldCondition.eq(
            fieldSyncId: 'f1',
            fieldName: '渠道',
            fieldType: 'singleSelect',
            value: '微信'),
        CustomFieldCondition.between(
            fieldSyncId: 'f2',
            fieldName: '押金',
            fieldType: 'amount',
            lower: 0,
            upper: 50),
      ]);
      expect(
          filter.matches(
              t: tx(customValuesJson: '{"f1":"微信","f2":30}')),
          isTrue);
      expect(
          filter.matches(
              t: tx(customValuesJson: '{"f1":"微信","f2":300}')),
          isFalse);
    });
  });
}
