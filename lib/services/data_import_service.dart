import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';
import '../cloud/transactions_json.dart';
import '../data/db.dart';
import '../data/repositories/base_repository.dart';
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
  });
}

/// 导入手动汇率覆盖（v8 G4）。业务键 (baseCurrency, quoteCurrency)。
class ImportRateOverride {
  final String baseCurrency;
  final String quoteCurrency;
  final double rate;

  const ImportRateOverride({
    required this.baseCurrency,
    required this.quoteCurrency,
    required this.rate,
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
  /// 从 attachments/<sha256>.bin 后台补齐文件。
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
  /// 共享账本 override：Editor 视角选 Owner 的 category/account/tag，
  /// 本地主表无对应 int id，直接存 Owner 的 syncId。JSON 同步必须传输，
  /// 否则 modified 后 override 丢失、回退到 categoryId int（可能为 null）。
  final String? categorySyncIdOverride;
  final String? accountSyncIdOverride;
  final String? toAccountSyncIdOverride;
  /// v8 G2：周期规则锚点。导入后用于重建 transactions.recurringId。
  final String? recurringSyncId;

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
    this.categorySyncIdOverride,
    this.accountSyncIdOverride,
    this.toAccountSyncIdOverride,
    this.recurringSyncId,
  });
}

/// 统一的导入数据格式
class ImportData {
  final List<ImportAccount> accounts;
  final List<ImportCategory> categories;
  final List<ImportTag> tags;
  final List<ImportTransaction> transactions;
  /// v8 G1：预算（快照恢复）
  final List<ImportBudget> budgets;
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
  /// 快照 payload version（H1/H3：镜像删除仅在 v8+ 生效）
  final int? version;
  /// H1：解析时因字段损坏被跳过的条目数（key: accounts/categories/
  /// budgets/recurring/rateOverrides/tags/transactions/attachments），
  /// 供日志与 UI 提示
  final Map<String, int> skippedItems;

