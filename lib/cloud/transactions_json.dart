import 'dart:convert';
import '../data/db.dart';
import '../data/repositories/base_repository.dart';
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';
import 'sync_fingerprint.dart';

/// 账本交易数据的 JSON 导入导出工具
///
/// 用于云同步时序列化和反序列化交易数据

// --- 字符串清理 ---

/// 清理字符串中的控制字符，防止 JSON 解析错误
String _sanitizeString(String? input) {
  if (input == null) return '';
  // 移除危险控制字符（ASCII 0-31 中除 \t \n \r 外的不可见字符与 DEL），
  // 防止 JSON 结构被破坏。
  //
  // 审计 S13：旧实现额外把 \n/\r/\t 替换成空格——多行备注在每次快照
  // 上传时被压平成单行，恢复到对端后换行永久丢失。控制字符正则本身
  // 已跳过这三个空白符（JSON 可安全承载），故删除压平逻辑；
  // name/tag 等短字段本就不该含换行，行为不受影响。
  return input
      .replaceAll(RegExp(r'[\x00-\x08\x0B-\x0C\x0E-\x1F\x7F]'), '')
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
  // M2：一次全量查询建 categoryId → {name, kind} 映射，替代旧实现的
  // 逐 categoryId 单查（N+1）；allCategoriesList 同时供下方 categories
  // 数组全量导出复用，不再二次查询。
  final allCategoriesList = await db.select(db.categories).get();
  final cats = <int, Map<String, dynamic>>{
    for (final c in allCategoriesList)
      c.id: {"name": _sanitizeString(c.name), "kind": c.kind},
  };

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
  // M2：allCategoriesList 已在上方一次查询，此处直接复用（原二次查询删除）
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
      // lastGeneratedDate 语义说明（与 sync_fingerprint 排除规则对齐）：
      // 它是「本机生成进度」而非数据本体，两端的值天然不同，故指纹计算时
      // 刻意排除（否则永久 different、每次启动误弹「云端有更新」）。快照里
      // 仍携带它，仅用于恢复侧 importRecurrings 以 max(local, cloud) 合并，
      // 防止旧快照回退进度 → 生成器重放历史交易。
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
    // v9: ledgerSyncId —— 账本跨设备身份随快照传播（恢复端回填
    // ledgers.sync_id，见 restoreLedgerFromJson）。不参与内容指纹：
    // 身份字段进指纹会让「回填前后的同一份数据」产生不同指纹，
    // 造成一轮永久 different。历史版本：v8 预算/周期/汇率覆盖 +
    // 全量分类/标签 + recurringSyncId。
    'version': 9,
    'exportedAt': DateTime.now().toUtc().toIso8601String(),
    'ledgerId': ledgerId,
    'ledgerName': ledger.name,
    'currency': ledger.currency,
    if (ledger.syncId != null && ledger.syncId!.isNotEmpty)
      'ledgerSyncId': ledger.syncId,
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

  // 审计 TSM-P3：指纹自描述 —— 把内容指纹写进快照本体。
  // contentFingerprintFromMap 是白名单式规范化（只读已知键），嵌入值不会
  // 反馈进哈希，无循环依赖；旧快照缺此键时读取端回退外部元数据，完全向后
  // 兼容。收益：WebDAV sidecar 丢失 / S3 元数据头被网关剥离时，冲突检测
  // 与完整性校验仍可从下载内容本身取到权威指纹，不再退化成 unknown 冲突循环。
  payload['contentFingerprint'] = contentFingerprintFromMap(payload);

  logger.debug('TransactionsJson', '导出完成: ${items.length} 条交易, ${categoryItems.length} 个分类');
  return jsonEncode(payload);
}

// --- 导入 ---

// ===== H1 安全读取助手：字段类型不符返回 null，由调用方决定跳过 =====
// 为什么不用硬 cast：远端/损坏 JSON 任一字段类型不符即抛 CastError，
// 会让整账本导入中断；改为「必填字段校验失败 → 跳过该条目并计数」，
// 保证单条脏数据不拖垮整个快照恢复。
String? _readString(Map<String, dynamic> m, String key) =>
    m[key] is String ? m[key] as String : null;

int? _readInt(Map<String, dynamic> m, String key) =>
    m[key] is int ? m[key] as int : (m[key] is num ? (m[key] as num).toInt() : null);

double? _readDouble(Map<String, dynamic> m, String key) =>
    m[key] is num ? (m[key] as num).toDouble() : null;

bool? _readBool(Map<String, dynamic> m, String key) =>
    m[key] is bool ? m[key] as bool : null;

DateTime? _readDate(Map<String, dynamic> m, String key) =>
    m[key] is String ? DateTime.tryParse(m[key] as String) : null;

void _skip(Map<String, int> skipped, String section) =>
    skipped[section] = (skipped[section] ?? 0) + 1;

