import 'dart:math' as math;

import 'package:flutter_market_data/flutter_market_data.dart';

import '../../data/db.dart';
import '../../data/repositories/base_repository.dart';
import '../../utils/holding_metrics.dart' show crossRate;
import '../system/logger_service.dart';

/// 一次行情刷新的统计结果。
class QuoteRefreshResult {
  const QuoteRefreshResult({
    required this.updated,
    required this.skipped,
    required this.failed,
    required this.requestCount,
    this.excluded = 0,
    this.errorKind,
  });

  static const QuoteRefreshResult empty = QuoteRefreshResult(
    updated: 0,
    skipped: 0,
    failed: 0,
    requestCount: 0,
  );

  /// 成功写入行情缓存的**持仓条数**（不是标的数：同一标的的多条持仓各算一条）
  final int updated;

  /// 未参与刷新的持仓条数（`autoQuote=false` / 无代码 / 市场不被该源支持）
  final int skipped;

  /// 因请求失败而未更新的持仓条数
  final int failed;

  /// 因「报价币种 ≠ 持仓币种且缺汇率」而被剔除、未写缓存的持仓条数
  /// （命中且价格合法，但折算不到持仓币种 —— 不写脏值、不推进 `fetchedAt`）。
  final int excluded;

  /// 实际发出的请求次数（批量源一次可带多个标的；超过上限会切片）
  final int requestCount;

  /// 失败类别（全部成功时为 null）
  final QuoteErrorKind? errorKind;

  @override
  String toString() => 'QuoteRefreshResult(updated=$updated, skipped=$skipped, '
      'failed=$failed, excluded=$excluded, requests=$requestCount, '
      'error=$errorKind)';
}

/// 单标的即时预览结果（编辑表单用）：折算到持仓币种的价 + 源返回的名称。
class QuotePreview {
  const QuotePreview({required this.price, this.name});

  /// 已折算到持仓币种的价
  final double price;

  /// 标的名称（源未提供 / 未取到为 null）—— 只在用户尚未填名时用于回填。
  final String? name;
}

/// 请求切片里的一个标的及其关联持仓。
class _Candidate {
  _Candidate({required this.symbol, required this.market});

  final String symbol;
  final String market;

  /// 指向同一 (市场, 代码) 的持仓行（多笔持仓可以持有同一标的）
  final List<Holding> holdings = <Holding>[];

  String get key => '$market|$symbol';
}

