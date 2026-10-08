import 'package:drift/drift.dart' as d;

import '../db.dart';
import '../../models/note_history.dart';

/// 周期实例指纹：同去重键 (recurringId, 本地日历日) 下区分
/// 「真重复」与「同日多笔合法交易」的最小字段集。
/// 恢复侧判重规则见 [TransactionRepository.getRecurringInstanceDetails]。
typedef RecurringInstanceFingerprint = ({
  String? syncId,
  double amount,
  String? note,
});

/// 批量按 syncId 更新交易时的单条 update payload。
class TransactionUpdateBySyncIdData {
  final String syncId;
  final String type;
  final double amount;
  final int? categoryId;
  final int? accountId;
  final int? toAccountId;
  final DateTime happenedAt;
  final String? note;
  /// v30 多币种：交易币种。null 表示保持本地原值。
  final String? currencyCode;
  /// v30 多币种：折算到账本本位币的金额。null 表示保持本地原值。
  /// 注意：sync_diff_service 的 modified 路径若只更新 amount 而不带
  /// nativeAmount，单币种账本下本地旧行的 native_amount 会与新的 amount
  /// 分裂，导致合计（SUM(COALESCE(native_amount, amount))）读旧值——即
  /// 此前"同步后明细变了但合计不变"的根因。调用方必须重算并传入。
  final double? nativeAmount;
  /// 账单标记：不计入统计。diff 合并必须带上，否则跨设备丢失。
  final bool excludeFromStats;
  /// 账单标记：不计入预算。同上。
  final bool excludeFromBudget;
  /// 附件清单（云→本 modified 合并，附件差异贯通修复）。
  ///
  /// - null：不改动本地 transaction_attachments 行；
  /// - 非 null（含空列表）：以云端清单整体替换本地行 —— 快照是全量清单，
  ///   "云端无此附件"即显式删除。替换后按引用计数清理不再被引用的物理文件。
  final List<BatchAttachmentData>? attachments;

  /// v45 原始金额（用户手填的票面/来源金额）。
  ///
  /// null 表示**云端快照未携带该键**（旧版客户端导出），语义为「不改动本地
  /// 原值」；非 null 才写入。与 currencyCode 同模式 —— 避免旧快照因缺键
  /// 触发全量 modified 并把本地已填值抹成 null。
  final double? originalAmount;

  /// v46 自定义字段值 `{ fieldSyncId: value }`。
  ///
  /// null 表示**云端快照未携带该键**（旧版客户端导出），语义为「不改动本地
  /// 原值」；非 null 才写入（空 map = 显式清空 → 列写 NULL）。与
  /// [originalAmount] 同模式 —— 避免旧快照因缺键把本地已填值抹平。
  final Map<String, dynamic>? customValues;

  /// v8 G2 周期规则锚点（**本地 int id**，由云端的 `recurringSyncId` 解析而来）。
  ///
  /// 三态：
  /// - `null`（不传）：**不改动**本地锚点 —— 调用方未涉及该字段时的默认值；
  /// - `d.Value(null)`：云端显式无锚点（快照未携带 `recurringSyncId`）→ 清空；
  /// - `d.Value(id)`：写入。
  ///
  /// 为什么用三态而不是"可空即清空"：后者会让所有未涉及该字段的调用方
  /// （含既有测试）在合并时**静默清掉**本机锚点。
  final d.Value<int?>? recurringId;

  const TransactionUpdateBySyncIdData({
    required this.syncId,
    required this.type,
    required this.amount,
    this.categoryId,
    this.accountId,
    this.toAccountId,
    required this.happenedAt,
    this.note,
    this.currencyCode,
    this.nativeAmount,
    this.excludeFromStats = false,
    this.excludeFromBudget = false,
    this.attachments,
    this.originalAmount,
    this.customValues,
    this.recurringId,
  });
}

