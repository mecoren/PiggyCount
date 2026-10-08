import 'dart:async';

import 'package:drift/drift.dart' as d;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/db.dart';
import '../data/repositories/local/local_repository.dart';
import '../services/system/logger_service.dart';
import '../utils/holding_metrics.dart';
import 'currency_providers.dart';
import 'database_providers.dart';
import 'statistics_providers.dart';

/// 投资持仓相关 Provider（v52）。
///
/// 分层：UI → Provider → Repository。持仓的**金额口径**（生效价、多币种折算、
/// 缺汇率剔除）全部在 `LocalAccountRepository` + `lib/utils/holding_metrics.dart`
/// 内闭合，Provider 只负责装配与刷新信号 —— 不要在 Provider 里重算金额，
/// 否则「账户页总额」与「持仓页合计」会漂成两个口径。

/// 某账户下的持仓（Stream：写库后列表自动刷新）。
final holdingsByAccountProvider =
    StreamProvider.family<List<Holding>, int>((ref, accountId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchHoldingsByAccount(accountId);
});

/// 某账户的持仓折算汇总（市值 / 成本 / 收益率 / 缺汇率剔除笔数）。
///
/// 依赖三个刷新信号：
/// - [holdingsByAccountProvider]：增删改持仓后重算；
/// - [effectiveRatesProvider]：汇率变化后跨币种持仓的折算值要跟着变；
/// - [holdingsRateBridgeProvider]：确保 Repository 已拿到汇率解析器。
final accountHoldingsSummaryProvider =
    FutureProvider.family<HoldingsValueSummary, int>((ref, accountId) async {
  ref.watch(holdingsByAccountProvider(accountId));
  ref.watch(effectiveRatesProvider);
  ref.watch(holdingsRateBridgeProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.getHoldingsSummaryForAccount(accountId);
});

/// 持仓表变更 → 刷新全局统计 tick（`statsRefreshProvider`）。
///
/// 为什么必须有无条件常驻的这一条：持仓的任何写都会改变账户金额
/// （用户新增/编辑/删除、删除账户级联、**行情缓存写入**），而净资产卡 /
/// 资产构成 / 净值趋势全都挂在 `statsRefreshProvider` 上；不 bump 就会出现
/// 「持仓页是新的、净资产卡还是旧的」。
///
/// 与 `lib/providers/sync_providers.dart` 里 transactions 表那条兜底同源 ——
/// 但那条挂在 `syncServiceProvider` 内部、**仅云模式生效**；持仓这条必须
/// 无条件常驻（本地模式同样需要）。行情刷新只写本地专有缓存列，也走这条链路。
///
/// ⚠️ 本 provider 自身没有别的消费者，需在 `lib/app.dart` 启动时 `ref.read`
/// 一次才会生效（同 [holdingsRateBridgeProvider]）。
final holdingsTableWatchProvider = Provider<void>((ref) {
  final db = ref.watch(databaseProvider);
  StreamSubscription<void>? sub;
  try {
    sub = db.tableUpdates(d.TableUpdateQuery.onTable(db.holdings)).listen((_) {
      ref.read(statsRefreshProvider.notifier).state++;
    });
  } catch (e, st) {
    // db 极少数时序下可能未就绪；不影响主流程，记日志即可。
    logger.warning('HoldingProvider', 'holdings table-watch 启动失败: $e', st);
  }
  ref.onDispose(() => sub?.cancel());
});

/// 把「有效汇率」桥接进 Repository 层，供持仓多币种折算使用。
///
/// 为什么需要桥接：`LocalAccountRepository.getAccountBalance` 等口径要算
/// 「持仓币种 ≠ 账户币种」的持仓，需要 `1 单位该币种 = ? 单位基准` 的汇率表；
/// 而 Repository 层**不依赖 Riverpod**（架构边界），所以这里用「注入闭包」
/// 的方式把 provider 里的汇率喂进去（见 `LocalRepository.setHoldingsRateResolver`）。
///
/// ⚠️ 本 provider 必须在应用启动时被实例化一次（`lib/app.dart` 的
/// postFrameCallback 里 `ref.read`），否则解析器为 null —— 那时只有
/// 「持仓币种 == 账户币种」的持仓计入，跨币种持仓会被静默剔除（不会算错，
/// 但会少算，与「缺汇率剔除」同一条降级路径）。这正是
/// `lib/app.dart` 里 P2-7 那条教训的同款陷阱：provider 定义了却无人消费。
final holdingsRateBridgeProvider = Provider<void>((ref) {
  final repo = ref.watch(repositoryProvider);
  if (repo is! LocalRepository) return;
  repo.setHoldingsRateResolver(() async {
    final base = ref.read(baseCurrencyProvider).toUpperCase();
    final rates = await ref.read(effectiveRatesProvider.future);
    // 口径与 `netWorthTrendSeriesProvider` 完全一致：base 自身恒 1.0，
    // 其余只收「解析成功且为正」的汇率。
    final map = <String, double>{base: 1.0};
    for (final e in rates.entries) {
      final rate = double.tryParse(e.value.rate);
      if (rate != null && rate > 0) map[e.key.toUpperCase()] = rate;
    }
    return map;
  });
});