/// 行情编排层（v52 预留）。
///
/// 职责边界：
/// - **它**负责「选哪些持仓、怎么切片、写哪个列、失败怎么降级」；
/// - [`QuoteProvider`] 只负责「把请求变成价格」，不做节流/缓存/落库。
///
/// 三条硬纪律（改了要同步看 `test/services/quote_service_test.dart`）：
/// 1. **默认零请求**：手动源（`capability.isAutomatic == false`）或候选为空时
///    一次网络都不发 —— 「本批默认关闭」不是靠 UI 开关，是靠这里直接返回。
/// 2. **只写本地专有缓存列**：`quote_price` / `quote_fetched_at` / `quote_source_id`，
///    **绝不碰** `unitPrice`（用户数据）；且这些列不进快照 / 指纹 / `local_changes`。
/// 3. **失败不写脏值**：请求失败或标的未命中时保留旧缓存，连 `quote_fetched_at`
///    都不推进 —— 否则 TTL 会把它误判为「刚更新过」，用户永远等不到重试。
/// 4. **缺汇率剔除**：报价币种 ≠ 持仓币种时按 `crossRate` 折算；折算不到（缺汇率）
///    整条剔除、不写缓存（`QuoteRefreshResult.excluded`），绝不把外币报价当本币写。
class QuoteService {
  QuoteService({
    required this.repository,
    required this.provider,
    this.ratesToBaseResolver,
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final BaseRepository repository;
  final QuoteProvider provider;

  /// 「币种 → 1 单位该币种 = ? 单位本位币」的汇率表解析器（`crossRate` 的入参）。
  ///
  /// 仅当「报价币种 ≠ 持仓币种」时才消费；为 null（未注入）时等价于空汇率表，
  /// 跨币种持仓一律剔除 —— 宁可少写也不把 100 USD 的报价当 100 CNY 写进缓存。
  final Future<Map<String, double>> Function()? ratesToBaseResolver;

  final DateTime Function() _now;

  QuoteCapability get capability => provider.capability;

  /// 当前行情源是否具备自动拉取能力（调度层据此决定要不要启动）。
  bool get supportsAutomaticQuotes => provider.capability.isAutomatic;

  /// 拉取所有符合条件的持仓行情并写入本地缓存。
  ///
  /// 「符合条件」= `autoQuote == true` **且** 有非空 `symbol` **且** 当前源
  /// 支持该 `market`。逐笔开关优先于全局：即使全局选了自动源，单笔也能保持手填。
  Future<QuoteRefreshResult> refreshQuotes() async {
    final holdings = await repository.getAllHoldings();
    if (holdings.isEmpty) return QuoteRefreshResult.empty;

    // ① 手动源：一次请求都不发（这就是「默认关闭」的实现）。
    if (!provider.capability.isAutomatic) {
      return QuoteRefreshResult(
        updated: 0,
        skipped: holdings.length,
        failed: 0,
        requestCount: 0,
      );
    }

    // ② 筛候选：逐笔开关 + 有代码 + 市场被支持（这里挡掉必然失败的请求）。
    final byKey = <String, _Candidate>{};
    var skipped = 0;
    for (final holding in holdings) {
      final symbol = holding.symbol?.trim() ?? '';
      final market = holding.market?.trim().toUpperCase();
      if (!holding.autoQuote ||
          symbol.isEmpty ||
          !provider.capability.supports(market)) {
        skipped++;
        continue;
      }
      final candidate = byKey.putIfAbsent(
        '$market|${symbol.toUpperCase()}',
        () => _Candidate(symbol: symbol, market: market!),
      );
      candidate.holdings.add(holding);
    }
    if (byKey.isEmpty) {
      return QuoteRefreshResult(
        updated: 0,
        skipped: skipped,
        failed: 0,
        requestCount: 0,
      );
    }

    // ③ 切片：批量源按 capability 上限切；不支持批量的源每片一个标的。
    final candidates = byKey.values.toList(growable: false);
    final batchSize = provider.capability.supportsBatch
        ? provider.capability.maxSymbolsPerRequest.clamp(1, 1000)
        : 1;

    var updated = 0;
    var failed = 0;
    var excluded = 0;
    var requestCount = 0;
    QuoteErrorKind? errorKind;

    // 汇率表惰性解析：只有「报价币种 ≠ 持仓币种」时才消费（多数同币种场景零开销）。
    Map<String, double>? ratesToBase;
    Future<Map<String, double>> resolveRates() async {
      return ratesToBase ??= ratesToBaseResolver != null
          ? await ratesToBaseResolver!()
          : const <String, double>{};
    }

    for (var start = 0; start < candidates.length; start += batchSize) {
      final chunk = candidates.sublist(
        start,
        math.min(start + batchSize, candidates.length),
      );
      requestCount++;
      Map<String, Quote> quotes;
      try {
        quotes = await provider.fetchQuotes(
          QuoteRequest(
            items: [
              for (final c in chunk)
                QuoteRequestItem(symbol: c.symbol, market: c.market),
            ],
          ),
        );
      } on QuoteException catch (e) {
        // 分类降级：调用方按 kind 决定退避 / 提示 / 放弃。
        failed += chunk.fold<int>(0, (n, c) => n + c.holdings.length);
        errorKind = e.kind;
        logger.warning('QuoteService',
            '行情拉取失败(${e.kind.name})：${chunk.length} 个标的，保留旧缓存');
        continue;
      } catch (e, st) {
        failed += chunk.fold<int>(0, (n, c) => n + c.holdings.length);
        errorKind = QuoteErrorKind.unknown;
        logger.error('QuoteService', '行情拉取未预期异常，保留旧缓存', e, st);
        continue;
      }

      // ④ 写缓存：只写命中的、价格为正、且能折算到持仓币种的标的。
      final stamp = _now();
      for (final c in chunk) {
        final quote = quotes[c.key];
        // 未命中（源没有这个标的）或价格非法 → 保留旧缓存，不写脏值。
        if (quote == null || quote.price <= 0) continue;
        for (final holding in c.holdings) {
          final qc = (quote.currency ?? '').trim().toUpperCase();
          final hc = holding.currency.trim().toUpperCase();
          // 同币种 / 源未标币种 → 零折算开销；跨币种才解析汇率表。
          final price = (qc.isEmpty || qc == hc)
              ? quote.price
              : _convertWithRates(quote, holding.currency, await resolveRates());
          if (price == null) {
            // 缺汇率整条剔除，不写脏值。
            excluded++;
            continue;
          }
          await repository.writeQuoteCache(
            holding.id,
            price: price,
            fetchedAt: stamp,
            sourceId: provider.providerId,
          );
          updated++;
        }
      }
    }

    logger.debug('QuoteService',
        '行情刷新完成：更新=$updated 跳过=$skipped 失败=$failed '
        '剔除=$excluded 请求=$requestCount');

    return QuoteRefreshResult(
      updated: updated,
      skipped: skipped,
      failed: failed,
      excluded: excluded,
      requestCount: requestCount,
      errorKind: errorKind,
    );
  }

  /// 单标的**即时预览**（编辑表单「输入代码即按源更新价 + 带出名称」用）。
  ///
  /// 与 [refreshQuotes] 同口径但**不写缓存、不节流**：命中且价格为正才返回，
  /// 跨币种按汇率折算到 [holdingCurrency]，未命中 / 缺汇率一律返回 null；
  /// 请求失败抛 [QuoteException]（调用方按 `kind` 提示）。
  ///
  /// 是否该调用由调用方判定（源是否具备自动能力 / 是否支持该市场 / 用户是否
  /// 勾选了自动刷新），本方法只管「把请求变成一个可展示的价 + 名称」。
  Future<QuotePreview?> previewQuote({
    required String symbol,
    required String market,
    required String holdingCurrency,
  }) async {
    final item = QuoteRequestItem(symbol: symbol, market: market);
    final quotes = await provider.fetchQuotes(
      QuoteRequest(items: [item]),
    );
    final quote = quotes[item.key];
    if (quote == null || quote.price <= 0) return null;
    final qc = (quote.currency ?? '').trim().toUpperCase();
    final hc = holdingCurrency.trim().toUpperCase();
    final price = (qc.isEmpty || qc == hc)
        ? quote.price
        : _convertWithRates(quote, holdingCurrency, await _loadRates());
    if (price == null) return null;
    return QuotePreview(price: price, name: quote.name);
  }

  /// 报价币种 → 持仓币种 的折算；同币种 / 源未标币种直接返回，缺汇率返回 null。
  double? _convertWithRates(
    Quote quote,
    String holdingCurrency,
    Map<String, double> ratesToBase,
  ) {
    final qc = (quote.currency ?? '').trim().toUpperCase();
    final hc = holdingCurrency.trim().toUpperCase();
    if (qc.isEmpty || qc == hc) return quote.price;
    final rate = crossRate(from: qc, to: hc, ratesToBase: ratesToBase);
    if (rate == null) return null;
    return quote.price * rate;
  }

  /// 解析一次汇率表。未注入解析器时等价于**空表**（跨币种持仓一律按
  /// 「缺汇率」处理）—— 宁可少展示，也不把外币报价当本币。
  Future<Map<String, double>> _loadRates() async {
    return ratesToBaseResolver != null
        ? await ratesToBaseResolver!()
        : const <String, double>{};
  }
}
