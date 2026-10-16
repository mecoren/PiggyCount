import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/models/analytics_amount_metric.dart';
import '../../l10n/app_localizations.dart';
import '../../pages/analytics/custom_field_analysis_page.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../services/custom_field_stats_service.dart';
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import 'custom_field_stats_view.dart';

/// 洞察页「自定义字段汇总」卡（自取数据）。
///
/// 显示条件（prd/analytics_custom_field_card F1/F2）：
/// - 结余视角隐藏（与分类构成/排行榜同口径）；
/// - 聚合为空（无定义或无值行）不渲染，无空态占位。
///
/// 数据经 [customFieldStatsForRangeProvider] 自取（键含 refreshTick），刻意
/// 不并入主链路 `List<dynamic>` 位次表 —— 位次表是卡片注册表批次的收编对象，
/// 这里再插位次只会先恶化再重构（见 design.md 决策 1）。
class CustomFieldStatsCard extends ConsumerWidget {
  const CustomFieldStatsCard({
    super.key,
    required this.start,
    required this.end,
    required this.type,
    required this.amountMetric,
  });

  final DateTime start;
  final DateTime end;

  /// 洞察视角：'expense' | 'income' | 'balance'（balance 隐藏本卡）。
  /// 同时作为值桶排序/金额展示维度（expense/income）。
  final String type;

  /// 金额口径：卡内金额列与页面其余卡片同源（原始金额口径下本卡也按原始金额）。
  final AnalyticsAmountMetric amountMetric;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (type == 'balance') return const SizedBox.shrink();
    final fields =
        ref.watch(customFieldStatsForRangeProvider((
          ledgerId: ref.watch(currentLedgerIdProvider),
          start: start,
          end: end,
          refreshTick: ref.watch(statsRefreshProvider),
          amountMetric: amountMetric,
        )))
            .when(
      data: (d) => d,
      loading: () => const <CustomFieldFieldStats>[],
      // 附属卡失败不拖垮主链路：落日志、不渲染（不吞错 —— 禁空 catch 约束）。
      error: (e, st) {
        logger.warning('洞察', '自定义字段汇总卡聚合失败: $e\n$st');
        return const <CustomFieldFieldStats>[];
      },
    );
    if (fields.isEmpty) return const SizedBox.shrink();

    // 卡片铬对齐洞察页既有卡片样式（accent 竖条 + 主色描边）。
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 14, 12, 8),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        border: Border.all(
          color: ref.watch(primaryColorProvider),
          width: 1.5,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 3,
                height: 14,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: PiggyTokens.primary(context),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
                ),
              ),
              Text(
                AppLocalizations.of(context).rangeReportCustomFieldTitle,
                style: PiggyTextTokens.strongTitle(context),
              ),
              const Spacer(),
              // F2 下钻入口（R5：值桶渲染逐像素不动，仅追加入口）。
              Semantics(
                button: true,
                label: AppLocalizations.of(context).customFieldAnalysisEntry,
                child: InkWell(
                  key: const Key('custom-field-analysis-entry'),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                  onTap: () {
                    Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CustomFieldAnalysisPage(
                          start: start,
                          end: end,
                          type: type,
                          amountMetric: amountMetric,
                        ),
                      ),
                    );
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        AppLocalizations.of(context).customFieldAnalysisEntry,
                        style: PiggyTextTokens.caption(context).copyWith(
                            color: PiggyTokens.textLink(context)),
                      ),
                      const SizedBox(width: 2),
                      Icon(Icons.chevron_right,
                          size: 16, color: PiggyTokens.textLink(context)),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          CustomFieldStatsView(fields: fields, dim: type),
        ],
      ),
    );
  }
}
