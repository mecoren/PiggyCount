import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/holding_metrics.dart';

/// 构造一条持仓计算输入（默认本位币场景：账户币种与持仓币种一致）。
HoldingValueInput _h({
  double quantity = 1,
  double unitCost = 0,
  double unitPrice = 0,
  double? quotePrice,
  bool useQuote = false,
  String currency = 'CNY',
}) =>
    HoldingValueInput(
      quantity: quantity,
      unitCost: unitCost,
      unitPrice: unitPrice,
      quotePrice: quotePrice,
      useQuote: useQuote,
      currency: currency,
    );

void main() {
  group('effectiveUnitPrice 生效价', () {
    test('行情不可用(未配置源 / 未开启 / 缓存过期)时回退手填净值', () {
      expect(
        effectiveUnitPrice(unitPrice: 12.5, quotePrice: 99, useQuote: false),
        12.5,
      );
    });

    test('行情可用且缓存非空时取行情价', () {
      expect(
        effectiveUnitPrice(unitPrice: 12.5, quotePrice: 13.0, useQuote: true),
        13.0,
      );
    });

    test('行情可用但缓存为空(从未拉到过)时回退手填净值', () {
      expect(
        effectiveUnitPrice(unitPrice: 12.5, quotePrice: null, useQuote: true),
        12.5,
      );
    });
  });

  group('isQuoteUsable 行情缓存可用性', () {
    final now = DateTime(2026, 10, 8, 12);

    test('无缓存价 → 不可用', () {
      expect(
        isQuoteUsable(quotePrice: null, quoteFetchedAt: now, now: now),
        isFalse,
      );
    });

    test('有价但无拉取时刻 → 不可用（不知道是否过期，宁可回退手填）', () {
      expect(
        isQuoteUsable(quotePrice: 1.0, quoteFetchedAt: null, now: now),
        isFalse,
      );
    });

    test('缓存过期（超过 maxAge）→ 不可用', () {
      expect(
        isQuoteUsable(
          quotePrice: 1.0,
          quoteFetchedAt: now.subtract(const Duration(hours: 25)),
          now: now,
        ),
        isFalse,
      );
    });

    test('缓存新鲜 → 可用', () {
      expect(
        isQuoteUsable(
          quotePrice: 1.0,
          quoteFetchedAt: now.subtract(const Duration(hours: 1)),
          now: now,
        ),
        isTrue,
      );
    });

    test('拉取时刻在将来（时钟回拨）→ 视为可用，不因负时长剔除', () {
      expect(
        isQuoteUsable(
          quotePrice: 1.0,
          quoteFetchedAt: now.add(const Duration(hours: 2)),
          now: now,
        ),
        isTrue,
      );
    });
  });

  group('市值 / 成本', () {
    test('市值 = 份额 × 生效净值（走行情价）', () {
      expect(
        holdingMarketValue(
          quantity: 100,
          unitPrice: 10,
          quotePrice: 12.5,
          useQuote: true,
        ),
        1250,
      );
    });

    test('市值 = 份额 × 手填净值（行情不可用）', () {
      expect(
        holdingMarketValue(
          quantity: 100,
          unitPrice: 10,
          quotePrice: 12.5,
          useQuote: false,
        ),
        1000,
      );
    });

    test('成本 = 份额 × 单位成本', () {
      expect(holdingCost(quantity: 100, unitCost: 8.5), 850);
    });
  });

  group('profitRate 成本收益率', () {
    test('成本为 0 返回 null（不做除零，UI 显示「—」）', () {
      expect(profitRate(marketValue: 100, cost: 0), isNull);
    });

    test('成本为负返回 null（不产出无意义的收益率）', () {
      expect(profitRate(marketValue: 100, cost: -10), isNull);
    });

    test('盈利 25%', () {
      expect(profitRate(marketValue: 1250, cost: 1000), closeTo(0.25, 1e-12));
    });

    test('亏损 20% 为负值', () {
      expect(profitRate(marketValue: 800, cost: 1000), closeTo(-0.2, 1e-12));
    });
  });

  group('crossRate 跨币种折算率', () {
    test('同币种恒为 1，且不需要任何汇率数据（大小写不敏感）', () {
      expect(crossRate(from: 'USD', to: 'usd', ratesToBase: const {}), 1.0);
    });

    test('源币种缺汇率 → null（绝不按 1.0 裸加）', () {
      expect(
        crossRate(from: 'USD', to: 'CNY', ratesToBase: const {'CNY': 1.0}),
        isNull,
      );
    });

    test('目标币种缺汇率 → null', () {
      expect(
        crossRate(from: 'USD', to: 'CNY', ratesToBase: const {'USD': 7.2}),
        isNull,
      );
    });

    test('目标汇率为 0 → null（不产出 Infinity）', () {
      expect(
        crossRate(
          from: 'USD',
          to: 'CNY',
          ratesToBase: const {'USD': 7.2, 'CNY': 0},
        ),
        isNull,
      );
    });

    test('正常按比值折算：1 USD = 7.2 CNY', () {
      expect(
        crossRate(
          from: 'USD',
          to: 'CNY',
          ratesToBase: const {'USD': 7.2, 'CNY': 1.0},
        ),
        closeTo(7.2, 1e-12),
      );
    });

    test('交叉折算（既非本位币的两个币种）', () {
      // 1 USD = 7.2 CNY，1 HKD = 0.92 CNY → 1 USD = 7.2/0.92 HKD
      expect(
        crossRate(
          from: 'USD',
          to: 'HKD',
          ratesToBase: const {'USD': 7.2, 'HKD': 0.92, 'CNY': 1.0},
        ),
        closeTo(7.2 / 0.92, 1e-12),
      );
    });
  });

  group('summarizeHoldings 汇总', () {
    test('空持仓 → 全零、收益率 null、无剔除', () {
      final result = summarizeHoldings(
        holdings: const [],
        accountCurrency: 'CNY',
        ratesToBase: const {},
      );

      expect(result.marketValue, 0);
      expect(result.cost, 0);
      expect(result.profit, 0);
      expect(result.profitRate, isNull);
      expect(result.total, 0);
      expect(result.excluded, 0);
      expect(result.hasExcluded, isFalse);
    });

    test('持仓币种等于账户币种时无需任何汇率数据也能汇总', () {
      final result = summarizeHoldings(
        holdings: [
          _h(quantity: 100, unitCost: 8, unitPrice: 10),
          _h(quantity: 50, unitCost: 12, unitPrice: 9),
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {},
      );

      // 市值 1000 + 450；成本 800 + 600
      expect(result.marketValue, closeTo(1450, 1e-9));
      expect(result.cost, closeTo(1400, 1e-9));
      expect(result.profit, closeTo(50, 1e-9));
      expect(result.total, 2);
      expect(result.excluded, 0);
    });

    test('跨币种持仓折算进账户币种', () {
      final result = summarizeHoldings(
        holdings: [
          // 100 股 × 10 USD = 1000 USD → 7200 CNY
          _h(quantity: 100, unitCost: 6, unitPrice: 10, currency: 'USD'),
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {'USD': 7.2, 'CNY': 1.0},
      );

      expect(result.marketValue, closeTo(7200, 1e-9));
      expect(result.cost, closeTo(100 * 6 * 7.2, 1e-9));
      expect(result.excluded, 0);
    });

    test('缺汇率的持仓整条剔除并计数透出（其余持仓照常计入）', () {
      final result = summarizeHoldings(
        holdings: [
          _h(quantity: 100, unitCost: 8, unitPrice: 10), // CNY，可计入
          _h(quantity: 10, unitCost: 1, unitPrice: 1, currency: 'JPY'), // 缺汇率
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {'CNY': 1.0},
      );

      expect(result.marketValue, closeTo(1000, 1e-9));
      expect(result.cost, closeTo(800, 1e-9));
      expect(result.total, 2);
      expect(result.excluded, 1);
      expect(result.hasExcluded, isTrue);
    });

    test('全部持仓都缺汇率 → 汇总为零且全部计数为剔除', () {
      final result = summarizeHoldings(
        holdings: [
          _h(quantity: 10, unitCost: 1, unitPrice: 2, currency: 'JPY'),
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {},
      );

      expect(result.marketValue, 0);
      expect(result.cost, 0);
      expect(result.profitRate, isNull);
      expect(result.total, 1);
      expect(result.excluded, 1);
    });

    test('收益率按折算后的市值/成本计算（汇率对分子分母同倍，不改变收益率）', () {
      final result = summarizeHoldings(
        holdings: [
          // 成本 100 USD × 7.2 = 720 CNY；市值 110 USD × 7.2 = 792 CNY
          _h(quantity: 10, unitCost: 10, unitPrice: 11, currency: 'USD'),
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {'USD': 7.2, 'CNY': 1.0},
      );

      expect(result.cost, closeTo(720, 1e-9));
      expect(result.marketValue, closeTo(792, 1e-9));
      expect(result.profit, closeTo(72, 1e-9));
      expect(result.profitRate, closeTo(0.1, 1e-12));
    });

    test('走行情价的持仓汇总用行情市值、成本仍用单位成本', () {
      final result = summarizeHoldings(
        holdings: [
          _h(
            quantity: 100,
            unitCost: 8,
            unitPrice: 10,
            quotePrice: 12,
            useQuote: true,
          ),
        ],
        accountCurrency: 'CNY',
        ratesToBase: const {},
      );

      expect(result.marketValue, closeTo(1200, 1e-9));
      expect(result.cost, closeTo(800, 1e-9));
      expect(result.profit, closeTo(400, 1e-9));
      expect(result.profitRate, closeTo(0.5, 1e-12));
    });
  });
}
