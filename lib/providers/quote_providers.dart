import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:flutter_market_data_eastmoney/flutter_market_data_eastmoney.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../data/repositories/base_repository.dart';
import '../services/investment/quote_service.dart';
import '../services/system/logger_service.dart';
import 'currency_providers.dart';
import 'database_providers.dart';

/// 行情源装配。
///
/// 已注册两个源：`manual`（手动录入，零网络，默认）与 `eastmoney`
/// （东方财富，A 股 / 港股 / 基金，免密钥）。接入新源只需：
/// 1. 新增 `packages/flutter_market_data_<vendor>` 子包实现 [QuoteProvider]；
/// 2. 在 [kAvailableQuoteProviderIds] 与 [_createProvider] 里各加一行；
/// 3. 无需改 schema、快照格式、同步契约。

/// 已注册的行情源标识（设置页据此渲染选项）。
///
/// **名称一律走 l10n**（`investmentQuoteSourceManual` /
/// `investmentQuoteSourceEastmoney` 等 key）：接口层的 `providerName` 只是
/// 开发者可读名，直接渲染会让中文界面出现英文源名。
const List<String> kAvailableQuoteProviderIds = <String>[
  ManualQuoteProvider.id,
  EastmoneyQuoteProvider.id,
];

/// 默认行情源（= 升级前的行为：手动录入手填净值，零网络）。切到 `eastmoney`
/// 必须由用户在设置里显式完成，**绝不默认开启网络请求**。
const String kDefaultQuoteProviderId = ManualQuoteProvider.id;

const String _quoteProviderIdPrefsKey = 'investment_quote_provider_id';

/// 当前选中的行情源标识（持久化）。
class QuoteProviderIdNotifier extends StateNotifier<String> {
  QuoteProviderIdNotifier({BaseRepository? repository})
      : _repository = repository,
        super(kDefaultQuoteProviderId) {
    _load();
  }

  /// 换源时用来清「旧源」缓存；可为 null（测试 / 极早期时序下不清理也不影响
  /// 正确性 —— 旧缓存会因 TTL 与「生效价」判定自然失效）。
  final BaseRepository? _repository;

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
  ///
  /// **换源清旧缓存**：真正发生切换时（old != new），定向清掉「旧源」写入的
  /// 行情缓存（`quote_source_id == oldId`）—— 旧源的价格不该继续参与「生效价」，
  /// 否则切换后界面会拿上一个源的价格继续显示（`isQuoteUsable` 不校验源标识，
  /// 清缓存是唯一收敛点）。手动源（`manual`）不写缓存，清理它是无害的空操作。
  Future<void> select(String providerId) async {
    if (!kAvailableQuoteProviderIds.contains(providerId)) {
      logger.warning('QuoteProvider', '未知行情源 id=$providerId，忽略');
      return;
    }
    final oldId = state;
    state = providerId;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_quoteProviderIdPrefsKey, providerId);
      if (oldId != providerId && _repository != null) {
        await _repository.clearQuoteCache(sourceId: oldId);
      }
    } catch (e) {
      logger.warning('QuoteProvider', '行情源设置写入 / 旧缓存清理失败: $e');
    }
  }
}

final quoteProviderIdProvider =
    StateNotifierProvider<QuoteProviderIdNotifier, String>(
  (ref) =>
      QuoteProviderIdNotifier(repository: ref.watch(repositoryProvider)),
);

/// 按 id 构造行情源实例。新增真实行情源时在这里加 case
/// （未知 id 一律回退手动源，永不抛）。
QuoteProvider _createProvider(String providerId) {
  switch (providerId) {
    case EastmoneyQuoteProvider.id:
      return EastmoneyQuoteProvider();
    case ManualQuoteProvider.id:
    default:
      return const ManualQuoteProvider();
  }
}

/// 当前行情源实例。
final quoteProviderProvider = Provider<QuoteProvider>(
  (ref) => _createProvider(ref.watch(quoteProviderIdProvider)),
);