/// 批量插入交易时附带的附件元数据。交易行还没插入,txId 未知,
/// repo 内部按 batch 内 index 找到刚插入的 txId 再组装 AttachmentsCompanion。
class BatchAttachmentData {
  final String fileName;
  final String? originalName;
  final int? fileSize;
  final int? width;
  final int? height;
  final int sortOrder;
  final String? cloudFileId;
  final String? cloudSha256;

  /// 快照链路内容哈希(attachment_binary_sync),恢复时随清单落列。
  final String? localSha256;

  const BatchAttachmentData({
    required this.fileName,
    this.originalName,
    this.fileSize,
    this.width,
    this.height,
    this.sortOrder = 0,
    this.cloudFileId,
    this.cloudSha256,
    this.localSha256,
  });
}

/// 首页交易窗口的默认页大小（M2-a）。
///
/// 一页 100 行 ≈ 首屏 + 一两次快滑，避免"滑到底才开始加载"的空窗；
/// 同时把首页常驻行数从「整本账本」压到「已滑过的页数 × 100」。
const int kTransactionWindowSize = 100;

/// 交易Repository接口
/// 定义交易相关的所有数据操作
abstract class TransactionRepository {
  /// 获取最近的交易记录
  Stream<List<Transaction>> watchRecentTransactions({
    required int ledgerId,
    int limit = 20,
  });

  /// 获取指定月份的交易记录
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  Stream<List<Transaction>> watchTransactionsInMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取所有交易记录（带分类信息）
  /// [ledgerId] 可选，不传则获取所有账本的交易
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryAll({
    int? ledgerId,
  });

