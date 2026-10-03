import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

/// 菜单面板宽度上限（px）。
///
/// 锚点浮层菜单**不该铺满**：条目文案最长也就「仅删除本地账本」这一档，再宽只会
/// 在右侧留出一片空白。取 min(240, 屏宽 0.62, 屏宽 - 32)，与 orbit 移动端
/// `orbit_dropdown_panel.dart` 的 `orbitPanelMaxWidth / orbitPanelWidthFactor`
/// 同口径。
const double _kMenuMaxWidth = 240;
const double _kMenuWidthFactor = 0.62;

/// 菜单面板宽度下限：短文案（2~3 字）不至于缩成一条窄缝。
const double _kMenuMinWidth = 160;

/// 菜单项类型
enum PiggyMenuItemType {
  /// 普通操作项
  action,

  /// 提示信息（禁用状态）
  tip,

  /// 分隔线
  divider,
}

/// 菜单项配置
class PiggyMenuItem {
  final String? value;
  final IconData? icon;
  final String? label;
  final PiggyMenuItemType type;

  /// 文案与图标着色（破坏性动作传 error；null 走默认层级）。
  ///
  /// 与 [isDanger] 同源，取值时 `color` 优先；两者都不给就走主题色。
  final Color? color;

  /// 破坏性动作快捷位：等价于 `color: error(context)`，但 [PiggyMenuItem]
  /// 不能带 context（它是纯数据），所以调用方仍用 `isDanger` 更省事。
  final bool isDanger;

  const PiggyMenuItem._({
    this.value,
    this.icon,
    this.label,
    required this.type,
    this.color,
    this.isDanger = false,
  });

  /// 创建普通操作项
  const PiggyMenuItem.action({
    required String value,
    required IconData icon,
    required String label,
    // 转发式构造器不能带字段初始化器（`this.color`），所以走普通具名参数再传下去。
    Color? color,
    bool isDanger = false,
  }) : this._(
          value: value,
          icon: icon,
          label: label,
          type: PiggyMenuItemType.action,
          color: color,
          isDanger: isDanger,
        );

  /// 创建提示信息
  const PiggyMenuItem.tip({
    required String label,
    IconData icon = Icons.lightbulb_outline,
  }) : this._(
          icon: icon,
          label: label,
          type: PiggyMenuItemType.tip,
        );

  /// 创建分隔线
  const PiggyMenuItem.divider() : this._(type: PiggyMenuItemType.divider);
}

/// 项目「锚点浮层菜单」：贴在触发钮附近的浮层卡片，**不铺遮罩色**、点面板外
/// 任意处关闭，条目成组、组间 1px 分隔线。
///
/// 视觉与交互参考 orbit 移动端 `orbit_dropdown_panel.dart` 的
/// `showOrbitDropdownPanel`（页头 ⋮ 的载体）：卡片宽按文案收敛而不是铺满、
/// 右沿对齐锚右沿、裸前置图标（不套背景盒）+ 单一文案色，破坏性条目整行染红。
class PiggyPopupMenu extends StatelessWidget {
  /// 菜单项列表
  final List<PiggyMenuItem> items;

  /// 选中回调
  final ValueChanged<String>? onSelected;

  /// 主题色（用于图标着色）
  final Color? primaryColor;

  /// 自定义图标（无 [icon] 时用 `Icons.more_vert`）
  final Widget? icon;

  /// 自定义触发区（给了 [icon] 就整体替换触发钮，尺寸由调用方自控）
  final Widget? child;

  /// 提示文字
  final String? tooltip;

  /// 菜单弹出方向，默认贴在触发钮下方（靠右的按钮会自动右沿对齐并夹在屏内）。
  final PopupMenuPosition position;

  /// 内层 [PopupMenuButton] 的 key。列表卡片这类「角标按钮 + 长按共用一份菜单」
  /// 的场景把它传进来，就能用 `menuKey.currentState!.showButtonMenu()` 从长按
  /// 手势打开同一份菜单（`PopupMenuButtonState.showButtonMenu` 是公开的）。
  final PiggyMenuKey? menuKey;

