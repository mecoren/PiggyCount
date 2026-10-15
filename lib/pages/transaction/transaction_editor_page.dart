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
import '../../data/models/custom_field_values.dart';
import '../../data/repositories/transaction_repository.dart'
    show RecentEntryDefaults;
import '../../models/last_entry_draft.dart';
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

  /// P1-E 快捷记账模式：无 [initialCategoryId] 时**直接落金额表单**（分类初值取
  /// 「5 分钟内继承上一笔」，未命中则留「选择分类」占位）。
  /// 见 prd/p1e_quick_entry_mode 与 [_resolveQuickInitials]。
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
  // v56 退款关联 + 报销状态（F1-b）编辑回显。
  int? initialRefundOfId,
  Transaction? initialRefundTarget,
  String initialReimburseStatus = 'none',
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
      initialRefundOfId: initialRefundOfId,
      initialRefundTarget: initialRefundTarget,
      initialReimburseStatus: initialReimburseStatus,
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

  /// P1-E：无 [initialCategoryId] 时直落金额表单（分类初值 = 5 分钟内继承上一笔；
  /// 未命中 / 校验失败 → 留占位，不做「先出网格再跳表单」的闪跳）。
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
  // v56 退款关联（F1-b）编辑回显：本笔冲正的原交易本地 id + 整行摘要。
  final int? initialRefundOfId;
  final Transaction? initialRefundTarget;
  // v56 报销状态（F1-b）编辑回显：none / pending / reimbursed。
  final String initialReimburseStatus;
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
    this.initialRefundOfId,
    this.initialRefundTarget,
    this.initialReimburseStatus = 'none',
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

  /// 按类型缓存的异步初值（分类 / 账户），**两种形态共用**：
  ///
  /// - 「金额表单优先」形态：记账界面**先出、初值后补** —— 首帧渲染的分类位是
  ///   占位、「无账户」高亮，解析完成后由 [AmountEditorSheet.didUpdateWidget]
  ///   原地补上，不做「先弹分类网格再跳金额表单」的闪跳；
  /// - 「分类网格」形态（快捷开关关闭）：网格路径命中 5 分钟窗口时拿这里的分类
  ///   直接进金额表单；用户手动点分类时也用它兜账户（见 [_onCategorySelected]）。
  ///
  /// 优先链见 [_resolveQuickInitials]。
  final Map<String, Category?> _quickCategoryByKind = {};
  final Map<String, int?> _quickAccountByKind = {};
  final Set<String> _quickInitialsResolved = {};

  /// 「带出上一笔」的来源行缓存（按 kind）。`null` = 该类型暂无来源 → 按钮不渲染。
  ///
  /// 探测在**抽屉首帧后**与**切换分段时**各跑一次（`getLastRecordedTransaction`
  /// 是「ledger_id 等值 + LIMIT 1」的常数级索引查询），**不进 build**：build 里
  /// 查库会在每次击键（金额表单的每个数字键都会重建宿主）时打一发查询。
  final Map<String, Transaction?> _copySourceByKind = {};
  final Set<String> _copySourceProbed = {};

  /// 快捷形态的「带出上一笔」载荷 + 版本号：靠它驱动
  /// [AmountEditorSheet.didUpdateWidget] 就地装填已渲染的表单（连点两次也要重装，
  /// 故版本号必须递增而不是只看载荷是否变化）。
  LastEntryDraft? _lastEntryPrefill;
  int _lastEntryPrefillToken = 0;

  /// 分类网格形态的暂存载荷：网格形态点按钮时不改分类网格，等用户点分类格时
  /// 与那一格一起传进金额表单（见 [_onCategorySelected]）。
  LastEntryDraft? _pendingGridPrefill;

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
    // 条件从「有 initialCategoryId **或** 快捷模式」放宽为「任何非转账的新建
    // 记账」：**5 分钟内再次记账**要能默认继承上一笔的分类与账户，两条形态都要
    // 生效（见 [_resolveQuickInitials]）。未命中窗口时行为与改造前一致 ——
    // 不预填、不报错，等用户自己点分类。
    if (widget.quickAdd && widget.initialKind != 'transfer') {
      if (_isQuickEntryMode) {
        // 金额表单优先形态：金额表单已经是主界面，不需要「自动开窗」；只需把
        // 异步初值解析出来交给它。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) unawaited(_resolveQuickInitials(widget.initialKind));
        });
      } else {
        // 分类网格形态：初值解析出分类就**直接进金额表单**（与「小组件点分类格 /
        // 深链带 category」的既有行为一致），解析不出就停在网格等用户自己点。
        WidgetsBinding.instance.addPostFrameCallback((_) async {
          if (!mounted || _autoOpened) return;
          // 显式传入的分类优先，且**保留原行为**：即使它的 kind 与 initialKind
          // 不同，也切到该分类所属类型再进表单（[_resolveQuickInitials] 会把
          // kind 不符的显式分类当成未命中，故这里单独兜一次）。
          final explicitId = widget.initialCategoryId;
          Category? c = explicitId == null
              ? null
              : await _resolveCategoryById(explicitId);

          if (c == null) {
            await _resolveQuickInitials(widget.initialKind);
            if (!mounted || _autoOpened) return;
            c = _quickCategoryByKind[widget.initialKind];
          }
          // await 之后再核一次 mounted，避免页面已卸载仍用 context 弹表单。
          if (!mounted || c == null) return;

          // 切换到对应的类型（提前取出 kind 避免 closure 内流分析丢失非空信息）
          final kind = c.kind;
          setState(() {
            _selectedKind = kind;
            _activatedKinds.add(kind);
          });
          _autoOpened = true;
          // 「带出上一笔」的来源探测：这条分支会把 _selectedKind 改成分类所属
          // 类型（绕过了分段选择器），不补一次探测的话回到网格后按钮会缺位。
          unawaited(_probeCopySource(kind));
          // 直接调用 onPick 逻辑，打开金额输入
          await _onCategorySelected(context, c, kind);
        });
      }
    }
    // 注意：转账编辑模式不需要在这里做任何操作，让 TransferForm 自己处理

    // 「带出上一笔」：抽屉首帧后探一次当前类型的来源（两种形态共用；编辑态与
    // 转账段由 [_probeCopySource] 直接跳过）。
    if (widget.quickAdd && widget.initialKind != 'transfer') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_probeCopySource(widget.initialKind));
      });
    }
  }

  /// 解析「某类型」的异步初值：分类与账户。两者都取不到就保持空值 ——
  /// 用户点分类位 / 账户位自己选，不预填错误的值。
  ///
  /// **分类优先链**：显式传入（小组件点分类格 / 深链带 category / 编辑既有交易）
  /// > **5 分钟内继承上一笔**（见 [getRecentEntryDefaults]）> 不预填。
  /// **账户优先链**：显式传入 > 5 分钟内继承上一笔（校验后）> 默认账户。
  ///
  /// 继承只对**新建**生效：编辑既有交易时那一笔自己的分类 / 账户就是答案，
  /// 不能被「上一笔」覆盖。
  ///
  /// explicitId 只给初始类型：它是「这一笔」的，切到另一类型不该继承。
  Future<void> _resolveQuickInitials(String kind) async {
    if (!_quickInitialsResolved.add(kind)) return; // 每类型只解析一次
    final ledgerId = ref.read(currentLedgerIdProvider);

    // 5 分钟窗口内「上一笔同类型交易」的默认值：一次查询同时拿到分类与账户
    // （窗口按录入时刻判，按 kind 分族；编辑态返回 null）。
    final inherited = await _inheritedDefaults(kind, ledgerId);

    // ---- 分类：显式 > 继承 > 不预填 ----
    final explicitId =
        kind == widget.initialKind ? widget.initialCategoryId : null;
    Category? category;
    if (explicitId != null) {
      final c = await _resolveCategoryById(explicitId);
      // 再核一次 kind，防止用户切换类型后把另一类型的分类带过来。
      if (c != null && c.kind == kind) category = c;
    }
    final inheritedCategoryId = inherited?.categoryId;
    if (category == null && inheritedCategoryId != null) {
      final c = await _resolveCategoryById(inheritedCategoryId);
      // 继承来的分类可能已被删除；kind 理论上必同（查询已按 kind 过滤），
      // 这里再核一次纯属防御 —— 预填错分类的危害大于不预填。
      if (c != null && c.kind == kind) category = c;
    }

    // ---- 账户：显式 > 继承（校验后）> 默认账户 ----
    int? accountId = widget.initialAccountId;
    if (widget.editingTransactionId == null &&
        widget.initialAccountId == null) {
      final inheritedAccountId = inherited?.accountId;
      if (inheritedAccountId != null) {
        accountId = await _validatedAccountId(inheritedAccountId, ledgerId);
      }
      // 继承为空 / 已被删除 / 已隐藏 / 币种不符 → 退回默认账户（而不是不填）。
      accountId ??= await _getDefaultAccountId(kind, ledgerId);
    }

    if (!mounted) return;
    setState(() {
      _quickCategoryByKind[kind] = category;
      _quickAccountByKind[kind] = accountId;
    });
  }

  /// 取「5 分钟内上一笔同类型交易」的默认值（分类 + 账户），供新建记账预填。
  ///
  /// 编辑既有交易恒返回 `null`（见 [_resolveQuickInitials] 的口径）。
  Future<RecentEntryDefaults?> _inheritedDefaults(String kind, int ledgerId) {
    if (widget.editingTransactionId != null) return Future.value(null);
    return ref
        .read(repositoryProvider)
        .getRecentEntryDefaults(ledgerId: ledgerId, kind: kind);
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
        // 切到新类型时要补解析**它自己**的初值：5 分钟继承按类型分族（支出找
        // 支出、收入找收入），不继承上一个类型的分类（见 [_resolveQuickInitials]）。
        // 两种形态都要解析 —— 网格形态下用户随后点分类时，账户要能取到该类型的
        // 继承值（见 [_onCategorySelected]）。
        if (value != 'transfer') {
          unawaited(_resolveQuickInitials(value));
          // 每个类型各有自己的「上一笔」，切过去要补探一次（结果缓存，只探一次）。
          unawaited(_probeCopySource(value));
        }
      }),
    );
  }

  /// 「带出上一笔」入口是否**允许出现**：新建态 + 非转账段 + 走抽屉形态。
  ///
  /// 编辑既有交易时不出现：那一笔自己的值就是答案，被「上一笔」覆盖没有意义。
  /// 转账段不出现：`TransferForm` 是另一套状态机，没有分类 / 自定义字段语义。
  bool get _canCopyLast =>
      widget.quickAdd &&
      widget.renderAsBottomSheet &&
      widget.editingTransactionId == null &&
      _selectedKind != 'transfer';

  /// 顶栏右上角的「带出上一笔」图标；无来源 / 不适用时返回 `null`。
  ///
  /// 只放图标（与左侧关闭键同款 IconButton，颜色走主题图标色，不再逐处取
  /// token），文案走 `tooltip` —— 顶栏槽位固定 48 宽，塞文字按钮会把居中标题挤偏。
  Widget? _buildCopyLastAction() {
    if (!_canCopyLast) return null;
    if (_copySourceByKind[_selectedKind] == null) return null;
    return IconButton(
      icon: const Icon(Icons.copy_all_outlined),
      tooltip: AppLocalizations.of(context).txCopyLastAction,
      onPressed: _copyLastEntry,
    );
  }

  /// 探测某类型是否有「上一笔」可带出（结果按 kind 缓存，只探一次）。
  ///
  /// 查询是「ledger_id 等值 + ORDER BY created_at DESC LIMIT 1」，命中
  /// `idx_transactions_ledger_created`，常数级。
  Future<void> _probeCopySource(String kind) async {
    if (widget.editingTransactionId != null) return;
    if (kind == 'transfer' || !_copySourceProbed.add(kind)) return;
    final ledgerId = ref.read(currentLedgerIdProvider);
    final row = await ref.read(repositoryProvider).getLastRecordedTransaction(
          ledgerId: ledgerId,
          kind: kind,
        );
    if (!mounted) return;
    setState(() => _copySourceByKind[kind] = row);
  }

  /// 点「带出上一笔」：组装载荷并落到当前形态的记账表单。
  ///
  /// - 快捷形态（金额表单已在屏上）：把载荷交给表单**就地装填**（不关不重建）；
  /// - 分类网格形态（还没有表单）：等同于「选中上一笔的分类并进入记账表单」；
  ///   上一笔没有可用分类时只暂存 + 提示，等用户点分类格时一并生效。
  Future<void> _copyLastEntry() async {
    final kind = _selectedKind;
    if (!_canCopyLast) return;
    final source = _copySourceByKind[kind];
    if (source == null) return;

    final draft = await _buildLastEntryDraft(source, kind);
    if (!mounted) return;
    HapticFeedback.lightImpact();

    if (_isQuickEntryMode) {
      setState(() {
        _lastEntryPrefill = draft;
        _lastEntryPrefillToken++;
        // 同步宿主持有的初值，避免下一次重建把**过时**的分类 / 账户再传下去
        // （表单侧已置 _categoryPicked / _accountPicked，不会吃回去，但状态要自洽）。
        _quickCategoryByKind[kind] = draft.category;
        _quickAccountByKind[kind] = draft.accountId;
      });
      return;
    }

    _pendingGridPrefill = draft;
    final category = draft.category;
    if (category == null) {
      // 上一笔没有分类（历史数据 / 跨类型）：网格形态下没有「进哪张表单」的
      // 落点，只能等用户点分类格 —— 提示一句，别让用户以为按钮没反应。
      showToast(context, AppLocalizations.of(context).txCopyLastPickCategory);
      return;
    }
    await _onCategorySelected(context, category, kind);
  }

  /// 把来源交易组装成「带出上一笔」载荷（**除金额外的字段**）。
  ///
  /// 每项都过一遍「还能不能用」的校验，宁可少带也不带坏值：
  /// - 分类：已删除 / 类型不符 → 不带出（预填错分类比不预填糟得多）；
  /// - 账户：复用 [_validatedAccountId]（删除 / 隐藏 / 币种不符 → 不带出）；
  /// - 标签：走 join 查询，已删除的标签天然不返回，避免悬空 id 在保存时炸外键；
  /// - 自定义字段：直接读交易行上的值（不依赖定义表是否已同步），定义缺了值也还在；
  ///   **金额类型的自定义字段整个剔除** —— 与「记账金额不带出」同一口径，
  ///   复刻上一笔时金额类的值一律要用户重填；
  /// - 备注敏感标记：设备本地标记，同文案沿用同一隐私处理（方向是安全侧）。
  ///
  /// **刻意不带出**：金额 / 原始金额 / 折算金额 / 汇率 / 发生日期（保持今天）/
  /// 附件（复制文件超出本需求范围）。
  Future<LastEntryDraft> _buildLastEntryDraft(
    Transaction source,
    String kind,
  ) async {
    final ledgerId = ref.read(currentLedgerIdProvider);
    final repo = ref.read(repositoryProvider);

    Category? category;
    final categoryId = source.categoryId;
    if (categoryId != null) {
      final c = await _resolveCategoryById(categoryId);
      if (c != null && c.kind == kind) category = c;
    }

    final sourceAccountId = source.accountId;
    final accountId = sourceAccountId == null
        ? null
        : await _validatedAccountId(sourceAccountId, ledgerId);

    final tags = await repo.getTagsForTransaction(source.id);
    final storedCustomValues = await repo.getValuesForTransaction(source.id);

    // 金额类型的自定义字段（v47 那套「和记账金额一样用自制键盘输入」的字段）
    // 一律不带出：定义表里 fieldType == amount 的 syncId 集合，把对应键整体剔除。
    // 用定义表（而非值的形态）判断类型：文本字段也可能存的是数字字符串，
    // 靠形态猜会误剔。decode 对空值返回 `const {}`（不可变），故这里新建 map
    // 而不是原地 removeWhere。
    final amountSyncIds = {
      for (final def in await repo.getDefinitionsForLedger(ledgerId))
        if (def.fieldType == CustomFieldType.amount &&
            (def.syncId ?? '').isNotEmpty)
          def.syncId!,
    };
    final customValues = amountSyncIds.isEmpty
        ? storedCustomValues
        : {
            for (final e in storedCustomValues.entries)
              if (!amountSyncIds.contains(e.key)) e.key: e.value,
          };

    final sensitiveIds = await ref.read(sensitiveNoteServiceProvider).load();

    return LastEntryDraft(
      kind: kind,
      category: category,
      accountId: accountId,
      note: source.note,
      noteSensitive: sensitiveIds.contains(source.id),
      tagIds: [for (final t in tags) t.id],
      excludeFromStats: source.excludeFromStats,
      excludeFromBudget: source.excludeFromBudget,
      currencyCode: source.currencyCode,
      customValues: customValues,
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
    // 「带出上一笔」：分类网格形态还没有表单，按钮放在标题栏右上角动作位
    // （`ExpandableBottomSheet.actions` → `PiggyTitleBar.actions`）。
    final copyLastAction = _buildCopyLastAction();
    return ExpandableBottomSheet(
      title: isEditing ? l10n.commonEdit : l10n.widgetQuickAddLabel,
      onClose: () => Navigator.of(context).pop(),
      initialChildSize: 0.7,
      minChildSize: 0.35,
      maxChildSize: 1.0,
      backgroundColor: sheetBg,
      actions: copyLastAction == null ? null : [copyLastAction],
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
  ///
  /// 外壳与顶栏都走项目统一口径：`PiggySheetCard`（transparent 弹层底 + 左右 /
  /// 底部 `p16` 留距 + `Material(surfaceElevated/radiusXl)`）+ `PiggySheetHeader`
  /// （X 左 / 标题居中 / 右补占位）—— 新建「记一笔」与编辑「编辑」共用这一形态，
  /// 只有标题文案不同。
  Widget _buildQuickEntrySheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final isEditing = widget.editingTransactionId != null;
    final isTransfer = _selectedKind == 'transfer';
    return PiggySheetCard(
      child: Column(
        // 供 widget 测试量高度（支出 / 收入 / 转账三段必须恒定同高）。
        key: const ValueKey('quickEntrySheet'),
        mainAxisSize: MainAxisSize.min,
        children: [
          PiggySheetHeader(
            title: isEditing ? l10n.commonEdit : l10n.widgetQuickAddLabel,
            // 「带出上一笔」：右上角只放图标，无来源 / 转账段 / 编辑态为 null
            // （标题仍严格居中 —— 槽位固定 48 宽）。
            trailingAction: _buildCopyLastAction(),
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
            // 支出 / 收入：保持自然高度（不留白），并顺手把高度报上去
            // 供转账对齐。只在非转账分支测量，所以切到转账后这个值就冻结了。
            //
            // 滚动职责已下沉给表单本身（`pinKeypad: true`）：上半属性区自己滚、
            // 数字键盘钉在卡片底部。这里**不再**套 SingleChildScrollView ——
            // 那样键盘会跟着一起滚，屏幕一矮数字键就漂、「完成」键滚出可视区。
            Flexible(
              child: _BodyHeightReporter(
                onMeasured: _onQuickBodyMeasured,
                child: IndexedStack(
                  index: _selectedKind == 'income' ? 1 : 0,
                  children: [
                    _buildQuickAmountSheet(context, 'expense'),
                    _buildQuickAmountSheet(context, 'income'),
                  ],
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
      // 抽屉形态：数字键盘钉在卡片底部，只有上半属性区滚动（2026-10-09）。
      pinKeypad: true,
      // 支出 / 收入两份表单在 IndexedStack 里同时保活，硬件键盘输入只放行
      // 当前分段这份 —— 否则一次击键会同时输进两份表单（2026-10-15）。
      hardwareKeysEnabled: _selectedKind == kind,
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
      initialNoteSensitive: _editingNoteSensitive,
      showAccountPicker: true,
      ledgerId: ledgerId,
      editingTransactionId: widget.editingTransactionId,
      transactionKind: kind,
      // 新建必须选分类（分类位可能只是「选择分类」占位 —— 5 分钟继承未命中时）；
      // 编辑存量交易不强制 —— 历史数据可能本来就没有分类，不能逼用户补一个才能保存。
      requireCategory: widget.editingTransactionId == null,
      initialExcludeFromStats: widget.initialExcludeFromStats,
      initialExcludeFromBudget: widget.initialExcludeFromBudget,
      // v56 退款关联 + 报销状态（F1-b）回显
      initialRefundOfId: widget.initialRefundOfId,
      initialRefundTarget: widget.initialRefundTarget,
      initialReimburseStatus: widget.initialReimburseStatus,
      initialCurrencyCode: widget.initialCurrencyCode,
      initialNativeAmount: widget.initialNativeAmount,
      initialOriginalAmount: widget.initialOriginalAmount,
      initialCustomValues: widget.initialCustomValues,
      // 「带出上一笔」：载荷 + 版本号驱动 didUpdateWidget 就地装填。载荷自带
      // kind，表单只在与自己的 transactionKind 一致时应用（支出 / 收入两份表单
      // 在 IndexedStack 里同时保活，同一份载荷会同时到达两者）。
      prefill: _lastEntryPrefill,
      prefillToken: _lastEntryPrefillToken,
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
      // 根据类型获取默认账户ID
      final defaultAccountId = kind == 'income'
          ? await ref.read(defaultIncomeAccountIdProvider.future)
          : await ref.read(defaultExpenseAccountIdProvider.future);

      if (defaultAccountId == null) return null;

      return await _validatedAccountId(defaultAccountId, ledgerId);
    } catch (e) {
      return null;
    }
  }

  /// 校验某个账户能否作为本次记账的预填账户；不能则返回 `null`。
  ///
  /// 三态都按「不能用」处理：账户已删除、已隐藏（#240 E3：正常路径下隐藏时已
  /// 清 pref，这里兜同步竞态等边缘情况）、币种与账本本位币不符。
  ///
  /// 默认账户与 **5 分钟继承到的账户** 共用这一口径 —— 预填一个错账户
  /// （尤其是跨币种）比不预填糟得多。
  Future<int?> _validatedAccountId(int accountId, int ledgerId) async {
    try {
      final ledger = await ref.read(ledgerByIdProvider(ledgerId).future);
      if (ledger == null) return null;

      final account = await ref.read(accountByIdProvider(accountId).future);
      if (account == null || account.hidden) return null;

      if (account.currency != ledger.currency) return null;

      return accountId;
    } catch (e) {
      return null;
    }
  }

  /// 按 id 取分类(本地分类表)。
  Future<Category?> _resolveCategoryById(int categoryId) {
    return ref.read(repositoryProvider).getCategoryById(categoryId);
  }

  Future<void> _onCategorySelected(
      BuildContext context, Category c, String kind) async {
    if (!widget.quickAdd) {
      Navigator.pop(context, c);
      return;
    }
    final ledgerId = ref.read(currentLedgerIdProvider);

    // 「带出上一笔」（网格形态）：载荷在按钮按下时暂存，用户点分类格的这一下把
    // 它一并带进金额表单 —— 分类以**用户点的这一格**为准（载荷里的分类只是
    // 「自动替你点一下」的入口），其余字段由载荷决定（含「源确实没填」= 留空）。
    // 立即取出并清空：本次消费掉，不影响用户取消后重选分类。
    final prefill = _pendingGridPrefill;
    _pendingGridPrefill = null;

    // 确定初始账户ID（与 [_resolveQuickInitials] 同一条优先链）：
    // 显式传入 > 带出的账户 > 已解析的初值（5 分钟继承 > 默认账户）> 现查默认账户。
    // 已解析初值走 [_quickAccountByKind]:网格路径命中窗口时用户改点别的分类，
    // 账户仍应继承上一笔（账户默认与分类选择互不绑定）。
    int? initialAccountId = widget.initialAccountId ?? prefill?.accountId;
    if (widget.editingTransactionId == null && initialAccountId == null) {
      initialAccountId = _quickAccountByKind[kind];
      initialAccountId ??= await _getDefaultAccountId(kind, ledgerId);
    }

    // await 后检查 mounted，避免页面已卸载仍使用 context 弹出底部表单
    // context 为方法参数,需与 State.mounted 一并校验
    if (!mounted || !context.mounted) return;

    // 外壳走项目「悬浮卡片」口径（[PiggySheetCard]：transparent 弹层底 + 左右
    // 留距 + Material(surfaceElevated/radiusXl)），不再用旧的全宽平底弹层
    // （surfaceSheet + BorderRadius.vertical(top:)）—— 见 AGENTS.md 抽屉约定。
    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => PiggySheetCard(
        child: AmountEditorSheet(
          // 网格路径同样把滚动职责下沉给表单（v56：收入表单多了退款关联行，
          // 非钉底形态在矮屏 + 自定义字段的场景会硬溢出；钉底形态属性区自滚、
          // 键盘固定，内容放得下时布局与从前逐字一致）。
          pinKeypad: true,
          categoryName: c.name,
          categoryId: c.id,
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
          // 「带出上一笔」激活时**整体接管**这几个非金额字段：载荷里为空就是
          // 「不带出 / 源确实没填」，不再回落到 widget.initialXxx（金额与
          // 发生日期不在此列 —— 那两个刻意不带出）。
          initialNote: prefill != null ? prefill.note : widget.initialNote,
          initialAccountId: initialAccountId,
          initialTagIds: prefill != null ? prefill.tagIds : widget.initialTagIds,
          initialNoteSensitive: prefill != null
              ? prefill.noteSensitive
              : _editingNoteSensitive,
          showAccountPicker: true,
          ledgerId: ledgerId,
          editingTransactionId: widget.editingTransactionId,
          transactionKind: kind,
          initialExcludeFromStats: prefill != null
              ? prefill.excludeFromStats
              : widget.initialExcludeFromStats,
          initialExcludeFromBudget: prefill != null
              ? prefill.excludeFromBudget
              : widget.initialExcludeFromBudget,
          // v56 退款关联 + 报销状态（F1-b）回显。「带出上一笔」刻意不带出
          // 这两项（退款关联是特定语义，报销状态不应随复制流传）。
          initialRefundOfId: widget.initialRefundOfId,
          initialRefundTarget: widget.initialRefundTarget,
          initialReimburseStatus: widget.initialReimburseStatus,
          initialCurrencyCode: prefill != null
              ? prefill.currencyCode
              : widget.initialCurrencyCode,
          initialNativeAmount: widget.initialNativeAmount,
          initialOriginalAmount: widget.initialOriginalAmount,
          initialCustomValues: prefill != null
              ? prefill.customValues
              : widget.initialCustomValues,
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
      ),
    );
  }

  /// 把金额表单的提交结果写库（附件 / 标签 / 同步触发 / 缓存刷新）。
  ///
  /// 两条路径共用：「分类网格」旧流程（金额表单盖在网格上）与「金额表单优先」
  /// 新流程（分类是表单的子界面）的**写库语义必须逐字一致**，差别只在关几层
  /// modal —— 那由各自的 onSubmit 调用方处理。
  ///
  /// 分类取 [AmountEditorResult.category]：新流程允许用户在表单内换分类，
  /// 闭包捕获的「进入表单时的分类」可能已经过时，不能再作为写入依据。
  /// 编辑态回显：该笔是否已标记为敏感备注（设备本地标记）。
  bool get _editingNoteSensitive {
    final id = widget.editingTransactionId;
    if (id == null) return false;
    return ref.read(sensitiveNoteIdsProvider).value?.contains(id) ?? false;
  }

  Future<void> _persistTransaction(
    BuildContext context,
    String kind,
    AmountEditorResult res,
  ) async {
    final ledgerId = ref.read(currentLedgerIdProvider);
    final repo = ref.read(repositoryProvider);
    final attachmentService = ref.read(attachmentServiceProvider);
    int transactionId;
    final categoryIdForWrite = res.category?.id;
    // picker 返 null 时账户 id 写 null。
    // addTransaction 的 accountId 是 int?(直接传 null 即写 null);
    // updateTransaction 的 accountId 是 dynamic,dart null 被解释成
    // Value.absent(=不更新该字段) → 用户选"不选择账户"无效;必须显式
    // 传 d.Value<int?>(null) 才会真清空旧 accountId。
    final accountIdForAdd = res.accountId;
    final accountIdForUpdate = d.Value<int?>(accountIdForAdd);
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
        // v56 退款关联（F1-b）：三态直写（dart null = 不改动 /
        // Value(null) = 用户在表单里解除了关联 / Value(id) = 写入）。
        // 表单对收入交易恒回传当前值，编辑支出/转账时是 null = 不动。
        refundOfId: d.Value<int?>(res.refundOfId),
        // v56 报销状态（F1-b）：表单恒回传三态之一。
        reimburseStatus: res.reimburseStatus,
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
        excludeFromStats: res.excludeFromStats,
        excludeFromBudget: res.excludeFromBudget,
        currencyCode: res.currencyCode,
        nativeAmount: res.nativeAmount,
        originalAmount: res.originalAmount,
        customValues: res.customValues,
        // v56 退款关联 + 报销状态（F1-b）
        refundOfId: res.refundOfId,
        reimburseStatus: res.reimburseStatus,
      );
    }
    // 备注敏感标记（设备本地，不参与同步）：随本次表单结果落盘
    await ref
        .read(sensitiveNoteServiceProvider)
        .setSensitive(transactionId, res.noteSensitive);
    ref.read(sensitiveNoteRefreshProvider.notifier).state++;

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
    if (res.tagIds.isNotEmpty) {
      await repo.updateTransactionTags(
        transactionId: transactionId,
        tagIds: res.tagIds,
      );
      ref.read(tagListRefreshProvider.notifier).state++;
    } else if (widget.editingTransactionId != null) {
      // 编辑模式没 tag → 清掉旧关联
      await repo.removeAllTagsFromTransaction(transactionId);
      ref.read(tagListRefreshProvider.notifier).state++;
    }

    // 统一处理：自动/手动同步与状态刷新（后台静默）
    PostProcessor.sync(ref, ledgerId: ledgerId);
    // 刷新：账本笔数与全局统计
    ref.invalidate(countsForLedgerProvider(ledgerId));
    ref.read(statsRefreshProvider.notifier).state++;
    // 刷新：预算数据
    ref.read(budgetRefreshProvider.notifier).state++;
    // 注：这里曾是快捷记账「记忆分类」Provider 的失效锚点；该 Provider 已被
    // 「5 分钟内继承上一笔」取代（窗口随墙钟滑动，不能缓存 —— 记账页每次打开
    // 现查一次仓储），故此处不再承担那层语义。
    // 更新小组件数据（后台执行，不阻塞UI）
    if (context.mounted) {
      updateAppWidget(ref, context);
    }
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
