import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:decimal/decimal.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:piggycount/widgets/ui/wheel_date_picker.dart';
import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../services/data/note_history_service.dart';
import '../../models/note_history.dart';
import '../../services/attachment_service.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../pages/tag/widgets/tag_selector.dart';
import 'custom_field_input.dart';
import 'note_picker_dialog.dart';
import 'attachment_source_sheet.dart';
import 'account_selector.dart';
import '../currency/currency_picker_sheet.dart';
import '../currency/currency_flag.dart';
import '../ui/toast.dart';
import '../ui/dialog.dart';
import '../ui/piggy_input.dart';
import '../ui/piggy_switcher.dart';
import 'tag_chip.dart';
import '../category_icon.dart';
import '../../pages/attachment/attachment_preview_page.dart';

/// 共享账本 tx 作者信息(创建人 + 最后编辑人)— 编辑器底部 sheet 用。
/// editingTransactionId=null(新建 tx)或非共享账本 → 返 null,widget 不渲染。
typedef AmountEditorResult = ({
  double amount,
  String? note,
  DateTime date,
  int? accountId,
  List<int> tagIds,
  List<File> pendingAttachments,
  bool excludeFromStats,
  bool excludeFromBudget,
  // v30 交易级多币种:交易币种(有账户=账户币种;无账户=手选,默认本位币)
  // 与折本位币快照(同币种 == amount;外币 = amount × 汇率,缺汇率已在提交前阻断)。
  String? currencyCode,
  double? nativeAmount,
  // v45 原始金额(选填):null = 用户未填写 → 语义为「默认金额 = 记账金额」。
  // 不在此处做 ?? amount 兜底,保留「是否手填」这一事实供差异统计使用。
  double? originalAmount,
  // v46 自定义字段值 { fieldSyncId: value }。
  // null = **不改动**（本次编辑未涉及自定义字段，或该笔本来就没值）；空 map
  // = 显式清空。与 v45 originalAmount 的"三态"同思路，避免顺手清空已有值。
  Map<String, dynamic>? customValues,
});

class AmountEditorSheet extends ConsumerStatefulWidget {
  final String categoryName; // 仅用于上层提交，不在UI展示
  final int? categoryId; // 当前本地分类ID，用于筛选历史备注
  final String? categorySyncId; // 共享账本分类同步ID，用于筛选历史备注
  /// 分类位（P1-E，design.md 决策 4）：金额表达式行最左侧展示的分类。
  ///
  /// 为 null 时不渲染该位 —— 转账金额表单、以及未传分类的调用方，布局与
  /// 改动前逐字一致。**刻意不做「只有快捷模式才显示分类」的分叉**：同一个
  /// 表单不该有两套信息层级（编辑交易、小组件带分类的既有调用方一并传它）。
  final Category? displayCategory;

  /// 点分类位的回调，入参为**当前已输金额**。null = 只读不可换
  /// （下层没有分类网格可退时，如全屏编辑场景）。
  ///
  /// 动作由调用方决定：快捷记账的调用方拿到金额后 pop 掉本表单回到分类网格，
  /// 用户点新分类时再以该金额作 initialAmount 重弹 —— 即决策 5 的换分类回路，
  /// 「换分类保留已输金额」由此免费获得，无需把金额提升成额外状态源。
  final ValueChanged<double>? onPickCategory;
  final DateTime initialDate;
  final double? initialAmount;
  final String? initialNote;
  final int? initialAccountId;
  final List<int>? initialTagIds; // 初始标签ID列表
  final bool showAccountPicker; // 是否显示账户选择
  final ValueChanged<AmountEditorResult> onSubmit;
  final int ledgerId;
  final int? editingTransactionId; // 编辑模式时的交易ID，用于显示已有附件
  final String transactionKind; // 'expense' / 'income' / 'transfer'，决定标记开关可见性
  final bool initialExcludeFromStats; // 不计入收支，编辑模式回显
  final bool initialExcludeFromBudget; // 不计入预算，编辑模式回显
  // v30 编辑模式回显:该笔的原币种与折算快照(用于推隐含汇率,只改备注时
  // 折算基准不漂移,.docs/multi-currency-ledger 01 §4.2)。
  final String? initialCurrencyCode;
  final double? initialNativeAmount;
  // v45 原始金额回显(编辑既有明细时回填);null = 该笔未填写。
  final double? initialOriginalAmount;
  // v46 自定义字段已存值回显(fieldSyncId → value)。编辑既有明细时由
  // transaction_edit_utils 读取;新建为空。
  final Map<String, dynamic> initialCustomValues;

  const AmountEditorSheet({
    super.key,
    required this.categoryName,
    this.categoryId,
    this.categorySyncId,
    this.displayCategory,
    this.onPickCategory,
    required this.initialDate,
    this.initialAmount,
    this.initialNote,
    this.initialAccountId,
    this.initialTagIds,
    this.showAccountPicker = false,
    required this.onSubmit,
    required this.ledgerId,
    this.editingTransactionId,
    this.transactionKind = 'expense',
    this.initialExcludeFromStats = false,
    this.initialExcludeFromBudget = false,
    this.initialCurrencyCode,
    this.initialNativeAmount,
    this.initialOriginalAmount,
    this.initialCustomValues = const {},
  });

  @override
  ConsumerState<AmountEditorSheet> createState() => _AmountEditorSheetState();
}

/// v45：自定义数字键盘的输入目标 —— 点哪个金额位，键盘就输哪个。
/// v47 增加 [customField]：自定义字段里的金额位也由这套键盘输入（具体是哪个
/// 字段另由 `_customFieldSyncId` 指定）。
enum _AmountEditTarget { amount, original, customField }

class _AmountEditorSheetState extends ConsumerState<AmountEditorSheet> {
  late String _amountStr;
  late DateTime _date;
  int? _selectedAccountId;
  final TextEditingController _noteCtrl = TextEditingController();
  // v45 原始金额(选填)的输入串。空串 = 未填写(提交 null)。
  // 刻意不用 TextField —— 它由下方**自定义数字键盘**输入，谁被选中就输谁，
  // 避免点击时弹出系统键盘、两套键盘打架。
  String _originalStr = '';
  // 小键盘当前输入目标(记账金额 / 原始金额 / 自定义字段金额位)。
  _AmountEditTarget _editTarget = _AmountEditTarget.amount;
  // v47 自定义字段(仅金额类型)的键盘输入串:fieldSyncId → 串。
  // 空串 = 未填写(与原始金额同口径,提交时被规范化剔除)。
  final Map<String, String> _customFieldStrs = {};
  // 当前键盘目标的自定义字段 syncId(null = 焦点不在自定义字段上)。
  String? _customFieldSyncId;
  // 运算缓存：支持简单 + / - 键入累计。
  // 按**输入目标隔离** —— 否则在原始金额位按 + 会把记账金额的累加器冲掉。
  // 自定义字段的算式额外在**切换字段时清空**(见 `_focusCustomField`)：同一个
  // customField 目标上的半截算式不能跨字段复用。
  final Map<_AmountEditTarget, double> _accByTarget = {};
  final Map<_AmountEditTarget, String?> _opByTarget = {};

  /// 当前输入目标的运算状态（小键盘把输入送到哪，运算就算在哪）。
  double get _acc => _accByTarget[_editTarget] ?? 0;
  set _acc(double v) => _accByTarget[_editTarget] = v;
  String? get _op => _opByTarget[_editTarget];
  set _op(String? v) => _opByTarget[_editTarget] = v;

  /// 记账金额位的运算状态 —— 提交求值与算式展示都钉在记账金额上，
  /// 与当前焦点无关。
  double get _amountAcc => _accByTarget[_AmountEditTarget.amount] ?? 0;
  String? get _amountOp => _opByTarget[_AmountEditTarget.amount];

  /// 当前输入目标的数值。
  double _parsedActive() => double.tryParse(_activeStr) ?? 0.0;

  /// 金额串去尾零（'12.00' → '12'）。
  static String _trimZeros(double v) {
    final s = v.abs().toStringAsFixed(2);
    final r = s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
    return r.isEmpty ? '0' : r;
  }

