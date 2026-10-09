// 搜索页「筛选」抽屉：八个筛选维度集中在一个悬浮卡片抽屉里。
//
// 相比旧的居中弹窗（AppDialogShell + ListTile 标题/副标题两行堆叠），这里做了
// 三件事：
// - 换底部抽屉外壳（PiggyFormSheet）：抓取条 + 居中标题 + 底部「取消｜确定」，
//   与账户 / 标签 / 币种 / 分类等二级选择器同一手感；
// - 每个维度统一成「图标 + 名称 + 当前值 + 箭头」的一行，值取主色并带尾部 X
//   单独清除，不再用两行堆叠的标题/副标题；
// - 附件从三个并排 ChoiceChip 换成分段控件（与自定义字段类型选择器同款），
//   金额 / 日期收进同一套行与输入框，减少视觉碎片。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../pages/tag/widgets/tag_selector.dart';
import '../currency/currency_picker_sheet.dart';
import '../ui/ui.dart';
import 'category_selector_dialog.dart';

/// 搜索页筛选条件的草稿值（各维度可空，null = 该维度不参与过滤）。
class SearchFilterValues {
  const SearchFilterValues({
    this.minAmount,
    this.maxAmount,
    this.startDate,
    this.endDate,
    this.category,
    this.account,
    this.tagIds = const <int>{},
    this.hasAttachment,
    this.currency,
  });

  final double? minAmount;
  final double? maxAmount;
  final DateTime? startDate;
  final DateTime? endDate;
  final Category? category;
  final Account? account;
  final Set<int> tagIds;

  /// null = 不限，true = 仅有附件，false = 仅无附件。
  final bool? hasAttachment;

  /// ISO 币种代码（大写）。
  final String? currency;
}

/// 弹出搜索筛选抽屉，返回用户确认的筛选条件（取消 / 下滑关闭返回 `null`）。
Future<SearchFilterValues?> showSearchFilterSheet(
  BuildContext context, {
  required SearchFilterValues initial,
}) {
  return showPiggyFormSheet<SearchFilterValues>(
    context,
    builder: (_) => _SearchFilterSheet(initial: initial),
  );
}

class _SearchFilterSheet extends ConsumerStatefulWidget {
  const _SearchFilterSheet({required this.initial});

  final SearchFilterValues initial;

  @override
  ConsumerState<_SearchFilterSheet> createState() => _SearchFilterSheetState();
}

class _SearchFilterSheetState extends ConsumerState<_SearchFilterSheet> {
  late final TextEditingController _minController;
  late final TextEditingController _maxController;

  late double? _minAmount;
  late double? _maxAmount;
  late DateTime? _startDate;
  late DateTime? _endDate;
  late Category? _category;
  late Account? _account;
  late Set<int> _tagIds;
  late bool? _hasAttachment;
  late String? _currency;

  @override
  void initState() {
    super.initState();
    _minAmount = widget.initial.minAmount;
    _maxAmount = widget.initial.maxAmount;
    _startDate = widget.initial.startDate;
    _endDate = widget.initial.endDate;
    _category = widget.initial.category;
    _account = widget.initial.account;
    _tagIds = {...widget.initial.tagIds};
    _hasAttachment = widget.initial.hasAttachment;
    _currency = widget.initial.currency;
    // 输入框自带 controller（不在 build 里重建）：否则每次 setState 都会丢
    // 光标位置，且旧 controller 泄漏。
    _minController = TextEditingController(text: _minAmount?.toString() ?? '');
    _maxController = TextEditingController(text: _maxAmount?.toString() ?? '');
  }

  @override
  void dispose() {
    _minController.dispose();
    _maxController.dispose();
    super.dispose();
  }

  /// 各维度就地清空（确认键才会写回页面）。
  void _clearAll() {
    setState(() {
      _minAmount = null;
      _maxAmount = null;
      _minController.clear();
      _maxController.clear();
      _startDate = null;
      _endDate = null;
      _category = null;
      _account = null;
      _tagIds = <int>{};
      _hasAttachment = null;
      _currency = null;
    });
  }

  SearchFilterValues _collect() => SearchFilterValues(
        minAmount: _minAmount,
        maxAmount: _maxAmount,
        startDate: _startDate,
        endDate: _endDate,
        category: _category,
        account: _account,
        tagIds: _tagIds,
        hasAttachment: _hasAttachment,
        currency: _currency,
      );

