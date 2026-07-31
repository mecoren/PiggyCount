import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import '../ui/piggy_switcher.dart';

/// 设置页专用组件集合
///
/// 移植自 wait-home 项目的设置页 UI 模式，包含 4 个组件：
/// - [SettingsSectionLabel]：分组小标题（12pt w600，左缩进 8px）
/// - [SettingsCard]：分组卡片容器（16px 圆角，无阴影无边框）
/// - [SettingsNavItem]：导航项（图标 + 标题/副标题 + chevron）
/// - [SettingsToggleItem]：开关项（导航项变体，trailing 为 Switch）
///
/// 与 PiggyCount 现有的 [AppListTile] / [SectionCard] 并存，互不影响。
/// 仅用于设置页（MinePage + lib/pages/settings/*）。

/// 分组小标题
///
/// 视觉规格：
/// - 字号 12pt / 字重 w600
/// - 颜色 `onSurfaceVariant`
/// - 左缩进 8px（比卡片左缘再缩进 8）
/// - 与卡片间距 8px（由调用方通过 SizedBox 控制）
class SettingsSectionLabel extends StatelessWidget {
  const SettingsSectionLabel(this.label, {super.key});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

/// 设置分组卡片容器
///
/// 视觉规格：
/// - 圆角 16px
/// - 背景色 `PiggyTokens.surface`
/// - 无阴影、无边框（靠背景色对比分层）
/// - 无默认 padding（children 自带 padding）
/// - 卡片内项目之间不画 Divider，靠 padding 分隔
class SettingsCard extends StatelessWidget {
  const SettingsCard({
    super.key,
    required this.children,
    this.margin,
  });

  final List<Widget> children;

  /// 外边距，默认为零（由外层 ListView 的 16px padding 控制水平间距）
  final EdgeInsets? margin;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: margin ?? EdgeInsets.zero,
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
      ),
      child: Column(children: children),
    );
  }
}

/// 设置导航项
///
/// 视觉规格：
/// - 左侧 24px 强调色图标（`useIconBox=false` 主页风格，裸图标）
///   或图标盒（`useIconBox=true` 子页风格：8dp padding + 10% accent 背景 + 10px 圆角 + 20px 图标）
/// - 中间：标题 `bodyMedium w500`（14px）+ 副标题 `bodySmall onSurfaceVariant`（12px）
/// - 右侧：`Icons.chevron_right_rounded`（颜色 `onSurfaceVariant`），可被 [trailing] 覆盖
/// - 整体 padding：`horizontal: 16, vertical: 14`（带 trailing 项为 vertical: 12）
/// - 涟漪圆角 12px
class SettingsNavItem extends StatelessWidget {
  const SettingsNavItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.onTap,
    this.trailing,
    this.useIconBox = false,
    this.enabled = true,
    this.accentColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final VoidCallback? onTap;
  final Widget? trailing;

  /// 是否使用图标盒样式（子页风格）。
  /// - false（默认）：裸 24px 图标（MinePage 风格）
  /// - true：8dp padding + 10% accent 背景 + 10px 圆角盒 + 20px 图标（子页风格）
  final bool useIconBox;

  final bool enabled;

  /// 强调色，默认取主题色。允许外部覆盖以支持品牌色图标场景。
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final accent = accentColor ?? theme.colorScheme.primary;
    final hasCustomTrailing = trailing != null;

    final Widget leading;
    if (useIconBox) {
      leading = Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusMd),
        ),
        child: Icon(icon, size: 20, color: accent),
      );
    } else {
      leading = Icon(icon, size: 24, color: accent);
    }

    final tile = Padding(
      padding: EdgeInsets.symmetric(
        horizontal: 16,
        vertical: hasCustomTrailing ? 12 : 14,
      ),
      child: Row(
        children: [
          leading,
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (subtitle != null)
                  Text(
                    subtitle!,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          if (hasCustomTrailing)
            trailing!
          else if (enabled)
            Icon(
              Icons.chevron_right_rounded,
              color: theme.colorScheme.onSurfaceVariant,
            ),
        ],
      ),
    );

    return Opacity(
      opacity: enabled ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        child: tile,
      ),
    );
  }
}

/// 设置开关项
///
/// [SettingsNavItem] 的变体，trailing 固定为 [Switch]（Material）。
/// 开关样式由主题级 switchTheme 统一控制（无描边、紧凑、跟随主色）。
/// 其余视觉规格与 [SettingsNavItem] 一致。
class SettingsToggleItem extends StatelessWidget {
  const SettingsToggleItem({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.useIconBox = false,
    this.accentColor,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final bool useIconBox;
  final Color? accentColor;

  @override
  Widget build(BuildContext context) {
    return SettingsNavItem(
      icon: icon,
      title: title,
      subtitle: subtitle,
      onTap: onChanged == null ? null : () => onChanged!(!value),
      useIconBox: useIconBox,
      accentColor: accentColor,
      // 使用 PiggySwitcher（参考 wait-home WaitSwitcher 视觉规格）：
      // 46×26 轨道、16dp 白色描边滑块、无 ripple、跟随主色
      trailing: PiggySwitcher(
        value: value,
        onChanged: onChanged,
        activeColor: accentColor,
      ),
    );
  }
}
