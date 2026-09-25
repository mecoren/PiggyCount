import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../models/ai_quick_command.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../providers/theme_providers.dart';

/// AI快捷指令横条组件
class AIQuickCommandsBar extends ConsumerWidget {
  /// 点击快捷指令的回调
  final Function(AIQuickCommand) onCommandTap;

  const AIQuickCommandsBar({
    super.key,
    required this.onCommandTap,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final commands = AIQuickCommands.getAllCommands();
    final primaryColor = ref.watch(primaryColorProvider);

    return SizedBox(
      height: 48.0.scaled(context, ref),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.only(
          left: 12.0.scaled(context, ref),
          right: 12.0.scaled(context, ref),
          bottom: 6.0.scaled(context, ref),
          top: 0,
        ),
        itemCount: commands.length,
        separatorBuilder: (_, __) => SizedBox(width: 8.0.scaled(context, ref)),
        itemBuilder: (context, index) {
          final command = commands[index];
          return _QuickCommandCard(
            command: command,
            l10n: l10n,
            primaryColor: primaryColor,
            onTap: () => onCommandTap(command),
          );
        },
      ),
    );
  }
}

/// 快捷指令卡片
class _QuickCommandCard extends ConsumerWidget {
  final AIQuickCommand command;
  final AppLocalizations l10n;
  final Color primaryColor;
  final VoidCallback onTap;

  const _QuickCommandCard({
    required this.command,
    required this.l10n,
    required this.primaryColor,
    required this.onTap,
  });

  String _getTitle() {
    switch (command.titleKey) {
      case 'aiQuickCommandFinancialHealthTitle':
        return l10n.aiQuickCommandFinancialHealthTitle;
      case 'aiQuickCommandMonthlyExpenseTitle':
        return l10n.aiQuickCommandMonthlyExpenseTitle;
      case 'aiQuickCommandCategoryAnalysisTitle':
        return l10n.aiQuickCommandCategoryAnalysisTitle;
      case 'aiQuickCommandBudgetPlanningTitle':
        return l10n.aiQuickCommandBudgetPlanningTitle;
      case 'aiQuickCommandAbnormalExpenseTitle':
        return l10n.aiQuickCommandAbnormalExpenseTitle;
      case 'aiQuickCommandSavingTipsTitle':
        return l10n.aiQuickCommandSavingTipsTitle;
      default:
        return command.titleKey;
    }
  }

  /// 指令说明文案的解析（与 [_getTitle] 同构）。
  ///
  /// 这套 `aiQuickCommand*Desc`（4 语言都有译文）此前是**死键**：模型上的
  /// `descriptionKey` 被赋值但全仓库无人读取 —— 静态分析清零那轮
  /// （commit 252a4e8）把当时未使用的 `_getDescription` 直接删了。见下方
  /// build 里为何用 Tooltip 而不是第二行文本来消费它。
  String? _getDescription() {
    final key = command.descriptionKey;
    if (key == null || key.isEmpty) return null;
    switch (key) {
      case 'aiQuickCommandFinancialHealthDesc':
        return l10n.aiQuickCommandFinancialHealthDesc;
      case 'aiQuickCommandMonthlyExpenseDesc':
        return l10n.aiQuickCommandMonthlyExpenseDesc;
      case 'aiQuickCommandCategoryAnalysisDesc':
        return l10n.aiQuickCommandCategoryAnalysisDesc;
      case 'aiQuickCommandBudgetPlanningDesc':
        return l10n.aiQuickCommandBudgetPlanningDesc;
      case 'aiQuickCommandAbnormalExpenseDesc':
        return l10n.aiQuickCommandAbnormalExpenseDesc;
      case 'aiQuickCommandSavingTipsDesc':
        return l10n.aiQuickCommandSavingTipsDesc;
      default:
        return key;
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isDark = PiggyTokens.isDark(context);
    final title = _getTitle();
    final description = _getDescription();

    final card = Material(
      color: PiggyTokens.surface(context),
      borderRadius: BorderRadius.circular(8.0.scaled(context, ref)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8.0.scaled(context, ref)),
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: 10.0.scaled(context, ref),
            vertical: 8.0.scaled(context, ref),
          ),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(8.0.scaled(context, ref)),
            border: Border.all(
              color: isDark
                  ? primaryColor.withAlpha(77) // 30% 透明度
                  : PiggyTokens.border(context),
              width: 1.0,
            ),
          ),
          child: Center(
            child: Text(
              title,
              style: TextStyle(
                fontSize: 12.0.scaled(context, ref),
                fontWeight: FontWeight.w500,
                color: PiggyTokens.textPrimary(context),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ),
      ),
    );

    // 指令条是固定 48px 高的单行横滑条（AIQuickCommandsBar 的 SizedBox），
    // 卡片里放不下第二行 —— 说明文案改用长按/悬停提示承载：既不挤动布局，
    // 又让已有 4 语言译文的 aiQuickCommand*Desc 不再是死键。
    if (description == null) return card;
    return Tooltip(message: description, child: card);
  }
}
