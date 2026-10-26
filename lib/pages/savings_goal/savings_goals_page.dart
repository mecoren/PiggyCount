import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/savings_goal_progress.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/savings_goal/savings_goal_card.dart';
import '../../widgets/ui/ui.dart';
import '../budget/widgets/budget_progress_bar.dart';
import 'savings_goal_edit_page.dart';

/// 储蓄目标列表页（v53）。
///
/// 数据源单一：`savingsGoalProgressProvider`（目标 × 进度的解算结果）——
/// 页面不做金额计算，也不自己查账户余额（见 `lib/providers/savings_goal_providers.dart`）。
///
/// 版式与洞察页同款分层：**头部是覆盖层**（`PiggyHeader` 自带渐变磨砂），列表
/// 铺满整个 body 从屏幕顶开始滚 —— 汇总卡往上滑时会钻到磨砂层下面，磨砂才有
/// 内容可模糊；同一时刻「总目标 / 总已存」收进标题栏右上角的紧凑样式，
/// 总览数字不会因为滚走而看不到。
class SavingsGoalsPage extends ConsumerStatefulWidget {
  const SavingsGoalsPage({super.key});

  @override
  ConsumerState<SavingsGoalsPage> createState() => _SavingsGoalsPageState();
}

class _SavingsGoalsPageState extends ConsumerState<SavingsGoalsPage> {
  final ScrollController _scroll = ScrollController();

  /// 汇总金额「收进右上角」的进度：0 = 汇总卡里的数字完整可见，1 = 只剩标题栏
  /// 右侧的紧凑版。用 ValueNotifier 而不是 setState —— 滚动每帧都变，只让标题栏
  /// 那一小块重建，列表不跟着逐帧重建。
  final ValueNotifier<double> _collapse = ValueNotifier<double>(0);

  @override
  void initState() {
    super.initState();
    _scroll.addListener(_syncCollapse);
  }

  @override
  void dispose() {
    _scroll
      ..removeListener(_syncCollapse)
      ..dispose();
    _collapse.dispose();
    super.dispose();
  }

