import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'gradient_backdrop_filter.dart';

/// 液态玻璃两行融合标题栏
///
/// 移植自 wait-home 项目。将"标题行 + 数量/排序/筛选行"融合为独立组件，
/// 整体覆盖无级渐变模糊背景。
///
/// 布局：
/// ```
/// 第一行：[菜单/返回] [标题] [搜索框+搜索键] [功能键]   （56dp）
/// 第二行：[图标+数量] ... [排序按钮] [筛选按钮]         （46dp，可选）
/// ```
///
/// 设置页仅使用第一行的基础能力（title / showBack / onBack / actions），
/// 搜索框、第二行、功能键等 API 保留供未来其他页面复用。
class LiquidGlassTitleBar extends StatefulWidget
    implements PreferredSizeWidget {
  const LiquidGlassTitleBar({
    super.key,
    // 第一行 - 左侧导航
    this.onBack,
    this.onMenuTap,
    this.showBack = true,
    this.showMenu = false,
    this.backIcon,
    this.leadingIcon,
    this.leadingPlain = false,
    // 第一行 - 标题
    this.title,
    this.subtitle,
    this.titleWidget,
    this.centerTitle = false,
    this.compact = false,
    // 第一行 - 自定义内容（showTitleSection=false 时启用）
    this.showTitleSection = true,
    this.content,
    // 第一行 - 搜索
    this.showSearch = false,
    this.onSearchChanged,
    this.searchHint = '搜索...',
    this.searchController,
    this.searchFocusNode,
    // 第一行 - 功能键
    this.showActions = true,
    this.actionsIcon,
    this.onActionsTap,
    this.actions,
    // 第二行
    this.showSecondRow = true,
    this.secondRowLeading,
    this.secondRowTrailing,
    // bottom 槽位（标题栏底部独立区域，用于 TabBar / 分段选择器）
    this.bottom,
    this.bottomHeight = 0,
    // 渐变模糊
    this.blur = true,
    this.maxSigma = _Dimens.blurTitleBarMax,
    this.minSigma = _Dimens.blurTitleBarMin,
    this.backgroundColor,
    this.showHighlightLine = true,
    this.bottomOpaque = false,
    // 动态模糊（滚动驱动渐显）
    this.scrollOffsetListenable,
    this.blurFadeDistance = _Dimens.blurScrollFadeDistance,
    // SafeArea
    this.primary = false,
  });

  // ===== 第一行 - 左侧导航 =====
  final VoidCallback? onBack;
  final VoidCallback? onMenuTap;
  final bool showBack;
  final bool showMenu;
  final Widget? backIcon;

  /// 左侧导航图标（仅当 showBack/showMenu 均为 false 且此参数非空时使用）。
  /// 用于迁移 PrimaryHeader 的 leadingIcon 场景。
  final IconData? leadingIcon;

  /// leadingIcon 是否以"纯图标"形式渲染（无圆形背景容器）。
  /// 对应 PrimaryHeader 的 leadingPlain 参数。
  final bool leadingPlain;

  // ===== 第一行 - 标题 =====
  final String? title;

  /// 副标题（可选）。存在时第一行高度从 56dp 增至 80dp，
  /// 渲染在 title 下方作为小字。对应 PrimaryHeader 的 subtitle 参数。
  final String? subtitle;

  final Widget? titleWidget;
  final bool centerTitle;

  /// 是否使用紧凑内边距。对应 PrimaryHeader 的 compact 参数。
  final bool compact;

  // ===== 第一行 - 自定义内容 =====

  /// 是否渲染默认标题行。为 false 时改用 [content] 自绘第一行内容，
  /// 用于迁移 PrimaryHeader 的 showTitleSection=false 场景（首页/分析页）。
  final bool showTitleSection;

  /// 自定义第一行内容（仅当 [showTitleSection] 为 false 时启用）。
  final Widget? content;

  // ===== 第一行 - 搜索 =====
  final bool showSearch;
  final ValueChanged<String>? onSearchChanged;
  final String searchHint;

  /// 外部传入的搜索 controller（可选，不传则内部创建）
  final TextEditingController? searchController;

  /// 外部传入的 focus node（可选，不传则内部创建）
  final FocusNode? searchFocusNode;

  // ===== 第一行 - 功能键 =====
  final bool showActions;
  final Widget? actionsIcon;
  final VoidCallback? onActionsTap;

  /// 额外的功能按钮列表（在功能键左侧），不受 showActions 影响
  final List<Widget>? actions;

  // ===== 第二行 =====
  final bool showSecondRow;
  final Widget? secondRowLeading;
  final Widget? secondRowTrailing;

  // ===== bottom 槽位 =====

  /// 标题栏底部独立区域（用于 TabBar / 分段选择器等）。
  /// 对应 PrimaryHeader 的 bottom 参数。渲染在第一行/第二行下方。
  final Widget? bottom;

  /// [bottom] 的高度（不含在 firstRowHeight / secondRowHeight 内）。
  /// preferredSize 会加上此值。
  final double bottomHeight;

  // ===== 渐变模糊 =====
  final bool blur;
  final double maxSigma;
  final double minSigma;
  final Color? backgroundColor;

  /// 是否显示底部高光线。底部抽屉等纯色背景场景应设为 false，
  /// 使标题栏与内容区无缝融合。
  final bool showHighlightLine;

  /// 是否让模糊层底部保持不透明，隔绝下方组件颜色渗透。
  /// 详见 [GradientBackdropFilter.bottomOpaque]。
  final bool bottomOpaque;

  // ===== 动态模糊（滚动驱动渐显） =====

  /// 滚动偏移监听器。传入后模糊层随滚动渐显：
  /// offset <= 0 时完全透明，offset >= [blurFadeDistance] 时完全显示。
  /// 为 null 时模糊层始终完全显示（向后兼容）。
  final ValueListenable<double>? scrollOffsetListenable;

  /// 模糊层从透明到完全显示的滚动偏移区间（像素），默认 32px。
  final double blurFadeDistance;

  /// 是否由外部（如 `AppBar` / `SafeArea`）处理状态栏避让。
  ///
  /// - `false`（默认）：组件自己读取状态栏高度并留出安全区，背景覆盖状态栏区域。
  ///   适用于直接放在 `Scaffold.body` 中的场景（如 `GlassHeader`）。
  /// - `true`：不自己处理状态栏，高度仅含内容行（56dp / 80dp）。
  ///   用于 `Scaffold.appBar` 时避免与 `AppBar` 内置 `SafeArea` 重复计算。
  final bool primary;

  /// 第一行高度（不含状态栏）。有 subtitle 时为 80dp，否则 56dp。
  double get firstRowHeight =>
      (subtitle != null && showTitleSection) ? _Dimens.titleBarWithSubtitle : _Dimens.titleBarHeight;

  /// 第二行高度
  static const double secondRowHeight = _Dimens.titleBarSecondRow;

  @override
  Size get preferredSize => Size.fromHeight(
        firstRowHeight +
            (showSecondRow ? secondRowHeight : 0) +
            (bottom != null ? bottomHeight : 0),
      );

  @override
  State<LiquidGlassTitleBar> createState() => _LiquidGlassTitleBarState();
}

