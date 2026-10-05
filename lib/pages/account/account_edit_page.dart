import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/biz/day_of_month_picker.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
import '../../data/db.dart' as db;
import '../../l10n/app_localizations.dart';
import '../../services/billing/post_processor.dart';
import '../../utils/currencies.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../utils/account_type_utils.dart';
import '../../providers/credit_card_reminder_providers.dart';

/// 以底部抽屉形式弹出账户编辑器（新建 / 编辑通用）
///
/// 唯一入口：新建与编辑都走项目统一的**悬浮卡片表单抽屉**（[PiggyFormSheet]：
/// 居中标题 + 卡片内滚动表单 + 底部「取消｜保存」双等宽按钮），与云同步配置表单 /
/// 加密设置密码抽屉同款。表单逻辑仍在本文件的 [AccountEditPage]。
///
/// 编辑态的「隐藏 / 删除」渲染在表单主体末尾、「取消｜保存」之上；保存 / 删除 /
/// 隐藏都走 `Navigator.pop(true)`，调用方据返回值决定要不要连带刷新上一层。
Future<bool?> showAccountFormBottomSheet(
  BuildContext context, {
  required int ledgerId,
  db.Account? account,
}) async {
  return showPiggyFormSheet<bool>(
    context,
    builder: (_) => AccountEditPage(
      account: account,
      ledgerId: ledgerId,
    ),
  );
}

class AccountEditPage extends ConsumerStatefulWidget {
  final db.Account? account; // null表示新建
  final int ledgerId;

  const AccountEditPage({
    super.key,
    this.account,
    required this.ledgerId,
  });

  @override
  ConsumerState<AccountEditPage> createState() => _AccountEditPageState();
}

