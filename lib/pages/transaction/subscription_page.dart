import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show SchedulerPhase;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart' show primaryColorProvider;
import '../../providers/subscription_providers.dart';
import '../../services/data/recurring_transaction_service.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../utils/pinned_summary_progress.dart';
import '../../utils/subscription_estimate.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/amount_text.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/category_icon.dart';
import '../../widgets/ui/ui.dart';
import 'recurring_transaction_edit_page.dart';

/// 订阅管理页 —— 周期账单的派生视图（零识别）。
///
/// 收录「当前账本启用中的支出型周期账单」，展示年支出 / 月均与下次扣款日；
/// 条目点击直接进对应周期账单编辑页。见
/// prd/subscription_and_overspend_alerts/requirements.md §4.1。
///
/// 版式与 [BudgetPage] / [CategoryBudgetTile] 同款：页面壳
/// （`PiggyTokens.scaffoldBackground` + `PiggyTitleBar` + `topScrollablePadding`）
/// → 一张 `SectionCard`（主题色描边）装汇总、一张装列表、条目用
/// `InkWell` + `.scaled()` 间距；间距/图标尺寸一律走 `ui_scale_extensions`。
///
/// 汇总卡随列表滚动：整块滑进标题栏后面之后，「年支出 / 月均 / 订阅数」在
/// 「订阅管理」右边淡入（标题栏本身是磨砂层，天然带模糊底），总览数字不会
/// 因为卡片滚走而看不到。判据与资产页同源（[pinnedSummaryProgress]）。
class SubscriptionPage extends ConsumerStatefulWidget {
  const SubscriptionPage({super.key});

  @override
  ConsumerState<SubscriptionPage> createState() => _SubscriptionPageState();
}

class _SubscriptionPageState extends ConsumerState<SubscriptionPage> {
  /// 汇总卡的锚点：滑动时用它判定「整块是否已滚进标题栏后面」。
  final GlobalKey _summaryKey = GlobalKey();

  /// 标题行紧凑汇总的折叠进度（0 = 完全隐藏，1 = 完全显示）。
  /// 用 ValueNotifier 而不是 setState：滚动每帧都变，只让标题栏那一小块重建，
  /// 长订阅列表不跟着逐帧重排。
  final ValueNotifier<double> _pinnedProgress = ValueNotifier<double>(0);

  final ScrollController _scrollController = ScrollController();
  bool _pinnedMeasureScheduled = false;