  Future<void> _pickCategory() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showCategorySelectorSheet(
      context,
      type: 'all',
      title: l10n.searchCategoryFilter,
      currentCategoryId: _category?.id,
      includeParentCategories: true,
      expandChildrenByDefault: true,
      heightFactor: 0.55,
    );
    if (picked == null || !mounted) return;
    setState(() => _category = picked);
  }

  Future<void> _pickAccount() async {
    final accounts = await ref.read(repositoryProvider).getAllAccounts();
    if (!mounted) return;
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.read(primaryColorProvider);
    final picked = await showPiggyPickerSheet<Account>(
      context,
      builder: (sheetCtx) => PiggyPickerSheet(
        title: l10n.searchAccountFilter,
        maxHeight: MediaQuery.sizeOf(sheetCtx).height * 0.7,
        // shrinkWrap：账户少时抽屉紧凑，超出 maxHeight 时内部滚动。
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p16),
          children: [
            for (final account in accounts)
              PiggyOptionRow(
                title: account.name,
                isSelected: account.id == _account?.id,
                primaryColor: primaryColor,
                onTap: () => Navigator.pop(sheetCtx, account),
              ),
          ],
        ),
      ),
    );
    if (picked == null || !mounted) return;
    setState(() => _account = picked);
  }

  Future<void> _pickTags() async {
    final picked = await TagSelector.show(
      context,
      selectedTagIds: _tagIds.toList(),
    );
    if (picked == null || !mounted) return;
    setState(() => _tagIds = picked.toSet());
  }

  Future<void> _pickCurrency() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: _currency ?? ref.read(baseCurrencyProvider),
      primaryColor: ref.read(primaryColorProvider),
      title: l10n.searchCurrencyFilter,
    );
    if (picked == null || !mounted) return;
    setState(() => _currency = picked.toUpperCase());
  }

  Future<void> _pickDate({required bool isStart}) async {
    final picked = await showWheelDatePicker(
      context,
      initial: (isStart ? _startDate : _endDate) ?? DateTime.now(),
      mode: WheelDatePickerMode.ymd,
      minDate: DateTime(2000),
      maxDate: DateTime.now(),
    );
    if (picked == null || !mounted) return;
    setState(() {
      if (isStart) {
        _startDate = picked;
      } else {
        _endDate = picked;
      }
    });
  }

  static String _formatDate(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);

    return PiggyFormSheet(
      title: l10n.searchFilterTitle,
      cancelLabel: l10n.commonCancel,
      confirmLabel: l10n.commonConfirm,
      onCancel: () => Navigator.of(context).pop(),
      onConfirm: () => Navigator.of(context).pop(_collect()),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 清空筛选：次要动作，靠右放在字段区顶部，不进底部按钮行。
          Align(
            alignment: Alignment.centerRight,
            child: TextButton(
              onPressed: _clearAll,
              style: TextButton.styleFrom(
                foregroundColor: PiggyTokens.textSecondary(context),
                minimumSize: Size.zero,
                padding: const EdgeInsets.symmetric(
                  horizontal: PiggyDimens.p8,
                  vertical: PiggyDimens.p8,
                ),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                textStyle: TextStyle(
                  fontSize: PiggyTextTokens.fs13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              child: Text(l10n.searchClearFilter),
            ),
          ),
          const SizedBox(height: PiggyDimens.p4),
          _FilterRow(
            icon: Icons.category_outlined,
            label: l10n.searchCategoryFilter,
            value: _category == null
                ? null
                : CategoryUtils.getDisplayName(_category!.name, context),
            onTap: _pickCategory,
            onClear: _category == null
                ? null
                : () => setState(() => _category = null),
          ),
          const SizedBox(height: PiggyDimens.p8),
          _FilterRow(
            icon: Icons.account_balance_wallet_outlined,
            label: l10n.searchAccountFilter,
            value: _account?.name,
            onTap: _pickAccount,
            onClear:
                _account == null ? null : () => setState(() => _account = null),
          ),
          const SizedBox(height: PiggyDimens.p8),
          _FilterRow(
            icon: Icons.sell_outlined,
            label: l10n.searchTagFilter,
            value: _tagIds.isEmpty
                ? null
                : l10n.searchTagFilterSelected(_tagIds.length),
            onTap: _pickTags,
            onClear: _tagIds.isEmpty
                ? null
                : () => setState(() => _tagIds = <int>{}),
          ),
          const SizedBox(height: PiggyDimens.p8),
          _FilterRow(
            icon: Icons.currency_exchange_outlined,
            label: l10n.searchCurrencyFilter,
            value: _currency,
            onTap: _pickCurrency,
            onClear: _currency == null
                ? null
                : () => setState(() => _currency = null),
          ),
          const SizedBox(height: PiggyDimens.p8),
          _FilterRow(
            icon: Icons.event_outlined,
            label: l10n.searchStartDate,
            value: _startDate == null ? null : _formatDate(_startDate!),
            onTap: () => _pickDate(isStart: true),
            onClear: _startDate == null
                ? null
                : () => setState(() => _startDate = null),
          ),
          const SizedBox(height: PiggyDimens.p8),
          _FilterRow(
            icon: Icons.event_outlined,
            label: l10n.searchEndDate,
            value: _endDate == null ? null : _formatDate(_endDate!),
            onTap: () => _pickDate(isStart: false),
            onClear:
                _endDate == null ? null : () => setState(() => _endDate = null),
          ),
          const SizedBox(height: PiggyDimens.p20),
          _SectionLabel(l10n.searchAmountFilter),
          const SizedBox(height: PiggyDimens.p8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _minController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: piggyOutlinedDecoration(
                    context,
                    label: l10n.searchMinAmount,
                  ),
                  onChanged: (value) => _minAmount = double.tryParse(value),
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: PiggyDimens.p8,
                ),
                child: Text(
                  '~',
                  style: PiggyTextTokens.body(context)
                      .copyWith(color: PiggyTokens.textTertiary(context)),
                ),
              ),
              Expanded(
                child: TextField(
                  controller: _maxController,
                  keyboardType:
                      const TextInputType.numberWithOptions(decimal: true),
                  decoration: piggyOutlinedDecoration(
                    context,
                    label: l10n.searchMaxAmount,
                  ),
                  onChanged: (value) => _maxAmount = double.tryParse(value),
                ),
              ),
            ],
          ),
          const SizedBox(height: PiggyDimens.p20),
          _SectionLabel(l10n.searchAttachmentFilter),
          const SizedBox(height: PiggyDimens.p8),
          _AttachmentSegmented(
            value: _hasAttachment,
            primaryColor: primaryColor,
            onChanged: (value) => setState(() => _hasAttachment = value),
          ),
        ],
      ),
    );
  }
}