class _AccountEditPageState extends ConsumerState<AccountEditPage> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _nameController;
  late final TextEditingController _initialBalanceController;
  late final TextEditingController _creditLimitController;
  late final TextEditingController _bankNameController;
  late final TextEditingController _cardLastFourController;
  late final TextEditingController _noteController;
  late String _selectedType;
  late String _selectedCurrency;
  int? _billingDay;
  int? _paymentDueDay;
  bool _reminderEnabled = false;
  int _reminderDaysBefore = 3;
  bool _saving = false;
  bool _isNameDuplicate = false;
  String? _nameErrorText;
  // 账户类型 Tab：0 = 日常账户，1 = 估值账户
  int _typeTab = 0;

  // 日常账户类型（走流水）
  static const List<String> tradableAccountTypes = [
    'cash',
    'bank_card',
    'credit_card',
    'alipay',
    'wechat',
    'other',
  ];

  // 估值账户类型（只记当前价值 / 欠款，不走流水）
  static const List<String> valuationAccountTypes = [
    'real_estate',
    'vehicle',
    'investment',
    'insurance',
    'social_fund',
    'loan',
  ];

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(text: widget.account?.name ?? '');
    _initialBalanceController = TextEditingController(
      text: widget.account?.initialBalance != null &&
              widget.account!.initialBalance != 0.0
          ? widget.account!.initialBalance.abs().toStringAsFixed(2)
          : '',
    );
    _creditLimitController = TextEditingController(
      text: widget.account?.creditLimit != null
          ? widget.account!.creditLimit!.toStringAsFixed(2)
          : '',
    );
    _bankNameController =
        TextEditingController(text: widget.account?.bankName ?? '');
    _cardLastFourController =
        TextEditingController(text: widget.account?.cardLastFour ?? '');
    _noteController = TextEditingController(text: widget.account?.note ?? '');
    _selectedType = widget.account?.type ?? 'cash';
    _selectedCurrency = widget.account?.currency ?? 'CNY';
    _billingDay = widget.account?.billingDay;
    _paymentDueDay = widget.account?.paymentDueDay;
    _typeTab = isValuationOnlyType(_selectedType) ? 1 : 0;
    _loadReminderSettings();
  }

  Future<void> _loadReminderSettings() async {
    if (widget.account != null) {
      final prefs = await SharedPreferences.getInstance();
      final enabled =
          prefs.getBool('cc_reminder_enabled_${widget.account!.id}') ?? false;
      final daysBefore =
          prefs.getInt('cc_reminder_days_${widget.account!.id}') ?? 3;
      if (mounted) {
        setState(() {
          _reminderEnabled = enabled;
          _reminderDaysBefore = daysBefore;
        });
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _initialBalanceController.dispose();
    _creditLimitController.dispose();
    _bankNameController.dispose();
    _cardLastFourController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  bool get isEditing => widget.account != null;

  String _getInitialBalanceLabel(AppLocalizations l10n) {
    if (isValuationOnlyType(_selectedType)) {
      return isLiabilityType(_selectedType)
          ? l10n.valuationCurrentDebt
          : l10n.valuationCurrentValue;
    }
    return l10n.accountInitialBalance;
  }

  String _getInitialBalanceHint(AppLocalizations l10n) {
    if (isValuationOnlyType(_selectedType)) {
      return isLiabilityType(_selectedType)
          ? l10n.valuationDebtHint
          : l10n.valuationAccountHint;
    }
    switch (_selectedType) {
      case 'credit_card':
        return l10n.creditCardInitialBalanceHint;
      default:
        return l10n.accountInitialBalanceHint;
    }
  }

  /// v1.15.0: 检查账户名称是否重复
  Future<void> _checkNameDuplicate(String name) async {
    if (name.trim().isEmpty) {
      setState(() {
        _isNameDuplicate = false;
        _nameErrorText = null;
      });
      return;
    }

    final repo = ref.read(repositoryProvider);
    final allAccounts = await repo.getAllAccounts();
    final isDuplicate = allAccounts.any((account) {
      // 如果是编辑模式，排除当前账户本身
      if (isEditing && account.id == widget.account!.id) {
        return false;
      }
      return account.name == name.trim();
    });

    if (mounted) {
      setState(() {
        _isNameDuplicate = isDuplicate;
        _nameErrorText = isDuplicate
            ? AppLocalizations.of(context).accountNameDuplicate
            : null;
      });
    }
  }

  /// 切换账户类型：复用旧逻辑——离开信用卡/银行卡时清空对应字段。
  void _selectType(String type) {
    setState(() {
      final oldType = _selectedType;
      _selectedType = type;
      if (oldType == 'credit_card' && type != 'credit_card') {
        _creditLimitController.clear();
        _billingDay = null;
        _paymentDueDay = null;
        _reminderEnabled = false;
      }
      final wasBankOrCredit =
          oldType == 'bank_card' || oldType == 'credit_card';
      final isBankOrCredit = type == 'bank_card' || type == 'credit_card';
      if (wasBankOrCredit && !isBankOrCredit) {
        _bankNameController.clear();
        _cardLastFourController.clear();
      }
    });
  }

  TextStyle _sectionTitle(BuildContext context) => TextStyle(
        fontSize: PiggyTextTokens.fs14,
        fontWeight: FontWeight.w600,
        color: PiggyTokens.textPrimary(context),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);

    final typesForTab =
        _typeTab == 0 ? tradableAccountTypes : valuationAccountTypes;
    final isCreditCard = _selectedType == 'credit_card';
    final isBankCard = _selectedType == 'bank_card';

    // 分组间距：卡片已拍平，靠它分隔字段组（对齐云同步配置表单的字段节奏）
    final sectionGap = 16.0.scaled(context, ref);

    final formWidget = Form(
      key: _formKey,
      child: ListView(
        // 内容由 [PiggyFormSheet] 的 SingleChildScrollView 承载，内层 ListView
        // 必须 shrinkWrap + 禁止自身滚动，否则在无界高度里报错
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        padding: EdgeInsets.only(
          left: 12.0.scaled(context, ref),
          right: 12.0.scaled(context, ref),
          top: 8.0.scaled(context, ref),
          // 底部安全区由 PiggyFormSheet 的 PiggySheetCard 统一吃掉，这里再叠
          // 会双重留白
          bottom: 8.0.scaled(context, ref),
        ),
        children: [
          // ===== 账户类型（资产/负债 Tab + 缩小网格）=====
          SectionCard(
            margin: EdgeInsets.zero,
            borderColor: primaryColor,
            // 抽屉本身已是悬浮卡片，卡片套卡片显得多余 —— 拍平后字段直接落在
            // 抽屉底色上，与云同步配置表单同款
            flat: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                WaitSlidingSegmentedControl<int>(
                  selected: _typeTab,
                  accentColor: primaryColor,
                  segments: [
                    WaitSlidingSegment(
                      value: 0,
                      label: l10n.accountGroupTradable,
                    ),
                    WaitSlidingSegment(
                      value: 1,
                      label: l10n.accountTabValuation,
                    ),
                  ],
                  onValueChanged: (value) => setState(() => _typeTab = value),
                ),
                SizedBox(height: 16.0.scaled(context, ref)),
                GridView.count(
                  crossAxisCount: 4,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  mainAxisSpacing: 10.0.scaled(context, ref),
                  crossAxisSpacing: 10.0.scaled(context, ref),
                  childAspectRatio: 1.0,
                  children: typesForTab.map((type) {
                    final isSelected = _selectedType == type;
                    // 编辑模式禁止跨“可交易 / 估值”大类切换（语义不同）
                    final disabled = isEditing &&
                        isValuationOnlyType(type) !=
                            isValuationOnlyType(widget.account!.type);
                    return _AccountTypeCard(
                      type: type,
                      label: getAccountTypeLabel(context, type),
                      isSelected: isSelected,
                      primaryColor: primaryColor,
                      disabled: disabled,
                      onTap: disabled ? () {} : () => _selectType(type),
                    );
                  }).toList(),
                ),
              ],
            ),
          ),

          SizedBox(height: sectionGap),

          // ===== 基本（名称 + 币种/余额）=====
          SectionCard(
            margin: EdgeInsets.zero,
            borderColor: primaryColor,
            flat: true,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextFormField(
                  controller: _nameController,
                  decoration: piggyOutlinedDecoration(
                    context,
                    label: l10n.accountNameLabel,
                    hint: l10n.accountNameHint,
                    errorText: _nameErrorText,
                  ),
                  style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                  onChanged: (value) => _checkNameDuplicate(value),
                  validator: (value) {
                    if (value == null || value.trim().isEmpty) {
                      return l10n.accountNameRequired;
                    }
                    return null;
                  },
                ),
                SizedBox(height: 12.0.scaled(context, ref)),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SizedBox(
                      width: 120.0.scaled(context, ref),
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusLg),
                        onTap: () async {
                          // 同账单日：开选择器前先收键盘
                          FocusManager.instance.primaryFocus?.unfocus();
                          if (isEditing) {
                            final repo = ref.read(repositoryProvider);
                            final hasTransactions =
                                await repo.hasTransactions(widget.account!.id);
                            if (hasTransactions) {
                              if (!context.mounted) return;
                              await AppDialog.info(
                                context,
                                title: l10n.commonNotice,
                                message: l10n.accountCurrencyLocked,
                              );
                              return;
                            }
                          }
                          if (!context.mounted) return;
                          final picked = await _showCurrencyPicker(context,
                              initial: _selectedCurrency);
                          if (picked != null) {
                            setState(() => _selectedCurrency = picked);
                          }
                        },
                        child: InputDecorator(
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.ledgersCurrency,
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayCurrency(_selectedCurrency, context),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                                ),
                              ),
                              Icon(Icons.expand_more,
                                  size: 18.0.scaled(context, ref),
                                  color: PiggyTokens.iconTertiary(context)),
                            ],
                          ),
                        ),
                      ),
                    ),
                    SizedBox(width: 12.0.scaled(context, ref)),
                    Expanded(
                      child: TextFormField(
                        controller: _initialBalanceController,
                        decoration: piggyOutlinedDecoration(
                          context,
                          label: _getInitialBalanceLabel(l10n),
                          hint: _getInitialBalanceHint(l10n),
                          prefix: '${getCurrencySymbol(_selectedCurrency)} ',
                        ),
                        style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                        keyboardType: const TextInputType.numberWithOptions(
                            decimal: true, signed: true),
                        validator: (value) {
                          if (value != null && value.trim().isNotEmpty) {
                            if (double.tryParse(value.trim()) == null) {
                              return '请输入有效的金额';
                            }
                          }
                          return null;
                        },
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // ===== 信用卡信息（仅 credit_card）=====
          if (isCreditCard) ...[
            SizedBox(height: sectionGap),
            SectionCard(
              margin: EdgeInsets.zero,
              borderColor: primaryColor,
              flat: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.creditCardSettings, style: _sectionTitle(context)),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  // 信用额度（必填）
                  TextFormField(
                    controller: _creditLimitController,
                    decoration: piggyOutlinedDecoration(
                      context,
                      label: '${l10n.creditLimit} *',
                      hint: l10n.creditLimitHint,
                      prefix: '${getCurrencySymbol(_selectedCurrency)} ',
                    ),
                    style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                    keyboardType:
                        const TextInputType.numberWithOptions(decimal: true),
                    validator: (value) {
                      final t = value?.trim() ?? '';
                      final parsed = double.tryParse(t);
                      if (t.isEmpty || parsed == null || parsed <= 0) {
                        return l10n.creditLimitHint;
                      }
                      return null;
                    },
                  ),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  // 账单日 / 还款日（双列，必填）
                  Row(
                    children: [
                      Expanded(
                        child: _DayPickerTile(
                          label: '${l10n.billingDay} *',
                          value: _billingDay,
                          primaryColor: primaryColor,
                          onChanged: (day) => setState(() => _billingDay = day),
                        ),
                      ),
                      SizedBox(width: 12.0.scaled(context, ref)),
                      Expanded(
                        child: _DayPickerTile(
                          label: '${l10n.paymentDueDay} *',
                          value: _paymentDueDay,
                          primaryColor: primaryColor,
                          onChanged: (day) =>
                              setState(() => _paymentDueDay = day),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  // 开户行 / 卡号后四（双列）
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _bankNameController,
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.accountBankName,
                            hint: l10n.accountBankNameHint,
                          ),
                          style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                        ),
                      ),
                      SizedBox(width: 12.0.scaled(context, ref)),
                      Expanded(
                        child: TextFormField(
                          controller: _cardLastFourController,
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.accountCardLastFour,
                            hint: l10n.accountCardLastFourHint,
                          ).copyWith(counterText: ''),
                          style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                          maxLength: 4,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: 4.0.scaled(context, ref)),
                  Divider(color: PiggyTokens.divider(context)),
                  // 还款提醒
                  PiggySwitchListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      l10n.creditCardReminderTitle,
                      style: PiggyTextTokens.body(context),
                    ),
                    subtitle: Text(
                      l10n.creditCardReminderDesc,
                      style: PiggyTextTokens.label(context)
                          .copyWith(color: PiggyTokens.textTertiary(context)),
                    ),
                    value: _reminderEnabled,
                    activeColor: primaryColor,
                    onChanged: (value) =>
                        setState(() => _reminderEnabled = value),
                  ),
                  if (_reminderEnabled) ...[
                    SizedBox(height: 4.0.scaled(context, ref)),
                    Wrap(
                      spacing: 8.0.scaled(context, ref),
                      children: [1, 3, 5, 7].map((days) {
                        final isSelected = _reminderDaysBefore == days;
                        return ChoiceChip(
                          label: Text(l10n.creditCardReminderDaysBefore(days)),
                          selected: isSelected,
                          selectedColor: primaryColor.withValues(alpha: 0.15),
                          labelStyle: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
                            color: isSelected
                                ? primaryColor
                                : PiggyTokens.textSecondary(context),
                            fontWeight: isSelected
                                ? FontWeight.w600
                                : FontWeight.normal,
                          ),
                          onSelected: (_) =>
                              setState(() => _reminderDaysBefore = days),
                        );
                      }).toList(),
                    ),
                  ],
                ],
              ),
            ),
          ],

          // ===== 卡信息（仅 bank_card）=====
          if (isBankCard) ...[
            SizedBox(height: sectionGap),
            SectionCard(
              margin: EdgeInsets.zero,
              borderColor: primaryColor,
              flat: true,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.accountMetaInfo, style: _sectionTitle(context)),
                  SizedBox(height: 12.0.scaled(context, ref)),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: TextFormField(
                          controller: _bankNameController,
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.accountBankName,
                            hint: l10n.accountBankNameHint,
                          ),
                          style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                        ),
                      ),
                      SizedBox(width: 12.0.scaled(context, ref)),
                      Expanded(
                        child: TextFormField(
                          controller: _cardLastFourController,
                          decoration: piggyOutlinedDecoration(
                            context,
                            label: l10n.accountCardLastFour,
                            hint: l10n.accountCardLastFourHint,
                          ).copyWith(counterText: ''),
                          style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                          maxLength: 4,
                          keyboardType: TextInputType.number,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],

          // ===== 备注（所有类型）=====
          SizedBox(height: sectionGap),
          SectionCard(
            margin: EdgeInsets.zero,
            borderColor: primaryColor,
            flat: true,
            child: TextFormField(
              controller: _noteController,
              decoration: piggyOutlinedDecoration(
                context,
                label: l10n.accountNote,
                hint: l10n.accountNoteHint,
              ),
              style: const TextStyle(fontSize: PiggyTextTokens.fs16),
              maxLines: 3,
              minLines: 1,
            ),
          ),

          SizedBox(height: 24.0.scaled(context, ref)),

          // 隐藏/恢复 + 删除按钮（仅编辑时显示；账户隐藏 #240,产品设计
          // 01 §3.2:隐藏=留数据、可恢复、仍计资产,删除=硬删除且不可逆;
          // 二者并列,删除按钮样式保持原样不变）
          if (isEditing) ...[
            SizedBox(height: 12.0.scaled(context, ref)),
            SizedBox(
              width: double.infinity,
              height: 48.0.scaled(context, ref),
              child: OutlinedButton(
                onPressed: _saving ? null : _toggleHidden,
                style: OutlinedButton.styleFrom(
                  foregroundColor: primaryColor,
                  side: BorderSide(color: primaryColor, width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                        PiggyDimens.radiusSm.scaled(context, ref)),
                  ),
                ),
                child: Text(
                  widget.account!.hidden
                      ? l10n.accountUnhide
                      : l10n.accountHide,
                  style: const TextStyle(
                    fontSize: PiggyTextTokens.fs16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            SizedBox(height: 12.0.scaled(context, ref)),
            SizedBox(
              width: double.infinity,
              height: 48.0.scaled(context, ref),
              child: OutlinedButton(
                onPressed: _saving ? null : _delete,
                style: OutlinedButton.styleFrom(
                  foregroundColor: PiggyTokens.error(context),
                  // U3：边框与前景同源（Colors.red 不跟随暗黑/主题错误色）
                  side:
                      BorderSide(color: PiggyTokens.error(context), width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(
                        PiggyDimens.radiusSm.scaled(context, ref)),
                  ),
                ),
                child: Text(
                  l10n.commonDelete,
                  style: const TextStyle(
                    fontSize: PiggyTextTokens.fs16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );

    // 外壳走项目统一的悬浮卡片表单抽屉（[PiggyFormSheet]：居中标题 + 卡片内
    // 滚动 + 底部「取消｜保存」），与云同步配置 / 加密设置密码 / 账户新建同款。
    // 新建与编辑共用本表单，差别只有标题文案与编辑态多出的「隐藏 / 删除」。
    return PiggyFormSheet(
      title: isEditing ? l10n.accountEditTitle : l10n.accountNewTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: _save,
      confirmBusy: _saving || _isNameDuplicate,
      child: formWidget,
    );
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;

    // 信用卡：账单日 / 还款日必填（额度由表单 validator 拦截）
    if (_selectedType == 'credit_card' &&
        (_billingDay == null || _paymentDueDay == null)) {
      showToast(context, AppLocalizations.of(context).creditCardDaysRequired);
      return;
    }

    setState(() => _saving = true);

    try {
      final repo = ref.read(repositoryProvider);
      final name = _nameController.text.trim();
      final initialBalanceText = _initialBalanceController.text.trim();
      var initialBalance =
          initialBalanceText.isEmpty ? 0.0 : double.parse(initialBalanceText);

      // 贷款类型：用户输入正数，存储为负数
      if (_selectedType == 'loan' && initialBalance > 0) {
        initialBalance = -initialBalance;
      }

      // 信用卡字段
      final isCreditCard = _selectedType == 'credit_card';
      final creditLimitText = _creditLimitController.text.trim();
      final creditLimit = isCreditCard && creditLimitText.isNotEmpty
          ? double.parse(creditLimitText)
          : null;

      if (isEditing) {
        // 检查币种是否变化
        String? currencyToUpdate;
        if (_selectedCurrency != widget.account!.currency) {
          // 币种变化了，需要再次检查是否有交易
          final hasTransactions =
              await repo.hasTransactions(widget.account!.id);
          if (hasTransactions) {
            if (mounted) {
              setState(() => _saving = false);
              final l10n = AppLocalizations.of(context);
              await AppDialog.info(
                context,
                title: l10n.commonNotice,
                message: l10n.accountCurrencyLocked,
              );
            }
            return;
          }
          currencyToUpdate = _selectedCurrency;
        }

        // 如果从信用卡切换到其他类型，清空信用卡字段
        final wasCreditCard = widget.account!.type == 'credit_card';
        final clearCreditCardFields = wasCreditCard && !isCreditCard;

        // 元信息字段
        final isBankOrCredit =
            _selectedType == 'bank_card' || _selectedType == 'credit_card';
        final wasBankOrCredit = widget.account!.type == 'bank_card' ||
            widget.account!.type == 'credit_card';
        final clearMetadataFields = wasBankOrCredit && !isBankOrCredit;
        final bankName =
            isBankOrCredit ? _bankNameController.text.trim() : null;
        final cardLastFour =
            isBankOrCredit ? _cardLastFourController.text.trim() : null;
        final noteText = _noteController.text.trim();

        await repo.updateAccount(
          widget.account!.id,
          name: name,
          type: _selectedType,
          currency: currencyToUpdate,
          initialBalance: initialBalance,
          creditLimit: isCreditCard ? creditLimit : null,
          billingDay: isCreditCard ? _billingDay : null,
          paymentDueDay: isCreditCard ? _paymentDueDay : null,
          clearCreditCardFields: clearCreditCardFields,
          bankName: bankName != null && bankName.isNotEmpty ? bankName : null,
          cardLastFour: cardLastFour != null && cardLastFour.isNotEmpty
              ? cardLastFour
              : null,
          note: noteText.isNotEmpty ? noteText : null,
          clearMetadataFields: clearMetadataFields,
        );

        // 保存还款提醒设置
        if (isCreditCard) {
          await _saveReminderSettings(widget.account!.id);
        }
      } else {
        final isBankOrCredit =
            _selectedType == 'bank_card' || _selectedType == 'credit_card';
        final bankNameText =
            isBankOrCredit ? _bankNameController.text.trim() : null;
        final cardLastFourText =
            isBankOrCredit ? _cardLastFourController.text.trim() : null;
        final noteText = _noteController.text.trim();

        final id = await repo.createAccount(
          ledgerId: widget.ledgerId,
          name: name,
          type: _selectedType,
          currency: _selectedCurrency,
          initialBalance: initialBalance,
          creditLimit: creditLimit,
          billingDay: isCreditCard ? _billingDay : null,
          paymentDueDay: isCreditCard ? _paymentDueDay : null,
          bankName: bankNameText != null && bankNameText.isNotEmpty
              ? bankNameText
              : null,
          cardLastFour: cardLastFourText != null && cardLastFourText.isNotEmpty
              ? cardLastFourText
              : null,
          note: noteText.isNotEmpty ? noteText : null,
        );

        // 保存还款提醒设置
        if (isCreditCard) {
          await _saveReminderSettings(id);
        }
      }

      // 触发账本同步(后台异步,不阻塞页面关闭)
      if (mounted) {
        PostProcessor.sync(ref, ledgerId: widget.ledgerId);
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${AppLocalizations.of(context).commonError}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context);

    // 双重危险确认（各 5 秒倒计时）：
    //  · 有关联交易时第一段额外警告「交易记录中的账户信息将被清空」；
    //  · 有周期规则引用时追加提示「规则将失去账户」。
    //
    // 为什么这里不能用 getTransactionCountByAccount 只数交易：周期规则是
    // **独立于交易**的一份引用（recurring_transactions.account_id /
    // to_account_id）。它此前不参与守卫、也不在删除时清理 —— 账户删掉后规则
    // 到期仍会生成新记录，且引用指向已不存在的账户。删除实现已补上断开引用
    // （LocalRepository.deleteAccount），守卫这里同步把影响告知用户。
    // 表覆盖范围与 LocalRepository.getSyncEntityReferences 的同名条目逐字一致。
    final repo = ref.read(repositoryProvider);
    final refs = await repo.getAccountRefCounts(widget.account!.id);

    if (!mounted) return;
    final impacts = <String>[
      if (refs.transactions > 0)
        l10n.accountDeleteWarningMessage(refs.transactions),
      if (refs.recurring > 0) l10n.accountDeleteRecurringImpact(refs.recurring),
    ];
    final firstMessage =
        impacts.isEmpty ? l10n.accountDeleteConfirm : impacts.join('\n');
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.accountDeleteWarningTitle,
      firstMessage: firstMessage,
      secondMessage: l10n.accountDeleteReconfirmMessage,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);

    try {
      await repo.deleteAccount(widget.account!.id);

      // 触发账本同步(后台异步,不阻塞页面关闭)
      if (mounted) {
        PostProcessor.sync(ref, ledgerId: widget.ledgerId);
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.commonError}: $e');
      }
    } finally {
      if (mounted) {
        setState(() => _saving = false);
      }
    }
  }

  /// 隐藏 / 恢复账户（账户隐藏 #240,产品设计 01 §3.2/§五）。
  /// - 恢复:低风险、可逆,不弹确认,即时生效(同管理页「已隐藏」分区的恢复按钮)。
  /// - 隐藏:弹确认框,若该账户被活跃周期模板引用(E2)追加提示;隐藏后若它是
  ///   默认收/支账户则清空该设置(E3)。
  Future<void> _toggleHidden() async {
    final l10n = AppLocalizations.of(context);
    final account = widget.account!;
    final repo = ref.read(repositoryProvider);

    if (account.hidden) {
      setState(() => _saving = true);
      try {
        await repo.setAccountHidden(account.id, false);
        if (mounted) {
          PostProcessor.sync(ref, ledgerId: widget.ledgerId);
          showToast(context, l10n.accountRestoredToast);
          Navigator.of(context).pop(true);
        }
      } catch (e) {
        if (mounted) showToast(context, '${l10n.commonError}: $e');
      } finally {
        if (mounted) setState(() => _saving = false);
      }
      return;
    }

    // E2:隐藏前查活跃周期模板数,>0 则确认框追加提示。
    final recurringCount =
        await repo.getActiveRecurringCountByAccount(account.id);

    if (!mounted) return;
    final confirm = await AppDialog.confirm<bool>(
      context,
      title: l10n.accountHideConfirmTitle,
      message: recurringCount > 0
          ? '${l10n.accountHideConfirmBody}\n${l10n.accountHideRecurringWarn(recurringCount)}'
          : l10n.accountHideConfirmBody,
      okLabel: l10n.accountHide,
    );

    if (confirm != true) return;

    setState(() => _saving = true);
    try {
      await repo.setAccountHidden(account.id, true);

      // E3:隐藏的是默认收/支账户 → 清空该设置 + toast。
      final defaultIncomeId =
          await ref.read(defaultIncomeAccountIdProvider.future);
      final defaultExpenseId =
          await ref.read(defaultExpenseAccountIdProvider.future);
      var clearedDefault = false;
      if (defaultIncomeId == account.id) {
        await ref
            .read(defaultAccountSetterProvider)
            .setDefaultIncomeAccountId(null);
        ref.invalidate(defaultIncomeAccountIdProvider);
        clearedDefault = true;
      }
      if (defaultExpenseId == account.id) {
        await ref
            .read(defaultAccountSetterProvider)
            .setDefaultExpenseAccountId(null);
        ref.invalidate(defaultExpenseAccountIdProvider);
        clearedDefault = true;
      }

      if (mounted) {
        PostProcessor.sync(ref, ledgerId: widget.ledgerId);
        showToast(
          context,
          clearedDefault
              ? '${l10n.accountHiddenToast} · ${l10n.accountHideClearedDefault}'
              : l10n.accountHiddenToast,
        );
        Navigator.of(context).pop(true);
      }
    } catch (e) {
      if (mounted) showToast(context, '${l10n.commonError}: $e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _saveReminderSettings(int accountId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('cc_reminder_enabled_$accountId', _reminderEnabled);
    await prefs.setInt('cc_reminder_days_$accountId', _reminderDaysBefore);

    // 调度或取消提醒
    if (_reminderEnabled && _paymentDueDay != null) {
      await CreditCardReminderService.scheduleReminder(
        accountId: accountId,
        accountName: _nameController.text.trim(),
        paymentDueDay: _paymentDueDay!,
        daysBefore: _reminderDaysBefore,
      );
    } else {
      await CreditCardReminderService.cancelReminder(accountId);
    }
  }

  /// 显示币种选择器（统一走共用币种抽屉：国旗 + 选中高亮 + 搜索）
  Future<String?> _showCurrencyPicker(BuildContext context, {String? initial}) {
    return showCurrencyPickerSheet(
      context,
      selected: initial ?? '',
      primaryColor: ref.read(primaryColorProvider),
      title: AppLocalizations.of(context).ledgersSelectCurrency,
    );
  }
}

/// 日期选择行（1-28）— filled 输入框样式，可双列并排
class _DayPickerTile extends ConsumerWidget {
  final String label;
  final int? value;
  final Color primaryColor;
  final ValueChanged<int?> onChanged;

  const _DayPickerTile({
    required this.label,
    required this.value,
    required this.primaryColor,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final hasValue = value != null;
    return InkWell(
      onTap: () => _showDayPicker(context, l10n),
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(context, label: label),
        child: Row(
          children: [
            Expanded(
              child: Text(
                hasValue ? l10n.dayOfMonth(value!) : l10n.selectDay,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: PiggyTextTokens.fs16,
                  color: hasValue
                      ? PiggyTokens.textPrimary(context)
                      : PiggyTokens.textTertiary(context),
                ),
              ),
            ),
            Icon(Icons.expand_more,
                size: 18.0.scaled(context, ref),
                color: PiggyTokens.iconTertiary(context)),
          ],
        ),
      ),
    );
  }

  void _showDayPicker(BuildContext context, AppLocalizations l10n) async {
    // 先收起键盘并等其收完，避免输入框焦点残留导致选完日期后键盘又弹回来
    FocusManager.instance.primaryFocus?.unfocus();
    await Future.delayed(const Duration(milliseconds: 100));
    if (!context.mounted) return;
    // 复用共用 1~N 日网格抽屉（点选即应用并收起）
    final picked = await showDayOfMonthPickerSheet(
      context,
      title: label,
      selected: value,
    );
    if (picked != null) onChanged(picked);
  }
}

/// 账户类型选择卡片
class _AccountTypeCard extends ConsumerWidget {
  final String type;
  final String label;
  final bool isSelected;
  final Color primaryColor;
  final VoidCallback onTap;
  final bool disabled;

  const _AccountTypeCard({
    required this.type,
    required this.label,
    required this.isSelected,
    required this.primaryColor,
    required this.onTap,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 禁用态：灰底 + 浅边 + 灰字 + 图标淡化，明确区别于可选/选中
    final Color bg = disabled
        ? PiggyTokens.surfaceInput(context)
        : (isSelected
            ? primaryColor.withValues(alpha: 0.12)
            : PiggyTokens.surfaceElevated(context));
    final Color borderColor = disabled
        ? PiggyTokens.divider(context)
        : (isSelected ? primaryColor : PiggyTokens.border(context));
    final Color fg = disabled
        ? PiggyTokens.textTertiary(context)
        : (isSelected ? primaryColor : PiggyTokens.textSecondary(context));
    return InkWell(
      onTap: disabled ? null : onTap,
      borderRadius:
          BorderRadius.circular(PiggyDimens.radiusSm.scaled(context, ref)),
      child: Container(
        padding: EdgeInsets.symmetric(horizontal: 2.0.scaled(context, ref)),
        decoration: BoxDecoration(
          color: bg,
          border: Border.all(
            color: borderColor,
            width: isSelected ? 2 : 1,
          ),
          borderRadius:
              BorderRadius.circular(PiggyDimens.radiusSm.scaled(context, ref)),
        ),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Opacity(
              opacity: disabled ? 0.35 : 1.0,
              child: AccountTypeIcon(
                type: type,
                size: 24.0.scaled(context, ref),
              ),
            ),
            SizedBox(height: 6.0.scaled(context, ref)),
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: PiggyTextTokens.fs12,
                fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                color: fg,
              ),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}
