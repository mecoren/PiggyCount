import 'dart:convert';
import 'dart:math' as math;

import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../../data/models/custom_field_values.dart';
import '../../data/repositories/base_repository.dart';
import '../system/logger_service.dart';

/// 测试数据规模：每类实体各生成多少条。
///
/// 默认档位即「几千条」：交易 3000 + 账户 120 + 分类 200 + 标签 200 + 分类预算
/// 120 + 总预算 1 + 回收站 200 + 周期账单 120 + 储蓄目标 100 + 持仓 150 +
/// 自定义字段 10，另附 2 个测试账本各 150 笔交易 + 20 条分类预算。
class DevSeedPlan {
  const DevSeedPlan({
    this.accounts = 120,
    this.categories = 200,
    this.tags = 200,
    this.customFields = 10,
    this.budgets = 120,
    this.recurring = 120,
    this.savingsGoals = 100,
    this.holdings = 150,
    this.transactions = 3000,
    this.trashTransactions = 200,
    this.extraLedgers = 2,
    this.extraLedgerTransactions = 150,
    this.extraLedgerBudgets = 20,
    this.refundPairs = 30,
  });

  /// 账户（含 1/10 的投资账户，用于持仓）。
  final int accounts;

  /// 分类（一级 + 二级合计）。
  final int categories;

  final int tags;
  final int customFields;

  /// 当前账本的分类预算条数。
  final int budgets;

  final int recurring;
  final int savingsGoals;
  final int holdings;

  /// 当前账本的交易条数（不含回收站）。
  final int transactions;

  /// 回收站里的（已软删）交易条数。
  final int trashTransactions;

  /// 额外创建的测试账本数量（写交易 + 分类预算，用于验证账本切换 / 统计隔离）。
  final int extraLedgers;
  final int extraLedgerTransactions;
  final int extraLedgerBudgets;

  /// 退款关联的（原支出 + 退款收入）对数。
  final int refundPairs;

  /// 预估总写入行数（不含 tag 关联、自定义字段值这类派生行）。
  int get totalRecords =>
      accounts +
      categories +
      tags +
      customFields +
      budgets +
      1 + // 总预算
      trashTransactions +
      recurring +
      savingsGoals +
      holdings +
      transactions +
      extraLedgers +
      extraLedgers * (extraLedgerTransactions + extraLedgerBudgets + 1);
}

/// 生成 / 清理结果。
class DevSeedResult {
  const DevSeedResult({
    required this.created,
    required this.cleaned,
    required this.failed,
    required this.elapsed,
  });

  /// 各实体实际写入条数，key 见 [DevSeedStage]。
  final Map<String, int> created;

  /// 清理阶段各实体实际删除条数。
  final Map<String, int> cleaned;

  /// 写入失败条数（撞唯一约束等，已跳过不中断整体流程）。
  final int failed;

  final Duration elapsed;

  int get createdTotal => created.values.fold(0, (a, b) => a + b);
  int get cleanedTotal => cleaned.values.fold(0, (a, b) => a + b);
}

/// 阶段标识（UI 侧据此映射本地化文案，服务层不碰用户文案）。
class DevSeedStage {
  DevSeedStage._();

  static const cleanup = 'cleanup';
  static const accounts = 'accounts';
  static const categories = 'categories';
  static const tags = 'tags';
  static const customFields = 'customFields';
  static const budgets = 'budgets';
  static const totalBudget = 'totalBudget';
  static const recurring = 'recurring';
  static const savingsGoals = 'savingsGoals';
  static const holdings = 'holdings';
  static const transactions = 'transactions';
  static const trash = 'trash';
  static const ledgers = 'ledgers';

  static const all = [
    accounts,
    categories,
    tags,
    customFields,
    budgets,
    totalBudget,
    recurring,
    savingsGoals,
    holdings,
    transactions,
    trash,
    ledgers,
  ];
}

typedef DevSeedProgress = void Function(String stage, int done, int total);

/// 开发 / 测试用数据生成器。
///
/// ## 可达性
/// 唯一 UI 入口 `DevTestDataPage` 由 `DevToolGate.enabled`（`!kReleaseMode &&
/// appFlavor == 'dev'`）把守：release 与 prod flavor 下入口不渲染、页面自检
/// 失败，构建期即可被 tree shaking 裁掉。本类不得被生产代码路径调用。
///
/// ## 契约
/// - **只经 [BaseRepository] 写库**（分层纪律），不直接碰 Drift；
/// - 所有生成的行都带 [marker] 标记（名称 / 备注前缀），[cleanup] 据此前置
///   清空。因此「重复生成」不会叠数据，也不会撞账户 / 标签 / 分类的全局唯一
///   名称约束；
/// - 标记前缀同时让用户一眼区分测试数据与手工数据。
class DevTestDataSeeder {
  DevTestDataSeeder._();

  /// 测试数据标记：账户 / 分类 / 标签 / 字段 / 目标 / 持仓落在名称前缀，
  /// 交易与周期规则落在备注前缀。
  static const String marker = '【T】';

