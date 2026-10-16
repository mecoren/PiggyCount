import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../data/models/analytics_time_metric.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../styles/tokens.dart';
import '../ui/ui.dart';
import 'metric_segment.dart';

/// 统计时间口径 chip：显示当前口径，点开底部抽屉单选。
///
/// 两个选项来源：
/// 1. 记账时间（默认，与洞察页历史行为逐字一致）；
/// 2. **日期型自定义字段**（逐个字段一项，按当前账本的定义列出）。
///
/// 与 [AmountMetricChip] 同款交互（chip + [showPiggyOptionSheet] 抽屉）：
/// 洞察页头部已有「档位 / 周期 / 收支」三行，这个口径是低频切换项，收进抽屉
/// 即可，不再压第四行常驻。两枚 chip 并排在标题行右侧，故本 chip 在
/// **没有可用的日期型字段时整个不渲染** —— 不给一个点开只有「记账时间」一项
/// 的入口，也不白占标题行的宽度。
///
/// 口径值存在全局 [analyticsTimeMetricProvider]（持久化），所以它在重启后
/// 保留；换到没有该字段的账本时由陈旧口径守卫回落默认（见下）。
class TimeMetricChip extends ConsumerWidget {
  const TimeMetricChip({
    super.key,
    this.compact = true,
    this.style = MetricChipStyle.pill,
  });

  /// 紧凑档：高度 30（与洞察页标题行的金额口径 chip / 圆形按钮齐平）。
  /// **仅 pill 形态生效**：轨道内的一段高度由轨道决定。
  final bool compact;

  /// 形态：独立描边胶囊（默认）或轨道内的一段（洞察页统计口径条）。
  final MetricChipStyle style;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final metric = ref.watch(analyticsTimeMetricProvider);
    final defsAsync = ref.watch(customFieldsForCurrentLedgerProvider);
    final supportAsync = ref.watch(customFieldAmountMetricSupportedProvider);
    // 探针取不到（加载中）按「可用」处理：不因启动瞬间的未知态把有效口径打回。
    final supported = supportAsync.value != false;
    final fields = dateFieldsOf(defsAsync.value);

