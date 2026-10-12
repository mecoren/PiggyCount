import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../budget_repository.dart';
import '../../../utils/month_range.dart';

const _uuid = Uuid();

/// 本地预算Repository实现
/// 基于 Drift 数据库实现
///
/// 这里 NOT 直接调 changeTracker;changeTracker 的注入是通过 LocalRepository
/// 包装层(lib/data/repositories/local/local_repository.dart)在 CRUD 前后
/// 统一 recordChange,保持跟 transaction / account 的代码结构一致。
class LocalBudgetRepository implements BudgetRepository {
  final PiggyDatabase db;

  LocalBudgetRepository(this.db);

  /// 读取账本的自定义每月起始日(1-28);账本缺失或查询异常时按 1(自然月)降级。
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

  // ============================================
  // 基础 CRUD 操作
  // ============================================

  @override
  Future<int> createBudget({
    required int ledgerId,
    required String type,
    int? categoryId,
    required double amount,
    String period = 'monthly',
    int startDay = 1,
    String? syncId,
    bool enabled = true,
  }) async {
    // 每条新建预算分配一个 UUID,跨设备 LWW 用。syncId 在 DB schema 上允许
    // NULL,只是为了 v22 migration 对老数据兼容;新建走这里永远填
    // (导入路径显式传快照里的 syncId,保持跨设备身份一致)。
    return await db.into(db.budgets).insert(
      BudgetsCompanion.insert(
        ledgerId: ledgerId,
        type: d.Value(type),
        categoryId: d.Value(categoryId),
        amount: amount,
        period: d.Value(period),
        startDay: d.Value(startDay),
        // 恢复/导入路径显式传快照里的 enabled（默认 true 仅服务本地新建）
        enabled: d.Value(enabled),
        syncId: d.Value(syncId ?? _uuid.v4()),
      ),
    );
  }

  @override
  Future<void> updateBudget(
    int id, {
    double? amount,
    int? startDay,
    bool? enabled,
    String? syncId,
  }) async {
    await (db.update(db.budgets)..where((b) => b.id.equals(id))).write(
      BudgetsCompanion(
        amount: amount != null ? d.Value(amount) : const d.Value.absent(),
        startDay: startDay != null ? d.Value(startDay) : const d.Value.absent(),
        enabled: enabled != null ? d.Value(enabled) : const d.Value.absent(),
        // 仅显式传入时回填（导入按业务键命中后补身份锚点），
        // null → absent 避免清掉已有 syncId。
        syncId: syncId != null ? d.Value(syncId) : const d.Value.absent(),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<void> deleteBudget(int id) async {
    // 先获取预算信息，判断是否为总预算
    final budget = await (db.select(db.budgets)
          ..where((b) => b.id.equals(id)))
        .getSingleOrNull();

    if (budget == null) return;

    if (budget.type == 'total') {
      // 删除总预算时，同时删除该账本的所有分类预算
      await (db.delete(db.budgets)
            ..where((b) => b.ledgerId.equals(budget.ledgerId)))
          .go();
    } else {
      // 删除单个分类预算
      await (db.delete(db.budgets)..where((b) => b.id.equals(id))).go();
    }
  }

  @override
  Future<Budget?> getTotalBudget(int ledgerId) async {
    // 使用 .get() 然后取第一个，避免多条脏数据时报错
    final budgets = await (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(ledgerId) & b.type.equals('total') & b.enabled.equals(true))
          ..orderBy([(b) => d.OrderingTerm(expression: b.createdAt)]))
        .get();
    return budgets.firstOrNull;
  }

  @override
  Future<List<Budget>> getCategoryBudgets(int ledgerId) async {
    return await (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(ledgerId) & b.type.equals('category') & b.enabled.equals(true)))
        .get();
  }

  @override
  Future<Budget?> getBudgetByCategory(int ledgerId, int categoryId) async {
    return await (db.select(db.budgets)
          ..where((b) =>
              b.ledgerId.equals(ledgerId) &
              b.type.equals('category') &
              b.categoryId.equals(categoryId) &
              b.enabled.equals(true)))
        .getSingleOrNull();
  }

  @override
  Future<List<Budget>> getAllBudgets(int ledgerId) async {
    return await (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(ledgerId))
          ..orderBy([
            (b) => d.OrderingTerm(expression: b.type),
            (b) => d.OrderingTerm(expression: b.createdAt),
          ]))
        .get();
  }