/// 分组小标题（金额 / 附件这两块没有独立行标题，单独起一节）。
class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: PiggyTextTokens.label(context).copyWith(
        fontWeight: FontWeight.w600,
        color: PiggyTokens.textSecondary(context),
      ),
    );
  }
}

/// 单个筛选维度行：图标 + 名称 + 当前值（未设置时显示占位文案）+ 尾部箭头。
///
/// [onClear] 非空时尾部多一个 X —— 只清本维度的值，与整体「清空筛选」分开。
class _FilterRow extends StatelessWidget {
  const _FilterRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.value,
    this.onClear,
  });

  final IconData icon;
  final String label;

  /// 当前值；null = 未设置。
  final String? value;

  final VoidCallback onTap;

  /// 清空本维度；null = 无值可清（不显示清除键）。
  final VoidCallback? onClear;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = PiggyTokens.primary(context);
    final hasValue = value != null;

    return Material(
      color: PiggyTokens.surfaceSecondary(context),
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PiggyDimens.p12,
            vertical: 12,
          ),
          child: Row(
            children: [
              Icon(icon, size: 20, color: PiggyTokens.iconSecondary(context)),
              const SizedBox(width: PiggyDimens.p12),
              Flexible(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PiggyTextTokens.body(context)
                      .copyWith(color: PiggyTokens.textSecondary(context)),
                ),
              ),
              const SizedBox(width: PiggyDimens.p8),
              // Expanded 让值贴右：值本身不占满时右对齐，过长时省略号截断。
              Expanded(
                child: Text(
                  hasValue ? value! : l10n.searchNotSet,
                  textAlign: TextAlign.right,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: PiggyTextTokens.body(context).copyWith(
                    color: hasValue
                        ? primaryColor
                        : PiggyTokens.textTertiary(context),
                    fontWeight: hasValue ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
              // 清除键占固定 32 槽位：没有值也留空位，否则箭头（与值的右边界）
              // 会随「本维度是否可选清除」左右跳动，各行的 › 对不上一条竖线。
              SizedBox(
                width: 32,
                height: 32,
                child: onClear == null
                    ? null
                    : IconButton(
                        onPressed: onClear,
                        icon: const Icon(Icons.close, size: 18),
                        tooltip: l10n.tooltipClear,
                        color: PiggyTokens.iconTertiary(context),
                        visualDensity: VisualDensity.compact,
                        padding: EdgeInsets.zero,
                        constraints:
                            const BoxConstraints(minWidth: 32, minHeight: 32),
                      ),
              ),
              Icon(
                Icons.chevron_right,
                size: 20,
                color: PiggyTokens.iconTertiary(context),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// 附件筛选分段控件：不限 / 有附件 / 无附件，三个等宽按钮。
///
/// 不用三个并排 ChoiceChip：Chip 自带留白且各自成块，占两行宽度后视觉碎片化；
/// 分段控件与「自定义字段类型」选择器同一套语言（选中 = 主色描边 + 12% 底）。
class _AttachmentSegmented extends StatelessWidget {
  const _AttachmentSegmented({
    required this.value,
    required this.primaryColor,
    required this.onChanged,
  });

  /// null = 不限，true = 有附件，false = 无附件。
  final bool? value;
  final Color primaryColor;
  final ValueChanged<bool?> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final options = <({bool? value, String label})>[
      (value: null, label: l10n.searchAttachmentAny),
      (value: true, label: l10n.searchAttachmentHas),
      (value: false, label: l10n.searchAttachmentNone),
    ];

    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: PiggyDimens.p8),
          Expanded(
            child: _Segment(
              label: options[i].label,
              selected: value == options[i].value,
              primaryColor: primaryColor,
              onTap: () => onChanged(options[i].value),
            ),
          ),
        ],
      ],
    );
  }
}

class _Segment extends StatelessWidget {
  const _Segment({
    required this.label,
    required this.selected,
    required this.primaryColor,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? primaryColor.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          border: Border.all(
            color: selected ? primaryColor : PiggyTokens.border(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs13,
            fontWeight: FontWeight.w600,
            color: selected ? primaryColor : PiggyTokens.textSecondary(context),
          ),
        ),
      ),
    );
  }
}