  /// 原始金额位的显示串：运算模式下带算式（`100 + 50`），否则就是输入值。
  String get _originalDisplay {
    final op = _opByTarget[_AmountEditTarget.original];
    if (op == null) return _originalStr;
    final acc = _accByTarget[_AmountEditTarget.original] ?? 0;
    return '${_trimZeros(acc)} ${_opGlyph(op)} $_originalStr';
  }

  /// 自定义金额字段当前编辑用的串：键盘串优先（含未完成的小数点，不能用
  /// double 回显），没碰过则回退到已存值的展示串。
  String _customFieldStr(String syncId) =>
      _customFieldStrs[syncId] ??
      CustomFieldValueCodec.toDisplayString(_customValues[syncId]) ??
      '';

  /// 自定义金额字段位的显示串：运算模式下带算式（与原始金额位同口径），
  /// 算式只在**当前聚焦的那个字段**上显示。
  String _customFieldDisplay(String syncId) {
    final op = _opByTarget[_AmountEditTarget.customField];
    if (op == null || _customFieldSyncId != syncId) {
      return _customFieldStr(syncId);
    }
    final acc = _accByTarget[_AmountEditTarget.customField] ?? 0;
    return '${_trimZeros(acc)} ${_opGlyph(op)} ${_customFieldStr(syncId)}';
  }

  /// 把自定义金额字段的键盘串写回值快照。
  ///
  /// 键盘串是这些字段的**唯一权威**：空串 / 非法串 → 删键（= 未填写），这样
  /// 「退格清空」才会真的落成空值，而不是被组件里那份快照的旧值顶回来。
  /// 幂等，可在每次击键后无脑调用。
  void _applyCustomFieldAmountValues() {
    for (final entry in _customFieldStrs.entries) {
      final value =
          CustomFieldValueCodec.fromInput(CustomFieldType.amount, entry.value);
      if (value == null) {
        _customValues.remove(entry.key);
      } else {
        _customValues[entry.key] = value;
      }
    }
  }

  /// 点自定义字段的金额位：把下方数字键盘的输入目标切到它。
  void _focusCustomField(String syncId) {
    setState(() {
      if (_customFieldSyncId != syncId) {
        // 换字段：上一个字段遗留的半截算式（累加器/运算符）不能带过来
        _accByTarget.remove(_AmountEditTarget.customField);
        _opByTarget.remove(_AmountEditTarget.customField);
      }
      _customFieldSyncId = syncId;
      _editTarget = _AmountEditTarget.customField;
      // 把已存值读成键盘串作为起点（此后首键是「追加」而不是覆盖，
      // 与原始金额位的既有手感一致）。
      _customFieldStrs.putIfAbsent(syncId, () => _customFieldStr(syncId));
    });
  }

  // 两个运算符键各自独立的模式(false=加/减,true=乘/除),长按各自切换,互不影响。
  bool _mulKey1 = false; // 键1:+ ↔ ×
  bool _mulKey2 = false; // 键2:− ↔ ÷

  // 高频备注列表（包含使用次数）
  List<NoteHistoryEntry> _frequentNotes = [];

  // 备注框焦点节点
  final FocusNode _noteFocusNode = FocusNode();
  // 用 ValueNotifier 承载焦点状态：焦点变化只重建外层 AnimatedPadding，
  // 不再 setState 重建整个 sheet（数字键盘/标签/账户/币种换算全部子树）。
  final ValueNotifier<bool> _noteFieldHasFocus = ValueNotifier(false);

  // 防重复提交标志
  bool _isSubmitting = false;

  // 已选标签ID列表
  late List<int> _selectedTagIds;

  // 待上传的附件列表（新建交易时）
  List<File> _pendingAttachments = [];

  // 交易标记（旗标弹窗）
  bool _excludeFromStats = false;
  bool _excludeFromBudget = false;

  // v46 自定义字段值(fieldSyncId → value)。初值来自编辑回显;
  // [CustomFieldsSection] 每次变更上抛全量快照。
  late Map<String, dynamic> _customValues;

  // v30 交易级多币种(L7 自动探测 + L12 无账户手选)
  String? _pickedCurrency; // 无账户时手选的币种;null = 本位币
  String? _selectedAccountCurrency; // 所选账户的币种(异步查,null = 未选/未知)
  String? _rateStr; // 本笔汇率(字符串);编辑模式初值=隐含汇率,用户可改
  bool _rateManuallySet = false; // 手改/隐含汇率后不再被有效汇率覆盖
  bool _fetchingRate = false; // 正在自动拉取汇率(汇率行显示获取中)
  String? _rateFetchAttemptedFor; // 已自动拉过的币种(防循环重试)

  @override
  void initState() {
    super.initState();
    _date = widget.initialDate;
    _excludeFromStats = widget.initialExcludeFromStats;
    _excludeFromBudget = widget.initialExcludeFromBudget;
    _selectedAccountId = widget.initialAccountId;
    _selectedTagIds = List.from(widget.initialTagIds ?? []);
    _customValues = Map<String, dynamic>.from(widget.initialCustomValues);
    _pickedCurrency = widget.initialCurrencyCode?.toUpperCase();
    // 编辑外币交易:汇率行初值 = 该笔隐含汇率(nativeAmount / amount),
    // 只改备注/分类时折算基准不漂移(01 §4.2)。
    final initAmount = widget.initialAmount ?? 0;
    final initNative = widget.initialNativeAmount;
    if (initNative != null && initAmount > 0 && initNative != initAmount) {
      _rateStr = (initNative / initAmount).toStringAsPrecision(6);
      _rateManuallySet = true;
    }
    if (widget.initialAccountId != null) {
      _loadAccountCurrency(widget.initialAccountId!);
    }
    // 保留原始小数（最多两位），避免编辑已有记录时小数被截断为整数
    final init = widget.initialAmount ?? 0;
    final s = init.toStringAsFixed(2);
    // 去除多余 0 和结尾的小数点
    final trimmed = s.contains('.')
        ? s.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
        : s;
    _amountStr = trimmed.isEmpty ? '0' : trimmed;
    _noteCtrl.text = widget.initialNote ?? '';
    // v45 原始金额回显:null → 留空(即「未填写」，保存时兜底为记账金额)。
    final initOriginal = widget.initialOriginalAmount;
    if (initOriginal != null) {
      final os = initOriginal.toStringAsFixed(2);
      final ot = os.contains('.')
          ? os.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
          : os;
      _originalStr = ot.isEmpty ? '0' : ot;
    }

    // 监听焦点变化：写入 ValueNotifier，只触发外层 AnimatedPadding 局部重建
    _noteFocusNode.addListener(() {
      _noteFieldHasFocus.value = _noteFocusNode.hasFocus;
    });

    // 加载最近使用的备注
    _loadRecentNotes();
  }

  @override
  void dispose() {
    _noteFocusNode.dispose();
    _noteFieldHasFocus.dispose();
    super.dispose();
  }

  Future<void> _loadRecentNotes() async {
    final repo = ref.read(repositoryProvider);
    final notes = await NoteHistoryService.getHistoryNotes(
      repository: repo,
      ledgerId: widget.ledgerId,
      scope: ref.read(noteHistoryScopeProvider),
      sort: ref.read(noteHistorySortProvider),
      categoryId: widget.categoryId,
      categorySyncId: widget.categorySyncId,
      limit: ref.read(noteHistoryLimitProvider),
    );
    if (!mounted) return; // 弹窗已关时不再 setState(widget 测试暴露的既有问题)
    setState(() {
      _frequentNotes = notes;
    });
  }

  Future<void> _loadAccountCurrency(int accountId) async {
    final repo = ref.read(repositoryProvider);
    // getAccountCurrencyByAnyId:正数查主表;负数是共享账本 Owner 资源的
    // synthetic id(§7),查镜像表 —— 否则成员选 Owner 外币账户会被静默
    // 解析成本位币(审查发现)。
    final currency = await repo.getAccountCurrencyByAnyId(accountId);
    if (!mounted) return;
    setState(() {
      _selectedAccountCurrency = currency;
    });
  }

