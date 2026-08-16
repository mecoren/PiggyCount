import 'dart:convert';
import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';

/// 账本交易数据的 JSON 导入导出工具
///
/// 用于云同步时序列化和反序列化交易数据

// --- 字符串清理 ---

/// 清理字符串中的控制字符，防止 JSON 解析错误
String _sanitizeString(String? input) {
  if (input == null) return '';
  // 移除所有控制字符（ASCII 0-31，除了常见的制表符、换行符等）
  // 并替换换行符和制表符为空格
  return input
      .replaceAll(RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]'), '')
      .replaceAll('\n', ' ')
      .replaceAll('\r', ' ')
      .replaceAll('\t', ' ')
      .trim();
}

// --- 导出 ---

/// 导出账本交易数据为 JSON 字符串
///
/// [db] - 数据库实例
/// [ledgerId] - 账本ID
///
/// 返回包含以下字段的 JSON：
/// - version: 数据格式版本（当前为7）
/// - exportedAt: 导出时间戳
/// - ledgerId: 账本ID
/// - ledgerName: 账本名称
/// - currency: 货币
/// - count: 交易条数
/// - accounts: 账户列表（name, type, currency, initialBalance + 扩展字段）
/// - categories: 分类列表（name, kind, level, icon, parentName）
/// - tags: 标签列表（name, color, syncId, sortOrder）
/// - items: 交易明细（type, amount, categoryName, categoryKind, happenedAt,
///   note, tags, tagSyncIds, override 字段）
Future<String> exportTransactionsJson(PiggyDatabase db, int ledgerId) async {
  logger.debug('TransactionsJson', '开始导出账本 $ledgerId');

  final txs = await (db.select(db.transactions)
        ..where((t) => t.ledgerId.equals(ledgerId)))
      .get();

  logger.debug('TransactionsJson', '账本 $ledgerId 共有 ${txs.length} 条交易');

  // 稳定排序，避免不同平台/查询导致顺序差异
  txs.sort((a, b) {
    final c = a.happenedAt.compareTo(b.happenedAt);
    if (c != 0) return c;
    return a.id.compareTo(b.id);
  });

  // ledger meta（提前查询：items 构建需要账本币种做币种规范化）
  final ledger = await (db.select(db.ledgers)
        ..where((l) => l.id.equals(ledgerId)))
      .getSingleOrNull();

  // 周期规则（v8 G2）：id → syncId 映射，items 的 recurringSyncId 需要它
  // 把本地 int 外键翻译成跨设备稳定的字符串锚点。
  final ledgerRecurrings = await (db.select(db.recurringTransactions)
        ..where((r) => r.ledgerId.equals(ledgerId)))
      .get();
  final recurringIdToSyncId = <int, String?>{};
  for (final r in ledgerRecurrings) {
    recurringIdToSyncId[r.id] = r.syncId;
  }

  // 获取所有交易的标签（批量查询）
  final txIds = txs.map((t) => t.id).toList();
  final tagsMap = <int, List<Tag>>{}; // transactionId -> tags
  final allUsedTags = <int, Tag>{}; // tagId -> tag（用于导出标签列表）

  if (txIds.isNotEmpty) {
    // 批量查询所有交易的标签关联
    final tagRelations = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.isIn(txIds)))
        .get();

    // 获取所有使用的标签ID
    final usedTagIds = tagRelations.map((r) => r.tagId).toSet();
    if (usedTagIds.isNotEmpty) {
      final tags = await (db.select(db.tags)
            ..where((t) => t.id.isIn(usedTagIds.toList())))
          .get();
      for (final tag in tags) {
        allUsedTags[tag.id] = tag;
      }

      // 构建 transactionId -> tags 映射
      for (final rel in tagRelations) {
        final tag = allUsedTags[rel.tagId];
        if (tag != null) {
          tagsMap.putIfAbsent(rel.transactionId, () => []).add(tag);
        }
      }
    }
  }

  // Map categoryId -> name/kind for used categories（仅服务 items 构建；
  // 分类数组本身 v8 起全量导出，不再依赖此集合）
  final usedCatIds = txs.map((t) => t.categoryId).whereType<int>().toSet();
  final cats = <int, Map<String, dynamic>>{};

  for (final cid in usedCatIds) {
    final c = await (db.select(db.categories)..where((c) => c.id.equals(cid)))
        .getSingleOrNull();
    if (c != null) {
      final sanitizedName = _sanitizeString(c.name);
      cats[cid] = {"name": sanitizedName, "kind": c.kind};
    }
  }

  // 账户是 user-global 实体(ledger_id=0,与账本解耦),这里导出**全量**账户
  // 而非仅被交易引用的账户 —— 否则未被交易引用的账户(新建空账户、删完交易
  // 的账户)永远不上云,另一台设备的资产管理里会缺账户(account_sync_fix G1)。
  // 每个 ledger 快照都携带同一份全量账户列表,恢复任意一个快照即可收敛
  // 账户集合;账户数量级小(几十条),冗余可接受。
  final accounts = (await db.select(db.accounts).get())
    ..sort((a, b) => a.id.compareTo(b.id)); // 稳定排序,保证跨设备指纹可比
  final accountIdToName = <int, String>{}; // 账户ID -> 名称映射
  final accountIdToSyncId = <int, String?>{}; // 账户ID -> syncId（v8 recurring 用）
  for (final a in accounts) {
    accountIdToName[a.id] = _sanitizeString(a.name);
    accountIdToSyncId[a.id] = a.syncId;
  }
  final accountItems = accounts
      .map((a) => {
            'name': _sanitizeString(a.name),
            'type': a.type,
            'currency': a.currency,
            'initialBalance': a.initialBalance,
            'sortOrder': a.sortOrder,
            if (a.creditLimit != null) 'creditLimit': a.creditLimit,
            if (a.billingDay != null) 'billingDay': a.billingDay,
            if (a.paymentDueDay != null) 'paymentDueDay': a.paymentDueDay,
            if (a.bankName != null) 'bankName': _sanitizeString(a.bankName),
            if (a.cardLastFour != null)
              'cardLastFour': _sanitizeString(a.cardLastFour),
            if (a.note != null) 'note': _sanitizeString(a.note),
            'hidden': a.hidden,
            if (a.syncId != null) 'syncId': a.syncId,
          })
      .toList();

  final items = txs.map((t) {
    // 安全获取分类信息（分类可能已被删除）
    final catInfo = t.categoryId != null ? cats[t.categoryId] : null;

    // 记录分类缺失的交易（用于排查数据问题）
    if (t.categoryId != null && catInfo == null) {
      logger.warning('TransactionsJson',
        '交易 ${t.id} 引用了不存在的分类 ${t.categoryId}, '
        'amount=${t.amount}, note=${t.note}, happenedAt=${t.happenedAt}');
    }

    final item = <String, dynamic>{
      'type': t.type,
      'amount': t.amount,
      'categoryName': catInfo?['name'],
      'categoryKind': catInfo?['kind'],
      'happenedAt': t.happenedAt.toUtc().toIso8601String(),
      'note': _sanitizeString(t.note),
      if (t.syncId != null) 'syncId': t.syncId,
      // 账单标记 + v30 多币种：必须随 JSON 传输，否则跨设备 WebDAV
      // 同步后标记/折算值丢失（例如"不计入统计"的交易同步后变回计入，
      // 导致合计虚高）。与 SyncEngine 的 entity_serializer 保持一致。
      'excludeFromStats': t.excludeFromStats,
      'excludeFromBudget': t.excludeFromBudget,
      // 币种规范化：currencyCode 为空视为账本本币、nativeAmount 为空视为
      // amount。不同写入路径（部分填 CNY+折算值、部分留空）产生的语义相同
      // 数据，若原样导出会让两台设备算出不同指纹 → 永远 cloudNewer →
      // 每次启动误弹「云端有更新」（account_dedup 排查实测 5700/8350 行
      // 因此不收敛）。规范化是导出字段的确定性函数，两端结果一致。
      'currencyCode': t.currencyCode ?? ledger?.currency ?? 'CNY',
      'nativeAmount': t.nativeAmount ?? t.amount,
      // 共享账本 override：Editor 选 Owner 的 category/account，本地主表
      // 无 int id，直接存 syncId。modified 同步后必须保留，否则 override
      // 丢失回退到 categoryId（可能 null）。
      if (t.categorySyncIdOverride != null)
        'categorySyncIdOverride': t.categorySyncIdOverride,
      if (t.accountSyncIdOverride != null)
        'accountSyncIdOverride': t.accountSyncIdOverride,
      if (t.toAccountSyncIdOverride != null)
        'toAccountSyncIdOverride': t.toAccountSyncIdOverride,
      // v8 G2：周期规则锚点。recurringId 是本地 int，跨设备必须用 syncId；
      // 规则本身在顶层 recurring 数组里，恢复端靠此字段重建关联。
      if (t.recurringId != null &&
          (recurringIdToSyncId[t.recurringId] ?? '').isNotEmpty)
        'recurringSyncId': recurringIdToSyncId[t.recurringId],
    };

    // 添加账户信息
    if (t.type == 'transfer') {
      // 转账：添加转出账户和转入账户
      if (t.accountId != null) {
        item['fromAccountName'] = accountIdToName[t.accountId];
      }
      if (t.toAccountId != null) {
        item['toAccountName'] = accountIdToName[t.toAccountId];
      }
    } else {
      // 收入或支出：添加账户
      if (t.accountId != null) {
        item['accountName'] = accountIdToName[t.accountId];
      }
    }

    // 添加标签（逗号分隔的标签名称 + syncId 列表）
    final txTags = tagsMap[t.id];
    if (txTags != null && txTags.isNotEmpty) {
      // 去重：防止脏数据产生重复标签名或重复 syncId，避免跨设备 diff 循环
      final seenTagIds = <int>{};
      final uniqueTags = txTags.where((tag) => seenTagIds.add(tag.id)).toList();

      item['tags'] = uniqueTags.map((tag) => _sanitizeString(tag.name)).join(',');
      final syncIds = uniqueTags
          .map((tag) => tag.syncId)
          .whereType<String>()
          .where((s) => s.isNotEmpty)
          .toSet()
          .toList();
      if (syncIds.isNotEmpty) item['tagSyncIds'] = syncIds;
    }

    return item;
  }).toList();

  // v1.20.0: 导出附件元数据
  final attachmentsMap = <int, List<Map<String, dynamic>>>{}; // transactionId -> attachments
  if (txIds.isNotEmpty) {
    final allAttachments = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.isIn(txIds)))
        .get();
    for (final a in allAttachments) {
      final attMap = <String, dynamic>{
        'fileName': a.fileName,
        'originalName': a.originalName,
        'fileSize': a.fileSize,
        'width': a.width,
        'height': a.height,
        'sortOrder': a.sortOrder,
      };
      if (a.cloudFileId != null) attMap['cloudFileId'] = a.cloudFileId;
      if (a.cloudSha256 != null) attMap['cloudSha256'] = a.cloudSha256;
      // v8+(attachment_binary_sync):本地内容哈希。恢复端凭它从
      // attachments/<sha256>.bin 补齐文件;旧快照无此字段则保持缺文件现状。
      if (a.localSha256 != null) attMap['sha256'] = a.localSha256;
      attachmentsMap.putIfAbsent(a.transactionId, () => []).add(attMap);
    }
  }

  // 将附件信息添加到对应的交易 item 中
  for (int i = 0; i < txs.length; i++) {
    final txId = txs[i].id;
    if (attachmentsMap.containsKey(txId)) {
      items[i]['attachments'] = attachmentsMap[txId];
    }
  }

  // 构建 categories 数组（v8 G3：全量导出，与账户 G1 同理 —— 未被交易
  // 引用的自定义分类也要上云，否则另一台设备分类管理里缺失）。
  final categoryItems = <Map<String, dynamic>>[];
  final allCategoriesList = await db.select(db.categories).get();
  // id → 名称映射：budgets/recurring 数组的分类引用要用
  final categoryIdToName = <int, String>{};
  for (final c in allCategoriesList) {
    categoryIdToName[c.id] = _sanitizeString(c.name);
  }

  // 先导出一级分类，再导出二级分类（便于导入时先创建父分类）
  allCategoriesList.sort((a, b) {
    if (a.level != b.level) return a.level.compareTo(b.level);
    return a.id.compareTo(b.id);
  });

  for (final cat in allCategoriesList) {
    final categoryItem = <String, dynamic>{
      'name': _sanitizeString(cat.name),
      'kind': cat.kind,
      'level': cat.level,
      'sortOrder': cat.sortOrder, // 保存排序顺序
      'iconType': cat.iconType, // 图标类型: material / custom / community
      // v8 G3：分类 syncId。此前表里有列但快照不传，导入只能按 name+kind
      // 匹配 —— 两端各自建的同名分类无法按身份收敛。
      if (cat.syncId != null && cat.syncId!.isNotEmpty) 'syncId': cat.syncId,
    };

    // 添加图标信息（如果存在）
    if (cat.icon != null && cat.icon!.isNotEmpty) {
      categoryItem['icon'] = cat.icon;
    }

    // 添加自定义图标路径（如果存在）
    if (cat.customIconPath != null && cat.customIconPath!.isNotEmpty) {
      categoryItem['customIconPath'] = cat.customIconPath;
    }

    // 添加社区图标ID（如果存在）
    if (cat.communityIconId != null && cat.communityIconId!.isNotEmpty) {
      categoryItem['communityIconId'] = cat.communityIconId;
    }

    // 添加父分类名称（如果是二级分类）
    if (cat.level == 2 && cat.parentId != null) {
      final parentCat = allCategoriesList.firstWhere(
        (c) => c.id == cat.parentId,
        orElse: () => allCategoriesList.first, // 不应该发生
      );
      categoryItem['parentName'] = _sanitizeString(parentCat.name);
    }

    categoryItems.add(categoryItem);
  }

  // 构建标签列表（v8 G3：全量导出 —— 未被交易引用的标签也要上云，
  // 与账户/分类同理。allUsedTags 仍用于 items 的 tag 名拼接。）
  final allTags = await db.select(db.tags).get()
    ..sort((a, b) => a.id.compareTo(b.id)); // 稳定排序
  final tagItems = allTags.map((tag) {
    final tagItem = <String, dynamic>{
      'name': _sanitizeString(tag.name),
    };
    if (tag.color != null && tag.color!.isNotEmpty) {
      tagItem['color'] = tag.color;
    }
    if (tag.syncId != null && tag.syncId!.isNotEmpty) {
      tagItem['syncId'] = tag.syncId;
    }
    tagItem['sortOrder'] = tag.sortOrder;
    return tagItem;
  }).toList();

  // v8 G1：预算数组。budgets 是 ledger-scoped（按 ledgerId 过滤），
  // 导出按 syncId 锚定、稳定排序（跨设备指纹可比）。
  final ledgerBudgets = await (db.select(db.budgets)
        ..where((b) => b.ledgerId.equals(ledgerId)))
      .get()
    ..sort((a, b) {
      final ka = a.syncId ?? 'budget_${a.id}';
      final kb = b.syncId ?? 'budget_${b.id}';
      return ka.compareTo(kb);
    });
  final budgetItems = ledgerBudgets.map((b) {
    final categoryName =
        b.categoryId != null ? categoryIdToName[b.categoryId] : null;
    return <String, dynamic>{
      if (b.syncId != null && b.syncId!.isNotEmpty) 'syncId': b.syncId,
      'type': b.type,
      if (categoryName != null) 'categoryName': categoryName,
      'amount': b.amount,
      'period': b.period,
      'startDay': b.startDay,
      'enabled': b.enabled,
    };
  }).toList();

  // v8 G2：周期规则数组。int 外键（category/account/toAccount）翻译成
  // name + syncId 双锚点：导入端优先按 syncId 反查，name 兜底。
  final recurringItems = ledgerRecurrings.map((r) {
    final catName =
        r.categoryId != null ? categoryIdToName[r.categoryId] : null;
    String? accSyncId;
    String? toAccSyncId;
    if (r.accountId != null) accSyncId = accountIdToSyncId[r.accountId];
    if (r.toAccountId != null) toAccSyncId = accountIdToSyncId[r.toAccountId];
    return <String, dynamic>{
      if (r.syncId != null && r.syncId!.isNotEmpty) 'syncId': r.syncId,
      'type': r.type,
      'amount': r.amount,
      if (catName != null) 'categoryName': catName,
      if (r.accountId != null)
        'accountName': accountIdToName[r.accountId],
      if (accSyncId != null && accSyncId.isNotEmpty)
        'accountSyncId': accSyncId,
      if (r.toAccountId != null)
        'toAccountName': accountIdToName[r.toAccountId],
      if (toAccSyncId != null && toAccSyncId.isNotEmpty)
        'toAccountSyncId': toAccSyncId,
      'note': _sanitizeString(r.note),
      'frequency': r.frequency,
      'interval': r.interval,
      if (r.dayOfMonth != null) 'dayOfMonth': r.dayOfMonth,
      if (r.dayOfWeek != null) 'dayOfWeek': r.dayOfWeek,
      if (r.monthOfYear != null) 'monthOfYear': r.monthOfYear,
      'startDate': r.startDate.toUtc().toIso8601String(),
      if (r.endDate != null)
        'endDate': r.endDate!.toUtc().toIso8601String(),
      if (r.lastGeneratedDate != null)
        'lastGeneratedDate': r.lastGeneratedDate!.toUtc().toIso8601String(),
      'enabled': r.enabled,
    };
  }).toList()
    ..sort((a, b) {
      final ka = (a['syncId'] as String?) ?? '';
      final kb = (b['syncId'] as String?) ?? '';
      return ka.compareTo(kb);
    });

  // v8 G4：手动汇率覆盖。user-global 实体，随快照冗余携带（行数极少，
  // 与账户同策略）；业务键 (baseCurrency, quoteCurrency)。
  final rateOverrides = (await db.select(db.exchangeRateOverrides).get())
    ..sort((a, b) =>
        '${a.baseCurrency}/${a.quoteCurrency}'.compareTo('${b.baseCurrency}/${b.quoteCurrency}'));
  final rateOverrideItems = rateOverrides.map((o) {
    return <String, dynamic>{
      if (o.syncId != null && o.syncId!.isNotEmpty) 'syncId': o.syncId,
      'baseCurrency': o.baseCurrency,
      'quoteCurrency': o.quoteCurrency,
      'rate': o.rate,
    };
  }).toList();

  // 检查账本是否存在
  if (ledger == null) {
    logger.error('TransactionsJson', '账本 $ledgerId 不存在！');
    throw Exception('账本 $ledgerId 不存在');
  }

  final payload = {
    'version': 8, // v8: budgets/recurring/exchangeRateOverrides + 全量分类/标签 + recurringSyncId
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'ledgerId': ledgerId,
    'ledgerName': ledger.name,
    'currency': ledger.currency,
    'monthStartDay': ledger.monthStartDay,
    'count': items.length,
    'accounts': accountItems,
    'categories': categoryItems,
    'tags': tagItems, // 新增：标签信息
    'budgets': budgetItems, // v8 G1：预算
    'recurring': recurringItems, // v8 G2：周期规则
    'exchangeRateOverrides': rateOverrideItems, // v8 G4：手动汇率
    'items': items,
  };

  logger.debug('TransactionsJson', '导出完成: ${items.length} 条交易, ${categoryItems.length} 个分类');
  return jsonEncode(payload);
}

