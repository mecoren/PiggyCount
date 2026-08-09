import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../widgets/ui/ui.dart';
import 'amount_text.dart';
import 'format_money.dart';

/// 首页头部大卡片：2×2 网格展示本月支出/收入/结余 + 月份选择器。
///
/// 参考蓝色渐变卡片样式，按主题色自适应：
/// - 亮色：主题色浅→深渐变
/// - 暗色：黑色 + 主题色半透明渐变
///
/// 替换了原 header 内的月份显示行 + `_HeaderCenterSummary` 三项平铺。
class HomeMonthSummaryCard extends ConsumerWidget {
  const HomeMonthSummaryCard({
    super.key,
    this.onMonthSelected,
  });

  /// 月份切换后的回调（用于上层触发列表跳转等）。
  final ValueChanged<DateTime>? onMonthSelected;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final month = ref.watch(selectedMonthProvider);
    final params = (ledgerId: ledgerId, month: month);

    // 触发月度统计刷新；monthlyTotalsProvider 的 value 优先（实时新数据），
    // lastMonthlyTotalsProvider 兜底（避免 autoDispose family 在切换月份后
    // 短暂 null 期间显示 0）。注意不能丢弃 monthlyTotalsProvider 的 watch,
    // 否则 family 不会触发新的异步计算 -> 切月后永远显示旧/零合计。
    final totalsAsync = ref.watch(monthlyTotalsProvider(params));
    final cachedTotals = ref.watch(lastMonthlyTotalsProvider(params));
    final (income, expense) =
        totalsAsync.valueOrNull ?? cachedTotals ?? (0.0, 0.0);

    // 预算级别（用于支出格括号显示）
    final overviewAsync = ref.watch(budgetOverviewProvider);
    final totalBudget = overviewAsync.valueOrNull?.totalBudget;

    // 货币来源：主币别优先(用户在多币种设置里选的那个) → 当前账本位币 → CNY。
    // 之前只读 ledger.currency,用户在设置里改了主币别卡片里依然按账本币显示,
    // 而"未设置"占位又把收入/结余格盖死,看不到任何币别反馈。
    final baseCurrency = ref.watch(baseCurrencyProvider).toUpperCase();
    final ledgerCurrency =
        ref.watch(currentLedgerProvider).asData?.value?.currency ?? '';
    final currencyCode = baseCurrency.isNotEmpty
        ? baseCurrency
        : (ledgerCurrency.isNotEmpty ? ledgerCurrency.toUpperCase() : 'CNY');
    final currencySymbol = getCurrencySymbol(currencyCode);
    // 括号占位:用主币别代码,支出格有预算时仍优先显示预算金额。
    final currencyLabel = currencyCode;

    final isDark = PiggyTokens.isDark(context);
    final primary = ref.watch(primaryColorProvider);

    return Container(
      margin: const EdgeInsets.fromLTRB(
        PiggyDimens.p12,
        0,
        PiggyDimens.p12,
        14,
      ),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        gradient: _cardGradient(context, ref, isDark),
        border: Border.all(
          color: primary,
          width: 1.5,
        ),
        boxShadow: isDark
            ? null
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.08),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 第一行：月份选择器（靠左）
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _MonthSelectorCell(
                        month: month,
                        onShift: (delta) => _shiftMonth(ref, delta),
                        onTapPicker: () => _pickMonth(context, ref),
                      ),
                    ),
                  ],
                ),
              ),
              // 行间分割线
              Container(
                height: 1,
                margin: const EdgeInsets.symmetric(vertical: 5),
                color: Colors.white.withValues(alpha: 0.18),
              ),
              // 第二行：本月支出 | 本月收入
              IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(
                      child: _StatCell(
                        label: l10n.homeMonthExpense,
                        value: expense,
                        parenthetical: totalBudget != null
                            ? l10n.homeBudgetSet(
                                '$currencySymbol${formatMoneyCompact(totalBudget.budget, maxDecimals: 0)}',
                              )
                            : currencyLabel,
                      ),
                    ),
                    Container(
                      width: 1,
                      margin: const EdgeInsets.symmetric(horizontal: 8),
                      color: Colors.white.withValues(alpha: 0.2),
                    ),
                    Expanded(
                      child: _StatCell(
                        label: l10n.homeMonthIncome,
                        value: income,
                        parenthetical: currencyLabel,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 月份切换：更新 provider，触发回调；不允许切换到未来月份。
  void _shiftMonth(WidgetRef ref, int delta) {
    final now = DateTime.now();
    final current = ref.read(selectedMonthProvider);
    final target = DateTime(current.year, current.month + delta, 1);
    if (target.isAfter(DateTime(now.year, now.month, 1))) return;
    ref.read(selectedMonthProvider.notifier).state = target;
    onMonthSelected?.call(target);
  }

  /// 月份选择器：弹 WheelDatePicker，更新 provider 并回调。
  Future<void> _pickMonth(BuildContext context, WidgetRef ref) async {
    final now = DateTime.now();
    final picked = await showWheelDatePicker(
      context,
      initial: ref.read(selectedMonthProvider),
      mode: WheelDatePickerMode.ym,
      maxDate: now,
    );
    if (picked == null) return;
    final target = DateTime(picked.year, picked.month, 1);
    if (target.isAfter(DateTime(now.year, now.month, 1))) return;
    ref.read(selectedMonthProvider.notifier).state = target;
    onMonthSelected?.call(target);
  }

  /// 卡片渐变：亮色主题色浅→深，暗色黑底 + 主题色半透明。
  LinearGradient _cardGradient(
    BuildContext context,
    WidgetRef ref,
    bool isDark,
  ) {
    final primary = ref.watch(primaryColorProvider);
    if (isDark) {
      return LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: [
          Colors.black,
          Color.lerp(Colors.black, primary, 0.4)!,
        ],
      );
    }
    return LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        Color.lerp(primary, Colors.white, 0.12)!,
        primary,
      ],
    );
  }
}

