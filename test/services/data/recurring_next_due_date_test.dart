// nextDueDateAfter：到期提醒依赖的「下一次发生日」纯函数。
//
// 与 calculateNextDate 的分工（见 prd/subscription_and_overspend_alerts/design.md §2）：
//   calculateNextDate → 「本次是否需要生成」（未来一律 null）
//   nextDueDateAfter  → 「下一笔什么时候发生」（严格晚于 now）
// 两者必须同源，本文件锁定 nextDueDateAfter 的口径；calculateNextDate 的既有
// 口径由 test/services/data/recurring_transaction_service_test.dart 锁定。

import 'package:drift/drift.dart' as d;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/services/data/recurring_transaction_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // nextDueDateAfter 的告警分支会走 logger（内部读 SharedPreferences）
    SharedPreferences.setMockInitialValues({});
  });

  // repository 传 null：被测函数是纯函数，不触碰仓储
  final service = RecurringTransactionService(null);

  RecurringTransaction template({
    required String frequency,
    int interval = 1,
    int? dayOfMonth,
    int? monthOfYear,
    required DateTime startDate,
    DateTime? endDate,
    DateTime? lastGeneratedDate,
    String type = 'expense',
  }) {
    return RecurringTransaction(
      id: 1,
      ledgerId: 1,
      type: type,
      amount: 100,
      frequency: frequency,
      interval: interval,
      dayOfMonth: dayOfMonth,
      monthOfYear: monthOfYear,
      startDate: startDate,
      endDate: endDate,
      lastGeneratedDate: lastGeneratedDate,
      enabled: true,
      createdAt: DateTime(2026, 1, 1),
      updatedAt: DateTime(2026, 1, 1),
    );
  }

  group('daily / weekly', () {
    test('daily：当天已生成 → 返回明天', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'daily',
          startDate: DateTime(2026, 1, 1),
          lastGeneratedDate: DateTime(2026, 10, 8),
        ),
        now: DateTime(2026, 10, 8, 12),
      );
      expect(due, DateTime(2026, 10, 9));
    });

    test('daily interval=3 → 上次生成日 + 3 天', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'daily',
          interval: 3,
          startDate: DateTime(2026, 1, 1),
          lastGeneratedDate: DateTime(2026, 10, 8),
        ),
        now: DateTime(2026, 10, 8, 12),
      );
      expect(due, DateTime(2026, 10, 11));
    });

    test('weekly interval=1：跳过已过的发生日', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'weekly',
          startDate: DateTime(2026, 10, 1),
          lastGeneratedDate: DateTime(2026, 10, 1),
        ),
        now: DateTime(2026, 10, 8, 12),
      );
      expect(due, DateTime(2026, 10, 15));
    });

    test('weekly interval=2 → 上次生成日 + 14 天', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'weekly',
          interval: 2,
          startDate: DateTime(2026, 10, 1),
          lastGeneratedDate: DateTime(2026, 10, 1),
        ),
        now: DateTime(2026, 10, 8, 12),
      );
      expect(due, DateTime(2026, 10, 15));
    });
  });

  group('monthly', () {
    test('目标日在本月且未过 → 取本月', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 10,
          startDate: DateTime(2026, 1, 10),
          lastGeneratedDate: DateTime(2026, 9, 10),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 10, 10));
    });

    test('目标日在本月已过 → 推到下月', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 5,
          startDate: DateTime(2026, 1, 5),
          lastGeneratedDate: DateTime(2026, 9, 5),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 11, 5));
    });

    test('interval=3 → 上次生成日 + 3 个月', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          interval: 3,
          dayOfMonth: 1,
          startDate: DateTime(2026, 1, 1),
          lastGeneratedDate: DateTime(2026, 7, 1),
        ),
        now: DateTime(2026, 9, 30),
      );
      expect(due, DateTime(2026, 10, 1));
    });

    test('月底不塌陷：1/31 → 2/28 → 3/31', () {
      final toFeb = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 31,
          startDate: DateTime(2026, 1, 31),
          lastGeneratedDate: DateTime(2026, 1, 31),
        ),
        now: DateTime(2026, 2, 1),
      );
      expect(toFeb, DateTime(2026, 2, 28), reason: '2026 非闰年，2 月夹到 28');

      final toMar = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 31,
          startDate: DateTime(2026, 1, 31),
          lastGeneratedDate: DateTime(2026, 2, 28),
        ),
        now: DateTime(2026, 2, 28, 12),
      );
      expect(toMar, DateTime(2026, 3, 31), reason: '目标日固定为 31，不得塌陷成 28');
    });

    test('首笔未生成 + 开始日在未来 → 取开始日', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 15,
          startDate: DateTime(2026, 12, 15),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 12, 15));
    });

    test('首笔未生成 + 开始日在过去 → 不回溯，取本月目标日', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 10,
          startDate: DateTime(2026, 1, 10),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 10, 10));
    });

    test('首笔未生成 + 开始日在过去 + 本月目标日已过 → 顺延一个月', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 5,
          startDate: DateTime(2026, 1, 5),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 11, 5));
    });
  });

  group('yearly', () {
    test('固定 monthOfYear/dayOfMonth，推进 interval 年', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'yearly',
          interval: 2,
          monthOfYear: 6,
          dayOfMonth: 1,
          startDate: DateTime(2024, 6, 1),
          lastGeneratedDate: DateTime(2026, 6, 1),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2028, 6, 1));
    });

    test('闰年 2/29 → 平年夹到 2/28', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'yearly',
          monthOfYear: 2,
          dayOfMonth: 29,
          startDate: DateTime(2024, 2, 29),
          lastGeneratedDate: DateTime(2024, 2, 29),
        ),
        now: DateTime(2024, 3, 1),
      );
      expect(due, DateTime(2025, 2, 28));
    });

    test('首笔未生成 + 开始日在过去 → 今年目标日', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'yearly',
          monthOfYear: 12,
          dayOfMonth: 20,
          startDate: DateTime(2020, 12, 20),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, DateTime(2026, 12, 20));
    });
  });

  // ==========================================================================
  // 「同源」交叉断言：nextDueDateAfter 必须等于生成逻辑（calculateNextDate）
  // 推进序列中第一个 > now 的项 —— 否则「提前 3 天提醒」会与实际扣款日错位。
  //
  // 手法：把 calculateNextDate 的 now 推到极远，它就会无条件返回下一个候选
  // （它的语义是「nextDate <= now 才返回」，now 极大即恒真），于是可以逐项
  // 展开生成序列。前提是模板**已生成过**（lastGeneratedDate != null），否则
  // 首笔会走「基准不早于今天零点」的钳制，被极远的 now 污染。
  // ==========================================================================
  group('与 calculateNextDate 同源（提醒日 == 实际扣款日）', () {
    List<DateTime> generationSequence(RecurringTransaction seed,
        {int steps = 4}) {
      final out = <DateTime>[];
      var current = seed;
      for (var i = 0; i < steps; i++) {
        final next = service.calculateNextDate(current, now: DateTime(9000));
        if (next == null) break;
        out.add(next);
        current = current.copyWith(lastGeneratedDate: d.Value(next));
      }
      return out;
    }

    test('monthly 改过目标日：跟生成逻辑走 baseDate+interval，不得提前到本月目标日', () {
      // 用户把「每月 15 号」改成「每月 25 号」，而 1 月 15 号已经生成过：
      // 生成逻辑的下一笔是 2/25；若按「本月 25 号」算就会报出 1/25（错）。
      final seed = template(
        frequency: 'monthly',
        dayOfMonth: 25,
        startDate: DateTime(2025, 1, 15),
        lastGeneratedDate: DateTime(2026, 1, 15),
      );
      final now = DateTime(2026, 1, 20);

      final expected =
          generationSequence(seed).firstWhere((d) => d.isAfter(now));
      expect(expected, DateTime(2026, 2, 25));
      expect(service.nextDueDateAfter(seed, now: now), expected);
    });

    test('monthly 常规：序列首项即下次扣款日', () {
      final seed = template(
        frequency: 'monthly',
        dayOfMonth: 10,
        startDate: DateTime(2025, 1, 10),
        lastGeneratedDate: DateTime(2026, 9, 10),
      );
      final now = DateTime(2026, 10, 8);

      final expected =
          generationSequence(seed).firstWhere((d) => d.isAfter(now));
      expect(expected, DateTime(2026, 10, 10));
      expect(service.nextDueDateAfter(seed, now: now), expected);
    });

    test('yearly 改过 monthOfYear/dayOfMonth 同样同源', () {
      final seed = template(
        frequency: 'yearly',
        monthOfYear: 12,
        dayOfMonth: 20,
        startDate: DateTime(2020, 6, 1),
        lastGeneratedDate: DateTime(2026, 6, 1),
      );
      final now = DateTime(2026, 10, 8);

      final expected =
          generationSequence(seed).firstWhere((d) => d.isAfter(now));
      expect(expected, DateTime(2027, 12, 20));
      expect(service.nextDueDateAfter(seed, now: now), expected);
    });

    test('daily / weekly 同源', () {
      final seeds = [
        template(
          frequency: 'daily',
          startDate: DateTime(2026, 1, 1),
          lastGeneratedDate: DateTime(2026, 10, 8),
        ),
        template(
          frequency: 'weekly',
          interval: 2,
          startDate: DateTime(2026, 1, 1),
          lastGeneratedDate: DateTime(2026, 10, 1),
        ),
      ];
      final now = DateTime(2026, 10, 8, 12);

      for (final seed in seeds) {
        final expected =
            generationSequence(seed).firstWhere((d) => d.isAfter(now));
        expect(
          service.nextDueDateAfter(seed, now: now),
          expected,
          reason: '${seed.frequency}(interval=${seed.interval}) 与生成逻辑不同源',
        );
      }
    });
  });

  group('边界与防御', () {
    test('endDate 已过 → null', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 10,
          startDate: DateTime(2026, 1, 10),
          lastGeneratedDate: DateTime(2026, 9, 10),
          endDate: DateTime(2026, 10, 1),
        ),
        now: DateTime(2026, 10, 8),
      );
      expect(due, isNull);
    });

    test('算出的发生日超过 endDate → null', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 10,
          startDate: DateTime(2026, 1, 10),
          lastGeneratedDate: DateTime(2026, 9, 10),
          endDate: DateTime(2026, 10, 5),
        ),
        now: DateTime(2026, 10, 4),
      );
      expect(due, isNull);
    });

    test('endDate 恰为下一次发生日 → 仍然返回该日', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'monthly',
          dayOfMonth: 10,
          startDate: DateTime(2026, 1, 10),
          lastGeneratedDate: DateTime(2026, 9, 10),
          endDate: DateTime(2026, 10, 10),
        ),
        now: DateTime(2026, 10, 4),
      );
      expect(due, DateTime(2026, 10, 10));
    });

    test('interval=0 按 1 处理，不死循环', () {
      final due = service.nextDueDateAfter(
        template(
          frequency: 'daily',
          interval: 0,
          startDate: DateTime(2026, 10, 1),
          lastGeneratedDate: DateTime(2026, 10, 8),
        ),
        now: DateTime(2026, 10, 8, 12),
      );
      expect(due, DateTime(2026, 10, 9));
    });
  });
}
