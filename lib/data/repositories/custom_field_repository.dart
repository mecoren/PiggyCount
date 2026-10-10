import '../db.dart';

/// v46 账本自定义字段的仓储接口。
///
/// 两类数据：
/// - **定义**（[CustomFieldDefinition]）：按账本隔离的名称/类型/排序，独立表。
/// - **值**：以 `{ fieldSyncId: value }` 落在 `transactions.custom_values_json`。
///   键用 fieldSyncId（而非本地 int id），因此共享账本下 Editor 写入 Owner
///   定义的字段值天然可锚定，无需像 tag 那样再建 override 表。
///
/// 值的三态契约（与 v45 originalAmount 同款，写入方必须显式区分）：
/// - `null` = **不改动**（批量改备注/改分类等无关路径不得顺手清空）
/// - `{}`（空 map）= **清空**（列写 NULL）
/// - 非空 map = 覆盖写入
abstract class CustomFieldRepository {
  // ============================================
  // 字段定义 CRUD
  // ============================================

  /// 创建字段定义。同账本内撞同名抛 [DuplicateNameException]。
  /// [syncId] 可选：导入/恢复等需要锚定的路径显式传入，UI 不传走 auto v4。
  /// [fieldType] 取 `amount | text | date`（见 `CustomFieldType`）。
  Future<int> createDefinition({
    required int ledgerId,
    required String name,
    required String fieldType,
    int sortOrder = 0,
    String? syncId,
  });

  /// 按 name 取定义，不存在则建一条（get-or-create 语义，给导入/恢复用，
  /// 不会抛 [DuplicateNameException]）。
  Future<int> upsertDefinition({
    required int ledgerId,
    required String name,
    required String fieldType,
    int? sortOrder,
    String? syncId,
  });

  /// 更新定义。null 表示不改动该字段。
  Future<void> updateDefinition(
    int id, {
    String? name,
    String? fieldType,
    int? sortOrder,
  });

  /// 删除定义，并**同时清理该账本下所有交易里对应该字段的值**。
  ///
  /// 清理按账本作用域走（值以 fieldSyncId 为键散落在交易行上），逐笔记
  /// transaction update 变更，保证其他设备也同步消失。
  Future<void> deleteDefinition(int id);

  /// 回填 syncId（导入场景：本地已有定义缺 syncId 时用 JSON 带的补上）。
  /// 不记 change —— 纯补全远端已有标识，push 时同 syncId 幂等。
  Future<void> updateDefinitionSyncId(int id, String syncId);

  /// 把本账本交易里 `custom_values_json` 的 [oldSyncId] 键改名为 [newSyncId]。
  ///
  /// 用途（2026-10-10）：**同名不同 syncId** 的定义归并时，定义行采纳云端的
  /// syncId 后，本机既有值的键必须跟着改名，否则值成孤儿（定义在、值看不见）。
  /// 不记 change：纯身份迁移，调用方（导入/合并路径）自身已在
  /// `withRecordingSuppressed` 包裹内，再记会产生幻影变更。
  ///
  /// 键冲突时**保留已存在的 [newSyncId] 值、丢弃 [oldSyncId] 值**：两行同名定义
  /// 属各自独立创建，云端那份被视为权威（与导入侧「远端为准」一致）。
  /// 返回实际改名的交易数。
  Future<int> renameFieldValueKey({
    required int ledgerId,
    required String oldSyncId,
    required String newSyncId,
  });

  Future<CustomFieldDefinition?> getDefinitionById(int id);

  Future<CustomFieldDefinition?> getDefinitionBySyncId(String syncId);

  /// 该账本的全部定义（按 sortOrder，同序按 id 稳定）。
  Future<List<CustomFieldDefinition>> getDefinitionsForLedger(int ledgerId);

  /// 该账本定义流（编辑表单与字段管理页共用）。
  Stream<List<CustomFieldDefinition>> watchDefinitionsForLedger(int ledgerId);

  /// 批量更新排序（拖拽结束后一次落库）。
  Future<void> updateDefinitionSortOrders(
      List<({int id, int sortOrder})> updates);

  /// 同账本内是否重名。[excludeId] 用于编辑时排除自身。
  Future<bool> isFieldNameDuplicate({
    required int ledgerId,
    required String name,
    int? excludeId,
  });

  // ============================================
  // 交易值读写
  // ============================================

  /// 读某笔交易的自定义字段值。无值 → 空 map（不是 null）。
  Future<Map<String, dynamic>> getValuesForTransaction(int transactionId);

  /// 批量读（导出侧一次查询建映射，避免 N+1）。无值的交易不出现在结果里。
  Future<Map<int, Map<String, dynamic>>> getValuesForTransactions(
      List<int> transactionIds);

  /// 写某笔交易的值。三态见接口头注释。
  Future<void> setValuesForTransaction(
      int transactionId, Map<String, dynamic>? values);

  /// 该账本下有多少笔交易填了自定义字段值（管理页删字段前提示影响面）。
  Future<int> countTransactionsWithValues(int ledgerId);
}