  /// 总预算的哨兵金额。
  ///
  /// `budgets` 表没有名称 / 备注列，无法挂 [marker]；总预算又只有「一条」，
  /// 只能靠一个明显不真实的金额来识别测试行（清理时精确匹配）。这是刻意的
  /// 取舍：宁可金额看起来假，也不去改 schema / 加清单文件。
  static const double seedTotalBudgetAmount = 123456.78;

  static const _uuid = Uuid();

  static const _tradableTypes = [
    'cash',
    'bank_card',
    'credit_card',
    'alipay',
    'wechat',
    'other',
  ];

  static const _accountTypeNames = {
    'cash': '现金',
    'bank_card': '银行卡',
    'credit_card': '信用卡',
    'alipay': '支付宝',
    'wechat': '微信',
    'other': '其他账户',
    'investment': '投资账户',
  };

  static const _expenseCategoryNames = [
    '餐饮',
    '交通',
    '购物',
    '娱乐',
    '居家',
    '医疗',
    '教育',
    '宠物',
    '运动',
    '数码',
    '旅行',
    '服饰',
    '美妆',
    '汽修',
    '通讯',
    '水电',
    '房租',
    '保险',
    '社交',
    '学习',
  ];

  static const _incomeCategoryNames = [
    '工资',
    '奖金',
    '理财收益',
    '报销',
    '兼职',
    '红包',
    '利息',
    '退款',
  ];

  static const _categoryIcons = [
    'restaurant',
    'directions_car',
    'shopping_cart',
    'movie',
    'home',
    'local_hospital',
    'school',
    'pets',
    'fitness_center',
    'smartphone',
    'flight',
    'checkroom',
    'face',
    'handyman',
    'phone',
    'flash_on',
    'apartment',
    'security',
    'group',
    'menu_book',
  ];

  static const _tagColors = [
    '#FF5722',
    '#42A5F5',
    '#66BB6A',
    '#FFA726',
    '#AB47BC',
    '#26C6DA',
    '#EF5350',
    '#8D6E63',
  ];

  static const _expenseNotes = [
    '午饭',
    '地铁',
    '超市采购',
    '外卖',
    '咖啡',
    '打车',
    '电影票',
    '快递费',
    '话费充值',
    '水电费',
    '房租',
    '药品',
    '健身卡',
    '宠物粮',
    '网购',
    '早餐',
    '夜宵',
    '理发',
    '加油',
    '停车费',
  ];

  static const _incomeNotes = [
    '工资',
    '项目奖金',
    '利息',
    '报销到账',
    '兼职收入',
    '红包',
    '二手出售',
    '基金分红',
  ];

  static const _fieldNames = ['金额备注', '行程编号', '报销日期', '支付渠道', '用餐人数'];

  static const _fieldOptions = ['选项甲', '选项乙', '选项丙'];

  static const _markets = ['SH', 'SZ', 'HK', 'US', 'FUND', 'CRYPTO'];

  static const _assetClasses = ['stock', 'fund', 'bond', 'crypto', 'other'];

  // ==========================================================================
  // 清理
  // ==========================================================================

