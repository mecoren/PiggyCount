import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:flutter_list_view/flutter_list_view.dart';
import 'package:visibility_detector/visibility_detector.dart';
import '../../data/db.dart';
import '../../providers.dart';
import '../../providers/budget_providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../services/system/logger_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../services/billing/post_processor.dart';
import '../../utils/transaction_edit_utils.dart';
import '../../utils/category_utils.dart';
import '../category_icon.dart';
import 'transaction_day_grouper.dart';
import '../../pages/transaction/category_detail_page.dart';
import '../../pages/tag/tag_detail_page.dart';
import '../../pages/attachment/attachment_preview_page.dart';
import '../../l10n/app_localizations.dart';
import '../../services/attachment_service.dart';
import '../../utils/month_range.dart';

/// 可复用的交易列表组件
/// 支持显示分组的交易列表，包含日期头部和交易项
class TransactionList extends ConsumerStatefulWidget {
  /// 完整交易数据（含标签、附件、账户，无需二次加载）
  final List<TransactionDisplayItem>? transactionsWithDetails;

  /// 交易数据（仅含分类，需二次加载标签和附件）
  final List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })>? transactions;

  /// 是否隐藏金额
  final bool hideAmounts;

  /// 是否启用可见性检测用于月份跳转（主要用于首页）
  final bool enableVisibilityTracking;

  /// 月份变化回调（用于首页月份跳转逻辑）
  final Function(String dateKey, bool isVisible)? onDateVisibilityChanged;

  /// 自定义空状态显示
  final Widget? emptyWidget;

  /// 列表控制器（可选，用于精准跳转）
  final FlutterListViewController? controller;

  /// 是否启用「分组卡片」风格:每个 day 渲染为 FlutterListView 的独立懒加载项,
  /// 首日画顶部圆角+顶边+阴影,末日画底部圆角+底边,中日只画左右边线——所有
  /// day 共享连续 surface 背景,形成「一张大卡片」观感。日内交易不再画分割线,
  /// 日间用细线分隔。滚动时按需构建/回收,避免 3000 笔账单下一次性构建全部
  /// 交易导致卡顿。
  /// - true:分组卡片风格(首页"明细"tab 当前风格);
  /// - false:不包外卡,回到无包裹状态(向后兼容)。
  final bool wrapInOuterCard;

  /// 列表头部自定义内容(如月份总结卡片),作为列表第一项随列表一起滚动。
  final Widget? listHeader;

  const TransactionList({
    super.key,
    this.transactionsWithDetails,
    this.transactions,
    required this.hideAmounts,
    this.enableVisibilityTracking = false,
    this.onDateVisibilityChanged,
    this.emptyWidget,
    this.controller,
    this.wrapInOuterCard = true,
    this.listHeader,
  }) : assert(transactionsWithDetails != null || transactions != null,
            'Either transactionsWithDetails or transactions must be provided');

  @override
  ConsumerState<TransactionList> createState() => TransactionListState();
}

class TransactionListState extends ConsumerState<TransactionList> {
  late FlutterListViewController _controller;
  List<dynamic> _flatItems = []; // 扁平化的项目列表
  final Map<String, int> _dateIndexMap = {}; // 日期到列表索引的映射

