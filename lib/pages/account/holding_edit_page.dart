import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/account_type_utils.dart';
import '../../utils/currencies.dart';
import '../../utils/holding_metrics.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/currency/currency_flag.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
import '../../widgets/ui/ui.dart';

/// 以底部抽屉形式弹出持仓编辑器（新建 / 编辑通用）。
///
/// 唯一入口：与预算 / 账户 / 周期账单 / 自定义字段同款 —— 项目约定「表单抽屉
/// 一律用悬浮卡片外壳」（[PiggyFormSheet]：居中标题 + 卡片内滚动表单 + 底部
/// 「取消｜保存」双等宽按钮），不要另起一个全屏 Scaffold 表单页。
Future<bool?> showHoldingFormBottomSheet(
  BuildContext context, {
  required int accountId,
  Holding? holding,
}) {
  return showPiggyFormSheet<bool>(
    context,
    builder: (_) => HoldingEditPage(accountId: accountId, holding: holding),
  );
}

/// 持仓编辑表单（悬浮卡片抽屉内容）。[holding] 为 null 即新建。
///
/// 字段观感对齐 `budget_edit_page` / `custom_field_manage_page` 的既有约定：
/// 输入框用 [piggyOutlinedDecoration] 的**浮动标签** + `fs16`；多选项用项目自绘的
/// 「等宽选项按钮」（主色填充 + 1.5px 描边）；币种走 [showCurrencyPickerSheet]。
///
/// 写路径纪律：一律经 `BaseRepository` 的 `createHolding` / `updateHolding` /
/// `deleteHolding`（内部记 user-global change），**不要**直接碰 Drift。
///
/// 「当前净值」写的是 `holdings.unit_price`（可同步的用户数据）；
/// `quote_price` 等本地专有行情缓存列由行情编排层（`QuoteService`）独占，
/// 本页**永不写入** —— 用户手填值必须能被行情覆盖、也能在行情失效时回退。
class HoldingEditPage extends ConsumerStatefulWidget {
  const HoldingEditPage({
    super.key,
    required this.accountId,
    this.holding,
  });

  final int accountId;
  final Holding? holding;

  @override
  ConsumerState<HoldingEditPage> createState() => _HoldingEditPageState();
}

class _HoldingEditPageState extends ConsumerState<HoldingEditPage> {
  late final TextEditingController _name;
  late final TextEditingController _symbol;
  late final TextEditingController _quantity;
  late final TextEditingController _unitCost;
  late final TextEditingController _unitPrice;
  late final TextEditingController _note;

  late String _assetClass;
  late String? _market;
  late String _currency;
  late bool _autoQuote;

  bool _saving = false;

  bool get _isEdit => widget.holding != null;

  /// 账户币种：新建时的默认持仓币种，也是币种选择器的汇率基准。
  String get _accountCurrency =>
      ref.read(accountByIdProvider(widget.accountId)).value?.currency ?? 'CNY';

  @override
  void initState() {
    super.initState();
    final h = widget.holding;
    _name = TextEditingController(text: h?.name ?? '');
    _symbol = TextEditingController(text: h?.symbol ?? '');
    _quantity = TextEditingController(text: _formatNumber(h?.quantity));
    _unitCost = TextEditingController(text: _formatNumber(h?.unitCost));
    _unitPrice = TextEditingController(text: _formatNumber(h?.unitPrice));
    _note = TextEditingController(text: h?.note ?? '');
    _assetClass = h?.assetClass ?? 'stock';
    _market = h?.market;
    // 新建时默认跟随账户币种（最常见的场景），可改
    _currency = h?.currency ?? _accountCurrency;
    _autoQuote = h?.autoQuote ?? false;
    for (final c in [_quantity, _unitCost, _unitPrice]) {
      c.addListener(_onInputChanged);
    }
  }

