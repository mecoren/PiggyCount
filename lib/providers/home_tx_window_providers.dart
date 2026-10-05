import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/repositories/transaction_repository.dart'
    show kTransactionWindowSize;
import 'database_providers.dart';

/// 首页交易窗口的当前页大小（M2-a）。
///
/// 首页原本把**整本账本**拉进内存（`watchTransactionsWithCategoryAll` 无 LIMIT）。
/// 窗口化后只加载最新 N 行，滚到接近底部再 `+= kTransactionWindowSize`：
/// - `limit` **只增不减** → 已显示的行永远不会被挤出窗口，
///   日分组器的"删除检测"因此不受影响（它只在行消失时才误判）；
/// - `limit` 变化 → `home_page` 里的 `_txStream` 换引用 → 用一个新查询重订阅
///   （`ORDER BY happened_at DESC, id DESC LIMIT n`），行集连同顺序一次给全。
final homeTxWindowLimitProvider =
    StateProvider.family<int, int>((ref, ledgerId) => kTransactionWindowSize);

/// 把窗口 `limit` 调大一页（滚动到底 / 月份跳转未命中时调用）。
///
/// 收在这里而不是让调用方自己 + 页大小：页大小常量只应有一个来源。
void growHomeTxWindow(WidgetRef ref, int ledgerId) {
  ref.read(homeTxWindowLimitProvider(ledgerId).notifier).state +=
      kTransactionWindowSize;
}

/// 首页日合计（口径见 `TransactionRepository.getDailyTotalsInRange`）。
///
/// 用 **family key = (ledgerId, 已加载窗口最旧的一天)** 而不是依赖窗口流本身：
/// 那样会让整窗行被 provider 再持有一次（内存翻倍，正好抵消窗口化的收益）。
/// 调用方本就有行列表，顺手把最旧一天算出来当 key 即可；同一天内增删不改 key，
/// 不重复取数。
final homeDayTotalsProvider = FutureProvider.family<
    Map<String, (double, double)>,
    ({int ledgerId, DateTime oldestDay})>((ref, key) async {
  final now = DateTime.now();
  // 半开区间 [最旧一天 00:00, 明天 00:00)：覆盖窗口内所有天（含今天更晚的行）。
  final end = DateTime(now.year, now.month, now.day)
      .add(const Duration(days: 1));
  return ref.watch(repositoryProvider).getDailyTotalsInRange(
        ledgerId: key.ledgerId,
        start: key.oldestDay,
        end: end,
      );
});
