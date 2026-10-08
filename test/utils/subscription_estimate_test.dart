// 订阅视图的年化折算与汇总纯函数（见
// prd/subscription_and_overspend_alerts/requirements.md §4.1 的折算表）。

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/services/data/recurring_transaction_service.dart';
import 'package:piggycount/utils/subscription_estimate.dart';

void main() {
  RecurringTransaction template({
    String frequency = 'monthly',
    int interval = 1,
    double amount = 100,
    String? currencyCode,
    String? note,
    String type = 'expense',
  }) {
    return RecurringTransaction(
      id: 1,
      ledgerId: 1,
      type: type,
      amount: amount,
      note: note,
      frequency: frequency,
      interval: interval,
      startDate: DateTime(2026, 1, 1),
      enabled: true,
      currencyCode: currencyCode,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  SubscriptionItem item({
    String frequency = 'monthly',
    int interval = 1,
    double amount = 100,
    bool isForeign = false,
  }) {
    final t = template(
      frequency: frequency,
      interval: interval,
      amount: amount,
    );
    return SubscriptionItem(
      recurring: t,
      annualAmount: annualizedAmount(
        amount,
        RecurringFrequency.fromString(frequency),
        interval,
      ),
      isForeign: isForeign,
    );
  }

  group('occurrencesPerYear', () {
    test('四频率基准次数', () {
      expect(occurrencesPerYear(RecurringFrequency.daily, 1), 365);
      expect(occurrencesPerYear(RecurringFrequency.weekly, 1), 52);
      expect(occurrencesPerYear(RecurringFrequency.monthly, 1), 12);
      expect(occurrencesPerYear(RecurringFrequency.yearly, 1), 1);
    });

    test('间隔参与折算', () {
      expect(occurrencesPerYear(RecurringFrequency.monthly, 3), 4);
      expect(occurrencesPerYear(RecurringFrequency.weekly, 2), 26);
    });

    test('interval < 1 按 1 处理（脏数据兜底）', () {
      expect(occurrencesPerYear(RecurringFrequency.monthly, 0), 12);
      expect(occurrencesPerYear(RecurringFrequency.monthly, -5), 12);
    });
  });

  group('annualizedAmount', () {
    test('每月 100 → 年 1200', () {
      expect(
        annualizedAmount(100, RecurringFrequency.monthly, 1),
        1200,
      );
    });

    test('每 3 个月 100 → 年 400', () {
      expect(
        annualizedAmount(100, RecurringFrequency.monthly, 3),
        400,
      );
    });

    test('每年 100 → 年 100', () {
      expect(annualizedAmount(100, RecurringFrequency.yearly, 1), 100);
    });
  });

  group('summarizeSubscriptions', () {
    test('本位币项求和，月均 = 年 / 12', () {
      final summary = summarizeSubscriptions(
        items: [item(amount: 100), item(frequency: 'yearly', amount: 200)],
        baseCurrency: 'CNY',
      );
      expect(summary.count, 2);
      expect(summary.foreignCount, 0);
      expect(summary.annualAmount, 1400);
      expect(summary.monthlyAmount, closeTo(1400 / 12, 1e-9));
      expect(summary.currencyCode, 'CNY');
      expect(summary.hasForeign, isFalse);
    });

    test('外币项只计数、不计金额', () {
      final summary = summarizeSubscriptions(
        items: [
          item(amount: 100),
          item(amount: 999, isForeign: true),
        ],
        baseCurrency: 'CNY',
      );
      expect(summary.count, 2);
      expect(summary.foreignCount, 1);
      expect(summary.annualAmount, 1200, reason: '999 的外币项不得计入');
      expect(summary.hasForeign, isTrue);
    });

    test('空列表 → 全零，不出现 NaN（月均不除零放大）', () {
      final summary = summarizeSubscriptions(
        items: const [],
        baseCurrency: 'USD',
      );
      expect(summary.count, 0);
      expect(summary.annualAmount, 0);
      expect(summary.monthlyAmount, 0);
      expect(summary.currencyCode, 'USD');
    });

    test('金额为 0 的订阅仍计入条数', () {
      final summary = summarizeSubscriptions(
        items: [item(amount: 0)],
        baseCurrency: 'CNY',
      );
      expect(summary.count, 1);
      expect(summary.annualAmount, 0);
    });
  });

  group('SubscriptionItem.displayName', () {
    test('备注优先', () {
      final it = SubscriptionItem(
        recurring: template(note: '  视频会员  '),
        annualAmount: 1200,
        isForeign: false,
      );
      expect(it.displayName, '视频会员');
    });

    test('无备注 / 空白备注 → null（交给 UI 兜底分类名或通用文案）', () {
      expect(
        SubscriptionItem(
          recurring: template(),
          annualAmount: 1200,
          isForeign: false,
        ).displayName,
        isNull,
      );
      expect(
        SubscriptionItem(
          recurring: template(note: '   '),
          annualAmount: 1200,
          isForeign: false,
        ).displayName,
        isNull,
      );
    });
  });
}
