import '../../data/db.dart' as db;

/// 交易列表条目（与 transaction_list.dart 的列表元素同构）。
typedef GroupedTransaction = ({
  db.Transaction t,
  db.Category? category,
  db.Account? account,
  db.Account? toAccount,
});

/// 按天分组交易列表（P1-C 增量分组核心）。
///
/// 职责：维护「tx id → 日 key」「tx id → 上次条目」两张索引与日分组结果，
/// 提供 [fullRebuild]（首次/回退全量）与 [applyDiff]（增量 diff）两条路径。
/// 纯逻辑无 widget 依赖，diff 算法直接单测（见
/// test/widgets/transaction_day_grouper_test.dart）。
///
/// 值相等依据：Drift 为 Transaction/Category/Account 生成全字段 `==`，
/// record `==` 为字段结构相等 —— 账户/分类改名导致的 JOIN 重发能正确判为
/// 变更并重建对应日；等值的重复 emit 判为无变化。
class TransactionDayGrouper {
  /// 日 key（'yyyy-MM-dd'）→ 当日条目（保持输入列表顺序）。
  final Map<String, List<GroupedTransaction>> dayGroups = {};

  /// 日 key 降序（最新在前）。'yyyy-MM-dd' 字典序 == 时间序。
  final List<String> sortedDayKeys = [];

  final Map<int, String> _idDayKey = {};
  final Map<int, GroupedTransaction> _idItem = {};

  /// 日 key：与 `DateFormat('yyyy-MM-dd').format(DateTime(y,m,d))` 产出
  /// 严格一致（jumpToMonth 的 split('-') 解析、VisibilityDetector key 依赖
  /// 该格式）。手工构建替代 DateFormat，消除 ICU 格式化开销。
  static String dayKeyOf(GroupedTransaction item) {
    final dt = item.t.happenedAt.toLocal();
    return '${dt.year.toString().padLeft(4, '0')}-'
        '${dt.month.toString().padLeft(2, '0')}-'
        '${dt.day.toString().padLeft(2, '0')}';
  }

  /// 全量重算并 seed 索引（首次构建 / 平铺模式回退路径）。
  void fullRebuild(List<GroupedTransaction> items) {
    dayGroups.clear();
    sortedDayKeys.clear();
    _idDayKey.clear();
    _idItem.clear();
    for (final item in items) {
      final key = dayKeyOf(item);
      dayGroups.putIfAbsent(key, () => []).add(item);
      _idDayKey[item.t.id] = key;
      _idItem[item.t.id] = item;
    }
    sortedDayKeys.addAll(dayGroups.keys);
    sortedDayKeys.sort((a, b) => b.compareTo(a));
  }

  /// 增量 diff 新列表，只重建内容变化的日分组。
  ///
  /// 返回发生变化的日 key 集合；无变化时返回 null（调用方据此跳过全部
  /// 扁平项重建 —— Drift 等值重复 emit 的场景成本为零）。
  ///
  /// 两遍算法：Pass 1 判定脏日集合时无法预知后续条目会不会弄脏早前判过的
  /// 日（后位新增交易弄脏前位所在日），因此 Pass 2 再按新列表顺序重建脏日
  /// —— 顺序语义与全量重算的 putIfAbsent 完全一致。
  Set<String>? applyDiff(List<GroupedTransaction> newItems) {
    final newKeyById = <int, String>{};
    final dirty = <String>{};

    // Pass 1（O(n)，值相等时零字符串格式化）
    for (final item in newItems) {
      final id = item.t.id;
      final oldKey = _idDayKey[id];
      if (oldKey == null) {
        final key = dayKeyOf(item);
        dirty.add(key);
        newKeyById[id] = key;
        continue;
      }
      final oldItem = _idItem[id]!;
      String key;
      if (identical(oldItem, item) || oldItem == item) {
        key = oldKey;
      } else {
        key = dayKeyOf(item);
        if (key != oldKey) dirty.add(oldKey);
        dirty.add(key);
      }
      newKeyById[id] = key;
    }

    // 删除：旧 id 不在新列表 → 其旧日脏
    for (final entry in _idDayKey.entries) {
      if (!newKeyById.containsKey(entry.key)) dirty.add(entry.value);
    }
    if (dirty.isEmpty) return null;

    // Pass 2：按新列表顺序重建脏日
    final rebuilt = <String, List<GroupedTransaction>>{};
    for (final item in newItems) {
      final key = newKeyById[item.t.id]!;
      if (dirty.contains(key)) {
        (rebuilt[key] ??= []).add(item);
      }
    }
    for (final key in dirty) {
      final list = rebuilt[key];
      if (list == null || list.isEmpty) {
        dayGroups.remove(key);
        sortedDayKeys.remove(key);
      } else {
        dayGroups[key] = list;
        if (!sortedDayKeys.contains(key)) _insertSortedDesc(key);
      }
    }

    // 增量维护 id 索引：消失删、变化写、未变不动
    _idDayKey.removeWhere((id, _) => !newKeyById.containsKey(id));
    _idItem.removeWhere((id, _) => !newKeyById.containsKey(id));
    for (final item in newItems) {
      final id = item.t.id;
      if (_idDayKey[id] != newKeyById[id]) _idDayKey[id] = newKeyById[id]!;
      final old = _idItem[id];
      if (!identical(old, item) && old != item) _idItem[id] = item;
    }
    return dirty;
  }

  /// 降序数组的二分插入位置（首个小于 key 的槽位）。
  void _insertSortedDesc(String key) {
    int lo = 0, hi = sortedDayKeys.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (sortedDayKeys[mid].compareTo(key) > 0) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    sortedDayKeys.insert(lo, key);
  }
}
