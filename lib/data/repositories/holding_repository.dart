import '../db.dart';

/// 投资持仓 Repository 接口（v52）。
///
/// ## 作用域契约（重要）
///
/// holdings 是 **user-global** 实体 —— 与 `accounts` 同款：`ledger_id` 恒 0、
/// 跨账本可见，快照里全量导出到每个账本快照。所有写操作必须经 ChangeTracker 的
/// `recordUserGlobalChange('holding', ...)` 登记（由 `LocalRepository` 的事务包裹
/// 统一完成），**不要**直接 `db.into(db.holdings)` 写表 —— 绕过 Repository 写库
/// 是严重 bug，本地变更不进 `local_changes`、云端同步静默丢数据。
///
/// ## 本地专有列（行情缓存）
///
/// [writeQuoteCache] / [clearQuoteCache] 只写 `quote_price` / `quote_fetched_at` /
/// `quote_source_id` 三列，**不登记 `local_changes`、不触发上传**。这三列不进快照、
/// 不进 `holdingCanon` 指纹 —— 行情刷新必须保持「零同步噪声」。
///
/// 口径判定（投资账户的金额由持仓市值接管还是回退手填估值）见
/// [hasHoldings] / [getAccountIdsWithHoldings]，具体金额计算在
/// `lib/utils/holding_metrics.dart`。
abstract class HoldingRepository {
  /// 监听某账户下的持仓（按 sortOrder / id 稳定排序）
  Stream<List<Holding>> watchHoldingsByAccount(int accountId);

  /// 某账户下的持仓（按 sortOrder / id 稳定排序）
  Future<List<Holding>> getHoldingsByAccount(int accountId);

  /// 全量持仓（快照导出与净值批量预取用；按 id 稳定排序，保证跨设备指纹可比）
  Future<List<Holding>> getAllHoldings();

  /// 取单条持仓
  Future<Holding?> getHolding(int id);

  /// 某账户是否有持仓。**有持仓 = 该投资账户金额走持仓市值口径**；
  /// 无持仓 = 回退 `accounts.initial_balance`（绝不双计）。
  Future<bool> hasHoldings(int accountId);

  /// 有持仓的账户 id 集合（批量口径判定，避免逐账户 N+1 查询）
  Future<Set<int>> getAccountIdsWithHoldings();

  /// 新增持仓，返回新行 id。
  ///
  /// [syncId] 可选：种子 / 导入类路径显式塞确定性 id，UI 不传则走 auto v4。
  Future<int> createHolding({
    required int accountId,
    required String name,
    required String currency,
    String? symbol,
    String? market,
    String assetClass = 'other',
    double quantity = 0.0,
    double unitCost = 0.0,
    double unitPrice = 0.0,
    bool autoQuote = false,
    String? note,
    int? sortOrder,
    String? syncId,
  });

  /// 更新持仓。null 参数表示**不改动**该字段（与账户更新同款三态语义）。
  ///
  /// [clearOptionalFields] 为 true 时把 [symbol] / [market] / [note] 显式置 NULL
  /// —— 用户清空代码或备注时必传，否则空串与 null 无法区分。
  Future<void> updateHolding(
    int id, {
    String? name,
    String? symbol,
    String? market,
    String? assetClass,
    String? currency,
    double? quantity,
    double? unitCost,
    double? unitPrice,
    bool? autoQuote,
    String? note,
    int? sortOrder,
    bool clearOptionalFields = false,
    String? syncId,
  });

  /// 删除持仓
  Future<void> deleteHolding(int id);

  /// 删除某账户的全部持仓（删除账户时的级联，由 `LocalRepository.deleteAccount`
  /// 调用并逐条登记 delete 变更）。返回被删除的持仓条数。
  Future<int> deleteHoldingsByAccount(int accountId);

  /// 批量更新排序（排序参与快照指纹，逐条登记 upsert）
  Future<void> updateHoldingSortOrders(List<({int id, int sortOrder})> updates);

  /// 写行情缓存（**本地专有列**：不入 `local_changes`、不触发同步）。
  /// 只写传入的非 null 列，未传的列保持不变 —— 在已拉到的价格上只补一个
  /// `fetchedAt` 时不会把价格清空。
  Future<void> writeQuoteCache(
    int id, {
    double? price,
    DateTime? fetchedAt,
    String? sourceId,
  });

  /// 清空行情缓存。传 [sourceId] 时只清「确认由该行情源写入」的缓存
  /// （切换行情源后旧源的缓存不应继续参与「生效价」）。返回清理条数。
  Future<int> clearQuoteCache({String? sourceId});
}
