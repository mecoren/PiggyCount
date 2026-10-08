import 'quote.dart';
import 'quote_capability.dart';
import 'quote_provider.dart';

/// 「手动录入」行情源 —— 当前唯一实现，**不发起任何网络请求**。
///
/// 语义：行情价 = 用户手填的持仓净值（`holdings.unit_price`）。它的存在让
/// 「行情」这条链路从一开始就是**完整的**（接口 / 装配 / 调度 / 设置项都在位），
/// 只是价格来源是用户自己。因此：
///
/// - [capability].`supportedMarkets` 为空集 → [QuoteCapability.isAutomatic]
///   恒 false → 编排层不会启动任何调度、不会产生任何请求；
/// - [fetchQuotes] 返回**空 map**：表达「本源不覆盖任何标的」，调用方据此
///   保留 `quote_price` 为空、走「生效价回退手填净值」分支 ——
///   这正是「没有行情功能之前的行为」，零行为变化。
///
/// 后期接真实行情源时不需要动它：新源与它并存，用户在设置里切换即可
/// （切源后旧源的缓存按 `quote_source_id` 定向清理）。
class ManualQuoteProvider implements QuoteProvider {
  const ManualQuoteProvider();

  /// 持久化用的稳定标识（设置项默认值就是它）
  static const String id = 'manual';

  @override
  String get providerId => id;

  @override
  String get providerName => 'Manual';

  @override
  QuoteCapability get capability => const QuoteCapability(
        // 空集合 = 不具备自动拉取能力
        supportedMarkets: <String>{},
        supportsBatch: false,
        // 手动源的「最小间隔」没有实际意义（不会自动刷新），给一个极大的值，
        // 保证任何基于 capability 的节流判定都不会误触发自动刷新。
        minRefreshInterval: Duration(days: 3650),
        requiresApiKey: false,
      );

  @override
  Future<void> initialize(Map<String, dynamic> config) async {}

  @override
  Future<Map<String, Quote>> fetchQuotes(QuoteRequest request) async =>
      const <String, Quote>{};

  @override
  Future<void> dispose() async {}
}
