import 'dart:async';

import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../data/db.dart';
import '../../data/repositories/local/local_repository.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../widgets/biz/amount_editor_sheet.dart';
import '../../widgets/category/category_picker_sheet.dart';
import '../../widgets/category/category_selector.dart';
import '../../widgets/transaction/transfer_form.dart';
import '../../styles/tokens.dart';
import '../../services/billing/post_processor.dart';
import '../../services/attachment_service.dart';

/// 以底部抽屉形式弹出交易编辑器（新建 / 编辑通用）
///
/// 内部复用 [TransactionEditorPage] 的逻辑，外层用 [ExpandableBottomSheet]
/// 渲染。编辑模式（[editingTransactionId] 非空）时传入金额/日期/备注/账户/
/// 标签/币种等参数用于回显，抽屉标题切换为「编辑」。
Future<void> showTransactionFormBottomSheet(
  BuildContext context, {
  String initialKind = 'expense',
  int? initialCategoryId,
  bool quickAdd = true,

  /// P1-E 快捷记账模式：无 [initialCategoryId] 时用 R1 的记忆分类直接落金额
  /// 表单（记忆未命中或校验失败则退回分类网格）。见 prd/p1e_quick_entry_mode。
  bool quickMode = false,
  String? initialNote,
  double? initialAmount,
  DateTime? initialDate,
  int? editingTransactionId,
  int? initialAccountId,
  int? initialToAccountId,
  List<int>? initialTagIds,
  bool initialExcludeFromStats = false,
  bool initialExcludeFromBudget = false,
  String? initialCurrencyCode,
  double? initialNativeAmount,
  // v45 原始金额回显(编辑既有明细)。
  double? initialOriginalAmount,
  // v46 自定义字段已存值回显(fieldSyncId → value)。
  Map<String, dynamic> initialCustomValues = const {},
}) async {
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => TransactionEditorPage(
      initialKind: initialKind,
      quickAdd: quickAdd,
      quickMode: quickMode,
      initialCategoryId: initialCategoryId,
      renderAsBottomSheet: true,
      initialNote: initialNote,
      initialAmount: initialAmount,
      initialDate: initialDate,
      editingTransactionId: editingTransactionId,
      initialAccountId: initialAccountId,
      initialToAccountId: initialToAccountId,
      initialTagIds: initialTagIds,
      initialExcludeFromStats: initialExcludeFromStats,
      initialExcludeFromBudget: initialExcludeFromBudget,
      initialCurrencyCode: initialCurrencyCode,
      initialNativeAmount: initialNativeAmount,
      initialOriginalAmount: initialOriginalAmount,
      initialCustomValues: initialCustomValues,
    ),
  );
}

/// 交易编辑器页面
/// 支持创建/编辑收入、支出和转账记录
class TransactionEditorPage extends ConsumerStatefulWidget {
  final String initialKind; // 'expense', 'income', or 'transfer'
  // quickAdd: 点击分类后在当前弹窗上叠加金额输入，保存成功后依次关闭两个弹窗
  final bool quickAdd;

  /// P1-E：无 [initialCategoryId] 时用 R1 记忆分类直落金额表单
  /// （记忆未命中 / 校验失败 → 退回分类网格，不做「先出网格再跳表单」的闪跳）。
  final bool quickMode;
  final int? initialCategoryId;
  final String? initialNote; // 用于金额输入弹窗回填备注
  final double? initialAmount;
  final DateTime? initialDate;
  final int? editingTransactionId;
  final int? initialAccountId;
  final int? initialToAccountId; // 转账时的目标账户
  final List<int>? initialTagIds; // 初始标签ID列表
  final bool initialExcludeFromStats; // 不计入收支，编辑模式回显
  final bool initialExcludeFromBudget; // 不计入预算，编辑模式回显
  // v30 多币种编辑回显(推隐含汇率用)
  final String? initialCurrencyCode;
  final double? initialNativeAmount;
  // v45 原始金额回显:null = 该笔未填写。
  final double? initialOriginalAmount;
  // v46 自定义字段已存值回显(fieldSyncId → value);新建为空。
  final Map<String, dynamic> initialCustomValues;

  /// 是否以底部抽屉形式渲染。
  ///
  /// 为 `true` 时 build 返回 [ExpandableBottomSheet]（用于新建场景）；
  /// 默认 `false` 保持全屏 Scaffold 行为（编辑场景与深链入口）。
  final bool renderAsBottomSheet;

  const TransactionEditorPage({
    super.key,
    required this.initialKind,
    this.quickAdd = false,
    this.quickMode = false,
    this.initialCategoryId,
    this.initialNote,
    this.initialAmount,
    this.initialDate,
    this.editingTransactionId,
    this.initialAccountId,
    this.initialToAccountId,
    this.initialTagIds,
    this.initialExcludeFromStats = false,
    this.initialExcludeFromBudget = false,
    this.initialCurrencyCode,
    this.initialNativeAmount,
    this.initialOriginalAmount,
    this.initialCustomValues = const {},
    this.renderAsBottomSheet = false,
  });

