import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/category_selector_dialog.dart';
import '../../widgets/biz/ledger_selector_dialog.dart';
import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/custom_field_providers.dart';
import '../../services/data/recurring_transaction_service.dart';
import '../../services/system/logger_service.dart';
import '../../services/system/recurring_due_reminder_service.dart';
import '../../utils/category_utils.dart';
import '../../utils/currencies.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/custom_field_input.dart';
import '../../widgets/currency/currency_flag.dart';
import '../../widgets/currency/currency_picker_sheet.dart';

/// 以底部抽屉形式弹出周期账单编辑器（新建 / 编辑通用）。
///
/// 唯一入口：新建与编辑都走项目统一的**悬浮卡片表单抽屉**（[PiggyFormSheet]：
/// 居中标题 + 卡片内滚动表单 + 底部「取消｜保存」双等宽按钮），与预算 / 账户 /
/// 云同步配置表单同款。表单逻辑仍在本文件的 [RecurringTransactionEditPage]。
///
/// 编辑态的「删除」渲染在表单主体末尾、「取消｜保存」之上；保存 / 删除都走
/// `Navigator.pop(true)`，调用方据返回值决定要不要连带刷新上一层。
Future<bool?> showRecurringFormBottomSheet(
  BuildContext context, {
  RecurringTransaction? recurring,
}) {
  return showPiggyFormSheet<bool>(
    context,
    builder: (_) => RecurringTransactionEditPage(recurring: recurring),
  );
}

/// 周期账单编辑表单（悬浮卡片抽屉内容）。
class RecurringTransactionEditPage extends ConsumerStatefulWidget {
  final RecurringTransaction? recurring;

  const RecurringTransactionEditPage({super.key, this.recurring});

  @override
  ConsumerState<RecurringTransactionEditPage> createState() =>
      _RecurringTransactionEditPageState();
}

