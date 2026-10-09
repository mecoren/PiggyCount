import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
import '../../widgets/ui/ui.dart';

/// 以底部抽屉形式弹出储蓄目标编辑器（新建 / 编辑通用）。
///
/// 与持仓 / 预算 / 周期账单同款：表单一律用悬浮卡片外壳 [PiggyFormSheet]，
/// 不另起全屏 Scaffold 表单页。
Future<bool?> showSavingsGoalFormBottomSheet(
  BuildContext context, {
  SavingsGoal? goal,
}) {
  return showPiggyFormSheet<bool>(
    context,
    builder: (_) => SavingsGoalEditPage(goal: goal),
  );
}

/// 储蓄目标编辑表单（悬浮卡片抽屉内容）。[goal] 为 null 即新建。
///
/// 两种进度来源互斥（见 prd/savings_goal/requirements.md §4.3）：
/// - **账户模式**：关联一个储蓄账户，进度 = 该账户余额；币种**锁定为账户币种**
///   （因此不需要视图期汇率折算，进度条不会随行情抖动）；
/// - **手动模式**：进度 = 手填的累计额，「存入 / 取出」调整的是**表单草稿**，
///   点「保存」才落库 —— 中途取消可撤销。
///
/// 写路径纪律：一律经 `BaseRepository` 的 `createSavingsGoal` /
/// `updateSavingsGoal` / `deleteSavingsGoal`（内部记 ledger-scoped change），
/// **不要**直接碰 Drift。
class SavingsGoalEditPage extends ConsumerStatefulWidget {
  const SavingsGoalEditPage({super.key, this.goal});

  final SavingsGoal? goal;

  @override
  ConsumerState<SavingsGoalEditPage> createState() =>
      _SavingsGoalEditPageState();
}

