import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../data/db.dart';
import '../data/models/custom_field_values.dart';
import 'database_providers.dart';
import 'theme_providers.dart';

/// 自定义字段定义列表刷新触发器。
///
/// 增删改字段 / 拖拽排序后 bump，让 Future 类 provider 重新取数
/// （Stream 类 provider 由 Drift 表更新自动驱动，不依赖它）。
final customFieldListRefreshProvider = StateProvider<int>((ref) => 0);

/// 指定账本的自定义字段定义流（管理页用）。
final customFieldDefinitionsProvider =
    StreamProvider.family<List<CustomFieldDefinition>, int>((ref, ledgerId) {
  ref.watch(customFieldListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.watchDefinitionsForLedger(ledgerId);
});

/// 指定账本的自定义字段定义（表单页一次性取用，周期账单模板编辑器用）。
///
/// 与 [customFieldsForCurrentLedgerProvider] 同款取舍：编辑表单是短暂弹出
/// 的页面，一次取够即可；Drift 的 `watch()` 流会在组件测试里留下 pending
/// Timer（stream query 调度器），表单页不该背这个成本。定义变更同样通过
/// [customFieldListRefreshProvider] 显式失效。
final customFieldDefinitionsOnceProvider =
    FutureProvider.family<List<CustomFieldDefinition>, int>((ref, ledgerId) {
  ref.watch(customFieldListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.getDefinitionsForLedger(ledgerId);
});

/// 当前账本的自定义字段定义（交易编辑器录入分区用）。
///
/// 用 Future 而非 Stream：编辑器是短暂弹出的表单，一次取够即可；定义变更
/// 通过 [customFieldListRefreshProvider] 显式失效。
final customFieldsForCurrentLedgerProvider =
    FutureProvider<List<CustomFieldDefinition>>((ref) async {
  ref.watch(customFieldListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  final ledgerId = ref.watch(currentLedgerIdProvider);
  return repo.getDefinitionsForLedger(ledgerId);
});

/// 某笔交易已存的自定义字段值（编辑回显用）。无值 → 空 map。
final transactionCustomValuesProvider =
    FutureProvider.family<Map<String, dynamic>, int>((ref, transactionId) async {
  ref.watch(customFieldListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.getValuesForTransaction(transactionId);
});

/// 该账本已填自定义字段值的交易条数（删字段前提示影响面）。
final customFieldFilledCountProvider =
    FutureProvider.family<int, int>((ref, ledgerId) async {
  ref.watch(customFieldListRefreshProvider);
  final repo = ref.watch(repositoryProvider);
  return repo.countTransactionsWithValues(ledgerId);
});

/// B1(v47):当前账本的明细行自定义字段角标 —— txId → [(字段名, 展示文本)]。
///
/// 值流 watch `transactions` 表里 `custom_values_json` 非空的行:任何交易
/// 更新都会重发,角标跟数据实时走,不依赖 refresh 触发器。字段名按定义
/// syncId 反查并按定义排序输出;定义已删的键跳过(deleteDefinition 会清值,
/// 这里只防云端在途的幽灵键)。「全部账本」模式下其它账本的值天然解析不出
/// 名称 → 不显示,属预期。日期值按 fieldType 转本地化 yMd 文本;填了时分秒
/// 且「显示交易时间」开启时连时间一并显示(与明细行时间口径一致)。
final customFieldValueBadgesProvider = StreamProvider<Map<int,
        List<({String name, String display})>>>((ref) {
  final db = ref.watch(databaseProvider);
  final ledgerId = ref.watch(currentLedgerIdProvider);
  final repo = ref.watch(repositoryProvider);
  final valuesStream = (db.select(db.transactions)
        ..where((t) =>
            t.ledgerId.equals(ledgerId) & t.customValuesJson.isNotNull()))
      .watch();
  // P7：decode 结果按 customValuesJson 串缓存 —— 交易表任何写操作都会
  // 重发全量行，此前每行每次重发都 jsonDecode 一遍；键是取值内容串，
  // 容量以「不同取值组合数」为界。decode 产物下方只读，可安全共享。
  final decodeCache = <String, Map<String, dynamic>>{};
  // P7：DateFormat 构造提出每值循环。
  final yMd = DateFormat.yMd();
  final yMdHms = DateFormat.yMd().add_Hms();
  final showTime = ref.watch(showTransactionTimeProvider);
  return valuesStream.asyncMap((rows) async {
    final defs = await repo.getDefinitionsForLedger(ledgerId);
    final out =
        <int, List<({String name, String display})>>{};
    for (final tx in rows) {
      final json = tx.customValuesJson;
      if (json == null) continue;
      final values = decodeCache.putIfAbsent(
          json, () => CustomFieldValueCodec.decode(json));
      if (values.isEmpty) continue;
      final badges = <({String name, String display})>[];
      for (final d in defs) {
        final sid = d.syncId;
        if (sid == null || sid.isEmpty || !values.containsKey(sid)) continue;
        String? display = CustomFieldValueCodec.toDisplayString(values[sid]);
        if (display == null) continue;
        if (d.fieldType == CustomFieldType.date) {
          final parsed = DateTime.tryParse(display);
          if (parsed != null) {
            // 零点值只出日期（旧数据与「只选日期」的存法），非零点且开关
            // 开着才连时分秒一起出 —— 与明细行自己的时间列同一判定。
            final withTime = showTime &&
                (parsed.hour != 0 || parsed.minute != 0 || parsed.second != 0);
            display = (withTime ? yMdHms : yMd).format(parsed);
          }
        }
        badges.add((name: d.name, display: display));
      }
      if (badges.isNotEmpty) out[tx.id] = badges;
    }
    return out;
  });
});
