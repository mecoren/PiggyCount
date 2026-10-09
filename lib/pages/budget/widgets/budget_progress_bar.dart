import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../styles/tokens.dart';
import '../../../utils/ui_scale_extensions.dart';

/// 预算进度条组件。
///
/// [positiveOverflow] 用来区分两类**相反**的进度语义：
/// - `false`（默认，预算）：用得越多越危险 —— 0.7 黄、0.9/1.0 红；
/// - `true`（目标型进度，如储蓄目标）：越多越好 —— 未达成走主题色表示「进行中」，
///   达成走成功色。储蓄目标若沿用预算的红色档位，会把「已达成」渲染成危险信号。
class BudgetProgressBar extends ConsumerWidget {
  final double used;
  final double budget;
  final bool showLabel;
  final double height;
  final String currencySymbol;

  /// 超额是否算正向（目标型进度）。见类注释。
  final bool positiveOverflow;

  const BudgetProgressBar({
    required this.used,
    required this.budget,
    this.showLabel = true,
    this.height = 8,
    this.currencySymbol = '¥',
    this.positiveOverflow = false,
    super.key,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rate = budget > 0 ? (used / budget).clamp(0.0, 1.0) : 0.0;
    final color = _getColor(context, rate);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(height / 2),
          child: LinearProgressIndicator(
            value: rate,
            backgroundColor: color.withValues(alpha: 0.2),
            valueColor: AlwaysStoppedAnimation(color),
            minHeight: height.scaled(context, ref),
          ),
        ),
        if (showLabel) ...[
          SizedBox(height: 4.0.scaled(context, ref)),
          Text(
            '$currencySymbol${used.toStringAsFixed(0)} / $currencySymbol${budget.toStringAsFixed(0)}',
            style: PiggyTextTokens.label(context),
          ),
        ],
      ],
    );
  }

  Color _getColor(BuildContext context, double rate) {
    // 目标型进度：达成是终点而非警报 —— 未达成为「进行中」主题色，达成为成功色。
    if (positiveOverflow) {
      return rate >= 1.0
          ? PiggyTokens.success(context)
          : PiggyTokens.primary(context);
    }
    if (rate >= 1.0) return PiggyTokens.error(context);
    if (rate >= 0.9) return PiggyTokens.error(context);
    if (rate >= 0.7) return PiggyTokens.warning(context);
    return PiggyTokens.success(context);
  }
}