class _SavingsGoalEditPageState extends ConsumerState<SavingsGoalEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _amount;
  late final TextEditingController _note;

  /// 进度来源：true = 关联账户，false = 手动累计。
  bool _useAccount = false;
  int? _accountId;
  String? _accountName;
  String _currency = 'CNY';
  DateTime _startDate = DateTime.now();
  DateTime? _targetDate;

  /// 手动累计额的**表单草稿**（存入 / 取出只改它，保存才落库）。
  double _saved = 0;
  bool _saving = false;

  bool get _isEdit => widget.goal != null;

  @override
  void initState() {
    super.initState();
    final g = widget.goal;
    _name = TextEditingController(text: g?.name ?? '');
    _amount = TextEditingController(text: _formatNumber(g?.targetAmount));
    _note = TextEditingController(text: g?.note ?? '');
    _useAccount = g?.accountId != null;
    _accountId = g?.accountId;
    _currency = g?.currency ??
        (ref.read(currentLedgerProvider).value?.currency ?? 'CNY');
    _startDate = g?.startDate ?? DateTime.now();
    _targetDate = g?.targetDate;
    _saved = g?.savedAmount ?? 0;
    unawaited(_resolveAccountName());
  }

  @override
  void dispose() {
    _name.dispose();
    _amount.dispose();
    _note.dispose();
    super.dispose();
  }

  /// 回显关联账户名，并把币种锁到账户币种（账户模式下币种不可选）。
  Future<void> _resolveAccountName() async {
    final id = _accountId;
    if (id == null) return;
    final account = await ref.read(repositoryProvider).getAccount(id);
    if (!mounted) return;
    setState(() {
      _accountName = account?.name;
      if (account != null) _currency = account.currency;
    });
  }

  /// 数字回填：整数不带小数点（100.0 → 100）。
  static String _formatNumber(double? v) {
    if (v == null || v == 0) return '';
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  Future<void> _pickAccount() async {
    final accounts = await ref.read(repositoryProvider).getAllAccounts();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final primary = ref.read(primaryColorProvider);
    final picked = await showPiggyPickerSheet<Account>(
      context,
      builder: (sheetCtx) => PiggyPickerSheet(
        title: l10n.savingsGoalAccount,
        maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.7,
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p16),
          children: [
            for (final a in accounts)
              PiggyOptionRow(
                title: a.name,
                isSelected: a.id == _accountId,
                primaryColor: primary,
                onTap: () => Navigator.pop(sheetCtx, a),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() {
      _accountId = picked.id;
      _accountName = picked.name;
      // 账户模式锁定币种 = 账户币种。
      _currency = picked.currency;
    });
  }

  /// 存入 / 取出：弹金额输入，只改表单草稿。
  ///
  /// controller 由 [_AmountPromptDialog] **自己持有并释放** —— 绝不在
  /// `await showDialog` 之后手动 dispose：弹窗退场动画期间 `TextField` 仍会
  /// rebuild，用已释放的 controller 会抛
  /// 「A TextEditingController was used after being disposed」，并连锁触发
  /// element 卸载期断言（`_dependents.isEmpty`）导致整页红屏。
  Future<void> _adjustSaved({required bool deposit}) async {
    final l10n = AppLocalizations.of(context);
    final amount = await showDialog<double>(
      context: context,
      builder: (_) => _AmountPromptDialog(
        title: deposit ? l10n.savingsGoalDeposit : l10n.savingsGoalWithdraw,
        amountLabel: l10n.savingsGoalAmountLabel,
      ),
    );

    if (amount == null || amount <= 0 || !mounted) return;
    setState(() {
      _saved = deposit ? _saved + amount : _saved - amount;
    });
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      showToast(context, l10n.savingsGoalValidationNameRequired);
      return;
    }
    final target = double.tryParse(_amount.text.trim());
    if (target == null || target <= 0) {
      showToast(context, l10n.savingsGoalValidationAmountInvalid);
      return;
    }
    if (_useAccount && _accountId == null) {
      showToast(context, l10n.savingsGoalValidationAccountRequired);
      return;
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repositoryProvider);
      final note = _note.text.trim();
      final accountId = _useAccount ? _accountId : null;
      if (_isEdit) {
        await repo.updateSavingsGoal(
          widget.goal!.id,
          name: name,
          targetAmount: target,
          currency: _currency,
          accountId: accountId,
          // 切回手动模式必须显式置空（null 兼职表达「不改」）。
          clearAccount: accountId == null,
          savedAmount: _saved,
          startDate: _startDate,
          targetDate: _targetDate,
          clearTargetDate: _targetDate == null,
          note: note.isEmpty ? null : note,
          clearNote: note.isEmpty,
        );
      } else {
        await repo.createSavingsGoal(
          ledgerId: ref.read(currentLedgerIdProvider),
          name: name,
          targetAmount: target,
          currency: _currency,
          accountId: accountId,
          savedAmount: _saved,
          startDate: _startDate,
          targetDate: _targetDate,
          note: note.isEmpty ? null : note,
        );
      }
      if (!mounted) return;
      showToast(context, l10n.savingsGoalSaveSuccess);
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context);
    // 不可恢复的实体删除 → **单次危险确认（3 秒时停）**：确认按钮在倒计时
    // 归零前禁用并显示剩余秒数，防连续快速点击误触。口径见 AGENTS.md
    // 「破坏性操作确认分档」（普通双按钮确认只允许用于可恢复的删除）。
    final confirmed = await showDangerConfirmDialog(
      context,
      title: l10n.savingsGoalDeleteConfirmTitle,
      message: l10n.savingsGoalDeleteConfirmBody(widget.goal!.name),
      okLabel: l10n.commonDelete,
      countdownSeconds: 3,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).deleteSavingsGoal(widget.goal!.id);
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _fieldLabel(String text) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          text,
          style: PiggyTextTokens.caption(context).copyWith(
            fontWeight: FontWeight.w600,
            color: PiggyTokens.textSecondary(context),
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primary = ref.watch(primaryColorProvider);
    final dateStyle = PiggyTextTokens.body(context);

    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return PiggyFormSheet(
      title: _isEdit ? l10n.savingsGoalEditTitle : l10n.savingsGoalAddTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _saving ? null : _save,
      confirmBusy: _saving,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _name,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.savingsGoalName,
              hint: l10n.savingsGoalNameHint,
            ),
          ),
          SizedBox(height: PiggyDimens.p16.scaled(context, ref)),
          TextField(
            controller: _amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.savingsGoalTargetAmount,
            ),
          ),
          SizedBox(height: PiggyDimens.p16.scaled(context, ref)),

          // ---- 进度来源 ----
          _fieldLabel(l10n.savingsGoalSource),
          Wrap(
            spacing: 8,
            children: [
              ChoiceChip(
                label: Text(l10n.savingsGoalSourceManual),
                selected: !_useAccount,
                onSelected: (_) => setState(() => _useAccount = false),
              ),
              ChoiceChip(
                label: Text(l10n.savingsGoalSourceAccount),
                selected: _useAccount,
                onSelected: (_) => setState(() => _useAccount = true),
              ),
            ],
          ),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),

          if (_useAccount)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.savingsGoalAccount),
              subtitle: Text(
                _accountName ??
                    (_accountId != null
                        ? l10n.savingsGoalAccountMissing
                        : l10n.searchNotSet),
              ),
              onTap: _pickAccount,
              trailing: const Icon(Icons.chevron_right, size: 24),
            )
          else ...[
            // 手动模式：币种可选 + 已存草稿（存入 / 取出）
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.savingsGoalCurrency),
              subtitle: Text(_currency),
              onTap: () async {
                final picked = await showCurrencyPickerSheet(
                  context,
                  selected: _currency,
                  primaryColor: primary,
                  title: l10n.savingsGoalCurrency,
                );
                if (picked != null && mounted) {
                  setState(() => _currency = picked.toUpperCase());
                }
              },
              trailing: const Icon(Icons.chevron_right, size: 24),
            ),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '${l10n.savingsGoalSaved}: ${_saved.toStringAsFixed(2)} $_currency',
                    style: dateStyle,
                  ),
                ),
                TextButton(
                  onPressed: () => _adjustSaved(deposit: true),
                  child: Text(l10n.savingsGoalDeposit),
                ),
                TextButton(
                  onPressed: () => _adjustSaved(deposit: false),
                  child: Text(l10n.savingsGoalWithdraw),
                ),
              ],
            ),
          ],

          // 账户模式：币种跟随账户，只读展示（不做视图期汇率折算）
          if (_useAccount)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(l10n.savingsGoalCurrency),
              subtitle: Text(_currency),
              trailing: Text(
                l10n.savingsGoalCurrencyFollowsAccount,
                style: PiggyTextTokens.caption(context),
              ),
            ),

          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),

          // ---- 日期 ----
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.savingsGoalStartDate),
            subtitle: Text(ymd(_startDate)),
            onTap: () async {
              final picked = await showWheelDatePicker(
                context,
                initial: _startDate,
                mode: WheelDatePickerMode.ymd,
                minDate: DateTime(2000),
                maxDate: DateTime(2100),
              );
              if (picked != null && mounted) {
                setState(() => _startDate = picked);
              }
            },
            trailing: const Icon(Icons.calendar_today, size: 20),
          ),
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(l10n.savingsGoalTargetDate),
            subtitle: Text(
              _targetDate != null ? ymd(_targetDate!) : l10n.searchNotSet,
            ),
            onTap: () async {
              final picked = await showWheelDatePicker(
                context,
                initial: _targetDate ?? DateTime.now(),
                mode: WheelDatePickerMode.ymd,
                minDate: DateTime(2000),
                maxDate: DateTime(2100),
              );
              if (picked != null && mounted) {
                setState(() => _targetDate = picked);
              }
            },
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_targetDate != null)
                  IconButton(
                    icon: const Icon(Icons.clear, size: 20),
                    tooltip: l10n.tooltipClear,
                    onPressed: () => setState(() => _targetDate = null),
                  ),
                const Icon(Icons.calendar_today, size: 20),
              ],
            ),
          ),

          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          TextField(
            controller: _note,
            maxLines: 2,
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.savingsGoalNote,
            ),
          ),

          if (_isEdit) ...[
            SizedBox(height: PiggyDimens.p16.scaled(context, ref)),
            Center(
              child: TextButton.icon(
                onPressed: _saving ? null : _confirmDelete,
                icon: const Icon(Icons.delete_outline, size: 18),
                style: TextButton.styleFrom(
                  foregroundColor: PiggyTokens.error(context),
                ),
                label: Text(l10n.commonDelete),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// 金额输入弹窗（「存入 / 取出」共用）。
///
/// 刻意做成独立 StatefulWidget 而不是「`showDialog` 里塞一个局部
/// `TextEditingController`」：局部 controller 只能在 `await` 返回后手动
/// `dispose()`，而那一刻弹窗的退场动画尚未结束、`TextField` 仍会 rebuild →
/// 撞「A TextEditingController was used after being disposed」→ element 树
/// 连锁损坏。让弹窗自己管生命周期，随 route 一起释放才是安全写法。
class _AmountPromptDialog extends StatefulWidget {
  const _AmountPromptDialog({required this.title, required this.amountLabel});

  final String title;
  final String amountLabel;

  @override
  State<_AmountPromptDialog> createState() => _AmountPromptDialogState();
}

class _AmountPromptDialogState extends State<_AmountPromptDialog> {
  final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double? get _amount => double.tryParse(_controller.text.trim());

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppDialogShell(
      title: Text(widget.title),
      content: TextField(
        controller: _controller,
        autofocus: true,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: piggyOutlinedDecoration(
          context,
          label: widget.amountLabel,
        ),
        onSubmitted: (_) => Navigator.pop(context, _amount),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, _amount),
          child: Text(l10n.commonConfirm),
        ),
      ],
    );
  }
}
