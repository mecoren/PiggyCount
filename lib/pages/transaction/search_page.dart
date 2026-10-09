import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/biz/search_filter_sheet.dart';
import '../../widgets/ui/ui.dart';
import '../../styles/tokens.dart';
import '../../utils/category_utils.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../utils/transaction_search_filter.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/category_icon.dart';
import 'category_detail_page.dart';

/// 搜索页面
class SearchPage extends ConsumerStatefulWidget {
  const SearchPage({super.key});

  @override
  ConsumerState<SearchPage> createState() => _SearchPageState();
}

class _SearchPageState extends ConsumerState<SearchPage> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _noteController = TextEditingController();

  List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })> _searchResults = [];
  List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })> _allTransactions = [];
  // stream 缓存：复用同一 stream 引用，避免无关 rebuild（搜索、筛选）导致
  // StreamBuilder 重新订阅 → snapshot 短暂 null → _allTransactions 被清空。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>>? _txStream;
  int? _txStreamLedgerId;
  bool _isSearching = false;
  String _searchText = '';

  // 筛选条件
  double? _minAmount;
  double? _maxAmount;
  DateTime? _startDate;
  DateTime? _endDate;
  Category? _selectedCategory;
  // 多维筛选（账户 / 标签 / 附件 / 币种）：标签与附件不在交易行上，需要按需
  // 查关联表（见 _ensureFilterRelations），其余两类直接读交易行字段。
  Account? _selectedAccount;
  final Set<int> _selectedTagIds = {};
  bool? _hasAttachmentFilter;
  String? _selectedCurrency;
  Map<int, Set<int>> _txTagIds = const {};
  Set<int> _txWithAttachment = const {};
  bool _relationsLoaded = false;
  // 交易数据代际：StreamBuilder 每次拿到新快照才重新过滤，避免「结果为空 →
  // 每帧重新调度搜索」的循环。
  int _allTxGeneration = 0;
  int _searchedGeneration = -1;
  Timer? _searchDebounce; // 搜索防抖：输入停顿后才执行全量过滤

  // 缓存汇总金额，避免每次 build() 重复计算
  double _totalExpense = 0.0;
  double _totalIncome = 0.0;

  // 批量操作相关
  bool _isBatchMode = false;
  final Set<int> _selectedIds = {};

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    _noteController.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    // 防抖：连续按键时只在停顿后执行一次全量过滤 + setState，
    // 避免每个字符都 O(n) 遍历 + 整页重建导致输入卡顿。
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 200), () {
      if (mounted) _performSearch();
    });
  }

  /// 当前筛选条件（各维度零散字段 → 单一条件对象，判定逻辑在
  /// [TransactionSearchFilter.matches]）。
  TransactionSearchFilter get _currentFilter => TransactionSearchFilter(
        keyword: _searchText,
        categoryId: _selectedCategory?.id,
        minAmount: _minAmount,
        maxAmount: _maxAmount,
        startDate: _startDate,
        endDate: _endDate,
        accountId: _selectedAccount?.id,
        tagIds: _selectedTagIds,
        hasAttachment: _hasAttachmentFilter,
        currencyCode: _selectedCurrency,
      );

  bool get _hasAnyFilter => _currentFilter.isNotEmpty;

  /// 执行搜索
  void _performSearch() {
    // 防抖期间 _searchText 可能滞后，这里从 controller 同步最新输入。
    _searchText = _searchController.text.trim();

    // 如果没有任何搜索条件，清空结果
    if (!_hasAnyFilter) {
      setState(() {
        _searchResults = [];
        _totalExpense = 0.0;
        _totalIncome = 0.0;
        _isSearching = false;
      });
      return;
    }

    // 500~3000 条数据的内存过滤为同步操作（<10ms），无需转圈（转圈在同一帧
    // 内也不会渲染），直接过滤后一次 setState。
    final filter = _currentFilter;
    // 交易未显式记币种时按账本本位币参与币种匹配。
    final ledgerCurrency =
        ref.read(currentLedgerProvider).value?.currency ?? '';
    final results = _allTransactions.where((item) {
      return filter.matches(
        t: item.t,
        category: item.category,
        categoryDisplayName:
            CategoryUtils.getDisplayName(item.category?.name, context),
        transactionTagIds: _txTagIds[item.t.id] ?? const <int>{},
        hasTransactionAttachment: _txWithAttachment.contains(item.t.id),
        ledgerCurrency: ledgerCurrency,
      );
    }).toList();

    setState(() {
      _searchResults = results;
      _totalExpense = results
          .where((e) => e.t.type == 'expense')
          .fold(0.0, (sum, e) => sum + (e.t.nativeAmount ?? e.t.amount).abs());
      _totalIncome = results
          .where((e) => e.t.type == 'income')
          .fold(0.0, (sum, e) => sum + (e.t.nativeAmount ?? e.t.amount).abs());
      _isSearching = false;
    });
  }

  /// 交易数据换代（全量替换 / 从库重拉）时作废标签、附件筛选的关联缓存。
  void _invalidateFilterRelations() {
    _relationsLoaded = false;
    _txTagIds = const {};
    _txWithAttachment = const {};
  }

  /// 按需加载标签 / 附件筛选所需的关联数据（未启用这两个维度时不查库）。
  Future<void> _ensureFilterRelations() async {
    if (_relationsLoaded) return;
    if (_selectedTagIds.isEmpty && _hasAttachmentFilter == null) {
      _relationsLoaded = true;
      return;
    }
    final ids = [for (final e in _allTransactions) e.t.id];
    if (ids.isEmpty) {
      _relationsLoaded = true;
      return;
    }

    final repo = ref.read(repositoryProvider);
    var tagIds = const <int, Set<int>>{};
    var withAttachment = const <int>{};
    try {
      if (_selectedTagIds.isNotEmpty) {
        final map = await repo.getTagsForTransactions(ids);
        tagIds = {
          for (final e in map.entries)
            e.key: {for (final tag in e.value) tag.id},
        };
      }
      if (_hasAttachmentFilter != null) {
        final counts = await repo.getAttachmentCountsForTransactions(ids);
        withAttachment = {
          for (final e in counts.entries)
            if (e.value > 0) e.key,
        };
      }
    } catch (_) {
      // 关联数据读失败按「无标签 / 无附件」处理，不阻断搜索主流程。
    }

    if (!mounted) return;
    _txTagIds = tagIds;
    _txWithAttachment = withAttachment;
    _relationsLoaded = true;
  }

  /// 筛选条件变化后的统一入口：作废关联缓存 → 按需重载 → 重新过滤。
  Future<void> _refreshSearch() async {
    _invalidateFilterRelations();
    await _ensureFilterRelations();
    if (!mounted) return;
    _performSearch();
  }

  /// 从数据库重新加载并执行搜索
  Future<void> _performSearchFromDb() async {
    if (!mounted) return;

    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);

    setState(() {
      _isSearching = true;
    });

    // 从数据库重新获取所有交易
    final allTransactions =
        await repo.transactionsWithCategoryAll(ledgerId: ledgerId).first;

    if (!mounted) return;

    // 更新_allTransactions
    _allTransactions = allTransactions;
    _allTxGeneration++;
    _searchedGeneration = _allTxGeneration;
    _invalidateFilterRelations();

    // 执行搜索筛选
    await _ensureFilterRelations();
    if (!mounted) return;
    _performSearch();
  }

  /// 切换批量操作模式
  void _toggleBatchMode() {
    setState(() {
      _isBatchMode = !_isBatchMode;
      if (!_isBatchMode) {
        _selectedIds.clear();
      }
    });
  }

  /// 切换选择
  void _toggleSelection(int id) {
    setState(() {
      if (_selectedIds.contains(id)) {
        _selectedIds.remove(id);
      } else {
        _selectedIds.add(id);
      }
    });
  }

  /// 全选/取消全选
  void _toggleSelectAll() {
    setState(() {
      if (_selectedIds.length == _searchResults.length) {
        _selectedIds.clear();
      } else {
        _selectedIds.clear();
        _selectedIds.addAll(_searchResults.map((e) => e.t.id));
      }
    });
  }

  /// 显示筛选抽屉：把当前各维度取值交给 [showSearchFilterSheet]，确认后
  /// 整包回写并重新搜索（取消 / 下滑关闭保持原条件）。
  Future<void> _showFilterSheet() async {
    final result = await showSearchFilterSheet(
      context,
      initial: SearchFilterValues(
        minAmount: _minAmount,
        maxAmount: _maxAmount,
        startDate: _startDate,
        endDate: _endDate,
        category: _selectedCategory,
        account: _selectedAccount,
        tagIds: _selectedTagIds,
        hasAttachment: _hasAttachmentFilter,
        currency: _selectedCurrency,
      ),
    );
    if (result == null || !mounted) return;

    setState(() {
      _minAmount = result.minAmount;
      _maxAmount = result.maxAmount;
      _startDate = result.startDate;
      _endDate = result.endDate;
      _selectedCategory = result.category;
      _selectedAccount = result.account;
      _selectedTagIds
        ..clear()
        ..addAll(result.tagIds);
      _hasAttachmentFilter = result.hasAttachment;
      _selectedCurrency = result.currency;
    });
    unawaited(_refreshSearch());
  }

  /// 批量操作完成后刷新
  Future<void> _refreshAfterBatchOperation(int count, String operation) async {
    if (mounted) {
      showToast(context, operation);
      setState(() {
        _selectedIds.clear();
        _isBatchMode = false;
      });
      // 从数据库重新加载最新数据并执行搜索
      await _performSearchFromDb();
    }
  }

  /// 批量删除：双重危险确认（各 5 秒倒计时）后才执行
  Future<void> _showBatchDeleteDialog() async {
    final count = _selectedIds.length;
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.searchBatchDeleteConfirmTitle,
      firstMessage: l10n.searchBatchDeleteConfirmMessage(count),
      secondMessage: l10n.searchBatchDeleteReconfirmMessage,
    );
    if (!confirmed || !mounted) return;
    await _executeBatchDelete();
  }

  /// 执行批量删除
  Future<void> _executeBatchDelete() async {
    final count = _selectedIds.length;
    final l10n = AppLocalizations.of(context);

    try {
      final repo = ref.read(repositoryProvider);
      // 批量删除交易（F1 回收站：软删除，可在回收站找回）。
      // P6：单事务批量，替代逐条 softDeleteTransaction（N 次事务提交）。
      await repo.softDeleteTransactions(_selectedIds.toList());
      ref.read(budgetRefreshProvider.notifier).state++;
      await _refreshAfterBatchOperation(
          count, l10n.searchBatchDeleteSuccess(count));
    } catch (e) {
      if (mounted) {
        showToast(context, l10n.searchBatchDeleteFailed(e.toString()));
      }
    }
  }

  /// 批量设置备注对话框
  void _showBatchSetNoteDialog() {
    _noteController.clear();
    final count = _selectedIds.length;
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AppDialogShell(
        wide: true,
        title: Text(l10n.searchBatchSetNoteTitle),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.searchBatchSetNoteMessage(count)),
            const SizedBox(height: 16),
            TextField(
              controller: _noteController,
              decoration: piggyOutlinedDecoration(
                context,
                hint: l10n.searchBatchSetNoteHint,
              ),
              maxLines: 3,
              autofocus: true,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonCancel),
          ),
          TextButton(
            onPressed: () async {
              final note = _noteController.text.trim();
              Navigator.pop(context);
              await _executeBatchSetNote(note);
            },
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  /// 执行批量设置备注
  Future<void> _executeBatchSetNote(String note) async {
    final repo = ref.read(repositoryProvider);
    final count = _selectedIds.length;
    final l10n = AppLocalizations.of(context);

    try {
      // P6：单事务批量更新备注（null = 清空），替代逐条 get+update
      // （每条双份 SELECT + 独立事务，同步记 change 契约由批量方法保持）。
      await repo.updateTransactionsBatchNote(
        ids: _selectedIds.toList(),
        note: note.isEmpty ? null : note,
      );
      await _refreshAfterBatchOperation(
          count, l10n.searchBatchSetNoteSuccess(count));
    } catch (e) {
      if (mounted) {
        showToast(context, l10n.searchBatchSetNoteFailed(e.toString()));
      }
    }
  }

  /// 批量调整分类对话框
  Future<void> _showBatchChangeCategoryDialog() async {
    final l10n = AppLocalizations.of(context);

    // 检查选中的交易类型是否一致
    final selectedTransactions = _searchResults
        .where((item) => _selectedIds.contains(item.t.id))
        .toList();

    // 获取所有选中交易的类型
    final types = selectedTransactions.map((item) => item.t.type).toSet();

    // 如果包含转账类型或类型不一致，则不允许修改分类
    if (types.contains('transfer')) {
      showToast(context, l10n.searchBatchCategoryTransferError);
      return;
    }

    if (types.length > 1) {
      showToast(context, l10n.searchBatchCategoryTypeError);
      return;
    }

    // 获取统一的交易类型
    final transactionType = types.first;

    // 显示分类选择器
    final selectedCategory = await showCategorySelector(
      context,
      type: transactionType,
      includeParentCategories: false, // 不包含有子分类的父分类
      showTransactionCount: true, // 显示笔数
      ledgerId: ref.read(currentLedgerIdProvider),
    );

    if (selectedCategory != null) {
      await _executeBatchChangeCategory(selectedCategory.id);
    }
  }

  /// 执行批量调整分类
  Future<void> _executeBatchChangeCategory(int categoryId) async {
    final repo = ref.read(repositoryProvider);
    final count = _selectedIds.length;
    final l10n = AppLocalizations.of(context);

    try {
      // P6：单事务批量调整分类，替代逐条 get+update（契约同批量备注）。
      await repo.updateTransactionsBatchCategory(
        ids: _selectedIds.toList(),
        categoryId: categoryId,
      );
      await _refreshAfterBatchOperation(
          count, l10n.searchBatchChangeCategorySuccess(count));
    } catch (e) {
      if (mounted) {
        showToast(context, l10n.searchBatchChangeCategoryFailed(e.toString()));
      }
    }
  }

  /// 已选筛选条件 chip（主色描边 + 浅底 + 删除叉），各维度统一样式。
  Widget _buildFilterChip({
    required String label,
    required Color primaryColor,
    required VoidCallback onDeleted,
  }) {
    return Chip(
      label: Text(
        label,
        style: TextStyle(
          fontSize: PiggyTextTokens.fs12,
          color: primaryColor,
        ),
      ),
      backgroundColor: primaryColor.withValues(alpha: 0.1),
      side: BorderSide(color: primaryColor, width: 1),
      deleteIconColor: primaryColor,
      deleteIcon: const Icon(Icons.close, size: 16),
      onDeleted: onDeleted,
    );
  }

  /// 构建收入/支出汇总标签
  Widget _buildSummaryChip({
    required String label,
    required double amount,
    required Color color,
  }) {
    final style = TextStyle(
        fontSize: PiggyTextTokens.fs12.scaled(context, ref), color: color);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        // label 固定展示，金额部分由 AmountText 处理隐藏/单位/币种
        Text('$label ', style: style),
        Flexible(
          child: AmountText(
            value: amount,
            signed: false,
            showCurrency: true,
            useCompactFormat: true,
            style: style,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = ref.watch(repositoryProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final hide = ref.watch(hideAmountsProvider);
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: _isBatchMode
            ? l10n.searchBatchModeWithCount(
                _selectedIds.length, _searchResults.length)
            : l10n.searchTitle,
        showBack: !_isBatchMode,
        actions: _isBatchMode && _searchResults.isNotEmpty
            ? [
                TextButton(
                  onPressed: _toggleSelectAll,
                  child: Text(
                    _selectedIds.length == _searchResults.length
                        ? l10n.searchDeselectAll
                        : l10n.searchSelectAll,
                    style: TextStyle(color: ref.watch(primaryColorProvider)),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: _toggleBatchMode,
                  tooltip: l10n.searchExitBatchMode,
                ),
              ]
            : null,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            // 搜索框区域
            if (!_isBatchMode) // 批量模式下隐藏搜索框
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
                // 不铺白底也不投影：顶部搜索区与标题栏同色（页面派生的主题淡色），
                // 整页只剩「一种背景色 + 浮在其中的描边搜索框」，不再出现
                // 标题栏淡色 / 搜索区白色 / 页面淡色三层色块。
                child: Column(
                  children: [
                    // 搜索框和筛选按钮
                    Row(
                      children: [
                        Expanded(
                          // 用 ValueListenableBuilder 监听 controller：输入时只局部
                          // 重建 TextField（刷新清除按钮），不再 setState 整页 rebuild。
                          child: ValueListenableBuilder<TextEditingValue>(
                            valueListenable: _searchController,
                            builder: (context, value, _) => TextField(
                              controller: _searchController,
                              // 顶部搜索框直接浮在页面底色上 → 走描边式
                              //（filled 底色与页面同色系会让边界消失）。
                              decoration: piggyOutlinedDecoration(
                                context,
                                hint: AppLocalizations.of(context).searchHint,
                                prefixIcon: Icon(Icons.search,
                                    color: PiggyTokens.iconTertiary(context)),
                                suffixIcon: value.text.isNotEmpty
                                    ? IconButton(
                                        onPressed: () {
                                          _searchController.clear();
                                        },
                                        tooltip: AppLocalizations.of(context)
                                            .tooltipClear,
                                        icon: Icon(Icons.clear,
                                            color: PiggyTokens.iconTertiary(
                                                context)),
                                      )
                                    : null,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        // 筛选按钮
                        IconButton(
                          onPressed: _showFilterSheet,
                          icon: Icon(
                            Icons.filter_list,
                            // 未筛选时用次级图标色（与搜索框内的图标同档），
                            // 不再用近乎纯黑的 iconPrimary；
                            // 有筛选条件时切主色，与页内主色元素一致。
                            color: _hasAnyFilter
                                ? ref.watch(primaryColorProvider)
                                : PiggyTokens.iconSecondary(context),
                          ),
                          tooltip: l10n.searchFilterTitle,
                        ),
                      ],
                    ),
                    // 显示已选筛选条件
                    if (_hasAnyFilter) ...[
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          if (_selectedCategory != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchCategoryFilter}: ${CategoryUtils.getDisplayName(_selectedCategory!.name, context)}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _selectedCategory = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_minAmount != null || _maxAmount != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchAmountFilter}: ${_minAmount?.toStringAsFixed(2) ?? '0'} ~ ${_maxAmount?.toStringAsFixed(2) ?? '∞'}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _minAmount = null;
                                  _maxAmount = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_startDate != null || _endDate != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchDateFilter}: ${_startDate != null ? '${_startDate!.year}-${_startDate!.month.toString().padLeft(2, '0')}-${_startDate!.day.toString().padLeft(2, '0')}' : l10n.searchDateStart} ~ ${_endDate != null ? '${_endDate!.year}-${_endDate!.month.toString().padLeft(2, '0')}-${_endDate!.day.toString().padLeft(2, '0')}' : l10n.searchDateEnd}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _startDate = null;
                                  _endDate = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_selectedAccount != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchAccountFilter}: ${_selectedAccount!.name}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _selectedAccount = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_selectedTagIds.isNotEmpty)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchTagFilter}: ${l10n.searchTagFilterSelected(_selectedTagIds.length)}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(_selectedTagIds.clear);
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_hasAttachmentFilter != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchAttachmentFilter}: ${_hasAttachmentFilter! ? l10n.searchAttachmentHas : l10n.searchAttachmentNone}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _hasAttachmentFilter = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                          if (_selectedCurrency != null)
                            _buildFilterChip(
                              label:
                                  '${l10n.searchCurrencyFilter}: ${_selectedCurrency!}',
                              primaryColor: primaryColor,
                              onDeleted: () {
                                setState(() {
                                  _selectedCurrency = null;
                                });
                                unawaited(_refreshSearch());
                              },
                            ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            // 搜索结果
            Expanded(
              child: StreamBuilder<
                  List<
                      ({
                        Transaction t,
                        Category? category,
                        Account? account,
                        Account? toAccount
                      })>>(
                stream: () {
                  // ledgerId 变化或首次才重建 stream；无关 rebuild 复用同一引用，
                  // 避免 StreamBuilder 重新订阅导致 _allTransactions 闪空。
                  if (_txStream == null || _txStreamLedgerId != ledgerId) {
                    _txStream =
                        repo.transactionsWithCategoryAll(ledgerId: ledgerId);
                    _txStreamLedgerId = ledgerId;
                  }
                  return _txStream;
                }(),
                builder: (context, snapshot) {
                  if (snapshot.hasData) {
                    // 仅在数据换代（首帧 / 库变更 emit 新 list）时重新过滤。
                    // 用 identical 而非「结果为空就再搜」：后者在零命中时会被
                    // 每帧重复调度。
                    if (!identical(snapshot.data, _allTransactions)) {
                      _allTransactions = snapshot.data!;
                      _allTxGeneration++;
                      _invalidateFilterRelations();
                    }
                    if (_hasAnyFilter &&
                        _allTxGeneration != _searchedGeneration) {
                      _searchedGeneration = _allTxGeneration;
                      WidgetsBinding.instance.addPostFrameCallback((_) {
                        if (mounted) {
                          unawaited(_refreshSearch());
                        }
                      });
                    }
                  }

                  if (_isSearching) {
                    return Center(
                        child: PiggySpinner(
                            size: 36, color: PiggyTokens.primary(context)));
                  }

                  if (!_hasAnyFilter) {
                    return AppEmpty(
                      text: AppLocalizations.of(context).searchNoInput,
                      icon: Icons.search,
                    );
                  }

                  if (_searchResults.isEmpty) {
                    return AppEmpty(
                      text: AppLocalizations.of(context).searchNoResults,
                      icon: Icons.search_off,
                    );
                  }

                  // 显示搜索结果列表
                  return Column(
                    children: [
                      // 批量操作入口 - 仅在非批量模式且有搜索结果时显示
                      if (!_isBatchMode)
                        Padding(
                          // 结果汇总条不铺白底：与列表同底色，页面只有一种背景色
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                          child: Row(
                            children: [
                              Text(
                                l10n.searchResultsCount(_searchResults.length),
                                style: Theme.of(context)
                                    .textTheme
                                    .bodyMedium
                                    ?.copyWith(
                                      color: PiggyTokens.textTertiary(context),
                                    ),
                              ),
                              SizedBox(width: 8.0.scaled(context, ref)),
                              // 支出/收入汇总：Expanded 占满剩余空间，内层 Flexible(loose) 让 chip 正常取自然宽度，超长时截断而非溢出
                              Expanded(
                                child: Row(
                                  children: [
                                    // 支出汇总
                                    Flexible(
                                      fit: FlexFit.loose,
                                      child: _buildSummaryChip(
                                        label: l10n.searchSummaryExpense,
                                        amount: _totalExpense,
                                        color: PiggyTokens.expenseColor(
                                            context, ref),
                                      ),
                                    ),
                                    SizedBox(width: 6.0.scaled(context, ref)),
                                    // 收入汇总
                                    Flexible(
                                      fit: FlexFit.loose,
                                      child: _buildSummaryChip(
                                        label: l10n.searchSummaryIncome,
                                        amount: _totalIncome,
                                        color: PiggyTokens.incomeColor(
                                            context, ref),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              TextButton(
                                onPressed: _toggleBatchMode,
                                style: TextButton.styleFrom(
                                  foregroundColor:
                                      PiggyTokens.textLink(context),
                                ),
                                child: Text(l10n.searchBatchMode),
                              ),
                            ],
                          ),
                        ),
                      // 批量模式下的操作栏
                      if (_isBatchMode)
                        Padding(
                          // 批量操作栏同样不铺白底（与列表/页面同底色）
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
                          child: Column(
                            children: [
                              // 全选按钮
                              Row(
                                children: [
                                  Text(
                                    l10n.searchSelectedCount(
                                        _selectedIds.length),
                                    style: Theme.of(context)
                                        .textTheme
                                        .bodyMedium
                                        ?.copyWith(
                                          color:
                                              PiggyTokens.textTertiary(context),
                                        ),
                                  ),
                                  const Spacer(),
                                  TextButton(
                                    onPressed: _toggleSelectAll,
                                    style: TextButton.styleFrom(
                                      foregroundColor:
                                          ref.watch(primaryColorProvider),
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 8, vertical: 4),
                                      minimumSize: const Size(0, 32),
                                    ),
                                    child: Text(
                                      _selectedIds.length ==
                                              _searchResults.length
                                          ? l10n.searchDeselectAll
                                          : l10n.searchSelectAll,
                                    ),
                                  ),
                                ],
                              ),
                              // 批量操作按钮 - 始终显示，未选择时禁用
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _selectedIds.isEmpty
                                          ? null
                                          : _showBatchSetNoteDialog,
                                      icon:
                                          const Icon(Icons.edit_note, size: 16),
                                      label: Text(l10n.searchBatchSetNote,
                                          style: const TextStyle(
                                              fontSize: PiggyTextTokens.fs13)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            ref.watch(primaryColorProvider),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6, horizontal: 8),
                                        minimumSize: const Size(0, 36),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _selectedIds.isEmpty
                                          ? null
                                          : _showBatchChangeCategoryDialog,
                                      icon:
                                          const Icon(Icons.category, size: 16),
                                      label: Text(
                                          l10n.searchBatchChangeCategory,
                                          style: const TextStyle(
                                              fontSize: PiggyTextTokens.fs13)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            ref.watch(primaryColorProvider),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6, horizontal: 8),
                                        minimumSize: const Size(0, 36),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: OutlinedButton.icon(
                                      onPressed: _selectedIds.isEmpty
                                          ? null
                                          : _showBatchDeleteDialog,
                                      icon: const Icon(Icons.delete_outline,
                                          size: 16),
                                      label: Text(l10n.commonDelete,
                                          style: const TextStyle(
                                              fontSize: PiggyTextTokens.fs13)),
                                      style: OutlinedButton.styleFrom(
                                        foregroundColor:
                                            PiggyTokens.error(context),
                                        padding: const EdgeInsets.symmetric(
                                            vertical: 6, horizontal: 8),
                                        minimumSize: const Size(0, 36),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      // 列表
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.fromLTRB(0, 8, 0, 0),
                          itemCount: _searchResults.length,
                          itemBuilder: (context, index) {
                            final item = _searchResults[index];
                            final isTransfer = item.t.type == 'transfer';
                            final isExpense = item.t.type == 'expense';

                            // 获取分类显示名称
                            final categoryName = CategoryUtils.getDisplayName(
                                item.category?.name, context);

                            final subtitle = item.t.note ?? '';
                            final isSelected = _selectedIds.contains(item.t.id);

                            final iconData = getCategoryIconData(
                                category: item.category,
                                categoryName: categoryName);

                            // v47：自定义字段角标（无值/定义解析不出 → 不显示）。
                            final customBadges = ref
                                    .watch(customFieldValueBadgesProvider)
                                    .value?[item.t.id] ??
                                const <({String name, String display})>[];
                            final customBadgeTexts = [
                              for (final b in customBadges)
                                '${b.name}: ${b.display}',
                            ];

                            return Column(
                              children: [
                                TransactionListItem(
                                  icon: iconData,
                                  category: item.category,
                                  title: subtitle,
                                  categoryName: categoryName,
                                  amount: item.t.amount,
                                  transactionId: item.t.id,
                                  currencyCode: item.t.currencyCode,
                                  nativeAmount: item.t.nativeAmount,
                                  customFieldBadges: customBadgeTexts.isNotEmpty
                                      ? customBadgeTexts
                                      : null,
                                  isExpense: isExpense,
                                  hide: hide,
                                  happenedAt: item.t.happenedAt,
                                  showFullDate: true,
                                  isSelectionMode: _isBatchMode,
                                  isSelected: isSelected,
                                  onSelectionChanged: () =>
                                      _toggleSelection(item.t.id),
                                  onTap: _isBatchMode
                                      ? null
                                      : () async {
                                          await TransactionEditUtils
                                              .editTransaction(
                                            context,
                                            ref,
                                            item.t,
                                            item.category,
                                          );
                                        },
                                  onCategoryTap: _isBatchMode ||
                                          isTransfer ||
                                          item.category?.id == null
                                      ? null
                                      : () {
                                          Navigator.of(context).push(
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  CategoryDetailPage(
                                                categoryId: item.category!.id,
                                                categoryName: categoryName,
                                              ),
                                            ),
                                          );
                                        },
                                ),
                                if (index < _searchResults.length - 1)
                                  PiggyDivider.short(
                                      indent: 56 + 16, endIndent: 16),
                              ],
                            );
                          },
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
