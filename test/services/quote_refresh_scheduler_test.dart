/// v52 行情刷新调度器的纯函数契约。
///
/// 重点：**默认关闭必须是硬保证** —— enabled 为 false 时不创建 Timer、
/// 不调用 onCheck，而不是靠调用方自觉不调 start()。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/services/investment/quote_refresh_scheduler.dart';

void main() {
  group('start() 默认关闭', () {
    test('enabled=false → 不启动（onCheck 永不被调用）', () async {
      var calls = 0;
      final scheduler = QuoteRefreshScheduler(
        enabled: false,
        onCheck: () async => calls++,
      );

      scheduler.start();
      scheduler.dispose();

      expect(calls, 0);
    });
  });

  group('shouldTriggerNow', () {
    final now = DateTime(2026, 10, 8, 15);

    test('未启用 → 永不触发（无论上次何时）', () {
      expect(
        shouldTriggerNow(
          enabled: false,
          lastFetchAt: null,
          minInterval: Duration.zero,
          now: now,
        ),
        isFalse,
      );
    });

    test('从未拉取过 → 允许触发（启动补拉）', () {
      expect(
        shouldTriggerNow(
          enabled: true,
          lastFetchAt: null,
          minInterval: const Duration(minutes: 15),
          now: now,
        ),
        isTrue,
      );
    });

    test('距上次不足最小间隔 → 不触发（节流）', () {
      expect(
        shouldTriggerNow(
          enabled: true,
          lastFetchAt: now.subtract(const Duration(minutes: 5)),
          minInterval: const Duration(minutes: 15),
          now: now,
        ),
        isFalse,
      );
    });

    test('距上次达到最小间隔 → 触发', () {
      expect(
        shouldTriggerNow(
          enabled: true,
          lastFetchAt: now.subtract(const Duration(minutes: 15)),
          minInterval: const Duration(minutes: 15),
          now: now,
        ),
        isTrue,
      );
    });

    test('时钟回拨（now 早于上次拉取）→ 不触发，防疯狂重试', () {
      expect(
        shouldTriggerNow(
          enabled: true,
          lastFetchAt: now.add(const Duration(hours: 2)),
          minInterval: Duration.zero,
          now: now,
        ),
        isFalse,
      );
    });
  });
}

/// 便于直接调用静态方法的别名（保持测试可读）
bool shouldTriggerNow({
  required bool enabled,
  required DateTime? lastFetchAt,
  required Duration minInterval,
  required DateTime now,
}) =>
    QuoteRefreshScheduler.shouldTriggerNow(
      enabled: enabled,
      lastFetchAt: lastFetchAt,
      minInterval: minInterval,
      now: now,
    );
