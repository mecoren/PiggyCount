import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

class SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry margin; // 新增 margin 参数

  /// 主题色细边框：非空时用 [Border.all] 绘制 [borderWidth] 边框，
  /// 并去掉默认阴影（边框替代阴影，与统计页图表卡片视觉一致）。
  final Color? borderColor;

  /// 自定义边框宽度，仅在 [borderColor] 非空时生效，默认 1.5。
  final double? borderWidth;

  /// **拍平**：不画底色 / 边框 / 阴影，也不加内边距 —— 直接透传 [child]。
  ///
  /// 用于「表单抽屉」形态：抽屉本身就是一张悬浮卡片（见 `PiggyFormSheet`），
  /// 字段再套一层带主题色描边的卡片就成了卡片套卡片（参考实现：云同步配置
  /// WebDAV / S3 / Supabase 三表单 —— 描边输入框直接落在抽屉底色上）。
  /// 页面级列表继续用默认的带卡片形态。
  final bool flat;

  const SectionCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(PiggyDimens.p12),
    this.margin = const EdgeInsets.symmetric(horizontal: PiggyDimens.p12), // 默认值
    this.borderColor,
    this.borderWidth,
    this.flat = false,
  });

  @override
  Widget build(BuildContext context) {
    if (flat) return child;

    final isDark = PiggyTokens.isDark(context);
    final hasCustomBorder = borderColor != null;
    final borderWidth = hasCustomBorder
        ? (this.borderWidth ?? 1.5)
        : PiggyTokens.cardOuterBorderWidth(context);
    final borderColorValue = hasCustomBorder
        ? borderColor!
        : PiggyTokens.cardOuterBorderColor(context);

    return Container(
      margin: margin, // 使用传入的 margin
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context), // ⭐ 使用 Token
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        border: borderWidth > 0
            ? Border.all(
                color: borderColorValue, // ⭐ 使用卡片边框 Token
                width: borderWidth,
              )
            : null,
        boxShadow: hasCustomBorder
            ? null // 有主题色边框时用边框替代阴影，与统计页图表卡片一致
            : (isDark ? null : PiggyShadows.card), // ⭐ 暗黑模式：无阴影，亮色模式：有阴影
      ),
      child: Padding(
        padding: padding,
        child: child,
      ),
    );
  }
}
