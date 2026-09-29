import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../data/db.dart' as db;
import '../../data/models/transaction_original_amount.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/original_amount_providers.dart';
import '../../services/original_amount_insight_service.dart';
import '../../styles/tokens.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// v45 金额偏差分析页。
///
/// 视角：原始金额（用户手填的票面/来源金额） vs 记账金额（即"默认金额"）。
/// - 汇总 / 趋势 / 分类排行：SQL 聚合，口径 `COALESCE(original_amount, amount) - amount`；
/// - 偏差洞察：由 [OriginalAmountInsightService] 纯函数规则引擎产出，
///   点击明细可直接跳回交易编辑页修正。
class AmountDeviationPage extends ConsumerStatefulWidget {
  const AmountDeviationPage({super.key, this.initialStart, this.initialEnd});

  final DateTime? initialStart;
  final DateTime? initialEnd;

  /// 超过这个天数就把日粒度换成月粒度（同区间报表的取舍：避免几百根柱）。
  static const int dayChartLimit = 45;

  /// 洞察列表最多展示条数。
  static const int insightLimit = 20;

  @override
  ConsumerState<AmountDeviationPage> createState() =>
      _AmountDeviationPageState();
}

class _AmountDeviationPageState extends ConsumerState<AmountDeviationPage> {
  late DateTime _start = widget.initialStart ??
      DateTime(DateTime.now().year, DateTime.now().month, 1);
  late DateTime _end = widget.initialEnd ??
      DateTime(DateTime.now().year, DateTime.now().month, DateTime.now().day)
          .add(const Duration(days: 1));

  String _dim = 'expense';

  Future<_DeviationData>? _future;
  String? _futureKey;

  Future<_DeviationData> _load(int ledgerId) async {
    final repo = ref.read(repositoryProvider);
    final metric = ref.read(originalAmountMetricProvider);
    final basis = ref.read(originalAmountBasisProvider);
    final granularity =
        _end.difference(_start).inDays > AmountDeviationPage.dayChartLimit
            ? 'month'
            : 'day';
    // 四条查询互不依赖 → record.wait 并发（Dart 3 + dart:async 扩展）。
    final (summary, trend, cats, rows) = await (
      repo.originalAmountDiffSummary(
          ledgerId: ledgerId,
          type: _dim,
          start: _start,
          end: _end,
          metric: metric,
          basis: basis),
      repo.originalAmountDiffTrend(
          ledgerId: ledgerId,
          type: _dim,
          start: _start,
          end: _end,
          granularity: granularity,
          metric: metric,
          basis: basis),
      repo.originalAmountDiffByCategory(
          ledgerId: ledgerId,
          type: _dim,
          start: _start,
          end: _end,
          metric: metric,
          basis: basis),
      repo.getTransactionsByDateRange(
          ledgerId: ledgerId, startDate: _start, endDate: _end),
    ).wait;

    final txs = rows
        .map((r) => (t: r.t, c: r.category))
        .where((e) => e.t.type == _dim)
        .toList();
    final insights = OriginalAmountInsightService.analyze(
      txs.map((e) => e.t).toList(),
      metric: metric,
      basis: basis,
    );

    return _DeviationData(
      summary: summary,
      trend: trend,
      cats: cats,
      insights: insights
          .take(AmountDeviationPage.insightLimit)
          .toList(growable: false),
      granularity: granularity,
      txById: {for (final e in txs) e.t.id: e.t},
      catById: {for (final e in txs) e.t.id: e.c},
    );
  }

  Future<_DeviationData> _futureFor(int ledgerId, int refreshTick) {
    final key = '$ledgerId|${_start.microsecondsSinceEpoch}'
        '|${_end.microsecondsSinceEpoch}|$_dim|$refreshTick'
        '|${ref.read(originalAmountMetricProvider).name}'
        '|${ref.read(originalAmountBasisProvider).name}';
    if (_futureKey == key && _future != null) return _future!;
    final f = _load(ledgerId);
    _futureKey = key;
    _future = f;
    return f;
  }