class _RecurringTransactionEditPageState
    extends ConsumerState<RecurringTransactionEditPage> {
  final _formKey = GlobalKey<FormState>();
  final _amountController = TextEditingController();
  final _noteController = TextEditingController();

  late String _type;
  late RecurringFrequency _frequency;
  late int _interval;
  late DateTime _startDate;
  DateTime? _endDate;
  int? _dayOfMonth;
  Category? _selectedCategory;
  int? _selectedAccountId;
  int? _selectedToAccountId; // 转账的目标账户
  late bool _enabled;
  bool _hasAttemptedSave = false; // 是否已尝试保存
  int? _selectedLedgerId; // 选中的账本ID
  bool _saving = false; // 抽屉「保存」进行中（防连点 + confirmBusy）

  /// v42(移植 BeeCount #444)模板币种:null = 所选账本的本位币。
  /// 与记账页 L12 同构 —— 币种优先联动:改币种 → 账户列表按新币种过滤、
  /// 已选账户清空。
  String? _currencyCode;

  /// 所选账本的本位币(异步查,用于判断「是否外币」与币种选择器的汇率基准)。
  String? _ledgerCurrency;

  /// v47 模板级自定义字段值(键为 fieldSyncId)。挂在模板上,每次生成实例
  /// 时整包注入;实例侧修改不影响模板。空 map = 未配置(落库 NULL)。
  Map<String, dynamic> _templateFieldValues = {};

  bool get _isEditing => widget.recurring != null;

  @override
  void initState() {
    super.initState();
    if (_isEditing) {
      _type = widget.recurring!.type;
      _frequency = RecurringFrequency.fromString(widget.recurring!.frequency);
      _interval = widget.recurring!.interval;
      _startDate = widget.recurring!.startDate;
      _endDate = widget.recurring!.endDate;
      _dayOfMonth = widget.recurring!.dayOfMonth;
      _selectedAccountId = widget.recurring!.accountId;
      _selectedToAccountId = widget.recurring!.toAccountId;
      _enabled = widget.recurring!.enabled;
      _selectedLedgerId = widget.recurring!.ledgerId;
      _currencyCode = widget.recurring!.currencyCode?.toUpperCase();
      _amountController.text = widget.recurring!.amount.toStringAsFixed(2);
      _noteController.text = widget.recurring!.note ?? '';
      _templateFieldValues =
          CustomFieldValueCodec.decode(widget.recurring!.templateFieldValues);
      _loadCategoryAndAccount();
    } else {
      _type = 'expense';
      _frequency = RecurringFrequency.monthly;
      _interval = 1;
      _startDate = DateTime.now();
      _dayOfMonth = DateTime.now().day;
      _enabled = true;
      // 新建时使用当前账本
      _selectedLedgerId = ref.read(currentLedgerIdProvider);
    }

    _loadLedgerCurrency();

    // 监听金额输入变化，更新按钮状态
    _amountController.addListener(() {
      setState(() {});
    });
  }

  /// 加载所选账本的本位币。账本切换后重新加载(币种字段与账户过滤都依赖它)。
  Future<void> _loadLedgerCurrency() async {
    final ledgerId = _selectedLedgerId;
    if (ledgerId == null) return;
    final ledger = await ref.read(repositoryProvider).getLedgerById(ledgerId);
    if (!mounted) return;
    setState(() {
      _ledgerCurrency = (ledger?.currency.isNotEmpty ?? false)
          ? ledger!.currency.toUpperCase()
          : 'CNY';
      // 模板币种恰等于新账本本位币 → 归一成 null(非外币)
      if (_currencyCode?.toUpperCase() == _ledgerCurrency) {
        _currencyCode = null;
      }
    });
  }

  /// 有效币种:模板币种 ?? 账本本位币。账户列表按它过滤,交易生成也落它。
  String _effectiveCurrency() =>
      _currencyCode ??
      _ledgerCurrency ??
      ref.read(currentLedgerCurrencyProvider);

  Future<void> _loadCategoryAndAccount() async {
    if (_isEditing && widget.recurring!.categoryId != null) {
      final repo = ref.read(repositoryProvider);

      final category =
          await repo.getCategoryById(widget.recurring!.categoryId!);

      setState(() {
        _selectedCategory = category;
      });
    }
  }

  @override
  void dispose() {
    _amountController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return PiggyFormSheet(
      title: _isEditing
          ? l10n.recurringTransactionEdit
          : l10n.recurringTransactionAdd,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(),
      // 不做 `_isFormValid()` 门控:必填项校验交给 _saveRecurringTransaction 内的
      // validate + _hasAttemptedSave(抽屉形态下按钮常在,错误提示才看得见)
      onConfirm: _saving ? null : _saveRecurringTransaction,
      confirmBusy: _saving,
      // 删除（仅编辑态）：标题栏左上角垃圾桶图标 —— 本表单字段多，放在字段区
      // 末尾会被推到屏幕外（用户以为没有删除入口）。
      deleteLabel: _isEditing ? l10n.commonDelete : null,
      onDelete: _deleteRecurringTransaction,
      deleteBusy: _saving,
      child: Form(
        key: _formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Type selection
            _buildTypeSelector(l10n),
            const SizedBox(height: PiggyDimens.p16),

            // Ledger selection
            _buildLedgerSelector(l10n),
            const SizedBox(height: PiggyDimens.p16),

            // Currency (v42 / 移植 BeeCount #444)
            _buildCurrencySelector(l10n),
            const SizedBox(height: PiggyDimens.p16),

            // Amount
            TextFormField(
              controller: _amountController,
              decoration: piggyOutlinedDecoration(
                context,
                label: l10n.importFieldAmount,
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return l10n.commonError;
                }
                if (double.tryParse(value) == null) {
                  return l10n.commonError;
                }
                return null;
              },
            ),
            const SizedBox(height: PiggyDimens.p16),

            // Category selection (not for transfer)
            if (_type != 'transfer') ...[
              _buildCategorySelector(l10n),
              const SizedBox(height: PiggyDimens.p16),
            ],

            // Account selection (from account)
            _buildAccountSelector(l10n, isFromAccount: true),
            const SizedBox(height: PiggyDimens.p16),

            // To account selection (only for transfer)
            if (_type == 'transfer') ...[
              _buildAccountSelector(l10n, isFromAccount: false),
              const SizedBox(height: PiggyDimens.p16),
            ],

            // Frequency
            _buildFrequencySelector(l10n),
            const SizedBox(height: PiggyDimens.p16),

            // Interval
            if (_frequency != RecurringFrequency.daily)
              _buildIntervalSelector(l10n),
            if (_frequency != RecurringFrequency.daily)
              const SizedBox(height: PiggyDimens.p16),

            // Day of month (for monthly)
            if (_frequency == RecurringFrequency.monthly)
              _buildDayOfMonthSelector(l10n),
            if (_frequency == RecurringFrequency.monthly)
              const SizedBox(height: PiggyDimens.p16),

            // Start date
            _buildDateField(
              label: l10n.recurringTransactionStartDate,
              date: _startDate,
              onTap: () => _selectDate(context, true),
            ),
            const SizedBox(height: PiggyDimens.p16),

            // End date
            _buildDateField(
              label: l10n.recurringTransactionEndDate,
              date: _endDate,
              onTap: () => _selectDate(context, false),
              allowClear: true,
              onClear: () => setState(() => _endDate = null),
            ),
            const SizedBox(height: PiggyDimens.p16),

            // Note
            TextFormField(
              controller: _noteController,
              decoration: piggyOutlinedDecoration(
                context,
                label: l10n.commonNoteHint,
              ),
              maxLines: 3,
            ),
            const SizedBox(height: PiggyDimens.p16),

            // v47 模板级自定义字段
            _buildTemplateCustomFields(l10n),
          ],
        ),
      ),
    );
  }

  Widget _buildTypeSelector(AppLocalizations l10n) {
    return RadioGroup<String>(
      groupValue: _type,
      onChanged: (value) {
        if (value == null) return;
        setState(() {
          _type = value;
          _selectedCategory = null; // Reset category when type changes
          // 转入账户只在收支两类下重置（转账选择自身带账户语义）
          if (value != 'transfer') {
            _selectedToAccountId = null; // Reset transfer account
          }
        });
      },
      child: Row(
        children: [
          Expanded(
            child: RadioListTile<String>(
              title: Text(l10n.categoryExpense,
                  style: const TextStyle(fontSize: PiggyTextTokens.fs14)),
              value: 'expense',
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: RadioListTile<String>(
              title: Text(l10n.categoryIncome,
                  style: const TextStyle(fontSize: PiggyTextTokens.fs14)),
              value: 'income',
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
          Expanded(
            child: RadioListTile<String>(
              title: Text(l10n.transferTitle,
                  style: const TextStyle(fontSize: PiggyTextTokens.fs14)),
              value: 'transfer',
              contentPadding: EdgeInsets.zero,
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCategorySelector(AppLocalizations l10n) {
    return InkWell(
      onTap: () => _selectCategory(),
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.categoryTitle,
          errorText: _getCategoryErrorText(),
        ),
        child: Text(
          _selectedCategory != null
              ? CategoryUtils.getDisplayName(_selectedCategory!.name, context)
              : l10n.commonSearch,
        ),
      ),
    );
  }

  Widget _buildLedgerSelector(AppLocalizations l10n) {
    return InkWell(
      onTap: () => _selectLedger(),
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.ledgerSelectTitle,
          errorText: _getLedgerErrorText(),
        ),
        child: FutureBuilder<Ledger?>(
          future: _selectedLedgerId != null
              ? ref.read(repositoryProvider).getLedgerById(_selectedLedgerId!)
              : Future.value(null),
          builder: (context, snapshot) {
            final ledgerName = snapshot.data?.name ?? l10n.ledgerSelect;
            return Text(ledgerName);
          },
        ),
      ),
    );
  }

  /// 币种字段(v42 / 移植 BeeCount #444)。默认=账本本位币,点开可改;改了之后
  /// 账户列表按新币种过滤(已选账户清空)。汇率不在此锁定 —— 每次生成按当日
  /// 汇率折算,故不展示折算预览,以免暗示「这笔换算已定」。
  Widget _buildCurrencySelector(AppLocalizations l10n) {
    final currency = _effectiveCurrency();
    return InkWell(
      onTap: _selectCurrency,
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.txCurrencyLabel,
        ),
        child: Row(
          children: [
            currencyFlag(context, currency, width: 22, height: 16, radius: 4),
            const SizedBox(width: 8),
            Expanded(child: Text(displayCurrency(currency, context))),
            const Icon(Icons.arrow_drop_down, size: 24),
          ],
        ),
      ),
    );
  }

  Future<void> _selectCurrency() async {
    final l10n = AppLocalizations.of(context);
    final String base =
        _ledgerCurrency ?? ref.read(currentLedgerCurrencyProvider);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: _effectiveCurrency(),
      primaryColor: ref.read(primaryColorProvider),
      title: l10n.txCurrencyPickerTitle,
      rateBase: base, // 展示各币种对账本本位币的汇率
    );
    if (picked == null || !mounted) return;
    final upper = picked.toUpperCase();
    if (upper == _effectiveCurrency()) return;
    setState(() {
      _currencyCode = upper == base.toUpperCase() ? null : upper;
      // 币种优先联动:账户列表按币种过滤,旧账户可能已不符 → 清空重选
      _selectedAccountId = null;
      _selectedToAccountId = null;
    });
  }

  Widget _buildAccountSelector(AppLocalizations l10n,
      {required bool isFromAccount}) {
    final accountId = isFromAccount ? _selectedAccountId : _selectedToAccountId;
    final label = isFromAccount
        ? (_type == 'transfer'
            ? l10n.transferFromAccount
            : l10n.accountSelectTitle)
        : l10n.transferToAccount;

    return InkWell(
      onTap: () => _selectAccount(isFromAccount: isFromAccount),
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: label,
          errorText: _getAccountErrorText(isFromAccount),
        ),
        child: FutureBuilder<Account?>(
          future: accountId != null
              ? ref.read(repositoryProvider).getAccount(accountId)
              : Future.value(null),
          builder: (context, snapshot) {
            final accountName = snapshot.data?.name ?? l10n.accountNone;
            return Text(accountName);
          },
        ),
      ),
    );
  }

  String? _getAccountErrorText(bool isFromAccount) {
    if (!_hasAttemptedSave) return null;

    final l10n = AppLocalizations.of(context);

    if (isFromAccount) {
      if (_type == 'transfer' && _selectedAccountId == null) {
        return l10n.transferSelectFromAccount;
      }
    } else {
      if (_type == 'transfer' && _selectedToAccountId == null) {
        return l10n.transferSelectToAccount;
      }
      if (_type == 'transfer' &&
          _selectedAccountId != null &&
          _selectedToAccountId != null &&
          _selectedAccountId == _selectedToAccountId) {
        return '转出账户和转入账户不能相同';
      }
    }

    return null;
  }

  String? _getLedgerErrorText() {
    if (!_hasAttemptedSave) return null;
    if (_selectedLedgerId == null) {
      return '请选择账本';
    }
    return null;
  }

  String? _getCategoryErrorText() {
    if (!_hasAttemptedSave) return null;
    if (_type != 'transfer' && _selectedCategory == null) {
      return '请选择分类';
    }
    return null;
  }

  bool _isFormValid() {
    // 检查金额
    if (_amountController.text.isEmpty ||
        double.tryParse(_amountController.text) == null) {
      return false;
    }

    // 检查账本
    if (_selectedLedgerId == null) {
      return false;
    }

    // 检查分类（非转账）
    if (_type != 'transfer' && _selectedCategory == null) {
      return false;
    }

    // 检查转账账户
    if (_type == 'transfer') {
      if (_selectedAccountId == null || _selectedToAccountId == null) {
        return false;
      }
      if (_selectedAccountId == _selectedToAccountId) {
        return false;
      }
    }

    return true;
  }

  Widget _buildFrequencySelector(AppLocalizations l10n) {
    String frequencyLabel;
    switch (_frequency) {
      case RecurringFrequency.daily:
        frequencyLabel = l10n.recurringTransactionDaily;
        break;
      case RecurringFrequency.weekly:
        frequencyLabel = l10n.recurringTransactionWeekly;
        break;
      case RecurringFrequency.monthly:
        frequencyLabel = l10n.recurringTransactionMonthly;
        break;
      case RecurringFrequency.yearly:
        frequencyLabel = l10n.recurringTransactionYearly;
        break;
    }

    return InkWell(
      onTap: () async {
        final result = await showWheelPicker<RecurringFrequency>(
          context,
          initial: _frequency,
          items: RecurringFrequency.values,
          labelBuilder: (freq) {
            switch (freq) {
              case RecurringFrequency.daily:
                return l10n.recurringTransactionDaily;
              case RecurringFrequency.weekly:
                return l10n.recurringTransactionWeekly;
              case RecurringFrequency.monthly:
                return l10n.recurringTransactionMonthly;
              case RecurringFrequency.yearly:
                return l10n.recurringTransactionYearly;
            }
          },
          title: l10n.recurringTransactionFrequency,
        );

        if (result != null) {
          setState(() {
            _frequency = result;
            if (_frequency == RecurringFrequency.daily) {
              _interval = 1;
            }
          });
        }
      },
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.recurringTransactionFrequency,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(frequencyLabel),
            const Icon(Icons.arrow_drop_down, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildIntervalSelector(AppLocalizations l10n) {
    String intervalLabel;
    switch (_frequency) {
      case RecurringFrequency.daily:
        intervalLabel = l10n.recurringTransactionEveryNDays(_interval);
        break;
      case RecurringFrequency.weekly:
        intervalLabel = l10n.recurringTransactionEveryNWeeks(_interval);
        break;
      case RecurringFrequency.monthly:
        intervalLabel = l10n.recurringTransactionEveryNMonths(_interval);
        break;
      case RecurringFrequency.yearly:
        intervalLabel = l10n.recurringTransactionEveryNYears(_interval);
        break;
    }

    return InkWell(
      onTap: () async {
        final result = await showWheelPicker<int>(
          context,
          initial: _interval,
          items: List.generate(12, (index) => index + 1),
          labelBuilder: (i) {
            switch (_frequency) {
              case RecurringFrequency.daily:
                return l10n.recurringTransactionEveryNDays(i);
              case RecurringFrequency.weekly:
                return l10n.recurringTransactionEveryNWeeks(i);
              case RecurringFrequency.monthly:
                return l10n.recurringTransactionEveryNMonths(i);
              case RecurringFrequency.yearly:
                return l10n.recurringTransactionEveryNYears(i);
            }
          },
          title: l10n.recurringTransactionInterval,
        );

        if (result != null) {
          setState(() {
            _interval = result;
          });
        }
      },
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.recurringTransactionInterval,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(intervalLabel),
            const Icon(Icons.arrow_drop_down, size: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildDayOfMonthSelector(AppLocalizations l10n) {
    return InkWell(
      onTap: () async {
        final result = await showWheelPicker<int>(
          context,
          initial: _dayOfMonth ?? 1,
          items: List.generate(31, (index) => index + 1),
          labelBuilder: (day) => '$day',
          title: l10n.recurringTransactionDayOfMonth,
        );

        if (result != null) {
          setState(() {
            _dayOfMonth = result;
          });
        }
      },
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: l10n.recurringTransactionDayOfMonth,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('${_dayOfMonth ?? 1}'),
            const Icon(Icons.arrow_drop_down, size: 24),
          ],
        ),
      ),
    );
  }

  /// v47 模板级自定义字段录入:与交易编辑器同款 [CustomFieldsSection]。
  /// 定义按所选账本隔离;该账本暂无定义时给一行空态提示(发现性)。
  /// ValueKey 按账本重建:子组件不随 initialValues 变化重置内部状态,
  /// 换账本必须换实例,配合 [_pruneTemplateValuesForLedger] 剪掉幽灵键。
  Widget _buildTemplateCustomFields(AppLocalizations l10n) {
    final ledgerId = _selectedLedgerId;
    if (ledgerId == null) return const SizedBox.shrink();
    final definitions =
        ref.watch(customFieldDefinitionsOnceProvider(ledgerId)).value ??
            const <CustomFieldDefinition>[];
    if (definitions.isEmpty) {
      return Text(
        l10n.customFieldSectionEmpty,
        // D1：字号走 label 令牌（12/继承行高与裸字面量同链路），
        // 不新增 ratchet 计数的 fontSize 字面量。
        style: PiggyTextTokens.label(context)
            .copyWith(color: PiggyTokens.textTertiary(context)),
      );
    }
    return CustomFieldsSection(
      key: ValueKey<String>('template-cf-$ledgerId'),
      definitions: definitions,
      initialValues: _templateFieldValues,
      onChanged: (values) {
        setState(() => _templateFieldValues = values);
      },
    );
  }

  Widget _buildDateField({
    required String label,
    required DateTime? date,
    required VoidCallback onTap,
    bool allowClear = false,
    VoidCallback? onClear,
  }) {
    return InkWell(
      onTap: onTap,
      child: InputDecorator(
        decoration: piggyOutlinedDecoration(
          context,
          label: label,
          suffixIcon: allowClear && date != null
              ? IconButton(
                  icon: const Icon(Icons.clear),
                  tooltip: AppLocalizations.of(context).tooltipClear,
                  onPressed: onClear,
                )
              : null,
        ),
        child: Text(
          date != null
              ? DateFormat.yMd().format(date)
              : AppLocalizations.of(context).recurringTransactionNoEndDate,
        ),
      ),
    );
  }

  Future<void> _selectDate(BuildContext context, bool isStartDate) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    // 开始日期最早只能是今天:禁止历史开始日期,避免回溯生成脏数据(issue #135);
    // 结束日期不早于开始日期。
    final minDate = isStartDate ? todayStart : _startDate;
    var initial = isStartDate ? _startDate : (_endDate ?? _startDate);
    if (initial.isBefore(minDate)) initial = minDate;

    final date = await showWheelDatePicker(
      context,
      initial: initial,
      minDate: minDate,
      maxDate: DateTime(2100),
    );

    if (date != null) {
      setState(() {
        if (isStartDate) {
          _startDate = date;
        } else {
          _endDate = date;
        }
      });
    }
  }

  Future<void> _selectLedger() async {
    if (!mounted) return;

    final selected = await showLedgerSelector(
      context,
      currentLedgerId: _selectedLedgerId,
    );

    if (selected != null) {
      setState(() {
        _selectedLedgerId = selected;
      });
      // 新账本本位币可能不同 → 重载并归一币种(_loadLedgerCurrency 内部处理)
      await _loadLedgerCurrency();
      // v47:换账本后,不属于新账本定义的 fieldSyncId 值剪掉 —— 值挂在
      // 新账本的字段定义上才有意义,跨账本残留会成为幽灵键(渲染不出、
      // 快照里却是脏数据)。
      await _pruneTemplateValuesForLedger(selected);
    }
  }

  /// 把模板值里不属于 [ledgerId] 字段定义的键剪掉(见 _selectLedger)。
  Future<void> _pruneTemplateValuesForLedger(int ledgerId) async {
    final defs =
        await ref.read(repositoryProvider).getDefinitionsForLedger(ledgerId);
    final validSyncIds = defs
        .map((d) => d.syncId)
        .whereType<String>()
        .where((s) => s.isNotEmpty)
        .toSet();
    final pruned = Map<String, dynamic>.from(_templateFieldValues)
      ..removeWhere((k, _) => !validSyncIds.contains(k));
    if (!mounted) return;
    setState(() => _templateFieldValues = pruned);
  }

  Future<void> _selectCategory() async {
    if (!mounted) return;

    final selected = await showCategorySelector(
      context,
      type: _type,
      currentCategoryId: _selectedCategory?.id,
    );

    if (selected != null) {
      setState(() {
        _selectedCategory = selected;
      });
    }
  }

  Future<void> _selectAccount({required bool isFromAccount}) async {
    final repo = ref.read(repositoryProvider);

    // 按**本模板的有效币种**过滤(v42 / 移植 BeeCount #444:此前硬按账本
    // 本位币过滤,外币账户根本选不到,且读的是 currentLedgerId 而非所选账本);
    // 排除已隐藏账户
    // (账户隐藏 #240 E2:该处历史上也缺 isTradableType,本期只补 hidden,不扩范围)
    final currency = _effectiveCurrency().toUpperCase();
    final allAccounts = await repo.getAllAccounts();
    var accounts = allAccounts
        .where((a) => a.currency.toUpperCase() == currency && !a.hidden)
        .toList();

    // 如果是选择转入账户，排除已选择的转出账户
    if (!isFromAccount && _selectedAccountId != null) {
      accounts = accounts.where((a) => a.id != _selectedAccountId).toList();
    }

    if (!mounted) return;

    final title = isFromAccount
        ? (_type == 'transfer'
            ? AppLocalizations.of(context).transferFromAccount
            : AppLocalizations.of(context).accountSelectTitle)
        : AppLocalizations.of(context).transferToAccount;

    final selected = await showDialog<int?>(
      context: context,
      builder: (context) => AppDialogShell(
        wide: true,
        title: Text(title),
        content: SizedBox(
          width: double.maxFinite,
          // 转入账户不给「不选择账户」兜底 → 该币种没有可选账户时列表会全空,
          // 给一句空态,别让用户对着空白弹窗猜(移植 BeeCount #444:切外币后常见)
          child: accounts.isEmpty && _type == 'transfer' && !isFromAccount
              ? Text(AppLocalizations.of(context).commonEmpty)
              : ListView.builder(
                  shrinkWrap: true,
                  itemCount: accounts.length +
                      (_type == 'transfer' && !isFromAccount
                          ? 0
                          : 1), // 转入账户不显示"无账户"
                  itemBuilder: (context, index) {
                    if (index == 0 && (_type != 'transfer' || isFromAccount)) {
                      return ListTile(
                        title: Text(AppLocalizations.of(context).accountNone),
                        onTap: () => Navigator.of(context).pop(null),
                      );
                    }
                    final accountIndex = _type == 'transfer' && !isFromAccount
                        ? index
                        : index - 1;
                    final account = accounts[accountIndex];
                    return ListTile(
                      title: Text(account.name),
                      onTap: () => Navigator.of(context).pop(account.id),
                    );
                  },
                ),
        ),
      ),
    );

    // 用户点击了选项或取消
    setState(() {
      if (isFromAccount) {
        _selectedAccountId = selected;
        // 如果转出账户与转入账户相同，清空转入账户
        if (_type == 'transfer' && selected == _selectedToAccountId) {
          _selectedToAccountId = null;
        }
      } else {
        _selectedToAccountId = selected;
      }
    });
  }

  Future<void> _saveRecurringTransaction() async {
    final l10n = AppLocalizations.of(context);

    // 标记为已尝试保存，触发错误提示显示
    setState(() {
      _hasAttemptedSave = true;
    });

    if (!_formKey.currentState!.validate()) {
      return;
    }

    if (!_isFormValid()) {
      return;
    }

    final repo = ref.read(repositoryProvider);

    setState(() => _saving = true);
    try {
      if (_isEditing) {
        // 编辑模式：检查是否需要重置 lastGeneratedDate
        bool shouldResetLastGenerated = false;
        if (widget.recurring!.lastGeneratedDate != null &&
            _startDate.isBefore(widget.recurring!.lastGeneratedDate!)) {
          shouldResetLastGenerated = true;
          logger.info('周期账单', '开始日期早于最后生成日期，重置 lastGeneratedDate');
        }

        await repo.updateRecurringTransaction(
          id: widget.recurring!.id,
          ledgerId: _selectedLedgerId!,
          type: _type,
          amount: double.parse(_amountController.text),
          categoryId: _type == 'transfer' ? null : _selectedCategory!.id,
          accountId: _selectedAccountId,
          toAccountId: _selectedToAccountId,
          note: _noteController.text.isEmpty ? null : _noteController.text,
          frequency: _frequency.value,
          interval: _interval,
          dayOfMonth: _dayOfMonth,
          dayOfWeek: null,
          monthOfYear: null,
          startDate: _startDate,
          endDate: _endDate,
          enabled: _enabled,
          currencyCode: _currencyCode, // null = 账本本位币
          templateFieldValues: _templateFieldValues, // 空 map = 清空
        );

        // 如果需要重置最后生成日期，单独更新
        if (shouldResetLastGenerated) {
          // 注意：这里需要先清空 lastGeneratedDate
          // 由于 updateLastGeneratedDate 不支持 null，我们需要直接在 updateRecurringTransaction 中处理
          // 暂时跳过这个步骤，后续如果需要可以扩展 Repository 接口
        }
      } else {
        // 新建模式
        await repo.addRecurringTransaction(
          ledgerId: _selectedLedgerId!,
          type: _type,
          amount: double.parse(_amountController.text),
          categoryId: _type == 'transfer' ? null : _selectedCategory!.id,
          accountId: _selectedAccountId,
          toAccountId: _selectedToAccountId,
          note: _noteController.text.isEmpty ? null : _noteController.text,
          frequency: _frequency.value,
          interval: _interval,
          dayOfMonth: _dayOfMonth,
          dayOfWeek: null,
          monthOfYear: null,
          startDate: _startDate,
          endDate: _endDate,
          currencyCode: _currencyCode, // null = 账本本位币
          templateFieldValues: _templateFieldValues, // 空 map = 未配置
        );
      }

      if (mounted) {
        Navigator.of(context).pop(true); // 返回 true 表示数据已更改
      }
      // 到期提醒跟随模板变更收敛（金额/频率/日期/启停都可能改了下次扣款日）。
      // fire-and-forget：不阻塞返回，失败只记日志（提醒丢了还有启动/前台恢复兜底）。
      unawaitedLog(
        RecurringDueReminderService(repository: repo).rescheduleAll(),
        '周期账单到期提醒重调度',
      );
    } catch (e, stackTrace) {
      // 使用 logger 记录详细错误信息
      logger.error('周期账单保存', '保存失败', e, stackTrace);
      if (mounted) {
        showToast(context, '${l10n.commonError}: $e');
      }
    } finally {
      // 抽屉保持打开时解除「保存」忙碌态；已 pop 的路径不必再 setState
      if (mounted && _saving) {
        setState(() => _saving = false);
      }
    }
  }

  Future<void> _deleteRecurringTransaction() async {
    // 不可恢复的实体删除 → 单次危险确认（3 秒时停），口径见 AGENTS.md
    // 「破坏性操作确认分档」。
    final confirmed = await showDangerConfirmDialog(
      context,
      title: AppLocalizations.of(context).commonDelete,
      message: AppLocalizations.of(context).recurringTransactionDeleteConfirm,
      okLabel: AppLocalizations.of(context).commonDelete,
      countdownSeconds: 3,
    );

    if (confirmed) {
      final repo = ref.read(repositoryProvider);
      await repo.deleteRecurringTransaction(widget.recurring!.id);

      if (mounted) {
        Navigator.of(context).pop(true); // 返回 true 表示数据已更改
      }
      // 模板已删 → 取消它那条到期提醒（ID 按 recurringId 分配，可精确撤销）
      unawaitedLog(
        RecurringDueReminderService(repository: repo)
            .cancelForTemplate(widget.recurring!.id),
        '周期账单到期提醒取消',
      );
    }
  }
}
