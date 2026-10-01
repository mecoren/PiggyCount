import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

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
  final bool isDanger;

  const PiggyMenuItem._({
    this.value,
    this.icon,
    this.label,
    required this.type,
    this.isDanger = false,
  });

  /// 创建普通操作项
  const PiggyMenuItem.action({
    required String value,
    required IconData icon,
    required String label,
    bool isDanger = false,
  }) : this._(
          value: value,
          icon: icon,
          label: label,
          type: PiggyMenuItemType.action,
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

/// 美化的弹出菜单组件
class PiggyPopupMenu extends StatelessWidget {
  /// 菜单项列表
  final List<PiggyMenuItem> items;

  /// 选中回调
  final ValueChanged<String>? onSelected;

  /// 主题色（用于图标背景）
  final Color? primaryColor;

  /// 自定义图标
  final Widget? icon;

  /// 提示文字
  final String? tooltip;

  const PiggyPopupMenu({
    super.key,
    required this.items,
    this.onSelected,
    this.primaryColor,
    this.icon,
    this.tooltip,
  });

  @override
  Widget build(BuildContext context) {
    final isDark = PiggyTokens.isDark(context);
    final themeColor = primaryColor ?? Theme.of(context).colorScheme.primary;

    return PopupMenuButton<String>(
      icon: icon ?? Icon(
        Icons.more_vert,
        color: PiggyTokens.textPrimary(context),
      ),
      tooltip: tooltip,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      color: PiggyTokens.surface(context),
      elevation: isDark ? 8 : 4,
      offset: const Offset(0, 8),
      onSelected: onSelected,
      itemBuilder: (context) {
        final List<PopupMenuEntry<String>> entries = [];
        for (final item in items) {
          switch (item.type) {
            case PiggyMenuItemType.action:
              entries.add(_buildActionItem(context, item, themeColor));
              break;
            case PiggyMenuItemType.tip:
              entries.add(_buildTipItem(context, item));
              break;
            case PiggyMenuItemType.divider:
              entries.add(const PopupMenuDivider(height: 1));
              break;
          }
        }
        return entries;
      },
    );
  }

  PopupMenuItem<String> _buildActionItem(
    BuildContext context,
    PiggyMenuItem item,
    Color themeColor,
  ) {
    // 危险项走项目 error token（Colors.red 不跟随暗黑模式与主题错误色）
    final color = item.isDanger ? PiggyTokens.error(context) : themeColor;

    return PopupMenuItem<String>(
      value: item.value,
      height: 48,
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            ),
            child: Icon(item.icon, size: 18, color: color),
          ),
          const SizedBox(width: 12),
          Text(
            item.label ?? '',
            style: TextStyle(
              fontSize: 15,
              color: item.isDanger
                  ? PiggyTokens.error(context)
                  : PiggyTokens.textPrimary(context),
              fontWeight: FontWeight.w500,
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
          const SizedBox(width: 8),
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
}
