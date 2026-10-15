// sumOfSeries 特征测试（批次② b2-1）。
//
// 目标函数是 _getSumFromSeries（原 _AnalyticsPageState 方法）收编出的顶层
// 纯函数：按 day/month/year 三种 record 形状求 total 之和，未知形状返回 0。
// 本测试钉死搬迁前后的行为等价性——逻辑逐字搬迁期间这组用例不得变红。
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/pages/main/analytics_page.dart';

void main() {
  group('sumOfSeries', () {
    test('day 形状：逐项累加 total', () {
      final series = <({DateTime day, double total})>[
        (day: DateTime(2026, 10, 1), total: 1.5),
        (day: DateTime(2026, 10, 2), total: 2.25),
        (day: DateTime(2026, 10, 3), total: -0.75),
      ];
      expect(sumOfSeries(series), 3.0);
    });

    test('month 形状：逐项累加 total', () {
      final series = <({DateTime month, double total})>[
        (month: DateTime(2026, 8), total: 10),
        (month: DateTime(2026, 9), total: 20.5),
        (month: DateTime(2026, 10), total: -0.5),
      ];
      expect(sumOfSeries(series), 30.0);
    });

    test('year 形状：逐项累加 total', () {
      final series = <({int year, double total})>[
        (year: 2024, total: 100),
        (year: 2025, total: 200),
        (year: 2026, total: -50),
      ];
      expect(sumOfSeries(series), 250.0);
    });

    test('三种形状的空列表均返回 0', () {
      expect(sumOfSeries(<({DateTime day, double total})>[]), 0.0);
      expect(sumOfSeries(<({DateTime month, double total})>[]), 0.0);
      expect(sumOfSeries(<({int year, double total})>[]), 0.0);
    });

    test('未知形状返回 0（含裸空列表/非序列值）', () {
      expect(sumOfSeries(<dynamic>[]), 0.0);
      expect(sumOfSeries(<double>[1, 2, 3]), 0.0);
      expect(sumOfSeries('not-a-series'), 0.0);
      expect(sumOfSeries(null), 0.0);
    });
  });
}