  void _syncCollapse() {
    final offset = _scroll.hasClients ? _scroll.offset : 0.0;
    // 汇总卡的数字在卡片顶部：滚 24~64dp 之间正好滑到标题栏磨砂层下沿。在这个
    // 区间淡入，再早会出现「同一个数字在上下两处并存」的重影。
    _collapse.value = ((offset - 24) / 40).clamp(0.0, 1.0);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final itemsAsync = ref.watch(savingsGoalProgressProvider);
    final summary = ref.watch(savingsGoalSummaryProvider).value;
    final currencyCode =
        ref.watch(currentLedgerProvider).value?.currency ?? 'CNY';
    final items = itemsAsync.value ?? const <SavingsGoalWithProgress>[];
    final hasSummary = summary != null && summary.totalCount > 0;

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      floatingActionButton: FloatingActionButton(
        onPressed: () => showSavingsGoalFormBottomSheet(context),
        // 只要一个「+」按钮，不带文字；按钮名走 tooltip（长按提示 + 无障碍朗读）
        tooltip: l10n.savingsGoalAddTitle,
        child: const Icon(Icons.add_rounded),
      ),
      body: Stack(
        children: [
          // 内容层：列表铺满整个 body，顶部留白由列表自己让出标题栏高度 ——
          // 视口从屏幕顶开始，卡片才穿得到磨砂层下面（包在 body 外就没这效果）。
          Positioned.fill(
            child: ListView(
              controller: _scroll,
              padding: EdgeInsets.only(
                // 标题栏下方留出呼吸位（与预算页口径一致），否则首卡顶边贴住标题栏下缘
                top: PiggyTokens.topScrollablePadding(
                  context,
                  extra: PiggyDimens.p8,
                ),
                // 给 FAB 留位 + 底部安全区
                bottom: 96 + MediaQuery.of(context).padding.bottom,
              ),
              children: [
                // 汇总卡随列表滚动（不再常驻）：滚走后由标题栏右上角的紧凑版接管
                if (hasSummary) ...[
                  _SummaryCard(summary: summary, currencyCode: currencyCode),
                  // SectionCard 只带水平 margin，卡与卡的纵向间距要在这里补，
                  // 否则汇总卡与列表卡上下贴死（间距口径取预算页的 12）
                  SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
                ],
                if (items.isEmpty && itemsAsync.hasValue)
                  Padding(
                    padding: EdgeInsets.only(
                      top: 48.0.scaled(context, ref),
                      left: 24.0.scaled(context, ref),
                      right: 24.0.scaled(context, ref),
                    ),
                    child: AppEmpty(
                      icon: Icons.savings_outlined,
                      text: l10n.savingsGoalEmpty,
                      subtext: l10n.savingsGoalEmptyHint,
                    ),
                  )
                else
                  SectionCard(
                    child: Column(
                      children: [
                        for (var i = 0; i < items.length; i++) ...[
                          if (i > 0)
                            Divider(
                                height: 1, color: PiggyTokens.divider(context)),
                          SavingsGoalCard(
                            item: items[i],
                            onTap: () => showSavingsGoalFormBottomSheet(
                              context,
                              goal: items[i].goal,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
              ],
            ),
          ),
          // 头部层：标题栏盖在列表之上，磨砂据此生效
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: _buildHeader(context, l10n, summary, currencyCode),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(BuildContext context, AppLocalizations l10n,
      SavingsGoalSummary? summary, String currencyCode) {
    final hasSummary = summary != null && summary.totalCount > 0;
    return PiggyHeader(
      child: SizedBox(
        // 与 PiggyTokens.topScrollablePadding 里的 kToolbarHeight 同源，
        // 列表的顶部留白才对得上头部高度
        height: kToolbarHeight,
        child: Padding(
          padding: PiggyDimens.headerHorizontal,
          child: Row(
            children: [
              IconButton(
                padding: const EdgeInsets.only(right: 8),
                icon: const Icon(Icons.arrow_back_rounded, size: 22),
                onPressed: () => Navigator.of(context).maybePop(),
              ),
              Expanded(
                child: Text(
                  l10n.savingsGoalPageTitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PiggyTextTokens.title(context),
                ),
              ),
              if (hasSummary)
                ConstrainedBox(
                  // 天花板：金额再长也只压缩自己，不许把标题挤没
                  constraints: BoxConstraints(
                    maxWidth: 168.0.scaled(context, ref),
                  ),
                  child: ValueListenableBuilder<double>(
                    valueListenable: _collapse,
                    builder: (context, progress, _) {
                      // 收敛到 0 时整块不建：「总目标 / 总已存」这两个词否则会
                      // 在页面上各出现两次（汇总卡里 + 标题栏里），读屏会重复播报
                      if (progress <= 0) return const SizedBox.shrink();
                      return Opacity(
                        opacity: progress,
                        child: Transform.translate(
                          // 从右侧滑入一点点：读起来是「收进右上角」，
                          // 而不是凭空多出一行字
                          offset: Offset(12 * (1 - progress), 0),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            // FittedBox 给子树的宽度约束是无界的，而紧凑汇总
                            // 用 Expanded 平分两栏 —— 必须自己带一个确定宽度。
                            child: SizedBox(
                              width: 148.0.scaled(context, ref),
                              child: _CompactSummary(
                                summary: summary,
                                currencyCode: currencyCode,
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 顶部汇总卡：总目标 / 总已存 / 总体进度 + 外币剔除提示。
///
/// **只汇总与账本本位币同币种的目标**（视图期没有可靠汇率，硬折会给出错误数字）；
/// 被剔除的外币目标数必须显式告诉用户，静默少算会被当成「App 算错了」。
class _SummaryCard extends ConsumerWidget {
  const _SummaryCard({required this.summary, required this.currencyCode});

  final SavingsGoalSummary summary;
  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final hide = ref.watch(hideAmountsProvider);
    // 汇总金额用 boldTitle（18 / w700，令牌里「大额数字」档）：比目标卡的
    // body 金额（14）大一档，汇总卡整体看起来才是「总览」而不是又一条明细
    final valueStyle = PiggyTextTokens.boldTitle(context);

    Widget metric(String label, double value) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: PiggyTextTokens.caption(context)),
            SizedBox(height: 4.0.scaled(context, ref)),
            AmountText(
              value: value,
              signed: false,
              showCurrency: true,
              currencyCode: currencyCode,
              useCompactFormat: true,
              hide: hide,
              style: valueStyle,
            ),
          ],
        );

    return SectionCard(
      // 主题色描边（去掉阴影）：汇总卡与下方普通列表卡区分开，
      // 外观口径同预算页「总预算卡」/ 持仓页汇总区
      borderColor: ref.watch(primaryColorProvider),
      child: Padding(
        // 水平 16（+ SectionCard 自身 12 = 28）：与下方目标卡的文字 / 进度条左缘
        // 对齐，两张卡的进度条起止点才落在同一条竖线上
        padding: EdgeInsets.symmetric(
          horizontal: PiggyDimens.p16.scaled(context, ref),
          vertical: PiggyDimens.p12.scaled(context, ref),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child:
                      metric(l10n.savingsGoalTotalTarget, summary.totalTarget),
                ),
                Expanded(
                  child: metric(l10n.savingsGoalTotalSaved, summary.totalSaved),
                ),
              ],
            ),
            SizedBox(height: PiggyDimens.p16.scaled(context, ref)),
            BudgetProgressBar(
              used: summary.totalSaved,
              budget: summary.totalTarget,
              showLabel: false,
              // 比目标卡的 8 更粗（同预算页「总预算卡」的 12）：汇总卡是主线，
              // 粗细差异让「总进度」与「单条进度」一眼分层
              height: 12,
              // 目标型进度：达成不报警（同目标卡口径）。
              positiveOverflow: true,
            ),
            if (summary.foreignCount > 0) ...[
              SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
              Row(
                children: [
                  Icon(
                    Icons.info_outline_rounded,
                    size: 14,
                    color: PiggyTokens.warning(context),
                  ),
                  SizedBox(width: PiggyDimens.p4.scaled(context, ref)),
                  Expanded(
                    child: Text(
                      l10n.savingsGoalForeignExcluded(summary.foreignCount),
                      style: PiggyTextTokens.caption(context)
                          .copyWith(color: PiggyTokens.warning(context)),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// 标题栏右上角的紧凑汇总：汇总卡往上滑走之后，「总目标 / 总已存」收到这里。
///
/// 版式与订阅管理页 / 资产页的标题行汇总一致：两栏「小字标签在上、金额在下」，
/// 中间一条竖分隔线（见 [PinnedTitleStat]）。此前是两行「标签 + 金额」横排，
/// 每行都要吃掉一大段宽度，右对齐的长金额更容易顶到标题。
/// 金额仍走 [AmountText]，跟随全局「隐藏金额」开关。
class _CompactSummary extends ConsumerWidget {
  const _CompactSummary({required this.summary, required this.currencyCode});

  final SavingsGoalSummary summary;
  final String currencyCode;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final hide = ref.watch(hideAmountsProvider);
    final valueStyle =
        PiggyTextTokens.caption(context).copyWith(fontWeight: FontWeight.w600);

    Widget cell(String label, double value) => PinnedTitleStat(
          label: label,
          value: AmountText(
            value: value,
            signed: false,
            showCurrency: true,
            currencyCode: currencyCode,
            useCompactFormat: true,
            hide: hide,
            style: valueStyle,
          ),
        );

    return Row(
      children: [
        Expanded(child: cell(l10n.savingsGoalTotalTarget, summary.totalTarget)),
        Container(
          width: 1,
          height: 20.0.scaled(context, ref),
          color: PiggyTokens.divider(context),
        ),
        Expanded(child: cell(l10n.savingsGoalTotalSaved, summary.totalSaved)),
      ],
    );
  }
}
