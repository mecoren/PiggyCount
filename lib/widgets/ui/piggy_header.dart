import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_providers.dart';
import '../../styles/header_skins.dart';
import '../../styles/tokens.dart';

/// PiggyCount 统一头部组件族。
///
/// 替代 [GlassTitleBar]/[GlassHomeBar]/[GlassHeader] 与已弃用的 [PrimaryHeader]，
/// 采用「95% 中性实色 + 直渲 HeaderSkin + 1px 高光线」视觉语言，
/// 与底部导航栏 [PiggyTokens.tabBarBackground] 同色，消除 app 级 BackdropFilter 开销。
///
/// 视觉层结构（四层 Stack，无模糊）：
/// ```
/// Stack
///  ├─ 层 A：95% 中性实色背景（PiggyTokens.tabBarBackground）
///  ├─ 层 B：HeaderSkin 装饰层（Opacity 0.85，护栏对比度）
///  ├─ 层 C：SafeArea(bottom: false) + 前景内容
///  └─ 层 D：0.5px 底部高光线（onSurface α0.15 暗 / α0.08 亮）
/// ```
///
/// 详见 prd/ui_optimization_review/design.md。

/// 用于 `Scaffold.appBar` 的统一标题栏（替代 `GlassTitleBar`）。
///
/// 实现 [PreferredSizeWidget]，高度计算与原 `GlassTitleBar` 完全一致：
/// - 单行 56dp；传入 [subtitle] 且 [showTitleSection] 为 true 时 80dp
/// - 传入 [bottom] 时额外加上 [bottomHeight]
class PiggyTitleBar extends StatelessWidget implements PreferredSizeWidget {
  const PiggyTitleBar({
    super.key,
    this.title,
    this.subtitle,
    this.titleWidget,
    this.onBack,
    this.onMenuTap,
    this.showBack = true,
    this.showMenu = false,
    this.actions,
    this.centerTitle = false,
    this.backIcon,
    this.leadingIcon,
    this.leadingPlain = false,
    this.compact = false,
    this.bottom,
    this.bottomHeight = 0,
    this.showTitleSection = true,
    this.content,
    this.primary = true,
    this.topPadding = 0,
    this.backgroundColor,
    // —— 以下参数为兼容旧 GlassTitleBar API 保留，内部忽略 ——
    @Deprecated('No longer used; PiggyTitleBar is always solid.')
    this.blur = true,
    @Deprecated('No longer used; PiggyTitleBar has no blur.')
    this.maxSigma = 20.0,
    @Deprecated('No longer used; PiggyTitleBar has no blur.')
    this.minSigma = 2.0,
    @Deprecated('No longer used; PiggyTitleBar always shows highlight line.')
    this.showHighlightLine = true,
    @Deprecated('No longer used; PiggyTitleBar is always opaque.')
    this.bottomOpaque = false,
    @Deprecated('No longer used; PiggyTitleBar has no blur fade.')
    this.scrollOffsetListenable,
  });

  final String? title;
  final String? subtitle;
  final Widget? titleWidget;
  final VoidCallback? onBack;
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;
  final List<Widget>? actions;
  final bool centerTitle;
  final Widget? backIcon;
  final IconData? leadingIcon;
  final bool leadingPlain;
  final bool compact;
  final Widget? bottom;
  final double bottomHeight;
  final bool showTitleSection;
  final Widget? content;

  /// 是否由外部 `AppBar` 处理状态栏避让（沿用 GlassTitleBar 语义）。
  final bool primary;

  /// 标题行顶部额外间距（在 SafeArea 状态栏避让之上再增加呼吸空间）。
  ///
  /// 默认 0，页面标题感觉离状态栏过近时可通过此参数微调。
  final double topPadding;

  /// 自定义标题栏背景色；为 null 时使用默认 [PiggyTokens.tabBarBackground]。
  final Color? backgroundColor;

  // —— 兼容字段（忽略）——
  final bool blur;
  final double maxSigma;
  final double minSigma;
  final bool showHighlightLine;
  final bool bottomOpaque;
  final ValueListenable<double>? scrollOffsetListenable;