  @override
  Future<List<Budget>> getAllBudgetsForExport() async {
    return await (db.select(db.budgets)
          ..orderBy([
            (b) => d.OrderingTerm(expression: b.ledgerId),
            (b) => d.OrderingTerm(expression: b.type),
            (b) => d.OrderingTerm(expression: b.createdAt),
          ]))
        .get();
  }

  // ============================================
  // 预算统计
  // ============================================

  @override
  Future<BudgetUsage> getBudgetUsage(int budgetId, DateTime month) async {
    final budget = await (db.select(db.budgets)
          ..where((b) => b.id.equals(budgetId)))
        .getSingleOrNull();

    if (budget == null) {
      return BudgetUsage(used: 0, budget: 0);
    }

    // 预算周期跟随账本 monthStartDay(设计 D5:budget.startDay 弃用,列保留
    // 兼容历史同步数据)。month 参数语义 = 「包含该日期的周期」,调用方传 now
    // (见 budget_providers.dart)。
    final sd = await _monthStartDayOf(budget.ledgerId);
    final range = periodContaining(month, sd);
    final startDate = range.start;
    final endDate = range.end;

    // 查询该周期内的支出
    double used = 0;
    if (budget.type == 'total') {
      // 总预算：统计所有支出
      //
      // v56 退款回补（F1-b，prd/refund_reimbursement R3）：把「关联了原交易
      // 的收入行（refund_of_id 非空）」按负值冲减 used。口径：
      // - 只认**退款行自身 category_id / 全局归属**，不 join 原交易分类；
      // - 跨月按**退款发生月**冲减（本查询按周期过滤，天然成立）；
      // - exclude_from_budget = 1 的退款行不冲减（用户显式排除的不冲，
      //   与支出侧排除语义对称）；
      // - **被引原交易必须仍存在于 transactions**（EXISTS 守卫）：原交易
      //   软删进行政归档 / 彻底 purge / 合并时只勾了退款行 → 原支出已不计
      //   用量，退款再冲减会把用量做成负数，语义倒挂；
      // - 存量数据 refund_of_id 全为 NULL → 冲减项恒 0 → 行为逐位不变。
      final result = await db.customSelect(
        '''
        SELECT
          COALESCE(SUM(CASE WHEN type = 'expense' AND exclude_from_budget = 0
                            THEN COALESCE(native_amount, amount) ELSE 0 END), 0)
          - COALESCE(SUM(CASE WHEN type = 'income'
                                   AND refund_of_id IS NOT NULL
                                   AND exclude_from_budget = 0
                                   AND EXISTS (SELECT 1 FROM transactions o
                                               WHERE o.id = transactions.refund_of_id)
                              THEN COALESCE(native_amount, amount) ELSE 0 END), 0)
          AS total
        FROM transactions
        WHERE ledger_id = ?
          AND happened_at >= ?
          AND happened_at < ?
          AND type IN ('expense', 'income')
        ''',
        variables: [
          d.Variable.withInt(budget.ledgerId),
          d.Variable.withDateTime(startDate),
          d.Variable.withDateTime(endDate),
        ],
        readsFrom: {db.transactions},
      ).getSingle();
      used = _parseDouble(result.data['total']);
    } else {
      // 分类预算：统计该分类支出（包含子分类）
      //
      // v56 退款回补（F1-b）：同总预算口径 —— 冲减只认**退款行自身
      // category_id**（或其父分类），用户想把退款算到哪个分类就记到哪个
      // 分类；未选分类的退款行不进任何分类预算的冲减；被引原交易必须仍
      // 存在于 transactions（EXISTS 守卫，理由同总预算处）。
      final result = await db.customSelect(
        '''
        SELECT
          COALESCE(SUM(CASE WHEN t.type = 'expense' AND t.exclude_from_budget = 0
                            THEN COALESCE(t.native_amount, t.amount) ELSE 0 END), 0)
          - COALESCE(SUM(CASE WHEN t.type = 'income'
                                   AND t.refund_of_id IS NOT NULL
                                   AND t.exclude_from_budget = 0
                                   AND EXISTS (SELECT 1 FROM transactions o
                                               WHERE o.id = t.refund_of_id)

                              THEN COALESCE(t.native_amount, t.amount) ELSE 0 END), 0)
          AS total
        FROM transactions t
        LEFT JOIN categories c ON t.category_id = c.id
        WHERE t.ledger_id = ?
          AND t.happened_at >= ?
          AND t.happened_at < ?
          AND t.type IN ('expense', 'income')
          AND (t.category_id = ? OR c.parent_id = ?)
        ''',
        variables: [
          d.Variable.withInt(budget.ledgerId),
          d.Variable.withDateTime(startDate),
          d.Variable.withDateTime(endDate),
          d.Variable.withInt(budget.categoryId!),
          d.Variable.withInt(budget.categoryId!),
        ],
        readsFrom: {db.transactions, db.categories},
      ).getSingle();
      used = _parseDouble(result.data['total']);
    }

    return BudgetUsage(used: used, budget: budget.amount);
  }

