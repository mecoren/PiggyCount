import 'package:drift/drift.dart' as d;
import 'package:flutter/foundation.dart' show compute;
import 'package:uuid/uuid.dart';
import '../cloud/sync/change_tracker.dart';
import '../cloud/transactions_json.dart';
import '../data/db.dart';
import '../data/models/custom_field_values.dart';
import '../data/repositories/base_repository.dart';
import '../data/repositories/local/local_repository.dart';
import '../data/repositories/transaction_repository.dart'
    show
        BatchAttachmentData,
        RecurringInstanceFingerprint,
        TransactionRepository;
import 'currency/rate_math.dart';
import 'system/logger_service.dart';

/// 统一的数据导入服务
///
/// 用于CSV导入和云端恢复，确保两者使用相同的导入逻辑

// --- 导入数据模型 ---

/// 导入账户数据
class ImportAccount {
  final String name;
  final String? type;
  final String? currency;
  final double? initialBalance;
  // 账户扩展字段（备份同步必须传输，否则恢复后信用卡/隐藏等属性丢失）
  final int? sortOrder;
  final double? creditLimit;
  final int? billingDay;
  final int? paymentDueDay;
  final String? bankName;
  final String? cardLastFour;
  final String? note;
  final bool? hidden;
  final String? syncId;

  const ImportAccount({
    required this.name,
    this.type,
    this.currency,
    this.initialBalance,
    this.sortOrder,
    this.creditLimit,
    this.billingDay,
    this.paymentDueDay,
    this.bankName,
    this.cardLastFour,
    this.note,
    this.hidden,
    this.syncId,
  });
}

/// 导入分类数据
class ImportCategory {
  final String name;
  final String kind; // 'income' or 'expense'
  final int level; // 1 or 2
  final int sortOrder; // 排序顺序
  final String? icon;
  final String? parentName; // 二级分类的父分类名称
  final String? iconType; // 图标类型: material / custom / community
  final String? customIconPath; // 自定义图标路径
  final String? communityIconId; // 社区图标ID
  /// v8 G3：分类 syncId。跨设备身份锚定（rename 后仍指向同一分类）。
  final String? syncId;

  const ImportCategory({
    required this.name,
    required this.kind,
    this.level = 1,
    this.sortOrder = 0,
    this.icon,
    this.parentName,
    this.iconType,
    this.customIconPath,
    this.communityIconId,
    this.syncId,
  });
}

/// 导入预算数据（v8 G1：快照恢复预算）
class ImportBudget {
  final String? syncId;
  final String type; // 'total' or 'category'
  final String? categoryName; // type == 'category' 时的分类名
  final double amount;
  final String period; // 'monthly' 等
  final int startDay;
  final bool enabled;

  const ImportBudget({
    this.syncId,
    required this.type,
    this.categoryName,
    required this.amount,
    this.period = 'monthly',
    this.startDay = 1,
    this.enabled = true,
  });
}

/// 导入周期规则数据（v8 G2：快照恢复周期记账）
class ImportRecurring {
  final String? syncId;
  final String type; // expense / income / transfer
  final double amount;
  final String? categoryName; // 分类引用（name 兜底锚点）
  final String? accountName;
  final String? accountSyncId; // 账户引用（syncId 优先锚点）
  final String? toAccountName;
  final String? toAccountSyncId;
  final String? note;
  final String frequency;
  final int interval;
  final int? dayOfMonth;
  final int? dayOfWeek;
  final int? monthOfYear;
  final DateTime startDate;
  final DateTime? endDate;
  /// 本机生成进度。导入取 max(local, cloud)，防止恢复旧快照后
  /// 生成器重放整段历史交易（sync_gap_closure 设计决策 2）。
  final DateTime? lastGeneratedDate;
  final bool enabled;

  /// v47:模板级自定义字段值({fieldSyncId: value})。
  /// null = 快照未携带该键(旧快照/模板未配置)。指纹把「缺键」与「空」
  /// 规范成同一个串,导入必须同语义:缺键 → 本地列写 NULL,否则已填值的
  /// 本地行与云端永远差一个键,表现为永不收敛的假冲突。
  final Map<String, dynamic>? templateFieldValues;

  const ImportRecurring({
    this.syncId,
    required this.type,
    required this.amount,
    this.categoryName,
    this.accountName,
    this.accountSyncId,
    this.toAccountName,
    this.toAccountSyncId,
    this.note,
    required this.frequency,
    this.interval = 1,
    this.dayOfMonth,
    this.dayOfWeek,
    this.monthOfYear,
    required this.startDate,
    this.endDate,
    this.lastGeneratedDate,
    this.enabled = true,
    this.templateFieldValues,
  });
}

/// 导入手动汇率覆盖（v8 G4）。业务键 (baseCurrency, quoteCurrency)。
class ImportRateOverride {
  final String baseCurrency;
  final String quoteCurrency;
  final double rate;

  /// 审计 TBL-M3：快照携带的跨设备身份锚点。此前导出写、解析丢，
  /// 恢复端身份重建为新 UUID，push/pull 的实体映射断裂。
  final String? syncId;

  const ImportRateOverride({
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.rate,
    this.syncId,
  });
}

/// 导入标签数据
class ImportTag {
  final String name;
  final String? color;
  final String? syncId;
  final int? sortOrder;

  const ImportTag({
    required this.name,
    this.color,
    this.syncId,
    this.sortOrder,
  });
}

/// 导入自定义字段定义（v46，快照恢复 / 导入）。
///
/// [syncId] 是跨设备锚点，也是交易值 map 的键：恢复时必须原样保留，
/// 否则交易上已存的值会因为键对不上而全部变成"野键"（定义看不见 → 不渲染）。
class ImportCustomField {
  final String name;
  final String fieldType; // amount / text / date
  final String? syncId;
  final int? sortOrder;

  const ImportCustomField({
    required this.name,
    this.fieldType = 'text',
    this.syncId,
    this.sortOrder,
  });
}

/// 导入附件数据
class ImportAttachment {
  final String fileName;
  final String? originalName;
  final int? fileSize;
  final int? width;
  final int? height;
  final int sortOrder;
  final String? cloudFileId;
  final String? cloudSha256;

  /// 快照链路内容哈希(attachment_binary_sync)。恢复端落列后据此
  /// 从 `attachments/<sha256>.bin` 后台补齐文件。
  final String? sha256;

  const ImportAttachment({
    required this.fileName,
    this.originalName,
    this.fileSize,
    this.width,
    this.height,
    this.sortOrder = 0,
    this.cloudFileId,
    this.cloudSha256,
    this.sha256,
  });
}

/// 导入交易数据
class ImportTransaction {
  final String type; // 'income', 'expense', 'transfer'
  final double amount;
  final String? categoryName;
  final String? categoryKind;
  final DateTime happenedAt;
  final String? note;
  final String? accountName; // 普通账户（收入/支出）
  final String? fromAccountName; // 转出账户（转账）
  final String? toAccountName; // 转入账户（转账）
  final List<String>? tagNames; // 标签名称列表
  final List<String>? tagSyncIds; // 标签 syncId 列表（优先于 tagNames 解析）
  final int? categoryId; // 预解析的分类ID（优先于categoryName）
  final List<ImportAttachment>? attachments; // 附件元数据列表
  final String? syncId; // 跨设备同步唯一标识
  /// v30 多币种:CSV 币种列(反馈10)。null → 账户币种/账本本位币兜底。
  final String? currencyCode;
  /// v30 多币种:折算到账本本位币的快照。JSON 同步时显式传输，避免
  /// 跨设备丢失（尤其外币账本，避免 modified 合并把 native 退化为旧值）。
  final double? nativeAmount;
  /// 账单标记：不计入统计。JSON 同步必须传输，否则跨设备后"不计入
  /// 统计"的交易变回计入 → 合计虚高。
  final bool excludeFromStats;
  /// 账单标记：不计入预算。同上，JSON 同步必须传输。
  final bool excludeFromBudget;
  /// v8 G2：周期规则锚点。导入后用于重建 transactions.recurringId。
  final String? recurringSyncId;
  /// v45 原始金额（用户手填票面/来源金额）。null = 未填写（或旧快照缺键），
  /// **原样落库为 NULL**；「默认金额 = amount」的语义由读取/统计侧的
  /// `COALESCE(original_amount, amount)` 承担。绝不在此兜底成 amount ——
  /// 那会让「快照缺键」与「手填同值」产生不同指纹，跨设备往返弹假冲突。
  final double? originalAmount;

  /// v46 自定义字段值 `{ fieldSyncId: value }`。
  ///
  /// null = **快照未携带该键**（旧版客户端导出），合并时保持本地原值；
  /// 空 map = 显式清空；非空 = 覆盖写入。与 [originalAmount] 同模式。
  final Map<String, dynamic>? customValues;

  const ImportTransaction({
    required this.type,
    required this.amount,
    this.currencyCode,
    this.nativeAmount,
    this.excludeFromStats = false,
    this.excludeFromBudget = false,
    this.categoryName,
    this.categoryKind,
    required this.happenedAt,
    this.note,
    this.accountName,
    this.fromAccountName,
    this.toAccountName,
    this.tagNames,
    this.tagSyncIds,
    this.categoryId,
    this.attachments,
    this.syncId,
    this.recurringSyncId,
    this.originalAmount,
    this.customValues,
  });
}

/// 导入投资持仓数据（v52：快照恢复 / 合并）。
///
/// ⚠️ 这里**只有可同步字段**。行情缓存三列（`quote_price` /
/// `quote_fetched_at` / `quote_source_id`）是本地专有列，**刻意不出现在本模型里**
/// —— 它们不进快照、不进指纹、合并时不得覆盖本地缓存。
class ImportHolding {
  final String? syncId;
  final String name;
  final String? symbol;
  /// 行情市场标识（SH / SZ / HK / US / FUND / CRYPTO），行情预留字段
  final String? market;
  final String? assetClass;
  final String? currency;
  final double? quantity;
  final double? unitCost;
  final double? unitPrice;
  /// 是否允许行情自动刷新（可同步，默认 false）
  final bool? autoQuote;
  final String? note;
  final int? sortOrder;

  /// 所属投资账户引用：**syncId 优先锚点**（跨设备 rename 后仍锚定同一账户）。
  final String? accountSyncId;
  /// 账户 name 兜底锚点（旧快照无 syncId 时用）。
  final String? accountName;

  const ImportHolding({
    required this.name,
    this.syncId,
    this.symbol,
    this.market,
    this.assetClass,
    this.currency,
    this.quantity,
    this.unitCost,
    this.unitPrice,
    this.autoQuote,
    this.note,
    this.sortOrder,
    this.accountSyncId,
    this.accountName,
  });
}

/// 导入储蓄目标（v12 / schema v53：快照恢复 / 合并）。
///
/// ⚠️ `updated_at` 是本地审计列（触发器维护），**刻意不出现在本模型里** —— 它
/// 不进快照、不进指纹，合并时也不得覆盖本地值。
class ImportSavingsGoal {
  final String? syncId;
  final String name;
  final double targetAmount;
  final String? currency;

  /// 关联账户引用：**syncId 优先锚点**（跨设备 rename 后仍锚定同一账户），
  /// `accountName` 兜底（旧快照 / 探不到 syncId 的遗留账户）。
  final String? accountSyncId;
  final String? accountName;

  /// 手动累计额（账户模式下不参与进度，但仍随快照往返）
  final double? savedAmount;
  final DateTime? startDate;
  final DateTime? targetDate;
  final String? note;
  final int? sortOrder;

  const ImportSavingsGoal({
    required this.name,
    required this.targetAmount,
    this.syncId,
    this.currency,
    this.accountSyncId,
    this.accountName,
    this.savedAmount,
    this.startDate,
    this.targetDate,
    this.note,
    this.sortOrder,
  });
}

/// 统一的导入数据格式
class ImportData {
  final List<ImportAccount> accounts;
  /// v52：投资持仓（user-global，随每个账本快照携带全量）
  final List<ImportHolding> holdings;
  final List<ImportCategory> categories;
  final List<ImportTag> tags;
  /// v46：账本自定义字段定义（快照恢复）
  final List<ImportCustomField> customFields;
  final List<ImportTransaction> transactions;
  /// v8 G1：预算（快照恢复）
  final List<ImportBudget> budgets;
  /// v12：储蓄目标（ledger-scoped，快照恢复）
  final List<ImportSavingsGoal> savingsGoals;
  /// v8 G2：周期规则（快照恢复）
  final List<ImportRecurring> recurrings;
  /// v8 G4：手动汇率覆盖（快照恢复）
  final List<ImportRateOverride> rateOverrides;

  /// 账本名称（可选，用于更新账本信息）
  final String? ledgerName;
  /// 货币（可选，用于更新账本信息）
  final String? currency;
  /// 每月起始日（可选，v8 G5：恢复时以云端快照为准回写账本元数据）
  final int? monthStartDay;
  /// v9：快照所属账本的 syncId（跨设备稳定身份）。恢复端用它回填本地
  /// 账本行缺失的 sync_id —— 否则纯快照（WebDAV/S3/iCloud）用户的
  /// legacy 账本永远没有跨设备身份，槽位命名与 push 锚点只能退回
  /// 本地数字 id（两台设备按数字撞名互覆的根源）。
  final String? ledgerSyncId;
  /// 快照 payload version（H1/H3：镜像删除仅在 v8+ 生效）
  final int? version;
  /// H1：解析时因字段损坏被跳过的条目数（key: accounts/categories/
  /// budgets/recurring/rateOverrides/tags/transactions/attachments），
  /// 供日志与 UI 提示
  final Map<String, int> skippedItems;

  const ImportData({
    this.accounts = const [],
    this.holdings = const [],
    this.categories = const [],
    this.tags = const [],
    this.customFields = const [],
    this.transactions = const [],
    this.budgets = const [],
    this.savingsGoals = const [],
    this.recurrings = const [],
    this.rateOverrides = const [],
    this.ledgerName,
    this.currency,
    this.monthStartDay,
    this.ledgerSyncId,
    this.version,
    this.skippedItems = const {},
  });
}