  // 数据指纹缓存:transactions 列表引用 + 长度 + 首尾交易 id 都未变时跳过
  // _buildFlatItems 的全量重算(格式化/分组/排序)。首页父级 rebuild(如
  // hideAmountsProvider、_loadTags setState)传入同一 list 引用时,3000 条
  // 数据不必每次重跑。
  //
  // 显式比较首尾 id 的原因:Drift watch 重新 emit 时,新 list 通常是不同引用,
  // 仅靠 !identical + length 就能 miss 缓存;但「云端合并」等场景下 stream
  // 偶尔会出现"新引用 + 相同长度 + 内部若干条 id 被替换/金额被改"的组合,
  // 此时日合计 _buildDayCard 的循环会拿到旧 list 的 (Transaction t) 元组,
  // 求和就是旧值,而 _buildTransactionRow 用的 Dismissible key 'tx-${id}'
  // 因为 id 变了会被强制重建——结果就是"明细是新数据、合计是旧数据"的诡异
  // 现象。把首尾 id 当作内容指纹的 O(1) 轻量代理,加进缓存 miss 条件。
  List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })>? _flatItemsSource;
  int? _flatItemsSourceLength;
  int? _firstTxId;
  int? _lastTxId;

  // P1-C 增量分组：分组卡片模式（wrapInOuterCard）的分组状态与日合计缓存。
  // _dayTotalsCache 仅脏日失效重算，未脏日（列表实例未变）直接复用。
  final TransactionDayGrouper _grouper = TransactionDayGrouper();
  bool _groupingSeeded = false;
  final Map<String, (double, double)> _dayTotalsCache = {};

  // 缓存标签数据（仅用于非预加载模式）
  Map<int, List<Tag>> _cachedTagsMap = {};
  List<int> _cachedTransactionIds = [];
  int _lastTagRefreshVersion = 0;

  // 缓存附件数量（仅用于非预加载模式）
  Map<int, int> _cachedAttachmentCounts = {};
  List<int> _cachedAttachmentIds = [];
  int _lastAttachmentRefreshVersion = 0;

  // D 方案后:不再需要 _cachedAccountNames / _cachedToAccountNames /
  // _lastSharedResourceRefreshVersion — 账户对象由 watchTransactionsWith*
  // 的 LEFT JOIN 直接挂在 tx 记录,Drift 自然响应主表变化 + SharedLedger*
  // 镜像变化。

  // 标记是否应使用预加载数据（当 Stream 数据与预加载数据不同时切换）
  bool _usePreloadedData = true;

  /// 获取统一格式的交易列表（用于内部处理）
  /// 始终使用 transactions 作为列表数据源，预加载数据只用于详情（标签、附件、账户）
  List<
      ({
        Transaction t,
        Category? category,
        Account? account,
        Account? toAccount
      })> get _transactionsList {
    return widget.transactions ?? [];
  }

  /// 预加载数据按 id 的 O(1) 查找表(避免每行渲染线性扫描整个列表)。
  /// 仅在预加载数据引用变化时惰性构建一次。
  Map<int, TransactionDisplayItem>? _preloadedById;
  bool _preloadedIdsStale = true;
  Map<int, TransactionDisplayItem> get _preloadedByIdMap {
    if (_preloadedIdsStale && widget.transactionsWithDetails != null) {
      _preloadedById = {
        for (final item in widget.transactionsWithDetails!) item.t.id: item,
      };
      _preloadedIdsStale = false;
    }
    return _preloadedById ?? const {};
  }

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? FlutterListViewController();
    // 始终加载标签和附件（用于非预加载范围的交易）
    _loadTags();
    _loadAttachmentCounts();
  }

  @override
  void didUpdateWidget(covariant TransactionList oldWidget) {
    super.didUpdateWidget(oldWidget);

    // 检测预加载数据是否变化（如账本切换），重置状态
    if (widget.transactionsWithDetails != oldWidget.transactionsWithDetails) {
      _preloadedIdsStale = true; // 预加载查找表已过期,下次访问时重建
      _preloadedById = null;
      if (widget.transactionsWithDetails != null) {
        _usePreloadedData = true; // 重置为预加载模式
      }
    }

    // 检查 transactions 数据变化，重新加载标签和附件。
    // P7：先走廉价短路——同一实例必未变；长度 + 首尾 id 一致也可跳过
    // （id 是自增主键，集合变化必然改长度或首尾）。原实现每次父重建
    // （隐藏金额切换、横幅等 setState）都 map 出全量 id 列表再比对。
    final txs = widget.transactions;
    if (txs != null) {
      final oldTxs = oldWidget.transactions;
      final cheapSame = identical(txs, oldTxs) ||
          (oldTxs != null &&
              txs.length == oldTxs.length &&
              (txs.isEmpty ||
                  (txs.first.t.id == oldTxs.first.t.id &&
                      txs.last.t.id == oldTxs.last.t.id)));
      if (!cheapSame) {
        final newIds = txs.map((t) => t.t.id).toList();
        if (!_listEquals(newIds, _cachedTransactionIds)) {
          _loadTags();
          _loadAttachmentCounts();
        }
      }
    }
  }

  bool _listEquals(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  Future<void> _loadTags() async {
    final transactionIds = _transactionsList.map((t) => t.t.id).toList();
    // 指纹去重:当前 id 列表与上次已加载的一致时跳过,避免 didUpdateWidget /
    // refresh provider 触发重复的全量批量查询。
    if (_listEquals(transactionIds, _cachedTransactionIds)) return;
    if (transactionIds.isEmpty) {
      setState(() {
        _cachedTagsMap = {};
        _cachedTransactionIds = [];
      });
      return;
    }

    final repo = ref.read(repositoryProvider);
    final tagsMap = await repo.getTagsForTransactions(transactionIds);

    if (mounted) {
      setState(() {
        _cachedTagsMap = tagsMap;
        _cachedTransactionIds = transactionIds;
      });
    }
  }

  Future<void> _loadAttachmentCounts() async {
    final transactionIds = _transactionsList.map((t) => t.t.id).toList();
    // 指纹去重:与上次已加载的 id 列表一致时跳过。
    if (_listEquals(transactionIds, _cachedAttachmentIds)) return;
    if (transactionIds.isEmpty) {
      setState(() {
        _cachedAttachmentCounts = {};
        _cachedAttachmentIds = [];
      });
      return;
    }

    final repo = ref.read(repositoryProvider);
    final countsMap =
        await repo.getAttachmentCountsForTransactions(transactionIds);

    if (mounted) {
      setState(() {
        _cachedAttachmentCounts = countsMap;
        _cachedAttachmentIds = transactionIds;
      });
    }
  }

  /// 获取预加载的交易详情(O(1) Map 查找,替代每行线性扫描)
  TransactionDisplayItem? _getPreloadedItem(int transactionId) {
    if (!_usePreloadedData) return null;
    return _preloadedByIdMap[transactionId];
  }

  /// 获取交易的标签列表（优先使用预加载数据）
  List<Tag> _getTagsForTransaction(int transactionId) {
    final preloaded = _getPreloadedItem(transactionId);
    if (preloaded != null) {
      return preloaded.tags;
    }
    return _cachedTagsMap[transactionId] ?? [];
  }

  /// 获取交易的附件数量（优先使用预加载数据）
  int _getAttachmentCountForTransaction(int transactionId) {
    final preloaded = _getPreloadedItem(transactionId);
    if (preloaded != null) {
      return preloaded.attachmentCount;
    }
    return _cachedAttachmentCounts[transactionId] ?? 0;
  }

  @override
  void dispose() {
    if (widget.controller == null) {
      _controller.dispose(); // 只在我们创建的controller时才dispose
    }
    super.dispose();
  }

  /// 跳转到列表顶部
  void jumpToTop() {
    try {
      _controller.sliverController.jumpToIndex(0);
    } catch (e) {
      // 跳转失败，忽略错误
    }
  }

  /// 切换到 Stream 模式（在用户离开首页时调用）
  /// 这样后续数据变化能正常刷新，且用户看不到切换过程
  void switchToStreamMode() {
    if (_usePreloadedData) {
      // 延迟 100ms 再切换，等导航动画开始后用户看不到
      Future.delayed(const Duration(milliseconds: 100), () {
        if (mounted && _usePreloadedData) {
          logger.info('TransactionList', '用户交互，切换到Stream模式');
          // 用 setState 改 _usePreloadedData,否则后续 build 还在跑
          // preloaded 路径,共享账本 WS 推送下来的新账户名永远不会显示
          // (preloaded.accountName 是 Splash 阶段的快照)。
          setState(() {
            _usePreloadedData = false;
          });
          // 开始加载标签和附件（异步，不阻塞）
          _loadTags();
          _loadAttachmentCounts();
        }
      });
    }
  }

  /// 共享账本 WS 推送强制切到 Stream 模式 — 没有导航动画顾虑,立即切。
  /// 用于 sharedResourceRefreshProvider tick 触发的场景:Owner 改 tx 引用的
  /// account/category/tag,Editor 这边需要立即丢掉 preloaded(里面挂的是
  /// Splash 阶段的旧 accountName)走 provider 拉新值。
  void forceStreamModeImmediate() {
    if (!mounted) return;
    if (!_usePreloadedData) return;
    logger.info('TransactionList', 'WS 推送强制切 Stream 模式 (immediate)');
    setState(() {
      _usePreloadedData = false;
    });
    _loadTags();
    _loadAttachmentCounts();
  }

  /// 跳转到指定周期标签月(按账本起始日的周期范围匹配,而非 yyyy-MM 前缀)
  bool jumpToMonth(DateTime targetMonth, {int startDay = 1}) {
    final range = periodForLabel(targetMonth.year, targetMonth.month, startDay);

    // 查找该周期内的任意一天
    for (final entry in _dateIndexMap.entries) {
      final parts = entry.key.split('-');
      if (parts.length != 3) continue;
      final d = DateTime(
          int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));
      if (!d.isBefore(range.start) && d.isBefore(range.end)) {
        try {
          _controller.sliverController.jumpToIndex(entry.value);
          return true;
        } catch (e) {
          // 跳转失败，返回false
          return false;
        }
      }
    }

    return false; // 没有找到目标月份
  }

  /// 构建扁平化的项目列表
  ///
  /// P1-C 增量分组：分组卡片模式（wrapInOuterCard，首页在用）走
  /// TransactionDayGrouper —— 已 seed 时先增量 diff，无变化直接返回（Drift
  /// 等值重复 emit 零重建成本），有变化仅重建脏日；首次构建 fullRebuild。
  /// 单笔增删改从「全量 DateFormat×n + 排序 + 全部扁平项重建」降为
  /// O(n) 值比较 + 脏日重建。平铺旧风格（无调用方）保留原全量路径。
  void _buildFlatItems() {
    final transactions = _transactionsList;

    if (widget.wrapInOuterCard) {
      if (_groupingSeeded) {
        final dirty = _grouper.applyDiff(transactions);
        if (dirty == null) return;
        // 脏日的合计缓存失效，扁平项重建时重算
        for (final key in dirty) {
          _dayTotalsCache.remove(key);
        }
      } else {
        _grouper.fullRebuild(transactions);
        _dayTotalsCache.clear();
        _groupingSeeded = true;
      }
      _rebuildFlatItemsFromGroups();
      return;
    }

    // ---- 平铺旧风格（wrapInOuterCard = false）：原全量路径 ----
    final dateFmt = DateFormat('yyyy-MM-dd');
    final groups = <String,
        List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>>{};
    for (final item in transactions) {
      final dt = item.t.happenedAt.toLocal();
      final key = dateFmt.format(DateTime(dt.year, dt.month, dt.day));
      groups.putIfAbsent(key, () => []).add(item);
    }
    final sortedKeys = groups.keys.toList()..sort((a, b) => b.compareTo(a));

    _flatItems = <dynamic>[];
    _dateIndexMap.clear();
    if (widget.listHeader != null) {
      _flatItems.add(('listHeader', null, null));
    }
    for (final key in sortedKeys) {
      final list = groups[key]!;
      _dateIndexMap[key] = _flatItems.length;
      _flatItems.add(('header', key, list, _computeDayTotals(list)));
      for (final item in list) {
        _flatItems.add(('transaction', item, list));
      }
    }
    if (_flatItems.isNotEmpty) {
      _flatItems.add(('bottomSpacer', null, null));
    }
  }

  /// O(days)：从 grouper 结果重建扁平项 / 日期索引 / 累计起点 / 首末日标记。
  /// 首末日标记每次重排（新日插入或末日删除会改变归属），O(days) 可接受。
  void _rebuildFlatItemsFromGroups() {
    _flatItems = <dynamic>[];
    _dateIndexMap.clear();

    if (widget.listHeader != null) {
      _flatItems.add(('listHeader', null, null));
    }

    final keys = _grouper.sortedDayKeys;
    if (keys.isNotEmpty) {
      final lastIndex = keys.length - 1;
      for (int i = 0; i < keys.length; i++) {
        final key = keys[i];
        final list = _grouper.dayGroups[key]!;
        _dateIndexMap[key] = _flatItems.length;
        _flatItems.add((
          'day',
          key,
          list,
          i == 0, // isFirst：首日画顶部圆角+顶边+阴影
          i == lastIndex, // isLast：末日画底部圆角
          _dayTotalsCache.putIfAbsent(key, () => _computeDayTotals(list)),
        ));
      }
    }

    if (_flatItems.isNotEmpty) {
      _flatItems.add(('bottomSpacer', null, null));
    }
  }

  /// 日合计预计算：income/expense 构建期一次算好存入 flat item，渲染期不再
  /// 每帧循环当天交易列表。转账不计入收支统计（与原口径一致）。
  (double, double) _computeDayTotals(
      List<
              ({
                Transaction t,
                Category? category,
                Account? account,
                Account? toAccount
              })>
          list) {
    double income = 0, expense = 0;
    for (final it in list) {
      if (it.t.type == 'income') income += it.t.nativeAmount ?? it.t.amount;
      if (it.t.type == 'expense') expense += it.t.nativeAmount ?? it.t.amount;
    }
    return (income, expense);
  }

  @override
  Widget build(BuildContext context) {
    // 监听标签刷新信号，当标签变化时重新加载
    final tagRefreshVersion = ref.watch(tagListRefreshProvider);
    if (tagRefreshVersion != _lastTagRefreshVersion) {
      _lastTagRefreshVersion = tagRefreshVersion;
      // 延迟加载以避免在build中setState
      Future.microtask(() => _loadTags());
    }

    // 监听附件刷新信号，当附件变化时重新加载
    final attachmentRefreshVersion = ref.watch(attachmentListRefreshProvider);
    if (attachmentRefreshVersion != _lastAttachmentRefreshVersion) {
      _lastAttachmentRefreshVersion = attachmentRefreshVersion;
      Future.microtask(() => _loadAttachmentCounts());
    }

    // D 方案后:不再 watch sharedResourceRefreshProvider 触发 _loadAccountNames
    // —— account / toAccount 由 Drift JOIN + SharedLedger* table-watch 自动
    // 推送,UI 直接读 it.account?.name。

    // 数据引用缓存:同一 transactions 列表引用 + 相同长度 + 相同首尾 id 时
    // 复用上次 _flatItems 结果(父级 rebuild 时传入同一引用),避免 3000 条
    // 数据每次 build 全量重算。引用变化(Stream 推送新列表)、长度变化、或
    // 首尾 id 变化(云端合并可能 emit 同长度新列表但内容不同)时才重建。
    final tx = _transactionsList;
    final firstId = tx.isNotEmpty ? tx.first.t.id : null;
    final lastId = tx.isNotEmpty ? tx.last.t.id : null;
    if (!identical(tx, _flatItemsSource) ||
        tx.length != _flatItemsSourceLength ||
        firstId != _firstTxId ||
        lastId != _lastTxId) {
      _buildFlatItems();
      _flatItemsSource = tx;
      _flatItemsSourceLength = tx.length;
      _firstTxId = firstId;
      _lastTxId = lastId;
    }

    // 无数据时展示空状态（列表头部仍显示，位于空状态上方）
    final hasTransactions = _transactionsList.isNotEmpty;
    if (_flatItems.isEmpty || (widget.listHeader != null && !hasTransactions)) {
      final empty = widget.emptyWidget ??
          AppEmpty(
            text: AppLocalizations.of(context).commonEmpty,
            subtext: AppLocalizations.of(context).homeNoRecords,
          );
      if (widget.listHeader != null) {
        return Column(
          children: [
            // 空数据时 listHeader 不随列表滚动,需要补上与正常路径等效的水平边距
            // (正常路径由 FlutterListView 外层 Container(margin: cardMargin) 给
            // 出,左右各 12px)。用 Container(margin: horizontal: 12) 而不是
            // Padding:Container 的 margin 让子项宽度 = (screenWidth - 24),
            // 与正常路径一致;Padding 会让背景延伸 + box 约束传播在 Row+Expanded
            // 嵌套下偶发 layout 异常(空状态提示不可见)。
            Container(
              margin: const EdgeInsets.fromLTRB(12, 4, 12, 0),
              child: widget.listHeader!,
            ),
            Expanded(child: empty),
          ],
        );
      }
      return empty;
    }

    // 使用FlutterListView渲染列表。外层 Container(margin: cardMargin) 给出
    // 「整张大卡片」整体边距,内部每个 day item 共享连续边线 boxShadow,而非
    // 每个 day 独立 margin —— 形成一个连续大卡片观感。
    return Container(
      margin: PiggyDimens.cardMargin,
      child: FlutterListView(
        controller: _controller,
        physics: const BouncingScrollPhysics(),
        delegate: FlutterListViewDelegate(
          (BuildContext context, int index) {
            final item = _flatItems[index];
            final type = item.$1 as String;

            if (type == 'listHeader') {
              // 列表头部内容（随列表滚动）
              return widget.listHeader ?? const SizedBox.shrink();
            }

            if (type == 'bottomSpacer') {
              // 悬浮 Tab 栏高度(56) + 浮动间距(12) + 安全区 + 额外间距
              final bottomPadding = MediaQuery.of(context).viewPadding.bottom;
              return SizedBox(height: 56 + 12 + bottomPadding + 16);
            }

            if (type == 'header') {
              // 渲染日期头部(平铺旧风格用)
              final dateKey = item.$2 as String;
              // 日合计在 _buildFlatItems 构建期预计算($4),渲染期零循环
              final totals = item.$4 as (double, double);
              final isFirst = index == 0;

              Widget header = Column(
                children: [
                  if (!isFirst)
                    Divider(
                      height: PiggyTokens.listDayDividerHeight(context),
                      color: PiggyTokens.listDayDividerColor(context),
                    ),
                  DaySectionHeader(
                    dateText: dateKey,
                    income: totals.$1,
                    expense: totals.$2,
                    hide: widget.hideAmounts,
                  ),
                ],
              );

              // 如果启用可见性跟踪，则包装VisibilityDetector
              if (widget.enableVisibilityTracking &&
                  widget.onDateVisibilityChanged != null) {
                header = VisibilityDetector(
                  key: Key('header-$dateKey'),
                  onVisibilityChanged: (VisibilityInfo info) {
                    // 当可见比例大于50%时认为可见
                    widget.onDateVisibilityChanged!(
                        dateKey, info.visibleFraction > 0.5);
                  },
                  child: header,
                );
              }

              return header;
            } else if (type == 'day') {
              // 「分组卡片」风格:每个 day 独立懒加载,首日画顶部圆角+阴影,末日
              // 画底部圆角,中日只画左右边线——视觉上各 day 共享连续边线,像"一张
              // 大卡片"。FlutterListView 按 index 按需构建/回收解决 3000 条卡顿。
              // jumpToMonth 仍用 _dateIndexMap 映射到各 day item。
              final dateKey = item.$2 as String;
              final list = item.$3 as List<
                  ({
                    Transaction t,
                    Category? category,
                    Account? account,
                    Account? toAccount
                  })>;
              final isFirst = item.$4 as bool;
              final isLast = item.$5 as bool;
              final dayTotals = item.$6 as (double, double);
              return _buildDayCard(context, dateKey, list, isFirst, isLast,
                  dayTotals: dayTotals);
            } else {
              // 'transaction' 平铺旧风格(wrapInOuterCard = false):平铺单条交易,
              // 项之间用 PiggyDivider.short 分隔,项的具体渲染复用 _buildTransactionRow。
              final it = item.$2 as ({
                Transaction t,
                Category? category,
                Account? account,
                Account? toAccount
              });
              final allItemsInDay = item.$3 as List<
                  ({
                    Transaction t,
                    Category? category,
                    Account? account,
                    Account? toAccount
                  })>;
              final isLastInGroup = allItemsInDay.last.t.id == it.t.id;

              return Column(
                children: [
                  _buildTransactionRow(context, it, allItemsInDay),
                  if (!isLastInGroup)
                    PiggyDivider.short(indent: 56 + 16, endIndent: 16),
                ],
              );
            }
          },
          // onItemHeight:为 flutter_list_view 提供 item 高度估算,避免默认 50px
          // 严重低估 day 卡片(实际 = header + 当天交易行数×行高)导致 constructNext
          // 按 50px 逐项构建直到填满视口 → 单帧过量构建大量日卡片(含当天全部
          // 交易行),这是 3000 笔数据下真实设备卡顿的根因之一。此值仅用于估算
          // 构建范围/总高度,不参与实际布局,偏高是安全的。
          onItemHeight: (index) {
            if (index < 0 || index >= _flatItems.length) return 50.0;
            final item = _flatItems[index];
            final type = item.$1 as String;
            switch (type) {
              case 'listHeader':
                return 160.0; // 月份总结卡片(随内容变化,估算偏大)
              case 'bottomSpacer':
                return 110.0; // 悬浮 Tab 栏留白
              case 'day':
                // DaySectionHeader(~40px) + 当天交易行数×行高。行高取单行
                // 48px(icon32+8*2) + 二级信息行(~28px)的保守上限 72px。
                final list = item.$3 as List;
                return 40.0 + list.length * 72.0;
              case 'header':
                return 40.0; // 平铺旧风格:DaySectionHeader
              case 'transaction':
                return 80.0; // 平铺旧风格:单行 + 分割线
              default:
                return 50.0;
            }
          },
          childCount: _flatItems.length,
        ),
      ),
    );
  }

  /// 渲染单个交易项(Dismissible + TransactionListItem)。被「日卡片」和
  /// 旧平铺模式共用;调用方负责在项之间加分隔线,此处不输出。
  Widget _buildTransactionRow(
    BuildContext context,
    ({
      Transaction t,
      Category? category,
      Account? account,
      Account? toAccount
    }) it,
    List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>
        allItemsInDay,
  ) {
    final isTransfer = it.t.type == 'transfer';
    final isExpense = it.t.type == 'expense';
    final isAdjustment = it.t.type == 'adjustment';

    final categoryName = isAdjustment
        ? AppLocalizations.of(context).adjustmentTransaction
        : CategoryUtils.getDisplayName(it.category?.name, context);

    final subtitle = it.t.note ?? '';

    // D 方案:account / toAccount 已经由 watchTransactionsWith* 的 LEFT JOIN
    // (+ SharedLedger* hydration) 直接挂在 tx 记录上,跟 category 同款。UI 只读
    // it.account?.name,Drift 自动响应主表 accounts 行变化 + 镜像表
    // sharedLedgerAccounts 变化,无需任何命令式 cache / setState / provider fallback。
    final accountFeatureEnabled =
        ref.watch(accountFeatureEnabledProvider).valueOrNull ?? true;
    String? accountName;
    String? toAccountName;
    if (accountFeatureEnabled) {
      accountName = it.account?.name;
      if (isTransfer) toAccountName = it.toAccount?.name;
    }

    return Dismissible(
      key: Key('tx-${it.t.id}'),
      direction: DismissDirection.endToStart,
      background: Container(
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        color: Colors.red,
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      confirmDismiss: (direction) async {
        return await AppDialog.confirm<bool>(
              context,
              title: AppLocalizations.of(context).deleteConfirmTitle,
              message: AppLocalizations.of(context).deleteConfirmMessage,
            ) ??
            false;
      },
      onDismissed: (direction) async {
        final repo = ref.read(repositoryProvider);
        bool moved = false;
        try {
          // F1 回收站：用户侧删除一律软删（整行搬进 deleted_transactions，
          // 标签/附件原地保留），可在「设置 > 数据管理 > 回收站」恢复。
          moved = await repo.softDeleteTransaction(it.t.id);
        } catch (e) {
          // 审计 U5：Dismissible 已把行从视觉上移除，删除失败必须显式
          // 提示，否则是「行消失但数据还在」的静默失败
          logger.error('TransactionList', '删除交易失败 id=${it.t.id}', e);
          if (context.mounted) {
            showToast(
                context, '${AppLocalizations.of(context).commonFailed}: $e');
          }
          return;
        }

        if (!context.mounted) return;
        final curLedger = ref.read(currentLedgerIdProvider);
        ref.invalidate(countsForLedgerProvider(curLedger));
        ref.read(statsRefreshProvider.notifier).state++;
        ref.read(budgetRefreshProvider.notifier).state++;
        PostProcessor.sync(ref, ledgerId: curLedger);

        if (context.mounted) {
          showToast(
              context,
              moved
                  ? AppLocalizations.of(context).recycleBinMoved
                  : AppLocalizations.of(context).ledgersDeleted);
        }
      },
      child: Builder(
        builder: (context) {
          // 获取该交易的标签（优先使用预加载数据）
          final transactionTags = _getTagsForTransaction(it.t.id);
          final tagsList = transactionTags
              .map((t) => (id: t.id, name: t.name, color: t.color))
              .toList();

          // 转账账户信息
          final transferAccountInfo =
              (accountName != null && toAccountName != null)
                  ? '$accountName → $toAccountName'
                  : null;

          // 获取附件数量（优先使用预加载数据）
          final attachmentCount = _getAttachmentCountForTransaction(it.t.id);

          // B1(v47):自定义字段角标 —— 按当前账本定义解析展示文本;
          // 无值 / 定义解析不出 → 不显示(列表不被噪音填满)。
          final customBadges = ref
                  .watch(customFieldValueBadgesProvider)
                  .valueOrNull?[it.t.id] ??
              const <({String name, String display})>[];
          final customBadgeTexts = [
            for (final b in customBadges) '${b.name}: ${b.display}',
          ];

          return TransactionListItem(
            icon: isAdjustment
                ? Icons.tune
                : getCategoryIconData(
                    category: it.category, categoryName: categoryName),
            category: isAdjustment ? null : it.category,
            title: isTransfer
                ? (subtitle.isNotEmpty
                    ? subtitle
                    : AppLocalizations.of(context).transferTitle)
                : isAdjustment
                    ? categoryName
                    : subtitle,
            categoryName: (isTransfer || isAdjustment) ? null : categoryName,
            amount: it.t.amount,
            transactionId: it.t.id,
            currencyCode: it.t.currencyCode,
            nativeAmount: it.t.nativeAmount,
            originalAmount: it.t.originalAmount,
            isExpense: isExpense,
            isTransfer: isTransfer,
            isAdjustment: isAdjustment,
            hide: widget.hideAmounts,
            happenedAt: it.t.happenedAt,
            accountName: isTransfer
                ? transferAccountInfo // 转账始终在第三行显示账户信息
                : accountName,
            tags: tagsList.isNotEmpty ? tagsList : null,
            attachmentCount: attachmentCount,
            customFieldBadges: customBadgeTexts.isNotEmpty
                ? customBadgeTexts
                : null,
            excludeFromStats: it.t.excludeFromStats,
            excludeFromBudget: it.t.excludeFromBudget,
            onAttachmentTap: attachmentCount > 0
                ? () async {
                    switchToStreamMode(); // 用户交互，切换到 Stream 模式
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AttachmentPreviewPage.fromTransaction(
                          transactionId: it.t.id,
                        ),
                      ),
                    );
                  }
                : null,
            onTagTap: (tagId, tagName) async {
              switchToStreamMode(); // 用户交互，切换到 Stream 模式
              await Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => TagDetailPage(
                    tagId: tagId,
                    tagName: tagName,
                  ),
                ),
              );
            },
            onTap: () async {
              switchToStreamMode(); // 用户交互，切换到 Stream 模式
              await TransactionEditUtils.editTransaction(
                context,
                ref,
                it.t,
                it.category,
              );
            },
            onCategoryTap: !isTransfer && it.category?.id != null
                ? () async {
                    switchToStreamMode(); // 用户交互，切换到 Stream 模式
                    await Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => CategoryDetailPage(
                          categoryId: it.category!.id,
                          categoryName: categoryName,
                        ),
                      ),
                    );
                  }
                : null,
          );
        },
      ),
    );
  }

  /// 渲染单日「分组卡片」:DaySectionHeader + 当天所有交易项 + (非末日)日间细线,
  /// 包在一个装饰容器里。
  ///
  /// 视觉上每个 day 作为 FlutterListView 独立懒加载项按 index 按需构建/回收。
  /// 首日画顶部圆角+顶边+亮色阴影,末日画底部圆角+底边,中日只画左右边线——
  /// 所有 day 共享连续 surface 背景,形成「一张大卡片」观感。替代旧版
  /// _buildOuterCard 一次性 O(n) 渲染,解决 3000 笔账单下首页卡顿。
  Widget _buildDayCard(
    BuildContext context,
    String dateKey,
    List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>
        list,
    bool isFirst,
    bool isLast, {
    /// 日合计:由 _buildFlatItems 构建期预计算,渲染期零循环。
    /// 未传时兜底现算(防御未来新增调用点)。
    (double, double)? dayTotals,
  }) {
    final isDark = PiggyTokens.isDark(context);
    final primary = ref.watch(primaryColorProvider);
    final borderWidth = 1.5;
    final borderColor = primary;

    // 当天收支(用于 DaySectionHeader)
    double dayIncome, dayExpense;
    if (dayTotals != null) {
      (dayIncome, dayExpense) = dayTotals;
    } else {
      dayIncome = 0;
      dayExpense = 0;
      for (final it in list) {
        if (it.t.type == 'income') {
          dayIncome += it.t.nativeAmount ?? it.t.amount;
        }
        if (it.t.type == 'expense') {
          dayExpense += it.t.nativeAmount ?? it.t.amount;
        }
      }
    }
    Widget header = DaySectionHeader(
      dateText: dateKey,
      income: dayIncome,
      expense: dayExpense,
      hide: widget.hideAmounts,
    );
    // 可见性跟踪用于首页月份跳转
    if (widget.enableVisibilityTracking &&
        widget.onDateVisibilityChanged != null) {
      header = VisibilityDetector(
        key: Key('header-$dateKey'),
        onVisibilityChanged: (VisibilityInfo info) {
          widget.onDateVisibilityChanged!(dateKey, info.visibleFraction > 0.5);
        },
        child: header,
      );
    }

    // day 内容:header + 当天所有交易 + (非末日)日间细线。
    // Dismissible key 只用 'tx-${id}'——transactions.id 是主键，且一条交易只会落进
    // 一个日期组，跨 day 不会撞 key；早先拼 flatIndex 会让 key 随滚动位置变化，
    // 导致行状态（滑动删除动画等）被反复重建。
    final children = <Widget>[
      header,
      for (final it in list) _buildTransactionRow(context, it, list),
      if (!isLast)
        Divider(
          height: PiggyTokens.listDayDividerHeight(context),
          thickness: PiggyTokens.listDayDividerHeight(context),
          color: PiggyTokens.listDayDividerColor(context),
          indent: 12,
          endIndent: 12,
        ),
    ];

    // 「分组卡片」装饰:首日画顶部圆角+顶边+亮色 boxShadow,末日画底部圆角+底边,
    // 中日只画左右边线——所有 day 共享连续 surface 背景,视觉上像一张大卡片。
    return Container(
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        border: Border(
          top: isFirst
              ? BorderSide(color: borderColor, width: borderWidth)
              : BorderSide.none,
          bottom: isLast
              ? BorderSide(color: borderColor, width: borderWidth)
              : BorderSide.none,
          left: BorderSide(color: borderColor, width: borderWidth),
          right: BorderSide(color: borderColor, width: borderWidth),
        ),
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
        boxShadow: isFirst ? (isDark ? null : PiggyShadows.card) : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: children,
      ),
    );
  }
}
