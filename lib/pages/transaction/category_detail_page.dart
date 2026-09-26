import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../data/db.dart' as db;
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/category_icon.dart';
import '../../styles/tokens.dart';
import 'package:intl/intl.dart';
import '../category/category_edit_page.dart';
import '../category/category_migration_page.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../services/billing/post_processor.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/category_utils.dart';

enum SortType { timeAsc, timeDesc, amountAsc, amountDesc }

class CategoryDetailPage extends ConsumerStatefulWidget {
  final int categoryId;
  final String categoryName;
  final DateTime? startDate; // 周期开始时间（可选）
  final DateTime? endDate; // 周期结束时间（可选）
  final String? periodLabel; // 周期标签（如"2024年11月"）
  final bool allLedgers; // true=全部账本(从分类管理进入)，false=当前账本(从明细进入)

  const CategoryDetailPage({
    super.key,
    required this.categoryId,
    required this.categoryName,
    this.startDate,
    this.endDate,
    this.periodLabel,
    this.allLedgers = false,
  });

  @override
  ConsumerState<CategoryDetailPage> createState() => _CategoryDetailPageState();
}

class _CategoryDetailPageState extends ConsumerState<CategoryDetailPage> {
  // 注意：不再需要SortType状态，因为现在由StateProvider管理

