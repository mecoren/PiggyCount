// 搜索页多维筛选的命中判定（账户 / 标签 / 附件 / 币种是新增维度，
// 关键字 / 分类 / 金额 / 日期为既有维度，一并钉住不回归）。

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/utils/transaction_search_filter.dart';

void main() {
  Transaction tx({
    int id = 1,
    String type = 'expense',
    double amount = 100,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    DateTime? happenedAt,
    String? note,
    String? currencyCode,
  }) {
    return Transaction(
      id: id,
      ledgerId: 1,
      type: type,
      amount: amount,
      categoryId: categoryId,
      accountId: accountId,
      toAccountId: toAccountId,
      happenedAt: happenedAt ?? DateTime(2026, 9, 15, 12),
      note: note,
      excludeFromStats: false,
      excludeFromBudget: false,
      currencyCode: currencyCode,
    );
  }

  Category category({int id = 1, int? parentId, String name = '餐饮'}) {
    return Category(
      id: id,
      name: name,
      kind: 'expense',
      sortOrder: 0,
      parentId: parentId,
      level: parentId == null ? 1 : 2,
      iconType: 'material',
    );
  }

  group('isEmpty', () {
    test('无条件视为空', () {
      expect(const TransactionSearchFilter().isEmpty, isTrue);
      expect(
        const TransactionSearchFilter(keyword: '   ', tagIds: <int>{}).isEmpty,
        isTrue,
      );
    });

    test('任一维度落地即非空', () {
      expect(const TransactionSearchFilter(keyword: '午餐').isNotEmpty, isTrue);
      expect(const TransactionSearchFilter(accountId: 2).isNotEmpty, isTrue);
      expect(const TransactionSearchFilter(tagIds: {1}).isNotEmpty, isTrue);
      expect(const TransactionSearchFilter(hasAttachment: false).isNotEmpty,
          isTrue);
      expect(const TransactionSearchFilter(currencyCode: 'USD').isNotEmpty,
          isTrue);
    });
  });

  group('关键字 / 分类 / 金额 / 日期', () {
    test('关键字命中备注、分类显示名或金额文本', () {
      const filter = TransactionSearchFilter(keyword: '午餐');
      expect(filter.matches(t: tx(note: '公司午餐'), categoryDisplayName: '餐饮'),
          isTrue);
      expect(filter.matches(t: tx(note: '打车'), categoryDisplayName: '交通'),
          isFalse);
      expect(filter.matches(t: tx(note: null), categoryDisplayName: '午餐费'),
          isTrue);
      expect(
          TransactionSearchFilter(keyword: '100').matches(t: tx(amount: 100)),
          isTrue);
    });

    test('分类筛选命中自身与直接子分类', () {
      const filter = TransactionSearchFilter(categoryId: 7);
      expect(filter.matches(t: tx(categoryId: 7), category: category(id: 7)),
          isTrue);
      expect(
          filter.matches(
              t: tx(categoryId: 8), category: category(id: 8, parentId: 7)),
          isTrue);
      expect(
          filter.matches(
              t: tx(categoryId: 8), category: category(id: 8, parentId: 99)),
          isFalse);
      expect(filter.matches(t: tx(), category: null), isFalse);
    });

    test('金额区间按绝对值且闭区间', () {
      const filter = TransactionSearchFilter(minAmount: 50, maxAmount: 100);
      expect(filter.matches(t: tx(amount: -50)), isTrue);
      expect(filter.matches(t: tx(amount: 100)), isTrue);
      expect(filter.matches(t: tx(amount: 49.99)), isFalse);
      expect(filter.matches(t: tx(amount: 100.01)), isFalse);
    });

    test('日期区间含当天首尾时刻', () {
      final filter = TransactionSearchFilter(
        startDate: DateTime(2026, 9, 1),
        endDate: DateTime(2026, 9, 15),
      );
      expect(filter.matches(t: tx(happenedAt: DateTime(2026, 9, 1))), isTrue);
      expect(
          filter.matches(t: tx(happenedAt: DateTime(2026, 9, 15, 23, 59, 59))),
          isTrue);
      expect(
          filter.matches(t: tx(happenedAt: DateTime(2026, 8, 31, 23, 59, 59))),
          isFalse);
      expect(filter.matches(t: tx(happenedAt: DateTime(2026, 9, 16))), isFalse);
    });
  });

  group('账户', () {
    test('命中的是转出账户或转入账户', () {
      const filter = TransactionSearchFilter(accountId: 3);
      expect(filter.matches(t: tx(accountId: 3)), isTrue);
      expect(
          filter.matches(t: tx(type: 'transfer', accountId: 1, toAccountId: 3)),
          isTrue);
      expect(filter.matches(t: tx(accountId: 1, toAccountId: 2)), isFalse);
      expect(filter.matches(t: tx()), isFalse);
    });
  });

  group('标签', () {
    test('任一选中标签命中即算匹配（OR 语义）', () {
      const filter = TransactionSearchFilter(tagIds: {1, 2});
      expect(filter.matches(t: tx(), transactionTagIds: {2, 9}), isTrue);
      expect(filter.matches(t: tx(), transactionTagIds: {1}), isTrue);
      expect(filter.matches(t: tx(), transactionTagIds: {3}), isFalse);
      expect(filter.matches(t: tx(), transactionTagIds: const {}), isFalse);
    });
  });

  group('附件', () {
    test('三态：不限 / 仅有附件 / 仅无附件', () {
      expect(
          const TransactionSearchFilter()
              .matches(t: tx(), hasTransactionAttachment: true),
          isTrue);
      expect(
          const TransactionSearchFilter(hasAttachment: true)
              .matches(t: tx(), hasTransactionAttachment: true),
          isTrue);
      expect(
          const TransactionSearchFilter(hasAttachment: true)
              .matches(t: tx(), hasTransactionAttachment: false),
          isFalse);
      expect(
          const TransactionSearchFilter(hasAttachment: false)
              .matches(t: tx(), hasTransactionAttachment: false),
          isTrue);
      expect(
          const TransactionSearchFilter(hasAttachment: false)
              .matches(t: tx(), hasTransactionAttachment: true),
          isFalse);
    });
  });

  group('币种', () {
    test('显式币种按交易行匹配，大小写不敏感', () {
      const filter = TransactionSearchFilter(currencyCode: 'usd');
      expect(filter.matches(t: tx(currencyCode: 'USD')), isTrue);
      expect(filter.matches(t: tx(currencyCode: 'JPY')), isFalse);
    });

    test('交易未记币种时按账本本位币匹配', () {
      const filter = TransactionSearchFilter(currencyCode: 'CNY');
      expect(filter.matches(t: tx(), ledgerCurrency: 'CNY'), isTrue);
      expect(filter.matches(t: tx(), ledgerCurrency: 'USD'), isFalse);
    });
  });

  test('多维度取交集', () {
    const filter = TransactionSearchFilter(
      categoryId: 7,
      accountId: 3,
      tagIds: {5},
      hasAttachment: true,
      currencyCode: 'CNY',
    );
    expect(
      filter.matches(
        t: tx(categoryId: 7, accountId: 3, currencyCode: 'CNY'),
        category: category(id: 7),
        transactionTagIds: {5},
        hasTransactionAttachment: true,
      ),
      isTrue,
    );
    expect(
      filter.matches(
        t: tx(categoryId: 7, accountId: 3, currencyCode: 'CNY'),
        category: category(id: 7),
        transactionTagIds: {5},
        hasTransactionAttachment: false,
      ),
      isFalse,
    );
  });
}