  @override
  ConsumerState<TransactionEditorPage> createState() =>
      _TransactionEditorPageState();
}

class _TransactionEditorPageState extends ConsumerState<TransactionEditorPage> {
  /// 当前选中的类型：'expense' | 'income' | 'transfer'
  String _selectedKind = 'expense';
  bool _autoOpened = false;

  /// P1-E 换分类回路（design.md 决策 5）：金额表单里点分类位时把当前已输金额
  /// 带回存这里，用户在另一个分类上重弹表单时以它作 initialAmount ——
  /// 「换分类保留已输金额」由此只用几行实现，无需把金额提升成额外状态源。
  /// 只在 [_onCategorySelected] 里读，不进 build，故不需要 setState。
  double? _lastAmount;

  /// 已激活（至少构建过一次）的类型集合，用于 IndexedStack 懒加载：
  /// 未访问过的类型返回 SizedBox.shrink()，避免三个子树同时初始化。
  /// 首次切换到某类型时才构建对应组件，已构建的保持存活以保留状态。
  final Set<String> _activatedKinds = {};

  /// 「金额表单优先」形态下按类型缓存的异步初值（记忆分类 / 默认账户）。
  ///
  /// 记账界面**先出、初值后补**：首帧渲染的分类位是占位、「无账户」高亮，
  /// 解析完成后由 [AmountEditorSheet.didUpdateWidget] 原地补上，不做
  /// 「先弹分类网格再跳金额表单」的闪跳。
  final Map<String, Category?> _quickCategoryByKind = {};
  final Map<String, int?> _quickAccountByKind = {};
  final Set<String> _quickInitialsResolved = {};

  /// 金额表单的**实测**高度（见 [_buildQuickEntrySheet]）。
  ///
  /// 转账的账户网格会把自然高度顶到全屏，导致切分段时抽屉高度突变；把它锁定
  /// 到这张表单实测到的高度，"支出 / 收入 / 转账"三段就恒定同高，超出部分由
  /// 转账自身滚动。实测而非写死比例：金额表单的高度随自定义字段数量、账户功能
  /// 是否开启、系统字号变化，写死要么把「完成」键顶出可视区，要么底部留白。
  double? _quickBodyHeight;

  /// 是否走「金额表单优先」形态（P1-E 迭代）：
  /// 点击记账 / 打开编辑，直接落在记账界面，分类退化为记账表单的子界面。
  ///
  /// 覆盖底部抽屉 + 快捷模式（含 `initialKind == 'transfer'`：`TransferForm`
  /// 在 [_buildQuickEntrySheet] 的转账分支里渲染，高度同样被锁定）。快捷开关
  /// 关闭时仍走原有「分类网格 → 点分类 → 金额表单」流程（设置开关是它的退路）。
  /// 编辑交易（`transaction_edit_utils` / AI 对话页）恒走本形态，不受开关控制：
  /// 编辑的第一屏就该是这笔交易的表单。
  bool get _isQuickEntryMode => widget.renderAsBottomSheet && widget.quickMode;

