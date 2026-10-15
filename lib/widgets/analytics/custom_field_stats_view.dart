import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/custom_field_stats_service.dart';
import '../../styles/tokens.dart';
import '../biz/biz.dart';

/// 自定义字段值桶分布（内容区，不含卡片铬）——区间报表与洞察页共用。
///
/// 自 `range_report_page.dart` 的 `_customFieldStats/_customFieldValueRows` 抽出，
/// 渲染口径原样保留：按 [dim]（'income'|'expense'）金额降序取桶、topN=8、
/// 超出合并「其他」、笔数走 `analyticsTxCountShort`、金额走 [AmountText]。
/// 文字一律走 PiggyTextTokens —— 不新增 fontSize 字面量（U1 ratchet）。
///
/// 卡片铬（标题栏/描边）留在各页自持：洞察页是 accent 竖条标题，区间报表是
/// 区段卡标题，差异大、不值得抽象。显示条件（非空才出卡）由调用方负责。
class CustomFieldStatsView extends StatelessWidget {
  const CustomFieldStatsView({
    super.key,
    required this.fields,
    required this.dim,
  });

  /// 聚合结果（`CustomFieldStatsService.aggregate` 输出）。
  final List<CustomFieldFieldStats> fields;

  /// 排序与金额展示维度：'income' | 'expense'（沿用 `sorted(dim)` 约定）。
  final String dim;

  /// 单字段最多展示的值桶数，超出合并「其他」。
  static const int topN = 8;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final field in fields) ...[
          Padding(
            padding: const EdgeInsets.only(top: 6, bottom: 2),
            child: Text(field.name, style: PiggyTextTokens.strongTitle(context)),
          ),
          ..._valueRows(context, l10n, field),
        ],
      ],
    );
  }

  List<Widget> _valueRows(BuildContext context, AppLocalizations l10n,
      CustomFieldFieldStats field) {
    final all = field.sorted(dim);
    final shown = all.take(topN).toList();
    final rest = all.skip(topN).toList();
    ({double income, double expense, int count}) mergeRest(
        List<({String label, double income, double expense, int count})> src) {
      var income = 0.0, expense = 0.0, count = 0;
      for (final b in src) {
        income += b.income;
        expense += b.expense;
        count += b.count;
      }
      return (income: income, expense: expense, count: count);
    }

    final buckets = [...shown];
    if (rest.isNotEmpty) {
      final merged = mergeRest(rest);
      buckets.add((
        label: l10n.commonOther,
        income: merged.income,
        expense: merged.expense,
        count: merged.count
      ));
    }
    return [
      for (final b in buckets)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              Expanded(
                child: Text(b.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: PiggyTextTokens.body(context)),
              ),
              const SizedBox(width: 6),
              Text(l10n.analyticsTxCountShort(b.count),
                  style: PiggyTextTokens.caption(context)
                      .copyWith(color: PiggyTokens.textTertiary(context))),
              const SizedBox(width: 12),
              AmountText(
                value: dim == 'income' ? b.income : b.expense,
                signed: false,
                showCurrency: true,
                useCompactFormat: true,
                style: PiggyTextTokens.strongTitle(context),
              ),
            ],
          ),
        ),
    ];
  }
}
