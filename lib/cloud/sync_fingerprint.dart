import 'dart:convert';

import 'package:crypto/crypto.dart';

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
/// - 排序键优先级：
///   happenedAt → type → amount → categoryName → categoryKind → note
///
/// 输入 payload 必须包含 `items` 字段（List<Map>），与 `exportTransactionsJson`
/// 输出结构一致。
String contentFingerprintFromMap(Map<String, dynamic> payload) {
  final items = (payload['items'] as List).cast<Map<String, dynamic>>();
  final canon = items
      .map((it) {
        // 标签：排序后拼接，确保顺序一致
        final tags = (it['tags'] as String?) ?? '';
        final sortedTags = tags.isNotEmpty
            ? (tags.split(',')..sort()).join(',')
            : '';
        // v7 标签 syncId 列表：排序后拼接，确保顺序无关
        final tagSyncIds = (it['tagSyncIds'] as List?)?.cast<String>() ?? const [];
        final sortedTagSyncIds = List<String>.from(tagSyncIds)..sort();
        // 账户：区分转账和普通交易
        final accountName = it['accountName'] as String? ?? '';
        final fromAccountName = it['fromAccountName'] as String? ?? '';
        final toAccountName = it['toAccountName'] as String? ?? '';
        // 转账交易不依赖分类，忽略 categoryName/categoryKind 避免跨设备分类缺失导致指纹不一致
        final type = it['type'] as String? ?? '';
        final isTransfer = type == 'transfer';

        return {
          'happenedAt': it['happenedAt'] as String? ?? '',
          'type': type,
          'amount': (it['amount'] as num?)?.toDouble().toString() ?? '0.0',
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
        };
      })
      .toList();
  canon.sort((a, b) {
    final c1 =
        (a['happenedAt'] as String).compareTo(b['happenedAt'] as String);
    if (c1 != 0) return c1;
    final c2 = (a['type'] as String).compareTo(b['type'] as String);
    if (c2 != 0) return c2;
    final c3 = (a['amount'] as String).compareTo(b['amount'] as String);
    if (c3 != 0) return c3;
    final c4 =
        (a['categoryName'] as String).compareTo(b['categoryName'] as String);
    if (c4 != 0) return c4;
    final c5 =
        (a['categoryKind'] as String).compareTo(b['categoryKind'] as String);
    if (c5 != 0) return c5;
    return (a['note'] as String).compareTo(b['note'] as String);
  });
  final bytes = utf8.encode(jsonEncode(canon));
  final fp = sha256.convert(bytes).toString();
  logger.debug(
      'Fingerprint', '交易数: ${canon.length}, 指纹: ${fp.substring(0, 16)}...');
  return fp;
}
