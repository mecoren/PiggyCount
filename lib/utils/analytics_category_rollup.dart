import '../data/db.dart' as db;

/// 分类层级聚合：把 `totalsByCategoryWithHierarchy` 的 L2 行金额/笔数并进 L1，
/// 并带出子分类明细。
///
/// 为什么在 utils 而不是页面私有：洞察页（固定周/月/年/全部视角）与 F2 的
/// 自定义区间报表要出**同一份**分类排行榜，两份实现必然算出两个数。
// 聚合一级分类数据（将二级分类金额/笔数聚合到一级分类）
Future<
    List<
        ({
          int? id,
          String name,
          db.Category? category,
          double total,
          int count,
          List<
              ({
                int id,
                db.Category category,
                String name,
                double total
              })> subCategories
        })>> aggregateTopLevelCategories(
    List<
            ({
              int? id,
              String name,
              String? icon,
              int? parentId,
              int level,
              double total,
              int count
            })>
        hierarchyData,
    dynamic repo) async {
  // 1. 先收集所有一级分类的完整信息
  final topLevelInfo = <int, db.Category>{};
  final topLevelNames = <int?, String>{};

  // 批量预取全部分类（此前三段循环内逐条 await getCategoryById，
  // 分类层级典型 20-60 个 → 每次刷新串行 20-60 条点查）。
  final positiveIds = <int>{
    for (final item in hierarchyData)
      if (item.id != null) item.id!,
    for (final item in hierarchyData)
      if (item.level == 2 && item.parentId != null) item.parentId!,
  };
  final categoriesById = await repo.getCategoriesByIds(positiveIds);

  for (final item in hierarchyData) {
    if (item.level == 1) {
      topLevelNames[item.id] = item.name;
      if (item.id != null) {
        final category = categoriesById[item.id!];
        if (category != null) {
          topLevelInfo[item.id!] = category;
        }
      }
    }
  }

  // 2. 收集所有需要查询的父分类ID（二级分类的父分类，但在topLevelInfo中不存在的）
  final parentIdsToQuery = <int>{};
  for (final item in hierarchyData) {
    if (item.level == 2 &&
        item.parentId != null &&
        !topLevelInfo.containsKey(item.parentId!)) {
      parentIdsToQuery.add(item.parentId!);
    }
  }

  // 3. 查询缺失的父分类信息
  for (final parentId in parentIdsToQuery) {
    final category = categoriesById[parentId];
    if (category != null) {
      topLevelInfo[parentId] = category;
    }
  }

  // 4. 聚合金额与笔数，同时收集子分类明细
  final topLevelMap = <int?, double>{};
  final topLevelCountMap = <int?, int>{};
  final subCategoriesMap = <int?,
      List<({int id, db.Category category, String name, double total})>>{};

  for (final item in hierarchyData) {
    if (item.level == 1) {
      // 一级分类：累加金额与笔数
      topLevelMap.update(item.id, (v) => v + item.total,
          ifAbsent: () => item.total);
      topLevelCountMap.update(item.id, (v) => v + item.count,
          ifAbsent: () => item.count);
    } else if (item.level == 2 && item.parentId != null) {
      // 二级分类：累加到父分类
      topLevelMap.update(item.parentId, (v) => v + item.total,
          ifAbsent: () => item.total);
      topLevelCountMap.update(item.parentId, (v) => v + item.count,
          ifAbsent: () => item.count);
      // 收集子分类明细 — 这样点击一级分类才能展开子分类,
      // 点击子分类才能进 CategoryDetailPage。
      if (item.id != null) {
        final subCategory = categoriesById[item.id!];
        if (subCategory != null) {
          subCategoriesMap.putIfAbsent(item.parentId, () => []);
          subCategoriesMap[item.parentId]!.add((
            id: item.id!,
            category: subCategory,
            name: item.name,
            total: item.total,
          ));
        }
      }
    }
  }

  // 5. 对每个父分类的子分类按金额降序排列
  for (final subs in subCategoriesMap.values) {
    subs.sort((a, b) => b.total.compareTo(a.total));
  }

  // 6. 转换为列表并排序
  final result = topLevelMap.entries.map((e) {
    final id = e.key;
    final total = e.value;
    final subs = subCategoriesMap[id] ??
        <({int id, db.Category category, String name, double total})>[];

    final count = topLevelCountMap[id] ?? 0;
    // 获取一级分类信息
    if (id != null && topLevelInfo.containsKey(id)) {
      final category = topLevelInfo[id]!;
      return (
        id: id,
        name: category.name,
        category: category,
        total: total,
        count: count,
        subCategories: subs,
      );
    } else if (topLevelNames.containsKey(id)) {
      // 有 name 但 db.Category 为 null,UI 用 name fallback
      return (
        id: id,
        name: topLevelNames[id]!,
        category: null,
        total: total,
        count: count,
        subCategories: subs,
      );
    } else {
      return (
        id: id,
        name: '未分类',
        category: null,
        total: total,
        count: count,
        subCategories: subs,
      );
    }
  }).toList()
    ..sort((a, b) => b.total.compareTo(a.total));

  return result;
}
