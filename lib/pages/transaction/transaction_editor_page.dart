import 'package:drift/drift.dart' as d;
import 'package:flutter/material.dart';
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
    // 缓存未就绪或记忆未命中 → 不预填、不报错，直接落回分类网格 ——
    //「预填错分类的危害大于不预填」，也刻意不做「先出网格再跳表单」的闪跳
    // （design.md 决策 5 与第四节风险表）。
    if (widget.quickAdd &&
        widget.initialKind != 'transfer' &&
        (widget.initialCategoryId != null || widget.quickMode)) {
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
    // 注意：转账编辑模式不需要在这里做任何操作，让 TransferForm 自己处理
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
          onCategorySelected: (c) =>
              _onCategorySelected(context, c, 'expense'),
          initialCategoryId: widget.initialCategoryId,
          scrollController: scrollController,
        );
      case 'income':
        return CategorySelector(
          kind: 'income',
          onCategorySelected: (c) =>
              _onCategorySelected(context, c, 'income'),
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

  /// 底部抽屉模式渲染：复用分类选择器与转账表单，分段选择器放进标题栏 bottom 槽。
  Widget _buildBottomSheet(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    // 分段选择器：放标题栏 bottom 槽，宽度铺满（无取消按钮，关闭走左上角 ×）
    final segmentControl = Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: WaitSlidingSegmentedControl<String>(
        selected: _selectedKind,
        segments: [
          WaitSlidingSegment(
            value: 'expense',
            label: l10n.categoryExpense,
          ),
          WaitSlidingSegment(
            value: 'income',
            label: l10n.categoryIncome,
          ),
          WaitSlidingSegment(
            value: 'transfer',
            label: l10n.transferTitle,
          ),
        ],
        onValueChanged: (value) => setState(() {
          _selectedKind = value;
          _activatedKinds.add(value);
        }),
      ),
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
        // 换分类（决策 5）：本表单只在 quickAdd 下被打开（此刻分类网格仍在
        // 下层），所以点分类位总是可换 —— 把当前已输金额存起来并关掉表单，
        // 回到网格重选，用户再点分类时由 _lastAmount 回填。
        onPickCategory: (amount) {
          _lastAmount = amount;
          Navigator.of(ctx).pop();
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
        onSubmit: (res) async {
          final repo = ref.read(repositoryProvider);
          final attachmentService = ref.read(attachmentServiceProvider);
          int transactionId;
          // §7 v25:Category 是来自 SharedLedger* 的 synthetic (id<0)时,
          // categoryId 留 null,override 走 syncId。同理对 account/toAccount。
          // res.accountId 可能也是 synthetic(Account picker 用同一规则)。
          final isSyntheticCategory = c.id < 0;
          final isSyntheticAccount =
              res.accountId != null && res.accountId! < 0;
          final categoryIdForWrite = isSyntheticCategory ? null : c.id;
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
                      await repo.db
                          .into(repo.db.transactionTagOverrides)
                          .insert(
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
          // 先关闭页面，再播放反馈
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
