import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// PiggyCount 风格开关组件
///
/// 参考 wait-home 项目的 `WaitSwitcher`（SaltUI `SaltSwitcher` 视觉规格）：
/// - 轨道尺寸 46×26 dp，全圆角
/// - 内边距 5 dp
/// - 开启态轨道使用强调色 [activeColor]，关闭态轨道使用次要文字色 @ 10% alpha
/// - 滑块为 16 dp 圆形，4 dp 白色描边，中心透明以透出轨道色
/// - 位移动画 + 颜色动画 300 ms，[Curves.fastOutSlowIn]
/// - 使用 [GestureDetector] 实现无 ripple 点击
///
/// 当 [onChanged] 为 null 时开关为只读态（不响应手势）。
class PiggySwitcher extends StatelessWidget {
  const PiggySwitcher({
    super.key,
    required this.value,
    this.onChanged,
    this.activeColor,
    this.duration = const Duration(milliseconds: 300),
  });

  /// 当前是否开启
  final bool value;

  /// 状态变化回调；为 null 表示只读
  final ValueChanged<bool>? onChanged;

  /// 开启态轨道颜色；默认使用主题色
  final Color? activeColor;

  /// 动画时长；默认 300 ms
  final Duration duration;

  // 规格尺寸（逻辑像素 == dp）
  static const double _trackWidth = 46;
  static const double _trackHeight = 26;
  static const double _padding = 5;
  static const double _thumbSize = 16;
  static const double _thumbBorderWidth = 4;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    final accent =
        activeColor ?? Theme.of(context).colorScheme.primary;

    // 关闭态轨道色：次要文字色 @ 10% alpha，与 wait-home 一致的极淡灰
    final trackColor = value
        ? accent
        : PiggyTokens.textSecondary(context).withValues(alpha: 0.1);

    return Semantics(
      toggled: value,
      enabled: enabled,
      container: true,
      child: GestureDetector(
        onTap: enabled ? () => onChanged!(!value) : null,
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: duration,
          curve: Curves.fastOutSlowIn,
          width: _trackWidth,
          height: _trackHeight,
          padding: const EdgeInsets.all(_padding),
          decoration: BoxDecoration(
            color: trackColor,
            borderRadius: BorderRadius.circular(_trackHeight / 2),
          ),
          child: AnimatedAlign(
            duration: duration,
            curve: Curves.fastOutSlowIn,
            alignment: value ? Alignment.centerRight : Alignment.centerLeft,
            child: Container(
              width: _thumbSize,
              height: _thumbSize,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                // 白色描边环，中心透明透出轨道色
                border: Border.fromBorderSide(
                  BorderSide(
                    color: Colors.white,
                    width: _thumbBorderWidth,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// PiggyCount 风格列表项开关
///
/// 用于替换 Material [SwitchListTile]，保持与 [PiggySwitcher] 一致的视觉语言。
/// 左侧可选 [leading] + 标题/副标题，右侧固定 [PiggySwitcher]。
class PiggySwitchListTile extends StatelessWidget {
  const PiggySwitchListTile({
    super.key,
    this.leading,
    required this.title,
    this.subtitle,
    required this.value,
    this.onChanged,
    this.contentPadding,
    this.activeColor,
    this.dense = false,
  });

  /// 左侧图标/装饰组件
  final Widget? leading;

  /// 标题
  final Widget title;

  /// 副标题
  final Widget? subtitle;

  /// 当前是否开启
  final bool value;

  /// 状态变化回调
  final ValueChanged<bool>? onChanged;

  /// 内边距；默认适配非 dense / dense 两种规格
  final EdgeInsetsGeometry? contentPadding;

  /// 开启态强调色；默认使用主题色
  final Color? activeColor;

  /// 紧凑模式：减小垂直内边距与字号，对齐原 SwitchListTile.dense 行为
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final padding = contentPadding ??
        (dense
            ? const EdgeInsets.symmetric(horizontal: 16, vertical: 4)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 12));

    final titleStyle = dense
        ? theme.textTheme.bodyMedium?.copyWith(
            fontSize: 14,
            fontWeight: FontWeight.w500,
          )
        : theme.textTheme.bodyLarge?.copyWith(
            fontWeight: FontWeight.w500,
          );

    return InkWell(
      onTap: onChanged != null ? () => onChanged!(!value) : null,
      child: Padding(
        padding: padding,
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  DefaultTextStyle(
                    style: titleStyle ?? const TextStyle(),
                    child: title,
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 4),
                    DefaultTextStyle(
                      style: theme.textTheme.bodySmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ) ??
                          const TextStyle(),
                      child: subtitle!,
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            PiggySwitcher(
              value: value,
              onChanged: onChanged,
              activeColor: activeColor,
            ),
          ],
        ),
      ),
    );
  }
}
