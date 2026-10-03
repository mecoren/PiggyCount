import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers/theme_providers.dart';
import '../../styles/tokens.dart';

/// 「整张大卡片」的单个分组外壳。
///
/// 账本明细（首页）/ 分类详情 / 标签详情共用同一视觉：首分组画顶部圆角 + 顶边
/// + 亮色阴影，末分组画底部圆角 + 底边，中间分组只画左右边线 —— 各分组共享
/// 连续 surface 底色与主题色边线，视觉上是「一张大卡片」而不是多张卡片。
///
/// 调用方负责分组内容（日期头 / 交易行 / 日间细线），这里只管外壳装饰。
class DayGroupCard extends ConsumerWidget {
  final bool isFirst;
  final bool isLast;
  final Widget child;

  const DayGroupCard({
    super.key,
    required this.isFirst,
    required this.isLast,
    required this.child,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final borderColor = ref.watch(primaryColorProvider);
    const borderWidth = 1.5;

    return Container(
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        border: Border(
          top: isFirst
              ? BorderSide(color: borderColor, width: borderWidth)
              : BorderSide.none,
          bottom: isLast
              ? BorderSide(color: borderColor, width: borderWidth)
              : BorderSide.none,
          left: BorderSide(color: borderColor, width: borderWidth),
          right: BorderSide(color: borderColor, width: borderWidth),
        ),
        borderRadius: BorderRadius.only(
          topLeft: isFirst
              ? const Radius.circular(PiggyDimens.radiusLg)
              : Radius.zero,
          topRight: isFirst
              ? const Radius.circular(PiggyDimens.radiusLg)
              : Radius.zero,
          bottomLeft: isLast
              ? const Radius.circular(PiggyDimens.radiusLg)
              : Radius.zero,
          bottomRight: isLast
              ? const Radius.circular(PiggyDimens.radiusLg)
              : Radius.zero,
        ),
        // 顶部阴影只由首分组画一次；有主题色边框替代阴影，暗黑模式不下阴影。
        boxShadow:
            isFirst && !PiggyTokens.isDark(context) ? PiggyShadows.card : null,
      ),
      child: child,
    );
  }
}
