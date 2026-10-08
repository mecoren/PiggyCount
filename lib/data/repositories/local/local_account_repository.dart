import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../services/system/logger_service.dart';
import '../../../utils/account_type_utils.dart';
import '../../../utils/holding_metrics.dart';
import '../account_repository.dart';
import '../exceptions.dart';

/// 本地账户Repository实现
/// 基于 Drift 数据库实现
class LocalAccountRepository implements AccountRepository {
  static const _uuid = Uuid();
  final PiggyDatabase db;

  /// 持仓多币种折算所需的汇率解析器（币种大写 → 「1 单位该币种 = ? 单位基准」）。
  ///
  /// 由装配层注入（见 `lib/providers/holding_providers.dart`）；null 或返回空 map
  /// 时，只有「持仓币种 == 账户币种」的持仓计入，其余整条剔除 —— 与既有
  /// 「缺汇率整条剔除、绝不按 1.0 裸加」口径一致（D5 红线）。
  HoldingsRateResolver? holdingsRateResolver;

  LocalAccountRepository(this.db, {this.holdingsRateResolver});

  // =====================================================================
  // v52 投资持仓 → 账户金额的口径单点化
  //
  // 规则（唯一口径，四类调用点全部走这里）：
  //   估值型账户 + **有持仓** → 账户金额 = Σ(份额 × 生效净值) 折算到账户币种；
  //   估值型账户 + **无持仓** → initialBalance（与 v52 之前逐字一致）。
  // 因此「删光持仓即自动回退手填估值」，可逆、不双计。
  //
  // 覆盖的调用点（**穷举**，v52 评审时逐个核过；新增口径时必须回到这里登记）：
  //   - getAccountBalance / getAccountGlobalBalance / getAccountDailyBalances
  //   - getAllAccountBalances / getAllAccountStats（两者都是批量 SQL，各自显式
  //     套用 _valuationAmount；getAllAccountStats 曾经漏改，会让账户总列表卡
  //     显示 initialBalance 而详情页显示持仓市值）
  //   - 上层口径 getNetWorthBreakdown / getNetWorthBreakdownByCurrency /
  //     getNetWorthDailyBalances / getNetWorthTrendSeries /
  //     getAssetCompositionByType / getAssetCompositionByTypeAndCurrency
  //     全部建立在 getAccountBalance / getAccountDailyBalances 之上，自动生效。
  // ⚠️ 新增净值口径时不要绕过上面的方法自己算，否则持仓会被漏掉。
  // =====================================================================

  /// 按账户汇总持仓市值（已折算到**各账户自己的币种**）。
  ///
  /// [onlyAccountId] 为空时一次读全表 —— 净资产趋势是「账户数 × 天数」的双层
  /// 循环，逐账户回查会把它放大成 N 倍查询；批量路径请一次取全量后在内存里索引。
  /// 账户已被删（悬空 account_id）的持仓不计入，避免幽灵金额。
  Future<Map<int, HoldingsValueSummary>> _holdingsSummaryByAccount(
      {int? onlyAccountId}) async {
    final query = db.select(db.holdings);
    if (onlyAccountId != null) {
      query.where((h) => h.accountId.equals(onlyAccountId));
    }
    final holdings = await query.get();
    if (holdings.isEmpty) return const {};

    final currencyById = {
      for (final a in await getAllAccounts()) a.id: a.currency,
    };
    final grouped = <int, List<HoldingValueInput>>{};
    for (final h in holdings) {
      if (!currencyById.containsKey(h.accountId)) continue;
      // 生效价判定走 holding_metrics 的唯一定点（与 UI 共用，见其文档注释）
      grouped.putIfAbsent(h.accountId, () => []).add(holdingValueInputOf(h));
    }
    if (grouped.isEmpty) return const {};

    final rates =
        await holdingsRateResolver?.call() ?? const <String, double>{};
    return {
      for (final e in grouped.entries)
        e.key: summarizeHoldings(
          holdings: e.value,
          accountCurrency: currencyById[e.key]!,
          ratesToBase: rates,
        ),
    };
  }

  /// 估值型账户的**有效金额**：有持仓 → 持仓折算市值合计，否则 → initialBalance。
  static double _valuationAmount(
    Account account,
    Map<int, HoldingsValueSummary> holdingsByAccount,
  ) {
    final summary = holdingsByAccount[account.id];
    if (summary == null || summary.total == 0) return account.initialBalance;
    return summary.marketValue;
  }

  /// 单账户版便捷入口（给逐账户调用点用）。
  Future<double> _effectiveValuation(Account account) async {
    final summary =
        await _holdingsSummaryByAccount(onlyAccountId: account.id);
    return _valuationAmount(account, summary);
  }

  @override
  Stream<List<Account>> watchAccountsForLedger(int ledgerId) {
    return (db.select(db.accounts)..where((a) => a.ledgerId.equals(ledgerId)))
        .watch();
  }

  @override
  Stream<List<Account>> watchAllAccounts() {
    return (db.select(db.accounts)
          ..orderBy([
            (a) => d.OrderingTerm(expression: a.type),
            (a) => d.OrderingTerm(expression: a.sortOrder),
          ]))
        .watch();
  }

  @override
  Future<List<Account>> getAllAccounts() async {
    return await (db.select(db.accounts)
          ..orderBy([
            (a) => d.OrderingTerm(expression: a.type),
            (a) => d.OrderingTerm(expression: a.sortOrder),
          ]))
        .get();
  }

  @override
  Future<Account?> getAccount(int accountId) async {
    return await (db.select(db.accounts)..where((a) => a.id.equals(accountId)))
        .getSingleOrNull();
  }

  @override
  Future<List<Account>> getAvailableAccountsForLedger(int ledgerId) async {
    // 获取账本信息
    final ledger = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingle();

    // 通过币种过滤账户
    return await (db.select(db.accounts)
          ..where((a) => a.currency.equals(ledger.currency)))
        .get();
  }