// 必须与 app 支持的一级交易类型完全对齐：adjustment（估值调整）是资产账户
// 估值变动的合法业务类型，早期漏登记导致 S3 快照恢复时被当作非法类型静默丢弃
// （云端有、恢复后没有 → 真实数据丢失）。新增交易类型时务必同步这里。
const _kValidTxTypes = {'expense', 'income', 'transfer', 'adjustment'};

/// 将 JSON 数据转换为统一的 ImportData 格式
ImportData parseJsonToImportData(String jsonStr) {
  final decoded = jsonDecode(jsonStr);
  // H1：顶层不是 JSON 对象（如数组/字符串）属于快照整体损坏，
  // 无法逐条降级，抛可读异常由上层走「拒绝恢复」分支。
  if (decoded is! Map) {
    throw const FormatException('快照格式损坏：顶层不是 JSON 对象');
  }
  final data = decoded.cast<String, dynamic>();
  final skipped = <String, int>{};

  // 解析账户（H1：name 必填，损坏条目跳过并计数）
  final accounts = <ImportAccount>[];
  final jsonAccounts = data['accounts'] as List?;
  if (jsonAccounts != null) {
    for (final acc in jsonAccounts) {
      if (acc is! Map) {
        _skip(skipped, 'accounts');
        continue;
      }
      final m = acc.cast<String, dynamic>();
      final name = _readString(m, 'name');
      if (name == null) {
        _skip(skipped, 'accounts');
        continue;
      }
      accounts.add(ImportAccount(
        name: name,
        type: _readString(m, 'type'),
        currency: _readString(m, 'currency'),
        initialBalance: _readDouble(m, 'initialBalance'),
        sortOrder: _readInt(m, 'sortOrder'),
        creditLimit: _readDouble(m, 'creditLimit'),
        billingDay: _readInt(m, 'billingDay'),
        paymentDueDay: _readInt(m, 'paymentDueDay'),
        bankName: _readString(m, 'bankName'),
        cardLastFour: _readString(m, 'cardLastFour'),
        note: _readString(m, 'note'),
        hidden: _readBool(m, 'hidden'),
        syncId: _readString(m, 'syncId'),
      ));
    }
  }

  // 解析分类（H1：name/kind 必填）
  final categories = <ImportCategory>[];
  final jsonCategories = data['categories'] as List?;
  if (jsonCategories != null) {
    for (final cat in jsonCategories) {
      if (cat is! Map) {
        _skip(skipped, 'categories');
        continue;
      }
      final m = cat.cast<String, dynamic>();
      final name = _readString(m, 'name');
      final kind = _readString(m, 'kind');
      if (name == null || kind == null) {
        _skip(skipped, 'categories');
        continue;
      }
      categories.add(ImportCategory(
        name: name,
        kind: kind,
        level: _readInt(m, 'level') ?? 1,
        sortOrder: _readInt(m, 'sortOrder') ?? 0,
        icon: _readString(m, 'icon'),
        parentName: _readString(m, 'parentName'),
        iconType: _readString(m, 'iconType'),
        customIconPath: _readString(m, 'customIconPath'),
        communityIconId: _readString(m, 'communityIconId'),
        syncId: _readString(m, 'syncId'),
      ));
    }
  }

  // 解析预算（v8 G1；旧快照无此数组 → 空列表，导入跳过不删本地）
  // H1：保留原有默认值逻辑，仅当字段「存在但类型错误」时跳过该条。
  final budgets = <ImportBudget>[];
  final jsonBudgets = data['budgets'] as List?;
  if (jsonBudgets != null) {
    for (final b in jsonBudgets) {
      if (b is! Map) {
        _skip(skipped, 'budgets');
        continue;
      }
      try {
        final m = b.cast<String, dynamic>();
        budgets.add(ImportBudget(
          syncId: m['syncId'] as String?,
          type: m['type'] as String? ?? 'total',
          categoryName: m['categoryName'] as String?,
          amount: (m['amount'] as num?)?.toDouble() ?? 0,
          period: m['period'] as String? ?? 'monthly',
          startDay: m['startDay'] as int? ?? 1,
          enabled: m['enabled'] as bool? ?? true,
        ));
      } catch (e) {
        // F7: 保留异常细节便于诊断损坏快照。budget 行解析失败仍跳过(单条
        // 损坏不拖垮整账本恢复),但不再静默丢弃异常对象。
        logger.debug('TransactionsJson', 'budget 解析失败,跳过: $e');
        _skip(skipped, 'budgets');
      }
    }
  }

  // 解析周期规则（v8 G2；旧快照无此数组 → 空列表）
  // H1：type/amount/frequency/startDate 为必填，缺失或类型不符跳过。
  // M13：兼容旧 SyncEngine 导出器的段键 'recurrings'（官方为 'recurring'），
  // 已上传的旧快照无需重传即可解析。
  final recurrings = <ImportRecurring>[];
  final jsonRecurrings =
      (data['recurring'] ?? data['recurrings']) as List?;
  if (jsonRecurrings != null) {
    for (final r in jsonRecurrings) {
      if (r is! Map) {
        _skip(skipped, 'recurring');
        continue;
      }
      final m = r.cast<String, dynamic>();
      final type = _readString(m, 'type');
      final amount = _readDouble(m, 'amount');
      final frequency = _readString(m, 'frequency');
      final startDate = _readDate(m, 'startDate');
      if (type == null || amount == null || frequency == null ||
          startDate == null) {
        _skip(skipped, 'recurring');
        continue;
      }
      recurrings.add(ImportRecurring(
        syncId: _readString(m, 'syncId'),
        type: type,
        amount: amount,
        categoryName: _readString(m, 'categoryName'),
        accountName: _readString(m, 'accountName'),
        accountSyncId: _readString(m, 'accountSyncId'),
        toAccountName: _readString(m, 'toAccountName'),
        toAccountSyncId: _readString(m, 'toAccountSyncId'),
        note: _readString(m, 'note'),
        frequency: frequency,
        interval: _readInt(m, 'interval') ?? 1,
        dayOfMonth: _readInt(m, 'dayOfMonth'),
        dayOfWeek: _readInt(m, 'dayOfWeek'),
        monthOfYear: _readInt(m, 'monthOfYear'),
        startDate: startDate,
        endDate: _readDate(m, 'endDate'),
        lastGeneratedDate: _readDate(m, 'lastGeneratedDate'),
        enabled: _readBool(m, 'enabled') ?? true,
      ));
    }
  }

  // 解析手动汇率覆盖（v8 G4）
  // M13：兼容旧 SyncEngine 导出器的段键 'rateOverrides'（官方为
  // 'exchangeRateOverrides'）。
  final rateOverrides = <ImportRateOverride>[];
  final jsonRateOverrides =
      (data['exchangeRateOverrides'] ?? data['rateOverrides']) as List?;
  if (jsonRateOverrides != null) {
    for (final o in jsonRateOverrides) {
      if (o is! Map) {
        _skip(skipped, 'rateOverrides');
        continue;
      }
      final m = o.cast<String, dynamic>();
      final base = _readString(m, 'baseCurrency');
      final quote = _readString(m, 'quoteCurrency');
      // exchangeRateOverrides.rate 是 TEXT 列，JSON 中以字符串形式序列化，
      // 需兼容 String 与 num 两种形态。
      final rate = (m['rate'] is num
              ? m['rate'] as num
              : num.tryParse(m['rate']?.toString() ?? ''))
          ?.toDouble();
      if (base == null || quote == null || rate == null || rate <= 0) {
        _skip(skipped, 'rateOverrides');
        continue;
      }
      rateOverrides.add(ImportRateOverride(
        baseCurrency: base,
        quoteCurrency: quote,
        rate: rate,
        // 审计 TBL-M3：回传快照身份锚点（v9 快照导出端已写入），
        // 恢复端据此回写本地行，不再重建新 UUID 撕裂跨设备映射
        syncId: _readString(m, 'syncId'),
      ));
    }
  }

  // 解析标签（H1：name 必填）
  final tags = <ImportTag>[];
  final jsonTags = data['tags'] as List?;
  if (jsonTags != null) {
    for (final tag in jsonTags) {
      if (tag is! Map) {
        _skip(skipped, 'tags');
        continue;
      }
      final m = tag.cast<String, dynamic>();
      final name = _readString(m, 'name');
      if (name == null) {
        _skip(skipped, 'tags');
        continue;
      }
      tags.add(ImportTag(
        name: name,
        color: m['color']?.toString(),
        syncId: _readString(m, 'syncId'),
        sortOrder: _readInt(m, 'sortOrder'),
      ));
    }
  }

  // 解析交易（H1：type 白名单/amount/happenedAt 必填；
  // 附件子条目缺 fileName 跳过该附件）
  final transactions = <ImportTransaction>[];
  final jsonItems = data['items'] as List?;
  if (jsonItems != null) {
    for (final it in jsonItems) {
      if (it is! Map) {
        _skip(skipped, 'transactions');
        continue;
      }
      final m = it.cast<String, dynamic>();
      final type = _readString(m, 'type');
      final amount = _readDouble(m, 'amount');
      final happenedAt = _readDate(m, 'happenedAt');
      if (type == null || !_kValidTxTypes.contains(type) ||
          amount == null || happenedAt == null) {
        _skip(skipped, 'transactions');
        continue;
      }

      // 解析标签名称列表
      List<String>? tagNames;
      final tagsStr = _readString(m, 'tags');
      if (tagsStr != null && tagsStr.trim().isNotEmpty) {
        tagNames = tagsStr.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
      }

      // 解析附件元数据（H1：损坏附件跳过，不影响所属交易）
      List<ImportAttachment>? attachments;
      final jsonAttachments = m['attachments'];
      if (jsonAttachments is List && jsonAttachments.isNotEmpty) {
        final validAttachments = <ImportAttachment>[];
        for (final a in jsonAttachments) {
          if (a is! Map) {
            _skip(skipped, 'attachments');
            continue;
          }
          final am = a.cast<String, dynamic>();
          final fileName = _readString(am, 'fileName');
          if (fileName == null) {
            _skip(skipped, 'attachments');
            continue;
          }
          validAttachments.add(ImportAttachment(
            fileName: fileName,
            originalName: _readString(am, 'originalName'),
            fileSize: _readInt(am, 'fileSize'),
            width: _readInt(am, 'width'),
            height: _readInt(am, 'height'),
            sortOrder: _readInt(am, 'sortOrder') ?? 0,
            cloudFileId: _readString(am, 'cloudFileId'),
            cloudSha256: _readString(am, 'cloudSha256'),
            sha256: _readString(am, 'sha256'),
          ));
        }
        if (validAttachments.isNotEmpty) attachments = validAttachments;
      }

      // 解析标签 syncId 列表
      List<String>? tagSyncIds;
      final rawTagSyncIds = m['tagSyncIds'];
      if (rawTagSyncIds is List && rawTagSyncIds.isNotEmpty) {
        tagSyncIds = rawTagSyncIds.whereType<String>().toList();
      }
      transactions.add(ImportTransaction(
        type: type,
        amount: amount,
        categoryName: _readString(m, 'categoryName'),
        categoryKind: _readString(m, 'categoryKind'),
        happenedAt: happenedAt.toLocal(),
        note: _readString(m, 'note'),
        // 账户信息：转账用 fromAccountName/toAccountName，其他用 accountName
        accountName: type != 'transfer' ? _readString(m, 'accountName') : null,
        fromAccountName: type == 'transfer' ? _readString(m, 'fromAccountName') : null,
        toAccountName: type == 'transfer' ? _readString(m, 'toAccountName') : null,
        tagNames: tagNames,
        tagSyncIds: tagSyncIds,
        attachments: attachments,
        syncId: _readString(m, 'syncId'),
        // 账单标记 + v30 多币种
        excludeFromStats: _readBool(m, 'excludeFromStats') ?? false,
        excludeFromBudget: _readBool(m, 'excludeFromBudget') ?? false,
        currencyCode: _readString(m, 'currencyCode'),
        nativeAmount: _readDouble(m, 'nativeAmount'),
        // 共享账本 override
        categorySyncIdOverride: _readString(m, 'categorySyncIdOverride'),
        accountSyncIdOverride: _readString(m, 'accountSyncIdOverride'),
        toAccountSyncIdOverride: _readString(m, 'toAccountSyncIdOverride'),
        // v8 G2：周期规则锚点
        recurringSyncId: _readString(m, 'recurringSyncId'),
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
    ledgerName: _readString(data, 'ledgerName'),
    currency: _readString(data, 'currency'),
    monthStartDay: _readInt(data, 'monthStartDay'),
    // v9：账本身份锚点。旧快照（v8-）无此键 → null，恢复端保持现状。
    ledgerSyncId: _readString(data, 'ledgerSyncId'),
    version: _readInt(data, 'version'),
    skippedItems: skipped,
  );
}

/// 解析 JSON 并增量导入
///
/// [repo] - 数据仓库
/// [ledgerId] - 目标账本ID
/// [jsonStr] - JSON 字符串
/// [onProgress] - 进度回调 (已处理数, 总数)
///
/// 返回 (inserted, skippedRecurring) 元组：
/// - inserted: 新增条数
/// - skippedRecurring: 恢复侧周期实例去重跳过条数（REC-05：
///   同规则同日且 syncId 或金额+备注相同才算真重复）
Future<({int inserted, int skippedRecurring})> importTransactionsJson(
  BaseRepository repo,
  int ledgerId,
  String jsonStr, {
  void Function(int done, int total)? onProgress,
  bool recordChanges = true,
}) async {
  // 1. 解析 JSON 为统一格式
  final importData = parseJsonToImportData(jsonStr);
  // H1：损坏条目已在解析层跳过，这里仅记录日志供排查，
  // 不中断导入（单条脏数据不应拖垮整账本恢复）。
  if (importData.skippedItems.isNotEmpty) {
    logger.warning('TransactionsJson',
        '快照解析跳过损坏条目（不影响其余数据）: ${importData.skippedItems}');
  }

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

  return (inserted: result.inserted, skippedRecurring: result.skippedRecurring);
}