  const PiggyPopupMenu({
    super.key,
    required this.items,
    this.onSelected,
    this.primaryColor,
    this.icon,
    this.child,
    this.tooltip,
    this.position = PopupMenuPosition.under,
    this.menuKey,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = PiggyTokens.isDark(context);
    final themeColor = primaryColor ?? Theme.of(context).colorScheme.primary;

    return PopupMenuButton<String>(
      key: menuKey,
      // PopupMenuButton 断言 icon 与 child 不能同时给（给了 child 就由它自控
      // 触发区外观与尺寸，icon 的默认值不能再兜）。
      icon: child != null
          ? null
          : icon ??
              Icon(
                Icons.more_vert,
                color: PiggyTokens.textPrimary(context),
              ),
      tooltip: tooltip,
      position: position,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        side: BorderSide(color: PiggyTokens.border(context)),
      ),
      color: PiggyTokens.surfaceElevated(context),
      elevation: isDark ? 8 : 4,
      offset: const Offset(0, 4),
      constraints: piggyMenuConstraints(context),
      onSelected: onSelected,
      itemBuilder: (context) => buildPiggyMenuEntries(
        context,
        items,
        primaryColor: themeColor,
      ),
      child: child,
    );
  }
}

/// 菜单 key 的类型别名：列表卡片这类「长按 + 角标按钮共用一份菜单」的场景要把
/// [PiggyPopupMenu.menuKey] 传进来，用 `key.currentState!.showButtonMenu()`
/// 从长按手势打开同一份菜单（`PopupMenuButtonState.showButtonMenu` 是公开的）。
typedef PiggyMenuKey = GlobalKey<PopupMenuButtonState<String>>;

/// 菜单条目列表 → Material 弹层条目。抽成顶层函数是为了让声明式的
/// [PiggyPopupMenu] 与编程入口共用同一套条目语言，不会各写一份。
List<PopupMenuEntry<String>> buildPiggyMenuEntries(
  BuildContext context,
  List<PiggyMenuItem> items, {
  Color? primaryColor,
}) {
  final themeColor = primaryColor ?? Theme.of(context).colorScheme.primary;
  return [
    for (final item in items)
      switch (item.type) {
        PiggyMenuItemType.action => _buildActionItem(context, item, themeColor),
        PiggyMenuItemType.tip => _buildTipItem(context, item),
        PiggyMenuItemType.divider => const PopupMenuDivider(height: 1),
      },
  ];
}

/// 菜单宽度区间（编程入口用）：不铺满，最宽 240。
BoxConstraints piggyMenuConstraints(BuildContext context) {
  final screen = MediaQuery.sizeOf(context).width;
  return BoxConstraints(
    minWidth: math.min(_kMenuMinWidth, screen - PiggyDimens.p16 * 2),
    maxWidth: math.min(
      _kMenuMaxWidth,
      math.min(
        screen * _kMenuWidthFactor,
        screen - PiggyDimens.p16 * 2,
      ),
    ),
  );
}

PopupMenuItem<String> _buildActionItem(
  BuildContext context,
  PiggyMenuItem item,
  Color themeColor,
) {
  // 着色优先级：显式 color > isDanger(error) > 主题色。error 必须走项目 token
  //（Colors.red 不跟随暗黑模式与主题错误色）。
  final tint =
      item.color ?? (item.isDanger ? PiggyTokens.error(context) : themeColor);
  return PopupMenuItem<String>(
    value: item.value,
    height: 48,
    child: Row(
      children: [
        // 裸前置标识：统一 24px 槽位居中，不套背景盒（与单选抽屉选项行同口径）
        SizedBox(
          width: 24,
          child: Icon(item.icon, size: 22, color: tint),
        ),
        const SizedBox(width: PiggyDimens.p12),
        Expanded(
          child: Text(
            item.label ?? '',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              color: item.color != null || item.isDanger
                  ? tint
                  : PiggyTokens.textPrimary(context),
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
      ],
    ),
  );
}

PopupMenuItem<String> _buildTipItem(BuildContext context, PiggyMenuItem item) {
  return PopupMenuItem<String>(
    value: 'tip',
    enabled: false,
    height: 40,
    child: Row(
      children: [
        Icon(
          item.icon,
          size: 16,
          color: PiggyTokens.textTertiary(context),
        ),
        const SizedBox(width: PiggyDimens.p8),
        Expanded(
          child: Text(
            item.label ?? '',
            style: TextStyle(
              fontSize: 12,
              color: PiggyTokens.textTertiary(context),
            ),
          ),
        ),
      ],
    ),
  );
}