  /// M2-a 首页窗口化：只取窗口内的交易（keyset 游标 + LIMIT）。
  ///
  /// 与 [watchTransactionsWithCategoryAll] **同口径**（同样三连 LEFT JOIN），
  /// 差别只有两点：
  /// 1. 排序加 `id DESC` 做 tiebreaker —— 同一时刻多笔时顺序稳定，游标可比较；
  /// 2. 只返回 [limit] 行，不再整本账本进内存。
  ///
  /// [before] = 上一页最后一行的 `(happenedAt, id)`；`null` 表示从最新一页开始。
  /// 首页当前用「`before: null` + 只增 `limit`」形态（一次查询给最新 N 行，滚动
  /// 追加即增大 N，天然不会把已显示的行挤出窗口）；按键分页（`before`）由
  /// `test/repositories/transaction_window_regression_test.dart` 钉住与全量查询的
  /// **逐值等价**。
  ///
  /// 命中既有索引 `idx_transactions_ledger_happened`（`(ledger_id, happened_at)`）。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionWindow({
    required int ledgerId,
    ({DateTime happenedAt, int id})? before,
    int limit = kTransactionWindowSize,
  });

  /// 获取所有交易记录（带分类信息）- 非 Stream 版本
  /// [ledgerId] 可选，不传则获取所有账本的交易
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> transactionsWithCategoryAll({
    int? ledgerId,
  });

  /// 获取最近的交易记录（带分类信息）- 用于预加载
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> getRecentTransactionsWithCategory({
    required int ledgerId,
    required int limit,
  });

  /// 聚合指定账本的历史备注。
  ///
  /// [categoryId] 为空时查询账本全部分类。
  Future<List<NoteHistoryEntry>> getNoteHistory({
    required int ledgerId,
    int? categoryId,
    required NoteHistorySort sort,
    int limit = 20,
  });

  /// 取该账本 + 该类型下**最近一笔带分类交易**的分类 —— 快捷记账模式的记忆源。
  ///
  /// 返回 `null` 表示扫描窗口内没有可用记忆，调用方应退回分类网格（**不要**预填空分类）。
  ///
  /// 只扫描最近 [scanLimit] 笔以保证工作量有上界；`type` 与 `category_id`
  /// 都不在 `idx_transactions_ledger_happened` 里，需要回表逐行判定。
  Future<int?> getLastUsedCategoryId({
    required int ledgerId,
    required String kind,
    int scanLimit,
  });

  /// 根据ID获取单条交易
  Future<Transaction?> getTransactionById(int id);

  /// 判断该周期模板在指定日期是否已生成过实例（用于 recurring 生成防重）。
  ///
  /// recurring 周期交易可能因「本地 generator 先生成 + S3 恢复又插入同周期
  /// 实例」而产生重复（两端 recurringId/happenedAt 相同、syncId 不同）。
  /// 生成前与恢复前都应调用此方法做 (recurringId, happenedAt) 维度的去重。
  /// [happenedAt] 传实例的计划日期即可（REC-01/02：按 [recurringInstanceKey]
  /// 的本地日历日维度匹配，不比较精确时刻）。
  Future<bool> existsRecurringInstance({
    required int recurringId,
    required DateTime happenedAt,
  });

  /// 批量获取周期实例指纹明细（键见 [recurringInstanceKey]）。
  ///
  /// 供导入路径预加载：一次查库构建内存映射，循环内 O(1) 判重，
  /// 替代逐笔 await 查询（大快照 N 笔周期实例 = N 次 SELECT）。
  /// 值携带同键下各实例的 (syncId, amount, note)：恢复侧命中同日键后
  /// 还需逐实例比对指纹——仅 syncId 相同（同一实体）或 amount+note 均
  /// 相同（generator 本机实例 vs 源端同源实例）才算真重复跳过；
  /// 同日不同金额/备注是合法的多笔交易，必须照常落库
  /// （回归案例：tx-hist-day-rent54 被同日 generator 实例误杀）。
  Future<Map<String, List<RecurringInstanceFingerprint>>>
      getRecurringInstanceDetails(Iterable<int> recurringIds);

  /// 归一化 (recurringId, happenedAt) → 周期实例去重键。
  ///
  /// 键取 happenedAt 的**本地日历日**（不含时刻）。理由：
  /// - JSON 导出走 `.toUtc()`、导入走 `.toLocal()`，跨时区恢复时精确毫秒
  ///   必然失配 → 同日归一后同设备/同时区恢复稳定命中；
  /// - daily/weekly 规则首笔继承 startDate 时刻（可能非 0 点），按日匹配
  ///   可与生成器的 0 点系实例互相识别；
  /// 已知局限：两端时区差跨午夜时（如 +08 与 UTC）仍可能漏判，根治需
  /// 存储生成意图日本身（schema 变更），当前以日志告警兜底。
  static String recurringInstanceKey(int recurringId, DateTime happenedAt) {
    final mm = happenedAt.month.toString().padLeft(2, '0');
    final dd = happenedAt.day.toString().padLeft(2, '0');
    return '$recurringId|${happenedAt.year.toString().padLeft(4, '0')}-$mm-$dd';
  }

  /// 获取指定月份的交易记录（带分类信息）
  ///
  /// [month] 为周期标签,约定传 DateTime(year, month, 1);实际范围由账本
  /// monthStartDay 决定:[y-m-起始日, y-(m+1)-起始日)。
  Stream<List<({Transaction t, Category? category, Account? account, Account? toAccount})>> watchTransactionsWithCategoryInMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定年份的交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category, Account? account, Account? toAccount})>> watchTransactionsWithCategoryInYear({
    required int ledgerId,
    required int year,
  });

  /// 获取指定分类和时间范围的交易记录（带分类信息）
  Stream<List<({Transaction t, Category? category, Account? account, Account? toAccount})>> watchTransactionsForCategoryInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
    int? categoryId,
    required String type,
  });

  /// 添加交易
  Future<int> addTransaction({
    required int ledgerId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
    String? syncId,
    /// 关联的周期模板 id（recurring_transactions.id）。recurring 生成器生成的
    /// 实例必须写入，否则 (recurringId, happenedAt) 去重键缺失，无法与
    /// S3 恢复来的同周期实例识别为重复（见 existsRecurringInstance）。
    int? recurringId,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
    // v30 交易级多币种:未传时聚合层兜底(currencyCode=账户币种/本位币;
    // nativeAmount 外币先按有效汇率折算,取不到才 =amount,详设计 02 §六)。
    String? currencyCode,
    double? nativeAmount,
    // v45 原始金额(用户手填):null = 未填写,语义等价于「默认金额 = amount」,
    // 不做 ?? amount 兜底落库 —— 物理 null 才能区分「未填」与「手填了相同值」。
    double? originalAmount,
    // v46 自定义字段值 { fieldSyncId: value }:null / 空 = 该笔没有值(列写 NULL)。
    // 新建路径没有"不改动"语义,直接落库。
    Map<String, dynamic>? customValues,
  });

  /// 批量新增交易，单事务内插入，返回插入条数。
  ///
  /// [recordChanges] 默认 true,会逐条登记 changeTracker.recordLedgerChange。
  /// FullPull 路径需要传 false 避免"从云端拉下来的数据又被反向 push 回去"。
  Future<int> insertTransactionsBatch(
    List<TransactionsCompanion> items, {
    bool recordChanges = true,
  });

  /// 插入单条交易（使用 Companion 对象）
  ///
  /// [recordChanges] 同 [insertTransactionsBatch]。
  Future<int> insertTransactionCompanion(
    TransactionsCompanion item, {
    bool recordChanges = true,
  });

  /// 批量插入交易 + 关联数据(tag / attachment),全部在单事务内完成。
  ///
  /// 用于带标签 / 带附件的 import 路径 — 原本的"单条 insert + 单条
  /// updateTransactionTags + 单条 createAttachment"会引发 N+1 + 嵌套事务,
  /// 1 万条带标签数据耗时数十分钟;本方法把 N 次单条事务折叠成 1 次,
  /// 并用 `db.batch` 合并 tag / attachment / local_changes 的 INSERT。
  ///
  /// [tagIdsByIndex] - 批次内 index → tagId 列表。调用方需保证 tagIds 去重
  ///   (TransactionTags 表无 UNIQUE 约束,本方法不做 select 防重)。
  /// [attachmentsByIndex] - 批次内 index → 附件元数据列表。
  /// [recordChanges] - 同 [insertTransactionsBatch]。
  ///
  /// 返回插入的 tx id 列表,顺序跟 [transactions] 输入对齐。
  Future<List<int>> insertTransactionsBatchWithRelations({
    required List<TransactionsCompanion> transactions,
    Map<int, List<int>> tagIdsByIndex = const {},
    Map<int, List<BatchAttachmentData>> attachmentsByIndex = const {},
    bool recordChanges = true,
  });

  /// 更新交易
  Future<void> updateTransaction({
    required int id,
    required String type,
    required double amount,
    int? categoryId,
    String? note,
    DateTime? happenedAt,
    dynamic accountId,
    bool? excludeFromStats,
    bool? excludeFromBudget,
    // v30 交易级多币种:未传(null)= 不改动既有值;聚合层对 amount/账户变化
    // 做折算兜底。
    String? currencyCode,
    double? nativeAmount,
    // v45 原始金额:dynamic 三态 —— dart null = 不改动既有值(批量改备注/
    // 改分类等非金额路径必须保持原值),d.Value<double?>(null) = 显式清空
    // (用户在编辑表单里删掉了原始金额),d.Value(x) = 写入。与 accountId 同模式。
    dynamic originalAmount,
    // v46 自定义字段值三态:null = **不改动**(批量改备注/改分类等路径不得
    // 顺手清空),空 map = 清空(列写 NULL),非空 = 覆盖写入。
    Map<String, dynamic>? customValues,
  });

  /// 删除交易
  Future<void> deleteTransaction(int id);

  // --- v44 回收站（F1）---------------------------------------------------
  //
  // 软删除 = 把整行搬进 deleted_transactions，标签/附件行原地保留；
  // `deleteTransaction` 保持"彻底删除"语义（同步/清库等内部路径专用）。
  // 返回 false 表示目标不存在（软删）或主键已被占用（恢复），调用方需提示。

  /// 软删除一笔交易（进回收站）
  Future<bool> softDeleteTransaction(int id);

  /// 批量软删除（搜索页批量操作）。语义同 [softDeleteTransaction]：只搬
  /// 交易本体进回收站，标签/附件原地保留，不写 local_changes。
  /// 单事务 + batch 合并 N 次插入（逐条调用 = N 次事务提交）。
  /// 返回实际入回收站条数（id 不存在自动跳过）。
  Future<int> softDeleteTransactions(List<int> ids);

  /// 回收站列表，按删除时间倒序；[ledgerId] 为空则跨账本
  Future<List<DeletedTransaction>> getDeletedTransactions({int? ledgerId});

  /// 从回收站恢复一笔交易
  Future<bool> restoreDeletedTransaction(int txId);

  /// 回收站里彻底删除一笔（连带附件行与磁盘文件）
  Future<void> purgeDeletedTransaction(int txId);

  /// 清空某账本的回收站（删账本 / 清空账本时内部调用）
  Future<int> purgeDeletedTransactionsForLedger(int ledgerId);

  /// 获取指定类型和时间范围内的交易数量
  Future<int> countByTypeInRange({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  });

  /// 获取账本的所有交易记录
  Future<List<Transaction>> getTransactionsByLedger(int ledgerId);

  /// 获取账本在指定时间范围内的交易记录
  Future<List<Transaction>> getTransactionsByLedgerInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });

  /// 最近 [limit] 笔交易(按 happenedAt 降序),纯 [Transaction] 行、无分类/账户
  /// join、不做任何 exclude 过滤。
  ///
  /// 供桌面小组件「最近交易」类型取数用(`WidgetDataService.gatherRecent`,
  /// `.docs/home-widget/plan.md` §一.3)。需要分类名/图标/账户名时由调用方
  /// 按交易的 categoryId / accountId 自行查 CategoryRepository.getCategoryById /
  /// AccountRepository.getAccount —— 与 [getRecentTransactionsWithCategory] 的
  /// 区别:后者额外 join 分类/账户表,语义更重,小组件场景不需要。
  Future<List<Transaction>> getRecentTransactions(
    int ledgerId, {
    int limit = 10,
  });

  /// 更新交易(通过 ID 和字段)。
  /// accountId / toAccountId 接 dynamic:dart `null` = absent(不更新);
  /// `d.Value<int?>(null)` = 显式清空;`int` = 写值。
  Future<void> updateTransactionFields({
    required int id,
    dynamic accountId,
    dynamic toAccountId,
  });

  /// 获取账本的首笔交易（按时间排序）
  Future<Transaction?> getFirstTransactionByLedger(int ledgerId);

  /// 获取账本的末笔交易（按时间排序）
  Future<Transaction?> getLastTransactionByLedger(int ledgerId);

  /// 全局最早一笔交易的发生时间（不限账本，用于净值趋势「全部」范围的起点）。无交易返回 null。
  Future<DateTime?> getEarliestTransactionDate();

  /// 更新交易的账本
  Future<void> updateTransactionLedger({
    required int id,
    required int ledgerId,
  });

  // ==================== 日历功能相关 ====================

  /// 获取指定月份的每日交易统计
  /// 返回 Map<日期字符串, (收入, 支出)>
  /// 例: {"2025-01-15": (500.0, 1200.0), ...}
  /// M2-a：按日聚合的「当日收支」（列表头显示用）。
  ///
  /// 口径与列表里原本的 Dart 循环 `_computeDayTotals` **逐字一致**：
  /// `nativeAmount ?? amount`、只计 income / expense（**transfer 不计**）、
  /// **不**过滤 `excludeFromStats`（这是"当日收支"展示，不是统计口径 ——
  /// 与 [getDailyTotalsByMonth] 的日历口径**故意不同**，别混用）。
  ///
  /// 窗口化之后，最旧的一天可能只加载了部分行，Dart 侧累加必然算少；
  /// 所以日合计必须由本方法从 SQL 出，key = `yyyy-MM-dd`（本地时区）。
  Future<Map<String, (double income, double expense)>> getDailyTotalsInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  });

  Future<Map<String, (double income, double expense)>> getDailyTotalsByMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定日期的所有交易（含分类、标签、附件、账户）
  Future<List<({
    Transaction t,
    Category? category,
    List<Tag> tags,
    List<TransactionAttachment> attachments,
    Account? account,
  })>> getTransactionsByDate({
    required int ledgerId,
    required DateTime date,
  });

  /// 获取指定时间范围的交易列表（用于日历当月列表）
  Future<List<({
    Transaction t,
    Category? category,
    List<Tag> tags,
    List<TransactionAttachment> attachments,
    Account? account,
  })>> getTransactionsByDateRange({
    required int ledgerId,
    required DateTime startDate,
    required DateTime endDate,
  });

  /// 获取指定月份所有有交易的日期列表
  /// 返回 ["2025-01-15", "2025-01-16", ...]
  Future<List<String>> getTransactionDatesByMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 根据 syncId 获取交易
  Future<Transaction?> getTransactionBySyncId(String syncId);

  /// 根据 syncId 更新交易的全部字段
  Future<void> updateTransactionBySyncId({
    required String syncId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
    // v45 原始金额:null = 不改动既有值(保持「全字段更新但可缺省」的既有语义)。
    double? originalAmount,
    // v46 自定义字段值:null = 不改动既有值;非 null(含空 map = 清空)才写入。
    Map<String, dynamic>? customValues,
  });

  /// 根据 syncId 删除交易
  Future<void> deleteTransactionBySyncId(String syncId);

  /// 批量按 syncId 删除交易(WebDAV/Supabase 同步从远端拉账本时,如果本地有
  /// 旧账本 + 用户选择"以远端为准"覆盖,N 条 delete by syncId 单条 await 会
  /// 跑几分钟;本方法用单条 `DELETE WHERE syncId IN (...)` 一次性删除)。
  ///
  /// [recordChanges] 默认 true,wrapper 会批量补 transaction:delete change log。
  /// 返回实际删除的条数。
  Future<int> deleteTransactionsBatchBySyncIds(
    List<String> syncIds, {
    bool recordChanges = true,
  });

  /// 批量按 syncId 更新交易主表字段。同事务内逐条 UPDATE,N 次跨 isolate
  /// boundary 但 BEGIN/COMMIT 只跑一次。
  ///
  /// **不涉及 tag 更新** — caller 拿到 returned `Map<syncId, txId>` 后自己批量
  /// 调 `updateTransactionTags`(或者更高效的 batch 接口,如果将来加的话)。
  Future<Map<String, int>> updateTransactionsBatchBySyncId(
    List<TransactionUpdateBySyncIdData> updates, {
    bool recordChanges = true,
  });

  /// 为「本地无 syncId、经业务键唯一匹配到云端交易」的行回填云端 syncId
  /// （认领语义，与 v9 快照导入的 sync_id 回填同源）。
  ///
  /// 双重守卫，任一不满足返回 false：
  /// - 目标行当前 syncId 必须为空（绝不覆盖既有身份）；
  /// - 全库不得已有其他行占用该 syncId（否则按 syncId 的批量更新会命中多行）。
  ///
  /// 不写 local_changes：身份锚定不是内容变更，且调用方
  /// （云→本合并）处于 withRecordingSuppressed 内。
  Future<bool> adoptTransactionSyncId(int txId, String syncId);

  /// 创建估值调整交易
  Future<int> createAdjustmentTransaction({
    required int ledgerId,
    required int accountId,
    required double amount,
    required DateTime happenedAt,
    String? note,
  });
}