    // 陈旧口径守卫：字段被删（或切到没有该字段的账本 / json 函数不可用）后，
    // 口径会指向一个取不到值的键 → 该口径下所有明细被过滤、页面读数全变 0。
    // 定义到手后校验一次并回落默认口径（加载中不判定，避免启动瞬间把有效口径
    // 打回默认）。落在 post-frame：build 期间不得改别的 provider。
    final sid = metric.fieldSyncId;
    final stale = sid != null &&
        (!supported ||
            (defsAsync.hasValue && !fields.any((d) => d.syncId == sid)));
    if (stale) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        ref.read(analyticsTimeMetricProvider.notifier).state =
            AnalyticsTimeMetric.happenedAt;
      });
    }

    // 没有可用的日期型字段、且当前就是默认口径 → 不渲染（无可用选项）。
    if (!supported || (fields.isEmpty && metric.isDefault)) {
      return const SizedBox.shrink();
    }

    // 非默认口径用主色强调：让「数字不是按记账时间算的」一眼可见。
    final isDefault = metric.isDefault;
    final fg = isDefault
        ? PiggyTokens.textSecondary(context)
        : PiggyTokens.primary(context);

    // 轨道内的一段（洞察页统计口径条）：非默认口径 = 主色胶囊，与金额口径
    // 那一段、下方分段控件的选中段同款。**用 `Expanded` 交出宽度**（口径条的
    // 几段等分），段宽因此不随文案长度变 —— 详见 [MetricSegment] 的类注释。
    // 本段隐藏时（无日期型字段）返回零宽的非 flex 子树，不占轨道里的槽位。
    if (style == MetricChipStyle.segment) {
      return Expanded(
        child: MetricSegment(
          key: const Key('time-metric-chip'),
          label: labelOf(l10n, metric, fields),
          active: !isDefault,
          onTap: () => showSheet(context, ref),
        ),
      );
    }

    final chip = Material(
      color: PiggyTokens.surface(context),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        side: BorderSide(color: PiggyTokens.borderThemed(context), width: 1.4),
      ),
      child: InkWell(
        key: const Key('time-metric-chip'),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        onTap: () => showSheet(context, ref),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: SizedBox(
            height: compact ? 30 : 36,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_outlined, size: 14, color: fg),
                const SizedBox(width: 4),
                Text(
                  labelOf(l10n, metric, fields),
                  style: TextStyle(
                    fontSize:
                        compact ? PiggyTextTokens.fs12 : PiggyTextTokens.fs13,
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

    // 与左邻的金额口径 chip 留 6 的间隔（两枚都是描边胶囊，贴在一起会被看成一
    // 个分段控件）。间隔加在「不渲染」分支之后 —— 本 chip 隐藏时不留空档。
    return Padding(padding: const EdgeInsets.only(left: 6), child: chip);
  }

  /// 打开统计时间口径抽屉（pill 形态与轨内段形态共用同一份选项与语义）。
  static Future<void> showSheet(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final metric = ref.read(analyticsTimeMetricProvider);
    final fields =
        dateFieldsOf(ref.read(customFieldsForCurrentLedgerProvider).value);
    await showPiggyOptionSheet<AnalyticsTimeMetric>(
      context: context,
      title: l10n.analyticsTimeMetricTitle,
      selected: metric,
      options: [
        PiggyOptionSheetItem(
          value: AnalyticsTimeMetric.happenedAt,
          title: l10n.analyticsTimeMetricHappenedAt,
          desc: l10n.analyticsTimeMetricHappenedAtDesc,
          icon: Icons.schedule,
        ),
        // 日期型自定义字段：一个字段一项（描述里点明「未填写不参与统计」
        // —— 这是该口径与默认口径最容易踩的语义差异）。
        for (final f in fields)
          PiggyOptionSheetItem(
            value: AnalyticsTimeMetric.customField(f.syncId!),
            title: f.name,
            desc: l10n.analyticsTimeMetricCustomFieldDesc(f.name),
            icon: Icons.event_outlined,
          ),
      ],
      onSelected: (v) =>
          ref.read(analyticsTimeMetricProvider.notifier).state = v,
    );
  }

  /// 当前账本的**日期型**自定义字段（`date` 类型且有 syncId）—— 只有这类
  /// 字段的值是一条时间；文本 / 金额 / 单选 / 多选的「值」不是日期。
  static List<CustomFieldDefinition> dateFieldsOf(
          List<CustomFieldDefinition>? defs) =>
      [
        for (final d in defs ?? const <CustomFieldDefinition>[])
          if (d.fieldType == CustomFieldType.date &&
              (d.syncId ?? '').isNotEmpty)
            d,
      ];

  /// chip 文案：默认口径取固定文案，字段口径取字段名（定义未到手时退化为
  /// 「自定义字段」，到手后即变字段名）。
  static String labelOf(AppLocalizations l10n, AnalyticsTimeMetric metric,
      List<CustomFieldDefinition> fields) {
    for (final d in fields) {
      if (d.syncId == metric.fieldSyncId) return d.name;
    }
    if (metric.isDefault) return l10n.analyticsTimeMetricHappenedAt;
    return l10n.analyticsTimeMetricCustomField;
  }
}

/// 非默认时间口径时的口径说明行（内容区顶部的小字）。
///
/// 必须写清的**排除**语义：未填写该字段的明细不参与统计（不是回落到记账时间，
/// 也不是算 0）—— 否则用户会以为「总额变少 = 少算了」。
///
/// 默认口径下返回零高占位，不占版面。
class TimeMetricNote extends ConsumerWidget {
  const TimeMetricNote({
    super.key,
    this.padding = const EdgeInsets.fromLTRB(16, 4, 16, 0),
  });

  /// 外层内边距：页面级独立一行用默认值；嵌在行内传 `EdgeInsets.only(left: 8)`。
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final metric = ref.watch(analyticsTimeMetricProvider);
    if (metric.isDefault) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: padding,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Text(
          l10n.analyticsTimeMetricNote,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: PiggyTextTokens.caption(context),
        ),
      ),
    );
  }
}