  @override
  Future<List<Account>> getAccountsByCurrency(String currency) async {
    return await (db.select(db.accounts)
          ..where((a) => a.currency.equals(currency)))
        .get();
  }

  @override
  Future<Map<String, List<Account>>> getAccountsGroupedByCurrency() async {
    final allAccounts = await getAllAccounts();
    final Map<String, List<Account>> grouped = {};

    for (final account in allAccounts) {
      grouped.putIfAbsent(account.currency, () => []).add(account);
    }

    return grouped;
  }

  @override
  Future<int> createAccount({
    required int ledgerId,
    required String name,
    String type = 'cash',
    String currency = 'CNY',
    double initialBalance = 0.0,
    double? creditLimit,
    int? billingDay,
    int? paymentDueDay,
    String? bankName,
    String? cardLastFour,
    String? note,
    String? syncId,
  }) async {
    // 撞同名抛 DuplicateNameException(name 全局唯一)。静默路径(import /
    // app-link 等)请改用 [upsertAccount]。
    final existingByName =
        await (db.select(db.accounts)..where((a) => a.name.equals(name))).get();
    if (existingByName.isNotEmpty) {
      throw DuplicateNameException(
        entityType: 'account',
        name: name,
        existingId: existingByName.first.id,
      );
    }
    try {
      // 计算同类型最大 sortOrder + 1
      final maxSortOrderResult = await db.customSelect(
        'SELECT COALESCE(MAX(sort_order), -1) AS max_order FROM accounts WHERE type = ?1',
        variables: [d.Variable.withString(type)],
        readsFrom: {db.accounts},
      ).getSingle();
      final nextSortOrder = (maxSortOrderResult.data['max_order'] as int) + 1;

      final companion = AccountsCompanion.insert(
        ledgerId: ledgerId,
        name: name,
        type: d.Value(type),
        currency: d.Value(currency),
        initialBalance: d.Value(initialBalance),
        createdAt: d.Value(DateTime.now()),
        sortOrder: d.Value(nextSortOrder),
        creditLimit: d.Value(creditLimit),
        billingDay: d.Value(billingDay),
        paymentDueDay: d.Value(paymentDueDay),
        bankName: d.Value(bankName),
        cardLastFour: d.Value(cardLastFour),
        note: d.Value(note),
        syncId: d.Value(syncId ?? _uuid.v4()),
      );

      final id = await db.into(db.accounts).insert(companion);
      // 单条 INFO 日志(import 批量场景下 3 条/账户 会把 logger 队列冲爆,降级
      // 到 debug;只在出错时 error)
      logger.debug('AccountCreate', '账户创建: id=$id name=$name type=$type');
      return id;
    } catch (e, stack) {
      logger.error('AccountCreate', '创建账户失败 name=$name', e, stack);
      rethrow;
    }
  }

  @override
  Future<int> upsertAccount({
    required String name,
    int ledgerId = 0,
    String type = 'cash',
    String currency = 'CNY',
    double initialBalance = 0.0,
  }) async {
    final existing =
        await (db.select(db.accounts)..where((a) => a.name.equals(name))).get();
    if (existing.isNotEmpty) return existing.first.id;
    // 复用 createAccount(此时 name 不冲突,不会抛)
    return createAccount(
      ledgerId: ledgerId,
      name: name,
      type: type,
      currency: currency,
      initialBalance: initialBalance,
    );
  }

  @override
  Future<void> updateAccount(
    int id, {
    String? name,
    String? type,
    String? currency,
    double? initialBalance,
    double? creditLimit,
    int? billingDay,
    int? paymentDueDay,
    bool clearCreditCardFields = false,
    String? bankName,
    String? cardLastFour,
    String? note,
    bool clearMetadataFields = false,
    bool? hidden,
    String? syncId,
  }) async {
    await (db.update(db.accounts)..where((a) => a.id.equals(id))).write(
      AccountsCompanion(
        name: name != null ? d.Value(name) : const d.Value.absent(),
        type: type != null ? d.Value(type) : const d.Value.absent(),
        currency: currency != null ? d.Value(currency) : const d.Value.absent(),
        initialBalance: initialBalance != null
            ? d.Value(initialBalance)
            : const d.Value.absent(),
        creditLimit: clearCreditCardFields
            ? const d.Value(null)
            : (creditLimit != null
                ? d.Value(creditLimit)
                : const d.Value.absent()),
        billingDay: clearCreditCardFields
            ? const d.Value(null)
            : (billingDay != null
                ? d.Value(billingDay)
                : const d.Value.absent()),
        paymentDueDay: clearCreditCardFields
            ? const d.Value(null)
            : (paymentDueDay != null
                ? d.Value(paymentDueDay)
                : const d.Value.absent()),
        bankName: clearMetadataFields
            ? const d.Value(null)
            : (bankName != null ? d.Value(bankName) : const d.Value.absent()),
        cardLastFour: clearMetadataFields
            ? const d.Value(null)
            : (cardLastFour != null
                ? d.Value(cardLastFour)
                : const d.Value.absent()),
        note: clearMetadataFields
            ? const d.Value(null)
            : (note != null ? d.Value(note) : const d.Value.absent()),
        hidden: hidden == null ? const d.Value.absent() : d.Value(hidden),
        // 仅回填,不清空:老账户恢复快照时收敛跨设备身份
        syncId: syncId != null ? d.Value(syncId) : const d.Value.absent(),
      ),
    );
  }

  @override
  Future<void> setAccountHidden(int id, bool hidden) =>
      updateAccount(id, hidden: hidden);

  @override
  Future<List<Account>> getCreditCardAccounts() async {
    return await (db.select(db.accounts)
          ..where((a) => a.type.equals('credit_card'))
          ..orderBy([(a) => d.OrderingTerm(expression: a.sortOrder)]))
        .get();
  }

