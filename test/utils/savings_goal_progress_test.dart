// 储蓄目标进度解算（纯函数）的边界回归。
// 口径见 prd/savings_goal/requirements.md §4.2。

import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/utils/savings_goal_progress.dart';

void main() {
  final start = DateTime(2026, 1, 1);
  final now = DateTime(2026, 1, 11); // 起算满 10 天

  group('computeSavingsGoalProgress', () {
    test('基本进度：目标 10000 已存 2500 → 25% / 剩余 7500', () {
      final p = computeSavingsGoalProgress(
        saved: 2500,
        targetAmount: 10000,
        startDate: start,
        now: now,
      );
      expect(p.saved, 2500);
      expect(p.target, 10000);
      expect(p.rate, closeTo(0.25, 1e-9));
      expect(p.remaining, 7500);
      expect(p.achieved, isFalse);
    });

    test('已超额：目标 10000 已存 12000 → rate clamp 到 1、达成、剩余 0', () {
      final p = computeSavingsGoalProgress(
        saved: 12000,
        targetAmount: 10000,
        startDate: start,
        now: now,
      );
      expect(p.rate, 1.0, reason: 'rate 只服务进度条宽度，必须 clamp');
      expect(p.saved, 12000, reason: '已存文本不得被 target 反推截断');
      expect(p.achieved, isTrue);
      expect(p.remaining, 0);
    });

    test('脏数据：目标 ≤ 0 → 进度 0、不判达成、不出现 NaN', () {
      for (final target in <double>[0, -100]) {
        final p = computeSavingsGoalProgress(
          saved: 500,
          targetAmount: target,
          startDate: start,
          now: now,
        );
        expect(p.rate, 0);
        expect(p.achieved, isFalse);
        expect(p.rate.isNaN, isFalse);
      }
    });

    test('账户透支（saved < 0）→ 进度 0、剩余 = 目标', () {
      final p = computeSavingsGoalProgress(
        saved: -300,
        targetAmount: 1000,
        startDate: start,
        now: now,
      );
      expect(p.rate, 0);
      expect(p.remaining, 1000);
      expect(p.achieved, isFalse);
    });

    test('速度估算：10 天存 1000、目标 2000 → 日均 100、还需 10 天', () {
      final p = computeSavingsGoalProgress(
        saved: 1000,
        targetAmount: 2000,
        startDate: start,
        now: now,
      );
      expect(p.dailyRate, closeTo(100, 1e-9));
      expect(p.estimatedDays, 10);
      expect(p.estimatedDate, DateTime(2026, 1, 21));
    });

    test('已达成 → 不给预计日（remaining 为 0）', () {
      final p = computeSavingsGoalProgress(
        saved: 2000,
        targetAmount: 2000,
        startDate: start,
        now: now,
      );
      expect(p.estimatedDays, isNull);
      expect(p.estimatedDate, isNull);
    });

    test('未起步（saved = 0）→ 无法估算速度', () {
      final p = computeSavingsGoalProgress(
        saved: 0,
        targetAmount: 1000,
        startDate: start,
        now: now,
      );
      expect(p.dailyRate, isNull);
      expect(p.estimatedDays, isNull);
    });

    test('起算日落在未来（脏数据 / 时区回拨）→ 按 1 天兜底，不放大速度', () {
      final p = computeSavingsGoalProgress(
        saved: 100,
        targetAmount: 1000,
        startDate: DateTime(2026, 2, 1),
        now: now,
      );
      expect(p.dailyRate, closeTo(100, 1e-9), reason: '100 / 1 天，而不是负天数');
    });

    test('同日创建（起算天数为 0）→ 按 1 天兜底', () {
      final p = computeSavingsGoalProgress(
        saved: 50,
        targetAmount: 100,
        startDate: now,
        now: now,
      );
      expect(p.dailyRate, closeTo(50, 1e-9));
    });
  });

  group('summarizeSavingsGoals', () {
    test('只汇总本位币（大小写不敏感），外币只计数', () {
      final s = summarizeSavingsGoals(
        [
          (target: 10000.0, saved: 2500.0, currency: 'CNY', accountId: null),
          (target: 5000.0, saved: 1000.0, currency: 'cny', accountId: null),
          (target: 1000.0, saved: 200.0, currency: 'USD', accountId: null),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalCount, 3);
      expect(s.foreignCount, 1);
      expect(s.totalTarget, 15000);
      expect(s.totalSaved, 3500);
    });

    test('空列表 → 全零，不出现 NaN', () {
      final s = summarizeSavingsGoals(const [], ledgerCurrency: 'CNY');
      expect(s.totalCount, 0);
      expect(s.foreignCount, 0);
      expect(s.totalTarget, 0);
      expect(s.totalSaved, 0);
    });

    test('全部为外币 → 合计为 0 且全部计数', () {
      final s = summarizeSavingsGoals(
        [
          (target: 100.0, saved: 10.0, currency: 'USD', accountId: null),
          (target: 200.0, saved: 20.0, currency: 'JPY', accountId: null),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalCount, 2);
      expect(s.foreignCount, 2);
      expect(s.totalTarget, 0);
      expect(s.totalSaved, 0);
    });

    test('同一账户的多个目标：总已存只计一次余额，目标额仍逐项累加', () {
      // 现实场景：账户余额 12.37 万，两个目标都挂在它上面。
      // 修前逐项相加 → 24.73 万（余额的 2 倍，虚高）。
      final s = summarizeSavingsGoals(
        [
          (target: 1000.0, saved: 123700.0, currency: 'CNY', accountId: 7),
          (target: 2000.0, saved: 123700.0, currency: 'CNY', accountId: 7),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalTarget, 3000);
      expect(s.totalSaved, 123700);
    });

    test('不同账户各自计入（去重只针对同一账户）', () {
      final s = summarizeSavingsGoals(
        [
          (target: 1000.0, saved: 500.0, currency: 'CNY', accountId: 7),
          (target: 1000.0, saved: 300.0, currency: 'CNY', accountId: 8),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalTarget, 2000);
      expect(s.totalSaved, 800);
    });

    test('手动模式（accountId 为空）逐项累加：那是各自独立的累计额', () {
      final s = summarizeSavingsGoals(
        [
          (target: 1000.0, saved: 200.0, currency: 'CNY', accountId: null),
          (target: 1000.0, saved: 300.0, currency: 'CNY', accountId: null),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalTarget, 2000);
      expect(s.totalSaved, 500);
    });

    test('账户模式与手动模式混合：手动项照常计入，不动账户去重', () {
      final s = summarizeSavingsGoals(
        [
          (target: 1000.0, saved: 800.0, currency: 'CNY', accountId: 7),
          (target: 1000.0, saved: 800.0, currency: 'CNY', accountId: 7),
          (target: 1000.0, saved: 150.0, currency: 'CNY', accountId: null),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.totalTarget, 3000);
      expect(s.totalSaved, 950);
    });

    test('外币目标同样按账户去重前就被排除（只计数）', () {
      final s = summarizeSavingsGoals(
        [
          (target: 1000.0, saved: 100.0, currency: 'USD', accountId: 7),
          (target: 2000.0, saved: 400.0, currency: 'USD', accountId: 7),
        ],
        ledgerCurrency: 'CNY',
      );
      expect(s.foreignCount, 2);
      expect(s.totalTarget, 0);
      expect(s.totalSaved, 0);
    });
  });
}
