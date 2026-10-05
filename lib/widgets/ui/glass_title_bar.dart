import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gradient_backdrop_filter.dart';
import 'liquid_glass_title_bar.dart';
import '../../styles/tokens.dart';

/// 带毛玻璃效果的顶部标题栏
///
/// 移植自 wait-home 项目。是 [LiquidGlassTitleBar] 的薄包装器，
/// 自动获得无级渐变模糊效果。
///
/// - 56dp 高度（单行，无第二行）；传入 [subtitle] 时增至 80dp
/// - 支持返回箭头（二级/三级页面）或汉堡键（一级页面）
/// - 标题左对齐紧贴 leading 按钮
///
/// ## bottomOpaque 默认值说明
/// 为保持现有 21 个设置页的视觉零退化，[bottomOpaque] 默认 `false`
/// （渐变透明：顶 alpha=1.0 → 底 alpha=0.0）。
/// 替换 `PrimaryHeader`（实底主题色）的页面应显式传 `bottomOpaque: true`，
/// 让底部保持不透明，隔绝下方紧贴的彩色组件颜色渗透。
@Deprecated('Use PiggyTitleBar instead. 玻璃模糊已被「95% 实色 + 直渲 HeaderSkin」取代，详见 prd/ui_optimization_review/design.md')
class GlassTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassTitleBar({
    super.key,
    this.title,
    this.subtitle,
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
    this.bottomOpaque = false,
    this.leadingIcon,
    this.leadingPlain = false,
    this.compact = false,
    this.bottom,
    this.bottomHeight = 0,
    this.showTitleSection = true,
    this.content,
    this.scrollOffsetListenable,
    this.primary = true,
  });

  final String? title;

  /// 副标题（可选）。存在时标题栏高度从 56dp 增至 80dp。
  final String? subtitle;

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

  /// 是否让模糊层底部保持不透明。详见 [GradientBackdropFilter.bottomOpaque]。
  /// 默认 `false` 保持向后兼容；替换 PrimaryHeader 的页面应传 `true`。
  final bool bottomOpaque;

  /// 左侧导航图标（仅当 showBack/showMenu 均为 false 且非空时使用）。
  final IconData? leadingIcon;

  /// leadingIcon 是否以纯图标形式渲染（无圆形背景）。
  final bool leadingPlain;

  /// 是否使用紧凑内边距。
  final bool compact;

  /// 标题栏底部独立区域（用于 TabBar / 分段选择器）。
  final Widget? bottom;

  /// [bottom] 的高度。
  final double bottomHeight;

  /// 是否渲染默认标题行。为 false 时改用 [content] 自绘。
  final bool showTitleSection;

  /// 自定义第一行内容（仅当 [showTitleSection] 为 false 时启用）。
  final Widget? content;

  /// 滚动偏移监听器，传入后模糊层随滚动渐显。
  final ValueListenable<double>? scrollOffsetListenable;

  /// 是否由外部 `AppBar` 处理状态栏避让。
  ///
  /// `GlassTitleBar` 默认用于 `Scaffold.appBar`，外部 `AppBar` 已内置
  /// `SafeArea`，因此默认 `true` 以避免状态栏高度被重复计算。
  final bool primary;

  @override
  Size get preferredSize {
    final firstRow = (subtitle != null && showTitleSection) ? 80.0 : 56.0;
    return Size.fromHeight(firstRow + (bottom != null ? bottomHeight : 0));
  }

  @override
  Widget build(BuildContext context) {
    return LiquidGlassTitleBar(
      title: title,
      subtitle: subtitle,
      titleWidget: titleWidget,
      onBack: onBack,
      onMenuTap: onMenuTap,
      showBack: showBack,
      showMenu: showMenu,
      backIcon: backIcon,
      leadingIcon: leadingIcon,
      leadingPlain: leadingPlain,
      compact: compact,
      centerTitle: centerTitle,
      showTitleSection: showTitleSection,
      content: content,
      actions: actions,
      showActions: false,
      showSearch: false,
      showSecondRow: false,
      bottom: bottom,
      bottomHeight: bottomHeight,
      blur: blur,
      maxSigma: maxSigma,
      minSigma: minSigma,
      backgroundColor: backgroundColor,
      showHighlightLine: showHighlightLine,
      bottomOpaque: bottomOpaque,
      scrollOffsetListenable: scrollOffsetListenable,
      primary: primary,
    );
  }
}

/// 首页/一级功能页专用玻璃标题栏（汉堡键 + 标题 + 右侧操作）
///
/// 移植自 wait-home 项目。是 [LiquidGlassTitleBar] 的薄包装器。
@Deprecated('Use PiggyHomeBar instead. 玻璃模糊已被「95% 实色 + 直渲 HeaderSkin」取代，详见 prd/ui_optimization_review/design.md')
class GlassHomeBar extends StatelessWidget implements PreferredSizeWidget {
  const GlassHomeBar({
    super.key,
    this.title,
    this.titleWidget,
    this.onMenuTap,
    this.actions,
    this.blur = true,
    this.bottomOpaque = false,
    this.primary = true,
  });