// --- 导入 ---

/// 将 JSON 数据转换为统一的 ImportData 格式
ImportData parseJsonToImportData(String jsonStr) {
  final data = jsonDecode(jsonStr) as Map<String, dynamic>;

  // 解析账户
  final accounts = <ImportAccount>[];
  final jsonAccounts = data['accounts'] as List?;
  if (jsonAccounts != null) {
    for (final acc in jsonAccounts.cast<Map<String, dynamic>>()) {
      accounts.add(ImportAccount(
        name: acc['name'] as String,
        type: acc['type'] as String?,
        currency: acc['currency'] as String?,
        initialBalance: (acc['initialBalance'] as num?)?.toDouble(),
        sortOrder: acc['sortOrder'] as int?,
        creditLimit: (acc['creditLimit'] as num?)?.toDouble(),
        billingDay: acc['billingDay'] as int?,
        paymentDueDay: acc['paymentDueDay'] as int?,
        bankName: acc['bankName'] as String?,
        cardLastFour: acc['cardLastFour'] as String?,
        note: acc['note'] as String?,
        hidden: acc['hidden'] as bool?,
        syncId: acc['syncId'] as String?,
      ));
    }
  }

  // 解析分类
  final categories = <ImportCategory>[];
  final jsonCategories = data['categories'] as List?;
  if (jsonCategories != null) {
    for (final cat in jsonCategories.cast<Map<String, dynamic>>()) {
      categories.add(ImportCategory(
        name: cat['name'] as String,
        kind: cat['kind'] as String,
        level: cat['level'] as int? ?? 1,
        sortOrder: cat['sortOrder'] as int? ?? 0,
        icon: cat['icon'] as String?,
        parentName: cat['parentName'] as String?,
        iconType: cat['iconType'] as String?,
        customIconPath: cat['customIconPath'] as String?,
        communityIconId: cat['communityIconId'] as String?,
        syncId: cat['syncId'] as String?,
      ));
    }
  }

  // 解析预算（v8 G1；旧快照无此数组 → 空列表，导入跳过不删本地）
  final budgets = <ImportBudget>[];
  final jsonBudgets = data['budgets'] as List?;
  if (jsonBudgets != null) {
    for (final b in jsonBudgets.cast<Map<String, dynamic>>()) {
      budgets.add(ImportBudget(
        syncId: b['syncId'] as String?,
        type: b['type'] as String? ?? 'total',
        categoryName: b['categoryName'] as String?,
        amount: (b['amount'] as num?)?.toDouble() ?? 0,
        period: b['period'] as String? ?? 'monthly',
        startDay: b['startDay'] as int? ?? 1,
        enabled: b['enabled'] as bool? ?? true,
      ));
    }
  }

  // 解析周期规则（v8 G2；旧快照无此数组 → 空列表）
  final recurrings = <ImportRecurring>[];
  final jsonRecurrings = data['recurring'] as List?;
  if (jsonRecurrings != null) {
    for (final r in jsonRecurrings.cast<Map<String, dynamic>>()) {
      recurrings.add(ImportRecurring(
        syncId: r['syncId'] as String?,
        type: r['type'] as String,
        amount: (r['amount'] as num).toDouble(),
        categoryName: r['categoryName'] as String?,
        accountName: r['accountName'] as String?,
        accountSyncId: r['accountSyncId'] as String?,
        toAccountName: r['toAccountName'] as String?,
        toAccountSyncId: r['toAccountSyncId'] as String?,
        note: r['note'] as String?,
        frequency: r['frequency'] as String,
        interval: r['interval'] as int? ?? 1,
        dayOfMonth: r['dayOfMonth'] as int?,
        dayOfWeek: r['dayOfWeek'] as int?,
        monthOfYear: r['monthOfYear'] as int?,
        startDate: DateTime.parse(r['startDate'] as String),
        endDate: r['endDate'] != null
            ? DateTime.parse(r['endDate'] as String)
            : null,
        lastGeneratedDate: r['lastGeneratedDate'] != null
            ? DateTime.parse(r['lastGeneratedDate'] as String)
            : null,
        enabled: r['enabled'] as bool? ?? true,
      ));
    }
  }

  // 解析手动汇率覆盖（v8 G4）
  final rateOverrides = <ImportRateOverride>[];
  final jsonRateOverrides = data['exchangeRateOverrides'] as List?;
  if (jsonRateOverrides != null) {
    for (final o in jsonRateOverrides.cast<Map<String, dynamic>>()) {
      final base = o['baseCurrency'] as String?;
      final quote = o['quoteCurrency'] as String?;
      // exchangeRateOverrides.rate 是 TEXT 列，JSON 中以字符串形式序列化，
      // 需兼容 String 与 num 两种形态。
      final rate = (o['rate'] is num
              ? o['rate'] as num
              : num.tryParse(o['rate']?.toString() ?? ''))
          ?.toDouble();
      if (base == null || quote == null || rate == null || rate <= 0) continue;
      rateOverrides.add(ImportRateOverride(
        baseCurrency: base,
        quoteCurrency: quote,
        rate: rate,
      ));
    }
  }

  // 解析标签
  final tags = <ImportTag>[];
  final jsonTags = data['tags'] as List?;
  if (jsonTags != null) {
    for (final tag in jsonTags.cast<Map<String, dynamic>>()) {
      tags.add(ImportTag(
        name: tag['name'] as String,
        color: tag['color']?.toString(),
        syncId: tag['syncId'] as String?,
        sortOrder: tag['sortOrder'] as int?,
      ));
    }
  }

  // 解析交易
  final transactions = <ImportTransaction>[];
  final jsonItems = data['items'] as List?;
  if (jsonItems != null) {
    for (final it in jsonItems.cast<Map<String, dynamic>>()) {
      // 解析标签名称列表
      List<String>? tagNames;
      final tagsStr = it['tags'] as String?;
      if (tagsStr != null && tagsStr.trim().isNotEmpty) {
        tagNames = tagsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      // 解析附件元数据
      List<ImportAttachment>? attachments;
      final jsonAttachments = it['attachments'] as List?;
      if (jsonAttachments != null && jsonAttachments.isNotEmpty) {
        attachments = jsonAttachments.cast<Map<String, dynamic>>().map((a) {
          return ImportAttachment(
            fileName: a['fileName'] as String,
            originalName: a['originalName'] as String?,
            fileSize: a['fileSize'] as int?,
            width: a['width'] as int?,
            height: a['height'] as int?,
            sortOrder: a['sortOrder'] as int? ?? 0,
            cloudFileId: a['cloudFileId'] as String?,
            cloudSha256: a['cloudSha256'] as String?,
            sha256: a['sha256'] as String?,
          );
        }).toList();
      }

      final type = it['type'] as String;
      // 解析标签 syncId 列表
      List<String>? tagSyncIds;
      final rawTagSyncIds = it['tagSyncIds'];
      if (rawTagSyncIds is List && rawTagSyncIds.isNotEmpty) {
        tagSyncIds = rawTagSyncIds.whereType<String>().toList();
      }
      transactions.add(ImportTransaction(
        type: type,
        amount: (it['amount'] as num).toDouble(),
        categoryName: it['categoryName'] as String?,
        categoryKind: it['categoryKind'] as String?,
        happenedAt: DateTime.parse(it['happenedAt'] as String).toLocal(),
        note: it['note'] as String?,
        // 账户信息：转账用 fromAccountName/toAccountName，其他用 accountName
        accountName: type != 'transfer' ? it['accountName'] as String? : null,
        fromAccountName: type == 'transfer' ? it['fromAccountName'] as String? : null,
        toAccountName: type == 'transfer' ? it['toAccountName'] as String? : null,
        tagNames: tagNames,
        tagSyncIds: tagSyncIds,
        attachments: attachments,
        syncId: it['syncId'] as String?,
        // 账单标记 + v30 多币种
        excludeFromStats: it['excludeFromStats'] as bool? ?? false,
        excludeFromBudget: it['excludeFromBudget'] as bool? ?? false,
        currencyCode: it['currencyCode'] as String?,
        nativeAmount: (it['nativeAmount'] as num?)?.toDouble(),
        // 共享账本 override
        categorySyncIdOverride: it['categorySyncIdOverride'] as String?,
        accountSyncIdOverride: it['accountSyncIdOverride'] as String?,
        toAccountSyncIdOverride: it['toAccountSyncIdOverride'] as String?,
        // v8 G2：周期规则锚点
        recurringSyncId: it['recurringSyncId'] as String?,
      ));
    }
  }

  // v8 G5：monthStartDay 进 ImportData。旧版注释里该字段由 Cloud 引擎的
  // syncLedgersFromServer 收敛 —— 但纯快照(WebDAV/S3/Supabase/iCloud)
  // 用户没有 Cloud 引擎,「下载恢复」后本地月起始日永远不收敛(sync_gap_closure G5)。
  // 现在恢复路径以快照为准回写;Cloud 路径同值写入幂等,不冲突。
  return ImportData(
    accounts: accounts,
    categories: categories,
    tags: tags,
    transactions: transactions,
    budgets: budgets,
    recurrings: recurrings,
    rateOverrides: rateOverrides,
    ledgerName: data['ledgerName'] as String?,
    currency: data['currency'] as String?,
    monthStartDay: data['monthStartDay'] as int?,
  );
}

/// 解析 JSON 并增量导入
///
/// [repo] - 数据仓库
/// [ledgerId] - 目标账本ID
/// [jsonStr] - JSON 字符串
/// [onProgress] - 进度回调 (已处理数, 总数)
///
/// 返回 (inserted,) 元组：
/// - inserted: 新增条数
Future<({int inserted})> importTransactionsJson(
  BaseRepository repo,
  int ledgerId,
  String jsonStr, {
  void Function(int done, int total)? onProgress,
  bool recordChanges = true,
}) async {
  // 1. 解析 JSON 为统一格式
  final importData = parseJsonToImportData(jsonStr);

  // 2. 使用统一导入服务
  // [recordChanges] 默认 true 兼容 CSV 导入路径(`data_import_service` 会
  // 通过 LocalRepository 写 local_changes 让本地变更能推到云端)。
  // SyncEngine.runFullPull 走"从云端拉数据"路径,显式传 false 避免反向回流。
  final result = await dataImportService.importData(
    repo,
    ledgerId,
    importData,
    defaultCurrency: importData.currency ?? 'CNY',
    onProgress: onProgress,
    recordChanges: recordChanges,
  );

  return (inserted: result.inserted,);
}