  @override
  void initState() {
    super.initState();
    // 设置初始选中类型
    _selectedKind = widget.initialKind;
    _activatedKinds.add(widget.initialKind);

    // 若需要自动打开金额输入，则在首帧后查询分类并触发
    // 注意：转账类型不走这个逻辑
    //
    // P1-E：条件从「有 initialCategoryId」放宽为「有 initialCategoryId **或**
    // 快捷模式」。快捷模式取 R1 的记忆分类（provider 侧已校验存在性与账本归属）；
    // 缓存未就绪或记忆未命中 → 不预填、不报错。
    if (widget.quickAdd &&
        widget.initialKind != 'transfer' &&
        (widget.initialCategoryId != null || widget.quickMode)) {
      if (_isQuickEntryMode) {
        // 新形态：金额表单已经是主界面，不需要「自动开窗」；只需把异步初值
        // 解析出来交给它。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_resolveQuickInitials(widget.initialKind));
        });
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted || _autoOpened) return;
          // 显式传入的分类优先于记忆：小组件点分类格 / 深链带 category 走前者。
          final categoryId = widget.initialCategoryId ??
              ref
                  .read(quickEntryLastCategoryProvider(widget.initialKind))
                  .valueOrNull;
          if (categoryId == null) return;
          final c = await _resolveCategoryById(categoryId);
          if (!mounted || c == null) return;
          // 切换到对应的类型（提前取出 kind 避免 closure 内流分析丢失非空信息）
          final kind = c.kind;
          setState(() {
            _selectedKind = kind;
            _activatedKinds.add(kind);
          });
          _autoOpened = true;
          // 直接调用 onPick 逻辑，打开金额输入
          await _onCategorySelected(context, c, kind);
        });
      }
    }
    // 注意：转账编辑模式不需要在这里做任何操作，让 TransferForm 自己处理
  }

  /// 解析「金额表单优先」形态某类型的异步初值：分类（显式传入优先，其次记忆）
  /// 与默认账户。两者都取不到就保持空值 —— 用户点分类位 / 账户位自己选，
  /// 不预填错误的值。
  Future<void> _resolveQuickInitials(String kind) async {
    if (!_quickInitialsResolved.add(kind)) return; // 每类型只解析一次
    final ledgerId = ref.read(currentLedgerIdProvider);

    // 分类：只有初始类型才认显式传入的 initialCategoryId（它是"这一笔"的，
    // 用户后来切到另一类型时不该继承）。
    final explicitId =
        kind == widget.initialKind ? widget.initialCategoryId : null;
    final categoryId = explicitId ??
        ref.read(quickEntryLastCategoryProvider(kind)).valueOrNull;
    Category? category;
    if (categoryId != null) {
      final c = await _resolveCategoryById(categoryId);
      // provider 侧已校验记忆分类的存在性与账本归属；这里再核一次 kind，
      // 防止用户切换类型后把另一类型的分类带过来。
      if (c != null && c.kind == kind) category = c;
    }

    // 默认账户：新建且调用方未指定时按类型取默认账户（含币种匹配与隐藏兜底）。
    int? accountId = widget.initialAccountId;
    if (widget.editingTransactionId == null &&
        widget.initialAccountId == null) {
      accountId = await _getDefaultAccountId(kind, ledgerId);
    }

    if (!mounted) return;
    setState(() {
      _quickCategoryByKind[kind] = category;
      _quickAccountByKind[kind] = accountId;
    });
  }

  @override
  Widget build(BuildContext context) {
    if (widget.renderAsBottomSheet) {
      return _buildBottomSheet(context);
    }
    return Scaffold(
      body: Column(
        children: [
          // 紧凑顶部：去除多余留白 + 滑动分段选择器（玻璃风格）
          PiggyHeader(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  Expanded(
                    child: WaitSlidingSegmentedControl<String>(
                      selected: _selectedKind,
                      segments: [
                        WaitSlidingSegment(
                          value: 'expense',
                          label: AppLocalizations.of(context).categoryExpense,
                        ),
                        WaitSlidingSegment(
                          value: 'income',
                          label: AppLocalizations.of(context).categoryIncome,
                        ),
                        WaitSlidingSegment(
                          value: 'transfer',
                          label: AppLocalizations.of(context).transferTitle,
                        ),
                      ],
                      onValueChanged: (value) => setState(() {
                        _selectedKind = value;
                        _activatedKinds.add(value);
                      }),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(AppLocalizations.of(context).commonCancel,
                        style:
                            TextStyle(color: PiggyTokens.textPrimary(context))),
                  )
                ],
              ),
            ),
          ),
          Expanded(
            child: IndexedStack(
              index: _selectedKind == 'expense'
                  ? 0
                  : (_selectedKind == 'income' ? 1 : 2),
              children: [
                _buildKindChild(context, 'expense'),
                _buildKindChild(context, 'income'),
                _buildKindChild(context, 'transfer'),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 按需构建对应类型的子组件（懒加载）
  ///
  /// 仅当类型已在 [_activatedKinds] 中（即用户至少切换到过一次）时才真正构建，
  /// 否则返回空 widget。已构建的子树在 IndexedStack 中保持存活，保留滚动位置等状态。
  ///
  /// [scrollController] 仅底部抽屉场景传入：且只应传给当前激活的分类页，
  /// 避免 expense/income 两个 ListView 同时挂载同一控制器报错。
  Widget _buildKindChild(
    BuildContext context,
    String kind, {
    ScrollController? scrollController,
  }) {
    if (!_activatedKinds.contains(kind)) {
      return const SizedBox.shrink();
    }
    switch (kind) {
      case 'expense':
        return CategorySelector(
          kind: 'expense',
          onCategorySelected: (c) => _onCategorySelected(context, c, 'expense'),
          initialCategoryId: widget.initialCategoryId,
          scrollController: scrollController,
        );
      case 'income':
        return CategorySelector(
          kind: 'income',
          onCategorySelected: (c) => _onCategorySelected(context, c, 'income'),
          initialCategoryId: widget.initialCategoryId,
          scrollController: scrollController,
        );
      case 'transfer':
        return TransferForm(
          onTransferComplete: () => Navigator.of(context).pop(),
          initialFromAccountId: widget.initialAccountId,
          initialToAccountId: widget.initialToAccountId,
          editingTransactionId: widget.editingTransactionId,
          initialAmount: widget.initialAmount,
          initialNote: widget.initialNote,
          initialDate: widget.initialDate,
          initialTagIds: widget.initialTagIds,
        );
      default:
        return const SizedBox.shrink();
    }
  }

  /// 支出 / 收入 / 转账分段选择器（两种形态共用）。
  Widget _buildKindSegments() {
    final l10n = AppLocalizations.of(context);
    return WaitSlidingSegmentedControl<String>(
      selected: _selectedKind,
      segments: [
        WaitSlidingSegment(value: 'expense', label: l10n.categoryExpense),
        WaitSlidingSegment(value: 'income', label: l10n.categoryIncome),
        WaitSlidingSegment(value: 'transfer', label: l10n.transferTitle),
      ],
      onValueChanged: (value) => setState(() {
        _selectedKind = value;
        _activatedKinds.add(value);
        // 金额表单优先形态下，切到新类型时要补解析它自己的初值
        // （记忆分类按类型分族，不继承上一个类型的分类）。
        if (_isQuickEntryMode && value != 'transfer') {
          unawaited(_resolveQuickInitials(value));
        }
      }),
    );
  }

  /// 底部抽屉模式渲染。两条路径：
  ///
  /// - 「金额表单优先」（[_isQuickEntryMode]）：直接呈现记账界面，分类退化为
  ///   它的子界面 —— 见 [_buildQuickEntrySheet]；
  /// - 原「分类网格」路径（快捷开关关闭时）：复用分类选择器与转账表单，
  ///   分段选择器放进标题栏 bottom 槽。
  Widget _buildBottomSheet(BuildContext context) {
    if (_isQuickEntryMode) return _buildQuickEntrySheet(context);

    final l10n = AppLocalizations.of(context);
    // 分段选择器：放标题栏 bottom 槽，宽度铺满（无取消按钮，关闭走左上角 ×）
    final segmentControl = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: _buildKindSegments(),
    );

    // 编辑模式标题显示「编辑」，新建模式显示「记一笔」
    final isEditing = widget.editingTransactionId != null;
    // 背景色取当前模式下的页面背景（淡蓝/深蓝），让弹窗与页面背景融为一体，
    // 而不是像传统 BottomSheet 那样使用卡片色悬浮在页面上（用户要求）。
    final sheetBg = PiggyTokens.scaffoldBackground(context);
    return ExpandableBottomSheet(
      title: isEditing ? l10n.commonEdit : l10n.widgetQuickAddLabel,
      onClose: () => Navigator.of(context).pop(),
      initialChildSize: 0.7,
      minChildSize: 0.35,
      maxChildSize: 1.0,
      backgroundColor: sheetBg,
      bottom: segmentControl,
      bottomHeight: 52,
      builder: (context, scrollController) {
        return IndexedStack(
          index: _selectedKind == 'expense'
              ? 0
              : (_selectedKind == 'income' ? 1 : 2),
          children: [
            // 仅当前激活的分类页接入抽屉 scrollController，
            // 驱动上滑全屏/下滑回弹；其余页传 null 走自带控制器
            _buildKindChild(
              context,
              'expense',
              scrollController:
                  _selectedKind == 'expense' ? scrollController : null,
            ),
            _buildKindChild(
              context,
              'income',
              scrollController:
                  _selectedKind == 'income' ? scrollController : null,
            ),
            _buildKindChild(context, 'transfer'),
          ],
        );
      },
    );
  }

  /// 「金额表单优先」形态（P1-E 迭代）：点击记账直接落在**记账界面**。
  ///
  /// 与旧形态的唯一区别是分类的位置：不再默认铺开分类网格，分类退化为记账
  /// 表单的**子界面** —— 点分类位才弹（`showCategoryPickerSheet`），且子界面与
  /// 记账界面不共享 ScrollController，弹出 / 滚动 / 关闭都不会让记账界面缩进去。
  ///
  /// 因此这里也不再使用 `ExpandableBottomSheet`：那个容器是为「拖拽分类网格
  /// 伸缩抽屉」准备的（分类网格与抽屉共享同一个 ScrollController，拖动网格就
  /// 会改变抽屉高度），而金额表单本身就是自适应高度的内容，不需要伸缩语义。
  Widget _buildQuickEntrySheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final sheetBg = PiggyTokens.scaffoldBackground(context);
    final isEditing = widget.editingTransactionId != null;
    final isTransfer = _selectedKind == 'transfer';
    // 用 Material 而不是裸 Container：表单里有 InkWell（分类位、键盘键等），
    // 需要一个 Material 祖先来画水波。真实场景下 showModalBottomSheet 会提供，
    // 但本组件不该依赖调用方 —— 直接挂到页面上时同样要能正常工作。
    return Material(
      // 供 widget 测试量高度（支出 / 收入 / 转账三段必须恒定同高）。
      key: const ValueKey('quickEntrySheet'),
      color: sheetBg,
      clipBehavior: Clip.antiAlias,
      borderRadius: const BorderRadius.vertical(
        top: Radius.circular(PiggyDimens.radiusXl),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          PiggyTitleBar(
            title: isEditing ? l10n.commonEdit : l10n.widgetQuickAddLabel,
            showBack: true,
            backIcon: const Icon(Icons.close),
            onBack: () => Navigator.of(context).pop(),
            backgroundColor: sheetBg,
            compact: true,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
            child: _buildKindSegments(),
          ),
          if (isTransfer)
            // 转账：内容（两个账户网格）远高于金额表单，锁到实测高度、内部滚动，
            // 而不是把抽屉顶到全屏 —— 这是「切分段时高度不闪现」的关键。
            // 极早期拿不到实测值时兜底给 0.6 屏高（正常路径不会走到）。
            SizedBox(
              height:
                  _quickBodyHeight ?? MediaQuery.sizeOf(context).height * 0.6,
              child: _buildKindChild(context, 'transfer'),
            )
          else
            // 支出 / 收入：保持自然高度（不留白、不滚动），并顺手把高度报上去
            // 供转账对齐。只在非转账分支测量，所以切到转账后这个值就冻结了。
            Flexible(
              child: _BodyHeightReporter(
                onMeasured: _onQuickBodyMeasured,
                child: SingleChildScrollView(
                  child: IndexedStack(
                    index: _selectedKind == 'income' ? 1 : 0,
                    children: [
                      _buildQuickAmountSheet(context, 'expense'),
                      _buildQuickAmountSheet(context, 'income'),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  void _onQuickBodyMeasured(double height) {
    if (!mounted || height <= 0 || height == _quickBodyHeight) return;
    setState(() => _quickBodyHeight = height);
  }

  /// 金额表单优先形态下某个类型的记账表单。
  ///
  /// 分类位点击 → 弹出分类选择**子界面**（独立底部抽屉），返回后由表单自身
  /// 就地更新分类位 —— 表单不关闭、不重建，金额 / 备注 / 标签 / 账户原地保留。
  Widget _buildQuickAmountSheet(BuildContext context, String kind) {
    if (!_activatedKinds.contains(kind)) return const SizedBox.shrink();
    final ledgerId = ref.watch(currentLedgerIdProvider);
    return AmountEditorSheet(
      key: ValueKey('quickAmount_$kind'),
      // 历史字段：金额表单不再靠它展示/提交分类（改走 displayCategory 与提交
      // 结果里的 category），保留是为了不动其它调用方的签名。
      categoryName: _quickCategoryByKind[kind]?.name ?? '',
      displayCategory: _quickCategoryByKind[kind],
      onPickCategory: (current, _) => showCategoryPickerSheet(
        context,
        kind: kind,
        currentCategoryId: current?.id,
      ),
      initialDate: widget.initialDate ?? DateTime.now(),
      initialAmount: widget.initialAmount,
      initialNote: widget.initialNote,
      initialAccountId: _quickAccountByKind[kind] ?? widget.initialAccountId,
      initialTagIds: widget.initialTagIds,
      showAccountPicker: true,
      ledgerId: ledgerId,
      editingTransactionId: widget.editingTransactionId,
      transactionKind: kind,
      initialExcludeFromStats: widget.initialExcludeFromStats,
      initialExcludeFromBudget: widget.initialExcludeFromBudget,
      initialCurrencyCode: widget.initialCurrencyCode,
      initialNativeAmount: widget.initialNativeAmount,
      initialOriginalAmount: widget.initialOriginalAmount,
      initialCustomValues: widget.initialCustomValues,
      onSubmit: (res) => _submitQuickEntry(context, kind, res),
    );
  }

  /// 金额表单优先形态的提交：写库后关掉记账抽屉（**只关一层**）并给反馈。
  ///
  /// 旧形态有两层 modal（金额表单盖在分类网格上）要依次关掉，关完落在网格上；
  /// 这里只有一层，用户点「完成」就直接回到记账前的页面。
  Future<void> _submitQuickEntry(
    BuildContext context,
    String kind,
    AmountEditorResult res,
  ) async {
    await _persistTransaction(context, kind, res);
    if (!context.mounted) return;
    if (Navigator.of(context).canPop()) Navigator.of(context).pop();
    HapticFeedback.lightImpact();
    SystemSound.play(SystemSoundType.click);
  }

  /// 获取默认账户ID（验证币种匹配）
  Future<int?> _getDefaultAccountId(String kind, int ledgerId) async {
    try {
      // 1. 根据类型获取默认账户ID
      final defaultAccountId = kind == 'income'
          ? await ref.read(defaultIncomeAccountIdProvider.future)
          : await ref.read(defaultExpenseAccountIdProvider.future);

      if (defaultAccountId == null) return null;

      // 2. 获取账本币种
      final ledger = await ref.read(ledgerByIdProvider(ledgerId).future);
      if (ledger == null) return null;

      // 3. 获取默认账户信息
      final account =
          await ref.read(accountByIdProvider(defaultAccountId).future);
      if (account == null) return null;

      // 账户隐藏 #240 E3:默认账户已被隐藏时按「无默认」处理(defensive 兜底,
      // 正常路径下隐藏时已清 pref,这里防同步竞态等边缘情况)
      if (account.hidden) return null;

      // 4. 验证币种匹配
      if (account.currency != ledger.currency) return null;

      return defaultAccountId;
    } catch (e) {
      return null;
    }
  }

  /// 按 id 取分类：synthetic(<0) 走共享账本表反查，否则走本地分类表。
  /// §7 共享账本：Editor 编辑共享账本下记的 tx 时，initialCategoryId 可能是
  /// synthetic —— 反查必须走 SharedLedger* 表。
  Future<Category?> _resolveCategoryById(int categoryId) async {
    final repo = ref.read(repositoryProvider);
    if (categoryId < 0 && repo is LocalRepository) {
      return repo.db.findCategoryBySyntheticId(categoryId);
    }
    return repo.getCategoryById(categoryId);
  }

  Future<void> _onCategorySelected(
      BuildContext context, Category c, String kind) async {
    if (!widget.quickAdd) {
      Navigator.pop(context, c);
      return;
    }
    final ledgerId = ref.read(currentLedgerIdProvider);

    // 确定初始账户ID（新建时使用默认账户，编辑时保持原值）
    int? initialAccountId = widget.initialAccountId;
    if (widget.editingTransactionId == null &&
        widget.initialAccountId == null) {
      // 新建模式：尝试获取默认账户
      initialAccountId = await _getDefaultAccountId(kind, ledgerId);
    }

    // await 后检查 mounted，避免页面已卸载仍使用 context 弹出底部表单
    // context 为方法参数,需与 State.mounted 一并校验
    if (!mounted || !context.mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: PiggyTokens.surfaceSheet(context),
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(PiggyDimens.radiusXl)),
      ),
      builder: (ctx) => AmountEditorSheet(
        categoryName: c.name,
        categoryId: c.id,
        categorySyncId: c.id < 0 ? c.syncId : null,
        // P1-E 分类位（决策 4）：编辑交易、小组件带分类的既有调用方一并显示，
        // 不做「只有快捷模式才显示分类」的分叉。
        displayCategory: c,
        // 换分类（网格路径）：本表单盖在分类网格之上，点分类位就把表单收起来
        // 回到网格重选 —— 已输金额经 _lastAmount 带回，用户不必重输。
        //（「金额表单优先」形态不走这里：那份表单不关闭，分类是它的子界面。）
        onPickCategory: (current, amount) async {
          _lastAmount = amount;
          Navigator.of(ctx).pop();
          return null;
        },
        initialDate: widget.initialDate ?? DateTime.now(),
        // 换分类回路回填的金额优先于进入页面时的初始金额
        initialAmount: _lastAmount ?? widget.initialAmount,
        initialNote: widget.initialNote,
        initialAccountId: initialAccountId,
        initialTagIds: widget.initialTagIds,
        showAccountPicker: true,
        ledgerId: ledgerId,
        editingTransactionId: widget.editingTransactionId,
        transactionKind: kind,
        initialExcludeFromStats: widget.initialExcludeFromStats,
        initialExcludeFromBudget: widget.initialExcludeFromBudget,
        initialCurrencyCode: widget.initialCurrencyCode,
        initialNativeAmount: widget.initialNativeAmount,
        initialOriginalAmount: widget.initialOriginalAmount,
        initialCustomValues: widget.initialCustomValues,
        onSubmit: (res) async {
          await _persistTransaction(context, kind, res);
          // 旧流程有两层 modal：金额表单 + 分类网格抽屉，要依次关掉。
          if (ctx.mounted && Navigator.of(ctx).canPop()) {
            Navigator.of(ctx).pop();
          }
          if (context.mounted && Navigator.of(context).canPop()) {
            Navigator.of(context).pop();
          }
          // 反馈：轻微触感 + 系统点击音
          HapticFeedback.lightImpact();
          SystemSound.play(SystemSoundType.click);
        },
      ),
    );
  }

  /// 把金额表单的提交结果写库（附件 / 标签 / 共享账本 override / 同步触发 /
  /// 缓存刷新）。
  ///
  /// 两条路径共用：「分类网格」旧流程（金额表单盖在网格上）与「金额表单优先」
  /// 新流程（分类是表单的子界面）的**写库语义必须逐字一致**，差别只在关几层
  /// modal —— 那由各自的 onSubmit 调用方处理。
  ///
  /// 分类取 [AmountEditorResult.category]：新流程允许用户在表单内换分类，
  /// 闭包捕获的「进入表单时的分类」可能已经过时，不能再作为写入依据。
  Future<void> _persistTransaction(
    BuildContext context,
    String kind,
    AmountEditorResult res,
  ) async {
    final ledgerId = ref.read(currentLedgerIdProvider);
    final repo = ref.read(repositoryProvider);
    final attachmentService = ref.read(attachmentServiceProvider);
    int transactionId;
    // §7 v25:Category 是来自 SharedLedger* 的 synthetic (id<0)时,
    // categoryId 留 null,override 走 syncId。同理对 account/toAccount。
    // res.accountId 可能也是 synthetic(Account picker 用同一规则)。
    final c = res.category;
    final isSyntheticCategory = c != null && c.id < 0;
    final isSyntheticAccount = res.accountId != null && res.accountId! < 0;
    final categoryIdForWrite = isSyntheticCategory ? null : c?.id;
    // synthetic / picker 返 null 时账户 id 写 null。
    // addTransaction 的 accountId 是 int?(直接传 null 即写 null);
    // updateTransaction 的 accountId 是 dynamic,dart null 被解释成
    // Value.absent(=不更新该字段) → 用户选"不选择账户"无效;必须显式
    // 传 d.Value<int?>(null) 才会真清空旧 accountId。
    final accountIdForAdd = isSyntheticAccount ? null : res.accountId;
    final accountIdForUpdate = d.Value<int?>(accountIdForAdd);
    final categoryOverride = isSyntheticCategory ? c.syncId : null;
    final accountOverride = isSyntheticAccount
        ? await _resolveSyncIdByAccountId(res.accountId!, ledgerId)
        : null;
    if (widget.editingTransactionId != null) {
      // 编辑模式：使用repository更新交易
      await repo.updateTransaction(
        id: widget.editingTransactionId!,
        type: kind,
        amount: res.amount,
        categoryId: categoryIdForWrite,
        note: res.note,
        happenedAt: res.date,
        accountId: accountIdForUpdate,
        categorySyncIdOverride: categoryOverride,
        accountSyncIdOverride: accountOverride,
        excludeFromStats: res.excludeFromStats,
        excludeFromBudget: res.excludeFromBudget,
        currencyCode: res.currencyCode,
        nativeAmount: res.nativeAmount,
        // v45 必须显式 d.Value,才能把「清空原始金额」写成 NULL:
        // 直接传 dart null 会被 updateTransaction 当作 absent(不改动),
        // 用户删掉原始金额后永远清不掉(同 accountIdForUpdate 的坑)。
        originalAmount: d.Value<double?>(res.originalAmount),
        // v46 自定义字段:null = 不改动;空 map = 清空;非空 = 覆盖。
        customValues: res.customValues,
      );
      transactionId = widget.editingTransactionId!;
    } else {
      transactionId = await repo.addTransaction(
        ledgerId: ledgerId,
        type: kind,
        amount: res.amount,
        categoryId: categoryIdForWrite,
        happenedAt: res.date,
        note: res.note,
        accountId: accountIdForAdd,
        categorySyncIdOverride: categoryOverride,
        accountSyncIdOverride: accountOverride,
        excludeFromStats: res.excludeFromStats,
        excludeFromBudget: res.excludeFromBudget,
        currencyCode: res.currencyCode,
        nativeAmount: res.nativeAmount,
        originalAmount: res.originalAmount,
        customValues: res.customValues,
      );
    }
    // 保存待上传的附件
    if (res.pendingAttachments.isNotEmpty) {
      await attachmentService.saveAttachments(
        transactionId: transactionId,
        sourceFiles: res.pendingAttachments,
        startIndex: 0,
      );
      // 刷新附件列表缓存
      ref.read(attachmentListRefreshProvider.notifier).state++;
    }
    // 更新标签关联
    // §7 共享账本:tag.id < 0 是 synthetic(Owner tag from SharedLedger*),
    // 主表 Tags 没该行,不能直接写 transaction_tags.tag_id。分两类:
    // - 正数 id → 写 transaction_tags 主表(老路径)
    // - 负数 id → 走 SharedLedgerTags 反查 syncId → 写 transaction_tag_overrides
    final normalTagIds = res.tagIds.where((id) => id >= 0).toList();
    final syntheticTagIds = res.tagIds.where((id) => id < 0).toList();

    if (normalTagIds.isNotEmpty) {
      await repo.updateTransactionTags(
        transactionId: transactionId,
        tagIds: normalTagIds,
      );
      ref.read(tagListRefreshProvider.notifier).state++;
    } else if (widget.editingTransactionId != null) {
      // 编辑模式没主表 tag → 清掉旧主表关联
      await repo.removeAllTagsFromTransaction(transactionId);
      ref.read(tagListRefreshProvider.notifier).state++;
    }

    // §7 写 override:先反查 tx.syncId + 把 synthetic tag_id 翻译成
    // Owner tag syncId,再 upsert 进 TransactionTagOverrides
    if (repo is LocalRepository) {
      final txRow = await (repo.db.select(repo.db.transactions)
            ..where((t) => t.id.equals(transactionId)))
          .getSingleOrNull();
      final txSyncId = txRow?.syncId;
      if (txSyncId != null) {
        await (repo.db.delete(repo.db.transactionTagOverrides)
              ..where((t) => t.transactionSyncId.equals(txSyncId)))
            .go();
        if (syntheticTagIds.isNotEmpty) {
          final allShared =
              await repo.db.select(repo.db.sharedLedgerTags).get();
          final now = DateTime.now().toUtc();
          for (final sid in syntheticTagIds) {
            for (final s in allShared) {
              if (syntheticIdForSyncId(s.syncId) == sid) {
                await repo.db.into(repo.db.transactionTagOverrides).insert(
                      TransactionTagOverridesCompanion.insert(
                        transactionSyncId: txSyncId,
                        tagSyncId: s.syncId,
                        createdAt: now,
                      ),
                    );
                break;
              }
            }
          }
          ref.read(tagListRefreshProvider.notifier).state++;
        }
        // 这里**不再**重复 recordLedgerChange(transaction:update)。
        // 之前为了"override 变化也走 push"专门补一条 update,但
        // - addTransaction / updateTransaction 已经登记过一次 change
        // - _serializeEntityForPush('transaction') 在 push 时**统一**读 DB
        //   最新状态(包括 transaction_tag_overrides 表),payload 自然含
        //   最新 overrides
        // 结论:那条补登记的 update 跟前面的 create/update 推同样 payload,
        // 服务端 sync_changes 表凭空多一条 row(已观察到共享账本 Editor
        // 创建 tx 时 1 秒内 2 条 identical upsert)。直接砍。
      }
    }
    // 统一处理：自动/手动同步与状态刷新（后台静默）
    PostProcessor.sync(ref, ledgerId: ledgerId);
    // 刷新：账本笔数与全局统计
    ref.invalidate(countsForLedgerProvider(ledgerId));
    ref.read(statsRefreshProvider.notifier).state++;
    // 刷新：预算数据
    ref.read(budgetRefreshProvider.notifier).state++;
    // P1-E：这里的 statsRefreshProvider 递增同时就是快捷记账「记忆分类」
    // 的失效锚点（该 provider 直接跟随 statsRefreshProvider 重算，
    // 不在各写入点逐个 invalidate —— 理由见 quick_entry_providers.dart）。
    // 更新小组件数据（后台执行，不阻塞UI）
    if (context.mounted) {
      updateAppWidget(ref, context);
    }
  }

  /// §7 v25:account picker 返 synthetic Account(id<0)时,把 id 反查
  /// SharedLedgerAccounts 拿 syncId,写到 tx.accountSyncIdOverride。
  /// 失败返 null,调用方应回到 accountId int 路径(synthetic 不一致时的兜底)。
  Future<String?> _resolveSyncIdByAccountId(int accountId, int ledgerId) async {
    if (accountId >= 0) return null;
    final repo = ref.read(repositoryProvider);
    if (repo is! LocalRepository) return null;
    // 反查:本地 ledger.syncId → SharedLedgerAccounts ledgerSyncId 范围
    final ledger = await (repo.db.select(repo.db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    if (ledger?.syncId == null) return null;
    final rows = await (repo.db.select(repo.db.sharedLedgerAccounts)
          ..where((t) => t.ledgerSyncId.equals(ledger!.syncId!)))
        .get();
    for (final r in rows) {
      if (syntheticIdForSyncId(r.syncId) == accountId) return r.syncId;
    }
    return null;
  }
}

/// 上报 child 布局后的高度（仅高度变化时回调一下）。
///
/// 用 render object 而不是 `GlobalKey` + post-frame 查询：高度在布局阶段就已知，
/// 不必等到帧后才知道，也不会在 build 里注册回调（那样每次重建都可能重复注册）。
/// 只在高度真的变了才回调，避免「测量 → setState → 再测量」自我循环。
class _BodyHeightReporter extends SingleChildRenderObjectWidget {
  const _BodyHeightReporter({required this.onMeasured, required super.child});

  final ValueChanged<double> onMeasured;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderBodyHeightReporter(onMeasured);

  @override
  void updateRenderObject(
      BuildContext context, _RenderBodyHeightReporter renderObject) {
    renderObject.onMeasured = onMeasured;
  }
}

class _RenderBodyHeightReporter extends RenderProxyBox {
  _RenderBodyHeightReporter(this.onMeasured);

  ValueChanged<double> onMeasured;
  double? _lastReported;

  @override
  void performLayout() {
    super.performLayout();
    final height = size.height;
    if (height == _lastReported) return;
    _lastReported = height;
    // 布局阶段不能 setState，推到帧后执行。
    WidgetsBinding.instance.addPostFrameCallback((_) => onMeasured(height));
  }
}