/// 2×2 网格中的单个金额格：标签 + 金额 + 括号预算级别。
class _StatCell extends StatelessWidget {
  const _StatCell({
    required this.label,
    required this.value,
    required this.parenthetical,
  });

  final String label;
  final double value;
  final String parenthetical;

  @override
  Widget build(BuildContext context) {
    final labelStyle = TextStyle(
      fontSize: 10,
      color: Colors.white.withValues(alpha: 0.78),
      fontWeight: FontWeight.w500,
      height: 1.2,
    );
    final parentheticalStyle = TextStyle(
      fontSize: 9,
      color: Colors.white.withValues(alpha: 0.62),
      fontWeight: FontWeight.w400,
      height: 1.2,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: labelStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        const SizedBox(height: 2),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: AmountText(
            value: value,
            signed: false,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Colors.white,
              height: 1.1,
            ),
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '（$parenthetical）',
          style: parentheticalStyle,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }
}

/// 右上角月份选择器：年份 + chevron左 + 月份文字（可点击弹选择器） + chevron右。
class _MonthSelectorCell extends StatelessWidget {
  const _MonthSelectorCell({
    required this.month,
    required this.onShift,
    required this.onTapPicker,
  });

  final DateTime month;
  final ValueChanged<int> onShift;
  final VoidCallback onTapPicker;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final yearStyle = TextStyle(
      fontSize: 12,
      color: Colors.white.withValues(alpha: 0.7),
      fontWeight: FontWeight.w500,
    );
    final monthStyle = const TextStyle(
      fontSize: 16,
      fontWeight: FontWeight.w600,
      color: Colors.white,
      height: 1.15,
    );

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      mainAxisAlignment: MainAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          l10n.homeYear(month.year),
          style: yearStyle,
          maxLines: 1,
        ),
        const SizedBox(width: 6),
        _ChevronButton(
          icon: Icons.chevron_left,
          onTap: () => onShift(-1),
        ),
        GestureDetector(
          onTap: onTapPicker,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Text(
              l10n.homeMonth(month.month.toString().padLeft(2, '0')),
              style: monthStyle,
            ),
          ),
        ),
        _ChevronButton(
          icon: Icons.chevron_right,
          onTap: () => onShift(1),
        ),
      ],
    );
  }
}

/// 圆形描边 chevron 按钮（与洞察页 _periodNavArrow 同款样式，
/// 适配渐变背景：白色描边 + 白色图标）。
class _ChevronButton extends StatelessWidget {
  const _ChevronButton({
    required this.icon,
    required this.onTap,
  });

  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = Colors.white.withValues(alpha: 0.55);
    return SizedBox(
      width: 30,
      height: 30,
      child: Material(
        color: Colors.transparent,
        shape: CircleBorder(
          side: BorderSide(color: borderColor, width: 1.4),
        ),
        child: InkWell(
          onTap: onTap,
          customBorder: const CircleBorder(),
          child: Center(
            child: Icon(
              icon,
              size: 18,
              color: Colors.white.withValues(alpha: 0.92),
            ),
          ),
        ),
      ),
    );
  }
}