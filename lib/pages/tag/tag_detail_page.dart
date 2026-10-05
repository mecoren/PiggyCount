import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart' as db;
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/category_icon.dart';
import '../../styles/tokens.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../utils/month_range.dart';
import '../../services/billing/post_processor.dart';
import '../../utils/category_utils.dart';
import '../../utils/shared_ledger_picker_filter.dart';
import '../../l10n/app_localizations.dart';
import '../attachment/attachment_preview_page.dart';
import '../transaction/category_detail_page.dart';
import 'tag_edit_page.dart';

/// 标签详情页
/// 显示标签统计和关联交易列表
class TagDetailPage extends ConsumerStatefulWidget {
  final int tagId;
  final String tagName;
  final bool allLedgers; // true=全部账本(从标签管理进入)，false=当前账本(从明细进入)

  const TagDetailPage({
    super.key,
    required this.tagId,
    required this.tagName,
    this.allLedgers = false,
  });

  @override
  ConsumerState<TagDetailPage> createState() => _TagDetailPageState();
}

/// 明细行数据：交易本体 + 该笔的其它标签 + 附件数（行渲染直接读，不二次查库）。
typedef _TagRow = ({db.Transaction t, List<db.Tag> tags, int attachmentCount});

class _TagDetailPageState extends ConsumerState<TagDetailPage> {
  // 缓存分类数据
  Map<int, db.Category> _categoryCache = {};
  // 缓存账户名(id → 名称),明细行的「账户 / 转出 → 转入」用
  Map<int, String> _accountNames = {};

  // 明细列表滚动控制:换周期 / 换维度后回到顶部,否则内容变短时视口停在
  // 旧偏移上(看起来像"内容凭空消失一截")。
  final ScrollController _listController = ScrollController();

  // #461 时间维度:month | year | all。默认 all 保持旧行为(与标签管理列表的
  // 总笔数对得上)。
  String _scope = 'all';
  // 月/年视角选中的周期标签(DateTime(y,m,1));null = 当前周期
  DateTime? _selMonth;

  /// 当前 scope 的统计/列表时间范围;all 返回 null(全部历史,含未来的预记账)。
  /// 月/年周期口径与洞察页一致(自定义每月起始日,periodForLabel/yearRangeFor)。
  DateRange? _rangeForScope(int startDay, DateTime selMonth) {
    switch (_scope) {
      case 'month':
        return periodForLabel(selMonth.year, selMonth.month, startDay);
      case 'year':
        return yearRangeFor(selMonth.year, startDay);
      default:
        return null;
    }
  }

  // 显示周期选择器(对齐洞察页:月=年月轮盘,年=年轮盘)
  void _showPeriodPicker(DateTime selMonth) async {
    if (_scope == 'month') {
      final res = await showWheelDatePicker(
        context,
        initial: selMonth,
        mode: WheelDatePickerMode.ym,
        maxDate: DateTime.now(),
      );
      if (res != null) {
        setState(() => _selMonth = DateTime(res.year, res.month, 1));
        _scrollListToTop();
      }
    } else if (_scope == 'year') {
      final res = await showWheelDatePicker(
        context,
        initial: selMonth,
        mode: WheelDatePickerMode.y,
        maxDate: DateTime.now(),
      );
      if (res != null) {
        setState(() => _selMonth = DateTime(res.year, 1, 1));
        _scrollListToTop();
      }
    }
  }

  @override
  void dispose() {
    _listController.dispose();
    super.dispose();
  }

  @override
  void initState() {
    super.initState();
    _loadLookups();
  }

  /// 一次性取明细行要用的查表数据:分类(含共享账本 synthetic)+ 账户名。
  /// 随页加载而非常驻 stream:标签详情是短页面,不值得为它挂一条长订阅。
  Future<void> _loadLookups() async {
    final repo = ref.read(repositoryProvider);
    final categories = await repo.getAllCategoriesIncludingShared();
    final accounts = await repo.getAllAccounts();
    if (mounted) {
      setState(() {
        _categoryCache = {for (var c in categories) c.id: c};
        _accountNames = {for (final a in accounts) a.id: a.name};
      });
    }
  }