  @override
  Size get preferredSize {
    final firstRow = (subtitle != null && showTitleSection) ? 80.0 : 56.0;
    // topPadding 是前景列里真实占位的空间（Padding(top) + SizedBox(firstRow)），
    // 必须计入 preferredSize，否则 Scaffold 只给 firstRow 高度，
    // 内容比预留空间高出 topPadding → "BOTTOM OVERFLOWED BY n PIXELS"。
    return Size.fromHeight(
      topPadding + firstRow + (bottom != null ? bottomHeight : 0),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PiggyHeaderShell(
      primary: primary,
      backgroundColor: backgroundColor,
      foreground: _buildForeground(context),
    );
  }

  Widget _buildForeground(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final horizontalPadding = compact ? 8.0 : PiggyDimens.headerHorizontalValue;
    final firstRowHeight = (subtitle != null && showTitleSection) ? 80.0 : 56.0;

    // 完全自绘模式：showTitleSection=false 且提供 content
    if (!showTitleSection && content != null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: EdgeInsets.only(top: topPadding),
            child: SizedBox(
              height: firstRowHeight,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
                child: content,
              ),
            ),
          ),
          if (bottom != null) SizedBox(height: bottomHeight, child: bottom),
        ],
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: EdgeInsets.only(top: topPadding),
          child: SizedBox(
            height: firstRowHeight,
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
              child: Row(
                children: [
                  if (showBack)
                    IconButton(
                      padding: const EdgeInsets.only(right: 8),
                      icon: backIcon ??
                          const Icon(Icons.arrow_back_rounded, size: 22),
                      onPressed:
                          onBack ?? () => Navigator.of(context).maybePop(),
                    ),
                  if (showMenu)
                    IconButton(
                      padding: const EdgeInsets.only(right: 8),
                      icon: const Icon(Icons.menu_rounded, size: 22),
                      onPressed: onMenuTap,
                    ),
                  if (!showBack && !showMenu && leadingIcon != null) ...[
                    leadingPlain
                        ? Icon(leadingIcon, size: 22)
                        : Container(
                            width: 36,
                            height: 36,
                            decoration: BoxDecoration(
                              color:
                                  colorScheme.primary.withValues(alpha: 0.12),
                              shape: BoxShape.circle,
                            ),
                            child: Icon(leadingIcon, size: 20),
                          ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Column(
                      crossAxisAlignment: centerTitle
                          ? CrossAxisAlignment.center
                          : CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (titleWidget != null)
                              Flexible(child: titleWidget!)
                            else if (title != null)
                              Flexible(
                                child: Text(
                                  title!,
                                  style: TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w500,
                                    color: colorScheme.onSurface,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                          ],
                        ),
                        if (subtitle != null) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle!,
                            style: TextStyle(
                              fontSize: 12,
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
          ),
        ),
        if (bottom != null) SizedBox(height: bottomHeight, child: bottom),
      ],
    );
  }
}

/// 首页/一级功能页统一标题栏（替代 `GlassHomeBar`）。
///
/// 汉堡键 + 标题 + 右侧操作，固定 56dp。
class PiggyHomeBar extends StatelessWidget implements PreferredSizeWidget {
  const PiggyHomeBar({
    super.key,
    this.title,
    this.titleWidget,
    this.onMenuTap,
    this.actions,
    this.primary = true,
    @Deprecated('No longer used; PiggyHomeBar is always solid.')
    this.blur = true,
    @Deprecated('No longer used; PiggyHomeBar is always opaque.')
    this.bottomOpaque = false,
  });

  final String? title;
  final Widget? titleWidget;
  final VoidCallback? onMenuTap;
  final List<Widget>? actions;
  final bool primary;

  // —— 兼容字段（忽略）——
  final bool blur;
  final bool bottomOpaque;

  @override
  Size get preferredSize => const Size.fromHeight(56);

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final horizontalPadding = PiggyDimens.headerHorizontalValue;
    return _PiggyHeaderShell(
      primary: primary,
      foreground: SizedBox(
        height: 56,
        child: Padding(
          padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
          child: Row(
            children: [
              IconButton(
                padding: const EdgeInsets.only(right: 8),
                icon: const Icon(Icons.menu_rounded, size: 22),
                onPressed: onMenuTap,
              ),
              Expanded(
                child: titleWidget ??
                    Text(
                      title ?? '',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w500,
                        color: colorScheme.onSurface,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
              ),
              if (actions != null) ...actions!,
            ],
          ),
        ),
      ),
    );
  }
}

/// 用于 `Scaffold.body` 第一个子节点的统一头部容器（替代 `GlassHeader`）。
///
/// 不实现 [PreferredSizeWidget]，高度由 [child]/[content]/[bottom] 决定。
///
/// 两种用法：
/// 1. **完全自绘**：传入 [child]，完全自定义头部内容（首页/分析页）
/// 2. **标题行 + content**：传入 [title]/[showBack]/[actions] + [content]
class PiggyHeader extends ConsumerWidget {
  const PiggyHeader({
    super.key,
    this.child,
    this.title,
    this.subtitle,
    this.showBack = false,
    this.actions,
    this.content,
    this.compact = false,
    this.bottom,
    this.bottomHeight = 0,
    // —— 以下参数为兼容旧 GlassHeader API 保留，内部忽略 ——
    @Deprecated('No longer used; PiggyHeader is always opaque.')
    this.bottomOpaque = false,
    @Deprecated('No longer used; PiggyHeader has no blur.')
    this.maxSigma = 20.0,
    @Deprecated('No longer used; PiggyHeader always shows highlight line.')
    this.showHighlightLine = true,
  });

  /// 完全自定义头部内容（优先于 title/showBack/actions/content）。
  final Widget? child;

  final String? title;
  final String? subtitle;
  final bool showBack;
  final List<Widget>? actions;
  final Widget? content;
  final bool compact;
  final Widget? bottom;
  final double bottomHeight;

  // —— 兼容字段（忽略）——
  final bool bottomOpaque;
  final double maxSigma;
  final bool showHighlightLine;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return _PiggyHeaderShell(
      primary: false,
      foreground: child ?? _buildForeground(context),
    );
  }

  Widget _buildForeground(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final horizontalPadding = compact ? 8.0 : PiggyDimens.headerHorizontalValue;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                        fontSize: 17,
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
                          fontSize: 12,
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
        if (bottom != null) SizedBox(height: bottomHeight, child: bottom),
      ],
    );
  }
}

