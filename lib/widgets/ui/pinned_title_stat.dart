import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 标题栏吸顶汇总的一栏：标签在上、数值在下。
///
/// 用于「汇总卡滑进标题栏后面后，把汇总数字收进标题栏」的场景 —— 订阅管理页
/// 与储蓄目标页共用同一种版式，避免两个页面各写一套，字重 / 间距 / 缩字号
/// 兜底慢慢漂移。
///
/// 标题栏里一栏只有几十 dp 宽，所以：
/// - 标签固定 `fs10` + 省略号（不换行、不缩字号）；
/// - [value] 由调用方给（金额 / 数量），统一套 `FittedBox(scaleDown)` 兜底，
///   长金额只把自己缩小，绝不换行把标题栏撑高。
class PinnedTitleStat extends StatelessWidget {
  const PinnedTitleStat({super.key, required this.label, required this.value});

  /// 顶部小字标签（如「年支出」「总目标」）
  final String label;

  /// 数值（通常是 `AmountText` 或 `Text`）
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