  @override
  Widget build(BuildContext context) {
    final categoryAsync = ref.watch(_categoryStreamProvider(widget.categoryId));
    final ledgerScope =
        widget.allLedgers ? null : ref.watch(currentLedgerIdProvider);
    final transactionsAsync = ref.watch(_categoryTransactionsWithSortProvider(
        (categoryId: widget.categoryId, ledgerId: ledgerScope)));
    final currentSortType =
        ref.watch(_categorySortTypeProvider(widget.categoryId));

    // 如果有周期限制，需要筛选交易数据
    // skipLoading*: 下拉刷新 invalidate 后保留旧数据渲染，避免整页闪 loading
    final filteredTransactionsAsync = transactionsAsync.when(
      skipLoadingOnReload: true,
      skipLoadingOnRefresh: true,
      loading: () => const AsyncValue<List<db.Transaction>>.loading(),
      error: (error, stack) =>
          AsyncValue<List<db.Transaction>>.error(error, stack),
      data: (transactions) {
        if (widget.startDate != null && widget.endDate != null) {
          final filtered = transactions.where((t) {
            // 修复：使用 >= 和 < 来包含起始日期，排除结束日期的下一天
            return t.happenedAt.isAtSameMomentAs(widget.startDate!) ||
                (t.happenedAt.isAfter(widget.startDate!) &&
                    t.happenedAt.isBefore(widget.endDate!));
          }).toList();
          return AsyncValue.data(filtered);
        }
        return AsyncValue.data(transactions);
      },
    );

    // 基于筛选后的数据计算汇总
    final summaryAsync = filteredTransactionsAsync.when(
      loading: () => const AsyncValue.loading(),
      error: (error, stack) => AsyncValue.error(error, stack),
      data: (transactions) {
        final totalCount = transactions.length;
        final totalAmount = transactions.fold(
            0.0, (sum, t) => sum + (t.nativeAmount ?? t.amount));
        final averageAmount = totalCount > 0 ? totalAmount / totalCount : 0.0;
        return AsyncValue.data((
          totalCount: totalCount,
          totalAmount: totalAmount,
          averageAmount: averageAmount,
        ));
      },
    );

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: categoryAsync.when(
        loading: () => PiggyTitleBar(
          title: AppLocalizations.of(context).categoryDetailSummaryTitle,
          showBack: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              tooltip: AppLocalizations.of(context).categoryMigrationTooltip,
              onPressed: null, // 加载时禁用
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: AppLocalizations.of(context).commonEdit,
              onPressed: null, // 加载时禁用
            ),
          ],
        ),
        error: (error, stack) => PiggyTitleBar(
          title: AppLocalizations.of(context).categoryDetailSummaryTitle,
          showBack: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              tooltip: AppLocalizations.of(context).categoryMigrationTooltip,
              onPressed: null, // 错误时禁用
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: AppLocalizations.of(context).commonEdit,
              onPressed: null, // 错误时禁用
            ),
          ],
        ),
        data: (category) => PiggyTitleBar(
          title: AppLocalizations.of(context).categoryDetailSummaryTitle,
          showBack: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.swap_horiz_outlined),
              tooltip: AppLocalizations.of(context).categoryMigrationTooltip,
              onPressed: category != null
                  ? () async {
                      final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CategoryMigrationPage(
                            preselectedFromCategory: category,
                          ),
                        ),
                      );

                      // 如果迁移完成，数据会自动通过Stream更新，无需手动刷新
                      if (result == true && mounted) {
                        // 响应式设计：数据库变化会自动推送到UI
                      }
                    }
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: AppLocalizations.of(context).commonEdit,
              onPressed: category != null
                  ? () async {
                      final result = await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => CategoryEditPage(
                            category: category,
                            kind: category.kind,
                          ),
                        ),
                      );

                      // 如果编辑成功，数据会自动通过Stream更新，无需手动刷新
                      if (result == true && mounted) {
                        // 响应式设计：数据库变化会自动推送到UI
                      }
                    }
                  : null,
            ),
          ],
        ),
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: Column(
                children: [
                  // 汇总信息卡片
                  summaryAsync.when(
                    loading: () => const SizedBox(
                      height: 120,
                      child: Center(child: CircularProgressIndicator()),
                    ),
                    error: (error, stack) => Container(
                      height: 120,
                      margin: const EdgeInsets.all(16),
                      child: Center(
                          child: Text(AppLocalizations.of(context)
                              .categoryLoadFailed(error.toString()))),
                    ),
                    data: (summary) => _buildSummaryCard(summary),
                  ),
                  // 排序控件
                  _buildSortControls(currentSortType),
                  // 交易记录列表
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async {
                        PiggyHaptics.light();
                        final params = (
                          categoryId: widget.categoryId,
                          ledgerId: ledgerScope
                        );
                        ref.invalidate(
                            _categoryTransactionsStreamProvider(params));
                        try {
                          await ref.read(
                              _categoryTransactionsStreamProvider(params)
                                  .future);
                        } catch (_) {
                          // 失败保持静默，错误分支由 when 展示
                        }
                      },
                      child: filteredTransactionsAsync.when(
                        skipLoadingOnReload: true,
                        skipLoadingOnRefresh: true,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (error, stack) => Center(
                            child: Text(
                                '${AppLocalizations.of(context).categoryDetailLoadFailed}: $error')),
                        data: (transactions) => _buildTransactionsList(
                            transactions, currentSortType),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSummaryCard(
      ({int totalCount, double totalAmount, double averageAmount}) summary) {
    // 获取分类信息以确定颜色
    final categoryAsync = ref.watch(_categoryStreamProvider(widget.categoryId));
    final category = categoryAsync.value;
    final isIncome = category?.kind == 'income';

    return Container(
      // 与下方明细外卡共用 12px 左右外边距(PiggyDimens.cardMargin 是 EdgeInsets),
      // 保证两张卡片左右同宽对齐。
      // SectionCard 默认还有 12px 水平外边距,会导致汇总卡比下方明细卡更窄,
      // 这里显式传 margin: EdgeInsets.zero 让外层 Container 单独控制边距。
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: SectionCard(
        margin: EdgeInsets.zero,
        borderColor: ref.watch(primaryColorProvider),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(
                    Icons.bar_chart,
                    color: PiggyTokens.primary(context),
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      widget.periodLabel != null
                          ? '${CategoryUtils.getDisplayName(widget.categoryName, context)} · ${widget.periodLabel}'
                          : CategoryUtils.getDisplayName(
                              widget.categoryName, context),
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  Expanded(
                    child: _SummaryItem(
                      label:
                          AppLocalizations.of(context).categoryDetailTotalCount,
                      value: AppLocalizations.of(context)
                          .categoryMigrationTransactionLabel(
                              summary.totalCount),
                      color: PiggyTokens.primary(context),
                    ),
                  ),
                  Expanded(
                    child: _SummaryItem(
                      label: AppLocalizations.of(context)
                          .categoryDetailTotalAmount,
                      value: summary.totalAmount,
                      isAmount: true,
                      color: isIncome
                          ? PiggyTokens.incomeColor(context, ref)
                          : PiggyTokens.expenseColor(context, ref),
                    ),
                  ),
                  Expanded(
                    child: _SummaryItem(
                      label: AppLocalizations.of(context)
                          .categoryDetailAverageAmount,
                      value: summary.averageAmount,
                      isAmount: true,
                      color: PiggyTokens.textTertiary(context),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 切换排序：仅在「时间/金额」两个维度内翻转方向。
  /// - 当前已是时间维度：timeDesc ⇄ timeAsc
  /// - 从金额维度切过来：回到默认的时间倒序
  SortType _toggleTime(SortType current) {
    if (current == SortType.timeDesc) return SortType.timeAsc;
    if (current == SortType.timeAsc) return SortType.timeDesc;
    return SortType.timeDesc;
  }

  /// 切换排序：仅在「金额」维度内翻转方向。
  /// - 当前已是金额维度：amountDesc ⇄ amountAsc
  /// - 从时间维度切过来：回到默认的金额倒序
  SortType _toggleAmount(SortType current) {
    if (current == SortType.amountDesc) return SortType.amountAsc;
    if (current == SortType.amountAsc) return SortType.amountDesc;
    return SortType.amountDesc;
  }

  Widget _buildSortControls(SortType currentSortType) {
    final l10n = AppLocalizations.of(context);
    final isTimeSelected = currentSortType == SortType.timeDesc ||
        currentSortType == SortType.timeAsc;
    final isAmountSelected = currentSortType == SortType.amountDesc ||
        currentSortType == SortType.amountAsc;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Row(
        children: [
          Icon(
            Icons.sort,
            size: 16,
            color: PiggyTokens.textTertiary(context),
          ),
          const SizedBox(width: 8),
          Text(
            l10n.categoryDetailSortTitle,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PiggyTokens.textTertiary(context),
                ),
          ),
          const Spacer(),
          _SortButton(
            // 激活时按当前方向显示「时间↓/时间↑」，未激活时显示默认倒序
            label: currentSortType == SortType.timeAsc
                ? l10n.categoryDetailSortTimeAsc
                : l10n.categoryDetailSortTimeDesc,
            isSelected: isTimeSelected,
            onTap: () => ref
                .read(_categorySortTypeProvider(widget.categoryId).notifier)
                .state = _toggleTime(currentSortType),
          ),
          const SizedBox(width: 8),
          _SortButton(
            label: currentSortType == SortType.amountAsc
                ? l10n.categoryDetailSortAmountAsc
                : l10n.categoryDetailSortAmountDesc,
            isSelected: isAmountSelected,
            onTap: () => ref
                .read(_categorySortTypeProvider(widget.categoryId).notifier)
                .state = _toggleAmount(currentSortType),
          ),
        ],
      ),
    );
  }

  Widget _buildTransactionsList(
      List<db.Transaction> transactions, SortType currentSortType) {
    if (transactions.isEmpty) {
      return AppEmpty(
        text: AppLocalizations.of(context).categoryDetailNoTransactions,
        subtext:
            AppLocalizations.of(context).categoryDetailNoTransactionsSubtext,
      );
    }

    // 全部账本模式下，构建账本名映射，用于在交易项展示账本标签
    final Map<int, String> ledgerNames = widget.allLedgers
        ? {
            for (final l
                in (ref.watch(ledgersStreamProvider).valueOrNull ?? []))
              l.id: l.name
          }
        : const <int, String>{};

    // 金额排序：不再按天分组（按金额排后位置会散），每条交易用 showFullDate
    // 完整显示日期+时间，项间用细分割线，保留与时间排序一致的「大卡片」外壳。
    // 每条交易作为独立的懒加载 item —— 明细多时按需构建，避免一次性渲染全部。
    if (currentSortType == SortType.amountDesc ||
        currentSortType == SortType.amountAsc) {
      return _buildLazyCard(
        itemCount: transactions.length,
        itemBuilder: (context, index) {
          final children = <Widget>[
            _buildTransactionItem(transactions[index], ledgerNames,
                showFullDate: true),
          ];
          if (index < transactions.length - 1) {
            children.add(Divider(
              height: PiggyTokens.listDayDividerHeight(context),
              thickness: PiggyTokens.listDayDividerHeight(context),
              color: PiggyTokens.listDayDividerColor(context),
              indent: 12,
              endIndent: 12,
            ));
          }
          return Column(children: children);
        },
      );
    }

    // 时间排序：按天分组 → 每个 day 作为独立懒加载 item（header + 当天交易
    // 连续显示），天与天之间用细分割线（与「整张明细」风格一致）。按天懒
    // 加载保证明细多时只构建视口内的 day，而不是一次性构建全部交易。
    final Map<String, List<db.Transaction>> groupedTransactions =
        <String, List<db.Transaction>>{};
    for (final transaction in transactions) {
      final dateKey =
          DateFormat('yyyy-MM-dd').format(transaction.happenedAt.toLocal());
      groupedTransactions.putIfAbsent(dateKey, () => []).add(transaction);
    }

    final sortedKeys = groupedTransactions.keys.toList();
    if (currentSortType == SortType.timeDesc) {
      sortedKeys.sort((a, b) => b.compareTo(a)); // 最新日期在前
    } else {
      sortedKeys.sort((a, b) => a.compareTo(b)); // 最早日期在前
    }

    return _buildLazyCard(
      itemCount: sortedKeys.length,
      itemBuilder: (context, index) {
        final dateKey = sortedKeys[index];
        final dayTransactions = groupedTransactions[dateKey]!;

        final children = <Widget>[
          DaySectionHeader(
            dateText: dateKey,
            expense: dayTransactions
                .where((t) => t.type == 'expense')
                .fold(0.0, (sum, t) => sum + (t.nativeAmount ?? t.amount)),
            income: dayTransactions
                .where((t) => t.type == 'income')
                .fold(0.0, (sum, t) => sum + (t.nativeAmount ?? t.amount)),
          ),
          for (final t in dayTransactions)
            _buildTransactionItem(t, ledgerNames),
        ];
        if (index < sortedKeys.length - 1) {
          children.add(Divider(
            height: PiggyTokens.listDayDividerHeight(context),
            thickness: PiggyTokens.listDayDividerHeight(context),
            color: PiggyTokens.listDayDividerColor(context),
            indent: 12,
            endIndent: 12,
          ));
        }
        return Column(children: children);
      },
    );
  }

  /// 构建单条交易项(无分组逻辑,纯 widget 工厂)。供时间/金额两种排序复用。
  /// - [showFullDate]:金额排序时为 true,在第二行完整显示日期+时间,替代
  ///   按天分组时的 DaySectionHeader。
  Widget _buildTransactionItem(
    db.Transaction transaction,
    Map<int, String> ledgerNames, {
    bool showFullDate = false,
  }) {
    final category = _getTransactionCategory();
    // v47：自定义字段角标（无值/定义解析不出 → 不显示）。
    final customBadges = ref
            .watch(customFieldValueBadgesProvider)
            .valueOrNull?[transaction.id] ??
        const <({String name, String display})>[];
    final customBadgeTexts = [
      for (final b in customBadges) '${b.name}: ${b.display}',
    ];
    return TransactionListItem(
      icon: _getTransactionIcon(transaction),
      category: category,
      title: transaction.note ?? '',
      transactionId: transaction.id,
      categoryName: CategoryUtils.getDisplayName(
          category?.name ?? widget.categoryName, context),
      ledgerName: ledgerNames[transaction.ledgerId],
      amount: transaction.amount,
      currencyCode: transaction.currencyCode,
      nativeAmount: transaction.nativeAmount,
      customFieldBadges:
          customBadgeTexts.isNotEmpty ? customBadgeTexts : null,
      isExpense: transaction.type == 'expense',
      happenedAt: transaction.happenedAt,
      showFullDate: showFullDate,
      onTap: () async {
        final categoryData =
            ref.read(_categoryStreamProvider(widget.categoryId));
        await TransactionEditUtils.editTransaction(
          context,
          ref,
          transaction,
          categoryData.value,
        );
        // 注意：现在无需手动刷新！
        // 数据库变化会自动通过Stream推送到UI
      },
      onDelete: () async {
        final repo = ref.read(repositoryProvider);
        final ledgerId = ref.read(currentLedgerIdProvider);

        try {
          // F1 回收站：软删除，可在「设置 > 数据管理 > 回收站」恢复
          await repo.softDeleteTransaction(transaction.id);

          // 统一处理：自动/手动同步与状态刷新（后台静默）
          await PostProcessor.sync(ref, ledgerId: ledgerId);

          // 刷新：账本笔数与全局统计
          ref.invalidate(countsForLedgerProvider(ledgerId));
          ref.read(statsRefreshProvider.notifier).state++;
          ref.read(budgetRefreshProvider.notifier).state++;
          if (mounted) {
            showToast(context, AppLocalizations.of(context).recycleBinMoved);
          }
        } catch (e) {
          if (mounted) {
            showToast(context,
                '${AppLocalizations.of(context).categoryDetailDeleteFailed}: $e');
          }
        }
      },
    );
  }

  /// 懒加载的「整张大卡片」外壳。
  ///
  /// 用 ListView.builder 把每个 day（时间排序）或每条交易（金额排序）作为
  /// 独立 item 按需构建：首 item 画顶部圆角 + 顶边 + 阴影，末 item 画底部
  /// 圆角 + 底边，中间 item 只画左右边线——视觉上仍是连续一张大卡片，
  /// 但明细很多时不会一次性构建/渲染全部交易（旧的 _buildOuterCard 把整棵
  /// 子树塞进单个 ListView item，年视角下分类明细可达上千笔 → 卡顿）。
  Widget _buildLazyCard({
    required int itemCount,
    required Widget Function(BuildContext context, int index) itemBuilder,
  }) {
    final isDark = PiggyTokens.isDark(context);
    final primary = ref.watch(primaryColorProvider);
    const borderWidth = 1.5;

    return Container(
      margin: PiggyDimens.cardMargin,
      child: ListView.builder(
        // item 间无额外间距，圆角/边框由首末 item 决定
        padding: EdgeInsets.zero,
        // AlwaysScrollable: 内容不满一屏时也能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: itemCount,
        itemBuilder: (context, index) {
          final isFirst = index == 0;
          final isLast = index == itemCount - 1;
          return Container(
            decoration: BoxDecoration(
              color: PiggyTokens.surface(context),
              borderRadius: BorderRadius.only(
                topLeft: isFirst
                    ? const Radius.circular(PiggyDimens.radiusLg)
                    : Radius.zero,
                topRight: isFirst
                    ? const Radius.circular(PiggyDimens.radiusLg)
                    : Radius.zero,
                bottomLeft: isLast
                    ? const Radius.circular(PiggyDimens.radiusLg)
                    : Radius.zero,
                bottomRight: isLast
                    ? const Radius.circular(PiggyDimens.radiusLg)
                    : Radius.zero,
              ),
              border: Border(
                top: isFirst
                    ? BorderSide(color: primary, width: borderWidth)
                    : BorderSide.none,
                bottom: isLast
                    ? BorderSide(color: primary, width: borderWidth)
                    : BorderSide.none,
                left: BorderSide(color: primary, width: borderWidth),
                right: BorderSide(color: primary, width: borderWidth),
              ),
              boxShadow: isFirst ? (isDark ? null : PiggyShadows.card) : null,
            ),
            child: itemBuilder(context, index),
          );
        },
      ),
    );
  }

  db.Category? _getTransactionCategory() {
    final categoryAsync = ref.read(_categoryStreamProvider(widget.categoryId));
    return categoryAsync.value;
  }

  IconData _getTransactionIcon(db.Transaction transaction) {
    final categoryAsync = ref.read(_categoryStreamProvider(widget.categoryId));
    final category = categoryAsync.value;
    final categoryName = category?.name ?? widget.categoryName;
    // 使用统一的图标获取逻辑,优先使用分类对象的icon字段
    return getCategoryIconData(category: category, categoryName: categoryName);
  }
}

class _SummaryItem extends ConsumerWidget {
  final String label;
  final dynamic value; // 可以是 String 或 double
  final Color color;
  final bool isAmount; // 是否为金额类型

  const _SummaryItem({
    required this.label,
    required this.value,
    required this.color,
    this.isAmount = false,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    Widget valueWidget;
    if (isAmount && value is double) {
      // 金额类型,使用 AmountText
      valueWidget = AmountText(
        value: value as double,
        signed: false,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      );
    } else {
      // 其他类型,直接显示字符串
      valueWidget = Text(
        value.toString(),
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      );
    }

    return Column(
      children: [
        valueWidget,
        const SizedBox(height: 4),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PiggyTokens.textTertiary(context),
              ),
        ),
      ],
    );
  }
}

// ===== 响应式Provider设计 =====

// 基础数据流：监听分类信息变化
final _categoryStreamProvider =
    StreamProvider.family<db.Category?, int>((ref, categoryId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchCategory(categoryId);
});

// 基础数据流：监听分类下交易变化（仅当前账本）
final _categoryTransactionsStreamProvider = StreamProvider.family<
    List<db.Transaction>, ({int categoryId, int? ledgerId})>((ref, params) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTransactionsByCategory(params.categoryId,
      ledgerId: params.ledgerId);
});

// 排序状态管理
final _categorySortTypeProvider =
    StateProvider.family<SortType, int>((ref, categoryId) {
  return SortType.timeDesc; // 默认时间倒序
});

// 派生数据：排序后的交易列表（自动响应排序状态变化）
final _categoryTransactionsWithSortProvider = Provider.family<
    AsyncValue<List<db.Transaction>>,
    ({int categoryId, int? ledgerId})>((ref, params) {
  final transactionsAsync =
      ref.watch(_categoryTransactionsStreamProvider(params));
  final sortType = ref.watch(_categorySortTypeProvider(params.categoryId));

  return transactionsAsync.when(
    loading: () => const AsyncValue.loading(),
    error: (error, stack) => AsyncValue.error(error, stack),
    data: (transactions) {
      final sorted = List<db.Transaction>.from(transactions);

      switch (sortType) {
        case SortType.timeAsc:
          sorted.sort((a, b) => a.happenedAt.compareTo(b.happenedAt));
          break;
        case SortType.timeDesc:
          sorted.sort((a, b) => b.happenedAt.compareTo(a.happenedAt));
          break;
        case SortType.amountAsc:
          sorted.sort((a, b) => a.amount.compareTo(b.amount));
          break;
        case SortType.amountDesc:
          sorted.sort((a, b) => b.amount.compareTo(a.amount));
          break;
      }

      return AsyncValue.data(sorted);
    },
  );
});

class _SortButton extends StatelessWidget {
  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  const _SortButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? PiggyTokens.primary(context)
              : PiggyTokens.surface(context),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
          border: Border.all(
            color: isSelected
                ? PiggyTokens.primary(context)
                : PiggyTokens.divider(context),
          ),
        ),
        child: Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: isSelected
                    ? PiggyTokens.textOnPrimary(context)
                    : PiggyTokens.textPrimary(context),
                fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
              ),
        ),
      ),
    );
  }
}