  final String? title;
  final Widget? titleWidget;
  final VoidCallback? onMenuTap;
  final List<Widget>? actions;
  final bool blur;
  final bool bottomOpaque;

  /// 是否由外部 `AppBar` 处理状态栏避让。
  ///
  /// 与 [GlassTitleBar.primary] 一致，默认 `true`。
  final bool primary;

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
      bottomOpaque: bottomOpaque,
      primary: primary,
    );
  }
}

/// 玻璃风格头部容器（非 appBar 模式）。
///
/// 用于 `body: Column` 第一个子节点，适用于 content 高度动态的主 Tab 页面
/// （首页 / 分析页 / 云服务页）。不实现 [PreferredSizeWidget]，
/// 内部用 [GradientBackdropFilter] + `SafeArea` 包装自定义 content。
///
/// 与 [GlassTitleBar] 的区别：
/// - [GlassTitleBar]：实现 PreferredSizeWidget，用于 `Scaffold.appBar`，高度固定
/// - [GlassHeader]：不实现 PreferredSizeWidget，用于 `Scaffold.body`，高度由 child 决定
///
/// ## 两种用法
/// 1. **完全自绘**：传入 [child]，完全自定义头部内容（首页/分析页）
/// 2. **标题行 + content**：传入 [title]/[showBack]/[actions] + [content]，
///    渲染标准标题行 + 标题行下方额外内容（云服务页）
@Deprecated('Use PiggyHeader instead. 玻璃模糊已被「95% 实色 + 直渲 HeaderSkin」取代，详见 prd/ui_optimization_review/design.md')
class GlassHeader extends StatelessWidget {
  const GlassHeader({
    super.key,
    this.child,
    this.title,
    this.subtitle,
    this.showBack = false,
    this.actions,
    this.content,
    this.bottomOpaque = false,
    this.maxSigma = 20.0,
    this.showHighlightLine = true,
    this.compact = false,
  });

  /// 完全自定义头部内容（优先于 title/showBack/actions/content）。
  /// 传入此参数时，[title]/[showBack]/[actions]/[content] 被忽略。
  final Widget? child;

  final String? title;
  final String? subtitle;
  final bool showBack;
  final List<Widget>? actions;

  /// 标题行下方的额外内容（仅当未传 [child] 且 [title] 非空时生效）。
  final Widget? content;

  /// 是否让模糊层底部保持不透明。详见 [GradientBackdropFilter.bottomOpaque]。
  final bool bottomOpaque;

  /// 顶部模糊 sigma。
  final double maxSigma;

  /// 是否显示底部高光线。
  final bool showHighlightLine;

  /// 是否使用紧凑内边距。
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final statusBarIconBrightness =
        isDark ? Brightness.light : Brightness.dark;

    // 完全自绘模式：直接用 child
    final Widget foreground;
    if (child != null) {
      foreground = child!;
    } else {
      // 标题行 + content 模式
      final horizontalPadding = compact ? 8.0 : 16.0;
      foreground = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 标题行
          Padding(
            padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
            child: Row(
              children: [
                if (showBack)
                  IconButton(
                    padding: const EdgeInsets.only(right: 8),
                    icon: const Icon(Icons.arrow_back_rounded, size: 22),
                    onPressed: () => Navigator.of(context).maybePop(),
                  ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        title ?? '',
                        style: TextStyle(
                          fontSize: PiggyTextTokens.fs17,
                          fontWeight: FontWeight.w500,
                          color: colorScheme.onSurface,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      if (subtitle != null) ...[
                        const SizedBox(height: 2),
                        Text(
                          subtitle!,
                          style: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
                            color: colorScheme.onSurfaceVariant,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                if (actions != null) ...actions!,
              ],
            ),
          ),
          // 标题行下方额外内容
          if (content != null)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: DefaultTextStyle(
                style: DefaultTextStyle.of(context).style.copyWith(
                  color: colorScheme.onSurface,
                ),
                child: IconTheme(
                  data: IconThemeData(color: colorScheme.onSurface),
                  child: content!,
                ),
              ),
            ),
        ],
      );
    }

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        statusBarIconBrightness: statusBarIconBrightness,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: RepaintBoundary(
        child: Stack(
          children: [
            // 层 A：渐变毛玻璃背景
            Positioned.fill(
              child: GradientBackdropFilter(
                maxSigma: maxSigma,
                bottomOpaque: bottomOpaque,
              ),
            ),
            // 层 B：前景内容（SafeArea 处理状态栏）
            SafeArea(
              bottom: false,
              child: foreground,
            ),
            // 层 C：底部高光线
            if (showHighlightLine)
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                height: 0.5,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colorScheme.onSurface.withValues(
                      alpha: isDark ? 0.15 : 0.08,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