  /// 交易币种(币种优先联动,第 6 条):手选币种 → 账户列表按它过滤,所选账户
  /// 币种必然一致。有账户但其币种尚在异步加载时,fallback 手选币种(而非本位
  /// 币,避免加载窗口内汇率行闪没)。
  String _txCurrency() {
    if (_selectedAccountId != null) {
      return _selectedAccountCurrency ??
          _pickedCurrency ??
          ref.read(currentLedgerCurrencyProvider);
    }
    return _pickedCurrency ?? ref.read(currentLedgerCurrencyProvider);
  }

  /// 本笔汇率:手改/隐含 > 有效汇率(effectiveRatesForLedgerProvider)。
  double? _currentRate() {
    if (_rateManuallySet) return double.tryParse(_rateStr ?? '');
    final rates = ref.read(effectiveRatesForLedgerProvider).valueOrNull;
    final er = rates?[_txCurrency()];
    return er == null ? null : double.tryParse(er.rate);
  }

  /// 外币且本地无该币种汇率时,自动拉一次(v30:记账页是汇率的新消费场景,
  /// 用户可能从没进过资产页/汇率页 → exchange_rates 表为空;且手选币种不在
  //// usedCurrencies 里,常规 refresh 不会带上它 → extraQuotes 显式传入)。
  /// 同一币种只自动试一次,失败后由用户手填(L8 缺失阻断仍兜底)。
  void _maybeAutoFetchRate() {
    final base = ref.read(currentLedgerCurrencyProvider);
    final txCurrency = _txCurrency();
    if (txCurrency == base || _rateManuallySet || _fetchingRate) return;
    if (_rateFetchAttemptedFor == txCurrency) return;
    final ratesAsync = ref.read(effectiveRatesForLedgerProvider);
    final rates = ratesAsync.valueOrNull;
    if (rates == null) return; // provider 尚未解析,等它先出结果
    if (rates.containsKey(txCurrency)) return; // 已有汇率
    _rateFetchAttemptedFor = txCurrency;
    setState(() => _fetchingRate = true);
    refreshExchangeRatesFromUi(ref, force: true, extraQuotes: {txCurrency})
        .whenComplete(() {
      if (mounted) setState(() => _fetchingRate = false);
    });
  }

  Future<void> _pickCurrency() async {
    final l10n = AppLocalizations.of(context);
    final base = ref.read(currentLedgerCurrencyProvider);
    final picked = await showCurrencyPickerSheet(
      context,
      selected: _pickedCurrency ?? base,
      primaryColor: Theme.of(context).colorScheme.primary,
      title: l10n.txCurrencyPickerTitle,
      rateBase: base, // 展示各币种对账本主币种的汇率
    );
    if (picked == null || !mounted) return;
    setState(() {
      _pickedCurrency =
          picked.toUpperCase() == base ? null : picked.toUpperCase();
      // 换币种后隐含/手改汇率作废,重新带有效汇率
      _rateStr = null;
      _rateManuallySet = false;
      // 币种优先联动(第 6 条):切币种 → 账户重置为不选,账户列表按新币种刷新
      // (AccountSelector.filterCurrency 变化触发重载)
      _selectedAccountId = null;
      _selectedAccountCurrency = null;
    });
  }

