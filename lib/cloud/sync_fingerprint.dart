import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/models/custom_field_values.dart';
import '../services/system/logger_service.dart';

/// 从 transactions JSON payload 计算内容指纹
///
/// 抽取自 `TransactionsSyncManager._contentFingerprintFromMap` 与
/// `_TransactionSerializer._contentFingerprintFromMap`（原两处实现完全一致），
/// 统一维护避免指纹规范化规则漂移。
///
/// 规范化规则：
/// - 标签按字典序排序后拼接，确保顺序无关
/// - 转账交易（type == 'transfer'）忽略 categoryName/categoryKind，
///   避免跨设备分类缺失导致指纹漂移
/// - tagSyncIds（v7）排序后拼接，确保顺序无关
/// - 共享账本 override 字段（v7）纳入指纹：否则两端仅 override 不同时
///   指纹相同 → getStatus 判定 inSync → 永不触发拉取 → override 不同步
/// - 顶层 accounts 数组（account_metadata_sync_fix G4）参与指纹：纯账户
///   变更（新增/修改账户、无交易变化）也要能被状态检测感知，否则误判
///   inSync，用户收不到「云端有更新」提示。账户按 syncId（无则 name）
///   排序后哈希——两端导出顺序依赖查询结果顺序，不排序会对同一份数据
///   产生不同指纹；缺失 accounts 键（旧快照）视为空列表
/// - v8（sync_gap_closure）：categories/tags（全量导出后，未被引用的
///   条目变更也要能触发状态检测，理同 accounts G4）、budgets、recurring、
///   exchangeRateOverrides、monthStartDay 全部参与指纹。recurring 的
///   lastGeneratedDate 刻意排除：它是「本机生成进度」而非数据本体，两端
///   天然不同，纳入会导致指纹永久 different → 每次启动误弹「云端有更新」。
///   注意：快照（transactions_json）里仍会携带 lastGeneratedDate 字段，但
///   那仅用于导入侧 max(local, cloud) 合并保证进度不回退（importRecurrings），
///   不参与指纹 —— 序列化携带与指纹排除并不矛盾。
/// - 排序键优先级：
///   happenedAt → type → amount → categoryName → categoryKind → note
/// - M2：顶层 ledgerName / currency 参与指纹（账本名/本位币变更也要能
///   触发状态检测）。已知取舍：算法变更导致升级后首轮一次性 outOfSync。
///   标签名含逗号的歧义（"a,b" vs 两个标签）刻意不在此处理：快照格式
///   本身以逗号串携带 tags，指纹层无法还原；tagSyncIds（List，无歧义）
///   已参与指纹兜底，两端都有 syncId 时不会碰撞。
///
/// 输入 payload 必须包含 `items` 字段（List<Map>），与 `exportTransactionsJson`
/// 输出结构一致。
String contentFingerprintFromMap(Map<String, dynamic> payload) {
  final items = (payload['items'] as List).cast<Map<String, dynamic>>();
  final canon = items
      .map((it) {
        // 标签：去重并排序后拼接，确保顺序一致并兼容历史脏数据
        final tags = (it['tags'] as String?) ?? '';
        final sortedTags = tags.isNotEmpty
            ? (tags.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toSet().toList()..sort()).join(',')
            : '';
        // v7 标签 syncId 列表：去重并排序后拼接，确保顺序无关
        final tagSyncIds = (it['tagSyncIds'] as List?)?.cast<String>() ?? const [];
        final sortedTagSyncIds = tagSyncIds.toSet().toList()..sort();
        // 账户：区分转账和普通交易
        final accountName = it['accountName'] as String? ?? '';
        final fromAccountName = it['fromAccountName'] as String? ?? '';
        final toAccountName = it['toAccountName'] as String? ?? '';
        // 转账交易不依赖分类，忽略 categoryName/categoryKind 避免跨设备分类缺失导致指纹不一致
        final type = it['type'] as String? ?? '';
        final isTransfer = type == 'transfer';

        // 审计 S11：附件清单参与指纹。只加/删/换附件不改交易内容时，
        // 旧白名单下两端指纹不变 → getStatus 判 inSync → 附件差异
        // 永不传播。规范化为排序后的 (sha256, fileName, sortOrder) 列表；
        // 缺键视为空列表（G2「缺失==显式空」约定，兼容旧快照）。
        // 键优先级对齐快照链口径（L1）：内容寻址锚点 localSha256（'sha256'）
        // 是上传/补齐链路的唯一事实源，优先采用；cloudSha256 只是 Cloud
        // 引擎的引用回填，混排进指纹会让「一端有 Cloud 残留列、另一端
        // 没有」的同一份文件产生不同指纹 → 永久 outOfSync。
        final rawAtts = (it['attachments'] as List?) ?? const [];
        final canonAttachments = rawAtts
            .whereType<Map>()
            .map((a) => [
                  ((a['sha256'] ?? a['cloudSha256']) ?? '') as String,
                  (a['fileName'] ?? '') as String,
                  ((a['sortOrder'] as num?) ?? 0).toString(),
                ].join('|'))
            .toList()
          ..sort();

        return {
          'happenedAt': it['happenedAt'] as String? ?? '',
          'type': type,
          'amount': (it['amount'] as num?)?.toDouble().toString() ?? '0.0',
          // P2-1：以下字段同样参与同步，漏算会导致脏检测漏报
          // （仅修改这些字段时自动同步不触发）
          'nativeAmount':
              (it['nativeAmount'] as num?)?.toDouble().toString() ?? '0.0',
          'currencyCode': it['currencyCode'] as String? ?? '',
          // v45 原始金额：必须进白名单，否则"仅改原始金额"时两端指纹相同
          // → 判 inSync → 该字段永不跨设备传播。缺失键（旧快照/未填写）
          // 规范化为空串，保证「旧快照无此键」与「显式未填写」指纹相同。
          'originalAmount':
              (it['originalAmount'] as num?)?.toDouble().toString() ?? '',
          // v46 自定义字段值：必须进白名单，否则「仅改自定义字段值」时两端
          // 指纹相同 → 判 inSync → 该值永不跨设备传播（同 v45 originalAmount
          // 的教训）。用 codec 的规范化串（键排序 + 数值表示统一），
          // 缺失键/空对象/全空值对象都规范化成空串 —— 「旧快照无此键」与
          // 「显式空」指纹一致，不会产生一轮永久 outOfSync。
          'customValues': CustomFieldValueCodec.canonical(
              (it['customValues'] is Map)
                  ? (it['customValues'] as Map).cast<String, dynamic>()
                  : null),
          'excludeFromStats': it['excludeFromStats'] as bool? ?? false,
          'excludeFromBudget': it['excludeFromBudget'] as bool? ?? false,
          'categoryName':
              isTransfer ? '' : (it['categoryName'] as String? ?? ''),
          'categoryKind':
              isTransfer ? '' : (it['categoryKind'] as String? ?? ''),
          'note': it['note'] as String? ?? '',
          'tags': sortedTags,
          'tagSyncIds': sortedTagSyncIds,
          'categorySyncIdOverride': it['categorySyncIdOverride'] as String? ?? '',
          'accountSyncIdOverride': it['accountSyncIdOverride'] as String? ?? '',
          'toAccountSyncIdOverride': it['toAccountSyncIdOverride'] as String? ?? '',
          'accountName': accountName,
          'fromAccountName': fromAccountName,
          'toAccountName': toAccountName,
          // v8 G2：交易与周期规则的关联也参与指纹（缺失视为空，
          // 保证「旧快照无此字段」与「显式无关联」产生相同指纹）
          'recurringSyncId': it['recurringSyncId'] as String? ?? '',
          // 审计 S11：附件清单指纹（排序后的规范化行，见上方注释）
          'attachments': canonAttachments,
        };
      })
      .toList();
  canon.sort((a, b) {
    final c1 =
        (a['happenedAt'] as String).compareTo(b['happenedAt'] as String);
    if (c1 != 0) return c1;
    final c2 = (a['type'] as String).compareTo(b['type'] as String);
    if (c2 != 0) return c2;
    // P3-1：按数值而非字符串比较金额，避免 '100.0' < '20.0' 的字典序误排
    final c3 = (double.tryParse(a['amount'] as String) ?? 0)
        .compareTo(double.tryParse(b['amount'] as String) ?? 0);
    if (c3 != 0) return c3;
    final c4 =
        (a['categoryName'] as String).compareTo(b['categoryName'] as String);
    if (c4 != 0) return c4;
    final c5 =
        (a['categoryKind'] as String).compareTo(b['categoryKind'] as String);
    if (c5 != 0) return c5;
    final c6 = (a['note'] as String).compareTo(b['note'] as String);
    if (c6 != 0) return c6;
    // 审计修复（指纹全序化）：以上 6 键打平、但其余参与哈希的字段
    // （accountName/tags/tagSyncIds/attachments/override 等）不同的两笔
    // 交易，旧实现的相对顺序随输入顺序漂移 —— 导出端输入按本地自增 id
    // 排序（transactions_json），跨设备 id 序列独立必然不同，同一逻辑
    // 数据两端会算出不同指纹 → 永久 outOfSync/different 循环。
    // 以完整规范化串做末位比较，使排序成为全序：平局项顺序确定、与
    // 输入顺序无关。无平局项的数据指纹不受影响（哈希内容不变）。
    // 已知取舍：算法变更让「存在 6 键平局交易」的存量用户升级后首轮
    // 一次性 outOfSync，同步一轮即收敛（同 M2 迁移先例）。
    return jsonEncode(a).compareTo(jsonEncode(b));
  });
  // 账户元数据规范化（account_metadata_sync_fix G4）：
  // 字段集与 exportTransactionsJson 的账户导出保持一致；缺失键以默认值
  // 兜底，保证「旧快照缺键」与「显式空值」产生相同指纹。
  final accounts = (payload['accounts'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final accountCanon = accounts
      .map((a) => {
            'syncId': a['syncId'] as String? ?? '',
            'name': a['name'] as String? ?? '',
            'type': a['type'] as String? ?? '',
            'currency': a['currency'] as String? ?? '',
            'initialBalance':
                (a['initialBalance'] as num?)?.toDouble().toString() ?? '0.0',
            'creditLimit':
                (a['creditLimit'] as num?)?.toDouble().toString() ?? '',
            'billingDay': (a['billingDay'] as num?)?.toInt().toString() ?? '',
            'paymentDueDay':
                (a['paymentDueDay'] as num?)?.toInt().toString() ?? '',
            'bankName': a['bankName'] as String? ?? '',
            'cardLastFour': a['cardLastFour'] as String? ?? '',
            'note': a['note'] as String? ?? '',
            'hidden': a['hidden'] as bool? ?? false,
            'sortOrder': (a['sortOrder'] as num?)?.toInt().toString() ?? '',
          })
      .toList();
  // 排序键：syncId 优先，缺失时回退 name —— 顺序无关且跨设备稳定。
  // 平局兜底同 items：完整规范化串比较，保证全序（两个同名且无 syncId
  // 的 legacy 账户旧实现会随输入顺序/本地 id 漂移）。
  accountCanon.sort((a, b) {
    final ka = (a['syncId'] as String).isNotEmpty
        ? a['syncId'] as String
        : (a['name'] as String);
    final kb = (b['syncId'] as String).isNotEmpty
        ? b['syncId'] as String
        : (b['name'] as String);
    final c = ka.compareTo(kb);
    if (c != 0) return c;
    return jsonEncode(a).compareTo(jsonEncode(b));
  });

  // ---- v8（sync_gap_closure）：全量分类/标签 + 预算/周期/汇率覆盖 ----
  // 理同 accounts G4：这些实体进了快照就必须进指纹，否则「仅这些数据
  // 变化」时两端判 inSync，新增的预算/规则/分类永远不被拉取。
  // 所有数组按稳定键排序（syncId 优先，业务键兜底）后序列化。

  // 通用兜底排序键：syncId 非空用 syncId，否则用 name / 业务键。
  // 平局时以完整规范化串定序（全序保证，理由同 items 的末位比较）：
  // 同名无 syncId 的分类/标签、以及无 syncId 的周期规则（recurring
  // 规范化 map 无 name 键，旧实现全部平局）此前都随输入顺序漂移。
  int compareBySyncIdOrName(Map<String, dynamic> a, Map<String, dynamic> b) {
    final ka = ((a['syncId'] as String?) ?? '').isNotEmpty
        ? a['syncId'] as String
        : ((a['name'] as String?) ?? '');
    final kb = ((b['syncId'] as String?) ?? '').isNotEmpty
        ? b['syncId'] as String
        : ((b['name'] as String?) ?? '');
    final c = ka.compareTo(kb);
    if (c != 0) return c;
    return jsonEncode(a).compareTo(jsonEncode(b));
  }

  final categories = (payload['categories'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final categoryCanon = categories
      .map((c) => {
            'syncId': c['syncId'] as String? ?? '',
            'name': c['name'] as String? ?? '',
            'kind': c['kind'] as String? ?? '',
            'level': (c['level'] as num?)?.toInt() ?? 1,
            'parentName': c['parentName'] as String? ?? '',
            'sortOrder': (c['sortOrder'] as num?)?.toInt() ?? 0,
            'iconType': c['iconType'] as String? ?? '',
            'icon': c['icon'] as String? ?? '',
            'customIconPath': c['customIconPath'] as String? ?? '',
            'communityIconId': c['communityIconId'] as String? ?? '',
          })
      .toList()
    ..sort(compareBySyncIdOrName);

  final tags = (payload['tags'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final tagCanon = tags
      .map((t) => {
            'syncId': t['syncId'] as String? ?? '',
            'name': t['name'] as String? ?? '',
            'color': t['color'] as String? ?? '',
            'sortOrder': (t['sortOrder'] as num?)?.toInt() ?? 0,
          })
      .toList()
    ..sort(compareBySyncIdOrName);

  final customFields = (payload['customFields'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final customFieldCanon = customFields
      .map((f) => {
            'syncId': f['syncId'] as String? ?? '',
            'name': f['name'] as String? ?? '',
            'fieldType': f['fieldType'] as String? ?? '',
            'sortOrder': (f['sortOrder'] as num?)?.toInt() ?? 0,
          })
      .toList()
    ..sort(compareBySyncIdOrName);

  final budgets = (payload['budgets'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final budgetCanon = budgets
      .map((b) => {
            'syncId': b['syncId'] as String? ?? '',
            'type': b['type'] as String? ?? '',
            'categoryName': b['categoryName'] as String? ?? '',
            'amount': (b['amount'] as num?)?.toDouble().toString() ?? '0.0',
            'period': b['period'] as String? ?? '',
            'startDay': (b['startDay'] as num?)?.toInt() ?? 1,
            'enabled': b['enabled'] as bool? ?? true,
          })
      .toList()
    // 预算排序键：syncId 优先，业务键兜底（旧快照无 syncId 的行）。
    // 平局兜底：完整规范化串（同 type/category/period 但金额不同的
    // 无 syncId 预算，旧实现顺序随输入漂移）。
    ..sort((a, b) {
      final ka = ((a['syncId'] as String?) ?? '').isNotEmpty
          ? a['syncId'] as String
          : '${a['type']}|${a['categoryName']}|${a['period']}';
      final kb = ((b['syncId'] as String?) ?? '').isNotEmpty
          ? b['syncId'] as String
          : '${b['type']}|${b['categoryName']}|${b['period']}';
      final c = ka.compareTo(kb);
      if (c != 0) return c;
      return jsonEncode(a).compareTo(jsonEncode(b));
    });

  final recurrings = (payload['recurring'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final recurringCanon = recurrings
      .map((r) => {
            'syncId': r['syncId'] as String? ?? '',
            'type': r['type'] as String? ?? '',
            'amount': (r['amount'] as num?)?.toDouble().toString() ?? '0.0',
            'categoryName': r['categoryName'] as String? ?? '',
            'accountName': r['accountName'] as String? ?? '',
            'accountSyncId': r['accountSyncId'] as String? ?? '',
            'toAccountName': r['toAccountName'] as String? ?? '',
            'toAccountSyncId': r['toAccountSyncId'] as String? ?? '',
            'note': r['note'] as String? ?? '',
            'frequency': r['frequency'] as String? ?? '',
            'interval': (r['interval'] as num?)?.toInt() ?? 1,
            'dayOfMonth': (r['dayOfMonth'] as num?)?.toInt().toString() ?? '',
            'dayOfWeek': (r['dayOfWeek'] as num?)?.toInt().toString() ?? '',
            'monthOfYear':
                (r['monthOfYear'] as num?)?.toInt().toString() ?? '',
            'startDate': r['startDate'] as String? ?? '',
            'endDate': r['endDate'] as String? ?? '',
            'enabled': r['enabled'] as bool? ?? true,
            // v47 模板级自定义字段值:必须经 canonical(键序/数值表示统一)。
            // 缺键与空对象在 canonical 下都是 ''——导出侧仅非空写键,两侧
            // 「未配置」指纹恒等,不会假冲突。
            'templateFieldValues': CustomFieldValueCodec.canonical(
                (r['templateFieldValues'] is Map)
                    ? (r['templateFieldValues'] as Map)
                        .cast<String, dynamic>()
                    : null),
            // lastGeneratedDate 刻意排除（本机生成进度，见函数头注释）
          })
      .toList()
    ..sort(compareBySyncIdOrName);

  final rateOverrides = (payload['exchangeRateOverrides'] as List?)
          ?.cast<Map<String, dynamic>>() ??
      const <Map<String, dynamic>>[];
  final rateOverrideCanon = rateOverrides
      .map((o) => {
            'baseCurrency': o['baseCurrency'] as String? ?? '',
            'quoteCurrency': o['quoteCurrency'] as String? ?? '',
            'rate': (o['rate'] is num
                    ? o['rate'] as num
                    : num.tryParse(o['rate']?.toString() ?? '') ?? 0.0)
                .toDouble()
                .toString(),
          })
      .toList()
    // 业务键 (base, quote) 理论唯一；平局兜底仍加全序比较，防脏数据
    // （同币种对多行）时顺序漂移
    ..sort((a, b) {
      final c = '${a['baseCurrency']}/${a['quoteCurrency']}'
          .compareTo('${b['baseCurrency']}/${b['quoteCurrency']}');
      if (c != 0) return c;
      return jsonEncode(a).compareTo(jsonEncode(b));
    });

  final bytes = utf8.encode(jsonEncode({
    'items': canon,
    'accounts': accountCanon,
    'categories': categoryCanon,
    'tags': tagCanon,
    'customFields': customFieldCanon,
    'budgets': budgetCanon,
    'recurring': recurringCanon,
    'exchangeRateOverrides': rateOverrideCanon,
    'monthStartDay': (payload['monthStartDay'] as num?)?.toInt() ?? 1,
    // M2：账本名与本位币参与指纹。两者随快照传播、导入侧支持回写，
    // 但旧白名单不含它们 → A 设备改名/改币种上传后，B 端 localFp ==
    // cloudFp 恒判 inSync，永不拉取 —— 币种变更直接影响金额解读，
    // 属高危元数据不同步。两个导出器（transactions_json v8 / 引擎
    // _exportLedgerJson）顶层都携带这两个键，缺失视为空串兼容旧快照。
    //
    // 注意指纹算法变更的迁移语义：升级后首轮 getStatus 必然本地新算法
    // vs 云端旧元数据 → 一次性 outOfSync，用户同步一轮即收敛。
    'ledgerName': payload['ledgerName'] as String? ?? '',
    'currency': payload['currency'] as String? ?? '',
  }));
  final fp = sha256.convert(bytes).toString();
  logger.debug('Fingerprint',
      '交易数: ${canon.length}, 账户数: ${accountCanon.length}, 分类数: ${categoryCanon.length}, '
      '标签数: ${tagCanon.length}, 自定义字段数: ${customFieldCanon.length}, '
      '预算数: ${budgetCanon.length}, 周期规则数: ${recurringCanon.length}, '
      '汇率覆盖数: ${rateOverrideCanon.length}, 指纹: ${fp.substring(0, 16)}...');
  return fp;
}