  const ImportData({
    this.accounts = const [],
    this.categories = const [],
    this.tags = const [],
    this.transactions = const [],
    this.budgets = const [],
    this.recurrings = const [],
    this.rateOverrides = const [],
    this.ledgerName,
    this.currency,
    this.monthStartDay,
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
      } catch (_) {}
    }
    if (data.monthStartDay != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          monthStartDay: data.monthStartDay!.clamp(1, 28),
        );
      } catch (_) {}
    }

    // 2. 导入账户
    final accountNameToId = await importAccounts(
      repo,
      data.accounts,
      defaultCurrency: data.currency ?? defaultCurrency,
    );

    // 3. 导入分类
    final categoryCache = await importCategories(repo, data.categories);

    // 4. 导入标签
    final tagMaps = await importTags(repo, data.tags);
    final tagNameToId = tagMaps.byName;
    final tagSyncIdToId = tagMaps.bySyncId;

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
      for (final acc in existingAccounts) {
        accountNameToId[acc.name] = acc.id;
        if (acc.syncId != null && acc.syncId!.isNotEmpty) {
          accountSyncIdToId[acc.syncId!] = acc.id;
          accountIdToSyncId[acc.id] = acc.syncId!;
        }
      }

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
          // 已存在账户：仅在存在非 null 扩展字段时才更新（null 保持本地
          // 原值）。避免全 null 时也触发 updateAccount → 无意义 DB 写入 +
          // change log 记录假'update' change（下次同步白推一次）。
          final localSyncId = accountIdToSyncId[existingId];
          // name 命中但本地无 syncId 时回填 incoming.syncId:让两台设备
          // 各自创建的同名账户收敛到同一身份,后续导出/同步按 syncId 锚定。
          final needBackfillSyncId =
              matchedByName && localSyncId == null && acc.syncId != null;
          final hasUpdates = acc.type != null ||
              acc.currency != null ||
              acc.initialBalance != null ||
              acc.creditLimit != null ||
              acc.billingDay != null ||
              acc.paymentDueDay != null ||
              acc.bankName != null ||
              acc.cardLastFour != null ||
              acc.note != null ||
              acc.hidden != null ||
              acc.sortOrder != null ||
              needBackfillSyncId;
          if (hasUpdates) {
            await repo.updateAccount(
              existingId,
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
            if (needBackfillSyncId && acc.syncId != null) {
              accountSyncIdToId[acc.syncId!] = existingId;
              accountIdToSyncId[existingId] = acc.syncId!;
            }
            // syncId 命中但名称被对端改过 → 同步刷新 name 映射,
            // 后续交易按新 name 引用才能命中该账户。
            accountNameToId[acc.name] = existingId;
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
    } catch (e, st) {
      logger.error('AccountImport', '账户导入失败', e, st);
    }

    return accountNameToId;
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
      for (final c in all) {
        byKindName['${c.kind}|${c.name}'] = c.id;
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
          // 命中：对齐云端 syncId（云端身份优先，null 不覆盖本地）
          final localSyncId = syncIdById[id];
          if (cat.syncId != null &&
              cat.syncId!.isNotEmpty &&
              cat.syncId != localSyncId) {
            await repo.updateCategory(id, syncId: cat.syncId);
            bySyncId[cat.syncId!] = id;
            syncIdById[id] = cat.syncId!;
            updated++;
          }
          categoryCache[key] = id;
          byKindName[key] = id;
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

  /// 导入手动汇率覆盖（v8 G4）。按 (base, quote) 唯一键 upsert，
  /// setOverride 内部已处理插入/更新两种情况。
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
          rate: o.rate.toStringAsFixed(6),
        );
      }
      logger.info('RateOverrideImport', '手动汇率导入完成');
    } catch (e, st) {
      logger.error('RateOverrideImport', '手动汇率导入失败', e, st);
    }
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
      // 共享账本 override 与本地 int id 互斥（§7 决策，与 SyncEngine 一致）：
      // override 非空时 categoryId/accountId/toAccountId 一律留 null，
      // 避免本地主表同名分类/账户被误解析导致「override + int 双写」。
      final hasCatOverride = (tx.categorySyncIdOverride?.isNotEmpty ?? false);
      final hasAccOverride = (tx.accountSyncIdOverride?.isNotEmpty ?? false);
      final hasToOverride =
          (tx.toAccountSyncIdOverride?.isNotEmpty ?? false);

      // 解析分类ID
      int? categoryId;
      if (hasCatOverride) {
        categoryId = null;
      } else if (tx.categoryId != null) {
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
          } catch (_) {}
        }
      }

      // 解析账户ID（override 非空时留 null，见上方分类注释）
      int? accountId;
      int? toAccountId;
      if (tx.type == 'transfer') {
        if (!hasAccOverride && tx.fromAccountName != null) {
          accountId = accountNameToId[tx.fromAccountName];
          if (accountId == null) {
            // B2:失败也回调进度,避免 UI 进度条卡死/失真
            failed++;
            processed++;
            if (onProgress != null) onProgress(processed, total);
            continue;
          }
        }
        if (!hasToOverride && tx.toAccountName != null) {
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
        if (!hasAccOverride && tx.accountName != null) {
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
            } catch (_) {}
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
        // 账单标记：JSON 同步必须传输，否则"不计入统计/预算"跨设备丢失
        excludeFromStats: d.Value(tx.excludeFromStats),
        excludeFromBudget: d.Value(tx.excludeFromBudget),
        // 共享账本 override：added 恢复路径必须写入，否则 JSON 全量导入后
        // Editor 视角记的 tx override 丢失、回退到 categoryId int（null）。
        categorySyncIdOverride: d.Value(tx.categorySyncIdOverride),
        accountSyncIdOverride: d.Value(tx.accountSyncIdOverride),
        toAccountSyncIdOverride: d.Value(tx.toAccountSyncIdOverride),
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
  final remoteImport = parseJsonToImportData(jsonStr);
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
  final deleted = await db.transaction(() async {
    final cleared = await clearLedgerTransactions(db, ledgerId);
    final result = await importTransactionsJson(repo, ledgerId, jsonStr,
        recordChanges: false);
    // H3 真覆盖（镜像云端）：v8+ 快照把云端已删除的预算/周期/分类/标签
    // 传播到本地。旧实现只 upsert 不删除，「全量覆盖」后云端删掉的实体
    // 在本地永不消失。
    if (remoteImport.version != null && remoteImport.version! >= 8) {
      await _mirrorDeleteAbsentEntities(db, ledgerId, remoteImport);
    }
    return (cleared, result);
  });

  return (
    inserted: deleted.$2.inserted,
    deletedDup: deleted.$1,
    skippedRecurring: deleted.$2.skippedRecurring,
  );
}

/// H3 真覆盖（镜像云端）：删除「本地有 syncId 但 v8 快照中不存在」的实体。
///
/// 安全边界：只删「本地行有 syncId 且不在云端 syncId 集合」——
/// 云端行无 syncId 或本地行无 syncId（同步纪元前遗留）都不删，
/// 防止旧快照/异常数据误删。分类/标签是全局表，仅在无任何账本引用
/// （交易/预算/周期/父子层级/标签关联）时删除。
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

  if (total > 0) {
    logger.info('DataImport',
        'H3 镜像删除(ledgerId=$ledgerId): 预算=$delBudgets 周期=$delRecs 分类=$delCats 标签=$delTags');
  }
  return total;
}