  Color _parseTagColor(String? colorHex) {
    if (colorHex == null || colorHex.isEmpty) {
      return PiggyTokens.primary(context);
    }
    try {
      String hex = colorHex;
      if (hex.startsWith('#')) {
        hex = hex.substring(1);
      }
      if (hex.length == 6) {
        hex = 'FF$hex';
      }
      return Color(int.parse(hex, radix: 16));
    } catch (e) {
      return PiggyTokens.primary(context);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final tagAsync = ref.watch(_tagStreamProvider(widget.tagId));
    final ledgerScope =
        widget.allLedgers ? null : ref.watch(currentLedgerIdProvider);
    // #461 时间维度:月/年/全部。all = null(全部历史,与旧行为一致)
    final startDay = ref.watch(currentMonthStartDayProvider);
    final selMonth = _selMonth ?? labelForDate(DateTime.now(), startDay);
    final range = _rangeForScope(startDay, selMonth);
    // 明细一次取全量(默认口径本就是「全部」)，月/年只在内存里过滤：
    // 切维度不再新建 provider 实例 → 没有 loading 态，切换零等待不闪。
    final params = (tagId: widget.tagId, ledgerId: ledgerScope);
    final rowsAsync = ref.watch(_tagRowsProvider(params));
    // 统计与列表同源：都按当前维度这批明细现算，删改后无需额外刷新（见 _statsOf）。
    final allRows = rowsAsync.valueOrNull;
    final rows = _rowsInScope(allRows ?? const <_TagRow>[], range);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: tagAsync.when(
        loading: () => PiggyTitleBar(
          title: l10n.tagDetailTitle,
          showBack: true,
        ),
        error: (error, stack) => PiggyTitleBar(
          title: l10n.tagDetailTitle,
          showBack: true,
        ),
        data: (tag) => PiggyTitleBar(
          title: l10n.tagDetailTitle,
          showBack: true,
          actions: [
            IconButton(
              icon: const Icon(Icons.edit_outlined),
              tooltip: l10n.commonEdit,
              onPressed: tag != null
                  ? () async {
                      await Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => TagEditPage(tag: tag),
                        ),
                      );
                    }
                  : null,
            ),
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: l10n.commonDelete,
              onPressed: tag != null ? () => _confirmDelete(tag, l10n) : null,
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
                  // 标签信息和统计卡片
                  tagAsync.when(
                    loading: () => SizedBox(
                      height: 140,
                      child: Center(
                          child: PiggySpinner(
                              size: 36, color: PiggyTokens.primary(context))),
                    ),
                    error: (error, stack) => Container(
                      height: 140,
                      margin: const EdgeInsets.all(16),
                      child: Center(child: Text('${l10n.commonError}: $error')),
                    ),
                    data: (tag) {
                      if (tag == null) {
                        return Container(
                          height: 140,
                          margin: const EdgeInsets.all(16),
                          child: Center(child: Text(l10n.tagNotFound)),
                        );
                      }
                      return _buildSummaryCard(
                          tag, _statsOf(allRows == null ? null : rows), l10n);
                    },
                  ),
                  // 时间维度筛选条(#461):月/年/全部 + 周期跳转
                  _buildScopeBar(l10n, selMonth),
                  // 交易列表标题
                  Padding(
                    padding: const EdgeInsets.symmetric(
                        horizontal: PiggyDimens.p12, vertical: PiggyDimens.p8),
                    child: Row(
                      children: [
                        Icon(
                          Icons.receipt_long_outlined,
                          size: 16,
                          color: PiggyTokens.textTertiary(context),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          l10n.tagDetailTransactionList,
                          style:
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    color: PiggyTokens.textTertiary(context),
                                  ),
                        ),
                      ],
                    ),
                  ),
                  // 交易列表
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async {
                        PiggyHaptics.light();
                        ref.invalidate(_tagRowsProvider(params));
                        await _loadLookups();
                        try {
                          await ref.read(_tagRowsProvider(params).future);
                        } catch (_) {
                          // 失败保持静默，错误分支由 when 展示
                        }
                      },
                      child: rowsAsync.when(
                        // skipLoading*: 下拉刷新后保留旧数据渲染，避免整页闪 loading
                        skipLoadingOnReload: true,
                        skipLoadingOnRefresh: true,
                        loading: () => Center(
                            child: PiggySpinner(
                                size: 36, color: PiggyTokens.primary(context))),
                        error: (error, stack) => Center(
                          child: Text('${l10n.commonError}: $error'),
                        ),
                        // 数据分支用内存过滤后的 rows（切月/年不产生 loading）
                        data: (_) => _buildTransactionsList(rows, l10n),
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

  /// 换时间维度。setState 后把明细滚回顶部（见 _scrollListToTop）。
  void _switchScope(String value) {
    setState(() => _scope = value);
    _scrollListToTop();
  }

  /// 换周期：滚回顶部。
  void _scrollListToTop() {
    if (!_listController.hasClients) return;
    _listController.jumpTo(0);
  }

  Widget _buildScopeBar(AppLocalizations l10n, DateTime selMonth) {
    final periodLabel = _scope == 'year'
        ? '${selMonth.year}'
        : '${selMonth.year}-${selMonth.month.toString().padLeft(2, '0')}';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      child: Row(
        children: [
          // 项目通用 tab 样式（WaitSlidingSegmentedControl）：与首页 / 洞察页
          // 同一控件，切换只有胶囊滑动，无重绘式闪动。
          Expanded(
            child: WaitSlidingSegmentedControl<String>(
              selected: _scope,
              height: 36,
              fontSize: PiggyTextTokens.fs13,
              segments: [
                WaitSlidingSegment(value: 'month', label: l10n.analyticsMonth),
                WaitSlidingSegment(value: 'year', label: l10n.analyticsYear),
                WaitSlidingSegment(value: 'all', label: l10n.analyticsAll),
              ],
              onValueChanged: _switchScope,
            ),
          ),
          // 周期切换器占满余量：「全部」时留白。固定用 Expanded 而不是
          // mainAxisSize.min —— 月↔年切换时文案宽度变化（2026-10 ↔ 2026）
          // 也不会让整行重排，切换过程零位移。
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: _scope == 'all'
                  ? null
                  : InkWell(
                      onTap: () => _showPeriodPicker(selMonth),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              periodLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: PiggyTextTokens.strongTitle(context),
                            ),
                          ),
                          Icon(
                            Icons.arrow_drop_down,
                            size: 20,
                            color: PiggyTokens.textPrimary(context),
                          ),
                        ],
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  /// 按当前时间维度过滤明细。range 为 null(全部)直接返回原列表。
  ///
  /// 走内存过滤而不是把 start/end 塞进 provider 参数:后者每换一个周期就
  /// 换一个 provider 实例 → 整个列表回 loading(转圈 + 内容闪烁),而默认
  /// 口径本就是「全部历史」,一次取全量没有额外成本。
  List<_TagRow> _rowsInScope(List<_TagRow> rows, DateRange? range) {
    if (range == null || rows.isEmpty) return rows;
    // 与按天分组同一口径:先转本地时间再比较,避免跨时区把边界日切错。
    final start = range.start;
    final end = range.end;
    return [
      for (final row in rows)
        if (_inRange(row.t.happenedAt.toLocal(), start, end)) row,
    ];
  }

  /// 半开区间 [start, end)。
  static bool _inRange(DateTime local, DateTime start, DateTime end) =>
      !local.isBefore(start) && local.isBefore(end);

  /// 汇总口径与 `getTagStats` 一致：笔数全计，金额跳过「不计收支」的记录。
  ({int count, double expense, double income})? _statsOf(List<_TagRow>? rows) {
    if (rows == null) return null;
    var count = 0;
    var expense = 0.0;
    var income = 0.0;
    for (final row in rows) {
      count++;
      if (row.t.excludeFromStats) continue;
      final value = row.t.nativeAmount ?? row.t.amount;
      if (row.t.type == 'expense') expense += value;
      if (row.t.type == 'income') income += value;
    }
    return (count: count, expense: expense, income: income);
  }

  Widget _buildSummaryCard(
    db.Tag tag,
    ({int count, double expense, double income})? stats,
    AppLocalizations l10n,
  ) {
    final tagColor = _parseTagColor(tag.color);

    return Container(
      // 与下方明细大卡片共用 12px 左右外边距(PiggyDimens.cardMargin),
      // 保证两张卡片左右同宽对齐(同分类详情页口径)。
      margin: const EdgeInsets.all(PiggyDimens.p12),
      child: SectionCard(
        margin: EdgeInsets.zero,
        borderColor: ref.watch(primaryColorProvider),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标签信息
              Row(
                children: [
                  // 颜色指示器
                  Container(
                    width: 16,
                    height: 16,
                    decoration: BoxDecoration(
                      color: tagColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      tag.name,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // 统计信息
              Row(
                children: [
                  Expanded(
                    child: _SummaryItem(
                      label: l10n.tagDetailTotalCount,
                      value: stats != null
                          ? l10n.tagTransactionCount(stats.count)
                          : '-',
                      color: PiggyTokens.primary(context),
                    ),
                  ),
                  Expanded(
                    child: _SummaryItem(
                      label: l10n.tagDetailTotalExpense,
                      value: stats?.expense ?? 0.0,
                      isAmount: true,
                      color: PiggyTokens.expenseColor(context, ref),
                    ),
                  ),
                  Expanded(
                    child: _SummaryItem(
                      label: l10n.tagDetailTotalIncome,
                      value: stats?.income ?? 0.0,
                      isAmount: true,
                      color: PiggyTokens.incomeColor(context, ref),
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

  Widget _buildTransactionsList(List<_TagRow> rows, AppLocalizations l10n) {
    if (rows.isEmpty) {
      return AppEmpty(
        text: l10n.tagDetailNoTransactions,
        subtext: l10n.tagDetailNoTransactionsHint,
      );
    }

    // 全部账本模式下，构建账本名映射，用于在交易项展示账本标签
    final ledgerNames = widget.allLedgers
        ? <int, String>{
            for (final l
                in (ref.watch(ledgersStreamProvider).valueOrNull ?? []))
              l.id: l.name
          }
        : const <int, String>{};

    // 账户名（转账显示「转出 → 转入」，其余显示账户名）。账户功能关闭时不展示。
    final accountsEnabled =
        ref.watch(accountFeatureEnabledProvider).valueOrNull ?? true;
    final accountNames =
        accountsEnabled ? _accountNames : const <int, String>{};

    // 按日期分组（与账本明细同一口径：本地日历日 yyyy-MM-dd，日期倒序）
    final Map<String, List<_TagRow>> groupedRows = {};
    for (final row in rows) {
      final at = row.t.happenedAt.toLocal();
      final key = '${at.year}-${at.month.toString().padLeft(2, '0')}-'
          '${at.day.toString().padLeft(2, '0')}';
      groupedRows.putIfAbsent(key, () => []).add(row);
    }
    final sortedKeys = groupedRows.keys.toList()
      ..sort((a, b) => b.compareTo(a));

    // 「整张大卡片」外壳：与账本明细同一视觉（主题色细边框 + 首末圆角），
    // 日间用细线分隔，按天懒加载避免一次性构建全部明细。
    return Container(
      margin: PiggyDimens.cardMargin,
      child: ListView.builder(
        controller: _listController,
        padding: EdgeInsets.zero,
        // AlwaysScrollable: 内容不满一屏时也能下拉刷新
        physics: const AlwaysScrollableScrollPhysics(),
        itemCount: sortedKeys.length,
        itemBuilder: (context, index) {
          final dateKey = sortedKeys[index];
          final dayRows = groupedRows[dateKey]!;
          final isLast = index == sortedKeys.length - 1;
          return DayGroupCard(
            isFirst: index == 0,
            isLast: isLast,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                DaySectionHeader(
                  dateText: dateKey,
                  expense: dayRows.where((r) => r.t.type == 'expense').fold(
                      0.0, (sum, r) => sum + (r.t.nativeAmount ?? r.t.amount)),
                  income: dayRows.where((r) => r.t.type == 'income').fold(
                      0.0, (sum, r) => sum + (r.t.nativeAmount ?? r.t.amount)),
                ),
                for (final row in dayRows)
                  _buildTransactionItem(row, ledgerNames, accountNames, l10n),
                if (!isLast)
                  Divider(
                    height: PiggyTokens.listDayDividerHeight(context),
                    thickness: PiggyTokens.listDayDividerHeight(context),
                    color: PiggyTokens.listDayDividerColor(context),
                    indent: 12,
                    endIndent: 12,
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// 单条明细(纯 widget 工厂)。行内容与账本明细(TransactionList)对齐：
  /// 转账/估值调整有各自的标题与图标口径，次要信息行带时间·账户·其它标签·
  /// 附件·自定义字段角标，金额侧遵循隐藏金额开关。
  Widget _buildTransactionItem(
    _TagRow row,
    Map<int, String> ledgerNames,
    Map<int, String> accountNames,
    AppLocalizations l10n,
  ) {
    final t = row.t;
    final isTransfer = t.type == 'transfer';
    final isAdjustment = t.type == 'adjustment';
    final isExpense = t.type == 'expense';

    // 共享账本交易的分类挂在 categorySyncIdOverride(syncId)，转 synthetic id 查；
    // 本地交易用 categoryId。两类 id 不重叠(本地正 / synthetic 负)。
    final catKey = (t.categorySyncIdOverride != null &&
            t.categorySyncIdOverride!.isNotEmpty)
        ? syntheticIdForSyncId(t.categorySyncIdOverride!)
        : t.categoryId;
    final category = catKey == null ? null : _categoryCache[catKey];
    final categoryName = isAdjustment
        ? l10n.adjustmentTransaction
        : CategoryUtils.getDisplayName(category?.name, context);

    // 转账恒显示「转出 → 转入」，其余显示账户名
    final fromName = accountNames[t.accountId];
    final toName = isTransfer ? accountNames[t.toAccountId] : null;
    final accountLine =
        (fromName != null && toName != null) ? '$fromName → $toName' : fromName;

    // 标签：当前标签本身不重复展示(用户就是点它进来的)，其它标签可点击跳转
    final tagChips = [
      for (final tag in row.tags)
        if (tag.id != widget.tagId)
          (id: tag.id, name: tag.name, color: tag.color),
    ];

    // v47：自定义字段角标（无值/定义解析不出 → 不显示）。
    final customBadges =
        ref.watch(customFieldValueBadgesProvider).valueOrNull?[t.id] ??
            const <({String name, String display})>[];
    final customBadgeTexts = [
      for (final b in customBadges) '${b.name}: ${b.display}',
    ];

    final note = t.note ?? '';
    return TransactionListItem(
      icon: isAdjustment
          ? Icons.tune
          : getCategoryIconData(category: category, categoryName: categoryName),
      category: isAdjustment ? null : category,
      title: isTransfer
          ? (note.isNotEmpty ? note : l10n.transferTitle)
          : isAdjustment
              ? categoryName
              : note,
      categoryName: (isTransfer || isAdjustment) ? null : categoryName,
      ledgerName: ledgerNames[t.ledgerId],
      amount: t.amount,
      transactionId: t.id,
      currencyCode: t.currencyCode,
      nativeAmount: t.nativeAmount,
      originalAmount: t.originalAmount,
      isExpense: isExpense,
      isTransfer: isTransfer,
      isAdjustment: isAdjustment,
      happenedAt: t.happenedAt,
      accountName: accountLine,
      tags: tagChips.isEmpty ? null : tagChips,
      attachmentCount: row.attachmentCount,
      customFieldBadges: customBadgeTexts.isEmpty ? null : customBadgeTexts,
      excludeFromStats: t.excludeFromStats,
      excludeFromBudget: t.excludeFromBudget,
      onAttachmentTap: row.attachmentCount > 0
          ? () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => AttachmentPreviewPage.fromTransaction(
                    transactionId: t.id,
                  ),
                ),
              )
          : null,
      onTagTap: (tagId, tagName) => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => TagDetailPage(tagId: tagId, tagName: tagName),
        ),
      ),
      onTap: () async {
        await TransactionEditUtils.editTransaction(context, ref, t, category);
      },
      onCategoryTap: !isTransfer && category != null
          ? () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => CategoryDetailPage(
                    categoryId: category.id,
                    categoryName: categoryName,
                  ),
                ),
              )
          : null,
      onDelete: () async {
        await _deleteTransaction(t, l10n);
      },
    );
  }

  Future<void> _deleteTransaction(
      db.Transaction transaction, AppLocalizations l10n) async {
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);

    try {
      // F1 回收站：软删除，可在「设置 > 数据管理 > 回收站」恢复
      await repo.softDeleteTransaction(transaction.id);

      await PostProcessor.sync(ref, ledgerId: ledgerId);

      ref.invalidate(countsForLedgerProvider(ledgerId));
      ref.read(statsRefreshProvider.notifier).state++;
      ref.read(budgetRefreshProvider.notifier).state++;
      ref.read(tagListRefreshProvider.notifier).state++;
      if (mounted) showToast(context, l10n.recycleBinMoved);
    } catch (e) {
      if (mounted) {
        showToast(context, '${l10n.commonError}: $e');
      }
    }
  }

  void _confirmDelete(db.Tag tag, AppLocalizations l10n) async {
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.tagDeleteConfirmTitle,
      message: l10n.tagDeleteConfirmMessage(tag.name),
      okLabel: l10n.commonDelete,
      destructive: true,
    );

    if (confirmed == true && mounted) {
      final repo = ref.read(repositoryProvider);
      await repo.deleteTag(tag.id);
      ref.read(tagListRefreshProvider.notifier).state++;

      if (mounted) {
        showToast(context, l10n.tagDeleteSuccess);
        Navigator.of(context).pop();
      }
    }
  }
}

class _SummaryItem extends ConsumerWidget {
  final String label;
  final dynamic value;
  final Color color;
  final bool isAmount;

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
      valueWidget = AmountText(
        value: value as double,
        signed: false,
        style: Theme.of(context).textTheme.titleLarge?.copyWith(
              color: color,
              fontWeight: FontWeight.w600,
            ),
      );
    } else {
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

// ===== Providers =====

/// 监听标签详情
final _tagStreamProvider = StreamProvider.family<db.Tag?, int>((ref, tagId) {
  final repo = ref.watch(repositoryProvider);
  return repo.watchTag(tagId);
});

/// 标签下的全部交易，逐笔补齐「其它标签 + 附件数」，让行渲染与账本明细等价
/// 而无需页面侧二次查库。
///
/// 不带时间维度参数:#461 的月/年筛选在页面侧按 _rowsInScope 内存过滤 —— 切
/// 维度因此不换 provider 实例,不产生 loading 态(无闪烁)。
/// 统计卡片同样由这批明细现算（见 _statsOf），删改后自动跟随。
final _tagRowsProvider = StreamProvider.autoDispose
    .family<List<_TagRow>, ({int tagId, int? ledgerId})>((ref, params) async* {
  final repo = ref.watch(repositoryProvider);
  await for (final txs in repo.watchTransactionsByTag(
    params.tagId,
    ledgerId: params.ledgerId,
  )) {
    final ids = [for (final t in txs) t.id];
    if (ids.isEmpty) {
      yield const [];
      continue;
    }
    final tagsMap = await repo.getTagsForTransactions(ids);
    final attachmentCounts = await repo.getAttachmentCountsForTransactions(ids);
    yield [
      for (final t in txs)
        (
          t: t,
          tags: tagsMap[t.id] ?? const <db.Tag>[],
          attachmentCount: attachmentCounts[t.id] ?? 0,
        ),
    ];
  }
});