/// 统一的头部外壳：四层 Stack（实色底 + 皮肤 + 前景 + 高光线）。
class _PiggyHeaderShell extends ConsumerWidget {
  const _PiggyHeaderShell({
    required this.foreground,
    required this.primary,
    this.backgroundColor,
  });

  final Widget foreground;

  /// 是否由外部 `AppBar` 处理状态栏避让（沿用 GlassTitleBar 语义）。
  final bool primary;

  /// 自定义背景色；为 null 时使用默认 [PiggyTokens.tabBarBackground]。
  final Color? backgroundColor;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colorScheme = theme.colorScheme;
    final statusBarIconBrightness = isDark ? Brightness.light : Brightness.dark;

    // 皮肤层：读取 headerSkinProvider，0.85 不透明度护栏对比度
    final skin = headerSkinById(ref.watch(headerSkinProvider));
    final primaryColor = ref.watch(primaryColorProvider);

    // 95% 中性实色背景；调用方可自定义（如底部抽屉与页面背景融合）。
    final bgColor = backgroundColor ?? PiggyTokens.tabBarBackground(context);

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
            // 层 A：95% 中性实色背景
            Positioned.fill(child: ColoredBox(color: bgColor)),
            // 层 B：HeaderSkin 装饰层（0.85 不透明度护栏）
            if (skin != null)
              Positioned.fill(
                child: Opacity(
                  opacity: 0.85,
                  child: skin.builder(primaryColor, isDark),
                ),
              ),
            // 层 C：前景内容（SafeArea 处理状态栏避让）
            SafeArea(bottom: false, child: foreground),
            // 层 D：底部 0.5px 高光线
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
