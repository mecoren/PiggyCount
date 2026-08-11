import 'package:drift/drift.dart' as d;
import 'package:uuid/uuid.dart';
import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../data/repositories/transaction_repository.dart' show BatchAttachmentData;
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

  const ImportAttachment({
    required this.fileName,
    this.originalName,
    this.fileSize,
    this.width,
    this.height,
    this.sortOrder = 0,
    this.cloudFileId,
    this.cloudSha256,
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
  });
}

/// 统一的导入数据格式
class ImportData {
  final List<ImportAccount> accounts;
  final List<ImportCategory> categories;
  final List<ImportTag> tags;
  final List<ImportTransaction> transactions;

  /// 账本名称（可选，用于更新账本信息）
  final String? ledgerName;
  /// 货币（可选，用于更新账本信息）
  final String? currency;

  const ImportData({
    this.accounts = const [],
    this.categories = const [],
    this.tags = const [],
    this.transactions = const [],
    this.ledgerName,
    this.currency,
  });
}

/// 导入结果
class ImportResult {
  final int inserted;
  final int failed;

  const ImportResult({
    required this.inserted,
    required this.failed,
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
    if (data.ledgerName != null || data.currency != null) {
      try {
        await repo.updateLedger(
          id: ledgerId,
          name: data.ledgerName,
          currency: data.currency,
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

    // 5. 导入交易
    final result = await importTransactions(
      repo,
      ledgerId,
      data.transactions,
      accountNameToId: accountNameToId,
      categoryCache: categoryCache,
      tagNameToId: tagNameToId,
      tagSyncIdToId: tagSyncIdToId,
      onProgress: onProgress,
      recordChanges: recordChanges,
    );

    return result;
  }

  /// 导入账户(全局按名称去重)。public — sync_diff_service 也复用,避免维护两套。
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
      for (final acc in existingAccounts) {
        accountNameToId[acc.name] = acc.id;
      }

      for (final acc in accounts) {
        if (!accountNameToId.containsKey(acc.name)) {
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
          final existingId = accountNameToId[acc.name]!;
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
              acc.sortOrder != null;
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
            );
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
  Future<Map<String, int>> importCategories(
    BaseRepository repo,
    List<ImportCategory> categories,
  ) async {
    final categoryCache = <String, int>{}; // key: kind|name -> id

    if (categories.isEmpty) return categoryCache;
    logger.info('CategoryImport', '开始导入分类: ${categories.length} 个');
    final sw = Stopwatch()..start();
    int created = 0;

    try {
      // 获取所有现有分类
      final existingExpense = await repo.getTopLevelCategories('expense');
      final existingIncome = await repo.getTopLevelCategories('income');
      final existingCategoryMap = <String, int>{};

      for (final cat in [...existingExpense, ...existingIncome]) {
        existingCategoryMap['${cat.kind}|${cat.name}'] = cat.id;
        // 获取子分类
        final subCats = await repo.getSubCategories(cat.id);
        for (final sub in subCats) {
          existingCategoryMap['${sub.kind}|${sub.name}'] = sub.id;
        }
      }

      // 分离一级和二级分类
      final level1 = categories.where((c) => c.level == 1 || c.parentName == null).toList();
      final level2 = categories.where((c) => c.level == 2 && c.parentName != null).toList();

      // 导入一级分类
      for (final cat in level1) {
        final key = '${cat.kind}|${cat.name}';
        if (existingCategoryMap.containsKey(key)) {
          categoryCache[key] = existingCategoryMap[key]!;
        } else {
          final id = await repo.createCategory(
            name: cat.name,
            kind: cat.kind,
            icon: cat.icon,
            sortOrder: cat.sortOrder,
          );
          categoryCache[key] = id;
          created++;

          // 如果有自定义图标信息，更新图标
          if (cat.iconType != null && cat.iconType != 'material') {
            await repo.updateCategoryIcon(
              id,
              iconType: cat.iconType!,
              icon: cat.icon,
              customIconPath: cat.customIconPath,
              communityIconId: cat.communityIconId,
            );
          }
        }
      }

      // 导入二级分类
      for (final cat in level2) {
        final key = '${cat.kind}|${cat.name}';
        if (existingCategoryMap.containsKey(key)) {
          categoryCache[key] = existingCategoryMap[key]!;
        } else {
          // 查找父分类ID
          final parentKey = '${cat.kind}|${cat.parentName}';
          final parentId = categoryCache[parentKey];
          if (parentId != null) {
            final id = await repo.createSubCategory(
              parentId: parentId,
              name: cat.name,
              kind: cat.kind,
              icon: cat.icon,
              sortOrder: cat.sortOrder,
            );
            categoryCache[key] = id;

            // 如果有自定义图标信息，更新图标
            if (cat.iconType != null && cat.iconType != 'material') {
              await repo.updateCategoryIcon(
                id,
                iconType: cat.iconType!,
                icon: cat.icon,
                customIconPath: cat.customIconPath,
                communityIconId: cat.communityIconId,
              );
            }
          }
        }
      }
      logger.info('CategoryImport',
          '分类导入完成: 新增=$created 已存在=${categories.length - created} 耗时=${sw.elapsedMilliseconds}ms');
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
    void Function(int done, int total)? onProgress,
    bool recordChanges = true,
  }) async {
    int inserted = 0;
    int failed = 0;
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
        logger.error('TxImport', '批次 flush 失败,本批 $size 条算 failed', e, st);
        failed += size;
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
            failed++;
            processed++;
            continue;
          }
        }
        if (!hasToOverride && tx.toAccountName != null) {
          toAccountId = accountNameToId[tx.toAccountName];
          if (toAccountId == null) {
            failed++;
            processed++;
            continue;
          }
        }
      } else {
        if (!hasAccOverride && tx.accountName != null) {
          accountId = accountNameToId[tx.accountName];
        }
      }

      // 解析标签ID — 优先按 tagSyncIds 匹配（跨设备 rename 稳定锚定），
      // 互斥而非叠加：v7 JSON 里 tagSyncIds 是权威锚点，name 只是可读参考，
      // 叠加会导致两端 tag 集合不一致时（本地同名不同 syncId 的独立标签）
      // 多加标签。syncId 全部 miss 才回退 name。用 Set 去重。
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
        resolvedBySyncId = resolvedTagIds.isNotEmpty;
      }

      // 2. 按 name 解析（仅当无 tagSyncIds 或 syncId 全部 miss 时兜底）
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
        '交易导入完成: 总数=$total 成功=$inserted 失败=$failed 总耗时=${overallSw.elapsedMilliseconds}ms');
    return ImportResult(inserted: inserted, failed: failed);
  }
}

/// 全局单例
final dataImportService = DataImportService();
