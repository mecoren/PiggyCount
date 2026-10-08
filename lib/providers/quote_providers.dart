import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../services/investment/quote_service.dart';
import '../services/system/logger_service.dart';
import 'database_providers.dart';

/// 行情源装配（v52 预留）。
///
/// 当前**只有「手动录入」一个源**：它不发起任何网络请求，语义是
/// 「行情价 = 用户手填净值」。整条链路（接口 / 编排 / 调度 / 设置项）都已就位，
/// 后期接入真实行情源只需：
/// 1. 新增 `packages/flutter_market_data_<vendor>` 子包实现 [QuoteProvider]；
/// 2. 在 [kAvailableQuoteProviderIds] 与 [_createProvider] 里各加一行；
/// 3. 无需改 schema、快照格式、同步契约。

/// 已注册的行情源标识（设置页据此渲染选项）。
///
/// **名称一律走 l10n**（`quoteSourceManual` 等 key）：接口层的 `providerName`
/// 只是开发者可读名，直接渲染会让中文界面出现英文源名。
const List<String> kAvailableQuoteProviderIds = <String>[
  ManualQuoteProvider.id,
];

/// 默认行情源（= 今天的行为：手动录入手填净值，零网络）
const String kDefaultQuoteProviderId = ManualQuoteProvider.id;

const String _quoteProviderIdPrefsKey = 'investment_quote_provider_id';

/// 当前选中的行情源标识（持久化）。
///
/// 默认「手动录入」—— 保证升级到 v52 的用户**不会被无感知地开启网络请求**。
class QuoteProviderIdNotifier extends StateNotifier<String> {
  QuoteProviderIdNotifier() : super(kDefaultQuoteProviderId) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final saved = prefs.getString(_quoteProviderIdPrefsKey);
      if (saved != null && kAvailableQuoteProviderIds.contains(saved)) {
        state = saved;
      }
    } catch (e) {
      // 读取失败保持默认（手动源）：宁可不自动拉行情，也不能猜一个源出来。
      logger.warning('QuoteProvider', '行情源设置读取失败，回退手动源: $e');
    }
  }

  /// 切换行情源并持久化。非法 id 一律忽略（保持当前值）。
  Future<void> select(String providerId) async {
    if (!kAvailableQuoteProviderIds.contains(providerId)) {
      logger.warning('QuoteProvider', '未知行情源 id=$providerId，忽略');
      return;
    }
    state = providerId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_quoteProviderIdPrefsKey, providerId);
    } catch (e) {
      logger.warning('QuoteProvider', '行情源设置写入失败: $e');
    }
  }
}

final quoteProviderIdProvider =
    StateNotifierProvider<QuoteProviderIdNotifier, String>(
  (ref) => QuoteProviderIdNotifier(),
);

/// 按 id 构造行情源实例。
///
/// 新增真实行情源时在这里加 case（未知 id 一律回退手动源，永不抛）。
QuoteProvider _createProvider(String providerId) {
  switch (providerId) {
    case ManualQuoteProvider.id:
    default:
      return const ManualQuoteProvider();
  }
}

/// 当前行情源实例。
final quoteProviderProvider = Provider<QuoteProvider>(
  (ref) => _createProvider(ref.watch(quoteProviderIdProvider)),
);

/// 行情编排服务（筛选 / 切片 / 写缓存 / 失败降级都在 `QuoteService` 内）。
final quoteServiceProvider = Provider<QuoteService>(
  (ref) => QuoteService(
    repository: ref.watch(repositoryProvider),
    provider: ref.watch(quoteProviderProvider),
  ),
);