  @override
  Future<double> getCreditCardUsedAmount(int accountId) async {
    // 已用额度 = -balance（余额为负表示欠款）
    final balance = await getAccountBalance(accountId);
    return balance < 0 ? -balance : 0.0;
  }

  @override
  Future<void> deleteAccount(int id) async {
    await (db.delete(db.accounts)..where((a) => a.id.equals(id))).go();
  }

  @override
  Future<double> getAccountBalance(int accountId) async {
    // 获取账户初始资金
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingleOrNull();

    if (account == null) return 0.0;

    // 估值账户：有持仓 → Σ 持仓市值（折算到账户币种）；无持仓 → initialBalance。
    if (isValuationOnlyType(account.type)) {
      return _effectiveValuation(account);
    }

    // SQL 聚合版(此前全量拉行进内存逐条累加,大账户万行级内存与延迟)。
    // 口径与旧实现/getAllAccountStats 逐字一致:不排除 excludeFromStats;
    // balance = initial + income − expense − 转出 transfer + adjustment +
    // 转入 transfer。
    final rows = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE type WHEN 'income' THEN amount ELSE 0 END), 0) AS main_income, "
      "COALESCE(SUM(CASE type WHEN 'expense' THEN amount ELSE 0 END), 0) AS main_expense, "
      "COALESCE(SUM(CASE type WHEN 'transfer' THEN amount ELSE 0 END), 0) AS main_transfer_out, "
      "COALESCE(SUM(CASE type WHEN 'adjustment' THEN amount ELSE 0 END), 0) AS main_adjustment "
      'FROM transactions '
      'WHERE account_id = ?1',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    final transferIn = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) AS transfer_in '
      'FROM transactions '
      "WHERE type = 'transfer' AND to_account_id = ?1",
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    return account.initialBalance +
        dval(rows.data['main_income']) -
        dval(rows.data['main_expense']) -
        dval(rows.data['main_transfer_out']) +
        dval(rows.data['main_adjustment']) +
        dval(transferIn.data['transfer_in']);
  }

  @override
  Future<double> getAccountGlobalBalance(int accountId) async {
    final account = await (db.select(db.accounts)
          ..where((a) => a.id.equals(accountId)))
        .getSingle();

    // 估值账户：有持仓 → Σ 持仓市值；无持仓 → initialBalance（同 getAccountBalance）。
    if (isValuationOnlyType(account.type)) {
      return _effectiveValuation(account);
    }

    // SQL 聚合版,口径与旧实现一致:跨全部账本;
    // 主账户侧收支/转出/调整 + 转入侧转账。
    final row = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE WHEN account_id = ?1 THEN ("
      "  CASE type "
      "    WHEN 'income' THEN amount "
      "    WHEN 'expense' THEN -amount "
      "    WHEN 'transfer' THEN -amount "
      "    WHEN 'adjustment' THEN amount "
      "    ELSE 0 END) ELSE 0 END), 0) AS main_delta, "
      "COALESCE(SUM(CASE WHEN to_account_id = ?1 AND type = 'transfer' "
      '  THEN amount ELSE 0 END), 0) AS transfer_in '
      'FROM transactions '
      'WHERE (account_id = ?1 OR to_account_id = ?1)',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    return account.initialBalance +
        dval(row.data['main_delta']) +
        dval(row.data['transfer_in']);
  }

  @override
  Future<double> getAccountBalanceInLedger(int accountId, int ledgerId) async {
    // SQL 聚合版,口径与旧实现一致:限定单个账本,主账户侧收支/转出/调整
    // + 转入侧转账(单账本维度按调用方指定的账本算)。
    final row = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE WHEN account_id = ?1 THEN ("
      "  CASE type "
      "    WHEN 'income' THEN amount "
      "    WHEN 'expense' THEN -amount "
      "    WHEN 'transfer' THEN -amount "
      "    WHEN 'adjustment' THEN amount "
      "    ELSE 0 END) ELSE 0 END), 0) AS main_delta, "
      "COALESCE(SUM(CASE WHEN to_account_id = ?1 AND type = 'transfer' "
      '  THEN amount ELSE 0 END), 0) AS transfer_in '
      'FROM transactions '
      'WHERE (account_id = ?1 OR to_account_id = ?1) AND ledger_id = ?2',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(ledgerId)],
      readsFrom: {db.transactions},
    ).getSingle();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    return dval(row.data['main_delta']) + dval(row.data['transfer_in']);
  }

  @override
  Future<Map<int, double>> getAllAccountBalances(int ledgerId) async {
    // SQL 聚合版(此前逐账户串行 getAccountBalance,N 账户 = N×2 条查询
    // 且每条全量拉行)。口径与 getAccountBalance 一致,估值账户由
    // initialBalance 分支给出。
    final rows = await db.customSelect(
      'SELECT '
      'a.id AS id, a.initial_balance AS initial_balance, '
      'COALESCE(b.main_income, 0) AS main_income, '
      'COALESCE(b.main_expense, 0) AS main_expense, '
      'COALESCE(b.main_transfer_out, 0) AS main_transfer_out, '
      'COALESCE(b.main_adjustment, 0) AS main_adjustment, '
      'COALESCE(t.transfer_in, 0) AS transfer_in '
      'FROM accounts a '
      'LEFT JOIN ('
      '  SELECT account_id AS aid, '
      "  SUM(CASE type WHEN 'income' THEN amount ELSE 0 END) AS main_income, "
      "  SUM(CASE type WHEN 'expense' THEN amount ELSE 0 END) AS main_expense, "
      "  SUM(CASE type WHEN 'transfer' THEN amount ELSE 0 END) AS main_transfer_out, "
      "  SUM(CASE type WHEN 'adjustment' THEN amount ELSE 0 END) AS main_adjustment "
      '  FROM transactions '
      '  WHERE account_id IS NOT NULL '
      '  GROUP BY account_id'
      ') b ON b.aid = a.id '
      'LEFT JOIN ('
      '  SELECT to_account_id AS tid, SUM(amount) AS transfer_in '
      "  FROM transactions WHERE type = 'transfer' AND to_account_id IS NOT NULL "
      '  GROUP BY to_account_id'
      ') t ON t.tid = a.id '
      'WHERE a.ledger_id = ?1',
      variables: [d.Variable.withInt(ledgerId)],
      readsFrom: {db.accounts, db.transactions},
    ).get();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    // 估值类型在 Dart 侧判定(单次拉齐,避免逐行回查)。
    final accounts = await (db.select(db.accounts)
          ..where((a) => a.ledgerId.equals(ledgerId)))
        .get();
    final accountById = {for (final a in accounts) a.id: a};
    final valuationIds = accounts
        .where((a) => isValuationOnlyType(a.type))
        .map((a) => a.id)
        .toSet();
    // 持仓一次全量预取后在内存里索引：本方法已经在做批量聚合，逐账户回查会把
    // 「批量」退化成 N 次查询（v52 加入持仓后的性能守线）。
    final holdingsByAccount = valuationIds.isEmpty
        ? const <int, HoldingsValueSummary>{}
        : await _holdingsSummaryByAccount();

    final Map<int, double> balances = {};
    for (final row in rows) {
      final id = row.read<int>('id');
      final initial = dval(row.data['initial_balance']);
      // 估值账户与 getAccountBalance 同口径:有持仓 → 持仓市值合计,否则 initialBalance。
      if (valuationIds.contains(id)) {
        final account = accountById[id];
        balances[id] =
            account == null ? initial : _valuationAmount(account, holdingsByAccount);
        continue;
      }
      balances[id] = initial +
          dval(row.data['main_income']) -
          dval(row.data['main_expense']) -
          dval(row.data['main_transfer_out']) +
          dval(row.data['main_adjustment']) +
          dval(row.data['transfer_in']);
    }
    return balances;
  }

  @override
  Future<int> getTransactionCountByAccount(int accountId) async {
    // 统计作为主账户的交易数
    final mainCount = await db.customSelect(
      'SELECT COUNT(*) AS count FROM transactions WHERE account_id = ?1',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    // 统计作为转入账户的交易数
    final toCount = await db.customSelect(
      'SELECT COUNT(*) AS count FROM transactions WHERE to_account_id = ?1',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    int parseCount(dynamic v) {
      if (v is int) return v;
      if (v is BigInt) return v.toInt();
      if (v is num) return v.toInt();
      return 0;
    }

    return parseCount(mainCount.data['count']) +
        parseCount(toCount.data['count']);
  }

  @override
  Future<double> getAccountExpense(int accountId) async {
    // SQL 聚合版,口径与旧实现/getAllAccountStats 一致:排除 excludeFromStats;
    // expense = 主账户 expense + 转出 transfer。
    final row = await db.customSelect(
      'SELECT COALESCE(SUM(amount), 0) AS expense '
      'FROM transactions '
      'WHERE account_id = ?1 AND exclude_from_stats = 0 '
      "AND type IN ('expense', 'transfer')",
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    return row.data['expense'] is num
        ? (row.data['expense'] as num).toDouble()
        : 0.0;
  }

  @override
  Future<double> getAccountIncome(int accountId) async {
    // SQL 聚合版,口径与旧实现/getAllAccountStats 一致:排除 excludeFromStats;
    // income = 主账户 income + 转入 transfer。
    final row = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE WHEN type = 'income' THEN amount ELSE 0 END), 0) AS income_main, "
      "COALESCE(SUM(CASE WHEN to_account_id = ?1 AND type = 'transfer' "
      '  THEN amount ELSE 0 END), 0) AS income_in '
      'FROM transactions '
      'WHERE (account_id = ?1 OR to_account_id = ?1) '
      'AND exclude_from_stats = 0',
      variables: [d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();
    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    return dval(row.data['income_main']) + dval(row.data['income_in']);
  }

  @override
  Future<({double balance, double expense, double income})> getAccountStats(
      int accountId) async {
    // 三个口径复用同一份聚合(getAccountBalance/Expense/Income 各自的 SQL
    // 已是聚合版,此处三次往返仍比旧的"全量拉行×5"快一个量级;口径一致性
    // 由 test/repositories/sql_aggregation_regression_test.dart 钉死)。
    final balance = await getAccountBalance(accountId);
    final expense = await getAccountExpense(accountId);
    final income = await getAccountIncome(accountId);
    return (balance: balance, expense: expense, income: income);
  }

  @override
  Future<Map<int, ({double balance, double expense, double income})>>
      getAllAccountStats() async {
    final accounts = await db.select(db.accounts).get();
    final valuationIds = accounts
        .where((a) => isValuationOnlyType(a.type))
        .map((a) => a.id)
        .toSet();

    // 单条聚合 SQL 同时算出所有账户的三个口径（此前逐账户串行 4-7 条查询，
    // 且每条全量加载行到内存再 Dart 累加）。口径与 getAccountBalance /
    // getAccountExpense / getAccountIncome 逐字对齐：
    // - balance：initialBalance + income − expense − 转出 transfer + adjustment
    //   + 转入 transfer（不排除 excludeFromStats）；
    // - expense：主账户 expense + 转出 transfer（排除 excludeFromStats）；
    // - income：主账户 income + 转入 transfer（排除 excludeFromStats）。
    // 估值账户无日常交易：金额走**持仓口径**（有持仓 → 持仓市值合计，否则
    // initialBalance），费用/收入恒 0。
    final rows = await db.customSelect(
      "SELECT a.id AS id, a.initial_balance AS initial_balance, "
      'COALESCE(b.main_income, 0) AS main_income, '
      'COALESCE(b.main_expense, 0) AS main_expense, '
      'COALESCE(b.main_transfer_out, 0) AS main_transfer_out, '
      'COALESCE(b.main_adjustment, 0) AS main_adjustment, '
      'COALESCE(t.transfer_in, 0) AS transfer_in, '
      'COALESCE(e.expense, 0) AS expense, '
      'COALESCE(im.income_main, 0) AS income_main, '
      'COALESCE(i.income, 0) AS income_in '
      'FROM accounts a '
      'LEFT JOIN ('
      '  SELECT account_id AS aid, '
      "  SUM(CASE type WHEN 'income' THEN amount ELSE 0 END) AS main_income, "
      "  SUM(CASE type WHEN 'expense' THEN amount ELSE 0 END) AS main_expense, "
      "  SUM(CASE type WHEN 'transfer' THEN amount ELSE 0 END) AS main_transfer_out, "
      "  SUM(CASE type WHEN 'adjustment' THEN amount ELSE 0 END) AS main_adjustment "
      '  FROM transactions '
      '  WHERE account_id IS NOT NULL '
      '  GROUP BY account_id'
      ') b ON b.aid = a.id '
      'LEFT JOIN ('
      '  SELECT to_account_id AS tid, SUM(amount) AS transfer_in '
      "  FROM transactions WHERE type = 'transfer' AND to_account_id IS NOT NULL "
      '  GROUP BY to_account_id'
      ') t ON t.tid = a.id '
      'LEFT JOIN ('
      '  SELECT account_id AS eid, SUM(amount) AS expense '
      '  FROM transactions '
      '  WHERE account_id IS NOT NULL AND exclude_from_stats = 0 '
      "  AND type IN ('expense', 'transfer') "
      '  GROUP BY account_id'
      ') e ON e.eid = a.id '
      'LEFT JOIN ('
      '  SELECT account_id AS iid, '
      "  SUM(CASE type WHEN 'income' THEN amount ELSE 0 END) AS income_main "
      "  FROM transactions WHERE account_id IS NOT NULL AND exclude_from_stats = 0 "
      '  GROUP BY account_id'
      ') im ON im.iid = a.id '
      'LEFT JOIN ('
      '  SELECT to_account_id AS tid2, SUM(amount) AS income '
      "  FROM transactions WHERE type = 'transfer' AND to_account_id IS NOT NULL "
      '  AND exclude_from_stats = 0 GROUP BY to_account_id'
      ') i ON i.tid2 = a.id',
      readsFrom: {db.accounts, db.transactions},
    ).get();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;

    // v52：估值账户的金额必须与 getAccountBalance / 净资产卡同口径（持仓市值
    // 接管），否则账户总列表卡与账户详情页会显示同一账户的两个不同金额。
    // 批量预取一次持仓，循环内零查询。
    final accountById = {for (final a in accounts) a.id: a};
    final holdingsByAccount = valuationIds.isEmpty
        ? const <int, HoldingsValueSummary>{}
        : await _holdingsSummaryByAccount();

    final Map<int, ({double balance, double expense, double income})> stats =
        {};
    for (final row in rows) {
      final id = row.read<int>('id');
      if (valuationIds.contains(id)) {
        final account = accountById[id];
        stats[id] = (
          balance: account == null
              ? dval(row.data['initial_balance'])
              : _valuationAmount(account, holdingsByAccount),
          expense: 0.0,
          income: 0.0,
        );
        continue;
      }
      stats[id] = (
        balance: dval(row.data['initial_balance']) +
            dval(row.data['main_income']) -
            dval(row.data['main_expense']) -
            dval(row.data['main_transfer_out']) +
            dval(row.data['main_adjustment']) +
            dval(row.data['transfer_in']),
        expense: dval(row.data['expense']),
        income: dval(row.data['income_main']) + dval(row.data['income_in']),
      );
    }
    return stats;
  }

  @override

  /// ⚠️ 多币种口径未处理:本方法跨所有账本/账户按 type 裸加 amount。当前
  /// 无 UI 消费(allAccountsTotalStatsProvider 是死代码),故不影响任何界面。
  /// 若将来接「全局总收支」卡片:这是跨账本汇总,正确口径是按各账户币种
  /// rate 折算到用户主币种(同净值卡 convertedNetWorth),**不是** nativeAmount
  /// (各账本本位币可能不同,nativeAmount 相加无意义)。届时须重写,勿直接
  /// 套账本维度的 nativeAmount 折算。
  Future<({double totalBalance, double totalExpense, double totalIncome})>
      getAllAccountsTotalStats() async {
    final accounts = await db.select(db.accounts).get();

    // 总余额 = 所有账户余额之和（转账不影响总余额）
    double totalBalance = 0.0;
    for (final account in accounts) {
      final balance = await getAccountBalance(account.id);
      totalBalance += balance;
    }

    // 总收入/支出：SQL 聚合版(此前把**全库**交易拉进 Dart 再按 type 累加)。
    // 口径逐字对齐旧实现：限定 account_id 非空且账户行仍存在（旧实现按
    // accountIds 集合过滤）、排除 excludeFromStats、只算 income/expense 两类
    // （transfer/adjustment 不进收支）。
    final totals = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE type WHEN 'income' THEN amount ELSE 0 END), 0) AS total_income, "
      "COALESCE(SUM(CASE type WHEN 'expense' THEN amount ELSE 0 END), 0) AS total_expense "
      'FROM transactions '
      'WHERE account_id IS NOT NULL AND exclude_from_stats = 0 '
      "AND type IN ('income', 'expense') "
      'AND account_id IN (SELECT id FROM accounts)',
      readsFrom: {db.transactions, db.accounts},
    ).getSingle();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    final totalIncome = dval(totals.data['total_income']);
    final totalExpense = dval(totals.data['total_expense']);

    return (
      totalBalance: totalBalance,
      totalExpense: totalExpense,
      totalIncome: totalIncome
    );
  }

  @override
  Future<Map<int, int>> getAccountUsageInLedgers(int accountId) async {
    final result = await db.customSelect(
      '''
      SELECT ledger_id, COUNT(*) as count
      FROM transactions
      WHERE account_id = ? OR to_account_id = ?
      GROUP BY ledger_id
      ''',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).get();

    final Map<int, int> usage = {};
    for (final row in result) {
      final ledgerId = row.data['ledger_id'] as int;
      final count = row.data['count'];

      int countInt = 0;
      if (count is int) {
        countInt = count;
      } else if (count is BigInt) {
        countInt = count.toInt();
      } else if (count is num) {
        countInt = count.toInt();
      }

      usage[ledgerId] = countInt;
    }

    return usage;
  }

  @override
  Future<int> migrateAccount({
    required int fromAccountId,
    required int toAccountId,
  }) async {
    final beforeCount = await getTransactionCountByAccount(fromAccountId);

    // 迁移作为主账户的交易
    await (db.update(db.transactions)
          ..where((t) => t.accountId.equals(fromAccountId)))
        .write(TransactionsCompanion(accountId: d.Value(toAccountId)));

    // 迁移作为转入账户的交易
    await (db.update(db.transactions)
          ..where((t) => t.toAccountId.equals(fromAccountId)))
        .write(TransactionsCompanion(toAccountId: d.Value(toAccountId)));

    // 周期规则同样引用账户（两列都可空，见 db.dart）。此前只搬交易，规则仍指向
    // 旧账户 —— 旧账户一旦被删就留下悬空引用，**且规则到期会持续生成新的悬空
    // 记录**。语义与交易完全一致，这里一并搬走。
    await (db.update(db.recurringTransactions)
          ..where((r) => r.accountId.equals(fromAccountId)))
        .write(RecurringTransactionsCompanion(accountId: d.Value(toAccountId)));
    await (db.update(db.recurringTransactions)
          ..where((r) => r.toAccountId.equals(fromAccountId)))
        .write(
            RecurringTransactionsCompanion(toAccountId: d.Value(toAccountId)));

    return beforeCount;
  }

  @override
  Future<bool> hasTransactions(int accountId) async {
    final count = await db.customSelect(
      'SELECT COUNT(*) as count FROM transactions WHERE account_id = ? OR to_account_id = ?',
      variables: [d.Variable.withInt(accountId), d.Variable.withInt(accountId)],
      readsFrom: {db.transactions},
    ).getSingle();

    final c = count.data['count'];
    if (c is int) return c > 0;
    if (c is BigInt) return c > BigInt.zero;
    if (c is num) return c > 0;
    return false;
  }

  @override
  Stream<Account?> watchAccount(int accountId) {
    return (db.select(db.accounts)..where((a) => a.id.equals(accountId)))
        .watchSingleOrNull();
  }

  @override
  Stream<List<Transaction>> watchAccountTransactions(int accountId) {
    return (db.select(db.transactions)
          ..where((t) =>
              t.accountId.equals(accountId) | t.toAccountId.equals(accountId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .watch();
  }

  @override
  Future<void> batchInsertAccounts(List<AccountsCompanion> accounts) async {
    await db.batch((batch) {
      batch.insertAll(db.accounts, accounts);
    });
  }

  @override
  Future<List<Account>> getAccountsByIds(List<int> accountIds) async {
    if (accountIds.isEmpty) return [];
    return await (db.select(db.accounts)..where((a) => a.id.isIn(accountIds)))
        .get();
  }

  @override
  Future<void> updateAccountSortOrders(
      List<({int id, int sortOrder})> updates) async {
    await db.transaction(() async {
      for (final update in updates) {
        await (db.update(db.accounts)..where((a) => a.id.equals(update.id)))
            .write(AccountsCompanion(sortOrder: d.Value(update.sortOrder)));
      }
    });
  }

  @override
  Future<List<Transaction>> getAccountTransactions(int accountId,
      {int limit = 50, int offset = 0, String? flow}) async {
    // flow 过滤按资金流向:支出视图含转出,收入视图含转入,null 为全部
    final where = switch (flow) {
      'expense' => "account_id = ?1 AND type IN ('expense', 'transfer')",
      'income' =>
        "(type = 'income' AND account_id = ?1) OR (type = 'transfer' AND to_account_id = ?1)",
      _ => 'account_id = ?1 OR to_account_id = ?1',
    };
    final results = await db.customSelect(
      '''
      SELECT * FROM transactions
      WHERE ($where)
      ORDER BY happened_at DESC
      LIMIT ?2 OFFSET ?3
      ''',
      variables: [
        d.Variable.withInt(accountId),
        d.Variable.withInt(limit),
        d.Variable.withInt(offset),
      ],
      readsFrom: {db.transactions},
    ).get();

    return results.map((row) {
      return Transaction(
        id: row.data['id'] as int,
        ledgerId: row.data['ledger_id'] as int,
        type: row.data['type'] as String,
        amount: (row.data['amount'] as num).toDouble(),
        categoryId: row.data['category_id'] as int?,
        accountId: row.data['account_id'] as int?,
        toAccountId: row.data['to_account_id'] as int?,
        happenedAt: DateTime.fromMillisecondsSinceEpoch(
            (row.data['happened_at'] as int) * 1000),
        note: row.data['note'] as String?,
        recurringId: row.data['recurring_id'] as int?,
        syncId: row.data['sync_id'] as String?,
        excludeFromStats: (row.data['exclude_from_stats'] as int? ?? 0) != 0,
        excludeFromBudget: (row.data['exclude_from_budget'] as int? ?? 0) != 0,
      );
    }).toList();
  }

  @override
  Future<List<({DateTime date, double balance})>> getAccountDailyBalances(
      int accountId,
      {required DateTime startDate,
      required DateTime endDate}) async {
    final account = await getAccount(accountId);
    if (account == null) return [];

    // 估值账户：每天返回固定的「有效估值」（有持仓 → 持仓市值合计，否则 initialBalance）。
    //
    // 口径说明（刻意的，不是缺陷）：手动估值没有历史快照，持仓市值只能按**当前值
    // 平铺**到整段区间 —— 这与 v52 之前估值账户「历史 = initialBalance 平铺」的
    // 语义完全一致。引入净值历史快照前，趋势图上估值账户就是一条水平线。
    if (isValuationOnlyType(account.type)) {
      final value = await _effectiveValuation(account);
      final result = <({DateTime date, double balance})>[];
      var currentDate =
          DateTime(startDate.year, startDate.month, startDate.day);
      final end = DateTime(endDate.year, endDate.month, endDate.day);
      while (!currentDate.isAfter(end)) {
        result.add((date: currentDate, balance: value));
        currentDate = currentDate.add(const Duration(days: 1));
      }
      return result;
    }

    // 获取 endDate **当天结束**之前的所有交易(按日期升序)。
    // endDate 语义是「含当天」:调用方(trendTodayAnchor)传当天 0 点,若用
    // <= endDate 会把当天发生的交易全部截掉 —— 趋势终点永远停在"昨晚为止",
    // 今天记的账不进趋势线。
    final endExclusive = DateTime(endDate.year, endDate.month, endDate.day)
        .add(const Duration(days: 1));
    final allTxs = await (db.select(db.transactions)
          ..where((t) =>
              t.accountId.equals(accountId) | t.toAccountId.equals(accountId))
          ..where((t) => t.happenedAt.isSmallerThanValue(endExclusive))
          // startDate 之前的行只要一个累计值，不再拉进内存（见下方 SQL 基线）
          ..where((t) => t.happenedAt.isBiggerOrEqualValue(startDate))
          ..orderBy([(t) => d.OrderingTerm(expression: t.happenedAt)]))
        .get();

    // startDate 之前的累计余额：SQL 聚合版(此前把该账户全部历史拉进 Dart 逐条
    // 累加，几年老账户上万行)。口径与 getAccountGlobalBalance 逐字一致：主账户侧
    // income + / expense - / transfer - / adjustment +，转入侧 transfer +；
    // 不排除 excludeFromStats（与原实现一致，趋势看的是账户真实余额）。
    final baseline = await db.customSelect(
      'SELECT '
      "COALESCE(SUM(CASE WHEN account_id = ?1 THEN ("
      '  CASE type '
      "    WHEN 'income' THEN amount "
      "    WHEN 'expense' THEN -amount "
      "    WHEN 'transfer' THEN -amount "
      "    WHEN 'adjustment' THEN amount "
      '    ELSE 0 END) ELSE 0 END), 0) AS main_delta, '
      "COALESCE(SUM(CASE WHEN to_account_id = ?1 AND type = 'transfer' "
      '  THEN amount ELSE 0 END), 0) AS transfer_in '
      'FROM transactions '
      'WHERE (account_id = ?1 OR to_account_id = ?1) '
      'AND happened_at < ?2',
      variables: [
        d.Variable.withInt(accountId),
        d.Variable<DateTime>(startDate),
      ],
      readsFrom: {db.transactions},
    ).getSingle();

    double dval(dynamic v) => v is num ? v.toDouble() : 0.0;
    // 计算 startDate 之前的余额
    double runningBalance = account.initialBalance +
        dval(baseline.data['main_delta']) +
        dval(baseline.data['transfer_in']);
    int txIndex = 0;

    // 按天填充
    final result = <({DateTime date, double balance})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);

    while (!currentDate.isAfter(end)) {
      final nextDate = currentDate.add(const Duration(days: 1));

      // 累加当天的交易
      while (txIndex < allTxs.length &&
          allTxs[txIndex].happenedAt.isBefore(nextDate)) {
        final tx = allTxs[txIndex];
        if (tx.accountId == accountId) {
          if (tx.type == 'income') {
            runningBalance += tx.amount;
          } else if (tx.type == 'expense') {
            runningBalance -= tx.amount;
          } else if (tx.type == 'transfer') {
            runningBalance -= tx.amount;
          } else if (tx.type == 'adjustment') {
            runningBalance += tx.amount;
          }
        }
        if (tx.toAccountId == accountId && tx.type == 'transfer') {
          runningBalance += tx.amount;
        }
        txIndex++;
      }

      result.add((date: currentDate, balance: runningBalance));
      currentDate = nextDate;
    }

    return result;
  }

  @override
  Future<List<({int? id, String name, String? icon, double total})>>
      getAccountCategoryStats(int accountId, {required String type}) async {
    final results = await db.customSelect(
      '''
      SELECT c.id, c.name, c.icon, SUM(t.amount) as total
      FROM transactions t
      LEFT JOIN categories c ON t.category_id = c.id
      WHERE t.account_id = ?1 AND t.type = ?2
      GROUP BY c.id
      ORDER BY total DESC
      ''',
      variables: [
        d.Variable.withInt(accountId),
        d.Variable.withString(type),
      ],
      readsFrom: {db.transactions, db.categories},
    ).get();

    return results.map((row) {
      return (
        id: row.data['id'] as int?,
        name: (row.data['name'] as String?) ?? '未分类',
        icon: row.data['icon'] as String?,
        total: (row.data['total'] as num).toDouble(),
      );
    }).toList();
  }

  @override

  /// ⚠️ 审计 U12：多币种口径未处理——本方法跨所有账户按币种裸加余额。
  /// 当前无 UI 消费（netWorthBreakdownProvider 已标记 deprecated）。
  /// 多币种场景必须用 [getNetWorthBreakdownByCurrency] + 折算链路
  /// （convertedNetWorth），勿直接接入本方法。
  Future<({double totalAssets, double totalLiabilities, double netWorth})>
      getNetWorthBreakdown() async {
    final accounts = await getAllAccounts();
    double totalAssets = 0.0;
    double totalLiabilities = 0.0;

    for (final account in accounts) {
      final balance = await getAccountBalance(account.id);
      if (isAssetType(account.type)) {
        totalAssets += balance;
      } else {
        totalLiabilities += balance;
      }
    }

    return (
      totalAssets: totalAssets,
      totalLiabilities: totalLiabilities,
      netWorth: totalAssets + totalLiabilities,
    );
  }

  @override
  Future<
          Map<String,
              ({double totalAssets, double totalLiabilities, double netWorth})>>
      getNetWorthBreakdownByCurrency() async {
    final accounts = await getAllAccounts();
    final Map<String,
            ({double totalAssets, double totalLiabilities, double netWorth})>
        result = {};

    for (final account in accounts) {
      final balance = await getAccountBalance(account.id);
      final currency = account.currency.toUpperCase();
      final prev = result[currency] ??
          (totalAssets: 0.0, totalLiabilities: 0.0, netWorth: 0.0);

      if (isAssetType(account.type)) {
        result[currency] = (
          totalAssets: prev.totalAssets + balance,
          totalLiabilities: prev.totalLiabilities,
          netWorth: prev.netWorth + balance,
        );
      } else {
        result[currency] = (
          totalAssets: prev.totalAssets,
          totalLiabilities: prev.totalLiabilities + balance,
          netWorth: prev.netWorth + balance,
        );
      }
    }

    return result;
  }

  @override
  Future<List<({DateTime date, double balance})>> getNetWorthDailyBalances({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final accounts = await getAllAccounts();
    if (accounts.isEmpty) return [];

    // 获取每个账户的每日余额
    final allBalances = <int, List<({DateTime date, double balance})>>{};
    for (final account in accounts) {
      allBalances[account.id] = await getAccountDailyBalances(
        account.id,
        startDate: startDate,
        endDate: endDate,
      );
    }

    // 按日聚合
    final result = <({DateTime date, double balance})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    int dayIndex = 0;

    while (!currentDate.isAfter(end)) {
      double dayTotal = 0.0;
      for (final account in accounts) {
        final balances = allBalances[account.id]!;
        if (dayIndex < balances.length) {
          dayTotal += balances[dayIndex].balance;
        }
      }
      result.add((date: currentDate, balance: dayTotal));
      currentDate = currentDate.add(const Duration(days: 1));
      dayIndex++;
    }

    return result;
  }

  @override
  Future<List<({DateTime date, double assets, double liabilities, double net})>>
      getNetWorthTrendSeries({
    required DateTime startDate,
    required DateTime endDate,
    required Map<String, double> ratesToBase,
  }) async {
    final accounts = await getAllAccounts();
    if (accounts.isEmpty) return [];

    final allBalances = <int, List<({DateTime date, double balance})>>{};
    for (final account in accounts) {
      allBalances[account.id] = await getAccountDailyBalances(account.id,
          startDate: startDate, endDate: endDate);
    }

    final result =
        <({DateTime date, double assets, double liabilities, double net})>[];
    var currentDate = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    int dayIndex = 0;
    while (!currentDate.isAfter(end)) {
      double assets = 0.0, liabilities = 0.0;
      for (final account in accounts) {
        final balances = allBalances[account.id]!;
        if (dayIndex < balances.length) {
          // 折算到主币种:缺汇率的币种整条剔除(与净资产卡同口径,绝不按 1.0 裸加)。
          final rate = ratesToBase[account.currency.toUpperCase()];
          if (rate == null) continue;
          final bal = balances[dayIndex].balance * rate;
          if (isAssetType(account.type)) {
            assets += bal;
          } else {
            liabilities += bal;
          }
        }
      }
      result.add((
        date: currentDate,
        assets: assets,
        liabilities: liabilities,
        net: assets + liabilities
      ));
      currentDate = currentDate.add(const Duration(days: 1));
      dayIndex++;
    }
    return result;
  }

  @override
  Future<List<({String type, double totalBalance})>>
      getAssetCompositionByType() async {
    final accounts = await getAllAccounts();
    final Map<String, double> typeBalances = {};

    for (final account in accounts) {
      final balance = await getAccountBalance(account.id);
      typeBalances.update(account.type, (v) => v + balance,
          ifAbsent: () => balance);
    }

    return typeBalances.entries
        .map((e) => (type: e.key, totalBalance: e.value))
        .toList();
  }

  @override
  Future<List<({String type, String currency, double totalBalance})>>
      getAssetCompositionByTypeAndCurrency() async {
    final accounts = await getAllAccounts();
    // (type, currency 大写) -> 余额累加
    final Map<({String type, String currency}), double> balances = {};

    for (final account in accounts) {
      final balance = await getAccountBalance(account.id);
      final key =
          (type: account.type, currency: account.currency.toUpperCase());
      balances.update(key, (v) => v + balance, ifAbsent: () => balance);
    }

    return balances.entries
        .map((e) => (
              type: e.key.type,
              currency: e.key.currency,
              totalBalance: e.value,
            ))
        .toList();
  }

  @override
  Future<HoldingsValueSummary> getHoldingsSummaryForAccount(
          int accountId) async =>
      (await _holdingsSummaryByAccount(onlyAccountId: accountId))[accountId] ??
      HoldingsValueSummary.empty;

  @override
  Future<void> updateAccountValuation(int accountId, double newValue) async {
    await (db.update(db.accounts)..where((a) => a.id.equals(accountId))).write(
      AccountsCompanion(
        initialBalance: d.Value(newValue),
        updatedAt: d.Value(DateTime.now()),
      ),
    );
  }

  @override
  Future<Set<String>> getUsedCurrencies() async {
    final rows =
        await db.customSelect('SELECT DISTINCT currency FROM accounts').get();
    return rows.map((r) => (r.read<String>('currency')).toUpperCase()).toSet();
  }
}
