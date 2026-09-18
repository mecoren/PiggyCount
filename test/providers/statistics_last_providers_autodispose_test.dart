/// E2 回归测试:`lastCountsAllProvider` 与 `lastMonthlyTotalsProvider` 必须
/// 是 `.autoDispose`。否则首页/统计页切走后,这两个 StateProvider 仍持有
/// 上一次的聚合结果(可能很大),且 family 实例永不释放,导致内存随访问
/// 账本/月份累积增长。
///
/// 验证方式:autoDispose StateProvider 在所有监听者断开后会重置为默认值
/// (null)。普通 StateProvider 则会保留上一次写入的值。
library;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/providers/statistics_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('lastCountsAllProvider:autoDispose,无监听者后重置为 null', () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    // 订阅并写入非默认值
    final sub = container.listen(lastCountsAllProvider, (_, __) {});
    container.read(lastCountsAllProvider.notifier).state =
        (dayCount: 10, txCount: 99);
    expect(container.read(lastCountsAllProvider), (dayCount: 10, txCount: 99));

    // 断开所有监听者,触发 autoDispose 回收
    sub.close();

    // 让 autoDispose 的 dispose 任务跑完
    await Future<void>.delayed(Duration.zero);

    // 再次读取:应回到默认值 null(若非 autoDispose,会保留 (10, 99))
    expect(container.read(lastCountsAllProvider), isNull,
        reason: 'lastCountsAllProvider 应为 autoDispose,无监听者后必须重置');
  });

  test('lastMonthlyTotalsProvider:autoDispose family,无监听者后重置为 null',
      () async {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final key = (ledgerId: 1, month: DateTime(2026, 7));
    final sub = container.listen(lastMonthlyTotalsProvider(key), (_, __) {});
    container.read(lastMonthlyTotalsProvider(key).notifier).state =
        (1000.0, 500.0);
    expect(container.read(lastMonthlyTotalsProvider(key)), (1000.0, 500.0));

    sub.close();
    await Future<void>.delayed(Duration.zero);

    expect(container.read(lastMonthlyTotalsProvider(key)), isNull,
        reason: 'lastMonthlyTotalsProvider 应为 autoDispose family,'
            '无监听者后必须重置');
  });
}