  /// 删除本机所有带 [marker] 标记的测试数据，返回各实体删除条数。
  ///
  /// 顺序有意为之：先交易（否则删分类 / 账户会留下悬空引用）、再依赖分类 id
  /// 的预算、最后才是字典与账户。全部走仓库接口，与手工删除同一套语义。
  static Future<Map<String, int>> cleanup({
    required BaseRepository repo,
    required int ledgerId,
    DevSeedProgress? onProgress,
  }) async {
    final cleaned = <String, int>{};

    bool marked(String? text) => (text ?? '').startsWith(marker);

    void report(int done, int total) =>
        onProgress?.call(DevSeedStage.cleanup, done, total);

    // 1) 当前账本的交易（连带 tag / 附件关联由仓库清理）。
    report(0, 10);
    final txs = await repo.getTransactionsByLedger(ledgerId);
    final seededTxs = txs.where((t) => marked(t.note)).toList();
    if (seededTxs.isNotEmpty) {
      final syncIds =
          seededTxs.map((t) => t.syncId).whereType<String>().toList();
      if (syncIds.isNotEmpty) {
        await repo.deleteTransactionsBatchBySyncIds(syncIds);
      }
      for (final tx in seededTxs.where((t) => t.syncId == null)) {
        await repo.deleteTransaction(tx.id);
      }
      cleaned[DevSeedStage.transactions] = seededTxs.length;
    }

    // 2) 回收站：deleted_transactions.payload 是原交易 JSON，靠【T】备注判定。
    var purged = 0;
    for (final row in await repo.getDeletedTransactions(ledgerId: ledgerId)) {
      if (marked(_noteOfPayload(row.payload))) {
        await repo.purgeDeletedTransaction(row.txId);
        purged++;
      }
    }
    if (purged > 0) cleaned[DevSeedStage.trash] = purged;

    // 3) 分类预算：预算本身没有名称，靠「引用了测试分类」判定。
    //    分类与预算各只读一次，后续复用（少两次全表扫描）。
    report(3, 10);
    final categories = await repo.getAllCategories();
    final seededCategories = categories.where((c) => marked(c.name)).toList();
    final seededCategoryIds = seededCategories.map((c) => c.id).toSet();
    final budgets = await repo.getAllBudgets(ledgerId);
    final deletedBudgetIds = <int>{};
    if (seededCategoryIds.isNotEmpty) {
      for (final budget in budgets) {
        final categoryId = budget.categoryId;
        if (categoryId != null && seededCategoryIds.contains(categoryId)) {
          await repo.deleteBudget(budget.id);
          deletedBudgetIds.add(budget.id);
        }
      }
      if (deletedBudgetIds.isNotEmpty) {
        cleaned[DevSeedStage.budgets] = deletedBudgetIds.length;
      }
    }

    // 3b) 总预算：只有「哨兵金额」才是测试行。**必须等分类预算删完、且账本里
    // 只剩它自己时才删** —— `deleteBudget` 对 total 是级联清掉整账本预算，
    // 顺手删会把用户自己的预算一起带走。
    final remainingBudgets =
        budgets.where((b) => !deletedBudgetIds.contains(b.id)).toList();
    final seedTotals = remainingBudgets
        .where((b) => b.type == 'total' && _isSeedTotalBudget(b.amount))
        .toList();
    if (seedTotals.isNotEmpty && remainingBudgets.length == seedTotals.length) {
      await repo.deleteBudget(seedTotals.first.id);
      cleaned[DevSeedStage.totalBudget] = seedTotals.length;
    }

    // 3) 周期账单。
    report(4, 10);
    var recurring = 0;
    for (final item in await repo.getRecurringTransactionsByLedger(ledgerId)) {
      if (marked(item.note)) {
        await repo.deleteRecurringTransaction(item.id);
        recurring++;
      }
    }
    if (recurring > 0) cleaned[DevSeedStage.recurring] = recurring;

    // 4) 储蓄目标。
    report(5, 10);
    var goals = 0;
    for (final goal in await repo.getSavingsGoalsByLedger(ledgerId)) {
      if (marked(goal.name)) {
        await repo.deleteSavingsGoal(goal.id);
        goals++;
      }
    }
    if (goals > 0) cleaned[DevSeedStage.savingsGoals] = goals;

    // 5) 投资持仓（user-global，跨账本可见）。
    report(6, 10);
    var holdings = 0;
    for (final holding in await repo.getAllHoldings()) {
      if (marked(holding.name)) {
        await repo.deleteHolding(holding.id);
        holdings++;
      }
    }
    if (holdings > 0) cleaned[DevSeedStage.holdings] = holdings;

    // 6) 自定义字段定义（会同时清掉交易里的值）。
    report(7, 10);
    var fields = 0;
    for (final def in await repo.getDefinitionsForLedger(ledgerId)) {
      if (marked(def.name)) {
        await repo.deleteDefinition(def.id);
        fields++;
      }
    }
    if (fields > 0) cleaned[DevSeedStage.customFields] = fields;

    // 7) 标签。
    report(8, 10);
    var tags = 0;
    for (final tag in await repo.getAllTags()) {
      if (marked(tag.name)) {
        await repo.deleteTag(tag.id);
        tags++;
      }
    }
    if (tags > 0) cleaned[DevSeedStage.tags] = tags;

    // 8) 分类（子分类随父分类删除，计数按「所有被标记的分类行」算，
    //    与实际生成量对齐；复用上面那次 getAllCategories 结果）。
    var deletedCategories = 0;
    for (final category in seededCategories) {
      if (category.parentId == null) {
        await repo.deleteCategory(category.id);
        deletedCategories++;
      }
    }
    if (seededCategories.isNotEmpty) {
      cleaned[DevSeedStage.categories] = seededCategories.length;
      logger.info('DevSeed', '删除测试分类根节点 $deletedCategories 个');
    }

    // 9) 账户。
    report(9, 10);
    var accounts = 0;
    for (final account in await repo.getAllAccounts()) {
      if (marked(account.name)) {
        await repo.deleteAccount(account.id);
        accounts++;
      }
    }
    if (accounts > 0) cleaned[DevSeedStage.accounts] = accounts;

    // 10) 额外测试账本（级联删除其交易）。
    var ledgers = 0;
    for (final ledger in await repo.getAllLedgers()) {
      if (ledger.id != ledgerId && marked(ledger.name)) {
        await repo.deleteLedger(ledger.id);
        ledgers++;
      }
    }
    if (ledgers > 0) cleaned[DevSeedStage.ledgers] = ledgers;

    report(10, 10);
    logger.info('DevSeed', '清理测试数据完成: $cleaned');
    return cleaned;
  }

  // ==========================================================================
  // 生成
  // ==========================================================================

