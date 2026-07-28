import 'package:flutter/material.dart';

import 'liquid_glass_title_bar.dart';

/// 带毛玻璃效果的顶部标题栏
///
/// 移植自 wait-home 项目。是 [LiquidGlassTitleBar] 的薄包装器，
/// 自动获得无级渐变模糊效果。
///
/// - 56dp 高度（单行，无第二行）
/// - 支持返回箭头（二级/三级页面）或汉堡键（一级页面）
/// - 标题左对齐紧贴 leading 按钮
class GlassTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTitleBar({
    super.key,
    this.title,
    this.titleWidget,
    this.onBack,
    this.onMenuTap,
    this.showBack = true,
    this.showMenu = false,
    this.actions,
    this.backgroundColor,
    this.blur = true,
    this.centerTitle = false,
    this.backIcon,
    this.maxSigma = 20.0,
    this.minSigma = 2.0,
    this.showHighlightLine = true,
  });

  final String? title;
  final Widget? titleWidget;
  final VoidCallback? onBack;
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;
  final List<Widget>? actions;
  final Color? backgroundColor;
  final bool blur;
  final bool centerTitle;
  final Widget? backIcon;
  final double maxSigma;
  final double minSigma;
  final bool showHighlightLine;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return LiquidGlassTitleBar(
      title: title,
      titleWidget: titleWidget,
      onBack: onBack,
      onMenuTap: onMenuTap,
      showBack: showBack,
      showMenu: showMenu,
      backIcon: backIcon,
      centerTitle: centerTitle,
      actions: actions,
      showActions: false,
      showSearch: false,
      showSecondRow: false,
      blur: blur,
      maxSigma: maxSigma,
      minSigma: minSigma,
      backgroundColor: backgroundColor,
      showHighlightLine: showHighlightLine,
    );
  }
}

/// 首页/一级功能页专用玻璃标题栏（汉堡键 + 标题 + 右侧操作）
///
/// 移植自 wait-home 项目。是 [LiquidGlassTitleBar] 的薄包装器。
class GlassHomeBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassHomeBar({
    super.key,
    this.title,
    this.titleWidget,
    this.onMenuTap,
    this.actions,
    this.blur = true,
  });

  final String? title;
  final Widget? titleWidget;
  final VoidCallback? onMenuTap;
  final List<Widget>? actions;
  final bool blur;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    return LiquidGlassTitleBar(
      title: title,
      titleWidget: titleWidget,
      onMenuTap: onMenuTap,
      showBack: false,
      showMenu: true,
      actions: actions,
      showActions: false,
      showSearch: false,
      showSecondRow: false,
      blur: blur,
    );
  }
}