  @override
  Future<BudgetOverview> getBudgetOverview(int ledgerId, DateTime month) async {
    // 获取总预算
    final totalBudget = await getTotalBudget(ledgerId);
    BudgetUsage? totalUsage;

    if (totalBudget != null) {
      totalUsage = await getBudgetUsage(totalBudget.id, month);
    }

    // 获取分类预算使用情况
    final categoryUsages = await getCategoryBudgetUsages(ledgerId, month);

    // 计算剩余天数(周期跟随账本 monthStartDay,与 getBudgetUsage 同口径)
    final now = DateTime.now();
    final sd = await _monthStartDayOf(ledgerId);
    final period = periodContaining(now, sd);
    final endDate = period.end;
    final daysRemaining = endDate.difference(now).inDays;

    // 计算日均可用
    final remaining = totalUsage?.remaining ?? 0;
    final dailyAvailable = daysRemaining > 0 ? remaining / daysRemaining : 0.0;

    return BudgetOverview(
      totalBudget: totalUsage,
      categoryBudgets: categoryUsages,
      daysRemaining: daysRemaining > 0 ? daysRemaining : 0,
      dailyAvailable: dailyAvailable > 0 ? dailyAvailable : 0,
      // 本地计算字段(不进快照):预算超支推送用它做「同周期只推一次」的水位 key
      periodStart: period.start,
      periodEnd: period.end,
    );
  }

  @override
  Future<List<CategoryBudgetUsage>> getCategoryBudgetUsages(
    int ledgerId,
    DateTime month,
  ) async {
    final budgets = await getCategoryBudgets(ledgerId);
    final result = <CategoryBudgetUsage>[];

    for (final budget in budgets) {
      if (budget.categoryId == null) continue;

      // 获取分类信息
      final category = await (db.select(db.categories)
            ..where((c) => c.id.equals(budget.categoryId!)))
          .getSingleOrNull();

      if (category == null) continue;

      // 获取使用情况
      final usage = await getBudgetUsage(budget.id, month);

      result.add(CategoryBudgetUsage(
        budgetId: budget.id,
        categoryId: category.id,
        categoryName: category.name,
        categoryIcon: category.icon,
        // 透传完整 Category 给 UI,让 CategoryBudgetTile 能用 CategoryIconWidget
        // 渲染 iconType='custom' 的自定义图片图标(只有 categoryIcon 字符串时
        // 走 CategoryService.getCategoryIcon switch,自定义路径会兜底成
        // Icons.category 通用占位 — 这是用户报"分类预算图标不正确"的根因)。
        category: category,
        usage: usage,
      ));
    }

    // 按使用率降序排列
    result.sort((a, b) => b.usage.rate.compareTo(a.usage.rate));

    return result;
  }

  // ============================================
  // 监听
  // ============================================

  @override
  Stream<List<Budget>> watchBudgets(int ledgerId) {
    return (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(ledgerId))
          ..orderBy([
            (b) => d.OrderingTerm(expression: b.type),
            (b) => d.OrderingTerm(expression: b.createdAt),
          ]))
        .watch();
  }

  // ============================================
  // 辅助方法
  // ============================================

  double _parseDouble(dynamic v) {
    if (v == null) return 0.0;
    if (v is double) return v;
    if (v is int) return v.toDouble();
    if (v is num) return v.toDouble();
    return 0.0;
  }
}