class _LiquidGlassTitleBarState extends State<LiquidGlassTitleBar>
    with SingleTickerProviderStateMixin {
  late final TextEditingController _searchController;
  late final FocusNode _searchFocusNode;
  bool _isSearchExpanded = false;

  @override
  void initState() {
    super.initState();
    _searchController = widget.searchController ?? TextEditingController();
    _searchFocusNode = widget.searchFocusNode ?? FocusNode();
  }

  @override
  void dispose() {
    // 仅释放内部创建的 controller/focusNode
    if (widget.searchController == null) _searchController.dispose();
    if (widget.searchFocusNode == null) _searchFocusNode.dispose();
    super.dispose();
  }

  void _expandSearch() {
    setState(() => _isSearchExpanded = true);
    // 延迟请求焦点，等待动画启动
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  void _collapseSearch() {
    _searchFocusNode.unfocus();
    _searchController.clear();
    widget.onSearchChanged?.call('');
    setState(() => _isSearchExpanded = false);
  }

  /// 将滚动偏移映射为模糊层不透明度（0.0→1.0 线性渐显）。
  double _mapOffsetToBlurOpacity(double offset) {
    if (offset <= 0.0) return 0.0;
    if (offset >= widget.blurFadeDistance) return 1.0;
    return offset / widget.blurFadeDistance;
  }

  /// 构建层 A：渐变毛玻璃背景（或纯色背景）
  Widget _buildBlurLayer(BuildContext context, ColorScheme colorScheme) {
    if (!widget.blur) {
      return Positioned.fill(
        child: ColoredBox(
          color: widget.backgroundColor ?? colorScheme.surface,
        ),
      );
    }
    // 动态模糊：用 ValueListenableBuilder 仅重建模糊子树
    if (widget.scrollOffsetListenable != null) {
      return Positioned.fill(
        child: ValueListenableBuilder<double>(
          valueListenable: widget.scrollOffsetListenable!,
          builder: (context, offset, _) {
            return GradientBackdropFilter(
              maxSigma: widget.maxSigma,
              minSigma: widget.minSigma,
              opacity: _mapOffsetToBlurOpacity(offset),
              bottomOpaque: widget.bottomOpaque,
            );
          },
        ),
      );
    }
    // 向后兼容：无滚动监听时模糊常显
    return Positioned.fill(
      child: GradientBackdropFilter(
        maxSigma: widget.maxSigma,
        minSigma: widget.minSigma,
        bottomOpaque: widget.bottomOpaque,
      ),
    );
  }

  /// 构建层 C：底部液态玻璃边缘高光线（跟随模糊层同步显隐）
  ///
  /// 注意：高光线仅占底部 1px，绝不能用 [Positioned.fill] 包裹，
  /// 否则会覆盖整个标题栏区域并拦截标题按钮点击事件。
  Widget _buildHighlightLine(BuildContext context, bool isDark) {
    final lineContainer = Container(
      height: _Defaults.highlightHeight,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.centerLeft,
          end: Alignment.centerRight,
          colors: isDark
              ? [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.30),
                  Colors.white.withValues(alpha: 0.45),
                  Colors.white.withValues(alpha: 0.30),
                  Colors.white.withValues(alpha: 0.0),
                ]
              : [
                  Colors.white.withValues(alpha: 0.0),
                  Colors.white.withValues(alpha: 0.85),
                  Colors.white.withValues(alpha: 1.0),
                  Colors.white.withValues(alpha: 0.85),
                  Colors.white.withValues(alpha: 0.0),
                ],
        ),
      ),
    );

    // 动态模糊：高光线跟随模糊层透明度同步显隐
    if (widget.scrollOffsetListenable != null) {
      return ValueListenableBuilder<double>(
        valueListenable: widget.scrollOffsetListenable!,
        builder: (context, offset, _) {
          final opacity = _mapOffsetToBlurOpacity(offset);
          if (opacity <= 0.0) return const SizedBox.shrink();
          return Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: opacity >= 1.0
                ? lineContainer
                : Opacity(opacity: opacity, child: lineContainer),
          );
        },
      );
    }
    return Positioned(
      bottom: 0,
      left: 0,
      right: 0,
      child: lineContainer,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;
    final statusBarHeight =
        widget.primary ? 0.0 : MediaQuery.of(context).padding.top;
    final totalContentHeight = widget.firstRowHeight +
        (widget.showSecondRow ? LiquidGlassTitleBar.secondRowHeight : 0) +
        (widget.bottom != null ? widget.bottomHeight : 0);

    // 状态栏图标颜色：亮色模式深色图标，暗色模式浅色图标（对齐 PrimaryHeader 行为）
    final statusBarIconBrightness =
        isDark ? Brightness.light : Brightness.dark;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemStatusBarContrastEnforced: false,
        statusBarIconBrightness: statusBarIconBrightness,
        statusBarBrightness: isDark ? Brightness.dark : Brightness.light,
      ),
      child: RepaintBoundary(
        child: SizedBox(
          height: statusBarHeight + totalContentHeight,
          child: Stack(
            children: [
              // 层 A：渐变毛玻璃背景（动态模糊时跟随滚动渐显）
              _buildBlurLayer(context, colorScheme),
              // 层 B：内容（第一行 + 第二行 + bottom，始终完全显示）
              Positioned(
                top: statusBarHeight,
                left: 0,
                right: 0,
                bottom: 0,
                child: Column(
                  children: [
                    SizedBox(
                      height: widget.firstRowHeight,
                      child: widget.showTitleSection
                          ? _buildFirstRow(context, colorScheme)
                          : (widget.content ??
                              const SizedBox.shrink()),
                    ),
                    if (widget.showSecondRow)
                      SizedBox(
                        height: LiquidGlassTitleBar.secondRowHeight,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: _Dimens.space16,
                          ),
                          child: Row(
                            children: [
                              if (widget.secondRowLeading != null)
                                widget.secondRowLeading!,
                              const Spacer(),
                              if (widget.secondRowTrailing != null)
                                widget.secondRowTrailing!,
                            ],
                          ),
                        ),
                      ),
                    if (widget.bottom != null)
                      SizedBox(
                        height: widget.bottomHeight,
                        child: widget.bottom!,
                      ),
                  ],
                ),
              ),
              // 层 C：底部液态玻璃边缘高光线（跟随模糊层同步显隐）
              if (widget.showHighlightLine)
                _buildHighlightLine(context, isDark),
            ],
          ),
        ),
      ),
    );
  }

  /// 构建第一行：导航键 + 标题 + [搜索框+搜索键] + 功能键
  Widget _buildFirstRow(BuildContext context, ColorScheme colorScheme) {
    final leading = _buildLeading();
    final title = _buildTitle(colorScheme);
    final trailing = _buildTrailing(colorScheme);

    // compact 模式减小水平内边距（对齐 PrimaryHeader.compact 行为）
    final horizontalPadding = widget.compact ? _Dimens.space8 : _Dimens.space16;

    return Container(
      height: widget.firstRowHeight,
      padding: EdgeInsets.symmetric(horizontal: horizontalPadding),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          if (leading != null) leading,
          if (widget.centerTitle)
            Expanded(child: Center(child: title))
          else
            Expanded(child: title),
          trailing ?? const SizedBox.shrink(),
        ],
      ),
    );
  }

  /// 构建左侧：菜单键 / 返回键 / 自定义 leadingIcon
  Widget? _buildLeading() {
    if (widget.showMenu) {
      return IconButton(
        padding: const EdgeInsets.only(right: _Dimens.space8),
        icon: const Icon(Icons.menu, size: _Dimens.iconSizeLg),
        onPressed: widget.onMenuTap,
      );
    }
    if (widget.showBack) {
      return IconButton(
        padding: const EdgeInsets.only(right: _Dimens.space8),
        icon: widget.backIcon ??
            const Icon(Icons.arrow_back_rounded, size: _Dimens.iconSizeLg),
        onPressed: widget.onBack ?? () => Navigator.of(context).maybePop(),
      );
    }
    // 迁移 PrimaryHeader.leadingIcon：无菜单/返回键时渲染自定义图标
    if (widget.leadingIcon != null) {
      final icon = Icon(widget.leadingIcon, size: _Dimens.iconSizeLg);
      return Padding(
        padding: const EdgeInsets.only(right: _Dimens.space8),
        child: widget.leadingPlain
            ? icon
            : Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                ),
                child: icon,
              ),
      );
    }
    return null;
  }

  /// 构建标题（始终可见，搜索展开时仅按需截断）。
  /// 存在 [widget.subtitle] 时用 Column 包裹主标题 + 副标题小字。
  Widget _buildTitle(ColorScheme colorScheme) {
    final mainTitle = widget.titleWidget ??
        Text(
          widget.title ?? '',
          style: _titleStyle(colorScheme),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        );

    if (widget.subtitle == null) return mainTitle;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        mainTitle,
        const SizedBox(height: 2),
        Text(
          widget.subtitle!,
          style: _subtitleStyle(colorScheme),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  /// 构建搜索框（高度 36dp，与图标对齐）
  Widget _buildSearchField(ColorScheme colorScheme) {
    return SizedBox(
      height: _Defaults.searchFieldHeight,
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        textAlignVertical: TextAlignVertical.center,
        style: TextStyle(
          fontSize: _Defaults.searchFontSize,
          color: colorScheme.onSurface,
        ),
        decoration: InputDecoration(
          hintText: widget.searchHint,
          hintStyle: TextStyle(
            fontSize: _Defaults.searchHintFontSize,
            color: colorScheme.onSurfaceVariant,
          ),
          prefixIcon:
              const Icon(Icons.search, size: _Dimens.iconSizeSm),
          prefixIconConstraints: const BoxConstraints(
            minWidth: _Defaults.searchIconBox,
            minHeight: _Defaults.searchIconBox,
          ),
          suffixIcon: ValueListenableBuilder<TextEditingValue>(
            valueListenable: _searchController,
            builder: (context, value, child) {
              if (value.text.isEmpty) return const SizedBox.shrink();
              return IconButton(
                icon: const Icon(
                  Icons.clear,
                  size: _Defaults.clearIconSize,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(
                  minWidth: _Defaults.suffixIconBox,
                  minHeight: _Defaults.suffixIconBox,
                ),
                onPressed: () {
                  _searchController.clear();
                  widget.onSearchChanged?.call('');
                  _searchFocusNode.requestFocus();
                },
              );
            },
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: _Defaults.suffixIconBox,
            minHeight: _Defaults.suffixIconBox,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: _Dimens.space12,
            vertical: _Defaults.searchContentVertical,
          ),
          filled: true,
          fillColor:
              colorScheme.surfaceContainerHighest.withValues(alpha: 0.6),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(
              _Defaults.searchFieldRadius,
            ),
            borderSide: BorderSide.none,
          ),
        ),
        onChanged: widget.onSearchChanged,
      ),
    );
  }

  /// 构建右侧：额外 actions + [搜索框+搜索键] + 功能键
  Widget? _buildTrailing(ColorScheme colorScheme) {
    final hasSearch = widget.showSearch;
    final hasActions =
        widget.actions != null && widget.actions!.isNotEmpty;
    final hasActionButton = widget.showActions;
    if (!hasSearch && !hasActions && !hasActionButton) return null;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (hasActions) ...widget.actions!,
        // 搜索组：位于功能按钮左侧
        if (hasSearch) _buildSearchGroup(colorScheme),
        if (hasActionButton)
          IconButton(
            icon: widget.actionsIcon ??
                const Icon(Icons.more_vert_rounded, size: _Dimens.iconSizeMd),
            onPressed: widget.onActionsTap,
          ),
      ],
    );
  }

  /// 搜索组：展开的文本框（在功能按钮左侧就地向左展开）+ 搜索/关闭键
  Widget _buildSearchGroup(ColorScheme colorScheme) {
    final screenWidth = MediaQuery.of(context).size.width;
    final leadingW =
        _buildLeading() != null ? _Dimens.touchTarget : 0.0;
    final functionW = widget.showActions ? _Dimens.touchTarget : 0.0;
    const toggleW = _Dimens.touchTarget;
    final actionsW =
        (widget.actions?.length ?? 0) * _Dimens.touchTarget;
    const reservedTitle = _Defaults.reservedTitleWidth;
    final avail = screenWidth -
        (_Dimens.space16 * 2) -
        leadingW -
        functionW -
        toggleW -
        actionsW -
        reservedTitle;
    final targetWidth = _isSearchExpanded
        ? avail.clamp(
            _Defaults.searchMinWidth,
            _Defaults.searchMaxWidth,
          )
        : 0.0;

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        AnimatedContainer(
          duration: const Duration(
            milliseconds: _Dimens.durationSlow,
          ),
          curve: Curves.easeOutCubic,
          width: targetWidth,
          child: ClipRect(
            child: _buildSearchField(colorScheme),
          ),
        ),
        _buildSearchToggleButton(),
      ],
    );
  }

  /// 搜索键/关闭键（图标用 AnimatedSwitcher 旋转切换）
  Widget _buildSearchToggleButton() {
    return IconButton(
      icon: AnimatedSwitcher(
        duration: const Duration(
          milliseconds: _Dimens.durationNormal,
        ),
        transitionBuilder: (child, animation) {
          return RotationTransition(
            turns: Tween<double>(begin: 0.5, end: 0).animate(
              CurvedAnimation(
                parent: animation,
                curve: Curves.easeOutCubic,
              ),
            ),
            child: FadeTransition(opacity: animation, child: child),
          );
        },
        child: _isSearchExpanded
            ? const Icon(
                Icons.close_rounded,
                size: _Dimens.iconSizeMd,
                key: ValueKey('close'),
              )
            : const Icon(
                Icons.search_rounded,
                size: _Dimens.iconSizeMd,
                key: ValueKey('search'),
              ),
      ),
      onPressed: _isSearchExpanded ? _collapseSearch : _expandSearch,
    );
  }

  TextStyle _titleStyle(ColorScheme colorScheme) {
    return TextStyle(
      fontSize: widget.centerTitle
          ? _Defaults.centeredTitleFontSize
          : _Defaults.titleFontSize,
      fontWeight:
          widget.centerTitle ? FontWeight.w600 : FontWeight.w500,
      color: colorScheme.onSurface,
    );
  }

  /// 副标题样式（小字、次要颜色，对齐 PrimaryHeader 的 subStyle 视觉）
  TextStyle _subtitleStyle(ColorScheme colorScheme) {
    return TextStyle(
      fontSize: _Defaults.subtitleFontSize,
      fontWeight: FontWeight.w400,
      color: colorScheme.onSurfaceVariant,
    );
  }
}

