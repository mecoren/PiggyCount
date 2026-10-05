/// M2-a 首页窗口 provider 契约：
/// - 窗口 limit 按账本隔离、每次增长一页；
/// - 日合计取数区间 = `[已加载窗口最旧一天 00:00, 明天 00:00)`，并把 SQL 结果透传。
///
/// 注：列表子项在 widget 测试环境不渲染（flutter_list_view 的既有约束，见
/// `transaction_list_incremental_test.dart` 头注释），所以这里不测"表头数字"，
/// 只测 provider 层的取值与区间。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/data/repositories/transaction_repository.dart'
    show kTransactionWindowSize;
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/home_tx_window_providers.dart';

/// 只实现被测方法，其余走 noSuchMethod（与既有 test fakes 同款）。
class _FakeRepo implements BaseRepository {
  ({int ledgerId, DateTime start, DateTime end})? lastCall;

  @override
  Future<Map<String, (double, double)>> getDailyTotalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    lastCall = (ledgerId: ledgerId, start: start, end: end);
    return {'2026-06-02': (1.0, 2.0)};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('growHomeTxWindow 把该账本的 limit 调大一页，且按账本隔离',
      (tester) async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    WidgetRef? captured;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: Consumer(builder: (ctx, ref, _) {
          captured = ref;
          return const SizedBox.shrink();
        }),
      ),
    ));

    expect(container.read(homeTxWindowLimitProvider(3)), kTransactionWindowSize);

    growHomeTxWindow(captured!, 3);
    expect(container.read(homeTxWindowLimitProvider(3)),
        kTransactionWindowSize * 2, reason: '滚动到底应增长一页');
    growHomeTxWindow(captured!, 3);
    expect(container.read(homeTxWindowLimitProvider(3)),
        kTransactionWindowSize * 3);

    expect(container.read(homeTxWindowLimitProvider(4)), kTransactionWindowSize,
        reason: '另一个账本必须从首页大小重新开始');
  });

  test('homeDayTotalsProvider：区间 [最旧一天, 明天) 且透传 SQL 结果', () async {
    final fake = _FakeRepo();
    final container = ProviderContainer(overrides: [
      repositoryProvider.overrideWithValue(fake),
    ]);
    addTearDown(container.dispose);

    final map = await container.read(homeDayTotalsProvider((
      ledgerId: 7,
      oldestDay: DateTime(2026, 6, 2),
    )).future);

    expect(map, {'2026-06-02': (1.0, 2.0)});
    expect(fake.lastCall!.ledgerId, 7);
    expect(fake.lastCall!.start, DateTime(2026, 6, 2),
        reason: '起点取最旧一天 00:00');
    final now = DateTime.now();
    expect(fake.lastCall!.end,
        DateTime(now.year, now.month, now.day).add(const Duration(days: 1)),
        reason: '半开区间上界 = 明天 00:00（覆盖今天更晚的行）');
  });
}
