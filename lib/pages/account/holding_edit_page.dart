import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/account_type_utils.dart';
import '../../utils/currencies.dart';
import '../../utils/holding_code_inference.dart';
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
/// 「当前净值」写的是 `holdings.unit_price`（可同步的用户数据）；`quote_*` 行情
/// 缓存列在保存时经 `BaseRepository.writeQuoteCache`（本地专有、不记 change）
/// 回填一次，来源是 `QuoteService.previewPrice` 的即时取值 —— 用户手填值仍会被
/// 行情覆盖、也能在行情失效时回退。
///
/// 自动刷新开启时，输入代码会**防抖**向所选行情源即时拉一次价并只读展示
/// （见 [_fetchQuote]）；手动源 / 关闭开关时代码退化为纯手填。
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

  /// 即时行情预览（输入代码 → 防抖向所选源拉一次价）。
  Timer? _quoteDebounce;
  double? _liveQuotePrice;
  bool _quoteLoading = false;
  QuoteErrorKind? _quoteErrorKind;

  /// 拉取序号：用户快速改代码时丢弃过期响应（只认最后一次）。
  int _quoteFetchToken = 0;

  bool get _isEdit => widget.holding != null;

  /// 已有行情缓存是否可用（编辑态 + 表单开了自动刷新 + TTL 内）。
  ///
  /// 刻意只看**表单的开关**（用户此刻的意图），而不是存储的 `autoQuote`：
  /// 用户在抽屉里关掉开关时，「当前净值」要立刻变回可编辑的手填值。
  bool get _cachedQuoteUsable {
    final h = widget.holding;
    if (h == null || !_autoQuote) return false;
    return isQuoteUsable(
      quotePrice: h.quotePrice,
      quoteFetchedAt: h.quoteFetchedAt,
      now: DateTime.now(),
    );
  }

  /// 「当前净值」是否由行情决定（刚拉到的即时价优先于已有缓存）。
  bool get _quoteManaged => _sourcePrice != null;

  /// 行情决定时展示的净值：即时价 > 已有缓存 > null（退化为手填）。
  double? get _sourcePrice {
    if (_liveQuotePrice != null) return _liveQuotePrice;
    if (_cachedQuoteUsable) return widget.holding!.quotePrice;
    return null;
  }

  /// 预览净值：行情接管时用行情价（与列表 / 账户口径一致），否则用输入框手填值。
  double get _previewUnitPrice => _sourcePrice ?? _parse(_unitPrice);

  /// 账户币种：新建时的默认持仓币种，也是币种选择器的汇率基准。
  String get _accountCurrency =>
      ref.read(accountByIdProvider(widget.accountId)).value?.currency ?? 'CNY';

  /// 新建持仓时「允许自动刷新行情」的默认值。
  ///
  /// 跟随「行情与投资」里的**全局自动刷新开关**：开关开着、且当前行情源具备
  /// 自动能力（如东方财富）时默认勾选，省得每新建一笔都要手动打开；手动源 /
  /// 开关关闭时保持不勾选（零网络语义）。编辑态一律沿用该持仓自身的值。
  bool get _defaultAutoQuote {
    if (!ref.read(quoteAutoRefreshSettingsProvider).enabled) return false;
    return ref.read(quoteProviderProvider).capability.isAutomatic;
  }

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
    _autoQuote = h?.autoQuote ?? _defaultAutoQuote;
    for (final c in [_quantity, _unitCost, _unitPrice]) {
      c.addListener(_onInputChanged);
    }
    // 敲代码 → 自动带出市场 / 资产类别 / 币种（用户随时可手动覆盖）。
    _symbol.addListener(_onSymbolChanged);
  }

  /// 代码变化时按前缀推断市场 / 资产类别 / 币种。
  ///
  /// - 币种**只在「市场发生切换」时跟随**：否则用户改一个错别字就会把刻意选的
  ///   计价币种冲掉，跨币种折算口径随之突变（缺汇率的持仓会被整条剔除）。
  /// - 推断不出（空 / 位数不合法）时**什么都不动**，避免把用户的选择清空。
  void _onSymbolChanged() {
    final guess = guessHoldingFromCode(_symbol.text);
    if (!guess.isEmpty) {
      setState(() {
        final marketChanged = guess.market != null && guess.market != _market;
        if (guess.market != null) _market = guess.market;
        if (guess.assetClass != null) _assetClass = guess.assetClass!;
        if (marketChanged && guess.currency != null) _currency = guess.currency!;
      });
    }
    // 代码变了 → 旧的即时价作废，重新防抖拉取。
    _scheduleQuoteFetch();
  }

  /// 防抖后向所选行情源即时拉一次价。
  ///
  /// 只在这些前提都满足时才发请求：**自动刷新开** + 代码与市场齐备 + 当前源
  /// 具备自动能力且支持该市场（手动源 / 关开关 → 纯手填，零请求）。
  void _scheduleQuoteFetch() {
    _quoteDebounce?.cancel();
    // 代码 / 市场 / 币种任一变化，先清掉上一轮的展示态。
    if (_liveQuotePrice != null || _quoteErrorKind != null || _quoteLoading) {
      setState(() {
        _liveQuotePrice = null;
        _quoteErrorKind = null;
        _quoteLoading = false;
      });
    }
    if (!_canFetchQuote) return;
    // 防抖 600ms：避免输每一位都打一次网络。
    _quoteDebounce = Timer(const Duration(milliseconds: 600), _fetchQuote);
  }

  /// 当前是否具备即时拉价条件（不发请求的纯判定）。
  bool get _canFetchQuote {
    if (!_autoQuote) return false;
    if (_symbol.text.trim().isEmpty) return false;
    final market = _market;
    if (market == null) return false;
    final capability = ref.read(quoteProviderProvider).capability;
    return capability.isAutomatic && capability.supports(market);
  }

  Future<void> _fetchQuote() async {
    if (!_canFetchQuote) return;
    final token = ++_quoteFetchToken;
    final symbol = _symbol.text.trim();
    final market = _market!;
    final currency = _currency;
    setState(() {
      _quoteLoading = true;
      _quoteErrorKind = null;
    });
    try {
      final preview = await ref.read(quoteServiceProvider).previewQuote(
            symbol: symbol,
            market: market,
            holdingCurrency: currency,
          );
      if (!mounted || token != _quoteFetchToken) return;
      setState(() {
        _liveQuotePrice = preview?.price;
        _quoteLoading = false;
        // 名称兜底：仅在用户**尚未填名**时用行情返回的名称默认带出，
        // 绝不覆盖用户已输入的内容。
        final name = preview?.name;
        if (name != null && _name.text.trim().isEmpty) {
          _name.text = name;
        }
      });
    } on QuoteException catch (e) {
      if (!mounted || token != _quoteFetchToken) return;
      setState(() {
        _liveQuotePrice = null;
        _quoteLoading = false;
        _quoteErrorKind = e.kind;
      });
    } catch (_) {
      if (!mounted || token != _quoteFetchToken) return;
      setState(() {
        _liveQuotePrice = null;
        _quoteLoading = false;
        _quoteErrorKind = QuoteErrorKind.unknown;
      });
    }
  }

  @override
  void dispose() {
    _quoteDebounce?.cancel();
    for (final c in [_name, _symbol, _quantity, _unitCost, _unitPrice, _note]) {
      c.dispose();
    }
    super.dispose();
  }

  void _onInputChanged() => setState(() {});

  /// 市场 / 币种 / 自动刷新开关变化都可能改变「该拉哪个价」，统一重排一次。
  void _onMarketChanged(String v) {
    setState(() => _market = _market == v ? null : v);
    _scheduleQuoteFetch();
  }

  void _onAutoQuoteChanged(bool v) {
    setState(() => _autoQuote = v);
    _scheduleQuoteFetch();
  }

  /// 「当前净值」区域。
  ///
  /// - 有行情价（即时拉取 / 已有缓存）→ **只读**展示，与列表 / 账户口径一致；
  /// - 正在拉取 → 先占位显示「获取中」；
  /// - 否则 → 可编辑手填框；自动刷新开启时在下方补一条状态说明
  ///   （获取失败 / 未命中）。
  Widget _buildUnitPriceField(AppLocalizations l10n, String currencySymbol) {
    final price = _sourcePrice;
    if (price != null) {
      return _QuotePriceField(
        label: l10n.holdingFieldUnitPrice,
        value: '$currencySymbol ${_formatNumber(price)}',
        hint: l10n.holdingFieldUnitPriceQuoteManaged,
        busy: _quoteLoading,
      );
    }
    if (_quoteLoading) {
      return _QuotePriceField(
        label: l10n.holdingFieldUnitPrice,
        value: '—',
        hint: l10n.holdingQuoteFetching,
        busy: true,
      );
    }
    final hint = _quoteHint(l10n);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _NumberField(
          controller: _unitPrice,
          label: l10n.holdingFieldUnitPrice,
          prefix: '$currencySymbol ',
        ),
        if (hint != null)
          Padding(
            padding: const EdgeInsets.only(
              top: PiggyDimens.p4,
              left: PiggyDimens.p4,
            ),
            child: Text(
              hint,
              style: PiggyTextTokens.caption(context).copyWith(
                color: _quoteErrorKind != null
                    ? PiggyTokens.error(context)
                    : PiggyTokens.textTertiary(context),
              ),
            ),
          ),
      ],
    );
  }

  /// 手填态、自动刷新开启时的补充说明（无则返回 null）。
  String? _quoteHint(AppLocalizations l10n) {
    if (!_autoQuote) return null;
    if (_quoteErrorKind != null) return l10n.holdingQuoteFetchFailed;
    if (_symbol.text.trim().isEmpty || _market == null) return null;
    return l10n.holdingQuoteFetchEmpty;
  }

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
            onSelect: _onMarketChanged,
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
          _buildUnitPriceField(l10n, currencySymbol),
          const SizedBox(height: PiggyDimens.p16),
          _PreviewCard(
            quantity: _parse(_quantity),
            unitCost: _parse(_unitCost),
            unitPrice: _previewUnitPrice,
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
              onChanged: _onAutoQuoteChanged,
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
    // 币种变了 → 跨币种折算口径变，重排一次即时拉价。
    _scheduleQuoteFetch();
  }

  /// 把即时拉到的行情价落进本地缓存（本地专有列、不记 change），
  /// 让保存后列表 / 账户**立刻**用上这个价 —— 否则要等下一轮后台刷新。
  Future<void> _cachePreviewQuote(int holdingId) async {
    final price = _liveQuotePrice;
    if (price == null || price <= 0) return;
    try {
      await ref.read(repositoryProvider).writeQuoteCache(
            holdingId,
            price: price,
            fetchedAt: DateTime.now(),
            sourceId: ref.read(quoteProviderProvider).providerId,
          );
    } catch (_) {
      // 缓存回填失败不影响保存主流程；下一轮后台刷新会补上。
    }
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
      final int holdingId;
      if (_isEdit) {
        holdingId = widget.holding!.id;
        await repo.updateHolding(
          holdingId,
          name: name,
          symbol: symbol.isEmpty ? null : symbol,
          market: _market,
          assetClass: _assetClass,
          currency: _currency,
          quantity: _parse(_quantity),
          unitCost: _parse(_unitCost),
          // 行情接管时输入框是只读的行情价展示，不能把它当作手填值写回
          // （null = 不改动该字段），否则会把用户的手填回退值悄悄覆盖成行情价。
          unitPrice: _quoteManaged ? null : _parse(_unitPrice),
          autoQuote: _autoQuote,
          note: note.isEmpty ? null : note,
          clearOptionalFields: symbol.isEmpty && _market == null && note.isEmpty,
        );
      } else {
        holdingId = await repo.createHolding(
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
      // 即时拉到的行情价随手落缓存，保存完立刻在列表 / 账户生效。
      await _cachePreviewQuote(holdingId);
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

/// 只读的行情价展示（编辑态 + 允许自动刷新 + 有可用行情时**取代**手填输入框）。
///
/// 用 [InputDecorator] 复用 [piggyOutlinedDecoration] 的浮动标签外形，与相邻的
/// 输入框像素级对齐；尾部一个同步图标点出「此价由行情自动更新」。下方补一句
/// 说明，解释手填值的定位 —— 这正是「编辑页与列表/账户数字对不上」的答案。
class _QuotePriceField extends StatelessWidget {
  const _QuotePriceField({
    required this.label,
    required this.value,
    required this.hint,
    this.busy = false,
  });

  final String label;
  final String value;
  final String hint;

  /// 正在拉取新价：尾部图标换成小转圈（值仍是上一轮 / 占位）。
  final bool busy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InputDecorator(
          decoration: piggyOutlinedDecoration(context, label: label),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  value,
                  style: const TextStyle(fontSize: PiggyTextTokens.fs16),
                ),
              ),
              if (busy)
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: PiggyTokens.primary(context),
                  ),
                )
              else
                Icon(
                  Icons.sync_rounded,
                  size: 18,
                  color: PiggyTokens.primary(context),
                ),
            ],
          ),
        ),
        const SizedBox(height: PiggyDimens.p4),
        Padding(
          padding: const EdgeInsets.only(left: PiggyDimens.p4),
          child: Text(hint, style: PiggyTextTokens.caption(context)),
        ),
      ],
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