/// 行情编排服务（筛选 / 切片 / 写缓存 / 缺汇率剔除 / 失败降级都在 `QuoteService`）。
///
/// 注入汇率解析器：跨币种持仓（如人民币账户持有港股）折算到持仓币种时消费，
/// 缺汇率整条剔除（`QuoteService` 内闭环，见 `QuoteRefreshResult.excluded`）。
final quoteServiceProvider = Provider<QuoteService>(
  (ref) => QuoteService(
    repository: ref.watch(repositoryProvider),
    provider: ref.watch(quoteProviderProvider),
    ratesToBaseResolver: () async {
      // 读取失败一律降级为空表（而非向上抛）：跨币种持仓按「缺汇率剔除」处理、
      // 同币种持仓不受影响 —— 行情刷新绝不因汇率侧异常而中断或冒泡到 UI。
      try {
        final base = ref.read(baseCurrencyProvider).toUpperCase();
        final rates = await ref.read(effectiveRatesProvider.future);
        // 口径与 holdingsRateBridgeProvider 完全一致：base 自身恒 1.0，
        // 其余只收「解析成功且为正」的汇率。
        final map = <String, double>{base: 1.0};
        for (final e in rates.entries) {
          final rate = double.tryParse(e.value.rate);
          if (rate != null && rate > 0) map[e.key.toUpperCase()] = rate;
        }
        return map;
      } catch (e) {
        logger.warning('QuoteProvider', '汇率加载失败，跨币种持仓本轮剔除: $e');
        return const <String, double>{};
      }
    },
  ),
);

// ── 自动刷新设置（开关 + 频率）──────────────────────────────────────────

/// 自动刷新频率的可选档位（升序）。调度器 15 分钟一跳，档位下限即 15 分钟。
const List<Duration> kQuoteRefreshFrequencies = <Duration>[
  Duration(minutes: 15),
  Duration(minutes: 30),
  Duration(hours: 1),
  Duration(hours: 4),
];

/// 默认频率。
const Duration kDefaultQuoteRefreshFrequency = Duration(minutes: 15);

/// 自动刷新设置：主开关 + 频率。
class QuoteAutoRefreshSettings {
  const QuoteAutoRefreshSettings({
    required this.enabled,
    required this.interval,
  });

  static const QuoteAutoRefreshSettings defaults = QuoteAutoRefreshSettings(
    enabled: false,
    interval: kDefaultQuoteRefreshFrequency,
  );

  final bool enabled;
  final Duration interval;

  @override
  bool operator ==(Object other) =>
      other is QuoteAutoRefreshSettings &&
      other.enabled == enabled &&
      other.interval == interval;

  @override
  int get hashCode => Object.hash(enabled, interval);
}

const String _autoRefreshEnabledPrefsKey = 'investment_auto_refresh_enabled';
const String _autoRefreshIntervalPrefsKey =
    'investment_auto_refresh_interval_minutes';

/// 自动刷新设置的持久化 notifier。默认关闭（不静默开启后台网络请求）。
class QuoteAutoRefreshSettingsNotifier
    extends StateNotifier<QuoteAutoRefreshSettings> {
  QuoteAutoRefreshSettingsNotifier() : super(QuoteAutoRefreshSettings.defaults) {
    _load();
  }

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_autoRefreshEnabledPrefsKey);
      final minutes = prefs.getInt(_autoRefreshIntervalPrefsKey);
      final interval = minutes == null
          ? kDefaultQuoteRefreshFrequency
          : Duration(minutes: minutes);
      state = QuoteAutoRefreshSettings(
        enabled: enabled ?? QuoteAutoRefreshSettings.defaults.enabled,
        interval: kQuoteRefreshFrequencies.contains(interval)
            ? interval
            : kDefaultQuoteRefreshFrequency,
      );
    } catch (e) {
      logger.warning('QuoteProvider', '自动刷新设置读取失败，保持默认关闭: $e');
    }
  }

  Future<void> setEnabled(bool value) async {
    state = QuoteAutoRefreshSettings(enabled: value, interval: state.interval);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_autoRefreshEnabledPrefsKey, value);
    } catch (e) {
      logger.warning('QuoteProvider', '自动刷新开关写入失败: $e');
    }
  }

  Future<void> setInterval(Duration value) async {
    if (!kQuoteRefreshFrequencies.contains(value)) return;
    state = QuoteAutoRefreshSettings(enabled: state.enabled, interval: value);
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_autoRefreshIntervalPrefsKey, value.inMinutes);
    } catch (e) {
      logger.warning('QuoteProvider', '自动刷新频率写入失败: $e');
    }
  }
}

final quoteAutoRefreshSettingsProvider =
    StateNotifierProvider<QuoteAutoRefreshSettingsNotifier,
        QuoteAutoRefreshSettings>((ref) => QuoteAutoRefreshSettingsNotifier());

/// 生效的刷新最小间隔 = max(用户频率, 行情源 `minRefreshInterval`)。
///
/// 调度层 `_runScheduledQuoteRefresh` 用它做节流：即使用户选了 15 分钟，
/// 行情源要求更慢（如 15 分钟）时也按源的节奏走。
final quoteEffectiveMinIntervalProvider = Provider<Duration>((ref) {
  final user = ref.watch(quoteAutoRefreshSettingsProvider).interval;
  final sourceMin =
      ref.watch(quoteProviderProvider).capability.minRefreshInterval;
  return user > sourceMin ? user : sourceMin;
});