  /// 汇总卡底边在**内容坐标**里的位置（不随滚动变化）。
  ///
  /// 必须缓存：ListView 懒加载会把滚出缓存的汇总卡整块卸载，`GlobalKey` 那时
  /// 拿不到 RenderBox —— 若此时把进度归零，标题栏里的汇总会在滑到深处时突然
  /// 消失。
  double? _summaryContentBottom;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScrollForPinnedSummary);
  }

  @override
  void dispose() {
    _scrollController
      ..removeListener(_onScrollForPinnedSummary)
      ..dispose();
    _pinnedProgress.dispose();
    super.dispose();
  }

  void _onScrollForPinnedSummary() {
    // 布局阶段（如内容变短被 correctPixels 夹回）里改 notifier 会撞
    // markNeedsBuild during layout，退到帧后再算。
    if (WidgetsBinding.instance.schedulerPhase ==
        SchedulerPhase.persistentCallbacks) {
      _schedulePinnedMeasure();
      return;
    }
    _applyPinnedProgress();
  }

  /// 按**上次实测**的汇总卡底边算进度。
  ///
  /// 这里刻意不测量：滚动通知发生在手势阶段，渲染树里的位置还是上一帧的
  /// （view 尚未按新 offset 重排），「旧全局坐标 + 新滚动偏移」会把底边缓存成
  /// 一个偏大的值（一次大幅滑动就是几百像素），进度从此永远停在 0、标题栏
  /// 汇总再也不出现。底边是内容坐标（不随滚动变化），只需在布局提交后测一次。
  void _applyPinnedProgress() {
    if (!mounted) return;
    final contentBottom = _summaryContentBottom;
    if (contentBottom == null) {
      // 尚未量到（还在 loading / 空态无汇总卡）：不显示紧凑汇总。
      _pinnedProgress.value = 0;
      return;
    }
    final offset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    _pinnedProgress.value = pinnedSummaryProgress(
      blockBottom: contentBottom - offset,
      appBarBottom: PiggyTokens.topScrollablePadding(context),
    );
  }

  /// 帧后补测汇总卡位置：数据到位 / 外币提示行出现都会改它的高度，
  /// 只在同帧没排过队时测一次。
  void _schedulePinnedMeasure() {
    if (_pinnedMeasureScheduled) return;
    _pinnedMeasureScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _pinnedMeasureScheduled = false;
      if (!mounted) return;
      _measurePinnedBlock();
      _applyPinnedProgress();
    });
  }

  /// 布局提交后实测「汇总卡底边的内容坐标」。
  ///
  /// extendBodyBehindAppBar 下 body 从屏幕顶部开始，全局坐标可直接换算：
  /// 内容坐标 = 全局坐标 + 当前滚动偏移。
  void _measurePinnedBlock() {
    final box = _summaryKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null || !box.attached || !box.hasSize) return;
    final offset =
        _scrollController.hasClients ? _scrollController.offset : 0.0;
    _summaryContentBottom =
        box.localToGlobal(Offset.zero).dy + box.size.height + offset;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final overviewAsync = ref.watch(subscriptionOverviewProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        // 标题行自带「年支出 / 月均 / 订阅数」紧凑汇总：汇总卡滑进标题栏后面
        // 之后淡入。preferredSize 不变，出现/消失不会让 body 重排。
        titleWidget: _SubscriptionTitleSummary(
          title: l10n.subscriptionPageTitle,
          progress: _pinnedProgress,
        ),
        showBack: true,
        actions: [
          // 与周期记账页 / 预算页同款：标题栏右侧「+」直达新建表单
          IconButton(
            onPressed: () => _createSubscription(context, ref),
            icon: const Icon(Icons.add),
            tooltip: l10n.recurringTransactionAdd,
          ),
        ],
      ),
      // 标题栏避让做进列表自身 padding（不能包在 body 外）：
      // 否则滚动视口从标题栏下沿开始，内容穿不到标题栏后面，磨砂无内容可模糊。
      body: RefreshIndicator(
        onRefresh: () async {
          PiggyHaptics.light();
          ref.invalidate(subscriptionOverviewProvider);
          try {
            await ref.read(subscriptionOverviewProvider.future);
          } catch (_) {
            // 失败保持静默，错误分支由 when 展示
          }
        },
        child: overviewAsync.when(
          // skipLoading*: 下拉刷新后保留旧数据渲染，避免整页闪 loading
          skipLoadingOnReload: true,
          skipLoadingOnRefresh: true,
          loading: () => Center(
            child: PiggySpinner(
              size: 36,
              color: PiggyTokens.primary(context),
            ),
          ),
          error: (error, stack) => Center(
            child: Text('${l10n.commonFailed}: $error'),
          ),
          data: (overview) {
            if (overview.items.isEmpty) {
              return Padding(
                padding: EdgeInsets.only(
                  top: PiggyTokens.topScrollablePadding(context),
                ),
                child: _EmptyView(
                  onCreate: () => _createSubscription(context, ref),
                ),
              );
            }
            // 数据到位 / 外币提示行出现都会改汇总卡高度，帧后补测一次进度。
            _schedulePinnedMeasure();
            return ListView(
              controller: _scrollController,
              // top 含标题栏避让，滚动内容可从标题栏下方穿过
              padding: EdgeInsets.only(
                left: 12.0.scaled(context, ref),
                right: 12.0.scaled(context, ref),
                top: PiggyTokens.topScrollablePadding(context) +
                    8.0.scaled(context, ref),
                bottom: 8.0.scaled(context, ref),
              ),
              // AlwaysScrollable: 内容不满一屏时也能下拉刷新
              physics: const AlwaysScrollableScrollPhysics(),
              children: [
                // 用 KeyedSubtree 挂锚点：标题行汇总靠它的底边判定是否已滚进
                // 标题栏后面。
                KeyedSubtree(
                  key: _summaryKey,
                  child: _SummaryCard(summary: overview.summary),
                ),
                SizedBox(height: 12.0.scaled(context, ref)),
                SectionCard(
                  margin: EdgeInsets.zero,
                  borderColor: ref.watch(primaryColorProvider),
                  child: Column(
                    children: [
                      for (final item in overview.items)
                        _SubscriptionTile(
                          item: item,
                          baseCurrency: overview.summary.currencyCode,
                          onTap: () async {
                            final result = await showRecurringFormBottomSheet(
                              context,
                              recurring: item.recurring,
                            );
                            if (result == true) {
                              ref.invalidate(subscriptionOverviewProvider);
                            }
                          },
                        ),
                    ],
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// 新建订阅（= 新建支出型周期账单）：走周期账单的统一表单抽屉，返回 true 即刷新。
Future<void> _createSubscription(BuildContext context, WidgetRef ref) async {
  final result = await showRecurringFormBottomSheet(context);
  if (result == true) {
    ref.invalidate(subscriptionOverviewProvider);
  }
}

/// 空态：引导去创建支出型周期账单（按钮样式同 [BudgetPage] 空态）。
class _EmptyView extends StatelessWidget {
  final VoidCallback onCreate;

  const _EmptyView({required this.onCreate});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return LayoutBuilder(
      builder: (context, constraints) => SingleChildScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        child: ConstrainedBox(
          constraints: BoxConstraints(minHeight: constraints.maxHeight),
          child: AppEmpty(
            text: l10n.subscriptionEmpty,
            subtext: l10n.subscriptionEmptyHint,
            icon: Icons.subscriptions_outlined,
            action: ElevatedButton.icon(
              onPressed: onCreate,
              icon: Icon(Icons.add,
                  color: PiggyTokens.buttonPrimaryText(context)),
              label: Text(l10n.subscriptionEmptyAction),
              style: ElevatedButton.styleFrom(
                backgroundColor: PiggyTokens.buttonPrimary(context),
                foregroundColor: PiggyTokens.buttonPrimaryText(context),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 标题行内的汇总：「订阅管理」右边淡入「年支出 / 月均 / 订阅数」。
///
/// 汇总卡整块滑进标题栏后面之后才出现 —— 它就在标题栏（磨砂层）内部，所以
/// 天然带着模糊底色。出现与否只重建这一段子树，标题栏 preferredSize 不变，
/// body 不会跟着重排。
class _SubscriptionTitleSummary extends ConsumerWidget {
  const _SubscriptionTitleSummary({
    required this.title,
    required this.progress,
  });

  final String title;
  final ValueListenable<double> progress;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final summary = ref.watch(subscriptionOverviewProvider).value?.summary;
    final hasSummary = summary != null && summary.count > 0;

    return Row(
      children: [
        // 与 PiggyTitleBar 内置标题同款字号 / 字重 / 颜色
        Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs17,
            fontWeight: FontWeight.w500,
            color: Theme.of(context).colorScheme.onSurface,
          ),
        ),
        Expanded(
          child: ValueListenableBuilder<double>(
            valueListenable: progress,
            builder: (context, value, child) {
              // 收起（或还没有汇总）时整块不建：否则「年支出 / 月均 / 共 N 个
              // 订阅」会在汇总卡和标题栏各出现一次，读屏会重复播报。
              if (!hasSummary || value <= 0) return const SizedBox.shrink();
              return Padding(
                padding: EdgeInsets.only(left: 8.0.scaled(context, ref)),
                child: Opacity(opacity: value, child: child),
              );
            },
            child: hasSummary
                ? _CompactSummaryRow(summary: summary)
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

/// 标题栏里的紧凑三栏：年支出 / 月均 / 订阅数。
///
/// 「订阅管理」右边只剩一百多 dp（还要给右上角的「+」让位），所以数值强制走
/// 大额缩写（万 / k / M），再套 FittedBox 缩字号兜底，绝不换行把标题栏撑高。
class _CompactSummaryRow extends ConsumerWidget {
  const _CompactSummaryRow({required this.summary});

  final SubscriptionSummary summary;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final divider = Container(
      width: 1,
      height: 20.0.scaled(context, ref),
      color: PiggyTokens.divider(context),
    );
    final valueStyle = TextStyle(
      fontSize: PiggyTextTokens.fs12,
      fontWeight: FontWeight.w600,
      color: PiggyTokens.textPrimary(context),
    );

    return Row(
      children: [
        Expanded(
          child: _CompactStatCell(
            label: l10n.subscriptionAnnualLabel,
            value: AmountText(
              value: summary.annualAmount,
              signed: false,
              showCurrency: true,
              useCompactFormat: true,
              currencyCode: summary.currencyCode,
              style: valueStyle,
            ),
          ),
        ),
        divider,
        Expanded(
          child: _CompactStatCell(
            label: l10n.subscriptionMonthlyLabel,
            value: AmountText(
              value: summary.monthlyAmount,
              signed: false,
              showCurrency: true,
              useCompactFormat: true,
              currencyCode: summary.currencyCode,
              style: valueStyle.copyWith(
                color: PiggyTokens.textSecondary(context),
              ),
            ),
          ),
        ),
        divider,
        Expanded(
          child: _CompactStatCell(
            label: l10n.subscriptionCountShort,
            value: Text('${summary.count}', style: valueStyle),
          ),
        ),
      ],
    );
  }
}

/// 紧凑汇总的一栏：一行小字标签 + 一行数值。
class _CompactStatCell extends StatelessWidget {
  const _CompactStatCell({required this.label, required this.value});

  final String label;
  final Widget value;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs10,
            color: PiggyTokens.textTertiary(context),
          ),
        ),
        const SizedBox(height: 1),
        FittedBox(fit: BoxFit.scaleDown, child: value),
      ],
    );
  }
}

/// 顶部汇总卡：年支出 / 月均 / 订阅数（+ 外币未计入提示）。
class _SummaryCard extends ConsumerWidget {
  final SubscriptionSummary summary;

  const _SummaryCard({required this.summary});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);

    return SectionCard(
      margin: EdgeInsets.zero,
      borderColor: ref.watch(primaryColorProvider),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.subscriptionCountLabel(summary.count),
            style: PiggyTextTokens.label(context)
                .copyWith(color: PiggyTokens.textTertiary(context)),
          ),
          SizedBox(height: 12.0.scaled(context, ref)),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: _SummaryMetric(
                  label: l10n.subscriptionAnnualLabel,
                  value: summary.annualAmount,
                  currencyCode: summary.currencyCode,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs20,
                    fontWeight: FontWeight.w700,
                    color: PiggyTokens.textPrimary(context),
                  ),
                ),
              ),
              Expanded(
                child: _SummaryMetric(
                  label: l10n.subscriptionMonthlyLabel,
                  value: summary.monthlyAmount,
                  currencyCode: summary.currencyCode,
                  style: TextStyle(
                    fontSize: PiggyTextTokens.fs16,
                    fontWeight: FontWeight.w600,
                    color: PiggyTokens.textSecondary(context),
                  ),
                ),
              ),
            ],
          ),
          if (summary.hasForeign) ...[
            SizedBox(height: 10.0.scaled(context, ref)),
            Text(
              l10n.subscriptionForeignHint(summary.foreignCount),
              style: TextStyle(
                fontSize: PiggyTextTokens.fs12,
                color: PiggyTokens.textTertiary(context),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SummaryMetric extends ConsumerWidget {
  final String label;
  final double value;
  final String currencyCode;
  final TextStyle style;

  const _SummaryMetric({
    required this.label,
    required this.value,
    required this.currencyCode,
    required this.style,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs12,
            color: PiggyTokens.textTertiary(context),
          ),
        ),
        SizedBox(height: 4.0.scaled(context, ref)),
        Align(
          alignment: Alignment.centerLeft,
          child: AmountText(
            value: value,
            signed: false,
            showCurrency: true,
            useCompactFormat: true,
            currencyCode: currencyCode,
            style: style,
          ),
        ),
      ],
    );
  }
}

/// 单条订阅（版式同 [CategoryBudgetTile]：36 图标盒 + 两行信息 + 右侧金额）。
class _SubscriptionTile extends ConsumerWidget {
  final SubscriptionItem item;
  final String baseCurrency;
  final VoidCallback onTap;

  const _SubscriptionTile({
    required this.item,
    required this.baseCurrency,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final primary = PiggyTokens.primary(context);

    final name = item.displayName ??
        (item.category != null
            ? CategoryUtils.getDisplayName(item.category!.name, context)
            : null) ??
        l10n.subscriptionUnknownName;

    final currencyCode =
        (item.recurring.currencyCode ?? baseCurrency).trim().toUpperCase();
    final nextDue = item.nextDueDate;
    final dueText = nextDue == null
        ? l10n.subscriptionNoNextDue
        : l10n.subscriptionNextDue(DateFormat.Md().format(nextDue));

    final subStyle = PiggyTextTokens.label(context)
        .copyWith(color: PiggyTokens.textTertiary(context));

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: Padding(
        padding: EdgeInsets.symmetric(
          vertical: 12.0.scaled(context, ref),
          horizontal: 4.0.scaled(context, ref),
        ),
        child: Row(
          children: [
            Container(
              width: 36.0.scaled(context, ref),
              height: 36.0.scaled(context, ref),
              decoration: BoxDecoration(
                color: primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(
                    PiggyDimens.radiusSm.scaled(context, ref)),
              ),
              alignment: Alignment.center,
              child: item.category != null
                  ? CategoryIconWidget(
                      category: item.category,
                      size: 20.0.scaled(context, ref),
                      color: primary,
                    )
                  : Icon(
                      Icons.subscriptions_outlined,
                      size: 20.0.scaled(context, ref),
                      color: primary,
                    ),
            ),
            SizedBox(width: 12.0.scaled(context, ref)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    name,
                    style: TextStyle(
                      fontSize: PiggyTextTokens.fs14,
                      fontWeight: FontWeight.w500,
                      color: PiggyTokens.textPrimary(context),
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: 4.0.scaled(context, ref)),
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _frequencyDescription(
                            l10n,
                            RecurringFrequency.fromString(
                                item.recurring.frequency),
                            item.recurring.interval,
                          ),
                          style: subStyle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      // 分隔点与周期账单列表同款（label 字号 + tertiary 色）
                      Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 6.0.scaled(context, ref)),
                        child: Text('·', style: subStyle),
                      ),
                      Flexible(
                        child: Text(
                          dueText,
                          style: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
                            color: nextDue == null
                                ? PiggyTokens.textTertiary(context)
                                : primary,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (item.isForeign) ...[
              SizedBox(width: 12.0.scaled(context, ref)),
              Text(
                currencyCode,
                style: TextStyle(
                  fontSize: PiggyTextTokens.fs12,
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textSecondary(context),
                ),
              ),
              SizedBox(width: 4.0.scaled(context, ref)),
            ] else
              SizedBox(width: 12.0.scaled(context, ref)),
            AmountText(
              value: item.recurring.amount,
              signed: false,
              decimals: 2,
              style: TextStyle(
                fontSize: PiggyTextTokens.fs16,
                fontWeight: FontWeight.w600,
                color: PiggyTokens.textPrimary(context),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _frequencyDescription(
    AppLocalizations l10n,
    RecurringFrequency frequency,
    int interval,
  ) {
    if (interval == 1) {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionDaily;
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionWeekly;
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionMonthly;
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionYearly;
      }
    } else {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionEveryNDays(interval);
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionEveryNWeeks(interval);
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionEveryNMonths(interval);
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionEveryNYears(interval);
      }
    }
  }
}