  /// 生成测试数据：先 [cleanup] 再写入，重复调用结果收敛。
  ///
  /// [ledgerId] 为当前账本 id；[currency] 为账本本位币（ISO 大写）。
  static Future<DevSeedResult> seed({
    required BaseRepository repo,
    required int ledgerId,
    required String currency,
    DevSeedPlan plan = const DevSeedPlan(),
    DevSeedProgress? onProgress,
    math.Random? random,
  }) async {
    final watch = Stopwatch()..start();
    final rnd = random ?? math.Random();
    final base = (currency.trim().isEmpty ? 'CNY' : currency).toUpperCase();
    final created = <String, int>{};
    var failed = 0;

    // 0) 先清旧数据：重复生成不叠数据，也不撞名称唯一约束。
    final cleaned = await cleanup(
      repo: repo,
      ledgerId: ledgerId,
      onProgress: onProgress,
    );

    // 1) 账户（约 1/10 为投资账户，供持仓挂靠）。
    final tradableAccounts = <int>[];
    final investmentAccounts = <int>[];
    for (var i = 0; i < plan.accounts; i++) {
      final isInvestment = i % 10 == 9;
      final type = isInvestment
          ? 'investment'
          : _tradableTypes[i % _tradableTypes.length];
      final name =
          '$marker${_accountTypeNames[type] ?? type} ${(i + 1).toString().padLeft(3, '0')}';
      try {
        final id = await repo.createAccount(
          ledgerId: ledgerId,
          name: name,
          type: type,
          currency: base,
          initialBalance: isInvestment
              ? _money(rnd, 50000, 500000)
              : (type == 'credit_card' ? 0 : _money(rnd, 1000, 80000)),
          creditLimit: type == 'credit_card' ? _money(rnd, 5000, 60000) : null,
          billingDay: type == 'credit_card' ? 1 + rnd.nextInt(28) : null,
          paymentDueDay: type == 'credit_card' ? 1 + rnd.nextInt(28) : null,
          bankName: type == 'bank_card' ? '测试银行 ${1 + i % 12}' : null,
          cardLastFour: type == 'bank_card'
              ? (1000 + rnd.nextInt(9000)).toString()
              : null,
          note: '$marker测试账户',
        );
        (isInvestment ? investmentAccounts : tradableAccounts).add(id);
        created[DevSeedStage.accounts] =
            (created[DevSeedStage.accounts] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建账户失败: $name ($e)');
      }
      onProgress?.call(DevSeedStage.accounts, i + 1, plan.accounts);
    }
    if (tradableAccounts.isEmpty) {
      // 没有可交易账户就没法记流水：直接返回，避免生成一堆无账户交易。
      return DevSeedResult(
        created: created,
        cleaned: cleaned,
        failed: failed,
        elapsed: watch.elapsed,
      );
    }

    // 2) 分类：一级 + 各挂 1 个二级，合计 = plan.categories。
    final parents = (plan.categories / 2).floor();
    final expenseParents = (parents * 0.8).round();
    final incomeParents = parents - expenseParents;
    final expenseCategories = <int>[];
    final incomeCategories = <int>[];

    Future<int?> createCategory({
      required String name,
      required String kind,
      required String icon,
      required int sortOrder,
    }) async {
      try {
        final id = await repo.createCategory(
          name: name,
          kind: kind,
          icon: icon,
          sortOrder: sortOrder,
          level: 1,
        );
        created[DevSeedStage.categories] =
            (created[DevSeedStage.categories] ?? 0) + 1;
        return id;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建分类失败: $name ($e)');
        return null;
      }
    }

    Future<int?> createSubCategory({
      required int parentId,
      required String name,
      required String kind,
      required String icon,
      required int sortOrder,
    }) async {
      try {
        final id = await repo.createSubCategory(
          parentId: parentId,
          name: name,
          kind: kind,
          icon: icon,
          sortOrder: sortOrder,
        );
        created[DevSeedStage.categories] =
            (created[DevSeedStage.categories] ?? 0) + 1;
        return id;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建子分类失败: $name ($e)');
        return null;
      }
    }

    for (var i = 0; i < expenseParents; i++) {
      final name = '$marker支出 '
          '${(i + 1).toString().padLeft(3, '0')} · '
          '${_expenseCategoryNames[i % _expenseCategoryNames.length]}';
      final icon = _categoryIcons[i % _categoryIcons.length];
      final parentId = await createCategory(
        name: name,
        kind: 'expense',
        icon: icon,
        sortOrder: i,
      );
      if (parentId == null) continue;
      expenseCategories.add(parentId);
      for (var j = 0; j < 1; j++) {
        final childId = await createSubCategory(
          parentId: parentId,
          name: '$marker支出子类 ${(i + 1).toString().padLeft(3, '0')}-${j + 1}',
          kind: 'expense',
          icon: icon,
          sortOrder: j,
        );
        if (childId != null) expenseCategories.add(childId);
      }
      onProgress?.call(
        DevSeedStage.categories,
        created[DevSeedStage.categories] ?? 0,
        plan.categories,
      );
    }

    for (var i = 0; i < incomeParents; i++) {
      final name = '$marker收入 '
          '${(i + 1).toString().padLeft(3, '0')} · '
          '${_incomeCategoryNames[i % _incomeCategoryNames.length]}';
      final icon = _categoryIcons[i % _categoryIcons.length];
      final parentId = await createCategory(
        name: name,
        kind: 'income',
        icon: icon,
        sortOrder: i,
      );
      if (parentId == null) continue;
      incomeCategories.add(parentId);
      final childId = await createSubCategory(
        parentId: parentId,
        name: '$marker收入子类 ${(i + 1).toString().padLeft(3, '0')}-1',
        kind: 'income',
        icon: icon,
        sortOrder: 0,
      );
      if (childId != null) incomeCategories.add(childId);
      onProgress?.call(
        DevSeedStage.categories,
        created[DevSeedStage.categories] ?? 0,
        plan.categories,
      );
    }

    // 3) 标签。
    final tagIds = <int>[];
    for (var i = 0; i < plan.tags; i++) {
      final name = '$marker标签 ${(i + 1).toString().padLeft(3, '0')}';
      try {
        tagIds.add(await repo.createTag(
          name: name,
          color: _tagColors[i % _tagColors.length],
          sortOrder: i,
        ));
        created[DevSeedStage.tags] = (created[DevSeedStage.tags] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建标签失败: $name ($e)');
      }
      onProgress?.call(DevSeedStage.tags, i + 1, plan.tags);
    }

    // 4) 自定义字段（5 种类型轮转，交易里会真写值）。
    for (var i = 0; i < plan.customFields; i++) {
      final type = CustomFieldType.all[i % CustomFieldType.all.length];
      final name = '$marker${_fieldNames[i % _fieldNames.length]} '
          '${(i + 1).toString().padLeft(2, '0')}';
      try {
        await repo.createDefinition(
          ledgerId: ledgerId,
          name: name,
          fieldType: type,
          sortOrder: i,
          options: CustomFieldType.hasOptions(type) ? _fieldOptions : null,
        );
        created[DevSeedStage.customFields] =
            (created[DevSeedStage.customFields] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建自定义字段失败: $name ($e)');
      }
      onProgress?.call(DevSeedStage.customFields, i + 1, plan.customFields);
    }
    final fieldDefs = await repo.getDefinitionsForLedger(ledgerId);
    final fields = fieldDefs.where((f) => f.name.startsWith(marker)).toList();

    // 5) 总预算：预算页在「没有总预算」时整页空状态，分类预算也就全都看不到，
    //    所以必须先补一条。只在账本一条预算都没有时建（有用户自己的预算就不碰），
    //    这样清理时删掉分类预算后账本里只剩这条哨兵行，删它不会级联误伤用户数据。
    final existingBudgets = await repo.getAllBudgets(ledgerId);
    final seedBudgets = existingBudgets.isEmpty;
    if (seedBudgets) {
      try {
        await repo.createBudget(
          ledgerId: ledgerId,
          type: 'total',
          amount: seedTotalBudgetAmount,
          period: 'monthly',
          startDay: 1,
        );
        created[DevSeedStage.totalBudget] = 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建总预算失败: $e');
      }
      onProgress?.call(DevSeedStage.totalBudget, 1, 1);
    } else {
      logger.info(
        'DevSeed',
        '账本 $ledgerId 已有 ${existingBudgets.length} 条预算，跳过预算写入以免覆盖用户配置',
      );
    }

    // 6) 分类预算。
    final budgetCats =
        expenseCategories.isNotEmpty ? expenseCategories : <int>[];
    const periods = ['monthly', 'weekly', 'yearly'];
    for (var i = 0;
        i < plan.budgets && seedBudgets && budgetCats.isNotEmpty;
        i++) {
      final categoryId = budgetCats[i % budgetCats.length];
      try {
        await repo.createBudget(
          ledgerId: ledgerId,
          type: 'category',
          categoryId: categoryId,
          amount: _money(rnd, 500, 8000),
          period: periods[i % periods.length],
          startDay: 1 + rnd.nextInt(28),
          enabled: i % 10 != 0,
        );
        created[DevSeedStage.budgets] =
            (created[DevSeedStage.budgets] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建预算失败(category=$categoryId): $e');
      }
      onProgress?.call(DevSeedStage.budgets, i + 1, plan.budgets);
    }

    // 6) 周期账单。
    const frequencies = ['daily', 'weekly', 'monthly', 'yearly'];
    final now = DateTime.now();
    for (var i = 0; i < plan.recurring; i++) {
      final kind = i % 8 == 0 ? 'income' : 'expense';
      final categories =
          kind == 'income' ? incomeCategories : expenseCategories;
      final frequency = frequencies[i % frequencies.length];
      try {
        await repo.addRecurringTransaction(
          ledgerId: ledgerId,
          type: kind,
          amount: _money(rnd, 20, 3000),
          categoryId:
              categories.isEmpty ? null : categories[i % categories.length],
          accountId: tradableAccounts[i % tradableAccounts.length],
          note: '$marker周期账单 ${(i + 1).toString().padLeft(3, '0')}',
          frequency: frequency,
          interval: 1 + rnd.nextInt(3),
          dayOfMonth: frequency == 'monthly' ? 1 + rnd.nextInt(28) : null,
          dayOfWeek: frequency == 'weekly' ? 1 + rnd.nextInt(7) : null,
          monthOfYear: frequency == 'yearly' ? 1 + rnd.nextInt(12) : null,
          startDate: DateTime(now.year, now.month - rnd.nextInt(12), 1),
          enabled: i % 6 != 0,
          currencyCode: base,
        );
        created[DevSeedStage.recurring] =
            (created[DevSeedStage.recurring] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建周期账单失败(#$i): $e');
      }
      onProgress?.call(DevSeedStage.recurring, i + 1, plan.recurring);
    }

    // 7) 储蓄目标（账户模式与手动模式混合）。
    for (var i = 0; i < plan.savingsGoals; i++) {
      final byAccount = i % 3 == 0;
      final target = _money(rnd, 3000, 200000);
      try {
        await repo.createSavingsGoal(
          ledgerId: ledgerId,
          name: '$marker储蓄目标 ${(i + 1).toString().padLeft(3, '0')}',
          targetAmount: target,
          currency: base,
          accountId:
              byAccount ? tradableAccounts[i % tradableAccounts.length] : null,
          savedAmount: byAccount ? 0 : target * (0.1 + rnd.nextDouble() * 0.8),
          startDate: DateTime(now.year, now.month - rnd.nextInt(18), 1),
          targetDate: DateTime(now.year + 1, 1 + rnd.nextInt(12), 1),
          note: '$marker测试储蓄目标',
          sortOrder: i,
        );
        created[DevSeedStage.savingsGoals] =
            (created[DevSeedStage.savingsGoals] ?? 0) + 1;
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建储蓄目标失败(#$i): $e');
      }
      onProgress?.call(DevSeedStage.savingsGoals, i + 1, plan.savingsGoals);
    }

    // 8) 投资持仓（挂到投资账户上；有持仓时账户金额走市值口径）。
    if (investmentAccounts.isNotEmpty) {
      for (var i = 0; i < plan.holdings; i++) {
        try {
          await repo.createHolding(
            accountId: investmentAccounts[i % investmentAccounts.length],
            name: '$marker持仓 ${(i + 1).toString().padLeft(3, '0')}',
            currency: base,
            symbol: 'TST${(i + 1).toString().padLeft(4, '0')}',
            market: _markets[i % _markets.length],
            assetClass: _assetClasses[i % _assetClasses.length],
            quantity: _money(rnd, 1, 2000),
            unitCost: _money(rnd, 1, 200),
            unitPrice: _money(rnd, 1, 260),
            autoQuote: i % 5 == 0,
            note: '$marker测试持仓',
            sortOrder: i,
          );
          created[DevSeedStage.holdings] =
              (created[DevSeedStage.holdings] ?? 0) + 1;
        } catch (e) {
          failed++;
          logger.warning('DevSeed', '创建持仓失败(#$i): $e');
        }
        onProgress?.call(DevSeedStage.holdings, i + 1, plan.holdings);
      }
    }

    // 9) 交易（当前账本）。
    final transferCategory = await repo.getTransferCategory();

    var inserted = 0;
    final refundPairs = <({String expenseSyncId, String incomeSyncId})>[];
    var batch = <TransactionsCompanion>[];
    var batchTags = <int, List<int>>{};

    Future<void> flush() async {
      if (batch.isEmpty) return;
      try {
        await repo.insertTransactionsBatchWithRelations(
          transactions: batch,
          tagIdsByIndex: batchTags,
        );
        inserted += batch.length;
      } catch (e) {
        failed += batch.length;
        logger.warning('DevSeed', '批量插入交易失败(${batch.length} 条): $e');
      }
      batch = <TransactionsCompanion>[];
      batchTags = <int, List<int>>{};
      onProgress?.call(DevSeedStage.transactions, inserted, plan.transactions);
    }

    for (var i = 0; i < plan.transactions; i++) {
      final type =
          i % 30 == 0 ? 'income' : (i % 40 == 0 ? 'transfer' : 'expense');
      final categoryId = type == 'transfer'
          ? transferCategory.id
          : (type == 'income'
              ? (incomeCategories.isEmpty
                  ? null
                  : incomeCategories[i % incomeCategories.length])
              : (expenseCategories.isEmpty
                  ? null
                  : expenseCategories[i % expenseCategories.length]));
      final accountId = tradableAccounts[i % tradableAccounts.length];
      final toAccountId = type == 'transfer'
          ? tradableAccounts[(i + 1) % tradableAccounts.length]
          : null;
      final amount =
          type == 'income' ? _money(rnd, 3000, 20000) : _money(rnd, 5, 800);
      final noteText = type == 'transfer'
          ? '账户互转'
          : (type == 'income'
              ? _incomeNotes[i % _incomeNotes.length]
              : _expenseNotes[i % _expenseNotes.length]);

      final values = <String, dynamic>{};
      if (fields.isNotEmpty && i % 4 == 0) {
        final count = 1 + rnd.nextInt(math.min(3, fields.length));
        for (var k = 0; k < count; k++) {
          final def = fields[(i + k) % fields.length];
          final syncId = def.syncId;
          if (syncId == null) continue;
          switch (def.fieldType) {
            case CustomFieldType.amount:
              values[syncId] = _money(rnd, 1, 500);
              break;
            case CustomFieldType.date:
              values[syncId] = DateTime(
                now.year,
                now.month - rnd.nextInt(12),
                1 + rnd.nextInt(28),
              ).toIso8601String();
              break;
            case CustomFieldType.singleSelect:
              values[syncId] = _fieldOptions[rnd.nextInt(_fieldOptions.length)];
              break;
            case CustomFieldType.multiSelect:
              values[syncId] = [
                _fieldOptions[rnd.nextInt(_fieldOptions.length)],
                _fieldOptions[rnd.nextInt(_fieldOptions.length)],
              ];
              break;
            default:
              values[syncId] = '备注 ${1000 + rnd.nextInt(9000)}';
          }
        }
      }

      final syncId = _uuid.v4();
      batch.add(TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: type,
        amount: amount,
        categoryId: d.Value(categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        happenedAt: d.Value(_randomHappenedAt(rnd, now)),
        note: d.Value('$marker$noteText ${(i + 1).toString().padLeft(4, '0')}'),
        syncId: d.Value(syncId),
        excludeFromStats: d.Value(i % 20 == 0),
        excludeFromBudget: d.Value(i % 25 == 0),
        currencyCode: d.Value(base),
        nativeAmount: d.Value(amount),
        originalAmount: d.Value(i % 30 == 0 ? _money(rnd, 1, 1000) : null),
        customValuesJson: d.Value(CustomFieldValueCodec.encode(values)),
        reimburseStatus: d.Value(
          i % 50 == 0 ? 'pending' : (i % 90 == 0 ? 'reimbursed' : 'none'),
        ),
      ));

      if (tagIds.isNotEmpty && i % 3 == 0) {
        final count = 1 + rnd.nextInt(3);
        final picked = <int>{};
        for (var k = 0; k < count; k++) {
          picked.add(tagIds[rnd.nextInt(tagIds.length)]);
        }
        batchTags[batch.length - 1] = picked.toList();
      }

      if (batch.length >= 300) await flush();
    }

    // 退款关联：每对「支出 + 指向它的收入」，插入后按 syncId 回填。
    for (var i = 0; i < plan.refundPairs; i++) {
      final expenseSyncId = _uuid.v4();
      final incomeSyncId = _uuid.v4();
      final amount = _money(rnd, 10, 500);
      batch.add(TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: 'expense',
        amount: amount,
        categoryId: d.Value(expenseCategories.isEmpty
            ? null
            : expenseCategories[i % expenseCategories.length]),
        accountId: d.Value(tradableAccounts[i % tradableAccounts.length]),
        happenedAt: d.Value(_randomHappenedAt(rnd, now)),
        note: d.Value('$marker退款原支出 ${(i + 1).toString().padLeft(3, '0')}'),
        syncId: d.Value(expenseSyncId),
        currencyCode: d.Value(base),
        nativeAmount: d.Value(amount),
      ));
      batch.add(TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: 'income',
        amount: amount,
        categoryId: d.Value(incomeCategories.isEmpty
            ? null
            : incomeCategories[i % incomeCategories.length]),
        accountId: d.Value(tradableAccounts[i % tradableAccounts.length]),
        happenedAt: d.Value(_randomHappenedAt(rnd, now)),
        note: d.Value('$marker退款入账 ${(i + 1).toString().padLeft(3, '0')}'),
        syncId: d.Value(incomeSyncId),
        currencyCode: d.Value(base),
        nativeAmount: d.Value(amount),
        reimburseStatus: d.Value('none'),
      ));
      refundPairs
          .add((expenseSyncId: expenseSyncId, incomeSyncId: incomeSyncId));
    }
    await flush();

    if (refundPairs.isNotEmpty) {
      final links = <({String txSyncId, int? refundOfId})>[];
      for (final pair in refundPairs) {
        final origin = await repo.getTransactionBySyncId(pair.expenseSyncId);
        if (origin == null) continue;
        links.add((txSyncId: pair.incomeSyncId, refundOfId: origin.id));
      }
      if (links.isNotEmpty) {
        await repo.backfillRefundLinks(links);
      }
    }
    created[DevSeedStage.transactions] = inserted;

    // 10) 回收站：先正常入库，再走仓库的软删语义搬进 deleted_transactions
    //     （标签 / 附件行原地保留，恢复是无损的）。
    if (plan.trashTransactions > 0) {
      final trashBatch = <TransactionsCompanion>[];
      for (var i = 0; i < plan.trashTransactions; i++) {
        final isIncome = i % 20 == 0;
        final amount = isIncome ? _money(rnd, 500, 8000) : _money(rnd, 5, 600);
        trashBatch.add(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: isIncome ? 'income' : 'expense',
          amount: amount,
          categoryId: d.Value(isIncome
              ? (incomeCategories.isEmpty
                  ? null
                  : incomeCategories[i % incomeCategories.length])
              : (expenseCategories.isEmpty
                  ? null
                  : expenseCategories[i % expenseCategories.length])),
          accountId: d.Value(tradableAccounts[i % tradableAccounts.length]),
          happenedAt: d.Value(_randomHappenedAt(rnd, now)),
          note: d.Value('$marker回收站流水 ${(i + 1).toString().padLeft(3, '0')}'),
          currencyCode: d.Value(base),
          nativeAmount: d.Value(amount),
        ));
      }
      try {
        final trashIds = await repo.insertTransactionsBatchWithRelations(
          transactions: trashBatch,
        );
        final moved = await repo.softDeleteTransactions(trashIds);
        created[DevSeedStage.trash] = moved;
      } catch (e) {
        failed += trashBatch.length;
        logger.warning('DevSeed', '生成回收站流水失败: $e');
      }
      onProgress?.call(
        DevSeedStage.trash,
        created[DevSeedStage.trash] ?? 0,
        plan.trashTransactions,
      );
    }

    // 11) 额外测试账本（各写交易 + 预算，用于账本切换 / 统计隔离）。
    for (var i = 0; i < plan.extraLedgers; i++) {
      try {
        final extraLedgerId = await repo.createLedger(
          name: '$marker测试账本 ${(i + 1).toString().padLeft(2, '0')}',
          currency: base,
        );
        created[DevSeedStage.ledgers] =
            (created[DevSeedStage.ledgers] ?? 0) + 1;
        var extraBatch = <TransactionsCompanion>[];
        var extraInserted = 0;

        Future<void> flushExtra() async {
          if (extraBatch.isEmpty) return;
          await repo.insertTransactionsBatch(extraBatch);
          extraInserted += extraBatch.length;
          extraBatch = <TransactionsCompanion>[];
        }

        for (var k = 0; k < plan.extraLedgerTransactions; k++) {
          final isIncome = k % 10 == 0;
          final amount =
              isIncome ? _money(rnd, 1000, 15000) : _money(rnd, 5, 600);
          extraBatch.add(TransactionsCompanion.insert(
            ledgerId: extraLedgerId,
            type: isIncome ? 'income' : 'expense',
            amount: amount,
            categoryId: d.Value(isIncome
                ? (incomeCategories.isEmpty
                    ? null
                    : incomeCategories[k % incomeCategories.length])
                : (expenseCategories.isEmpty
                    ? null
                    : expenseCategories[k % expenseCategories.length])),
            accountId: d.Value(tradableAccounts[k % tradableAccounts.length]),
            happenedAt: d.Value(_randomHappenedAt(rnd, now)),
            note:
                d.Value('$marker测试账本流水 ${(k + 1).toString().padLeft(3, '0')}'),
            currencyCode: d.Value(base),
            nativeAmount: d.Value(amount),
          ));
          if (extraBatch.length >= 150) await flushExtra();
        }
        await flushExtra();
        created[DevSeedStage.transactions] =
            (created[DevSeedStage.transactions] ?? 0) + extraInserted;

        // 预算也按账本各来一套：切到测试账本时预算页不该是空状态。
        // 这些行随 deleteLedger 级联清理，不需要哨兵金额。
        try {
          await repo.createBudget(
            ledgerId: extraLedgerId,
            type: 'total',
            amount: _money(rnd, 5000, 50000),
            period: 'monthly',
            startDay: 1,
          );
          created[DevSeedStage.totalBudget] =
              (created[DevSeedStage.totalBudget] ?? 0) + 1;
          for (var b = 0;
              b < plan.extraLedgerBudgets && expenseCategories.isNotEmpty;
              b++) {
            await repo.createBudget(
              ledgerId: extraLedgerId,
              type: 'category',
              categoryId: expenseCategories[b % expenseCategories.length],
              amount: _money(rnd, 300, 5000),
              period: periods[b % periods.length],
              startDay: 1 + rnd.nextInt(28),
            );
            created[DevSeedStage.budgets] =
                (created[DevSeedStage.budgets] ?? 0) + 1;
          }
        } catch (e) {
          failed++;
          logger.warning('DevSeed', '创建测试账本预算失败(#$i): $e');
        }
      } catch (e) {
        failed++;
        logger.warning('DevSeed', '创建测试账本失败(#$i): $e');
      }
      onProgress?.call(DevSeedStage.ledgers, i + 1, plan.extraLedgers);
    }

    logger.info(
      'DevSeed',
      '测试数据生成完成: created=$created failed=$failed '
          'elapsed=${watch.elapsedMilliseconds}ms',
    );
    return DevSeedResult(
      created: created,
      cleaned: cleaned,
      failed: failed,
      elapsed: watch.elapsed,
    );
  }

  // ==========================================================================
  // 内部工具
  // ==========================================================================

  /// 是否为测试生成的总预算（靠哨兵金额识别，见 [seedTotalBudgetAmount]）。
  static bool _isSeedTotalBudget(double amount) =>
      (amount - seedTotalBudgetAmount).abs() < 0.005;

  /// 从回收站行里取出原交易的备注。
  ///
  /// `deleted_transactions.payload` 是 `Transaction.toJson()` 的 JSON 字符串
  /// （Drift 生成，key 为 snake_case），备注 key 正好是 `note`。
  static String? _noteOfPayload(String payload) {
    try {
      final decoded = jsonDecode(payload);
      if (decoded is Map<String, dynamic>) {
        final note = decoded['note'];
        if (note is String) return note;
      }
    } catch (e) {
      logger.warning('DevSeed', '解析回收站 payload 失败: $e');
    }
    return null;
  }

  /// 两位小数的随机金额。
  static double _money(math.Random rnd, double min, double max) {
    final value = min + rnd.nextDouble() * (max - min);
    return (value * 100).roundToDouble() / 100;
  }

  /// 最近 24 个月内的随机发生时刻（含本月；日取 1~28 规避月末差异）。
  static DateTime _randomHappenedAt(math.Random rnd, DateTime now) {
    final firstOfMonth = DateTime(now.year, now.month - rnd.nextInt(24), 1);
    return DateTime(
      firstOfMonth.year,
      firstOfMonth.month,
      1 + rnd.nextInt(28),
      rnd.nextInt(24),
      rnd.nextInt(60),
    );
  }
}
