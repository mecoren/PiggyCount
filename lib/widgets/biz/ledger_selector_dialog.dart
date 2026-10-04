import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../l10n/app_localizations.dart';
import '../ui/dialog.dart';
import '../ui/piggy_spinner.dart';

/// 显示账本选择器
///
/// [currentLedgerId] 当前选中的账本ID（可选，用于高亮显示）
/// Returns: 选中的账本ID，如果取消则返回null
Future<int?> showLedgerSelector(
  BuildContext context, {
  int? currentLedgerId,
}) async {
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => LedgerSelectorDialog(
      currentLedgerId: currentLedgerId,
    ),
  );
}

/// 账本选择弹窗。
///
/// 走项目弹窗外壳（[AppDialogShell]：居中标题 + 项目卡片 + 底部「取消」），
/// 不再用 Material 默认外观的 `SimpleDialog`（左对齐标题 + 无收尾动作区，
/// 与全站弹窗语言不一致）。
class LedgerSelectorDialog extends ConsumerWidget {
  final int? currentLedgerId;

  const LedgerSelectorDialog({
    super.key,
    this.currentLedgerId,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final l10n = AppLocalizations.of(context);

    return AppDialogShell(
      wide: true,
      title: Text(l10n.ledgerSelectTitle),
      content: FutureBuilder<List<Ledger>>(
        future: repo.getAllLedgers(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: PiggySpinner(size: 36, color: PiggyTokens.primary(context)),
              ),
            );
          }

          final ledgers = snapshot.data!;
          if (ledgers.isEmpty) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                l10n.ledgersEmpty,
                textAlign: TextAlign.center,
                style: PiggyTextTokens.body(context)
                    .copyWith(color: PiggyTokens.textSecondary(context)),
              ),
            );
          }

          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final ledger in ledgers) _option(context, ledger),
            ],
          );
        },
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }

  Widget _option(BuildContext context, Ledger ledger) {
    final isSelected = ledger.id == currentLedgerId;
    final primaryColor = PiggyTokens.primary(context);
    return InkWell(
      onTap: () => Navigator.pop(context, ledger.id),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Row(
          children: [
            Icon(
              isSelected ? Icons.check_circle : Icons.radio_button_unchecked,
              color: isSelected
                  ? primaryColor
                  : PiggyTokens.textTertiary(context),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ledger.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                  color: isSelected
                      ? primaryColor
                      : PiggyTokens.textPrimary(context),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