  @override
  void dispose() {
    for (final c in [_name, _symbol, _quantity, _unitCost, _unitPrice, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  /// 数字输入框回填：整数不带小数点（100.0 → 100），避免用户每次都要删尾零
  static String _formatNumber(double? v) {
    if (v == null || v == 0) return '';
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  static double _parse(TextEditingController c) =>
      double.tryParse(c.text.trim()) ?? 0;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currencySymbol = getCurrencySymbol(_currency);

    return PiggyFormSheet(
      title: _isEdit ? l10n.holdingEditTitle : l10n.holdingAddTitle,
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
              label: l10n.holdingFieldName,
              hint: l10n.holdingFieldNameHint,
            ),
          ),
          const SizedBox(height: PiggyDimens.p12),
          TextField(
            controller: _symbol,
            textInputAction: TextInputAction.next,
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.holdingFieldSymbol,
              hint: l10n.holdingFieldSymbolHint,
            ),
          ),
          const SizedBox(height: PiggyDimens.p16),
          _label(l10n.holdingFieldAssetClass),
          const SizedBox(height: PiggyDimens.p8),
          _ChoiceGrid(
            values: holdingAssetClassOrder,
            selected: _assetClass,
            labelOf: (v) => getHoldingAssetClassLabel(v, l10n),
            iconOf: getHoldingAssetClassIcon,
            onSelect: (v) => setState(() => _assetClass = v),
          ),
          const SizedBox(height: PiggyDimens.p16),
          _label(l10n.holdingFieldMarket),
          const SizedBox(height: PiggyDimens.p8),
          _ChoiceGrid(
            values: holdingMarketOrder,
            selected: _market,
            labelOf: (v) => getHoldingMarketLabel(v, l10n),
            // 市场是行情源匹配用的标识，手填版可以留空 —— 再点一次取消选择
            onSelect: (v) => setState(() => _market = _market == v ? null : v),
          ),
          const SizedBox(height: PiggyDimens.p16),
          InkWell(
            onTap: _saving ? null : _selectCurrency,
            child: InputDecorator(
              decoration: piggyOutlinedDecoration(
                context,
                label: l10n.holdingFieldCurrency,
              ),
              child: Row(
                children: [
                  currencyFlag(context, _currency,
                      width: 22, height: 16, radius: 4),
                  const SizedBox(width: PiggyDimens.p8),
                  Expanded(
                    child: Text(
                      displayCurrency(_currency, context),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                    ),
                  ),
                  const Icon(Icons.arrow_drop_down, size: 24),
                ],
              ),
            ),
          ),
          const SizedBox(height: PiggyDimens.p16),
          _NumberField(
            controller: _quantity,
            label: l10n.holdingFieldQuantity,
          ),
          const SizedBox(height: PiggyDimens.p12),
          _NumberField(
            controller: _unitCost,
            label: l10n.holdingFieldUnitCost,
            prefix: '$currencySymbol ',
          ),
          const SizedBox(height: PiggyDimens.p12),
          _NumberField(
            controller: _unitPrice,
            label: l10n.holdingFieldUnitPrice,
            prefix: '$currencySymbol ',
          ),
          const SizedBox(height: PiggyDimens.p16),
          _PreviewCard(
            quantity: _parse(_quantity),
            unitCost: _parse(_unitCost),
            unitPrice: _parse(_unitPrice),
            currency: _currency,
          ),
          const SizedBox(height: PiggyDimens.p12),
          Padding(
            padding: const EdgeInsets.only(left: PiggyDimens.p4),
            child: PiggySwitchListTile(
              leading: const Icon(Icons.sync_rounded),
              title: Text(
                l10n.holdingFieldAutoQuote,
                style: const TextStyle(fontSize: PiggyTextTokens.fs16),
              ),
              subtitle: Text(l10n.holdingFieldAutoQuoteSubtitle),
              dense: true,
              value: _autoQuote,
              onChanged: (v) => setState(() => _autoQuote = v),
            ),
          ),
          const SizedBox(height: PiggyDimens.p12),
          TextField(
            controller: _note,
            maxLines: 2,
            style: const TextStyle(fontSize: PiggyTextTokens.fs16),
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.holdingFieldNote,
            ),
          ),
          // 删除渲染在表单末尾、「取消｜保存」之上（与预算 / 周期账单同款）
          if (_isEdit) ...[
            const SizedBox(height: PiggyDimens.p24),
            SizedBox(
              width: double.infinity,
              height: PiggySheetActions.kHeight,
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _confirmDelete,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(l10n.commonDelete),
                style: OutlinedButton.styleFrom(
                  foregroundColor: PiggyTokens.error(context),
                  // 边框与前景同源（裸 Colors.red 不跟暗黑 / 主题错误色）
                  side: BorderSide(color: PiggyTokens.error(context), width: 1.5),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// 分组小标题（与自定义字段管理页的 `_label` 同款）
  Widget _label(String text) => Text(
        text,
        style: PiggyTextTokens.label(context).copyWith(
          fontWeight: FontWeight.w500,
        ),
      );

  Future<void> _selectCurrency() async {
    final l10n = AppLocalizations.of(context);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: _currency,
      primaryColor: ref.read(primaryColorProvider),
      title: l10n.holdingFieldCurrency,
      // 以账户币种为汇率基准：持仓折算的中间跳就是它，展示对它的汇率最直观
      rateBase: _accountCurrency,
    );
    if (picked == null || !mounted) return;
    setState(() => _currency = picked.toUpperCase());
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context);
    final name = _name.text.trim();
    if (name.isEmpty) {
      showToast(context, l10n.holdingValidationNameRequired);
      return;
    }
    // 校验：允许 0（尚未建仓 / 已清仓），但**非空且解析失败**必须拦下 ——
    // 静默把它当 0 会让一笔净值悄悄消失。
    for (final entry in {
      l10n.holdingValidationQuantityInvalid: _quantity,
      l10n.holdingValidationPriceInvalid: _unitPrice,
      l10n.holdingValidationCostInvalid: _unitCost,
    }.entries) {
      final raw = entry.value.text.trim();
      if (raw.isNotEmpty && double.tryParse(raw) == null) {
        showToast(context, entry.key);
        return;
      }
    }

    setState(() => _saving = true);
    try {
      final repo = ref.read(repositoryProvider);
      final symbol = _symbol.text.trim();
      final note = _note.text.trim();
      if (_isEdit) {
        await repo.updateHolding(
          widget.holding!.id,
          name: name,
          symbol: symbol.isEmpty ? null : symbol,
          market: _market,
          assetClass: _assetClass,
          currency: _currency,
          quantity: _parse(_quantity),
          unitCost: _parse(_unitCost),
          unitPrice: _parse(_unitPrice),
          autoQuote: _autoQuote,
          note: note.isEmpty ? null : note,
          clearOptionalFields: symbol.isEmpty && _market == null && note.isEmpty,
        );
      } else {
        await repo.createHolding(
          accountId: widget.accountId,
          name: name,
          currency: _currency,
          symbol: symbol.isEmpty ? null : symbol,
          market: _market,
          assetClass: _assetClass,
          quantity: _parse(_quantity),
          unitCost: _parse(_unitCost),
          unitPrice: _parse(_unitPrice),
          autoQuote: _autoQuote,
          note: note.isEmpty ? null : note,
        );
      }
      if (!mounted) return;
      showToast(context, l10n.holdingSaveSuccess);
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context);
    // 不可恢复的实体删除 → 单次危险确认（3 秒时停），口径见 AGENTS.md
    // 「破坏性操作确认分档」。
    final confirmed = await showDangerConfirmDialog(
      context,
      title: l10n.holdingDeleteConfirmTitle,
      message: l10n.holdingDeleteConfirmBody(widget.holding!.name),
      okLabel: l10n.commonDelete,
      countdownSeconds: 3,
    );
    if (!confirmed || !mounted) return;

    setState(() => _saving = true);
    try {
      await ref.read(repositoryProvider).deleteHolding(widget.holding!.id);
      if (!mounted) return;
      showToast(context, l10n.holdingDeleteSuccess);
      Navigator.of(context).pop(true);
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}

/// 多选项选择器：项目自绘的「等宽选项按钮」三列网格。
///
/// 规格取自 `custom_field_manage_page._buildTypeSelector`（项目里唯一的表单内
/// 多选控件先例）：选中主色 `alpha 0.12` 填充 + 1.5px 主色描边，未选中
/// `PiggyTokens.border` 1px 描边，`radiusSm`，图标 18 + fs12 w600 文案。
/// 用 [LayoutBuilder] 按可用宽度铺三列，5~6 个选项刚好两行。
class _ChoiceGrid extends StatelessWidget {
  const _ChoiceGrid({
    required this.values,
    required this.selected,
    required this.labelOf,
    required this.onSelect,
    this.iconOf,
  });

  final List<String> values;
  final String? selected;
  final String Function(String) labelOf;
  final ValueChanged<String> onSelect;
  final IconData Function(String)? iconOf;

  @override
  Widget build(BuildContext context) {
    final primary = PiggyTokens.primary(context);
    const gap = PiggyDimens.p8;

    return LayoutBuilder(
      builder: (context, constraints) {
        final itemWidth = (constraints.maxWidth - gap * 2) / 3;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final v in values)
              SizedBox(
                width: itemWidth,
                child: GestureDetector(
                  onTap: () => onSelect(v),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                        vertical: PiggyDimens.p12),
                    decoration: BoxDecoration(
                      color: v == selected
                          ? primary.withValues(alpha: 0.12)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                      border: Border.all(
                        color: v == selected
                            ? primary
                            : PiggyTokens.border(context),
                        width: v == selected ? 1.5 : 1,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (iconOf != null)
                          Icon(
                            iconOf!(v),
                            size: 18,
                            color: v == selected
                                ? primary
                                : PiggyTokens.textTertiary(context),
                          ),
                        if (iconOf != null) const SizedBox(height: PiggyDimens.p4),
                        Text(
                          labelOf(v),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: PiggyTextTokens.fs12,
                            fontWeight: FontWeight.w600,
                            color: v == selected
                                ? primary
                                : PiggyTokens.textSecondary(context),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// 数字输入（只放行数字与一个小数点，最多 4 位小数 —— 份额与净值都可能需要
/// 比金额更高的精度，但多余的字符只会让 `double.tryParse` 失败）
class _NumberField extends StatelessWidget {
  const _NumberField({
    required this.controller,
    required this.label,
    this.prefix,
  });

  final TextEditingController controller;
  final String label;
  final String? prefix;

  @override
  Widget build(BuildContext context) {
    return TextField(
      controller: controller,
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'^\d*\.?\d{0,4}')),
      ],
      style: const TextStyle(fontSize: PiggyTextTokens.fs16),
      decoration: piggyOutlinedDecoration(
        context,
        label: label,
        prefix: prefix,
      ),
    );
  }
}

/// 实时预览：市值 / 盈亏 / 收益率（**持仓币种**口径，不做折算）
class _PreviewCard extends ConsumerWidget {
  const _PreviewCard({
    required this.quantity,
    required this.unitCost,
    required this.unitPrice,
    required this.currency,
  });

  final double quantity;
  final double unitCost;
  final double unitPrice;
  final String currency;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final marketValue = holdingMarketValue(
      quantity: quantity,
      unitPrice: unitPrice,
    );
    final cost = holdingCost(quantity: quantity, unitCost: unitCost);
    final profit = marketValue - cost;
    final rate = profitRate(marketValue: marketValue, cost: cost);
    final color = profit < 0
        ? PiggyTokens.expenseColor(context, ref)
        : PiggyTokens.incomeColor(context, ref);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.holdingPreviewMarketValue,
                  style: PiggyTextTokens.label(context)),
              const SizedBox(height: PiggyDimens.p4),
              AmountText(
                value: marketValue,
                signed: false,
                showCurrency: true,
                currencyCode: currency,
                useCompactFormat: ref.watch(compactAmountProvider),
                style: PiggyTextTokens.body(context)
                    .copyWith(fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.holdingPreviewProfit,
                  style: PiggyTextTokens.label(context)),
              const SizedBox(height: PiggyDimens.p4),
              AmountText(
                value: profit,
                signed: true,
                showCurrency: true,
                currencyCode: currency,
                useCompactFormat: ref.watch(compactAmountProvider),
                style: PiggyTextTokens.body(context)
                    .copyWith(color: color, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: PiggyDimens.p4),
              Text(
                rate == null ? '—' : '${(rate * 100).toStringAsFixed(2)}%',
                style: PiggyTextTokens.caption(context).copyWith(color: color),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
