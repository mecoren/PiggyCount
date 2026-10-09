import '../db.dart';

/// 储蓄目标仓库接口（**ledger-scoped**，见 prd/savings_goal/requirements.md）。
///
/// 进度来源二选一（互斥）：
/// - `accountId` 非空 = 账户模式，进度由该账户余额实时给出；
/// - `accountId` 为空 = 手动模式，进度读 `savedAmount`。
///
/// 仓库只负责存取，**不解算进度**——纯函数在 `lib/utils/savings_goal_progress.dart`，
/// 因为账户模式需要账户余额，而余额是跨表的读侧聚合（由 Provider / 页面喂入）。
abstract class SavingsGoalRepository {
  // ============ CRUD ============

  /// 创建储蓄目标。
  ///
  /// 新建即分配 UUID `syncId`（跨设备 LWW 用）；`sync_id` 在 schema 上允许
  /// NULL 只为兼容未来可能的存量行，新建走这里永远填（导入路径显式传快照里的
  /// syncId，保持跨设备身份一致）。
  Future<int> createSavingsGoal({
    required int ledgerId,
    required String name,
    required double targetAmount,
    String currency = 'CNY',
    int? accountId,
    double savedAmount = 0,
    DateTime? startDate,
    DateTime? targetDate,
    String? note,
    int sortOrder = 0,
    String? syncId,
  });

  /// 更新储蓄目标。
  ///
  /// 可空字段一律「null = 不改」；需要**清空**时用对应的显式开关
  /// （[clearAccount] / [clearTargetDate] / [clearNote]），避免用 null
  /// 兼职表达「不改」与「清空」两种语义。
  Future<void> updateSavingsGoal(
    int id, {
    String? name,
    double? targetAmount,
    String? currency,
    int? accountId,
    bool clearAccount = false,
    double? savedAmount,
    DateTime? startDate,
    DateTime? targetDate,
    bool clearTargetDate = false,
    String? note,
    bool clearNote = false,
    int? sortOrder,
    String? syncId,
  });

  /// 删除储蓄目标
  Future<void> deleteSavingsGoal(int id);

  /// 「存入 / 取出」落点：直接改手动累计额（账户模式下该列不参与进度，
  /// 但 UI 仍可写入以备切回手动模式）。
  Future<void> updateSavingsGoalSavedAmount(int id, double savedAmount);

  // ============ 查询 ============

  Future<SavingsGoal?> getSavingsGoal(int id);

  Future<List<SavingsGoal>> getSavingsGoalsByLedger(int ledgerId);

  /// 所有账本的所有目标（导出用）。
  Future<List<SavingsGoal>> getAllSavingsGoals();

  /// 按账本监听目标列表（写库自动刷新），排序 `sortOrder, id` 稳定。
  Stream<List<SavingsGoal>> watchSavingsGoalsByLedger(int ledgerId);

  Future<void> updateSavingsGoalSortOrders(List<SavingsGoal> goals);

  /// 账户被删除时把引用置空（目标**降级为手动模式**，不级联删除）。
  /// 返回受影响的行数。
  Future<int> clearSavingsGoalAccountRefs(int accountId);
}