/// 导入结果
class ImportResult {
  final int inserted;
  final int failed;
  /// 因 recurring 周期实例去重而被跳过的交易条数（B 方案）。
  final int skippedRecurring;

  const ImportResult({
    required this.inserted,
    required this.failed,
    this.skippedRecurring = 0,
  });
}

// --- 数据导入服务 ---

/// 通用数据导入服务
///
/// 提供统一的导入逻辑，支持：
/// - 账户创建（全局按名称去重）
/// - 分类创建（先一级后二级）
/// - 标签创建
/// - 交易插入（批量写入）
/// - 标签关联
class DataImportService {
  /// 导入数据到指定账本
  ///
  /// [repo] - 数据仓库
  /// [ledgerId] - 目标账本ID
  /// [data] - 导入数据
  /// [defaultCurrency] - 默认货币（用于创建账户）
  /// [onProgress] - 进度回调 (done, total)
  /// [recordChanges] - 默认 true,会调 repo.insertTransactionsBatch 时登记
  ///   changeTracker。FullPull 路径传 false,避免"从云端拉下来的数据又反向推
  ///   回去"。
  Future<ImportResult> importData(
    BaseRepository repo,
    int ledgerId,
    ImportData data, {
    String defaultCurrency = 'CNY',
    void Function(int done, int total)? onProgress,
    bool recordChanges = true,
  }) async {
    // 1. 更新账本信息（如果提供）
    //    v8 G5：monthStartDay 一并回写 —— 纯快照(WebDAV 等)用户没有
    //    Cloud 引擎帮其收敛月起始日，恢复时以云端快照为准。
    if (data.ledgerName != null || data.currency != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          name: data.ledgerName,
          currency: data.currency,
        );
      } catch (e) {
        logger.warning('DataImport', '导入时回写账本名称/币种失败', e);
      }
    }
    if (data.monthStartDay != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          monthStartDay: data.monthStartDay!.clamp(1, 28),
        );
      } catch (e) {
        logger.warning('DataImport', '导入时回写月起始日失败', e);
      }
    }

    // 2. 导入账户
    final accountNameToId = await importAccounts(
      repo,
      data.accounts,
      defaultCurrency: data.currency ?? defaultCurrency,
    );

    // 2.1 v52 导入投资持仓。必须在「账户之后、任何用到净资产的逻辑之前」——
    //     持仓按账户 syncId/name 锚定，账户没落库就无处可挂。持仓是 user-global
    //     实体，快照已由所有账本携带全量，恢复任意一本即可收敛。
    await importHoldings(
      repo,
      data.holdings,
      accountNameToId: accountNameToId,
    );

    // 3. 导入分类
    final categoryCache = await importCategories(repo, data.categories);

    // 4. 导入标签
    final tagMaps = await importTags(repo, data.tags);
    final tagNameToId = tagMaps.byName;
    final tagSyncIdToId = tagMaps.bySyncId;

    // 4.1 v46 导入自定义字段定义。必须在交易之前：交易上的值以定义 syncId
    //     为键，定义先落库，编辑表单才能渲染出对应输入位。
    await importCustomFields(repo, ledgerId, data.customFields);

    // 5. 导入周期规则（v8 G2）。必须在交易之前 —— 交易的 recurringSyncId
    //    要靠这里产出的 syncId→id 映射回填 transactions.recurringId。
    final recurringSyncIdToId = await importRecurrings(
      repo,
      ledgerId,
      data.recurrings,
      accountNameToId: accountNameToId,
      categoryCache: categoryCache,
    );

    // 6. 导入预算 + 手动汇率（v8 G1/G4）
    await importBudgets(repo, ledgerId, data.budgets,
        categoryCache: categoryCache);
    // 6.1 v12 导入储蓄目标（ledger-scoped）。放在这里：不依赖交易，但依赖账户
    //     已落库（accountSyncId / accountName 锚定）。
    await importSavingsGoals(repo, ledgerId, data.savingsGoals,
        accountNameToId: accountNameToId);
    await importRateOverrides(repo, data.rateOverrides);

    // 7. 导入交易
    final result = await importTransactions(
      repo,
      ledgerId,
      data.transactions,
      accountNameToId: accountNameToId,
      categoryCache: categoryCache,
      tagNameToId: tagNameToId,
      tagSyncIdToId: tagSyncIdToId,
      recurringSyncIdToId: recurringSyncIdToId,
      onProgress: onProgress,
      recordChanges: recordChanges,
    );

    return result;
  }

  /// 导入账户(全局去重:syncId 优先匹配,name 兜底)。
  /// public — sync_diff_service 也复用,避免维护两套。
  Future<Map<String, int>> importAccounts(
    BaseRepository repo,
    List<ImportAccount> accounts,
    {String defaultCurrency = 'CNY'}
  ) async {
    final accountNameToId = <String, int>{};

    if (accounts.isEmpty) return accountNameToId;
    logger.info('AccountImport', '开始导入账户: ${accounts.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      final existingAccounts = await repo.getAllAccounts();
      // syncId 索引:跨设备稳定身份锚定(策略对齐 importTags)。
      // 仅按 name 去重会把「两台设备各自创建的同名账户」错并、
      // 「同一账户 rename 后」拆成两条(account_sync_fix G2)。
      final accountSyncIdToId = <String, int>{};
      final accountIdToSyncId = <int, String>{};
      // 账户实体索引：改名判定要比「云端名 vs 本地名」，写库判定要比「云端值
      // vs 本地值」。ImportAccount 的 name 必填恒非 null，拿非 null 当更新
      // 信号会对每个账户都做无意义 UPDATE（见下方 hasUpdates 注释）。
      final existingById = {for (final a in existingAccounts) a.id: a};
      for (final acc in existingAccounts) {
        accountNameToId[acc.name] = acc.id;
        if (acc.syncId != null && acc.syncId!.isNotEmpty) {
          accountSyncIdToId[acc.syncId!] = acc.id;
          accountIdToSyncId[acc.id] = acc.syncId!;
        }
      }

      // P2 定位用：单次 updateAccount 耗时抽样（合并路径实测单账本 61 个
      // 账户 30~54s，全量恢复路径同函数仅数百毫秒，先量化再定位）。
      final slowWrites = <(int, String)>[];
      for (final acc in accounts) {
        // 匹配优先级: ① syncId —— 跨设备 rename 后仍锚定同一账户;
        // ② name —— 旧快照(无 syncId)或本地账户无 syncId 时兜底。
        int? existingId;
        if (acc.syncId != null && acc.syncId!.isNotEmpty) {
          existingId = accountSyncIdToId[acc.syncId];
        }
        var matchedByName = false;
        if (existingId == null && accountNameToId.containsKey(acc.name)) {
          existingId = accountNameToId[acc.name];
          matchedByName = true;
        }

        if (existingId == null) {
          final id = await repo.createAccount(
            ledgerId: 0, // 账户独立,不绑定账本
            name: acc.name,
            type: acc.type ?? 'cash',
            currency: acc.currency ?? defaultCurrency,
            initialBalance: acc.initialBalance ?? 0.0,
            creditLimit: acc.creditLimit,
            billingDay: acc.billingDay,
            paymentDueDay: acc.paymentDueDay,
            bankName: acc.bankName,
            cardLastFour: acc.cardLastFour,
            note: acc.note,
            syncId: acc.syncId,
          );
          accountNameToId[acc.name] = id;
          if (acc.syncId != null && acc.syncId!.isNotEmpty) {
            accountSyncIdToId[acc.syncId!] = id;
            accountIdToSyncId[id] = acc.syncId!;
          }
          created++;
          // hidden / sortOrder 单独更新（createAccount 接口无此参数）
          if (acc.hidden != null) {
            await repo.updateAccount(id, hidden: acc.hidden);
          }
          if (acc.sortOrder != null) {
            await repo.updateAccountSortOrders([(id: id, sortOrder: acc.sortOrder!)]);
          }
        } else {
          // 已存在账户：仅当**云端值确实与本地不同**时才更新（null 表示
          // 云端未携带该字段 → 保持本地原值）。旧实现用「任一字段非 null」
          // 当信号，而完整快照里 type/currency 等恒非 null ⇒ 每轮合并把全部
          // 账户整表重写一遍：合并路径每个账本都会调一次 importAccounts，
          // 8 个账本 = 8 × 61 次单事务写（实测该阶段占单账本合并耗时的 75%，
          // 其中 7/8 是纯冗余——账户是 user-global，每个账本的快照都带同一份）。
          final existing = existingById[existingId];
          bool differs<T>(T? incoming, T? local) =>
              incoming != null && incoming != local;
          final localSyncId = accountIdToSyncId[existingId];
          // name 命中但本地无 syncId 时回填 incoming.syncId:让两台设备
          // 各自创建的同名账户收敛到同一身份,后续导出/同步按 syncId 锚定。
          final needBackfillSyncId =
              matchedByName && localSyncId == null && acc.syncId != null;
          // 改名：ImportAccount.name 必填（恒非 null），只能按「与本地名不同」
          // 判定。目标名已被**另一个**账户占用时保守跳过 rename —— accounts
          // 表无 name 唯一约束，强改会让后续按 name 兜底匹配指错账户，
          // 策略与 importTags 的「目标名被占用则跳过改名」一致。
          final existingName = existing?.name;
          final renameTaken = accountNameToId[acc.name] != null &&
              accountNameToId[acc.name] != existingId;
          final needRename = existing != null &&
              acc.name.isNotEmpty &&
              acc.name != existingName &&
              !renameTaken;
          final hasUpdates = existing != null &&
              (needRename ||
                  needBackfillSyncId ||
                  differs(acc.type, existing.type) ||
                  differs(acc.currency, existing.currency) ||
                  differs(acc.initialBalance, existing.initialBalance) ||
                  differs(acc.creditLimit, existing.creditLimit) ||
                  differs(acc.billingDay, existing.billingDay) ||
                  differs(acc.paymentDueDay, existing.paymentDueDay) ||
                  differs(acc.bankName, existing.bankName) ||
                  differs(acc.cardLastFour, existing.cardLastFour) ||
                  differs(acc.note, existing.note) ||
                  differs(acc.hidden, existing.hidden) ||
                  differs(acc.sortOrder, existing.sortOrder));
          if (hasUpdates) {
            final writeSw = Stopwatch()..start();
            await repo.updateAccount(
              existingId,
              name: needRename ? acc.name : null,
              type: acc.type,
              currency: acc.currency,
              initialBalance: acc.initialBalance,
              creditLimit: acc.creditLimit,
              billingDay: acc.billingDay,
              paymentDueDay: acc.paymentDueDay,
              bankName: acc.bankName,
              cardLastFour: acc.cardLastFour,
              note: acc.note,
              hidden: acc.hidden,
              syncId: needBackfillSyncId ? acc.syncId : null,
            );
            writeSw.stop();
            if (writeSw.elapsedMilliseconds >= 50) {
              slowWrites.add((writeSw.elapsedMilliseconds, acc.name));
            }
            if (needBackfillSyncId && acc.syncId != null) {
              accountSyncIdToId[acc.syncId!] = existingId;
              accountIdToSyncId[existingId] = acc.syncId!;
            }
            if (needRename) {
              // 改名落库后同步置换内存索引，否则同一批后续引用旧名的条目
              // 仍会命中本账户（反过来新名会被判为「未占用」而重复建）。
              accountNameToId.remove(existingName);
              existingById[existingId] = existing.copyWith(name: acc.name);
            }
            // 目标名未被他人占用时刷新 name 映射，后续交易按新 name 引用
            // 才能命中该账户；已被占用则不抢占他人映射。
            if (!renameTaken) accountNameToId[acc.name] = existingId;
            if (acc.sortOrder != null) {
              await repo.updateAccountSortOrders([
                (id: existingId, sortOrder: acc.sortOrder!)
              ]);
            }
            updated++;
          }
        }
      }
      logger.info('AccountImport',
          '账户导入完成: 新增=$created 更新=$updated 耗时=${sw.elapsedMilliseconds}ms');
      if (slowWrites.isNotEmpty) {
        slowWrites.sort((a, b) => b.$1.compareTo(a.$1));
        logger.debug('AccountImport',
            '[perf] 慢写 top${slowWrites.length > 3 ? 3 : slowWrites.length}: '
            '${slowWrites.take(3).map((e) => '${e.$1}ms(${e.$2})').join(' ')}');
      }
    } catch (e, st) {
      logger.error('AccountImport', '账户导入失败', e, st);
    }

    return accountNameToId;
  }

  /// 导入投资持仓（v52）。public — sync_diff_service 的合并路径复用。
  ///
  /// 匹配锚点：① syncId（跨设备 rename 后仍锚定同一持仓）；② `accountId|name`
  /// 业务键兜底（旧快照无 syncId 时用）。
  ///
  /// 账户锚点：先按 `accountSyncId` 查本地账户，未命中再按 `accountName`；
  /// **两者都未命中时跳过该条**——绝不创建悬空 `account_id` 的持仓（那会让
  /// 一个不存在的账户凭空多出金额，且对端每次同步都要重新处理）。
  ///
  /// ⚠️ 行情缓存三列（quote_price / quote_fetched_at / quote_source_id）是
  /// 本地专有列，本方法**一概不写**；导入/合并都不得覆盖本机已拉到的行情。
  Future<void> importHoldings(
    BaseRepository repo,
    List<ImportHolding> holdings, {
    required Map<String, int> accountNameToId,
  }) async {
    if (holdings.isEmpty) return;

    logger.info('HoldingImport', '开始导入投资持仓: ${holdings.length} 条');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;
    int skipped = 0;

    try {
      // 账户索引（syncId 优先锚点 + id→币种兜底）。账户数量级几十条，一次全量读足够。
      final accountSyncIdToId = <String, int>{};
      final accountCurrencyById = <int, String>{};
      for (final a in await repo.getAllAccounts()) {
        accountCurrencyById[a.id] = a.currency;
        final sid = a.syncId;
        if (sid != null && sid.isNotEmpty) accountSyncIdToId[sid] = a.id;
      }

      final existing = await repo.getAllHoldings();
      final existingBySyncId = <String, Holding>{};
      final existingByBizKey = <String, Holding>{};
      for (final h in existing) {
        final sid = h.syncId;
        if (sid != null && sid.isNotEmpty) existingBySyncId[sid] = h;
        existingByBizKey['${h.accountId}|${h.name}'] = h;
      }

      for (final h in holdings) {
        // ① 定位所属账户
        int? accountId;
        final accountSyncId = h.accountSyncId;
        if (accountSyncId != null && accountSyncId.isNotEmpty) {
          accountId = accountSyncIdToId[accountSyncId];
        }
        final accountName = h.accountName;
        if (accountId == null && accountName != null) {
          accountId = accountNameToId[accountName];
        }
        if (accountId == null) {
          skipped++;
          logger.debug('HoldingImport',
              '持仓「${h.name}」的账户在本机未命中'
              '(syncId=$accountSyncId / name=$accountName) → 跳过');
          continue;
        }

        // ② 匹配本地已有持仓
        Holding? matched;
        final syncId = h.syncId;
        if (syncId != null && syncId.isNotEmpty) {
          matched = existingBySyncId[syncId];
        }
        matched ??= existingByBizKey['$accountId|${h.name}'];

        if (matched == null) {
          await repo.createHolding(
            accountId: accountId,
            name: h.name,
            // 账户币种兜底：持仓币种缺失时跟随账户，不落成硬编码 'CNY'。
            currency: h.currency ?? accountCurrencyById[accountId] ?? 'CNY',
            symbol: h.symbol,
            market: h.market,
            assetClass: h.assetClass ?? 'other',
            quantity: h.quantity ?? 0.0,
            unitCost: h.unitCost ?? 0.0,
            unitPrice: h.unitPrice ?? 0.0,
            autoQuote: h.autoQuote ?? false,
            note: h.note,
            sortOrder: h.sortOrder,
            syncId: syncId,
          );
          created++;
        } else {
          // 与 importAccounts 同款：只在「云端值非 null 且确实与本地不同」时才写。
          // **绝不把「缺键」当清空信号** —— 那是 v45/v46/v47 反复踩过的假冲突
          // 来源；而且持仓是 user-global，每个账本快照都带同一份，无脑整表重写
          // 会让 N 个账本各写一遍（importAccounts 注释实测这是合并耗时大头）。
          bool differs<T>(T? incoming, T? local) =>
              incoming != null && incoming != local;
          final localSyncId = matched.syncId;
          final needBackfillSyncId =
              (localSyncId == null || localSyncId.isEmpty) &&
                  syncId != null &&
                  syncId.isNotEmpty;
          final needRename = h.name.isNotEmpty && h.name != matched.name;
          final hasUpdates = needRename ||
              needBackfillSyncId ||
              differs(h.symbol, matched.symbol) ||
              differs(h.market, matched.market) ||
              differs(h.assetClass, matched.assetClass) ||
              differs(h.currency, matched.currency) ||
              differs(h.quantity, matched.quantity) ||
              differs(h.unitCost, matched.unitCost) ||
              differs(h.unitPrice, matched.unitPrice) ||
              differs(h.autoQuote, matched.autoQuote) ||
              differs(h.note, matched.note) ||
              differs(h.sortOrder, matched.sortOrder);
          if (hasUpdates) {
            await repo.updateHolding(
              matched.id,
              name: needRename ? h.name : null,
              symbol: h.symbol,
              market: h.market,
              assetClass: h.assetClass,
              currency: h.currency,
              quantity: h.quantity,
              unitCost: h.unitCost,
              unitPrice: h.unitPrice,
              autoQuote: h.autoQuote,
              note: h.note,
              sortOrder: h.sortOrder,
              // 身份对齐：本地缺 syncId 时回填云端身份（同 importCategories）
              syncId: needBackfillSyncId ? syncId : null,
            );
            updated++;
          }
        }
      }

      logger.info('HoldingImport',
          '投资持仓导入完成: 新增=$created 更新=$updated 跳过=$skipped '
          '耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('HoldingImport', '投资持仓导入失败', e, st);
    }
  }

  /// 导入分类(先一级后二级)。public — sync_diff_service 复用。
  ///
  /// 匹配锚点：① syncId（v8 G3，rename 后仍指向同一分类）
  /// ② kind|name 业务键（(name,kind) 联合唯一约束即此键）。
  /// 命中后若本地 syncId 缺失或与云端不同 → 回填对齐云端身份：
  /// 两台设备独立创建的同名分类若各自保留本地 syncId，指纹（含分类
  /// syncId）两端永久不一致，合并后互相覆盖 ping-pong（sync_convergence_fix）。
  Future<Map<String, int>> importCategories(
    BaseRepository repo,
    List<ImportCategory> categories,
  ) async {
    final categoryCache = <String, int>{}; // key: kind|name -> id

    if (categories.isEmpty) return categoryCache;
    logger.info('CategoryImport', '开始导入分类: ${categories.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      // 全量分类建索引。之前只查 expense/income 两种 kind，transfer 等
      // 其他 kind（如内置「转账」）不在索引里 → 走 createCategory →
      // 撞 (name,kind) 联合唯一约束抛 DuplicateNameException → 整个
      // 分类导入中止，本地/云端分类集永不收敛，启动同步死循环。
      final all = await repo.getAllCategories();
      final bySyncId = <String, int>{};
      final byKindName = <String, int>{};
      final syncIdById = <int, String>{};
      // 本地原名/原业务键索引：ImportCategory.name 必填（恒非 null），改名
      // 判定只能比较「云端名 vs 本地名」；改名会同时置换业务键 kind|name。
      final nameById = <int, String>{};
      final kindNameById = <int, String>{};
      for (final c in all) {
        byKindName['${c.kind}|${c.name}'] = c.id;
        nameById[c.id] = c.name;
        kindNameById[c.id] = '${c.kind}|${c.name}';
        if (c.syncId != null && c.syncId!.isNotEmpty) {
          bySyncId[c.syncId!] = c.id;
          syncIdById[c.id] = c.syncId!;
        }
      }

      // 匹配或创建单个分类；返回 id（失败返回 null，不中断循环）
      Future<int?> matchOrCreate(ImportCategory cat, {int? parentId}) async {
        final key = '${cat.kind}|${cat.name}';
        // ① syncId 锚定
        int? id;
        if (cat.syncId != null && cat.syncId!.isNotEmpty) {
          id = bySyncId[cat.syncId];
        }
        // ② kind|name 业务键兜底
        id ??= byKindName[key];

        if (id != null) {
          // 命中：① 对齐云端 syncId（云端身份优先，null 不覆盖本地）
          //      ② 回写云端改名（与 importTags 同口径；此前只对齐 syncId，
          //        导致 A 端改分类名后 B 端永远拿不到新名）
          final localSyncId = syncIdById[id];
          final needAlignSyncId = cat.syncId != null &&
              cat.syncId!.isNotEmpty &&
              cat.syncId != localSyncId;
          // 目标 kind|name 已被**另一条**分类占用时保守跳过 rename：
          // categories 有 (name,kind) 业务唯一约束，强改会抛
          // DuplicateNameException 并中止整批导入（见上方历史事故注释）。
          final renameTaken =
              byKindName[key] != null && byKindName[key] != id;
          final localName = nameById[id];
          final needRename = cat.name.isNotEmpty &&
              localName != null &&
              cat.name != localName &&
              !renameTaken;
          if (needAlignSyncId || needRename) {
            await repo.updateCategory(
              id,
              name: needRename ? cat.name : null,
              syncId: needAlignSyncId ? cat.syncId : null,
            );
            if (needAlignSyncId) {
              bySyncId[cat.syncId!] = id;
              syncIdById[id] = cat.syncId!;
            }
            if (needRename) {
              // 同步置换内存业务键索引，否则同一批后续引用旧 kind|name 的
              // 条目仍命中本分类、引用新名的条目会被判为空闲而重复建。
              final oldKey = kindNameById[id];
              if (oldKey != null) byKindName.remove(oldKey);
              kindNameById[id] = key;
              nameById[id] = cat.name;
            }
            updated++;
          }
          categoryCache[key] = id;
          if (!renameTaken) byKindName[key] = id;
          return id;
        }

        // 新建。单个失败只记日志继续 —— 之前整个循环共用一个 try，
        // 一条坏数据会吞掉剩余所有分类的导入
        try {
          final newId = parentId != null
              // 必须透传云端 syncId：repo 在 syncId 为 null 时会自动生成新 UUID，
              // 导致本地分类与云端快照的 syncId 不一致，随后被 H3 镜像删除
              // （按 syncId 判定"本地有、云端无"）误删。与 importAccounts 保持一致。
              ? await repo.createSubCategory(
                  parentId: parentId,
                  name: cat.name,
                  kind: cat.kind,
                  icon: cat.icon,
                  sortOrder: cat.sortOrder,
                  syncId: cat.syncId,
                )
              : await repo.createCategory(
                  name: cat.name,
                  kind: cat.kind,
                  icon: cat.icon,
                  sortOrder: cat.sortOrder,
                  syncId: cat.syncId,
                );
          categoryCache[key] = newId;
          byKindName[key] = newId;
          if (cat.syncId != null && cat.syncId!.isNotEmpty) {
            bySyncId[cat.syncId!] = newId;
            syncIdById[newId] = cat.syncId!;
          }
          created++;

          // 如果有自定义图标信息，更新图标
          if (cat.iconType != null && cat.iconType != 'material') {
            await repo.updateCategoryIcon(
              newId,
              iconType: cat.iconType!,
              icon: cat.icon,
              customIconPath: cat.customIconPath,
              communityIconId: cat.communityIconId,
            );
          }
          return newId;
        } catch (e) {
          logger.warning(
              'CategoryImport', '分类创建失败(跳过继续): ${cat.kind}|${cat.name} - $e');
          return null;
        }
      }

      // 分离一级和二级分类（二级依赖一级先落库/命中以解析 parentId）
      final level1 =
          categories.where((c) => c.level == 1 || c.parentName == null).toList();
      final level2 =
          categories.where((c) => c.level == 2 && c.parentName != null).toList();

      for (final cat in level1) {
        await matchOrCreate(cat);
      }
      for (final cat in level2) {
        // 父分类先从缓存解析；解析不到时尝试按 kind|parentName 匹配建父
        final parentKey = '${cat.kind}|${cat.parentName}';
        final parentId = categoryCache[parentKey] ?? byKindName[parentKey];
        if (parentId != null) {
          await matchOrCreate(cat, parentId: parentId);
        }
      }
      logger.info('CategoryImport',
          '分类导入完成: 新增=$created 更新=$updated 已存在=${categories.length - created - updated} 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('CategoryImport', '分类导入失败', e, st);
    }

    return categoryCache;
  }

  /// 导入自定义字段定义（v46，快照恢复 / 增量合并共用）。
  ///
  /// 匹配优先级与 [importTags] 一致：syncId 优先（跨设备 rename 后仍稳定
  /// 锚定），name 兜底。已存在的定义以**远端为准**对齐 fieldType/sortOrder
  /// —— 否则云端改过的类型/排序在本地永远不收敛，两端指纹永久不同 →
  /// 每次启动都判 cloudNewer。name 撞车（目标名已被同账本另一字段占用）时
  /// 保守跳过改名，避免账本内重名脏数据。
  ///
  /// 值（custom_values_json）不在这里处理：它随交易条目落库（见
  /// [importTransactions]），因为值的键就是定义的 syncId，定义先落库即可。
  Future<void> importCustomFields(
    BaseRepository repo,
    int ledgerId,
    List<ImportCustomField> fields,
  ) async {
    if (fields.isEmpty) return;

    final existing = await repo.getDefinitionsForLedger(ledgerId);
    final byName = <String, CustomFieldDefinition>{
      for (final f in existing) f.name: f,
    };
    final bySyncId = <String, CustomFieldDefinition>{
      for (final f in existing)
        if (f.syncId != null && f.syncId!.isNotEmpty) f.syncId!: f,
    };

    for (final field in fields) {
      final sid = (field.syncId != null && field.syncId!.trim().isNotEmpty)
          ? field.syncId!.trim()
          : null;
      final current = (sid != null ? bySyncId[sid] : null) ?? byName[field.name];

      if (current == null) {
        final id = await repo.upsertDefinition(
          ledgerId: ledgerId,
          name: field.name,
          fieldType: field.fieldType,
          sortOrder: field.sortOrder,
          syncId: field.syncId,
        );
        final created = await repo.getDefinitionById(id);
        if (created != null) {
          byName[created.name] = created;
          if (created.syncId != null && created.syncId!.isNotEmpty) {
            bySyncId[created.syncId!] = created;
          }
        }
        continue;
      }

      final renaming = field.name != current.name;
      final needType = current.fieldType != field.fieldType;
      final needSort =
          field.sortOrder != null && field.sortOrder != current.sortOrder;
      if (!renaming && !needType && !needSort) continue;

      // 改名撞车：目标名已被同账本另一字段占用 → 只对齐类型/排序。
      final renameBlocked = renaming && byName.containsKey(field.name);

      await repo.updateDefinition(
        current.id,
        name: renameBlocked ? null : (renaming ? field.name : null),
        fieldType: field.fieldType,
        sortOrder: field.sortOrder,
      );

      final updated = await repo.getDefinitionById(current.id);
      if (updated != null) {
        if (renaming && !renameBlocked) byName.remove(current.name);
        byName[updated.name] = updated;
        if (updated.syncId != null && updated.syncId!.isNotEmpty) {
          bySyncId[updated.syncId!] = updated;
        }
      }
    }
  }

  /// **D-4**：增量合并路径的「自定义字段定义」镜像删除（对齐恢复路径的 H3）。
  ///
  /// 背景：全量恢复由 `_mirrorDeleteAbsentEntities` 负责镜像删除（version ≥ 8
  /// 门控，其中就有自定义字段分支）；而**增量合并**此前只调 [importCustomFields]
  /// （upsert-only、无删除分支）→「A 端删掉字段定义」在对端**永不传播**。
  /// 设备端实测：A 删 8 个定义 → B「下载同步」零变更 → B merge-then-publish
  /// 又把它们写回云端 → A 再同步时 8 个定义**全部回来**。
  ///
  /// 与恢复路径的一处关键差异（不处理会引入新缺陷）：恢复路径的交易行被
  /// `clearLedgerTransactions` 整体清空后重导，引用被删定义的值随之消失；
  /// **合并路径的行是保留的**，故这里走 `repo.deleteDefinition` —— 它按仓储
  /// 职责**连带清理交易值与周期模板里的同名键**，不留孤儿键
  /// （定义没了，值键既渲染不出又会让快照带幽灵字段）。
  ///
  /// 保守规则与恢复路径一致：**只删"本地已有 syncId"的行**。无 syncId 是本机
  /// 新建、尚未上传过的字段，云端"缺席"不等于用户删过它。
  ///
  /// [version] 为快照 payload version；`null` 或 < 8 → 视为旧快照，**不删**
  /// （旧快照可能根本不携带 `customFields` 段，"云端缺席"不具备删除语义）——
  /// 与 `_mirrorDeleteAbsentEntities` 的门控完全相同。
  ///
  /// 返回删除的定义数。
  Future<int> mirrorDeleteAbsentCustomFields({
    required BaseRepository repo,
    required int ledgerId,
    required List<ImportCustomField> cloudFields,
    required int? version,
  }) async {
    if (version == null || version < 8) return 0;
    final cloudSyncIds = cloudFields
        .map((f) => f.syncId)
        .whereType<String>()
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toSet();
    final existing = await repo.getDefinitionsForLedger(ledgerId);
    var deleted = 0;
    for (final def in existing) {
      final sid = def.syncId;
      if (sid == null || sid.isEmpty) continue; // 本机新建未上传 → 保留
      if (cloudSyncIds.contains(sid)) continue; // 云端仍在 → 保留
      try {
        await repo.deleteDefinition(def.id); // 连带清值（仓储职责）
        deleted++;
      } catch (e, st) {
        logger.error('DataImport',
            'D-4 删除自定义字段定义失败 id=${def.id}', e, st);
      }
    }
    if (deleted > 0) {
      logger.info('DataImport',
          'D-4 镜像删除自定义字段定义(ledgerId=$ledgerId): $deleted 个'
          '（对端已删；已连带清理交易值/模板值）');
    }
    return deleted;
  }

  /// 导入标签。返回 byName + bySyncId 两个映射：
  /// - byName：标签名 → 本地 id（CSV/老 JSON 兜底匹配用）
  /// - bySyncId：标签 syncId → 本地 id（v7 JSON 跨设备稳定匹配，避免 rename 错挂）
  Future<({Map<String, int> byName, Map<String, int> bySyncId})>
      importTags(
    BaseRepository repo,
    List<ImportTag> tags,
  ) async {
    final tagNameToId = <String, int>{};
    final tagSyncIdToId = <String, int>{};

    if (tags.isEmpty) {
      return (byName: tagNameToId, bySyncId: tagSyncIdToId);
    }

    logger.info('TagImport', '开始导入标签: ${tags.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      final existingTags = await repo.getAllTags();
      final existingTagMap = <String, Tag>{};
      final existingTagById = <int, Tag>{};
      for (final tag in existingTags) {
        tagNameToId[tag.name] = tag.id;
        existingTagMap[tag.name] = tag;
        existingTagById[tag.id] = tag;
        if (tag.syncId != null && tag.syncId!.isNotEmpty) {
          tagSyncIdToId[tag.syncId!] = tag.id;
        }
      }

      // 单条 await 循环 — 标签量通常小(<100),没批量接口暂保持,但去掉 per-row
      // INFO 日志:N 个标签会打 3N 条 INFO,把 logger 队列冲爆,导致后续 import
      // 阶段的日志被淹没,用户感知"日志不全"。
      for (final tag in tags) {
        // 优先按 syncId 匹配已存在标签（跨设备 rename 后仍能稳定锚定）
        int? existingIdBySyncId;
        if (tag.syncId != null && tag.syncId!.isNotEmpty) {
          existingIdBySyncId = tagSyncIdToId[tag.syncId];
        }
        final existingByName = existingTagMap[tag.name];

        if (existingIdBySyncId == null && existingByName == null) {
          // 新建：带 syncId（若 JSON 有）和 sortOrder
          final id = await repo.createTag(
            name: tag.name,
            color: tag.color,
            sortOrder: tag.sortOrder ?? 0,
            syncId: tag.syncId,
          );
          tagNameToId[tag.name] = id;
          if (tag.syncId != null && tag.syncId!.isNotEmpty) {
            tagSyncIdToId[tag.syncId!] = id;
          }
          created++;
        } else if (existingIdBySyncId != null) {
          // 按 syncId 命中已存在：用非 null 字段更新（color/sortOrder）
          final existingTag = existingTagById[existingIdBySyncId]!;
          var needUpdate = false;
          String? newColor = existingTag.color;
          int? newSortOrder;
          if (tag.color != null && tag.color != existingTag.color) {
            newColor = tag.color;
            needUpdate = true;
          }
          if (tag.sortOrder != null && tag.sortOrder != existingTag.sortOrder) {
            newSortOrder = tag.sortOrder;
            needUpdate = true;
          }
          // name 也可能更新（远端 rename 了）。撞同名（目标 name 已被另一个
          // tag 占用）时跳过 rename 保持原名 —— Tags 表无 DB 唯一约束，
          // 强行 rename 会产生两个同名脏标签。保守跳过比产生脏数据安全。
          if (tag.name != existingTag.name &&
              (tagNameToId.containsKey(tag.name))) {
            // 目标名已被占用：本行不改名，仅更新 color/sortOrder
            if (needUpdate) {
              await repo.updateTag(existingTag.id,
                  color: newColor, sortOrder: newSortOrder);
              updated++;
            }
          } else if (tag.name != existingTag.name) {
            await repo.updateTag(existingTag.id,
                name: tag.name, color: newColor, sortOrder: newSortOrder);
            tagNameToId.remove(existingTag.name);
            tagNameToId[tag.name] = existingTag.id;
            // 同步更新内存 map：existingTagMap 按 name 索引，避免后续同 JSON
            // 里其他 tag 引用旧名字时解析到已改名的行。
            existingTagMap.remove(existingTag.name);
            existingTagMap[tag.name] = existingTag;
            updated++;
          } else if (needUpdate) {
            await repo.updateTag(existingTag.id,
                color: newColor, sortOrder: newSortOrder);
            updated++;
          }
        } else if (existingByName != null) {
          // 仅 name 命中（本地无 syncId、JSON 有 syncId 或都没有）
          // 用非 null 字段更新；若本地 syncId 缺失且 JSON 带了，需要回填
          var needUpdate = false;
          String? newColor = existingByName.color;
          int? newSortOrder;
          if (tag.color != null && tag.color != existingByName.color) {
            newColor = tag.color;
            needUpdate = true;
          }
          if (tag.sortOrder != null &&
              tag.sortOrder != existingByName.sortOrder) {
            newSortOrder = tag.sortOrder;
            needUpdate = true;
          }
          if (needUpdate) {
            await repo.updateTag(existingByName.id,
                color: newColor, sortOrder: newSortOrder);
            updated++;
          }
          // 回填 syncId：本地缺失时用 JSON 带的 syncId 补上。否则下次导出
          // 该 tag 仍无 syncId、交易 tagSyncIds 无法锚定（#6 闭环断裂）。
          if (tag.syncId != null &&
              tag.syncId!.isNotEmpty &&
              (existingByName.syncId == null ||
                  existingByName.syncId!.isEmpty)) {
            await repo.updateTagSyncId(existingByName.id, tag.syncId!);
            updated++;
          }
          if (tag.syncId != null && tag.syncId!.isNotEmpty) {
            tagSyncIdToId[tag.syncId!] = existingByName.id;
          }
        }
      }
      logger.info('TagImport',
          '标签导入完成: 新增=$created 更新=$updated 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('TagImport', '标签导入失败', e, st);
    }

    return (byName: tagNameToId, bySyncId: tagSyncIdToId);
  }

  /// 导入周期规则（v8 G2，sync_gap_closure）
  ///
  /// 合并策略（对齐设计文档决策 3，upsert-only 不删本地多余项）：
  /// ① syncId 命中 → 整行以快照为准更新，lastGeneratedDate 取
  ///    max(local, cloud) —— 防止恢复旧快照后生成器重放历史交易；
  /// ② 业务键（type|note|frequency|amount|dayOfMonth）兜底命中 →
  ///    同上更新并回填 syncId（本地建的同规则收敛到同一身份）；
  /// ③ 都未命中 → 新建。
  ///
  /// 返回 syncId → 本地 id 映射：importTransactions 靠它把交易的
  /// recurringSyncId 翻译回 transactions.recurringId int 外键。
  Future<Map<String, int>> importRecurrings(
    BaseRepository repo,
    int ledgerId,
    List<ImportRecurring> recurrings, {
    required Map<String, int> accountNameToId,
    required Map<String, int> categoryCache,
  }) async {
    final recurringSyncIdToId = <String, int>{};
    if (recurrings.isEmpty) return recurringSyncIdToId;

    logger.info('RecurringImport', '开始导入周期规则: ${recurrings.length} 条');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;
    int failed = 0;

    try {
      // 解析引用锚点：账户（syncId 优先、name 兜底）、分类（name）。
      // categoryCache 键是 'kind|name'，recurring 快照只带 categoryName
      // —— 剥掉 kind 前缀建 name→id 映射；跨 kind 同名分类极少见，
      // 命中歧义时后写覆盖（预算分类同理）。
      final categoryNameToId = <String, int>{};
      for (final e in categoryCache.entries) {
        final idx = e.key.indexOf('|');
        categoryNameToId[e.key.substring(idx + 1)] = e.value;
      }
      final accountSyncIdToId = <String, int>{};
      for (final a in await repo.getAllAccounts()) {
        if (a.syncId != null && a.syncId!.isNotEmpty) {
          accountSyncIdToId[a.syncId!] = a.id;
        }
      }

      final existing =
          await repo.getRecurringTransactionsByLedger(ledgerId);
      final existingBySyncId = <String, RecurringTransaction>{};
      final existingByBizKey = <String, RecurringTransaction>{};
      String bizKey(String type, String? note, String frequency, double amount,
              int? dayOfMonth) =>
          '$type|${note ?? ''}|$frequency|${amount.toStringAsFixed(2)}|${dayOfMonth ?? ''}';
      for (final r in existing) {
        if (r.syncId != null && r.syncId!.isNotEmpty) {
          existingBySyncId[r.syncId!] = r;
        }
        existingByBizKey[bizKey(
            r.type, r.note, r.frequency, r.amount, r.dayOfMonth)] = r;
      }

      // REC-03 修复：单条规则失败只跳过该条并记 error，不中断其余规则。
      // 此前 try 包住整个循环，一条规则抛异常会中断其后所有规则的导入，
      // 这些规则的 syncId 全部缺失映射 → 对应交易以 recurringId=null
      // 落库，恢复侧 (recurringId, happenedAt) 去重随之失效，且调用方无感知。
      for (final r in recurrings) {
        try {
          // 引用解析：syncId 优先，name 兜底；都失败置 null + warning
          // （与交易缺分类的容错一致，不阻断整体导入）。
          int? categoryId;
          if (r.categoryName != null) {
            categoryId = categoryNameToId[r.categoryName];
            if (categoryId == null) {
              logger.warning('RecurringImport',
                  '周期规则分类未命中: "${r.categoryName}" → 置空');
            }
          }
          int? accountId;
          if (r.accountSyncId != null && r.accountSyncId!.isNotEmpty) {
            accountId = accountSyncIdToId[r.accountSyncId];
          }
          accountId ??= (r.accountName != null
              ? accountNameToId[r.accountName]
              : null);
          int? toAccountId;
          if (r.toAccountSyncId != null && r.toAccountSyncId!.isNotEmpty) {
            toAccountId = accountSyncIdToId[r.toAccountSyncId];
          }
          toAccountId ??= (r.toAccountName != null
              ? accountNameToId[r.toAccountName]
              : null);

          // 匹配：① syncId ② 业务键
          RecurringTransaction? matched;
          var matchedByBizKey = false;
          if (r.syncId != null && r.syncId!.isNotEmpty) {
            matched = existingBySyncId[r.syncId];
          }
          if (matched == null) {
            final key = bizKey(
                r.type, r.note, r.frequency, r.amount, r.dayOfMonth);
            matched = existingByBizKey[key];
            matchedByBizKey = matched != null;
          }

          if (matched == null) {
            final id = await repo.addRecurringTransaction(
              ledgerId: ledgerId,
              type: r.type,
              amount: r.amount,
              categoryId: categoryId,
              accountId: accountId,
              toAccountId: toAccountId,
              note: r.note,
              frequency: r.frequency,
              interval: r.interval,
              dayOfMonth: r.dayOfMonth,
              dayOfWeek: r.dayOfWeek,
              monthOfYear: r.monthOfYear,
              startDate: r.startDate,
              endDate: r.endDate,
              enabled: r.enabled,
              syncId: r.syncId,
              templateFieldValues: r.templateFieldValues,
            );
            created++;
            if (r.syncId != null && r.syncId!.isNotEmpty) {
              recurringSyncIdToId[r.syncId!] = id;
            }
          } else {
            // 已存在：整行以快照为准更新；lastGeneratedDate 取 max 防
            // 旧快照回退进度 → 生成器重放整段历史交易。
            final mergedLastGen = _maxDate(
                matched.lastGeneratedDate, r.lastGeneratedDate);
            await repo.updateRecurringTransaction(
              id: matched.id,
              ledgerId: ledgerId,
              type: r.type,
              amount: r.amount,
              categoryId: categoryId,
              accountId: accountId,
              toAccountId: toAccountId,
              note: r.note,
              frequency: r.frequency,
              interval: r.interval,
              dayOfMonth: r.dayOfMonth,
              dayOfWeek: r.dayOfWeek,
              monthOfYear: r.monthOfYear,
              startDate: r.startDate,
              endDate: r.endDate,
              enabled: r.enabled,
              lastGeneratedDate: mergedLastGen,
              // v47 模板值:快照未携带该键 → null → 本地列清 NULL。必须与
              // 指纹语义一致(缺键 == ''),否则已填值的本地行与云端永远差
              // 一个键,表现为永不收敛的假冲突(v45 originalAmount 同款)。
              templateFieldValues: r.templateFieldValues,
              // 业务键命中的本地行可能无 syncId（v33 前建的），回填收敛身份
              syncId: matchedByBizKey ? r.syncId : null,
            );
            updated++;
            if (r.syncId != null && r.syncId!.isNotEmpty) {
              recurringSyncIdToId[r.syncId!] = matched.id;
            }
          }
        } catch (e, st) {
          failed++;
          logger.error('RecurringImport',
              '单条周期规则导入失败(已跳过，不影响其余规则): syncId=${r.syncId ?? '无'}',
              e, st);
        }
      }
      logger.info('RecurringImport',
          '周期规则导入完成: 新增=$created 更新=$updated 失败=$failed 耗时=${sw.elapsedMilliseconds}ms');
      if (failed > 0) {
        logger.error('RecurringImport',
            '有 $failed 条周期规则未导入成功，引用这些规则的交易将以无周期锚点落库'
            '（recurringId=null），恢复侧去重对其失效');
      }
    } catch (e, st) {
      logger.error('RecurringImport', '周期规则导入失败', e, st);
    }

    return recurringSyncIdToId;
  }

  /// 导入预算（v8 G1，sync_gap_closure）
  ///
  /// 匹配：① syncId ② 业务键（type|categoryId|period）→ 更新并回填
  /// syncId；③ 新建。upsert-only：云端快照不删本地多余预算（旧快照
  /// 误删新数据的风险 > 删除不传播的不便，与交易恢复同语义）。
  Future<void> importBudgets(
    BaseRepository repo,
    int ledgerId,
    List<ImportBudget> budgets, {
    required Map<String, int> categoryCache,
  }) async {
    if (budgets.isEmpty) return;

    logger.info('BudgetImport', '开始导入预算: ${budgets.length} 条');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      final categoryNameToId = <String, int>{};
      for (final e in categoryCache.entries) {
        final idx = e.key.indexOf('|');
        categoryNameToId[e.key.substring(idx + 1)] = e.value;
      }

      final existing = await repo.getAllBudgets(ledgerId);
      final existingBySyncId = <String, Budget>{};
      final existingByBizKey = <String, Budget>{};
      for (final b in existing) {
        if (b.syncId != null && b.syncId!.isNotEmpty) {
          existingBySyncId[b.syncId!] = b;
        }
        existingByBizKey['${b.type}|${b.categoryId ?? ''}|${b.period}'] = b;
      }

      for (final b in budgets) {
        int? categoryId;
        if (b.type == 'category' && b.categoryName != null) {
          categoryId = categoryNameToId[b.categoryName];
          if (categoryId == null) {
            logger.warning('BudgetImport',
                '预算分类未命中: "${b.categoryName}" → 跳过该条');
            continue;
          }
        }

        Budget? matched;
        var matchedByBizKey = false;
        if (b.syncId != null && b.syncId!.isNotEmpty) {
          matched = existingBySyncId[b.syncId];
        }
        if (matched == null) {
          matched = existingByBizKey['${b.type}|${categoryId ?? ''}|${b.period}'];
          matchedByBizKey = matched != null;
        }

        if (matched == null) {
          await repo.createBudget(
            ledgerId: ledgerId,
            type: b.type,
            categoryId: categoryId,
            amount: b.amount,
            period: b.period,
            startDay: b.startDay,
            syncId: b.syncId,
            // enabled 必须随快照落库：漏传会把云端「已停用」的预算建成启用，
            // 而 enabled 参与快照指纹 → 该账本永久「有差异」却又 diff 不出
            // 变更（2026-10-02 全字段闭环门禁 Tier 5 实测复现）
            enabled: b.enabled,
          );
          created++;
        } else {
          await repo.updateBudget(
            matched.id,
            amount: b.amount,
            startDay: b.startDay,
            enabled: b.enabled,
            syncId: matchedByBizKey ? b.syncId : null,
          );
          updated++;
        }
      }
      logger.info('BudgetImport',
          '预算导入完成: 新增=$created 更新=$updated 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('BudgetImport', '预算导入失败', e, st);
    }
  }

  /// 导入储蓄目标（v12 / schema v53，**ledger-scoped**）。
  ///
  /// 匹配锚点：① `syncId`（跨设备 rename 后仍锚定同一目标）；② 业务键 `name`
  /// 兜底（旧快照无 syncId 时用）。upsert-only：云端快照不删本地多余目标
  /// （与 importBudgets 同语义 —— 删除由 diff 的实体删除语义承担）。
  ///
  /// 账户锚点：先按 `accountSyncId` 查本地账户，未命中再按 `accountName`；
  /// **两者都未命中时降级为手动模式**（`accountId = null`）而不是丢弃整条 ——
  /// 目标不像持仓那样「挂错账户会算错钱」（它只是个展示实体，且对端下次同步
  /// 还能带回来）。带引用但本机解析不出时**保持本地账户不动**，绝不误清。
  Future<void> importSavingsGoals(
    BaseRepository repo,
    int ledgerId,
    List<ImportSavingsGoal> goals, {
    required Map<String, int> accountNameToId,
  }) async {
    if (goals.isEmpty) return;

    logger.info('SavingsGoalImport', '开始导入储蓄目标: ${goals.length} 条');
    final sw = Stopwatch()..start();
    int created = 0;
    int updated = 0;

    try {
      // 账户索引（syncId 优先锚点）。账户数量级几十条，一次全量读足够。
      final accountSyncIdToId = <String, int>{};
      for (final a in await repo.getAllAccounts()) {
        final sid = a.syncId;
        if (sid != null && sid.isNotEmpty) accountSyncIdToId[sid] = a.id;
      }

      final existing = await repo.getSavingsGoalsByLedger(ledgerId);
      final existingBySyncId = <String, SavingsGoal>{};
      final existingByName = <String, SavingsGoal>{};
      for (final g in existing) {
        final sid = g.syncId;
        if (sid != null && sid.isNotEmpty) existingBySyncId[sid] = g;
        existingByName[g.name] = g;
      }

      for (final g in goals) {
        int? accountId;
        final accountSyncId = g.accountSyncId;
        if (accountSyncId != null && accountSyncId.isNotEmpty) {
          accountId = accountSyncIdToId[accountSyncId];
        }
        final accountName = g.accountName;
        if (accountId == null && accountName != null && accountName.isNotEmpty) {
          accountId = accountNameToId[accountName];
        }

        SavingsGoal? matched;
        final syncId = g.syncId;
        if (syncId != null && syncId.isNotEmpty) {
          matched = existingBySyncId[syncId];
        }
        matched ??= existingByName[g.name];

        if (matched == null) {
          await repo.createSavingsGoal(
            ledgerId: ledgerId,
            name: g.name,
            targetAmount: g.targetAmount,
            // 币种缺失时落 'CNY' 兜底（账户模式下 UI 会强制等于账户币种）。
            currency: g.currency ?? 'CNY',
            accountId: accountId,
            savedAmount: g.savedAmount ?? 0,
            startDate: g.startDate,
            targetDate: g.targetDate,
            note: g.note,
            sortOrder: g.sortOrder ?? 0,
            syncId: syncId,
          );
          created++;
        } else {
          // 与 importAccounts / importHoldings 同款：只在「云端值非 null 且确实
          // 与本地不同」时才写，**绝不把缺键当清空信号**（v45/v46/v47 反复踩过
          // 的假冲突来源）。
          bool differs<T>(T? incoming, T? local) =>
              incoming != null && incoming != local;
          final localSyncId = matched.syncId;
          final needBackfillSyncId =
              (localSyncId == null || localSyncId.isEmpty) &&
                  syncId != null &&
                  syncId.isNotEmpty;

          // 账户引用是「可为 null 的实质字段」，三态必须分开：
          // - 快照带引用且本机解析得出 → 与本地不同则更新；
          // - 快照带引用但本机解析不出（账户被删 / 名字对不上）→ **保持不动**；
          // - 快照压根没带（该目标本来就是手动模式）→ 本地有账户则清空。
          final hasAccountRef =
              (accountSyncId != null && accountSyncId.isNotEmpty) ||
                  (accountName != null && accountName.isNotEmpty);
          final canResolveAccount = hasAccountRef && accountId != null;
          final needAccountChange =
              canResolveAccount && accountId != matched.accountId;
          final needClearAccount = !hasAccountRef && matched.accountId != null;

          final hasUpdates = (g.name.isNotEmpty && g.name != matched.name) ||
              needBackfillSyncId ||
              needAccountChange ||
              needClearAccount ||
              differs(g.targetAmount, matched.targetAmount) ||
              differs(g.currency, matched.currency) ||
              differs(g.savedAmount, matched.savedAmount) ||
              differs(g.startDate, matched.startDate) ||
              differs(g.targetDate, matched.targetDate) ||
              differs(g.note, matched.note) ||
              differs(g.sortOrder, matched.sortOrder);
          if (!hasUpdates) continue;

          await repo.updateSavingsGoal(
            matched.id,
            name: g.name.isNotEmpty ? g.name : null,
            targetAmount: g.targetAmount,
            currency: g.currency,
            accountId: needAccountChange ? accountId : null,
            clearAccount: needClearAccount,
            savedAmount: g.savedAmount,
            startDate: g.startDate,
            targetDate: g.targetDate,
            note: g.note,
            sortOrder: g.sortOrder,
            syncId: needBackfillSyncId ? syncId : null,
          );
          updated++;
        }
      }
      logger.info('SavingsGoalImport',
          '储蓄目标导入完成: 新增=$created 更新=$updated 耗时=${sw.elapsedMilliseconds}ms');
    } catch (e, st) {
      logger.error('SavingsGoalImport', '储蓄目标导入失败', e, st);
    }
  }

  /// 导入手动汇率覆盖（v8 G4）。按 (base, quote) 唯一键 upsert，
  /// setOverride 内部已处理插入/更新两种情况。
  ///
  /// TBL-M3 补全（云端新账本导入路径）：按 (base, quote) 业务键把快照
  /// 携带的 syncId 回写本地行。此前只调 setOverride，行不存在时生成全新
  /// UUID，两端身份撕裂——restoreLedgerFromJson 路径已有
  /// _restoreRateOverrideSyncIds 回写，本路径（importTransactionsJson →
  /// 云端账本发现导入新账本）漏掉了同款处理。行已存在且 syncId 相同则
  /// 幂等跳过；业务键冲突（本地已有行）时保留快照身份（新账本导入场景
  /// 云端即权威）。仅 LocalRepository 能直查 drift 表，其他实现静默跳过
  /// （与 _restoreRateOverrideSyncIds 的防御语义一致）。
  Future<void> importRateOverrides(
    BaseRepository repo,
    List<ImportRateOverride> overrides,
  ) async {
    if (overrides.isEmpty) return;
    logger.info('RateOverrideImport', '开始导入手动汇率: ${overrides.length} 条');
    try {
      for (final o in overrides) {
        await repo.setOverride(
          base: o.baseCurrency,
          quote: o.quoteCurrency,
          // setOverride 接口收 String；toStringAsFixed 丢失精度可控
          //（汇率 6 位小数足够），跨设备由快照统一值覆盖。
          rate: _normalizeRateForStorage(o.rate),
        );
      }
      // TBL-M3 补全：回写快照携带的 syncId（身份对齐，防未来按 syncId
      // 的增量 diff 配不上对）
      if (repo is LocalRepository) {
        await _restoreRateOverrideSyncIds(repo.db, overrides);
      }
      logger.info('RateOverrideImport', '手动汇率导入完成');
    } catch (e, st) {
      logger.error('RateOverrideImport', '手动汇率导入失败', e, st);
    }
  }

  /// 手动汇率存储口径（#4 统一）：导出端写 '7.1'，导入端此前写
  /// '7.100000'，两端 DB 字面不一致（指纹已数值规范化，不影响同步，
  /// 但字面差异让跨端对比/排查困惑）。统一为「去掉多余尾零」的最简
  /// 小数形态，与导出端一致。
  static String _normalizeRateForStorage(double rate) {
    var s = rate.toStringAsFixed(6);
    s = s.replaceFirst(RegExp(r'0+$'), '');
    s = s.replaceFirst(RegExp(r'\.$'), '');
    return s;
  }

  /// 两个可空日期取较新者（周期规则进度合并用）。
  DateTime? _maxDate(DateTime? a, DateTime? b) {
    if (a == null) return b;
    if (b == null) return a;
    return a.isAfter(b) ? a : b;
  }

  /// 导入交易(统一 batch 路径,tag/attachment 跟 tx 一起 batch insert)
  ///
  /// **历史**:之前"有标签/附件"的 tx 走单条 await 路径,
  ///   `insertTransactionCompanion` → `updateTransactionTags` → `createAttachment`
  /// 各开自己的 BEGIN/COMMIT,N+1 + 嵌套事务双重放大,1 万条带标签数据要几十
  /// 分钟。
  ///
  /// **现在**:全部走 `insertTransactionsBatchWithRelations`,500 条 / 批,
  /// 一个 db.transaction 内 batch insert tx + tag + attachment + local_changes,
  /// 把 N 次 BEGIN/COMMIT/fsync 折叠成 1 次。
  ///
  /// public — sync_diff_service 复用。
  Future<ImportResult> importTransactions(
    BaseRepository repo,
    int ledgerId,
    List<ImportTransaction> transactions, {
    required Map<String, int> accountNameToId,
    required Map<String, int> categoryCache,
    required Map<String, int> tagNameToId,
    Map<String, int>? tagSyncIdToId,
    Map<String, int>? recurringSyncIdToId,
    void Function(int done, int total)? onProgress,
    bool recordChanges = true,
  }) async {
    int inserted = 0;
    int failed = 0;
    int skipped = 0;
    int processed = 0;
    final total = transactions.length;
    logger.info('TxImport',
        '开始导入交易: $total 条 (recordChanges=$recordChanges)');

    // v30 交易级多币种(02 §六导入修补):批量预取本位币/账户币种/有效汇率,
    // 逐条填 currencyCode + nativeAmount,不再落 NULL(NULL 行 L11 检测
    // 需 join 兜底,且外币账户导入折算会静默 1:1)。
    final ledger = await repo.getLedgerById(ledgerId);
    final ledgerBase = ((ledger?.currency.isNotEmpty ?? false)
            ? ledger!.currency
            : 'CNY')
        .toUpperCase();
    final accountCurrencyById = <int, String>{
      for (final a in await repo.getAllAccounts())
        a.id: (a.currency.isNotEmpty ? a.currency : ledgerBase).toUpperCase(),
    };
    Map<String, EffectiveRate> importRates = const {};
    try {
      final autos = await repo.getLatestAutoRates(ledgerBase);
      final overrides = await repo.getOverrides(ledgerBase);
      importRates = mergeEffectiveRates(
        autoRates: [
          for (final r in autos)
            (quote: r.quoteCurrency, rate: r.rate, rateDate: r.rateDate)
        ],
        overrides: [
          for (final o in overrides) (quote: o.quoteCurrency, rate: o.rate)
        ],
      );
    } catch (e) {
      logger.warning('TxImport', '导入取汇率失败,外币交易将按 1:1 待 L11 捞回: $e');
    }
    final overallSw = Stopwatch()..start();

    const batchSize = 500;
    // 批次缓冲:tx 列表 + 按 batch 内 index 索引的关联数据
    final batchTx = <TransactionsCompanion>[];
    final batchTagsByIndex = <int, List<int>>{};
    final batchAttachmentsByIndex = <int, List<BatchAttachmentData>>{};

    final localCategoryCache = Map<String, int>.from(categoryCache);

    // REC-04：预加载本批次涉及周期规则的已有实例指纹，循环内 O(1) 查内存，
    // 替代逐笔 await DB 查询（大快照 N 笔周期实例 = N 次 SELECT）。键为
    // (recurringId, 本地日历日)（REC-01/02：导出 toUtc/导入 toLocal 跨时区
    // 下精确毫秒必失配；非 0 点实例按同日归一）。导入中新落库的指纹同步入
    // 映射，兼得批内去重（flush 前 DB 里还没有这批行）。预加载失败按空映射
    // 处理并告警，不阻断整体恢复（与下方逐笔容错语义一致）。
    //
    // REC-05：值从 Set<String> 升级为指纹明细 List<RecurringInstanceFingerprint>
    // (syncId/amount/note)。同日键命中只是"候选重复"，还须逐实例比对：
    // - syncId 相同 → 同一实体（重复恢复同一快照），跳过；
    // - amount+note 均相同 → generator 本机实例 vs 源端同源实例，跳过；
    // - 其余（同日不同金额/备注的多笔合法交易）→ 照常落库。
    // 回归案例：tx-hist-day-rent54（08:00）被同日 generator 实例
    // 房租月付（00:00）仅凭同日键误杀，恢复后两端差一笔。
    final existingRecurringInstances =
        <String, List<RecurringInstanceFingerprint>>{};
    try {
      final involvedIds = <int>{
        for (final tx in transactions)
          if (tx.recurringSyncId != null &&
              recurringSyncIdToId != null &&
              recurringSyncIdToId[tx.recurringSyncId] != null)
            recurringSyncIdToId[tx.recurringSyncId]!,
      };
      existingRecurringInstances.addAll(
          await repo.getRecurringInstanceDetails(involvedIds));
    } catch (e, st) {
      logger.warning('TxImport',
          '周期实例去重键预加载失败(按空集处理，本批不去重): $e, $st');
    }

    // 把当前缓冲 flush 到 repo。捕获异常时整批算 failed,继续下一批。
    Future<void> flush() async {
      if (batchTx.isEmpty) return;
      final size = batchTx.length;
      final batchSw = Stopwatch()..start();
      try {
        final ids = await repo.insertTransactionsBatchWithRelations(
          transactions: List.of(batchTx),
          tagIdsByIndex: Map.of(batchTagsByIndex),
          attachmentsByIndex: Map.of(batchAttachmentsByIndex),
          recordChanges: recordChanges,
        );
        inserted += ids.length;
        logger.info('TxImport',
            'flush 批次: size=$size 耗时=${batchSw.elapsedMilliseconds}ms 累计=${processed + size}/$total');
      } catch (e, st) {
        // B1:整批失败时不直接 `failed += size`,降级为逐条重试,定位真实坏行。
        // 否则一批 500 条里只有 1 条坏数据也会被全部计为失败,且无法定位哪条。
        // 连续失败超过阈值视为系统性故障(如 DB 锁/schema 不匹配),避免无谓
        // 重试拖垮导入耗时。
        logger.error('TxImport', '批次 flush 失败,降级逐条重试定位坏行', e, st);
        int consecutiveFailures = 0;
        for (int i = 0; i < size; i++) {
          try {
            final ids = await repo.insertTransactionsBatchWithRelations(
              transactions: [batchTx[i]],
              tagIdsByIndex: batchTagsByIndex.containsKey(i)
                  ? {0: batchTagsByIndex[i]!}
                  : const {},
              attachmentsByIndex: batchAttachmentsByIndex.containsKey(i)
                  ? {0: batchAttachmentsByIndex[i]!}
                  : const {},
              recordChanges: recordChanges,
            );
            inserted += ids.length;
            consecutiveFailures = 0;
          } catch (e2, st2) {
            logger.error('TxImport', '单条插入失败(坏行): batchIndex=$i', e2, st2);
            failed++;
            consecutiveFailures++;
            if (consecutiveFailures >= 10) {
              logger.error('TxImport',
                  '连续 $consecutiveFailures 条失败,视为系统性故障,'
                  '剩余 ${size - i - 1} 条整批算 failed');
              failed += size - i - 1;
              break;
            }
          }
        }
      }
      processed += size;
      batchTx.clear();
      batchTagsByIndex.clear();
      batchAttachmentsByIndex.clear();
      if (onProgress != null) onProgress(processed, total);
    }

    for (final tx in transactions) {
      // 解析分类ID
      int? categoryId;
      if (tx.categoryId != null) {
        categoryId = tx.categoryId;
      } else if (tx.categoryName != null && tx.categoryKind != null) {
        final key = '${tx.categoryKind}|${tx.categoryName}';
        categoryId = localCategoryCache[key];
        if (categoryId == null && tx.type != 'transfer') {
          try {
            categoryId = await repo.upsertCategory(
              name: tx.categoryName!,
              kind: tx.categoryKind!,
            );
            localCategoryCache[key] = categoryId;
          } catch (e) {
            logger.warning('DataImport', '导入时创建分类失败: ${tx.categoryName}', e);
          }
        }
      }

      // 解析账户ID
      int? accountId;
      int? toAccountId;
      if (tx.type == 'transfer') {
        if (tx.fromAccountName != null) {
          accountId = accountNameToId[tx.fromAccountName];
          if (accountId == null) {
            // B2:失败也回调进度,避免 UI 进度条卡死/失真
            failed++;
            processed++;
            if (onProgress != null) onProgress(processed, total);
            continue;
          }
        }
        if (tx.toAccountName != null) {
          toAccountId = accountNameToId[tx.toAccountName];
          if (toAccountId == null) {
            // B2:失败也回调进度,避免 UI 进度条卡死/失真
            failed++;
            processed++;
            if (onProgress != null) onProgress(processed, total);
            continue;
          }
        }
      } else {
        if (tx.accountName != null) {
          accountId = accountNameToId[tx.accountName];
        }
      }

      // 解析标签ID — 优先按 tagSyncIds 匹配（跨设备 rename 稳定锚定），
      // 用 Set 去重。仅当所有 syncId 都完整命中时才直接返回，否则继续按
      // name 兜底，避免部分 miss 导致标签缺失并触发无限 diff 循环。
      final resolvedTagIds = <int>{};
      var resolvedBySyncId = false;

      // 1. 优先按 syncId 解析
      if (tagSyncIdToId != null &&
          tx.tagSyncIds != null &&
          tx.tagSyncIds!.isNotEmpty) {
        for (final syncId in tx.tagSyncIds!) {
          final tagId = tagSyncIdToId[syncId];
          if (tagId != null) resolvedTagIds.add(tagId);
        }
        resolvedBySyncId = resolvedTagIds.isNotEmpty &&
            resolvedTagIds.length == tx.tagSyncIds!.length;
      }

      // 2. 按 name 解析（syncId 缺失或部分 miss 时兜底）
      if (!resolvedBySyncId && tx.tagNames != null) {
        for (final tagName in tx.tagNames!) {
          var tagId = tagNameToId[tagName];
          if (tagId == null) {
            try {
              final existingTag = await repo.getTagByName(tagName);
              if (existingTag != null) {
                tagId = existingTag.id;
              } else {
                tagId = await repo.createTag(name: tagName);
              }
              tagNameToId[tagName] = tagId;
            } catch (e) {
              logger.warning('DataImport', '导入时创建标签失败: $tagName', e);
            }
          }
          if (tagId != null) {
            resolvedTagIds.add(tagId);
          }
        }
      }
      final uniqueTagIds = resolvedTagIds.toList();

      // v30:交易币种 = CSV 币种列(显式,反馈10)?? 账户币种 ?? 本位币;
      // 折算快照同币种 = amount,外币按有效汇率,取不到 = amount(L11 可捞回)。
      final txCurrency = ((tx.currencyCode?.isNotEmpty ?? false)
              ? tx.currencyCode!
              : null) ??
          (accountId != null ? accountCurrencyById[accountId] : null) ??
          ledgerBase;
      // 优先用 JSON 显式携带的折算快照（跨设备同步时保持一致）；缺失时
      // 按旧逻辑重算（单币种 = amount，外币按汇率，取不到 = amount）。
      final txNative = tx.nativeAmount ??
          (txCurrency == ledgerBase
              ? tx.amount
              : (computeNativeAmount(
                      amount: tx.amount,
                      accountCurrency: txCurrency,
                      ledgerBase: ledgerBase,
                      rates: importRates) ??
                  tx.amount));

      // 构建交易记录
      // E3:导入路径主动生成 syncId,不依赖仓储层兜底。避免 ChangeTracker
      // 静默跳过 null-syncId 交易(local_repository.dart `if (tx.syncId == null) continue;`),
      // 导致该笔永远不会被推送到云端,且 SyncEngine 无 transaction backfill 兜底。
      final effectiveSyncId = tx.syncId ?? const Uuid().v4();
      // v8 G2：周期规则关联。recurringSyncId → 本地 recurring int id
      // （映射由 importRecurrings 产出；规则未导入/未命中 → null，
      // 交易本身照常落库，仅来源关联缺失）。
      final resolvedRecurringId = (tx.recurringSyncId != null &&
              recurringSyncIdToId != null)
          ? recurringSyncIdToId[tx.recurringSyncId!]
          : null;
      // B 方案（同步恢复侧去重，REC-05 细化）：带周期规则锚点的实例命中
      // 同 (recurringId, 本地日历日) 键时，不再一律跳过——逐实例比对指纹：
      // - syncId 相同：同一实体（同一快照重复恢复），跳过；
      // - amount+note 均相同：generator 本机实例 vs 源端同源实例
      //   （generator 的 note=规则备注、amount=规则金额，与源端生成实例
      //   同源同值），跳过；否则「本地生成实例 + 源端恢复实例」因 syncId
      //   不同无法被 syncId 去重识别，导致重复。
      // - 金额或备注不同：同日多笔合法交易（如手工补记的历史房租 vs
      //   本月自动生成房租），必须落库。此前仅凭同日键误杀
      //   （回归案例 tx-hist-day-rent54）。
      if (resolvedRecurringId != null) {
        final dupKey = TransactionRepository.recurringInstanceKey(
            resolvedRecurringId, tx.happenedAt);
        final candidates = existingRecurringInstances[dupKey];
        final incomingNote = tx.note ?? '';
        final isTrueDup = candidates != null &&
            candidates.any((c) =>
                (c.syncId != null && c.syncId == tx.syncId) ||
                (c.amount == tx.amount && (c.note ?? '') == incomingNote));
        if (isTrueDup) {
          skipped++;
          processed++;
          if (onProgress != null) onProgress(processed, total);
          continue;
        }
        final fingerprint = (
          syncId: tx.syncId,
          amount: tx.amount,
          note: tx.note,
        );
        if (candidates != null) {
          candidates.add(fingerprint);
        } else {
          existingRecurringInstances[dupKey] = [fingerprint];
        }
      }
      final txCompanion = TransactionsCompanion.insert(
        ledgerId: ledgerId,
        type: tx.type,
        amount: tx.amount,
        categoryId: d.Value(tx.type == 'transfer' ? null : categoryId),
        accountId: d.Value(accountId),
        toAccountId: d.Value(toAccountId),
        happenedAt: d.Value(tx.happenedAt),
        note: d.Value(tx.note),
        syncId: d.Value(effectiveSyncId),
        currencyCode: d.Value(txCurrency),
        nativeAmount: d.Value(txNative),
        // v45 原始金额：**原样落库，绝不 `?? amount` 兜底**。导出侧
        // （transactions_json）是「仅非空才写键」，若这里兜底成记账金额，
        // 「快照未携带该键」恢复后就变成「手填了等于记账金额的值」→ 两端
        // 指纹不同 → 首次跨设备往返必然弹一次假的「云端有更新」（下一轮
        // 才收敛）。原样落库后：缺键 → 列 NULL → 再导出仍不写键，指纹与
        // 源端一字不差。NULL 即「用户未填写」，读取/统计侧统一走
        // `COALESCE(original_amount, amount)`（见 db.dart 该列注释），
        // 与 v45 迁移「物理 NULL 才能区分未填写与手填同值」的取舍一致。
        originalAmount: d.Value(tx.originalAmount),
        // v46 自定义字段值：null（旧快照缺键 / 该笔无值）→ 列写 NULL；
        // 经 codec 编码（键排序 + 空值剔除，与导出侧表示同源）。
        customValuesJson: d.Value(CustomFieldValueCodec.encode(tx.customValues)),
        // 账单标记：JSON 同步必须传输，否则"不计入统计/预算"跨设备丢失
        excludeFromStats: d.Value(tx.excludeFromStats),
        excludeFromBudget: d.Value(tx.excludeFromBudget),
        recurringId: d.Value(resolvedRecurringId),
      );

      final indexInBatch = batchTx.length;
      batchTx.add(txCompanion);
      if (uniqueTagIds.isNotEmpty) {
        batchTagsByIndex[indexInBatch] = uniqueTagIds;
      }
      if (tx.attachments != null && tx.attachments!.isNotEmpty) {
        batchAttachmentsByIndex[indexInBatch] = tx.attachments!
            .map((a) => BatchAttachmentData(
                  fileName: a.fileName,
                  originalName: a.originalName,
                  fileSize: a.fileSize,
                  width: a.width,
                  height: a.height,
                  sortOrder: a.sortOrder,
                  cloudFileId: a.cloudFileId,
                  cloudSha256: a.cloudSha256,
                  localSha256: a.sha256,
                ))
            .toList();
      }

      if (batchTx.length >= batchSize) {
        await flush();
      }
    }

    // 刷剩余
    await flush();

    logger.info('TxImport',
        '交易导入完成: 总数=$total 成功=$inserted 跳过recurring重复=$skipped(同规则同日且syncId或金额+备注相同) 失败=$failed 总耗时=${overallSw.elapsedMilliseconds}ms');
    return ImportResult(
        inserted: inserted, failed: failed, skippedRecurring: skipped);
  }
}

/// 全局单例
final dataImportService = DataImportService();

/// ============================================================
/// 账本整体恢复（云同步恢复 / 云端备份恢复 共用）
/// ============================================================

/// 清空指定账本的全部交易及关联行（transactionTags /
/// transactionAttachments）。
///
/// 从 TransactionsSyncManager 迁移为公共函数：恢复是「先清空再导入」，
/// 清空逻辑必须单一事实源，避免备份/同步两条链路各自实现产生分叉。
/// 不记录 local_changes（为导入数据腾位置，不应反向回流云端）。
/// 调用方应将其与导入操作包裹在同一事务内，保证原子性。
Future<int> clearLedgerTransactions(PiggyDatabase db, int ledgerId) async {
  final txIds = await (db.selectOnly(db.transactions)
        ..addColumns([db.transactions.id])
        ..where(db.transactions.ledgerId.equals(ledgerId)))
      .map((row) => row.read(db.transactions.id)!)
      .get();

  if (txIds.isEmpty) return 0;

  await (db.delete(db.transactionTags)
        ..where((t) => t.transactionId.isIn(txIds)))
      .go();
  await (db.delete(db.transactionAttachments)
        ..where((t) => t.transactionId.isIn(txIds)))
      .go();
  final deleted = await (db.delete(db.transactions)
        ..where((t) => t.ledgerId.equals(ledgerId)))
      .go();
  logger.info('DataImport', '恢复前清空账本 $ledgerId: 删除 $deleted 笔交易');
  return deleted;
}

/// 用快照 JSON 整体恢复指定账本（清空后导入，事务原子）。
///
/// 抽取自 TransactionsSyncManager.downloadAndRestoreToCurrentLedger 中段，
/// 供云同步恢复与云端备份恢复（CloudBackupService）共用同一语义。
///
/// 返回 (inserted, deletedDup, skippedRecurring)；返回 null 表示跳过恢复：
/// - P1-1 守卫：快照不含任何交易且本地非空 → 拒绝空覆盖
///   （误上传空文件不应静默抹掉本地全部交易；确需清空走显式上传覆盖）。
///
/// [jsonStr] 必须是已解密的明文 JSON。调用方需保证 ledgerId 的本地账本已存在。
Future<({int inserted, int deletedDup, int skippedRecurring})?>
    restoreLedgerFromJson({
  required PiggyDatabase db,
  required BaseRepository repo,
  required int ledgerId,
  required String jsonStr,
}) async {
  // 万笔级大快照的 jsonDecode + 逐条校验放后台 isolate，解析在 DB 事务
  // 外完成（结果为纯数据对象，可直接跨 isolate 返回），UI 线程零解析耗时。
  final remoteImport = await compute(parseJsonToImportData, jsonStr);
  if (remoteImport.transactions.isEmpty) {
    final localRows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
    if (localRows.isNotEmpty) {
      logger.warning('DataImport',
          '快照为空但本地有 ${localRows.length} 条交易，拒绝空覆盖（ledgerId=$ledgerId）');
      return null;
    }
  }

  // 清空 + 导入包裹同一事务：导入失败则清空一并回滚，本地不会被部分清空。
  // importTransactionsJson 内部事务作为 savepoint 嵌套。
  // recordChanges: false —— 恢复不应写入本地变更历史（P2-3）
  //
  // 审计 TBL-S1/M5 加固：全程包 withRecordingSuppressed。此前仅交易显式
  // 关闭了记录，快照内部补建的账户/分类（repo.createAccount 等）与汇率
  // 覆盖 upsert（setOverride）仍会无条件回流 local_changes，成为推回
  // server 的幻影变更。抑制开关在 tracker 层统一拦截所有 record*Change，
  // 与 sync_diff_service.applySyncChanges 的做法对齐。
  Future<(int, ({int inserted, int skippedRecurring}))> runTx() =>
      _restoreLedgerFromJsonTx(db, repo, ledgerId, jsonStr, remoteImport);
  final tracker = repo.changeTracker;
  final deleted = tracker != null
      ? await tracker.withRecordingSuppressed(runTx)
      : await runTx();

  return (
    inserted: deleted.$2.inserted,
    deletedDup: deleted.$1,
    skippedRecurring: deleted.$2.skippedRecurring,
  );
}

/// restoreLedgerFromJson 的事务体（抽出以便被抑制上下文包裹）。
Future<(int, ({int inserted, int skippedRecurring}))>
    _restoreLedgerFromJsonTx(
        PiggyDatabase db,
        BaseRepository repo,
        int ledgerId,
        String jsonStr,
        ImportData remoteImport) async {
  return await db.transaction(() async {
    // v9：账本身份回填。快照携带 ledgerSyncId 且本地行缺失时补写，
    // 让 legacy 账本在首次恢复后即获得跨设备稳定身份（后续 push 锚点、
    // 云端槽位命名都依赖它，不再退回本地数字 id）。
    await _backfillLedgerSyncId(db, ledgerId, remoteImport.ledgerSyncId);
    // P1-5：抓取「本机专属列」的旧值（按 syncId），导入完成后回填。
    // 见 _snapshotLocalOnlyTxColumns 的说明。
    final localOnlyColumns = await _snapshotLocalOnlyTxColumns(db, ledgerId);
    final cleared = await clearLedgerTransactions(db, ledgerId);
    final result = await importTransactionsJson(repo, ledgerId, jsonStr,
        recordChanges: false);
    await _restoreLocalOnlyTxColumns(db, ledgerId, localOnlyColumns);
    // 审计 TBL-M3：快照携带的汇率覆盖 syncId 回写本地行。此前解析器丢弃
    // syncId，恢复端身份重建为新 UUID，跨设备 push/pull 映射断裂。
    await _restoreRateOverrideSyncIds(db, remoteImport.rateOverrides);
    // H3 真覆盖（镜像云端）：v8+ 快照把云端已删除的预算/周期/分类/标签
    // 传播到本地。旧实现只 upsert 不删除，「全量覆盖」后云端删掉的实体
    // 在本地永不消失。
    if (remoteImport.version != null && remoteImport.version! >= 8) {
      await _mirrorDeleteAbsentEntities(db, ledgerId, remoteImport);
    }
    // W4：恢复 = 以云端状态为权威，恢复前已存在的未推送 local_changes
    // 全部过期，必须同事务清理。否则残留队列三连炸：
    // a) 陈旧 delete 在下次 push 把刚恢复的数据删掉并传播到所有设备；
    // b) S3b 守卫（sync_engine_apply._hasUnpushedLocalChange）把该实体
    //    的所有后续远端更新持续拦截；
    // c) v35 唯一索引 + insertOrIgnore 保留旧 entityId 死行 → push 序列化
    //    查不到实体发空 payload，用户真实编辑永久丢失。
    await _purgeStaleLocalChanges(db, ledgerId, remoteImport);
    return (cleared, result);
  });
}

/// P1-5：恢复前抓取交易的「本机专属列」（按 syncId）。
///
/// 【为什么需要】
/// `created_by_user_id` / `last_edited_by_user_id` **从不出现在云快照里**
/// （`transactions_json.dart` 的 item map 没有这两个键），而全量恢复是
/// 「清空后重建行」—— 重建走的 `TransactionsCompanion.insert` 不含它们，
/// 于是本机值被静默清空（2026-09-27 实测：全量下载后 created_by 非空行
/// **5075 → 0**）。
///
/// 语义上这属于"本机专属信息被远端覆盖"：**云端从未对这两列表达过意见**，
/// 恢复不应让它们丢失。（增量合并路径本来就不会碰它们 —— 合并用的
/// `TransactionUpdateBySyncIdData` 里没有这两列，实测 5075 → 5075 不变。）
///
/// 只收 `syncId` 非空的行：没有稳定身份就无法在重建后对上号（这类行本来也
/// 无法跨设备对齐，行为与改动前一致）。
Future<Map<String, (String?, String?)>> _snapshotLocalOnlyTxColumns(
    PiggyDatabase db, int ledgerId) async {
  final rows = await (db.select(db.transactions)
        ..where((t) => t.ledgerId.equals(ledgerId)))
      .get();
  return {
    for (final r in rows)
      if (r.syncId != null && r.syncId!.isNotEmpty)
        r.syncId!: (r.createdByUserId, r.lastEditedByUserId),
  };
}

/// P1-5：把本机专属列回填到同 `syncId` 的新行上（恢复事务内调用）。
///
/// 只回填**非空**值（旧值本来就是 NULL 的行无需写，避免无用 UPDATE）；
/// 用 `db.batch` 而非逐条 await —— 实测数据里可能有数千行带值，逐条往返会
/// 明显拖慢恢复。
Future<void> _restoreLocalOnlyTxColumns(
  PiggyDatabase db,
  int ledgerId,
  Map<String, (String?, String?)> saved,
) async {
  final pending = [
    for (final e in saved.entries)
      if (e.value.$1 != null || e.value.$2 != null) e,
  ];
  if (pending.isEmpty) return;
  await db.batch((b) {
    for (final e in pending) {
      final (createdBy, lastEditedBy) = e.value;
      b.update(
        db.transactions,
        TransactionsCompanion(
          createdByUserId: createdBy == null
              ? const d.Value.absent()
              : d.Value(createdBy),
          lastEditedByUserId: lastEditedBy == null
              ? const d.Value.absent()
              : d.Value(lastEditedBy),
        ),
        where: (t) => t.ledgerId.equals(ledgerId) & t.syncId.equals(e.key),
      );
    }
  });
  logger.info('DataImport',
      '恢复后回填本机专属列(created_by/last_edited_by): ${pending.length} 行 '
      '(ledgerId=$ledgerId)');
}

/// 审计 TBL-M3：按业务键 (base, quote) 把快照携带的 syncId 回写本地
/// 汇率覆盖行。本地行缺失（导入被跳过等）静默跳过；已在恢复事务内调用。
Future<void> _restoreRateOverrideSyncIds(
    PiggyDatabase db, List<ImportRateOverride> overrides) async {
  for (final o in overrides) {
    final sid = o.syncId?.trim();
    if (sid == null || sid.isEmpty) continue;
    final baseUp = o.baseCurrency.toUpperCase();
    final quoteUp = o.quoteCurrency.toUpperCase();
    final row = await (db.select(db.exchangeRateOverrides)
          ..where((t) =>
              t.baseCurrency.equals(baseUp) & t.quoteCurrency.equals(quoteUp)))
        .getSingleOrNull();
    if (row == null || row.syncId == sid) continue;
    await (db.update(db.exchangeRateOverrides)
          ..where((t) => t.id.equals(row.id)))
        .write(ExchangeRateOverridesCompanion(syncId: d.Value(sid)));
  }
}

/// v9：账本身份回填。快照携带 ledgerSyncId 时对账本地行做保守收敛：
/// - 本地行无 syncId → 回填快照值（legacy 账本首次恢复后获得跨设备身份）；
/// - 本地行已有 syncId 且与快照一致 → 幂等无操作（最常见：两端同源）；
/// - 两者不同 → 保留本地身份不动，仅告警。本地 syncId 是该账本在全部
///   设备与快照间的实体锚点,贸然覆盖会撕裂实体映射;身份冲突应交给
///   用户在设置里处理而非静默改写。
///
/// 必须在 restoreLedgerFromJson 的恢复事务内调用。快照无 ledgerSyncId
/// （v8- 旧格式）时为空操作。
Future<void> _backfillLedgerSyncId(
    PiggyDatabase db, int ledgerId, String? snapshotSyncId) async {
  final value = snapshotSyncId?.trim();
  if (value == null || value.isEmpty) return;

  final row = await (db.select(db.ledgers)
        ..where((l) => l.id.equals(ledgerId)))
      .getSingleOrNull();
  if (row == null) return; // 调用方契约保证存在；防御性跳过

  final current = row.syncId;
  if (current != null && current.trim().isNotEmpty) {
    if (current.trim() != value) {
      logger.warning('DataImport',
          '账本身份不一致（保留本地）: ledgerId=$ledgerId '
          'local=$current snapshot=$value');
    }
    return;
  }

  await (db.update(db.ledgers)..where((l) => l.id.equals(ledgerId)))
      .write(LedgersCompanion(syncId: d.Value(value)));
  logger.info('DataImport',
      'v9 回填账本 sync_id: ledgerId=$ledgerId -> $value');
}

/// W4：清理恢复作用域内已过期的未推送 local_changes（必须在
/// restoreLedgerFromJson 的事务内、导入完成后调用）。
///
/// 范围：
/// - ledger-scoped（transaction/budget/recurring/ledger/ledger_snapshot）：
///   该账本的全部未推送行 —— 快照整体替换了账本权威状态。
/// - user-global（account/category/tag/exchange_rate_override）：仅清
///   「本次快照列出的实体」，快照外的全局改动未被触碰，仍然有效，保留。
///
/// exchange_rate_override：v9 快照已携带 syncId 锚点（审计 TBL-M3 修复），
/// 与 account/category/tag 同口径纳入清理。此前因解析器丢弃 syncId 无法
/// 精确对齐而刻意跳过；残留影响有界（S3b 守卫最多延迟一次远端覆盖更新，
/// 下次编辑自愈），现在可以精确清理了。
Future<int> _purgeStaleLocalChanges(
    PiggyDatabase db, int ledgerId, ImportData cloud) async {
  var purged = await (db.delete(db.localChanges)
        ..where((c) => c.pushedAt.isNull() & c.ledgerId.equals(ledgerId)))
      .go();

  final globalSyncIds = <String>{
    ...cloud.accounts.map((a) => a.syncId).whereType<String>(),
    ...cloud.categories.map((c) => c.syncId).whereType<String>(),
    ...cloud.tags.map((t) => t.syncId).whereType<String>(),
    ...cloud.rateOverrides.map((o) => o.syncId).whereType<String>(),
  };
  if (globalSyncIds.isNotEmpty) {
    purged += await (db.delete(db.localChanges)
          ..where((c) => c.pushedAt.isNull() &
              c.ledgerId.equals(0) &
              c.entitySyncId.isIn(globalSyncIds.toList())))
        .go();
  }

  final liveGlobalSyncIds = await _liveUserGlobalSyncIds(db);

  // 悬挂变更（2026-10-07 修复，S3/WebDAV 双端实测复现）：
  // user-global 实体的未推送**非删除**行，其 syncId 在本机现存表里已找不到。
  //
  // 产生时序：本机先删掉某 user-global 实体（账户/分类/标签/汇率覆盖），
  // 快照随后拍摄 → 快照实体集天然不含它 → 上面「按快照实体清理」命中不了，
  // 而它又不属于本账本（ledgerId=0）→ 第一条也命中不了 ⇒ 永久残留。
  // 实测案例：分类「测-转账」（syncId b20c86b1…）在 R4 被本机删除，
  // 恢复后 local_changes 仍留 1 行 `category/upsert/ledger_id=0`。
  //
  // 危害：`_localChangeEvidence` 的 `lc_n` 口径是 `ledger_id IN (ledgerId, 0)`，
  // 一行悬挂的 user-global 行就让 `unpushed > 0` 恒真 → trust 门禁放行墙钟
  // 分支 → 恢复后方向误判 localNewer（实测：云端 40012 / 本地 40011 仍报
  // localNewer）→ UI 指引「上传」→ **云端较新副本被静默回退**。
  // 本条即把「留下的行必是本机真实写入」这个不变式补齐（见
  // transactions_sync_manager.dart 的 b 条注释）。
  //
  // 只动非 delete：delete 行承载「本机删掉了该实体」的合法待推送语义，必须留。
  // 保留「实体仍存在但不在快照里」的行：那是本机新建、尚未上传的全局实体。
  if (liveGlobalSyncIds.isEmpty) {
    purged += await (db.delete(db.localChanges)
          ..where((c) => c.pushedAt.isNull() &
              c.ledgerId.equals(0) &
              c.action.isNotIn(_nonUpsertActions) &
              c.entityType.isIn(_userGlobalEntityTypeList) &
              c.entitySyncId.isNotNull()))
        .go();
  } else {
    purged += await (db.delete(db.localChanges)
          ..where((c) => c.pushedAt.isNull() &
              c.ledgerId.equals(0) &
              c.action.isNotIn(_nonUpsertActions) &
              c.entityType.isIn(_userGlobalEntityTypeList) &
              c.entitySyncId.isNotNull() &
              c.entitySyncId.isNotIn(liveGlobalSyncIds.toList())))
        .go();
  }

  if (purged > 0) {
    logger.info('DataImport',
        '恢复后清理过期的未推送变更 $purged 条（ledgerId=$ledgerId，'
        '含 user-global ${globalSyncIds.length} 个快照实体的匹配行 + '
        '本机现存全局实体 ${liveGlobalSyncIds.length} 个的悬挂行）');
  }
  return purged;
}

/// user-global 变更行里**不**参与「悬挂清理」的 action：删除与 server 标记。
///
/// `delete` 是「本机删掉了该实体」的合法待推送语义 —— 实体已不存在正是它的
/// 预期状态，清掉就等于把这次删除静默吞掉。`server_marker` 是 pull 防重推
/// 标记，与业务实体存在性无关。
const List<String> _nonUpsertActions = <String>[
  'delete',
  ChangeTracker.serverMarkerAction,
];

/// [ChangeTracker.userGlobalEntityTypes] 的 List 形态（drift `isIn` 需要 List）。
final List<String> _userGlobalEntityTypeList =
    ChangeTracker.userGlobalEntityTypes.toList();

/// 本机现存 user-global 实体的 syncId 全集（悬挂变更判定用）。
///
/// 四张表同口径取 `sync_id IS NOT NULL` 的行；判定语义是「该 syncId 在任何
/// 一张 user-global 表里都找不到 ⟹ 该实体在本机已不存在」。空集与查询失败
/// 由调用方分别处理（空集 = 本机没有任何全现实体，此时非删除行全部悬挂）。
Future<Set<String>> _liveUserGlobalSyncIds(PiggyDatabase db) async {
  final ids = <String>{};
  void take(Iterable<String?> values) {
    for (final v in values) {
      if (v != null && v.isNotEmpty) ids.add(v);
    }
  }

  take((await (db.select(db.accounts)..where((t) => t.syncId.isNotNull()))
          .get())
      .map((r) => r.syncId));
  take((await (db.select(db.categories)..where((t) => t.syncId.isNotNull()))
          .get())
      .map((r) => r.syncId));
  take((await (db.select(db.tags)..where((t) => t.syncId.isNotNull())).get())
      .map((r) => r.syncId));
  take((await (db.select(db.exchangeRateOverrides)
            ..where((t) => t.syncId.isNotNull()))
          .get())
      .map((r) => r.syncId));
  return ids;
}

/// H3 真覆盖（镜像云端）：删除「本地有 syncId 但 v8 快照中不存在」的实体。
///
/// 安全边界：只删「本地行有 syncId 且不在云端 syncId 集合」——
/// 云端行无 syncId 或本地行无 syncId（同步纪元前遗留）都不删，
/// 防止旧快照/异常数据误删。分类/标签/账户是全局表，仅在无任何账本引用
/// 时删除。
///
/// 账户纳入镜像的原因（审计 F4）：指纹 G4 把全量 accounts 纳入比对，
/// 若云端已删账户在本地永不消失，两端指纹永久不一致 → 每次启动判
/// different → merge-then-publish 又把已删账户推回云端复活，形成
/// 不收敛循环。引用守卫与分类/标签同款：被任何交易/周期规则
/// （含转账 toAccountId）引用的账户一律保留。
///
/// 必须在 restoreLedgerFromJson 的事务内调用（清空+导入完成后）。
Future<int> _mirrorDeleteAbsentEntities(
    PiggyDatabase db, int ledgerId, ImportData cloud) async {
  var total = 0;

  // 预算：按账本范围镜像
  final cloudBudgetSyncIds =
      cloud.budgets.map((b) => b.syncId).whereType<String>().toSet();
  final delBudgets = await (db.delete(db.budgets)
        ..where((b) => b.ledgerId.equals(ledgerId) &
              b.syncId.isNotNull() &
              (cloudBudgetSyncIds.isEmpty
                  ? const d.Constant(true)
                  : b.syncId.isNotIn(cloudBudgetSyncIds.toList()))))
      .go();
  total += delBudgets;

  // 周期规则：按账本范围镜像
  final cloudRecurringSyncIds =
      cloud.recurrings.map((r) => r.syncId).whereType<String>().toSet();
  final delRecs = await (db.delete(db.recurringTransactions)
        ..where((r) => r.ledgerId.equals(ledgerId) &
              r.syncId.isNotNull() &
              (cloudRecurringSyncIds.isEmpty
                  ? const d.Constant(true)
                  : r.syncId.isNotIn(cloudRecurringSyncIds.toList()))))
      .go();
  total += delRecs;

  // v46 自定义字段定义（ledger-scoped）：删「不在云端且本地已有 syncId」的行。
  // 无 syncId 的本地行保留 —— 那是尚未上传过的新字段，云端"缺席"不代表
  // 用户删过它（同 tags 的保守规则）。对应的交易值无需单独清理：
  // 交易行已被 clearLedgerTransactions 整体清空后重导。
  final cloudCustomFieldSyncIds = cloud.customFields
      .map((f) => f.syncId)
      .whereType<String>()
      .where((s) => s.isNotEmpty)
      .toSet();
  final delCustomFields = await (db.delete(db.customFieldDefinitions)
        ..where((f) => f.ledgerId.equals(ledgerId) &
              f.syncId.isNotNull() &
              (cloudCustomFieldSyncIds.isEmpty
                  ? const d.Constant(true)
                  : f.syncId.isNotIn(cloudCustomFieldSyncIds.toList()))))
      .go();
  total += delCustomFields;

  // 分类：全局表，仅删「不在云端且无任何引用」的
  // （引用来源：交易 categoryId、预算 categoryId、周期 categoryId、子分类 parentId）
  final cloudCatSyncIds =
      cloud.categories.map((c) => c.syncId).whereType<String>().toSet();
  final usedCatIds = <int>{
    ...(await (db.selectOnly(db.transactions)
            ..addColumns([db.transactions.categoryId]))
        .map((row) => row.read(db.transactions.categoryId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.budgets)
            ..addColumns([db.budgets.categoryId]))
        .map((row) => row.read(db.budgets.categoryId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.recurringTransactions)
            ..addColumns([db.recurringTransactions.categoryId]))
        .map((row) => row.read(db.recurringTransactions.categoryId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.categories)
            ..addColumns([db.categories.parentId]))
        .map((row) => row.read(db.categories.parentId))
        .get())
        .whereType<int>(),
  };
  final delCats = await (db.delete(db.categories)
        ..where((c) => c.syncId.isNotNull() &
              (cloudCatSyncIds.isEmpty
                  ? const d.Constant(true)
                  : c.syncId.isNotIn(cloudCatSyncIds.toList())) &
              (usedCatIds.isEmpty
                  ? const d.Constant(true)
                  : c.id.isNotIn(usedCatIds.toList()))))
      .go();
  total += delCats;

  // 标签：仅删「不在云端且无交易关联」的
  final cloudTagSyncIds =
      cloud.tags.map((t) => t.syncId).whereType<String>().toSet();
  final usedTagIds = (await (db.selectOnly(db.transactionTags)
          ..addColumns([db.transactionTags.tagId]))
        .map((row) => row.read(db.transactionTags.tagId))
        .get())
      .whereType<int>()
      .toSet();
  final delTags = await (db.delete(db.tags)
        ..where((t) => t.syncId.isNotNull() &
              (cloudTagSyncIds.isEmpty
                  ? const d.Constant(true)
                  : t.syncId.isNotIn(cloudTagSyncIds.toList())) &
              (usedTagIds.isEmpty
                  ? const d.Constant(true)
                  : t.id.isNotIn(usedTagIds.toList()))))
      .go();
  total += delTags;

  // 账户：全局表，仅删「不在云端且无任何引用」的
  // （引用来源：交易 accountId/toAccountId、周期 accountId/toAccountId，
  // 全账本范围 —— 账户是 user-global 实体，其他账本的引用同样构成保留理由）
  final cloudAccountSyncIds =
      cloud.accounts.map((a) => a.syncId).whereType<String>().toSet();
  final usedAccountIds = <int>{
    ...(await (db.selectOnly(db.transactions)
            ..addColumns([db.transactions.accountId]))
        .map((row) => row.read(db.transactions.accountId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.transactions)
            ..addColumns([db.transactions.toAccountId]))
        .map((row) => row.read(db.transactions.toAccountId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.recurringTransactions)
            ..addColumns([db.recurringTransactions.accountId]))
        .map((row) => row.read(db.recurringTransactions.accountId))
        .get())
        .whereType<int>(),
    ...(await (db.selectOnly(db.recurringTransactions)
            ..addColumns([db.recurringTransactions.toAccountId]))
        .map((row) => row.read(db.recurringTransactions.toAccountId))
        .get())
        .whereType<int>(),
  };
  final delAccounts = await (db.delete(db.accounts)
        ..where((a) => a.syncId.isNotNull() &
              (cloudAccountSyncIds.isEmpty
                  ? const d.Constant(true)
                  : a.syncId.isNotIn(cloudAccountSyncIds.toList())) &
              (usedAccountIds.isEmpty
                  ? const d.Constant(true)
                  : a.id.isNotIn(usedAccountIds.toList()))))
      .go();
  total += delAccounts;

  if (total > 0) {
    logger.info('DataImport',
        'H3 镜像删除(ledgerId=$ledgerId): 预算=$delBudgets 周期=$delRecs '
        '自定义字段=$delCustomFields 分类=$delCats 标签=$delTags 账户=$delAccounts');
  }
  return total;
}
