import 'package:drift/drift.dart' as d;

import '../../db.dart';
import '../../models/transaction_original_amount.dart';
import '../../../utils/month_range.dart';
import '../../../utils/shared_ledger_picker_filter.dart';
import '../statistics_repository.dart';

/// 本地统计Repository实现
/// 基于 Drift 数据库实现
class LocalStatisticsRepository implements StatisticsRepository {
  final PiggyDatabase db;

  LocalStatisticsRepository(this.db);

  @override
  Future<List<({int? id, String name, String? icon, double total})>> totalsByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    final q = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.type.equals(type) &
              t.excludeFromStats.equals(false) &
              t.happenedAt.isBiggerOrEqualValue(start) & t.happenedAt.isSmallerThanValue(end)))
        .join([
      d.leftOuterJoin(db.categories,
          db.categories.id.equalsExp(db.transactions.categoryId)),
    ]);
    final rows = await q.get();
    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    final map = <int?, double>{};
    final names = <int?, String>{};
    final icons = <int?, String?>{};
    for (final r in rows) {
      final t = r.readTable(db.transactions);
      final c = r.readTableOrNull(db.categories);
      int? id = c?.id;
      String name = c?.name ?? '未分类';
      String? icon = c?.icon;
      // [共享账本已下线] §7 共享账本:Editor 写的 tx categoryId 为空,但
      // categorySyncIdOverride 指向 Owner 的分类 syncId — 查
      // SharedLedgerCategories 兜底(仅存量 override 数据命中)。
      if (c == null && t.categorySyncIdOverride != null) {
        final s = shared[t.categorySyncIdOverride!];
        if (s != null) {
          id = syntheticIdForSyncId(s.syncId);
          name = s.name;
          icon = s.icon;
        }
      }
      names[id] = name;
      icons[id] = icon;
      map.update(id, (v) => v + (t.nativeAmount ?? t.amount),
          ifAbsent: () => t.nativeAmount ?? t.amount);
    }
    final list = map.entries
        .map((e) => (id: e.key, name: names[e.key] ?? '未分类', icon: icons[e.key], total: e.value))
        .toList()
      ..sort((a, b) => b.total.compareTo(a.total));
    return list;
  }

  /// [共享账本已下线] 加载当前账本的 SharedLedger 分类索引(by syncId)。
  /// 单人账本返回空 map;共享账本(仅存量数据)返回 Owner user-global 的镜像。
  Future<Map<String, SharedLedgerCategory>> _loadSharedCategoriesForLedger(
      int ledgerId) async {
    final ledger = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    final syncId = ledger?.syncId;
    if (syncId == null || syncId.isEmpty) return const {};
    final rows = await (db.select(db.sharedLedgerCategories)
          ..where((t) => t.ledgerSyncId.equals(syncId)))
        .get();
    return {for (final r in rows) r.syncId: r};
  }

  @override
  Future<Map<int, Category>> getSharedSyntheticCategoriesForLedger(
      int ledgerId) async {
    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    if (shared.isEmpty) return const {};
    return {
      for (final s in shared.values)
        syntheticIdForSyncId(s.syncId): Category(
          id: syntheticIdForSyncId(s.syncId),
          name: s.name,
          kind: s.kind,
          icon: s.icon,
          sortOrder: s.sortOrder,
          // §7 二级分类 hierarchy:转 synthetic 父 id,让 analytics 的
          // L2→L1 rollup 找到 SharedLedger* 父分类(主表查不到这些 negative id)。
          parentId: (s.parentSyncId != null && s.parentSyncId!.isNotEmpty)
              ? syntheticIdForSyncId(s.parentSyncId!)
              : null,
          level: s.level,
          iconType: s.iconType,
          customIconPath: s.iconType == 'custom' && s.iconCloudSha256 != null
              ? 'custom_icons/shared_${s.iconCloudSha256}.png'
              : null,
          communityIconId: null,
          syncId: s.syncId,
        )
    };
  }

  @override
  Future<List<({int? id, String name, String? icon, int? parentId, int level, double total, int count})>>
      totalsByCategoryWithHierarchy({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    final q = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.type.equals(type) &
              t.excludeFromStats.equals(false) &
              t.happenedAt.isBiggerOrEqualValue(start) & t.happenedAt.isSmallerThanValue(end)))
        .join([
      d.leftOuterJoin(db.categories,
          db.categories.id.equalsExp(db.transactions.categoryId)),
    ]);

    final rows = await q.get();
    final shared = await _loadSharedCategoriesForLedger(ledgerId);
    final map = <int?, double>{};
    final countMap = <int?, int>{};
    final categoryInfo = <int?, ({String name, String? icon, int? parentId, int level})>{};

    for (final r in rows) {
      final t = r.readTable(db.transactions);
      final c = r.readTableOrNull(db.categories);
      int? id = c?.id;

      if (c != null) {
        categoryInfo[id] = (
          name: c.name,
          icon: c.icon,
          parentId: c.parentId,
          level: c.level,
        );
      } else if (t.categorySyncIdOverride != null &&
          shared[t.categorySyncIdOverride!] != null) {
        // §7 共享账本:Editor 写的 tx 用 categorySyncIdOverride 指向 Owner
        // 的分类,主表 join 不到,查 SharedLedger* 兜底。用 synthetic 负 id
        // 做聚合 key,跟 picker filter 保持一致。
        // §7 二级分类 hierarchy:Phase 2 加了 parent_sync_id 后,L2 SharedLedger*
        // 行有父分类 syncId — 转 synthetic 负 id 写入 parentId,让 analytics
        // 的 L2→L1 rollup 正确累加,而不是把 L2 当 orphan 丢掉。
        final s = shared[t.categorySyncIdOverride!]!;
        id = syntheticIdForSyncId(s.syncId);
        final pSyncId = s.parentSyncId;
        final parentSyntheticId = (pSyncId != null && pSyncId.isNotEmpty)
            ? syntheticIdForSyncId(pSyncId)
            : null;
        categoryInfo[id] = (
          name: s.name,
          icon: s.icon,
          parentId: parentSyntheticId,
          level: s.level,
        );
      } else {
        categoryInfo[id] = (
          name: '未分类',
          icon: null,
          parentId: null,
          level: 1,
        );
      }

      map.update(id, (v) => v + (t.nativeAmount ?? t.amount),
          ifAbsent: () => t.nativeAmount ?? t.amount);
      countMap.update(id, (v) => v + 1, ifAbsent: () => 1);
    }

    final list = map.entries.map((e) {
      final info = categoryInfo[e.key]!;
      return (
        id: e.key,
        name: info.name,
        icon: info.icon,
        parentId: info.parentId,
        level: info.level,
        total: e.value,
        count: countMap[e.key] ?? 0,
      );
    }).toList()
      ..sort((a, b) => b.total.compareTo(a.total));

    return list;
  }

  @override
  Future<List<({DateTime day, double total})>> totalsByDay({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    // SQL 分组聚合（此前全量加载日期范围内交易行再 Dart 循环累加）。
    // 分组键与旧实现严格一致：本地时区的日界（date(happened_at, 'unixepoch',
    // 'localtime')），原生 Dart 构造的 DateTime(local) 转 unixepoch 传入。
    // 结果补零保证 [start, end) 区间逐日连续。
    final rows = await db.customSelect(
      "SELECT date(happened_at, 'unixepoch', 'localtime') AS day, "
      'SUM(COALESCE(native_amount, amount)) AS total '
      'FROM transactions '
      'WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0 '
      'AND happened_at >= ?3 AND happened_at < ?4 '
      'GROUP BY day',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    final map = <DateTime, double>{
      for (final r in rows)
        DateTime.parse(r.read<String>('day')):
            (r.read<double>('total') as num).toDouble(),
    };
    final result = <({DateTime day, double total})>[];
    for (DateTime d = DateTime(start.year, start.month, start.day);
        d.isBefore(end);
        d = d.add(const Duration(days: 1))) {
      result.add((day: d, total: map[d] ?? 0));
    }
    return result;
  }

  @override
  Future<List<({DateTime month, double total})>> totalsByMonth({
    required int ledgerId,
    required String type,
    required int year,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final yr = yearRangeFor(year, sd);
    // SQL 聚合（此前全量载行再 Dart 循环）。startDay=1 时直接按自然月
    // 分组；startDay>1 时先用 WHERE 剪到该年范围，再按「周期标签月」在
    // SQL 内计算分组键（day >= startDay 归当月，否则归上月，与
    // labelForDate 逐字一致）。
    final rows = await db.customSelect(
      "SELECT strftime('%Y-%m', happened_at, 'unixepoch', 'localtime', "
      "CASE WHEN CAST(strftime('%d', happened_at, 'unixepoch', 'localtime') AS INTEGER) >= ?4 "
      "THEN 'start of month' ELSE '-1 month' END) AS label, "
      'SUM(COALESCE(native_amount, amount)) AS total '
      'FROM transactions '
      'WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0 '
      'AND happened_at >= ?3 AND happened_at < ?5 '
      "GROUP BY label HAVING substr(label, 1, 4) = ?6",
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(yr.start),
        d.Variable<int>(sd),
        d.Variable<DateTime>(yr.end),
        d.Variable<String>(year.toString()),
      ],
      readsFrom: {db.transactions},
    ).get();
    final map = <int, double>{
      for (final r in rows)
        int.parse(r.read<String>('label').split('-')[1]):
            (r.read<double>('total') as num).toDouble(),
    };
    final result = <({DateTime month, double total})>[];
    for (int m = 1; m <= 12; m++) {
      result.add((month: DateTime(year, m, 1), total: map[m] ?? 0));
    }
    return result;
  }

  @override
  Future<List<({int year, double total})>> totalsByYearSeries({
    required int ledgerId,
    required String type,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    // SQL 聚合（此前**无任何时间过滤**全量载入该账本全部交易行）。
    // startDay>1 时按周期标签年分组（同 totalsByMonth 的 label 规则）；
    // startDay=1 直接自然年。MIN/MAX 用同一标签列，保证首尾年连续性
    // 与旧实现一致（无数据返回空列表）。
    final rows = await db.customSelect(
      "WITH labeled AS (SELECT "
      "strftime('%Y', happened_at, 'unixepoch', 'localtime', "
      "CASE WHEN CAST(strftime('%d', happened_at, 'unixepoch', 'localtime') AS INTEGER) >= ?3 "
      "THEN 'start of month' ELSE '-1 month' END) AS label, "
      'COALESCE(native_amount, amount) AS v '
      'FROM transactions '
      'WHERE ledger_id = ?1 AND type = ?2 AND exclude_from_stats = 0) '
      'SELECT label, SUM(v) AS total FROM labeled GROUP BY label ORDER BY label',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<int>(sd),
      ],
      readsFrom: {db.transactions},
    ).get();
    if (rows.isEmpty) return const [];
    final out = <({int year, double total})>[];
    var minYear = int.parse(rows.first.read<String>('label'));
    var maxYear = int.parse(rows.last.read<String>('label'));
    final map = <int, double>{
      for (final r in rows)
        int.parse(r.read<String>('label')): (r.read<double>('total') as num).toDouble(),
    };
    for (int y = minYear; y <= maxYear; y++) {
      out.add((year: y, total: map[y] ?? 0));
    }
    return out;
  }

  /// 标签维度：一笔交易可挂多个标签，各标签分别计入（与标签详情页同源，
  /// 所以各行之和通常 **大于** 该区间总额，这是标签不互斥的口径而非 bug）。
  ///
  /// 两条 SQL 在 Dart 侧按 tag id 合并：
  /// 1. 主表路 `transaction_tags → tags`（本机拥有的标签）；
  /// 2. 共享账本 Editor 路 `transaction_tag_overrides → shared_ledger_tags`
  ///    （标签行不在主表，按 syncId 转 synthetic 负 id，同 `LocalTagRepository`）。
  /// 外键未启用、`native_amount` 可空 → 与既有统计一样 `COALESCE(native_amount, amount)`。
  @override
  Future<List<({int id, String name, String? color, double total, int count})>>
      totalsByTag({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    int ival(dynamic v) => v is num ? v.toInt() : (v is BigInt ? v.toInt() : 0);
    double dval(dynamic v) => v is num ? v.toDouble() : (v is BigInt ? v.toDouble() : 0.0);

    final rows = await db.customSelect(
      'SELECT tg.id AS id, tg.name AS name, tg.color AS color, '
      'COUNT(*) AS cnt, SUM(COALESCE(t.native_amount, t.amount)) AS total '
      'FROM transaction_tags tt '
      'INNER JOIN transactions t ON t.id = tt.transaction_id '
      'INNER JOIN tags tg ON tg.id = tt.tag_id '
      'WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?3 AND t.happened_at < ?4 '
      'GROUP BY tg.id',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactionTags, db.transactions, db.tags},
    ).get();
    final map = <int, ({int id, String name, String? color, double total, int count})>{
      for (final r in rows)
        r.read<int>('id'): (
          id: r.read<int>('id'),
          name: r.read<String>('name'),
          color: r.readNullable<String>('color'),
          total: dval(r.data['total']),
          count: ival(r.data['cnt']),
        )
    };

    final overrides = await db.customSelect(
      'SELECT o.tag_sync_id AS sync_id, st.name AS name, st.color AS color, '
      'COUNT(*) AS cnt, SUM(COALESCE(t.native_amount, t.amount)) AS total '
      'FROM transaction_tag_overrides o '
      'INNER JOIN transactions t ON t.sync_id = o.transaction_sync_id '
      'INNER JOIN shared_ledger_tags st ON st.sync_id = o.tag_sync_id '
      'WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?3 AND t.happened_at < ?4 '
      'GROUP BY o.tag_sync_id',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {
        db.transactionTagOverrides,
        db.transactions,
        db.sharedLedgerTags
      },
    ).get();
    for (final r in overrides) {
      final id = syntheticIdForSyncId(r.read<String>('sync_id'));
      final inc = dval(r.data['total']);
      final cnt = ival(r.data['cnt']);
      final prev = map[id];
      map[id] = (
        id: id,
        name: r.read<String>('name'),
        color: r.readNullable<String>('color'),
        total: (prev?.total ?? 0) + inc,
        count: (prev?.count ?? 0) + cnt,
      );
    }
    return map.values.toList()..sort((a, b) => b.total.compareTo(a.total));
  }

  @override
  Future<(double income, double expense)> totalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }

  /// 读取账本的自定义每月起始日(1-28);账本缺失或查询异常时按 1(自然月)降级
  /// —— watch 流经 Stream.fromFuture 包裹,这里抛错会让流永久进 error 态。
  Future<int> _monthStartDayOf(int ledgerId) async {
    try {
      final row = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerId)))
          .getSingleOrNull();
      return (row?.monthStartDay ?? 1).clamp(1, 28);
    } catch (_) {
      return 1;
    }
  }

  @override
  Future<(double income, double expense)> monthlyTotals({
    required int ledgerId,
    required DateTime month,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final range = periodForLabel(month.year, month.month, sd);
    final start = range.start;
    final end = range.end;

    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }

  @override
  Future<(double income, double expense)> yearlyTotals({
    required int ledgerId,
    required int year,
  }) async {
    final sd = await _monthStartDayOf(ledgerId);
    final range = yearRangeFor(year, sd);
    final start = range.start;
    final end = range.end;

    // 使用 SQL 聚合查询，比查出全部数据再累加快得多
    final result = await db.customSelect(
      '''
      SELECT
        COALESCE(SUM(CASE WHEN type = 'income' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS income,
        COALESCE(SUM(CASE WHEN type = 'expense' THEN COALESCE(native_amount, amount) ELSE 0 END), 0) AS expense
      FROM transactions
      WHERE ledger_id = ?1 AND happened_at >= ?2 AND happened_at < ?3
        AND exclude_from_stats = 0
      ''',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    final income = (result.data['income'] as num?)?.toDouble() ?? 0.0;
    final expense = (result.data['expense'] as num?)?.toDouble() ?? 0.0;
    return (income, expense);
  }

  // --- v45 原始金额偏差 ---------------------------------------------------

  /// 记账侧金额表达式（按 [metric] 口径）。
  /// 本位币口径 = `COALESCE(native_amount, amount)`，与账本总览统计同源。
  static String _recordedExpr(OriginalAmountMetric metric) =>
      metric == OriginalAmountMetric.native
          ? 'COALESCE(t.native_amount, t.amount)'
          : 't.amount';

  /// 原始侧金额表达式（按 [metric] 口径）。
  ///
  /// - 未填写 → 回落[同口径]记账金额（差异恒 0）；
  /// - 本位币口径 → 按该笔隐含汇率缩放（`original × native / amount`），
  ///   `amount = 0` 时汇率无从推断，保留原币值（不产生除零）。
  ///
  /// 与 Dart 侧 `TransactionOriginalAmountX.originalAmountOf` 逐字同义。
  static String _originalExpr(OriginalAmountMetric metric) {
    final rec = _recordedExpr(metric);
    if (metric == OriginalAmountMetric.currency) {
      return 'COALESCE(t.original_amount, t.amount)';
    }
    return 'CASE WHEN t.original_amount IS NULL THEN $rec '
        'WHEN t.amount = 0 THEN t.original_amount '
        'ELSE t.original_amount * $rec / t.amount END';
  }

  /// 差异表达式。基准 = 记账金额 → `原始 − 记账`；基准 = 原始金额 → 取反。
  static String _diffExpr(
      OriginalAmountMetric metric, OriginalAmountBasis basis) {
    final rec = _recordedExpr(metric);
    final ori = _originalExpr(metric);
    return basis == OriginalAmountBasis.recorded
        ? '($ori - $rec)'
        : '($rec - $ori)';
  }

  /// SQLite 聚合值安全转 int（COUNT/SUM 可能给 int 或 BigInt）。
  static int _i(dynamic v) =>
      v is num ? v.toInt() : (v is BigInt ? v.toInt() : 0);

  /// SQLite 聚合值安全转 double。
  static double _f(dynamic v) =>
      v is num ? v.toDouble() : (v is BigInt ? v.toDouble() : 0.0);

  @override
  Future<({
    int total,
    int deviated,
    double diffSum,
    double absDiffSum,
    double maxAbsDiff,
  })> originalAmountDiffSummary({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  }) async {
    final diff = _diffExpr(metric, basis);
    final row = await db.customSelect(
      'SELECT COUNT(*) AS total, '
      // deviated：差异非零的明细数。0.005 半分钱容差吸收 REAL 浮点噪声，
      // 不与"金额精度到分"的业务语义冲突。
      'COALESCE(SUM(CASE WHEN ABS($diff) > 0.005 THEN 1 ELSE 0 END), 0) AS deviated, '
      'COALESCE(SUM($diff), 0) AS diff_sum, '
      'COALESCE(SUM(ABS($diff)), 0) AS abs_diff_sum, '
      'COALESCE(MAX(ABS($diff)), 0) AS max_abs_diff '
      'FROM transactions t '
      'WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?3 AND t.happened_at < ?4',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();
    final data = row.data;
    return (
      total: _i(data['total']),
      deviated: _i(data['deviated']),
      diffSum: _f(data['diff_sum']),
      absDiffSum: _f(data['abs_diff_sum']),
      maxAbsDiff: _f(data['max_abs_diff']),
    );
  }

  @override
  Future<
      List<
          ({
            DateTime bucket,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffTrend({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required String granularity,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  }) async {
    final diff = _diffExpr(metric, basis);
    // 桶表达式白名单拼接（三个字面量，非用户输入，无注入面）。
    // ponytail: 按自然日历分组，不套账本 monthStartDay 标签 —— 偏差趋势
    // 看的是"何时开始偏"，起点平移不改变形状。要与报表月严格对账时，
    // 再复用 _monthStartDayOf 的 CASE 分支即可。
    final bucketExpr = switch (granularity) {
      'month' =>
        "strftime('%Y-%m', t.happened_at, 'unixepoch', 'localtime')",
      'year' => "strftime('%Y', t.happened_at, 'unixepoch', 'localtime')",
      _ => "date(t.happened_at, 'unixepoch', 'localtime')",
    };
    final rows = await db.customSelect(
      'SELECT $bucketExpr AS bucket, '
      'COALESCE(SUM(CASE WHEN ABS($diff) > 0.005 THEN 1 ELSE 0 END), 0) AS deviated, '
      'COALESCE(SUM($diff), 0) AS diff_sum, '
      'COALESCE(SUM(ABS($diff)), 0) AS abs_diff_sum '
      'FROM transactions t '
      'WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?3 AND t.happened_at < ?4 '
      'GROUP BY bucket ORDER BY bucket',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    final raw = <String, ({int deviated, double diffSum, double absDiffSum})>{
      for (final r in rows)
        r.read<String>('bucket'): (
          deviated: _i(r.data['deviated']),
          diffSum: _f(r.data['diff_sum']),
          absDiffSum: _f(r.data['abs_diff_sum']),
        ),
    };

    String keyOf(DateTime b) {
      final y = b.year.toString().padLeft(4, '0');
      if (granularity == 'year') return y;
      final m = b.month.toString().padLeft(2, '0');
      if (granularity == 'month') return '$y-$m';
      return '$y-$m-${b.day.toString().padLeft(2, '0')}';
    }

    final out = <({
      DateTime bucket,
      int deviated,
      double diffSum,
      double absDiffSum,
    })>[];
    void push(DateTime b) {
      final hit = raw[keyOf(b)];
      out.add((
        bucket: b,
        deviated: hit?.deviated ?? 0,
        diffSum: hit?.diffSum ?? 0,
        absDiffSum: hit?.absDiffSum ?? 0,
      ));
    }

    // 补零：桶连续，折线/柱状图不断线（与 totalsByDay 的补零理由一致）。
    if (granularity == 'year') {
      for (var y = start.year; y <= end.year; y++) {
        push(DateTime(y));
      }
    } else if (granularity == 'month') {
      var m = DateTime(start.year, start.month);
      final last = DateTime(end.year, end.month);
      while (!m.isAfter(last)) {
        push(m);
        m = DateTime(m.year, m.month + 1);
      }
    } else {
      for (var dd = DateTime(start.year, start.month, start.day);
          dd.isBefore(end);
          dd = dd.add(const Duration(days: 1))) {
        push(dd);
      }
    }
    return out;
  }

  @override
  Future<
      List<
          ({
            int? categoryId,
            String? categoryName,
            String? categoryIcon,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffByCategory({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  }) async {
    final diff = _diffExpr(metric, basis);
    // 未填写的原始金额在保存/迁移时已兜底为记账金额（差异 0），
    // HAVING 直接滤掉零偏差分类 —— 无需再判 NULL。
    // ponytail: 共享账本 Editor 行(category_id 空)会落到 null 桶、名称走
    // UI 的「未分类」；要精确显示 Owner 分类名时再按 existing
    // totalsByCategory 的做法接 categorySyncIdOverride 兜底。
    final rows = await db.customSelect(
      'SELECT t.category_id AS cid, c.name AS cname, c.icon AS cicon, '
      'COALESCE(SUM(CASE WHEN ABS($diff) > 0.005 THEN 1 ELSE 0 END), 0) AS deviated, '
      'COALESCE(SUM($diff), 0) AS diff_sum, '
      'COALESCE(SUM(ABS($diff)), 0) AS abs_diff_sum '
      'FROM transactions t '
      'LEFT JOIN categories c ON c.id = t.category_id '
      'WHERE t.ledger_id = ?1 AND t.type = ?2 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?3 AND t.happened_at < ?4 '
      'GROUP BY t.category_id '
      'HAVING abs_diff_sum > 0',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions, db.categories},
    ).get();
    return rows
        .map((r) => (
              categoryId: r.data['cid'] == null ? null : _i(r.data['cid']),
              categoryName: r.read<String?>('cname'),
              categoryIcon: r.read<String?>('cicon'),
              deviated: _i(r.data['deviated']),
              diffSum: _f(r.data['diff_sum']),
              absDiffSum: _f(r.data['abs_diff_sum']),
            ))
        .toList();
  }

  @override
  Future<
      List<
          ({
            int ledgerId,
            int deviated,
            double diffSum,
            double absDiffSum,
          })>> originalAmountDiffByLedger({
    required String type,
    required DateTime start,
    required DateTime end,
    required OriginalAmountMetric metric,
    required OriginalAmountBasis basis,
  }) async {
    final diff = _diffExpr(metric, basis);
    final rows = await db.customSelect(
      'SELECT t.ledger_id AS lid, '
      'COALESCE(SUM(CASE WHEN ABS($diff) > 0.005 THEN 1 ELSE 0 END), 0) AS deviated, '
      'COALESCE(SUM($diff), 0) AS diff_sum, '
      'COALESCE(SUM(ABS($diff)), 0) AS abs_diff_sum '
      'FROM transactions t '
      'WHERE t.type = ?1 AND t.exclude_from_stats = 0 '
      'AND t.happened_at >= ?2 AND t.happened_at < ?3 '
      'GROUP BY lid '
      'HAVING abs_diff_sum > 0',
      variables: [
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    return rows
        .map((r) => (
              ledgerId: _i(r.data['lid']),
              deviated: _i(r.data['deviated']),
              diffSum: _f(r.data['diff_sum']),
              absDiffSum: _f(r.data['abs_diff_sum']),
            ))
        .toList();
  }

  @override
  Future<List<({String type, double nativeAmount, String? customValuesJson})>>
      customFieldStatsRows({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    final rows = await db.customSelect(
      'SELECT type AS type, '
      'COALESCE(native_amount, amount) AS total, '
      'custom_values_json AS custom_values_json '
      'FROM transactions '
      'WHERE ledger_id = ?1 AND exclude_from_stats = 0 '
      'AND custom_values_json IS NOT NULL '
      'AND happened_at >= ?2 AND happened_at < ?3',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).get();
    return rows
        .map((r) => (
              type: r.read<String>('type'),
              nativeAmount: _f(r.data['total']),
              customValuesJson: r.readNullable<String>('custom_values_json'),
            ))
        .toList();
  }
}
