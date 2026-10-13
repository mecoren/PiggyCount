/// 持仓代码 → 市场 / 资产类别 / 币种 的推断契约。
///
/// 锁死各市场的特征前缀规则，以及「其余 6 位数字归入场外基金」的兜底口径
/// （用户明确要求「场外基金也要有推断方法」）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/utils/holding_code_inference.dart';

void main() {
  HoldingCodeGuess g(String code) => guessHoldingFromCode(code);

  group('上交所', () {
    test('股票：600/601/603/605/688/9', () {
      for (final c in ['600519', '601318', '603259', '605499', '688981', '900901']) {
        expect(g(c).market, 'SH', reason: c);
        expect(g(c).assetClass, 'stock', reason: c);
        expect(g(c).currency, 'CNY', reason: c);
      }
    });

    test('ETF/基金：510~518 / 560~563 / 588', () {
      for (final c in ['510300', '511010', '512880', '513100', '518880', '588000']) {
        expect(g(c).market, 'SH', reason: c);
        expect(g(c).assetClass, 'fund', reason: c);
      }
    });

    test('可转债：110/111/113', () {
      for (final c in ['110038', '113050']) {
        expect(g(c).market, 'SH', reason: c);
        expect(g(c).assetClass, 'bond', reason: c);
      }
    });
  });

  group('深交所', () {
    test('股票：000/001/002/003/300/301', () {
      for (final c in ['000001', '001979', '002594', '003816', '300750', '301236']) {
        expect(g(c).market, 'SZ', reason: c);
        expect(g(c).assetClass, 'stock', reason: c);
        expect(g(c).currency, 'CNY', reason: c);
      }
    });

    test('ETF/LOF：159 / 15x / 16x / 18x', () {
      for (final c in ['159361', '159915', '150019', '161725', '184801']) {
        expect(g(c).market, 'SZ', reason: c);
        expect(g(c).assetClass, 'fund', reason: c);
      }
    });

    test('可转债：123/127/128', () {
      for (final c in ['123456', '127045', '128145']) {
        expect(g(c).market, 'SZ', reason: c);
        expect(g(c).assetClass, 'bond', reason: c);
      }
    });
  });

  group('港股 / 美股 / 加密', () {
    test('1~5 位数字 → 港股', () {
      for (final c in ['700', '00700', '09988', '5']) {
        expect(g(c).market, 'HK', reason: c);
        expect(g(c).assetClass, 'stock', reason: c);
        expect(g(c).currency, 'HKD', reason: c);
      }
    });

    test('字母 ticker → 美股', () {
      for (final c in ['AAPL', 'tsla', 'MSFT']) {
        expect(g(c).market, 'US', reason: c);
        expect(g(c).assetClass, 'stock', reason: c);
        expect(g(c).currency, 'USD', reason: c);
      }
    });

    test('主流加密符号 → 数字货币', () {
      for (final c in ['BTC', 'eth', 'SOL']) {
        expect(g(c).market, 'CRYPTO', reason: c);
        expect(g(c).assetClass, 'crypto', reason: c);
        expect(g(c).currency, 'USD', reason: c);
      }
    });
  });

  group('场外基金兜底（无交易所特征前缀的 6 位数字）', () {
    test('004/007/519/2 段 → FUND / fund / CNY', () {
      for (final c in ['004123', '007301', '519702', '200001', '320007']) {
        expect(g(c).market, 'FUND', reason: c);
        expect(g(c).assetClass, 'fund', reason: c);
        expect(g(c).currency, 'CNY', reason: c);
      }
    });
  });

  group('无法推断 → 不改动', () {
    test('空串 / 非数字字母 / 位数不合法', () {
      for (final c in ['', '   ', '1234567', '---']) {
        expect(g(c).isEmpty, isTrue, reason: '"$c"');
        expect(g(c).market, isNull, reason: '"$c"');
      }
    });

    test('前后空白 / 含分隔符的代码也能识别（只取数字段）', () {
      expect(g(' 600519 ').market, 'SH');
      expect(g('159361').market, 'SZ');
    });
  });
}