  Future<void> _editRate() async {
    final l10n = AppLocalizations.of(context);
    final ctrl = TextEditingController(
        text: _rateStr ?? _currentRate()?.toStringAsPrecision(6) ?? '');
    final entered = await showDialog<String>(
      context: context,
      builder: (dctx) => AppDialogShell(
        title: Text(l10n.txRateLabel),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: piggyOutlinedDecoration(
            context,
            hint:
                '1 ${_txCurrency()} = ? ${ref.read(currentLedgerCurrencyProvider)}',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dctx),
            child: Text(AppLocalizations.of(dctx).commonCancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dctx, ctrl.text.trim()),
            child: Text(AppLocalizations.of(dctx).commonConfirm),
          ),
        ],
      ),
    );
    if (entered == null || !mounted) return;
    final v = double.tryParse(entered);
    if (v == null || v <= 0) return;
    setState(() {
      _rateStr = entered;
      _rateManuallySet = true;
    });
  }

  /// 币种标(金额表达式最左):点开即选(币种优先联动:选后账户重置、账户
  /// 列表按新币种过滤)。转账不显示:转账币种恒=账户币种,选了也会被忽略。
  /// 当前「有效金额」：未进运算模式时即输入值；运算模式未按等号时是累加结果。
  /// 与 `doneKey` 里判「完成」可用性的算法一致（那处是 build 内的局部闭包，
  /// 不便共用，此处按同一口径重算一次）。用于换分类时回传金额。
  double _effectiveAmount() {
    final cur = double.tryParse(_amountStr) ?? 0.0;
    // 钉在记账金额口径：换分类回传的是记账金额，与当前焦点无关。
    return _amountOp == null ? cur : _compute(_amountAcc, _amountOp!, cur);
  }

  /// 分类位（P1-E，design.md 决策 4）：放在金额表达式行**最左**。
  ///
  /// 那里本来就是 `Spacer()` 让出的空白，加进去不增加纵向高度 —— 决策 4 的
  /// 风险项「金额表单是否因此显得拥挤」由此规避；同时它落在数字键盘的视觉
  /// 主注视区内，没有藏在备注/标签之下。
  ///
  /// **按可用宽度三级让位**。槽位宽度不由分类位决定：它是 `Expanded`，吃的是
  /// 「币种标 + 算式」剩下的余量，小屏 + 大字模式（或窄屏 + 长金额）下可能
  /// 只剩二三十像素。实测过：槽位剩 ~31px 而分类位内部「图标 16 + 间距 5 +
  /// 箭头 16 = 37px」是硬的，分类名已被 `Flexible` 压到 0 也还是顶出 22px 的
  /// `RenderFlex overflowed`。分类位是**附加信息**、金额才是这张表单的主内容，
  /// 所以窄到一定程度它必须自己让位，而不是把金额行顶坏：
  ///   1. 宽 ≥ 72：图标 + 分类名（96px 上限，超出省略）+ 下拉箭头；
  ///   2. 宽 ≥ 53：去掉名字，图标 + 箭头（仍看得出「可点换分类」）；
  ///   3. 再窄：只剩图标（最小占用 24px）—— 图标是硬约束（分类必须可辨认）。
  Widget _buildCategoryChip(BuildContext context) {
    final category = widget.displayCategory;
    if (category == null) return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    final canPick = widget.onPickCategory != null;
    return LayoutBuilder(
      builder: (context, constraints) {
        // 53 = 图标 16 + 间距 5 + 箭头 16 + 左右内边距 16，是「带箭头」的
        // 最小占用；72 再给分类名留 19px，否则名字只剩省略号、不如不给。
        final showName = constraints.maxWidth >= 72;
        final showArrow = canPick && constraints.maxWidth >= 53;
        // 只剩图标时把内边距收到 4：24px 总宽是分类位能缩到的极限。
        final pad = showArrow || showName ? 8.0 : 4.0;
        return InkWell(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          onTap:
              canPick ? () => widget.onPickCategory!(_effectiveAmount()) : null,
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: pad, vertical: 5),
            decoration: BoxDecoration(
              color: PiggyTokens.surfaceKeySecondary(context),
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CategoryIconWidget(
                  category: category,
                  size: 16,
                  color: PiggyTokens.iconSecondary(context),
                ),
                if (showName) ...[
                  const SizedBox(width: 5),
                  // 自定义分类名可能很长。三重收窄：Flexible（可被压缩）+
                  // 96px 上限（宽屏也不让它挤走金额）+ 省略号。空间不够时
                  // 优先让分类名让位，图标始终保留 —— 分类仍是可辨认的。
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 96),
                      child: Text(
                        category.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        softWrap: false,
                        style: text.bodySmall?.copyWith(
                          color: PiggyTokens.textSecondary(context),
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
                if (showArrow) ...[
                  const SizedBox(width: 5),
                  Icon(Icons.arrow_drop_down,
                      size: 16, color: PiggyTokens.iconSecondary(context)),
                ],
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCurrencyChip(BuildContext context) {
    if (widget.transactionKind == 'transfer') return const SizedBox.shrink();
    final text = Theme.of(context).textTheme;
    ref.watch(currentLedgerCurrencyProvider); // 账本切换时重建
    final txCurrency = _txCurrency();
    return InkWell(
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      onTap: _pickCurrency,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: PiggyTokens.surfaceKeySecondary(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 小国旗(欧元→欧盟旗;区域货币→符号占位)
            currencyFlag(context, txCurrency, width: 19, height: 14, radius: 4),
            const SizedBox(width: 5),
            Text(
              txCurrency,
              style: text.bodySmall?.copyWith(
                color: PiggyTokens.textSecondary(context),
                fontWeight: FontWeight.w600,
              ),
            ),
            Icon(Icons.arrow_drop_down,
                size: 16, color: PiggyTokens.iconSecondary(context)),
          ],
        ),
      ),
    );
  }

  /// 折算预览(仅外币时出现,金额下方右对齐一行,反馈9):`≈ 86.40 CNY`。
  /// 汇率数字不展示(自动拉取内部使用);获取失败时本行变错误提示,可点手填(L8)。
  Widget _buildCurrencySection(BuildContext context) {
    if (widget.transactionKind == 'transfer') return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context);
    final text = Theme.of(context).textTheme;
    final ledgerBase = ref.watch(currentLedgerCurrencyProvider);
    ref.watch(effectiveRatesForLedgerProvider);
    final txCurrency = _txCurrency();
    final isForeign = txCurrency != ledgerBase;
    if (!isForeign) return const SizedBox.shrink();

    final rate = _currentRate();
    if (rate == null && !_fetchingRate) {
      // 外币无汇率 → 自动拉一次(post-frame 防 build 中副作用;方法内幂等防重)
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _maybeAutoFetchRate();
      });
    }
    final amount = double.tryParse(_amountStr) ?? 0.0;
    final preview = (rate != null && rate > 0) ? (amount * rate) : null;
    final rateMissing = rate == null && !_fetchingRate;

    return Padding(
      padding: const EdgeInsets.only(top: 2),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          InkWell(
            // 常态纯展示;仅获取失败时点击手填汇率(L8 兜底)
            onTap: rateMissing ? _editRate : null,
            child: Text(
              preview != null
                  ? l10n.txConvertedPreview(
                      preview.toStringAsFixed(2), ledgerBase)
                  : _fetchingRate
                      ? '≈ … $ledgerBase'
                      : l10n.txRateMissingHint,
              style: text.bodySmall?.copyWith(
                color: rateMissing
                    ? Theme.of(context).colorScheme.error
                    : PiggyTokens.textTertiary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 小键盘当前输入目标对应的串。原始金额位 / 自定义字段金额位被选中时，
  /// 键盘就输在那边。
  String get _activeStr {
    switch (_editTarget) {
      case _AmountEditTarget.original:
        return _originalStr;
      case _AmountEditTarget.customField:
        final syncId = _customFieldSyncId;
        return syncId == null ? '' : _customFieldStr(syncId);
      case _AmountEditTarget.amount:
        return _amountStr;
    }
  }

  set _activeStr(String v) {
    switch (_editTarget) {
      case _AmountEditTarget.original:
        _originalStr = v;
      case _AmountEditTarget.customField:
        final syncId = _customFieldSyncId;
        if (syncId != null) _customFieldStrs[syncId] = v;
      case _AmountEditTarget.amount:
        _amountStr = v;
    }
  }

  void _append(String s) {
    setState(() {
      final cur = _activeStr;
      if (s == '.' && cur.contains('.')) return;
      // 限制两位小数
      if (cur.contains('.')) {
        final dot = cur.indexOf('.');
        final decimals = cur.length - dot - 1;
        if (s != '.' && decimals >= 2) return;
      }
      // 去除前导 0
      if (cur == '0' && s != '.') {
        _activeStr = s;
      } else if (cur == '-0' && s != '.') {
        _activeStr = '-$s';
      } else {
        _activeStr = cur + s;
      }
      _applyCustomFieldAmountValues();
    });
    SystemSound.play(SystemSoundType.click);
  }

  void _backspace() {
    setState(() {
      final cur = _activeStr;
      if (cur.isEmpty) return;
      final next = cur.substring(0, cur.length - 1);
      if (next.isEmpty) {
        // 原始金额与自定义字段金额位允许「空」= 未填写（原始金额保存时兜底
        // 为记账金额）；记账金额不能为空，回落到 0。
        _activeStr = _editTarget == _AmountEditTarget.amount ? '0' : '';
      } else {
        _activeStr = next;
      }
      _applyCustomFieldAmountValues();
    });
    SystemSound.play(SystemSoundType.click);
  }

  // 旧 _toggleSign 已废弃，符号由类别含义决定

  // _setToday 移除，改为点击日历按钮选择日期

  void _pickDate() async {
    // 关闭键盘，避免选择日期后键盘重新弹出
    FocusManager.instance.primaryFocus?.unfocus();

    // 等待键盘完全关闭
    await Future.delayed(const Duration(milliseconds: 100));

    if (!mounted) return;

    final showTime = ref.read(showTransactionTimeProvider);

    if (showTime) {
      // 显示时间功能开启时，使用两步选择器（先日期后时间）
      final res = await showWheelDateTimePicker(
        context,
        initial: _date,
        maxDate: DateTime.now(),
      );
      if (res != null) setState(() => _date = res);
    } else {
      // 普通模式，只选择日期
      final res = await showWheelDatePicker(
        context,
        initial: _date,
        mode: WheelDatePickerMode.ymd,
        maxDate: DateTime.now(),
      );
      if (res != null) setState(() => _date = res);
    }
  }

  /// 用 Decimal 精确运算(避免浮点漂移,如 0.1+0.2),左到右无运算符优先级,
  /// 除零保护;结果四舍五入到最多两位小数(金额精度)。
  double _compute(double a, String op, double b) {
    final da = Decimal.parse(a.toStringAsFixed(2));
    final db = Decimal.parse(b.toStringAsFixed(2));
    final Decimal r;
    switch (op) {
      case '+':
        r = da + db;
        break;
      case '-':
        r = da - db;
        break;
      case '×':
        r = da * db;
        break;
      case '÷':
        if (db == Decimal.zero) return a; // 除零保护:保持被除数不变
        r = (da.toRational() / db.toRational())
            .toDecimal(scaleOnInfinitePrecision: 12);
        break;
      default:
        return b;
    }
    return r.round(scale: 2).toDouble();
  }

  /// 运算符显示字形(减号用真减号 −,而非连字符 -)。
  String _opGlyph(String op) {
    switch (op) {
      case '-':
        return '−';
      case '×':
        return '×';
      case '÷':
        return '÷';
      default:
        return '+';
    }
  }

  @override
  Widget build(BuildContext context) {
    final primary = Theme.of(context).colorScheme.primary;
    final text = Theme.of(context).textTheme;

    double parsed() => double.tryParse(_amountStr) ?? 0.0;

    void applyOp(String op) {
      // 运算符作用于**当前输入目标**：不再把焦点抢回记账金额，
      // 两个金额位的运算状态各自独立（_accByTarget / _opByTarget）。
      final cur = _parsedActive();
      if (_op == null) {
        // 首次点击运算符，将当前值存入累加器
        _acc = cur;
      } else {
        // 左到右:先把上一个运算符算掉
        _acc = _compute(_acc, _op!, cur);
      }
      _op = op;
      _activeStr = '0';
      HapticFeedback.selectionClick();
      SystemSound.play(SystemSoundType.click);
      setState(() {});
    }

    // 计算等号：完成当前运算，将结果写回当前目标，清空该目标的运算状态
    void applyEquals() {
      final op = _opByTarget[_editTarget];
      if (op == null) return; // 没有运算符，不执行
      final cur = _parsedActive();
      final total = _compute(_acc, op, cur);
      _activeStr = _trimZeros(total);
      _acc = 0;
      _op = null;
      _applyCustomFieldAmountValues();
      HapticFeedback.selectionClick();
      SystemSound.play(SystemSoundType.click);
      setState(() {});
    }

    Widget keyBtn(String label, {Color? bg, Color? fg, VoidCallback? onTap}) {
      return Padding(
        // 供 widget 测试定位数字键（金额输入目标切换回归）。
        key: ValueKey('amountKey_$label'),
        padding: const EdgeInsets.all(6),
        child: Material(
          color: bg ?? PiggyTokens.surfaceKey(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          child: InkWell(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            onTap: onTap,
            child: Container(
              height: 60,
              alignment: Alignment.center,
              child: Text(
                label,
                style: text.titleMedium?.copyWith(
                  color: fg ?? PiggyTokens.textPrimary(context),
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ),
      );
    }

    // 运算符键:同时显示「加减」与「乘除」两组运算符;当前激活的一组用主色高亮、
    // 另一组用次级色弱化(主次区分,也作为"长按可切到乘除"的提示)。单击应用激活
    // 运算符,长按切换加减 ↔ 乘除。
    Widget opKey(
        String addSubOp, String mulDivOp, bool isMul, VoidCallback onToggle) {
      final activeOp = isMul ? mulDivOp : addSubOp;
      // 激活的运算符与数字键完全一致(字号 18 / w600),保证视觉粗细相同 —— 字号
      // 更大即使同 weight 笔画也会更粗。未激活更小(14)+ 灰色以分主次。
      TextStyle opStyle(bool active) => text.titleMedium!.copyWith(
            color: active
                ? PiggyTokens.textPrimary(context)
                : PiggyTokens.textTertiary(context),
            fontSize: active ? 18 : 14,
            fontWeight: FontWeight.w600,
          );
      return Padding(
        // 供 widget 测试定位运算符键（输入目标不跳转回归）。
        key: ValueKey('amountOpKey_$addSubOp'),
        padding: const EdgeInsets.all(6),
        child: Material(
          color: PiggyTokens.surfaceKeySecondary(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          child: InkWell(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            onTap: () => applyOp(activeOp),
            // 双击 / 长按都是「切到另一组运算符并直接应用」(一步用上另一个);
            // applyOp 内部已带触感/声音。
            onDoubleTap: () {
              onToggle();
              applyOp(isMul ? addSubOp : mulDivOp);
            },
            onLongPress: () {
              onToggle();
              applyOp(isMul ? addSubOp : mulDivOp);
            },
            child: SizedBox(
              height: 60,
              // 「加减/乘除」中间一个斜杠分隔;单击用激活运算符,长按只切换本键(两键独立)。
              child: Center(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: _opGlyph(addSubOp), style: opStyle(!isMul)),
                    TextSpan(
                      text: '/',
                      style: text.titleMedium!.copyWith(
                        color: PiggyTokens.textTertiary(context),
                        fontSize: 14,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    TextSpan(text: _opGlyph(mulDivOp), style: opStyle(isMul)),
                  ]),
                ),
              ),
            ),
          ),
        ),
      );
    }

    String fmtDate(DateTime d) => '${d.year}/${d.month}/${d.day}';
    String fmtTime(DateTime d) =>
        '${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}:${d.second.toString().padLeft(2, '0')}';
    final showTime = ref.watch(showTransactionTimeProvider);

    return SafeArea(
      top: false,
      // 焦点状态通过 ValueNotifier 隔离：备注框获得/失去焦点、输入法弹起时
      // 只重建外层 AnimatedPadding 的 padding，整个内容 Column 作为 child
      // 传入保持引用不变，避免重建数字键盘/标签/账户/币种换算等全部子树。
      child: ValueListenableBuilder<bool>(
        valueListenable: _noteFieldHasFocus,
        builder: (context, focused, child) {
          final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;
          final extraPadding = (focused && keyboardHeight > 0) ? 100.0 : 0.0;
          return AnimatedPadding(
            duration: const Duration(milliseconds: 100),
            padding: EdgeInsets.fromLTRB(
              16,
              12,
              16,
              16 + extraPadding,
            ),
            child: child!,
          );
        },
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 金额显示区域（表达式模式）
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                // 表达式行:金额表达式。左侧币种标,右侧运算显示。
                Row(
                  children: [
                    // P1-E 分类位：金额行最左，占住「币种标 + 算式」之外的全部剩余
                    // 空间。**必须用 Expanded 而不是原来的 Spacer**：Spacer 只是
                    // 空白、不承载内容，换成它占位后分类位在窄屏上无法被压缩 ——
                    // 实测 320dp + 长分类名 + 6 位金额时把整行顶出 158px。
                    // Expanded 同时满足两件事：宽屏时吃掉剩余空间（视觉与 Spacer
                    // 等价），窄屏时缩到剩余的宽度、由分类位自己三级让位
                    // （收名字 → 收箭头 → 只剩图标，见 `_buildCategoryChip`）。
                    Expanded(
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: _buildCategoryChip(context),
                      ),
                    ),
                    // v30 币种标:金额表达式的最左侧(反馈11:运算模式下
                    // 不能夹在「10 + 20」中间),点开选币种。
                    _buildCurrencyChip(context),
                    const SizedBox(width: 6),
                    if (_amountOp != null) ...[
                      // 显示累加值（钉在记账金额口径，与当前焦点无关）
                      Text(
                        (() {
                          final s = _amountAcc.abs().toStringAsFixed(2);
                          final r1 = s.contains('.')
                              ? s.replaceFirst(RegExp(r'0+$'), '')
                              : s;
                          return r1.endsWith('.')
                              ? r1.substring(0, r1.length - 1)
                              : r1;
                        })(),
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: PiggyTokens.textSecondary(context),
                        ),
                      ),
                      // 显示运算符
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8),
                        child: Text(
                          _opGlyph(_amountOp!),
                          style: text.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: primary,
                          ),
                        ),
                      ),
                    ],
                    // 当前输入值。
                    // 可点击：把自定义小键盘的输入目标切回报账金额；选中态用
                    // 主色描边 + 淡底，与原始金额位形成"谁在接收输入"的对照。
                    //
                    // Expanded(flex 3)：金额位必须**占满**自己的槽位，右边界才会
                    // 与下方「原始金额」框、自定义字段金额位对齐到同一条竖线
                    // （原来是 Flexible/loose：金额只包住文字、右侧空一大截，三个
                    // 输入框长短不一）。与分类位按 1:3 分走剩余宽度，故窄屏不会
                    // 因此新增溢出；空间不够时内层 FittedBox 等比缩放，金额始终
                    // 完整可见、不被截断。
                    Expanded(
                      flex: 3,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () => setState(
                            () => _editTarget = _AmountEditTarget.amount),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          decoration: BoxDecoration(
                            // 金额位常显填充框（与原始金额位同口径）：
                            // 未聚焦用 surfaceInput 浅底保证可见，聚焦时叠主色
                            // 淡底 + 主色描边，仍保留"谁在接收输入"的对照。
                            color: _editTarget == _AmountEditTarget.amount
                                ? PiggyTokens.surfaceSelected(context)
                                : PiggyTokens.surfaceInput(context),
                            borderRadius:
                                BorderRadius.circular(PiggyDimens.radiusLg),
                            border: Border.all(
                              width: 1.5,
                              color: _editTarget == _AmountEditTarget.amount
                                  ? primary
                                  : Colors.transparent,
                            ),
                          ),
                          // 空间不够时等比缩小；够用时逐像素不变。
                          // 金额是主内容，宁可缩小也不截断、也不把行顶破。
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            alignment: Alignment.centerRight,
                            child: Text(
                              _amountStr,
                              key: const ValueKey('amountEditorAmountValue'),
                              style: text.titleLarge?.copyWith(
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.0,
                                color: PiggyTokens.textPrimary(context),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
                // 等号行：仅当记账金额位有运算符时显示
                if (_amountOp != null) ...[
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      Text(
                        '= ',
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w500,
                          color: PiggyTokens.textTertiary(context),
                        ),
                      ),
                      Text(
                        (() {
                          final cur = parsed();
                          final total = _compute(_amountAcc, _amountOp!, cur);
                          final s = total.abs().toStringAsFixed(2);
                          final r1 = s.contains('.')
                              ? s.replaceFirst(RegExp(r'0+$'), '')
                              : s;
                          return r1.endsWith('.')
                              ? r1.substring(0, r1.length - 1)
                              : r1;
                        })(),
                        style: text.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: primary,
                        ),
                      ),
                    ],
                  ),
                ],
                // v30 折算预览:金额模块区域内、金额/等号下方(反馈11)。
                _buildCurrencySection(context),
              ],
            ),
            const SizedBox(height: 10),
            // v45 原始金额(选填):留空 = 未填写(提交 null),统计层按记账
            // 金额兜底。刻意复用备注框的浅填充无边框样式 —— 只占一行,不
            // 抢占上方数字键盘的主输入动线。
            Row(
              children: [
                Icon(Icons.receipt_long_outlined,
                    size: 16, color: PiggyTokens.iconSecondary(context)),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context).txOriginalAmountLabel,
                  style: text.labelMedium?.copyWith(
                    color: PiggyTokens.textSecondary(context),
                  ),
                ),
                const SizedBox(width: 10),
                // 伪输入框：点它把自定义小键盘的输入目标切到原始金额，
                // 自身不弹系统键盘（避免两套键盘争抢输入）。
                Expanded(
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () => setState(
                        () => _editTarget = _AmountEditTarget.original),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 120),
                      height: 40,
                      alignment: Alignment.centerLeft,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: PiggyTokens.surfaceInput(context),
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusLg),
                        border: Border.all(
                          width: 1.5,
                          color: _editTarget == _AmountEditTarget.original
                              ? primary
                              : Colors.transparent,
                        ),
                      ),
                      child: Text(
                        _originalDisplay.isEmpty
                            ? AppLocalizations.of(context).txOriginalAmountHint
                            : _originalDisplay,
                        key: const ValueKey('amountEditorOriginalValue'),
                        style: _originalDisplay.isEmpty
                            ? text.labelSmall?.copyWith(
                                color: PiggyTokens.textTertiary(context))
                            : text.bodyMedium?.copyWith(
                                color: PiggyTokens.textPrimary(context),
                                fontWeight: FontWeight.w600,
                              ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            // 备注输入区域 - 带历史备注图标前缀
            TextField(
              focusNode: _noteFocusNode,
              controller: _noteCtrl,
              style: TextStyle(color: PiggyTokens.textPrimary(context)),
              decoration: InputDecoration(
                hintText: AppLocalizations.of(context).commonNoteHint,
                hintStyle: TextStyle(color: PiggyTokens.textTertiary(context)),
                isDense: true,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                  borderSide: BorderSide.none,
                ),
                filled: true,
                fillColor: PiggyTokens.surfaceInput(context),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                // 历史备注图标作为前缀
                prefixIcon: _frequentNotes.isNotEmpty
                    ? GestureDetector(
                        onTap: () async {
                          await showDialog(
                            context: context,
                            builder: (context) => NotePickerDialog(
                              ledgerId: widget.ledgerId,
                              categoryId: widget.categoryId,
                              categorySyncId: widget.categorySyncId,
                              onNotePicked: (note) {
                                setState(() {
                                  _noteCtrl.text = note;
                                  _noteCtrl.selection =
                                      TextSelection.fromPosition(
                                    TextPosition(offset: note.length),
                                  );
                                });
                              },
                            ),
                          );
                        },
                        child: Icon(
                          Icons.history,
                          color: PiggyTokens.iconSecondary(context),
                          size: 20,
                        ),
                      )
                    : null,
                prefixIconConstraints: _frequentNotes.isNotEmpty
                    ? const BoxConstraints(
                        minWidth: 40,
                        minHeight: 20,
                      )
                    : null,
              ),
            ),
            // 账户选择（仅在启用时显示）
            if (widget.showAccountPicker) ...[
              const SizedBox(height: 8),
              Consumer(
                builder: (context, ref, child) {
                  // 检查账户功能是否启用
                  final accountFeatureAsync =
                      ref.watch(accountFeatureEnabledProvider);
                  return accountFeatureAsync.when(
                    data: (enabled) {
                      if (!enabled) return const SizedBox.shrink();

                      // 使用新的横滑账户选择器
                      return AccountSelector(
                        selectedAccountId: _selectedAccountId,
                        ledgerId: widget.ledgerId,
                        // 币种优先联动:账户列表只显示当前所选币种的账户
                        filterCurrency: _txCurrency(),
                        // 账户隐藏(#240)E1 钉住:该笔交易本来挂的账户(编辑
                        // 态)若已被隐藏,选择器补回并打灰标,可原样保存。
                        pinnedAccountId: widget.initialAccountId,
                        onAccountSelected: (accountId) {
                          setState(() {
                            _selectedAccountId = accountId;
                            _selectedAccountCurrency = null; // 异步刷新
                          });
                          if (accountId != null) {
                            _loadAccountCurrency(accountId);
                          }
                        },
                      );
                    },
                    loading: () => const SizedBox.shrink(),
                    error: (_, __) => const SizedBox.shrink(),
                  );
                },
              ),
            ],
            // 标签和附件选择区域（一行）
            const SizedBox(height: 8),
            _buildTagAndAttachmentRow(),
            // v46 自定义字段录入分区（该账本无定义时整块隐藏）
            _buildCustomFieldsSection(),
            const SizedBox(height: 10),
            // 数字键盘
            LayoutBuilder(builder: (ctx, c) {
              final w = (c.maxWidth) / 4;
              Widget dateKey() => Padding(
                    padding: const EdgeInsets.all(6),
                    child: Material(
                      color: PiggyTokens.surfaceKeySecondary(context),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusLg),
                        onTap: () {
                          SystemSound.play(SystemSoundType.click);
                          _pickDate();
                        },
                        child: SizedBox(
                          height: 60,
                          child: Center(
                            child: showTime
                                ? Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Text(
                                        fmtDate(_date),
                                        style: text.labelSmall?.copyWith(
                                            color: PiggyTokens.textPrimary(
                                                context),
                                            fontWeight: FontWeight.w600),
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        fmtTime(_date),
                                        style: text.labelSmall?.copyWith(
                                            color: PiggyTokens.textSecondary(
                                                context),
                                            fontWeight: FontWeight.w500),
                                      ),
                                    ],
                                  )
                                : Text(
                                    fmtDate(_date),
                                    style: text.labelMedium?.copyWith(
                                        color: PiggyTokens.textPrimary(context),
                                        fontWeight: FontWeight.w600),
                                  ),
                          ),
                        ),
                      ),
                    ),
                  );
              Widget closeKey() => Padding(
                    padding: const EdgeInsets.all(6),
                    child: Material(
                      color: PiggyTokens.surfaceKey(context),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                      child: InkWell(
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusLg),
                        onTap: _backspace,
                        child: SizedBox(
                          height: 60,
                          child: Center(
                              child: Icon(Icons.backspace_outlined,
                                  color: PiggyTokens.textPrimary(context))),
                        ),
                      ),
                    ),
                  );
              Widget doneKey() {
                // 提交的是**记账金额**：求值必须用记账金额位的运算状态，
                // 与当前焦点无关（否则焦点在原始金额时会漏算记账侧的算式）。
                final cur = parsed();
                final total = _amountOp == null
                    ? cur
                    : _compute(_amountAcc, _amountOp!, cur);

                // 当前焦点位仍在运算中时，「完成」先当等号用。
                final isInCalcMode = _op != null;
                final isEnabled =
                    (isInCalcMode ? true : total.abs() > 0) && !_isSubmitting;

                return Padding(
                  padding: const EdgeInsets.all(6),
                  child: Material(
                    color: isEnabled
                        ? primary
                        : PiggyTokens.surfaceDisabled(context),
                    borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                    child: InkWell(
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                      onTap: isEnabled
                          ? () async {
                              if (isInCalcMode) {
                                // 运算模式：点击等号计算结果
                                applyEquals();
                                return;
                              }

                              // 正常模式：提交
                              // 防重复点击
                              if (_isSubmitting) return;
                              setState(() => _isSubmitting = true);

                              // v30:折本位币快照。外币且汇率无效 → 阻断(L8)。
                              final txCurrency = _txCurrency();
                              final ledgerBase =
                                  ref.read(currentLedgerCurrencyProvider);
                              double? nativeAmount;
                              if (txCurrency == ledgerBase) {
                                nativeAmount = total.abs();
                              } else {
                                final r = _currentRate();
                                if (r == null || r <= 0) {
                                  setState(() => _isSubmitting = false);
                                  showToast(
                                      context,
                                      AppLocalizations.of(context)
                                          .txRateMissingHint);
                                  return;
                                }
                                nativeAmount = total.abs() * r;
                              }

                              HapticFeedback.lightImpact();
                              SystemSound.play(SystemSoundType.click);
                              // v45 原始金额:空串/非法输入 → null,由仓储层
                              // 在保存时兜底为记账金额(产品口径:每条明细都有
                              // 原始金额)。
                              final ogText = _originalStr.trim();
                              final originalAmount = ogText.isEmpty
                                  ? null
                                  : double.tryParse(ogText);
                              widget.onSubmit((
                                amount: total.abs(), // 始终正数
                                note: _noteCtrl.text.isEmpty
                                    ? null
                                    : _noteCtrl.text,
                                date: _date,
                                accountId: _selectedAccountId,
                                tagIds: _selectedTagIds,
                                pendingAttachments: _pendingAttachments,
                                excludeFromStats: _excludeFromStats,
                                excludeFromBudget: _excludeFromBudget,
                                currencyCode: txCurrency,
                                nativeAmount: nativeAmount,
                                originalAmount: originalAmount,
                                // v46 自定义字段:原值与现值都为空 → null
                                // (不改动,避免把别的设备已填的值抹掉);
                                // 否则提交全量快照(空 map = 显式清空)。
                                customValues: (_customValues.isEmpty &&
                                        widget.initialCustomValues.isEmpty)
                                    ? null
                                    : Map<String, dynamic>.from(_customValues),
                              ));

                              // 注意：不需要在这里重置 _isSubmitting
                              // 因为提交后整个 Sheet 会被关闭，State 会被销毁
                            }
                          : null,
                      child: SizedBox(
                        height: 60,
                        child: Center(
                          child: _isSubmitting
                              ? SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    // UI-14：主色底上的前景走 textOnPrimary token
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                        PiggyTokens.textOnPrimary(context)),
                                  ),
                                )
                              : Text(
                                  isInCalcMode
                                      ? '='
                                      : AppLocalizations.of(context)
                                          .commonFinish,
                                  style: TextStyle(
                                      // UI-14：同上；禁用态用 textDisabled 语义更准
                                      color: isEnabled
                                          ? PiggyTokens.textOnPrimary(context)
                                          : PiggyTokens.textDisabled(context),
                                      fontSize: isInCalcMode ? 24 : 16,
                                      fontWeight: FontWeight.w700),
                                ),
                        ),
                      ),
                    ),
                  ),
                );
              }

              return Column(
                children: [
                  Row(children: [
                    SizedBox(
                        width: w,
                        child: keyBtn('7', onTap: () => _append('7'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('8', onTap: () => _append('8'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('9', onTap: () => _append('9'))),
                    SizedBox(width: w, child: dateKey()),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    SizedBox(
                        width: w,
                        child: keyBtn('4', onTap: () => _append('4'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('5', onTap: () => _append('5'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('6', onTap: () => _append('6'))),
                    SizedBox(
                        width: w,
                        child: opKey('+', '×', _mulKey1,
                            () => setState(() => _mulKey1 = !_mulKey1))),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    SizedBox(
                        width: w,
                        child: keyBtn('1', onTap: () => _append('1'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('2', onTap: () => _append('2'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('3', onTap: () => _append('3'))),
                    SizedBox(
                        width: w,
                        child: opKey('-', '÷', _mulKey2,
                            () => setState(() => _mulKey2 = !_mulKey2))),
                  ]),
                  const SizedBox(height: 2),
                  Row(children: [
                    SizedBox(
                        width: w,
                        child: keyBtn('.', onTap: () => _append('.'))),
                    SizedBox(
                        width: w,
                        child: keyBtn('0', onTap: () => _append('0'))),
                    SizedBox(width: w, child: closeKey()),
                    SizedBox(width: w, child: doneKey()),
                  ]),
                ],
              );
            })
          ],
        ),
      ),
    );
  }

  /// v46 自定义字段录入分区。
  ///
  /// 定义按账本走 `customFieldsForCurrentLedgerProvider`；该账本没有定义 / 定义
  /// 尚未加载完成时返回 [SizedBox.shrink]，布局与改动前逐字一致。值变更只更新
  /// 本地快照（不 setState），避免每次击键重建整个 sheet 的数字键盘与标签区。
  ///
  /// v47：金额类型的字段改由**下方这套数字键盘**输入（点金额位 → 键盘目标切
  /// 过去），样式与「原始金额」位一致；字段名列宽也按原始金额行量出，让金额位
  /// 的左边界与原始金额位对齐。
  Widget _buildCustomFieldsSection() {
    final definitions =
        ref.watch(customFieldsForCurrentLedgerProvider).valueOrNull ??
            const <CustomFieldDefinition>[];
    if (definitions.isEmpty) return const SizedBox.shrink();

    final l10n = AppLocalizations.of(context);
    final amountFieldIds = [
      for (final def in definitions)
        if (def.fieldType == CustomFieldType.amount &&
            (def.syncId ?? '').isNotEmpty)
          def.syncId!,
    ];
    final hasAmountField = amountFieldIds.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: CustomFieldsSection(
        definitions: definitions,
        initialValues: widget.initialCustomValues,
        onChanged: (values) {
          // 组件上抛的是它自己那份快照，金额位的键盘串不在其中 —— 接住其它
          // 字段的值后立刻用键盘串覆盖回来，否则刚清空的金额会被旧值顶回去。
          _customValues = values;
          _applyCustomFieldAmountValues();
        },
        onAmountFieldTapped: hasAmountField ? _focusCustomField : null,
        activeAmountSyncId: _editTarget == _AmountEditTarget.customField
            ? _customFieldSyncId
            : null,
        amountTextOverride: hasAmountField
            ? {for (final id in amountFieldIds) id: _customFieldDisplay(id)}
            : null,
        // 字段名列 + 行内 8px 间距 = 原始金额位的左缩进 → 两个金额位的左边界
        // 落在同一条竖线上。
        labelWidth:
            (_amountFieldLeadingInset(context, l10n) - 8).clamp(76.0, 212.0),
      ),
    );
  }

  /// 金额输入位的左缩进：「原始金额」行的图标 + 标签 + 间距总宽。
  ///
  /// 用 [TextPainter] 现量而不是写死常量：标签宽度随语言与系统字号变化。
  /// 记账金额行左侧的币种/分类位是另一个量级，不参与这个对齐。
  double _amountFieldLeadingInset(BuildContext context, AppLocalizations l10n) {
    final style = Theme.of(context).textTheme.labelMedium!;
    final painter = TextPainter(
      text: TextSpan(text: l10n.txOriginalAmountLabel, style: style),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    // icon 16 + 间距 6 + 标签 + 间距 10（与原始金额行的排布一致）
    return (16 + 6 + painter.width + 10).clamp(84.0, 220.0);
  }

  /// 构建标签和附件选择行（一行显示）
  Widget _buildTagAndAttachmentRow() {
    // §7 共享账本:用按当前 ledger 过滤后的 tags(Editor 视角下走 SharedLedgerTags,
    // synthetic id 跟 tag picker 一致),否则编辑模式 tx 已选的 synthetic id 在
    // 主表里找不到,显示"无标签"。
    final allTagsAsync = ref.watch(tagsForCurrentLedgerProvider);
    final allTags = allTagsAsync.valueOrNull ?? [];

    // 获取已选中的标签详情
    final selectedTags =
        allTags.where((t) => _selectedTagIds.contains(t.id)).toList();

    // 获取附件数量
    if (widget.editingTransactionId != null) {
      final attachmentsAsync = ref
          .watch(transactionAttachmentsProvider(widget.editingTransactionId!));
      // 同样使用 valueOrNull 避免闪烁
      final attachments = attachmentsAsync.valueOrNull ?? [];
      final totalCount = attachments.length + _pendingAttachments.length;
      return _buildRowContent(selectedTags, totalCount, attachments);
    }
    return _buildRowContent(selectedTags, _pendingAttachments.length, []);
  }

  /// 交易标记弹窗：两个标记开关。
  /// 可见性(01 §三):不计入收支 对 income/expense 显示;不计入预算 仅 expense。
  /// 转账两个开关都不显示 → 旗标图标本身不渲染,不会触发此弹窗。
  Future<void> _showFlagsDialog() async {
    final l10n = AppLocalizations.of(context);
    final primary = ref.watch(primaryColorProvider);
    final kind = widget.transactionKind;
    final showStats = kind != 'transfer';
    final showBudget = kind == 'expense';

    // 弹窗内用临时变量 + StatefulBuilder 实现实时切换,关闭时写回 sheet 状态。
    bool stats = _excludeFromStats;
    bool budget = _excludeFromBudget;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            Widget switchTile({
              required String title,
              required String hint,
              required bool value,
              required ValueChanged<bool> onChanged,
            }) {
              return PiggySwitchListTile(
                contentPadding: EdgeInsets.zero,
                dense: true,
                title: Text(
                  title,
                  style: TextStyle(
                    color: PiggyTokens.textPrimary(context),
                    fontSize: 15.0.scaled(context, ref),
                  ),
                ),
                subtitle: Text(
                  hint,
                  style: TextStyle(
                    color: PiggyTokens.textTertiary(context),
                    fontSize: 12.0.scaled(context, ref),
                  ),
                ),
                value: value,
                activeColor: primary,
                onChanged: onChanged,
              );
            }

            return AlertDialog(
              backgroundColor: PiggyTokens.surface(context),
              title: Text(
                l10n.txFlagDialogTitle,
                style: TextStyle(
                  color: PiggyTokens.textPrimary(context),
                  fontSize: 17.0.scaled(context, ref),
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (showStats)
                    switchTile(
                      title: l10n.txFlagExcludeFromStats,
                      hint: l10n.txFlagExcludeFromStatsHint,
                      value: stats,
                      onChanged: (v) {
                        setDialogState(() => stats = v);
                        // 实时写回 sheet 状态,图标 active 态即时更新
                        setState(() => _excludeFromStats = v);
                      },
                    ),
                  if (showBudget)
                    switchTile(
                      title: l10n.txFlagExcludeFromBudget,
                      hint: l10n.txFlagExcludeFromBudgetHint,
                      value: budget,
                      onChanged: (v) {
                        setDialogState(() => budget = v);
                        setState(() => _excludeFromBudget = v);
                      },
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(
                    AppLocalizations.of(context).commonConfirm,
                    style: TextStyle(color: primary),
                  ),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Widget _buildRowContent(List<Tag> selectedTags, int attachmentCount,
      List<TransactionAttachment> savedAttachments) {
    final l10n = AppLocalizations.of(context);
    final hasAttachments = attachmentCount > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: PiggyTokens.surfaceInput(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      child: Row(
        children: [
          // 标签部分（可点击展开）
          Expanded(
            child: GestureDetector(
              onTap: () async {
                final result = await TagSelector.show(
                  context,
                  selectedTagIds: _selectedTagIds,
                );
                if (result != null) {
                  setState(() {
                    _selectedTagIds = result;
                  });
                }
              },
              behavior: HitTestBehavior.opaque,
              child: selectedTags.isEmpty
                  ? Text(
                      l10n.tagSelectTitle,
                      style: PiggyTextTokens.body(context)
                          .copyWith(color: PiggyTokens.textTertiary(context)),
                    )
                  : SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: selectedTags.map((tag) {
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: TagChip(
                              name: tag.name,
                              color: tag.color,
                              size: TagChipSize.small,
                            ),
                          );
                        }).toList(),
                      ),
                    ),
            ),
          ),
          // 间距代替分隔线
          const SizedBox(width: 16),
          // 附件部分（图标 + 数字）
          GestureDetector(
            onTap: () => _handleAttachmentTap(savedAttachments),
            behavior: HitTestBehavior.opaque,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  hasAttachments ? Icons.image : Icons.image_outlined,
                  size: 18,
                  color: hasAttachments
                      ? Theme.of(context).colorScheme.primary
                      : PiggyTokens.iconSecondary(context),
                ),
                if (hasAttachments) ...[
                  const SizedBox(width: 4),
                  Text(
                    '$attachmentCount',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ],
            ),
          ),
          // 旗标图标:紧跟附件图标。转账(两个标记都不适用)→ 不渲染。
          ..._buildFlagIcon(),
        ],
      ),
    );
  }

  /// 账单标记旗标图标:点击打开标记弹窗。
  /// 可见性:转账(income/expense 均不适用)时整体不渲染。
  /// active 态(任一标记为真)用主题色 + 实心旗;否则与附件图标一致的次级灰 + 空心旗。
  List<Widget> _buildFlagIcon() {
    final kind = widget.transactionKind;
    final showStats = kind != 'transfer';
    final showBudget = kind == 'expense';
    // 两个开关都不适用(转账)→ 不显示旗标触发器
    if (!showStats && !showBudget) return const [];

    final active = _excludeFromStats || _excludeFromBudget;
    return [
      const SizedBox(width: 16),
      GestureDetector(
        onTap: _showFlagsDialog,
        behavior: HitTestBehavior.opaque,
        child: Icon(
          active ? Icons.flag : Icons.outlined_flag,
          size: 18,
          color: active
              ? ref.watch(primaryColorProvider)
              : PiggyTokens.iconSecondary(context),
        ),
      ),
    ];
  }

  Future<void> _handleAttachmentTap(
      List<TransactionAttachment> savedAttachments) async {
    final totalCount = savedAttachments.length + _pendingAttachments.length;

    if (totalCount == 0) {
      // 没有附件，直接添加
      await _showAddAttachmentOptions();
    } else {
      // 有附件，打开预览页（支持添加和删除）
      final result = await Navigator.push<List<File>?>(
        context,
        MaterialPageRoute(
          builder: (_) => AttachmentPreviewPage(
            attachments: savedAttachments,
            initialIndex: 0,
            allowDelete: true,
            allowAdd: true,
            pendingFiles: _pendingAttachments,
            transactionId: widget.editingTransactionId,
          ),
        ),
      );
      // 如果返回了新的待上传文件列表，更新状态
      if (result != null) {
        setState(() {
          _pendingAttachments = result;
        });
      }
    }
  }

  Future<void> _showAddAttachmentOptions() async {
    final service = ref.read(attachmentServiceProvider);

    await showAttachmentSourceSheet(
      context,
      onTakePhoto: () async {
        final file = await service.takePhoto();
        if (file != null && mounted) {
          if (widget.editingTransactionId != null) {
            // 编辑模式：直接保存
            await service.saveAttachment(
              transactionId: widget.editingTransactionId!,
              sourceFile: file,
              index: 0,
            );
            ref.read(attachmentListRefreshProvider.notifier).state++;
          } else {
            // 新建模式：添加到待上传列表
            setState(() {
              _pendingAttachments = [..._pendingAttachments, file];
            });
          }
        }
      },
      onPickFromGallery: () async {
        final files = await service.pickFromGallery(
            maxCount: 9 - _pendingAttachments.length);
        if (files.isNotEmpty && mounted) {
          if (widget.editingTransactionId != null) {
            // 编辑模式：直接保存
            await service.saveAttachments(
              transactionId: widget.editingTransactionId!,
              sourceFiles: files,
              startIndex: 0,
            );
            ref.read(attachmentListRefreshProvider.notifier).state++;
          } else {
            // 新建模式：添加到待上传列表
            setState(() {
              _pendingAttachments = [..._pendingAttachments, ...files];
            });
          }
        }
      },
    );
  }
}
