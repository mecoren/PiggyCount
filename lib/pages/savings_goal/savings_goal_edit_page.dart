import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
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

  /// 「存入 / 取出」按钮：与分段控件同高（40）同圆角（`radiusSm`），
  /// 两个等宽动作键并排 —— 不用主色填充，避免与底部「保存」抢焦点。
  ButtonStyle get _savedActionStyle => OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(40),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
        ),
      );

  /// 币种选择（仅手动模式可改；账户模式锁定为账户币种）。
  Future<void> _pickCurrency() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: _currency,
      primaryColor: ref.read(primaryColorProvider),
      title: l10n.savingsGoalCurrency,
    );
    if (picked == null || !mounted) return;
    setState(() => _currency = picked.toUpperCase());
  }

  /// 起算日（必填，默认今天）。
  Future<void> _pickStartDate() async {
    final picked = await showWheelDatePicker(
      context,
      initial: _startDate,
      mode: WheelDatePickerMode.ymd,
      minDate: DateTime(2000),
      maxDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _startDate = picked);
  }

  /// 目标日期（可空；尾部清除键把它置回「未设置」）。
  Future<void> _pickTargetDate() async {
    final picked = await showWheelDatePicker(
      context,
      initial: _targetDate ?? DateTime.now(),
      mode: WheelDatePickerMode.ymd,
      minDate: DateTime(2000),
      maxDate: DateTime(2100),
    );
    if (picked == null || !mounted) return;
    setState(() => _targetDate = picked);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    String ymd(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return PiggyFormSheet(
      title: _isEdit ? l10n.savingsGoalEditTitle : l10n.savingsGoalAddTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _saving ? null : _save,
      confirmBusy: _saving,
      // 删除（仅编辑态）：标题栏左上角图标，与其它编辑抽屉一致。
      deleteLabel: _isEdit ? l10n.commonDelete : null,
      onDelete: _confirmDelete,
      deleteBusy: _saving,
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
          SizedBox(height: PiggyDimens.p20.scaled(context, ref)),

          // ---- 进度来源 ----
          //
          // 版式与搜索筛选抽屉同一套语言（PiggySectionLabel + 分段控件 +
          // PiggyValueRow），不要退回两行堆叠的 ListTile 或并排 ChoiceChip：
          // Chip 自带留白且各自成块，两三个并排就会显得零碎、高度也对不齐。
          PiggySectionLabel(l10n.savingsGoalSource),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          PiggySegmentedControl<bool>(
            selected: _useAccount,
            onChanged: (useAccount) => setState(() => _useAccount = useAccount),
            options: [
              PiggySegmentOption(
                value: false,
                label: l10n.savingsGoalSourceManual,
              ),
              PiggySegmentOption(
                value: true,
                label: l10n.savingsGoalSourceAccount,
              ),
            ],
          ),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),

          if (_useAccount)
            PiggyValueRow(
              icon: Icons.account_balance_wallet_outlined,
              label: l10n.savingsGoalAccount,
              placeholder: l10n.searchNotSet,
              value: _accountName ??
                  (_accountId != null ? l10n.savingsGoalAccountMissing : null),
              onTap: _pickAccount,
            )
          else ...[
            // 手动模式的进度是**表单草稿**（存入 / 取出只改草稿，保存才落库），
            // 所以这里只读展示当前值，改值走下面两个动作键。
            // 金额走 AmountText：跟随全局「隐藏金额」开关，别自己拼字符串。
            PiggyValueRow(
              icon: Icons.savings_outlined,
              label: l10n.savingsGoalSaved,
              valueWidget: AmountText(
                value: _saved,
                signed: false,
                showCurrency: true,
                currencyCode: _currency,
                style: PiggyTextTokens.body(context).copyWith(
                  color: PiggyTokens.primary(context),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _adjustSaved(deposit: false),
                    style: _savedActionStyle,
                    child: Text(l10n.savingsGoalWithdraw),
                  ),
                ),
                const SizedBox(width: PiggyDimens.p8),
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => _adjustSaved(deposit: true),
                    style: _savedActionStyle,
                    child: Text(l10n.savingsGoalDeposit),
                  ),
                ),
              ],
            ),
          ],
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          // 币种：手动模式可改；账户模式锁定为账户币种，只读 + 尾注说明出处。
          PiggyValueRow(
            icon: Icons.currency_exchange_outlined,
            label: l10n.savingsGoalCurrency,
            value: _currency,
            onTap: _useAccount ? null : _pickCurrency,
            trailingCaption:
                _useAccount ? l10n.savingsGoalCurrencyFollowsAccount : null,
          ),

          // ---- 日期 ----
          SizedBox(height: PiggyDimens.p20.scaled(context, ref)),
          PiggyValueRow(
            icon: Icons.event_outlined,
            label: l10n.savingsGoalStartDate,
            value: ymd(_startDate),
            onTap: _pickStartDate,
          ),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          PiggyValueRow(
            icon: Icons.event_available_outlined,
            label: l10n.savingsGoalTargetDate,
            placeholder: l10n.searchNotSet,
            value: _targetDate == null ? null : ymd(_targetDate!),
            onTap: _pickTargetDate,
            // 有值 → 尾部是清除键（取代箭头，同搜索筛选抽屉口径）
            onClear: _targetDate == null
                ? null
                : () => setState(() => _targetDate = null),
          ),

          SizedBox(height: PiggyDimens.p20.scaled(context, ref)),
          TextField(
            controller: _note,
            maxLines: 2,
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.savingsGoalNote,
            ),
          ),
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