/// 移植自 wait-home AppDimens 的尺寸常量
/// 保留为私有常量避免污染 PiggyCount 的 PiggyDimens Token 体系
class _Dimens {
  _Dimens._();

  static const double space8 = 8;
  static const double space12 = 12;
  static const double space16 = 16;
  static const double touchTarget = 48;
  static const double titleBarHeight = 56;
  static const double titleBarWithSubtitle = 80;
  static const double titleBarSecondRow = 46;
  static const double iconSizeSm = 18;
  static const double iconSizeMd = 22;
  static const double iconSizeLg = 24;
  static const double blurTitleBarMax = 20;
  static const double blurTitleBarMin = 2;
  static const double blurScrollFadeDistance = 32;
  static const int durationNormal = 250;
  static const int durationSlow = 300;
}

/// [LiquidGlassTitleBar] 默认值集中管理
class _Defaults {
  _Defaults._();

  /// 底部高光线高度
  static const double highlightHeight = 1;

  /// 搜索框高度
  static const double searchFieldHeight = 36;

  /// 搜索框文字字号
  static const double searchFontSize = 14;

  /// 搜索框 hint 字号
  static const double searchHintFontSize = 13;

  /// 搜索框前缀/后缀图标触控盒尺寸
  static const double searchIconBox = 34;

  /// 搜索框后缀清除按钮触控盒尺寸
  static const double suffixIconBox = 32;

  /// 清除按钮图标尺寸
  static const double clearIconSize = 16;

  /// 搜索框内容垂直内边距
  static const double searchContentVertical = 6;

  /// 搜索框圆角
  static const double searchFieldRadius = 18;

  /// 搜索框最小展开宽度
  static const double searchMinWidth = 120;

  /// 搜索框最大展开宽度
  static const double searchMaxWidth = 240;

  /// 标题预留宽度（避免搜索框挤压导致标题不可见）
  static const double reservedTitleWidth = 80;

  /// 居中标题字号
  static const double centeredTitleFontSize = 18;

  /// 普通标题字号
  static const double titleFontSize = 17;

  /// 副标题字号（小字，对齐 PrimaryHeader 的 subStyle）
  static const double subtitleFontSize = 12;
}
