import 'package:drift/drift.dart' as d;

import '../db.dart';
import '../models/analytics_amount_metric.dart';
import '../models/analytics_time_metric.dart';
import '../models/analytics_transaction_filter.dart';
import '../models/transaction_search_query.dart';
import '../../models/note_history.dart';

/// 「5 分钟内再次记账继承上一笔默认值」的窗口长度（**唯一来源**：UI 与测试共用）。
///
/// 语义见 [TransactionRepository.getRecentEntryDefaults]。
const Duration kRecentEntryInheritWindow = Duration(minutes: 5);

/// 从已保存交易派生的「上一笔录入默认值」，供记账页预填。
///
/// 字段可空：对应上一笔确实没选分类 / 账户（此时**不继续前溯**，交由调用方
/// 回退到自己的默认值）。
typedef RecentEntryDefaults = ({int? categoryId, int? accountId});

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

  /// v56 退款关联（F1-b，`prd/refund_reimbursement`）：收入行指向被冲正的
  /// 支出行（同账本 1:1；部分退款台账明确不做）。
  ///
  /// 三态（同 [recurringId]）：
  /// - `null`（不传）：**不改动**本地关联 —— 调用方未涉及该字段时的默认值；
  /// - `d.Value(null)`：云端显式无关联（快照未携带 / 携带 null）→ 清空；
  /// - `d.Value(id)`：写入。
  ///
  /// 为什么用三态而不是「可空即清空」：同 [recurringId] 的理由 —— 会让所有
  /// 未涉及该字段的调用方在合并时**静默清掉**本机关联。
  final d.Value<int?>? refundOfId;

  /// v56 报销状态（F1-b）：三态字符串 `none` / `pending` / `reimbursed`。
  ///
  /// null = 云端快照未携带该键（旧版客户端导出的 v13 快照）→ **不改动**本地
  /// 原值；非 null 才写入（v14 快照恒写该键，合并路径照云端值落，含
  /// `'none'` 重置）。与 [originalAmount] 同模式 —— 避免旧快照缺键把本地
  /// 已设状态抹平。
  final String? reimburseStatus;

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
    this.refundOfId,
    this.reimburseStatus,
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

  /// 按搜索条件过滤的交易流（带分类 / 转入转出账户）。
  ///
  /// 条件在 SQL 侧下推（时间 / 金额 / 分类 / 账户 / 标签 / 附件 / 币种 /
  /// 关键字备注与金额文本），只返回命中行；调用方只保留「分类显示名关键字」
  /// 与「自定义字段值条件」两类 Dart 侧精判（见 [TransactionSearchQuery]）。
  /// 排序与列表页一致：`happened_at DESC, id DESC`。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsByQuery({
    required int ledgerId,
    required TransactionSearchQuery query,
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

  /// 取「最近一次录入」的默认值（分类 + 账户），供记账页在
  /// [kRecentEntryInheritWindow] 内预填 —— 连续记账少点几次。
  ///
  /// - 窗口按 [Transactions.createdAt]（**本设备录入时刻**）判定，不看
  ///   `happenedAt`：用户可以补记发生日期为昨天的一笔，按发生时间判会让整批
  ///   补记都不继承。
  /// - 按 [kind]（`expense` / `income`）分别取最近一笔同类型交易：分类本身分
  ///   kind，跨 kind 继承会预填一个类型不匹配的分类。转账既不参与也不作源。
  /// - `createdAt` 为 NULL 的行（批量导入 / 云恢复 / 周期模板生成）不参与。
  /// - 返回 `null` = 窗口内没有可用来源；返回记录则**忠实地**带上上一笔的
  ///   分类 / 账户（可能为 null，不继续前溯）。
  ///
  /// [now] 仅供测试注入，生产不要传。
  Future<RecentEntryDefaults?> getRecentEntryDefaults({
    required int ledgerId,
    required String kind,
    Duration within = kRecentEntryInheritWindow,
    DateTime? now,
  });

  /// 取「本机最近录入的一笔同类型交易」整行，供记账抽屉「带出上一笔」。
  ///
  /// 与 [getRecentEntryDefaults] **同一取数口径**（同账本、同 [kind]、按
  /// [Transactions.createdAt] 本机录入时刻倒序、排除 `createdAt` 为 NULL 与
  /// `recurringId` 非空的行；转账既不参与也不作源），唯一差别是：
  /// - **没有时间窗** —— 用户显式点「带出上一笔」时，昨天那笔也该带出来；
  /// - 返回**整行**，由调用方决定带出哪些字段（金额 / 日期等由 UI 侧排除）。
  ///
  /// 返回 `null` = 该类型在本账本没有可作来源的录入，调用方应隐藏入口而不是
  /// 带出一份空数据。
  Future<Transaction?> getLastRecordedTransaction({
    required int ledgerId,
    required String kind,
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
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryInMonth({
    required int ledgerId,
    required DateTime month,
  });

  /// 获取指定年份的交易记录（带分类信息）
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryInYear({
    required int ledgerId,
    required int year,
  });

  /// 获取指定分类和时间范围的交易记录（带分类信息）
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsForCategoryInRange({
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
    // v56 退款关联(F1-b):收入行指向被冲正的支出行(同账本 1:1)。
    // null = 非退款行(存量行与普通新行的默认态)。
    int? refundOfId,
    // v56 报销状态三态(F1-b):none(默认,不涉及报销)/ pending(待报销)/
    // reimbursed(已报销)。新建路径直接落库,无"不改动"语义。
    String reimburseStatus = 'none',
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
    // v56 退款关联三态(F1-b):dart null = 不改动既有值;d.Value<int?>(null) =
    // 用户在编辑表单里解除关联;d.Value(x) / x = 写入。与 originalAmount 同模式。
    dynamic refundOfId,
    // v56 报销状态(F1-b):null = 不改动;非 null = 显式写入(含 'none' 重置)。
    String? reimburseStatus,
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
  ///
  /// [amountMetric] 只用于**行过滤**：自定义字段口径下「没填该字段」的明细
  /// 不计入笔数（记账金额 / 原始金额口径零影响）。笔数必须与同页金额同口径，
  /// 否则「¥500 / 8 笔」里的笔数会跟金额对不上账。
  ///
  /// [timeMetric] 只用于**区间判定**（`[start, end)`，日粒度）：自定义字段时间
  /// 口径下按该字段的日期划区间，且没填该字段的明细同样不计入笔数 —— 笔数必须
  /// 与同页金额同口径。
  ///
  /// **历史语义（有意保留）**：本方法**不过滤 `exclude_from_stats`**（「不计
  /// 收支」的明细也算笔数），而 `totalsInRange` 等同页金额聚合会过滤 —— 即
  /// 「¥500 / 8 笔」里的笔数分母比金额集合略宽。改它会动到报表页已有数字，故
  /// 保持现状。
  Future<int> countByTypeInRange({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
    AnalyticsAmountMetric amountMetric,
    AnalyticsTimeMetric timeMetric,
    AnalyticsTransactionFilter filter,
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
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> getTransactionsByDate({
    required int ledgerId,
    required DateTime date,
  });

  /// 获取指定时间范围的交易列表（用于日历当月列表 / 明细导出）。
  ///
  /// **区间语义**：默认口径是**闭区间** `[startDate, endDate]`（`BETWEEN`，
  /// 历史行为，调用方自己收到半开）；自定义字段时间口径下没有「当天的什么时刻」
  /// 可言，改用与统计口径一致的**日粒度半开区间** `[startDate, endDate)`
  /// （见 [AnalyticsTimeMetric.rangeSqlInlined]）—— 调用方收口时应用
  /// [AnalyticsTimeMetric.inRange]，它对两种口径都与这里的 SQL 同义。
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> getTransactionsByDateRange({
    required int ledgerId,
    required DateTime startDate,
    required DateTime endDate,
    AnalyticsTimeMetric timeMetric,
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

  /// v56 退款关联批量回填（F1-b 导入路径专用，`prd/refund_reimbursement`）。
  ///
  /// 导入时退款行可能排在它所引用的交易**之前**（快照 JSON 数组顺序不保证），
  /// 插入时只能先落 NULL；本方法在整批插入落库后按 syncId 解析回填。
  /// [links] 的 `refundOfId` 为 null 表示解析不到（调用方应先过滤掉，
  /// 方法内对 null 也按「写 NULL」处理，语义安全）。
  ///
  /// [recordChanges] 语义同其它写方法：false（云→本地合并路径）不回流
  /// local_changes。返回实际更新条数。
  Future<int> backfillRefundLinks(
    List<({String txSyncId, int? refundOfId})> links, {
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
