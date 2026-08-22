import 'package:piggycount/widgets/biz/piggy_icon.dart';
import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';

/// 统一空状态组件。
///
/// 默认展示 Piggy 图标 + 主文案(+ 可选副文案);可通过 [icon] 换成
/// 场景化图标,通过 [action] 提供一个引导按钮(如"去记一笔")。
class AppEmpty extends StatelessWidget {
  final String? text;
  final String? subtext;

  /// 场景化图标;不传则使用默认 Piggy logo 圆形底。
  final IconData? icon;

  /// 引导动作(如 FilledButton.tonal "去记一笔");null 则不显示。
  final Widget? action;
  const AppEmpty({
    super.key,
    this.text,
    this.subtext,
    this.icon,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primary = theme.colorScheme.primary;
    final bg = primary.withValues(alpha: 0.08);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 88,
              height: 88,
              decoration: BoxDecoration(
                color: bg,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: icon != null
                  ? Icon(icon, size: 44, color: primary)
                  : PiggyIcon(
                      size: 52,
                    ),
            ),
            const SizedBox(height: 14),
            Text(text ?? AppLocalizations.of(context).commonEmpty,
                style: theme.textTheme.bodyMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            if (subtext != null) ...[
              const SizedBox(height: 6),
              Text(subtext!, style: theme.textTheme.bodySmall),
            ],
            if (action != null) ...[
              const SizedBox(height: 16),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}