  Future<void> _pickRange() async {
    final now = DateTime.now();
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year, now.month, now.day),
      initialDateRange: DateTimeRange(
        start: DateTime(_start.year, _start.month, _start.day),
        end: DateTime(_end.year, _end.month, _end.day)
            .subtract(const Duration(days: 1)),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _start = picked.start;
      // 选择器是「含末日」，内部统一半开区间 [start, end)
      _end = picked.end.add(const Duration(days: 1));
    });
  }

  String _rangeText() {
    final f = DateFormat('yyyy.MM.dd');
    return '${f.format(_start)} ~ '
        '${f.format(_end.subtract(const Duration(days: 1)))}';
  }

  String _severityText(AppLocalizations l10n, OriginalAmountSeverity s) {
    switch (s) {
      case OriginalAmountSeverity.slight:
        return l10n.amountDeviationSeveritySlight;
      case OriginalAmountSeverity.notable:
        return l10n.amountDeviationSeverityNotable;
      case OriginalAmountSeverity.severe:
        return l10n.amountDeviationSeveritySevere;
    }
  }

  String _reasonText(AppLocalizations l10n, OriginalAmountReasonCode c) {
    switch (c) {
      case OriginalAmountReasonCode.aboveRecorded:
        return l10n.amountDeviationReasonAbove;
      case OriginalAmountReasonCode.belowRecorded:
        return l10n.amountDeviationReasonBelow;
      case OriginalAmountReasonCode.multipleOfRecorded:
        return l10n.amountDeviationReasonMultiple;
      case OriginalAmountReasonCode.categoryHabit:
        return l10n.amountDeviationReasonCategoryHabit;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final refreshTick = ref.watch(statsRefreshProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.amountDeviationTitle,
        subtitle: _rangeText(),
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 80),
        child: FutureBuilder<_DeviationData>(
          future: _futureFor(ledgerId, refreshTick),
          builder: (context, snap) {
            if (snap.connectionState != ConnectionState.done) {
              return const Center(child: CircularProgressIndicator());
            }
            if (snap.hasError) {
              return Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Text('${l10n.commonError}: ${snap.error}'),
                ),
              );
            }
            final data = snap.data!;
            return ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              children: [
                _rangeCard(context, l10n),
                const SizedBox(height: 12),
                _dimChips(l10n),
                const SizedBox(height: 8),
                _metricChips(l10n),
                if (data.summary.deviated == 0) ...[
                  const SizedBox(height: 24),
                  AppEmpty(
                    text: l10n.commonEmpty,
                    subtext: l10n.amountDeviationEmptySubtext,
                  ),
                ] else ...[
                  const SizedBox(height: 12),
                  _summaryCard(context, l10n, data),
                  const SizedBox(height: 12),
                  _card(
                    context,
                    title: l10n.amountDeviationTrendTitle,
                    child: _trendChart(context, l10n, data),
                  ),
                  if (data.cats.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _card(
                      context,
                      title: l10n.amountDeviationCategoryTitle,
                      child: _categoryRanking(context, l10n, data),
                    ),
                  ],
                  if (data.insights.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _card(
                      context,
                      title: l10n.amountDeviationInsightTitle,
                      child: _insightList(context, l10n, data),
                    ),
                  ],
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  // --- 组件 ---------------------------------------------------------------

  Widget _rangeCard(BuildContext context, AppLocalizations l10n) {
    return Material(
      color: PiggyTokens.surface(context),
      borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
      child: InkWell(
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        onTap: _pickRange,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          child: Row(
            children: [
              Icon(Icons.calendar_today_outlined,
                  size: 18, color: PiggyTokens.primary(context)),
              const SizedBox(width: 10),
              Expanded(
                child: Text(_rangeText(),
                    style: PiggyTextTokens.strongTitle(context)),
              ),
              Icon(Icons.expand_more,
                  color: PiggyTokens.textTertiary(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _dimChips(AppLocalizations l10n) {
    return Row(
      children: [
        ChoiceChip(
          label: Text(l10n.homeExpense),
          selected: _dim == 'expense',
          onSelected: (_) => setState(() => _dim = 'expense'),
        ),
        const SizedBox(width: 8),
        ChoiceChip(
          label: Text(l10n.homeIncome),
          selected: _dim == 'income',
          onSelected: (_) => setState(() => _dim = 'income'),
        ),
      ],
    );
  }

  /// 金额口径 + 差异基准选择器。
  ///
  /// 两个维度都与统计 SQL、洞察规则引擎、明细列表角标同源 —— 这里一切换，
  /// 整页与列表同时跟随，不会出现"页面一套口径、列表另一套"。
  Widget _metricChips(AppLocalizations l10n) {
    final metric = ref.watch(originalAmountMetricProvider);
    final basis = ref.watch(originalAmountBasisProvider);
    final labelStyle = PiggyTextTokens.caption(context)
        .copyWith(color: PiggyTokens.textSecondary(context));

    Widget chip({
      required String text,
      required bool selected,
      required VoidCallback onTap,
    }) =>
        ChoiceChip(
          label: Text(text),
          selected: selected,
          onSelected: (_) => setState(onTap),
        );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${l10n.amountDeviationMetricLabel}:', style: labelStyle),
            chip(
              text: l10n.amountDeviationMetricCurrency,
              selected: metric == OriginalAmountMetric.currency,
              onTap: () => ref
                  .read(originalAmountMetricProvider.notifier)
                  .state = OriginalAmountMetric.currency,
            ),
            chip(
              text: l10n.amountDeviationMetricNative,
              selected: metric == OriginalAmountMetric.native,
              onTap: () => ref
                  .read(originalAmountMetricProvider.notifier)
                  .state = OriginalAmountMetric.native,
            ),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('${l10n.amountDeviationBasisLabel}:', style: labelStyle),
            chip(
              text: l10n.amountDeviationBasisRecorded,
              selected: basis == OriginalAmountBasis.recorded,
              onTap: () => ref
                  .read(originalAmountBasisProvider.notifier)
                  .state = OriginalAmountBasis.recorded,
            ),
            chip(
              text: l10n.amountDeviationBasisOriginal,
              selected: basis == OriginalAmountBasis.original,
              onTap: () => ref
                  .read(originalAmountBasisProvider.notifier)
                  .state = OriginalAmountBasis.original,
            ),
          ],
        ),
      ],
    );
  }

  Widget _card(BuildContext context,
      {required String title, required Widget child}) {
    return Material(
      color: PiggyTokens.surface(context),
      borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: PiggyTextTokens.strongTitle(context)),
            const SizedBox(height: 12),
            child,
          ],
        ),
      ),
    );
  }

  Widget _summaryCard(
      BuildContext context, AppLocalizations l10n, _DeviationData data) {
    final s = data.summary;
    Widget cell(String label, String value, {Color? color}) => Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: PiggyTextTokens.caption(context).copyWith(
                      color: PiggyTokens.textSecondary(context))),
              const SizedBox(height: 4),
              Text(value,
                  style: PiggyTextTokens.strongTitle(context)
                      .copyWith(color: color)),
            ],
          ),
        );

    final diffColor = s.diffSum >= 0
        ? PiggyTokens.expenseColor(context, ref)
        : PiggyTokens.incomeColor(context, ref);
    String fmt(double v) =>
        '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)}';

    return _card(
      context,
      title: l10n.amountDeviationTitle,
      child: Column(
        children: [
          Row(children: [
            cell(l10n.amountDeviationTotalLabel, '${s.total}'),
            cell(l10n.amountDeviationDeviatedLabel, '${s.deviated}'),
          ]),
          const SizedBox(height: 14),
          Row(children: [
            cell(l10n.amountDeviationDiffSumLabel, fmt(s.diffSum),
                color: diffColor),
            cell(l10n.amountDeviationMaxDiffLabel,
                s.maxAbsDiff.toStringAsFixed(2)),
          ]),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              l10n.amountDeviationBottomFillHint,
              style: PiggyTextTokens.caption(context)
                  .copyWith(color: PiggyTokens.textTertiary(context)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _trendChart(
      BuildContext context, AppLocalizations l10n, _DeviationData data) {
    final maxAbs = data.trend.fold<double>(
        0, (m, e) => math.max(m, e.diffSum.abs()));
    if (maxAbs == 0) {
      return SizedBox(
        height: 60,
        child: Center(
          child: Text(l10n.amountDeviationNoDiff,
              style: PiggyTextTokens.caption(context)
                  .copyWith(color: PiggyTokens.textTertiary(context))),
        ),
      );
    }
    final labelFmt = data.granularity == 'month'
        ? DateFormat('MM')
        : DateFormat('dd');
    return SizedBox(
      height: 150,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final e in data.trend)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 1),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    // 柱高按 |diffSum| / maxAbs 归一；正偏差支出色、负偏差收入色。
                    Container(
                      height: 4 + 100 * (e.diffSum.abs() / maxAbs),
                      decoration: BoxDecoration(
                        color: e.diffSum >= 0
                            ? PiggyTokens.expenseColor(context, ref)
                            : PiggyTokens.incomeColor(context, ref),
                        borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                      ),
                    ),
                    const SizedBox(height: 4),
                    if (data.trend.length <= 16)
                      Text(
                        labelFmt.format(e.bucket),
                        style: PiggyTextTokens.caption(context).copyWith(
                            fontSize: 9,
                            color: PiggyTokens.textTertiary(context)),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _categoryRanking(
      BuildContext context, AppLocalizations l10n, _DeviationData data) {
    final cats = [...data.cats]
      ..sort((a, b) => b.absDiffSum.compareTo(a.absDiffSum));
    final maxAbs = cats.first.absDiffSum;
    String fmt(double v) =>
        '${v >= 0 ? '+' : '−'}${v.abs().toStringAsFixed(2)}';
    return Column(
      children: [
        for (final c in cats.take(8))
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.categoryName ?? l10n.commonUncategorized,
                        style: PiggyTextTokens.body(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      fmt(c.diffSum),
                      style: PiggyTextTokens.caption(context).copyWith(
                        color: c.diffSum >= 0
                            ? PiggyTokens.expenseColor(context, ref)
                            : PiggyTokens.incomeColor(context, ref),
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                  child: LinearProgressIndicator(
                    value: maxAbs == 0 ? 0 : c.absDiffSum / maxAbs,
                    minHeight: 6,
                    backgroundColor: PiggyTokens.surfaceInput(context),
                    valueColor: AlwaysStoppedAnimation<Color>(
                        PiggyTokens.primary(context)),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }

  Widget _insightList(
      BuildContext context, AppLocalizations l10n, _DeviationData data) {
    Color severityColor(OriginalAmountSeverity s) {
      switch (s) {
        case OriginalAmountSeverity.slight:
          return PiggyTokens.textTertiary(context);
        case OriginalAmountSeverity.notable:
          return PiggyTokens.primary(context);
        case OriginalAmountSeverity.severe:
          return PiggyTokens.expenseColor(context, ref);
      }
    }

    return Column(
      children: [
        for (final ins in data.insights)
          InkWell(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            onTap: () {
              final tx = data.txById[ins.transactionId];
              if (tx == null) return;
              TransactionEditUtils.editTransaction(
                  context, ref, tx, data.catById[ins.transactionId]);
            },
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Container(
                    margin: const EdgeInsets.only(top: 2),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: severityColor(ins.severity).withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                    ),
                    child: Text(
                      _severityText(l10n, ins.severity),
                      style: PiggyTextTokens.caption(context).copyWith(
                        color: severityColor(ins.severity),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          // 箭头方向跟随基准：记账基准 =「原始 → 记账」，
                          // 原始基准 =「记账 → 原始」，与差异的正负含义一致。
                          ref.read(originalAmountBasisProvider) ==
                                  OriginalAmountBasis.recorded
                              ? '${ins.originalAmount.toStringAsFixed(2)}'
                                  ' → ${ins.recordedAmount.toStringAsFixed(2)}'
                              : '${ins.recordedAmount.toStringAsFixed(2)}'
                                  ' → ${ins.originalAmount.toStringAsFixed(2)}',
                          style: PiggyTextTokens.body(context).copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _reasonText(l10n, ins.reasonCode),
                          style: PiggyTextTokens.caption(context).copyWith(
                              color: PiggyTokens.textSecondary(context)),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded,
                      size: 18, color: PiggyTokens.textTertiary(context)),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// 页面一次加载的全部数据（避免 widget 内散落多个 FutureBuilder）。
class _DeviationData {
  final ({
    int total,
    int deviated,
    double diffSum,
    double absDiffSum,
    double maxAbsDiff,
  }) summary;
  final List<
      ({
        DateTime bucket,
        int deviated,
        double diffSum,
        double absDiffSum,
      })> trend;
  final List<
      ({
        int? categoryId,
        String? categoryName,
        String? categoryIcon,
        int deviated,
        double diffSum,
        double absDiffSum,
      })> cats;
  final List<OriginalAmountInsight> insights;
  final String granularity;
  final Map<int, db.Transaction> txById;
  final Map<int, db.Category?> catById;

  const _DeviationData({
    required this.summary,
    required this.trend,
    required this.cats,
    required this.insights,
    required this.granularity,
    required this.txById,
    required this.catById,
  });
}
