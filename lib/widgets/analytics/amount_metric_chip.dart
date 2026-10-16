import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/models/analytics_amount_metric.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../styles/tokens.dart';
import '../ui/ui.dart';

/// 金额口径 chip：显示当前口径，点开底部抽屉单选。
///
/// 三个选项来源：
/// 1. 记账金额（默认）；
/// 2. 原始金额；
/// 3. **金额型自定义字段**（逐个字段一项，按当前账本的定义列出）。
///
/// 为什么是 chip + 抽屉而不是再压一行分段胶囊：洞察页头部已有「档位 / 周期 /
/// 收支」三行，第四行常驻会再吃掉一截首屏高度；而这个口径是低频切换项，
/// 收进抽屉即可（与项目「选择器抽屉统一口径」一致，走 [showPiggyOptionSheet]）。
///
/// 口径值存在全局 [analyticsAmountMetricProvider]（持久化），所以洞察页、
/// 区间报表、导出页上的同一枚 chip 改的是同一个值 —— 读数到哪都一致。
class AmountMetricChip extends ConsumerWidget {
  const AmountMetricChip({super.key, this.compact = true});

  /// 紧凑档：高度 30（与洞察页导航行的圆形箭头 / 收支胶囊齐平）。
  /// 传 false 时高度 36，用于报表页的常规行。
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final metric = ref.watch(analyticsAmountMetricProvider);
    final defsAsync = ref.watch(customFieldsForCurrentLedgerProvider);
    final supportAsync = ref.watch(customFieldAmountMetricSupportedProvider);
    final fields = amountFieldsOf(defsAsync.value);

    // 陈旧口径守卫：字段被删（或切到没有该字段的账本）后，口径会指向一个
    // 取不到值的键 → 该口径下所有明细被过滤、页面读数全变 0。定义到手后校验
    // 一次并回落默认口径（加载中不判定，避免启动瞬间把有效口径打回默认）。
    // 落在 post-frame：build 期间不得改别的 provider。
    final sid = metric.fieldSyncId;
    // 探针取不到（加载中）按「可用」处理：不因启动瞬间的未知态把有效口径打回。
    final supported = supportAsync.value != false;
    final stale = sid != null &&
        (!supported ||
            (defsAsync.hasValue && !fields.any((d) => d.syncId == sid)));
    if (stale) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(analyticsAmountMetricProvider.notifier).state =
            AnalyticsAmountMetric.recorded;
      });
    }

    // 非默认口径用主色强调：让「数字不是按记账金额算的」一眼可见。
    final isDefault = metric.isDefault;
    final fg = isDefault
        ? PiggyTokens.textSecondary(context)
        : PiggyTokens.primary(context);

    return Material(
      color: PiggyTokens.surface(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        side: BorderSide(color: PiggyTokens.borderThemed(context), width: 1.4),
      ),
      child: InkWell(
        key: const Key('amount-metric-chip'),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        onTap: () async {
          // 探针在开抽屉前取（通常已就绪，毫秒级）：json 函数不可用时
          // 不提供自定义字段选项，而不是给一个必然读数为 0 的口径。
          final supported = await ref
              .read(customFieldAmountMetricSupportedProvider.future)
              .catchError((_) => false);
          if (!context.mounted) return;
          await showPiggyOptionSheet<AnalyticsAmountMetric>(
            context: context,
            title: l10n.analyticsAmountMetricTitle,
            selected: metric,
            options: [
              PiggyOptionSheetItem(
                value: AnalyticsAmountMetric.recorded,
                title: l10n.analyticsAmountMetricRecorded,
                desc: l10n.analyticsAmountMetricRecordedDesc,
                icon: Icons.account_balance_wallet_outlined,
              ),
              PiggyOptionSheetItem(
                value: AnalyticsAmountMetric.original,
                title: l10n.analyticsAmountMetricOriginal,
                desc: l10n.analyticsAmountMetricOriginalDesc,
                icon: Icons.receipt_long_outlined,
              ),
              // 金额型自定义字段：一个字段一项（描述里点明「未填写不参与
              // 统计」—— 这是该口径与前两者最容易踩的语义差异）。
              if (supported)
                for (final f in fields)
                  PiggyOptionSheetItem(
                    value: AnalyticsAmountMetric.customField(f.syncId!),
                    title: f.name,
                    desc: l10n.analyticsAmountMetricCustomFieldDesc(f.name),
                    icon: Icons.sell_outlined,
                  ),
            ],
            onSelected: (v) =>
                ref.read(analyticsAmountMetricProvider.notifier).state = v,
          );
        },
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: SizedBox(
            height: compact ? 30 : 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.tune, size: 14, color: fg),
                const SizedBox(width: 4),
                Text(
                  labelOf(l10n, metric, fields),
                  style: TextStyle(
                    fontSize: compact
                        ? PiggyTextTokens.fs12
                        : PiggyTextTokens.fs13,
                    color: fg,
                    fontWeight: isDefault ? FontWeight.w400 : FontWeight.w600,
                  ),
                ),
                Icon(Icons.expand_more, size: 15, color: fg),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// 当前账本的**金额型**自定义字段（`amount` 类型且有 syncId）—— 只有这类
  /// 字段有可求和的金额；文本 / 日期 / 单选 / 多选的「值」不是金额。
  static List<CustomFieldDefinition> amountFieldsOf(
          List<CustomFieldDefinition>? defs) =>
      [
        for (final d in defs ?? const <CustomFieldDefinition>[])
          if (d.fieldType == CustomFieldType.amount &&
              (d.syncId ?? '').isNotEmpty)
            d,
      ];

  /// chip 文案：内置口径取固定文案，自定义字段口径取字段名（定义未到手时
  /// 退化为「自定义字段」，到手后即变字段名）。
  static String labelOf(AppLocalizations l10n, AnalyticsAmountMetric metric,
      List<CustomFieldDefinition> fields) {
    for (final d in fields) {
      if (d.syncId == metric.fieldSyncId) return d.name;
    }
    if (metric == AnalyticsAmountMetric.recorded) {
      return l10n.analyticsAmountMetricRecorded;
    }
    if (metric == AnalyticsAmountMetric.original) {
      return l10n.analyticsAmountMetricOriginal;
    }
    return l10n.analyticsAmountMetricCustomField;
  }
}

/// 非默认口径时的口径说明行（内容区顶部的小字）。
///
/// - 原始金额口径：说明必须写清的兜底语义（未填写即按记账金额计），不写清楚
///   用户会以为「数字变小 = 丢数据」；
/// - 自定义字段口径：说明必须写清的**排除**语义（未填写该字段的明细不参与
///   统计），否则用户会以为「总额变少 = 少算了」。
///
/// 默认口径下返回零高占位，不占版面。
class AmountMetricNote extends ConsumerWidget {
  const AmountMetricNote({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 0),
  });

  /// 外层内边距：页面级独立一行用默认值；嵌在行内（如区间报表的口径行）
  /// 传 `EdgeInsets.only(left: 8)`。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final metric = ref.watch(analyticsAmountMetricProvider);
    if (metric.isDefault) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          metric.fieldSyncId == null
              ? l10n.analyticsAmountMetricNote
              : l10n.analyticsAmountMetricNoteCustomField,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PiggyTextTokens.caption(context),
        ),
      ),
    );
  }
}
