import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../models/ledger_display_item.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../pages/main/ledgers_page_new.dart';
import '../ui/dialog.dart';
import '../ui/option_sheet.dart';

/// 账本选择弹窗组件
///
/// 居中显示，用于快速切换账本。外壳走项目弹窗语言（[AppDialogShell]）：
/// 居中标题 + 项目卡片 + 底部分栏动作区，标题固定不随列表滚动。
///
/// 选项行复用单选列表抽屉的基准行 [PiggyOptionRow]（与「备注显示方式」等
/// 单选列表同一语言）：**文字靠左、不放左侧勾选**，标题 + 「币种 · N 笔」
/// 副文案，尾部给选中勾；高亮只给选中项（标题主色 + 尾部勾）。
class LedgerPickerDialog extends ConsumerWidget {
  const LedgerPickerDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final ledgersAsync = ref.watch(localLedgersProvider);
    final currentId = ref.watch(currentLedgerIdProvider);
    final primaryColor = ref.watch(primaryColorProvider);

    // 不再自绘 Dialog(shape radiusXl) + 关闭圆钮 + 裸字号标题；底部动作区
    // 交给 [AppDialogShell] 的 [PiggyDialogActionsBar]（末位取主题色）。
    return AppDialogShell(
      wide: true,
      title: Text(l10n.homeSwitchLedger),
      content: ledgersAsync.when(
        data: (ledgers) => _buildLedgerList(
          context,
          ref,
          ledgers,
          currentId,
          primaryColor,
        ),
        loading: () => const Padding(
          padding: EdgeInsets.all(32),
          child: Center(child: CircularProgressIndicator()),
        ),
        error: (e, _) => Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            'Error: $e',
            style: PiggyTextTokens.body(context)
                .copyWith(color: PiggyTokens.textSecondary(context)),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => const LedgersPageNew(),
              ),
            );
          },
          child: Text(l10n.homeManageLedgers),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }

  Widget _buildLedgerList(
    BuildContext context,
    WidgetRef ref,
    List<LedgerDisplayItem> ledgers,
    int currentId,
    Color primaryColor,
  ) {
    if (ledgers.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.book_outlined,
              size: 48,
              color: PiggyTokens.iconTertiary(context),
            ),
            const SizedBox(height: 12),
            Text(
              AppLocalizations.of(context).ledgersEmpty,
              style: TextStyle(color: PiggyTokens.textSecondary(context)),
            ),
          ],
        ),
      );
    }

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: ledgers.length,
      itemBuilder: (context, index) {
        final ledger = ledgers[index];
        final isSelected = ledger.id == currentId;

        return PiggyOptionRow(
          title: ledger.name,
          desc: '${ledger.currency} · ${ledger.transactionCount} 笔',
          isSelected: isSelected,
          primaryColor: primaryColor,
          onTap: () {
            if (!isSelected) {
              ref.read(currentLedgerIdProvider.notifier).state = ledger.id;
            }
            Navigator.pop(context);
          },
        );
      },
    );
  }
}

/// 显示账本选择弹窗
void showLedgerPicker(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => const LedgerPickerDialog(),
  );
}
