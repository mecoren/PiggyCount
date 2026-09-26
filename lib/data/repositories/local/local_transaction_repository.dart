import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as path;
import 'package:uuid/uuid.dart';

import '../../db.dart';
import '../../../utils/month_range.dart';
import '../../../utils/shared_ledger_picker_filter.dart';
import '../../../models/note_history.dart';
import '../../models/custom_field_values.dart';
import '../transaction_repository.dart';
import '../../../services/system/logger_service.dart';

/// 快捷记账「上次分类」的取数语句（P1-E R1）。
///
/// **为什么公开**：让 `quick_entry_last_category_test.dart` 能对**同一份 SQL**
/// 跑 `EXPLAIN QUERY PLAN`，断言命中 `idx_transactions_ledger_happened`。
/// 若测试自己另抄一份字面量，那么改这里就能悄悄骗过测试，索引退化会直接溜进 CI。
///
/// 生产代码请走 [LocalTransactionRepository.getLastUsedCategoryId]，不要直接用本串。
///
/// ⚠️ **`type` 过滤刻意不写进 WHERE，而是在 Dart 侧做** —— 这是上界成立的前提。
/// SQLite 的 `LIMIT` 约束的是**结果行数**，不是**扫描行数**：若写成
/// `WHERE ledger_id = ? AND type = ? ... LIMIT ?`，当最近若干笔都不是目标类型时，
/// SQLite 必须沿索引一路回表扫描到凑满 K 行匹配记录（或扫完整个索引）才返回 ——
/// 上界直接丢失，退化成与被否决的「全账本 GROUP BY」同量级的 O(N)。
/// 把 `type` 判在结果集之外，`LIMIT` 才真正等价于「只看最近 K 笔」。
///
/// （本设计文档 `prd/p1e_quick_entry_mode/design.md` 决策 1 最初给出的 SQL 就是
/// 带 `type = ?` 的版本，其「工作量上界 100 次索引项」的推理是错的；
/// 该 bug 由本方法的单测在实现当天测出，详见测试文件头注释。）
///
/// 语句要点：
/// - `ledger_id` 等值 + `happened_at DESC` 由复合索引一次满足；
/// - `id` 是 INTEGER PRIMARY KEY（即 rowid），索引倒序扫描天然给出
///   `happened_at DESC, id DESC`，无需额外排序步骤；
/// - `happened_at IS NOT NULL` 排除排序位置无意义的行（NULL 在 DESC 下落到末尾）。
const String quickEntryLastCategorySql = '''
SELECT type, category_id, category_sync_id_override
FROM transactions
WHERE ledger_id = ? AND happened_at IS NOT NULL
ORDER BY happened_at DESC, id DESC
LIMIT ?
''';

/// 本地交易Repository实现
/// 基于 Drift 数据库实现
class LocalTransactionRepository implements TransactionRepository {
  final PiggyDatabase db;

  LocalTransactionRepository(this.db);

  @override
  Stream<List<Transaction>> watchRecentTransactions({
    required int ledgerId,
    int limit = 20,
  }) {
    return (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .watch();
  }

  /// 读取账本的自定义每月起始日(1-28);账本缺失或查询异常时按 1(自然月)降级
  /// —— watch 流经 Stream.fromFuture 包裹,这里抛错会让流永久进 error 态。
  Future<int> _monthStartDayOf(int ledgerId) async {
    try {
      final row = await (db.select(db.ledgers)
            ..where((l) => l.id.equals(ledgerId)))
          .getSingleOrNull();
      return (row?.monthStartDay ?? 1).clamp(1, 28);
    } catch (_) {
      return 1;
    }
  }

  @override
  Stream<List<Transaction>> watchTransactionsInMonth({
    required int ledgerId,
    required DateTime month,
  }) {
    return Stream.fromFuture(_monthStartDayOf(ledgerId)).asyncExpand((sd) {
      final range = periodForLabel(month.year, month.month, sd);
      return (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(range.start) &
                t.happenedAt.isSmallerThanValue(range.end))
            ..orderBy([
              (t) => d.OrderingTerm(
                  expression: t.happenedAt, mode: d.OrderingMode.desc)
            ]))
          .watch();
    });
  }

  /// Drift `accounts` 表的两个 alias —— from 账户(`transactions.account_id`)
  /// 和 to 账户(`transactions.to_account_id`,转账场景)。Drift 同一张表
  /// JOIN 两次必须用 alias 区分,否则解析阶段就报"column reference ambiguous"。
  late final $AccountsTable _fromAccountTable =
      db.alias(db.accounts, 'from_account');
  late final $AccountsTable _toAccountTable =
      db.alias(db.accounts, 'to_account');

  /// 标准 tx + category + from/to account 三连 LEFT JOIN。所有 list 风格的
  /// watch 都走这个,避免重复写 join 表。
  List<d.Join<d.HasResultSet, dynamic>> _txJoins() => [
        d.leftOuterJoin(db.categories,
            db.categories.id.equalsExp(db.transactions.categoryId)),
        d.leftOuterJoin(_fromAccountTable,
            _fromAccountTable.id.equalsExp(db.transactions.accountId)),
        d.leftOuterJoin(_toAccountTable,
            _toAccountTable.id.equalsExp(db.transactions.toAccountId)),
      ];

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> watchTransactionsWithCategoryAll({
    int? ledgerId,
  }) {
    final select = db.select(db.transactions);
    if (ledgerId != null) {
      select.where((t) => t.ledgerId.equals(ledgerId));
    }
    select.orderBy([
      (t) => d.OrderingTerm(expression: t.happenedAt, mode: d.OrderingMode.desc)
    ]);
    final q = select.join(_txJoins());
    return _watchTxJoinWithSharedHydration(q);
  }

  /// §7 共享账本:把 Drift 主表 stream 跟 SharedLedger* 表更新合流,任一
  /// 变化都重跑 hydration 并 emit。
  ///
  /// 单纯用 q.watch() 时,Drift 只 track query 里 join 到的表(transactions /
  /// categories / accounts)。SharedLedger* 行被 WS handler 改了,stream 不会
  /// re-emit → tx tile 显示旧名字/图标,跟 picker 不一致。这里手动加两路
  /// db.tableUpdates(SharedLedger{Categories,Accounts}) 监听,触发时拿上一次
  /// Drift 结果重 hydrate 再 emit。
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> _watchTxJoinWithSharedHydration(d.JoinedSelectStatement q) {
    late StreamController<
        List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>> ctrl;
    StreamSubscription? txSub;
    StreamSubscription? sharedCatSub;
    StreamSubscription? sharedAccSub;
    List<d.TypedResult>? lastRows;

    Future<void> rehydrate() async {
      if (lastRows == null) return;
      final out = lastRows!
          .map((r) => (
                t: r.readTable(db.transactions),
                category: r.readTableOrNull(db.categories),
                account: r.readTableOrNull(_fromAccountTable),
                toAccount: r.readTableOrNull(_toAccountTable),
              ))
          .toList();
      final hydrated = await _hydrateSharedOverrides(out);
      if (!ctrl.isClosed) ctrl.add(hydrated);
    }

    ctrl = StreamController<
        List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>>(
      onListen: () {
        txSub = q.watch().listen((rows) {
          lastRows = rows;
          rehydrate();
        });
        sharedCatSub = db
            .tableUpdates(d.TableUpdateQuery.onTable(db.sharedLedgerCategories))
            .listen((_) => rehydrate());
        sharedAccSub = db
            .tableUpdates(d.TableUpdateQuery.onTable(db.sharedLedgerAccounts))
            .listen((_) => rehydrate());
      },
      onCancel: () async {
        await txSub?.cancel();
        await sharedCatSub?.cancel();
        await sharedAccSub?.cancel();
      },
    );
    return ctrl.stream;
  }

  /// §7 v25:Editor 在共享账本下记的 tx,主表 JOIN 不到 category / account 行,
  /// 字段是 null。这里二次查 SharedLedger{Categories,Accounts} 按 syncId 找,
  /// 转 synthetic 实体回填,UI 不用区分。
  ///
  /// 合并 category + from-account + to-account 三类 hydration:共用同一遍 rows
  /// 扫描;每类各一个 batch query。
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> _hydrateSharedOverrides(
    List<
            ({
              Transaction t,
              Category? category,
              Account? account,
              Account? toAccount
            })>
        rows,
  ) async {
    // 1. 收集所有需要反查的 syncId(分类 / from 账户 / to 账户)
    final catSyncIds = <String>{};
    final accSyncIds = <String>{};
    for (final r in rows) {
      final cOv = r.t.categorySyncIdOverride;
      if (r.category == null && cOv != null && cOv.isNotEmpty) {
        catSyncIds.add(cOv);
      }
      final aOv = r.t.accountSyncIdOverride;
      if (r.account == null && aOv != null && aOv.isNotEmpty) {
        accSyncIds.add(aOv);
      }
      final tOv = r.t.toAccountSyncIdOverride;
      if (r.toAccount == null && tOv != null && tOv.isNotEmpty) {
        accSyncIds.add(tOv);
      }
    }
    if (catSyncIds.isEmpty && accSyncIds.isEmpty) return rows;

    // 2. 批量查 SharedLedger* 镜像表
    final catBySyncId = <String, SharedLedgerCategory>{};
    if (catSyncIds.isNotEmpty) {
      final shared = await (db.select(db.sharedLedgerCategories)
            ..where((t) => t.syncId.isIn(catSyncIds.toList())))
          .get();
      for (final s in shared) {
        catBySyncId[s.syncId] = s;
      }
    }
    final accBySyncId = <String, SharedLedgerAccount>{};
    if (accSyncIds.isNotEmpty) {
      final shared = await (db.select(db.sharedLedgerAccounts)
            ..where((t) => t.syncId.isIn(accSyncIds.toList())))
          .get();
      for (final s in shared) {
        accBySyncId[s.syncId] = s;
      }
    }

    // 3. 回填到每行
    return rows.map((r) {
      Category? category = r.category;
      Account? account = r.account;
      Account? toAccount = r.toAccount;

      final cOv = r.t.categorySyncIdOverride;
      if (category == null && cOv != null && cOv.isNotEmpty) {
        final s = catBySyncId[cOv];
        if (s != null) category = _syntheticCategoryFromShared(s);
      }
      final aOv = r.t.accountSyncIdOverride;
      if (account == null && aOv != null && aOv.isNotEmpty) {
        final s = accBySyncId[aOv];
        if (s != null) account = _syntheticAccountFromShared(s);
      }
      final tOv = r.t.toAccountSyncIdOverride;
      if (toAccount == null && tOv != null && tOv.isNotEmpty) {
        final s = accBySyncId[tOv];
        if (s != null) toAccount = _syntheticAccountFromShared(s);
      }

      return (
        t: r.t,
        category: category,
        account: account,
        toAccount: toAccount,
      );
    }).toList();
  }

  /// SharedLedgerCategory → synthetic Category。用 syntheticIdForSyncId 而不
  /// 是 -1 — 否则所有共享分类都拿到同一个 id,首页点击分类详情时反查不到
  /// 目标 syncId,详情页 0 笔交易。改成 hash 派生后跟 picker / watchCategory
  /// 路径对齐。
  Category _syntheticCategoryFromShared(SharedLedgerCategory s) {
    return Category(
      id: syntheticIdForSyncId(s.syncId),
      name: s.name,
      kind: s.kind,
      icon: s.icon,
      sortOrder: s.sortOrder,
      parentId: null,
      level: s.level,
      iconType: s.iconType,
      customIconPath: s.iconType == 'custom' && s.iconCloudSha256 != null
          ? 'custom_icons/shared_${s.iconCloudSha256}.png'
          : null,
      communityIconId: null,
      syncId: s.syncId,
    );
  }

  /// SharedLedgerAccount → synthetic Account。跟 accountForTxProvider 同款映射。
  Account _syntheticAccountFromShared(SharedLedgerAccount s) {
    return Account(
      id: syntheticIdForSyncId(s.syncId),
      ledgerId: 0,
      name: s.name,
      type: s.accountType,
      currency: s.currency,
      initialBalance: s.initialBalance ?? 0.0,
      createdAt: null,
      updatedAt: null,
      sortOrder: 0,
      creditLimit: s.creditLimit,
      billingDay: s.billingDay,
      paymentDueDay: s.paymentDueDay,
      bankName: s.bankName,
      cardLastFour: s.cardLastFour,
      note: s.note,
      syncId: s.syncId,
      // SharedLedgerAccounts 镜像表没有 hidden 概念(隐藏是 Owner 侧个人状态,
      // 不随共享账本镜像同步),synthetic 账户固定按「未隐藏」处理。
      hidden: false,
    );
  }

  @override
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
  }) {
    return Stream.fromFuture(_monthStartDayOf(ledgerId)).asyncExpand((sd) {
      final range = periodForLabel(month.year, month.month, sd);
      final q = (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(range.start) &
                t.happenedAt.isSmallerThanValue(range.end))
            ..orderBy([
              (t) => d.OrderingTerm(
                  expression: t.happenedAt, mode: d.OrderingMode.desc)
            ]))
          .join(_txJoins());
      return _watchTxJoinWithSharedHydration(q);
    });
  }

  @override
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
  }) {
    final start = DateTime(year, 1, 1);
    final end = DateTime(year + 1, 1, 1);
    final q = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .join(_txJoins());
    return _watchTxJoinWithSharedHydration(q);
  }

  @override
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
  }) {
    final base = (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.type.equals(type) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .join(_txJoins());
    if (categoryId == null) {
      base.where(db.transactions.categoryId.isNull());
    } else {
      base.where(db.transactions.categoryId.equals(categoryId));
    }
    return _watchTxJoinWithSharedHydration(base);
  }

  static const _uuid = Uuid();

  @override
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
    int? recurringId,
    String? categorySyncIdOverride,
    String? accountSyncIdOverride,
    String? toAccountSyncIdOverride,
    bool excludeFromStats = false,
    bool excludeFromBudget = false,
    String? currencyCode,
    double? nativeAmount,
    double? originalAmount,
    Map<String, dynamic>? customValues,
  }) async {
    // v30:子仓收「已定值」直写;带折算的兜底(查账户/汇率)在聚合
    // LocalRepository 包装层(子仓拿不到汇率)。
    // v45:原始金额未填则**落库兜底为记账金额** —— 保证每条明细都有原始
    // 金额(差异 0),而不是留 NULL 靠读取侧回落。
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId,
          type: type,
          amount: amount,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          toAccountId: d.Value(toAccountId),
          happenedAt: d.Value(happenedAt),
          note: d.Value(note),
          syncId: d.Value(syncId ?? _uuid.v4()),
          recurringId: d.Value(recurringId),
          categorySyncIdOverride: d.Value(categorySyncIdOverride),
          accountSyncIdOverride: d.Value(accountSyncIdOverride),
          toAccountSyncIdOverride: d.Value(toAccountSyncIdOverride),
          excludeFromStats: d.Value(excludeFromStats),
          excludeFromBudget: d.Value(excludeFromBudget),
          currencyCode: d.Value(currencyCode),
          nativeAmount: d.Value(nativeAmount),
          originalAmount: d.Value(originalAmount ?? amount),
          // v46:空/null → 列写 NULL(该笔无自定义字段值)。
          customValuesJson: d.Value(CustomFieldValueCodec.encode(customValues)),
        ));
  }

  @override
  Future<int> insertTransactionsBatch(
    List<TransactionsCompanion> items, {
    bool recordChanges = true,
  }) async {
    // 子仓库不挂 changeTracker,recordChanges 参数对它无作用 — 真正的 record
    // 在 LocalRepository wrapper 那一层。这里保留参数只是为了接口一致。
    if (items.isEmpty) return 0;
    final effectiveItems = items.map((item) {
      if (item.syncId == const d.Value.absent() || item.syncId.value == null) {
        return item.copyWith(syncId: d.Value(_uuid.v4()));
      }
      return item;
    }).toList();
    return db.transaction(() async {
      await db.batch((b) => b.insertAll(db.transactions, effectiveItems));
      return effectiveItems.length;
    });
  }

  @override
  Future<List<int>> insertTransactionsBatchWithRelations({
    required List<TransactionsCompanion> transactions,
    Map<int, List<int>> tagIdsByIndex = const {},
    Map<int, List<BatchAttachmentData>> attachmentsByIndex = const {},
    bool recordChanges = true,
  }) async {
    if (transactions.isEmpty) return const [];
    // 预填充 syncId — batch insertAll 不返回 row id,必须靠 syncId 反查。
    final effective = transactions.map((tx) {
      if (tx.syncId == const d.Value.absent() || tx.syncId.value == null) {
        return tx.copyWith(syncId: d.Value(_uuid.v4()));
      }
      return tx;
    }).toList();

    return db.transaction(() async {
      // 1. 一次性 batch insert 所有 tx
      await db.batch((b) => b.insertAll(db.transactions, effective));

      // 2. SELECT 回拿 (id, syncId) 映射,按 effective 顺序对齐
      final syncIds = effective.map((c) => c.syncId.value!).toList();
      final inserted = await (db.select(db.transactions)
            ..where((t) => t.syncId.isIn(syncIds)))
          .get();
      final idBySyncId = <String, int>{
        for (final tx in inserted)
          if (tx.syncId != null) tx.syncId!: tx.id,
      };
      final ids = syncIds.map((s) => idBySyncId[s]!).toList();

      // 3. batch insert tag 关联 — 调用方需保证 tagIds 已去重,本方法不查重
      //   (TransactionTags 表没 UNIQUE 约束,select 防重就是 N+1 来源)
      if (tagIdsByIndex.isNotEmpty) {
        await db.batch((b) {
          for (final entry in tagIdsByIndex.entries) {
            final txId = ids[entry.key];
            for (final tagId in entry.value) {
              b.insert(
                db.transactionTags,
                TransactionTagsCompanion.insert(
                  transactionId: txId,
                  tagId: tagId,
                ),
              );
            }
          }
        });
      }

      // 4. batch insert attachment 元数据(文件本身在另一个流程下载)
      if (attachmentsByIndex.isNotEmpty) {
        await db.batch((b) {
          for (final entry in attachmentsByIndex.entries) {
            final txId = ids[entry.key];
            for (final att in entry.value) {
              b.insert(
                db.transactionAttachments,
                TransactionAttachmentsCompanion.insert(
                  transactionId: txId,
                  fileName: att.fileName,
                  originalName: d.Value(att.originalName),
                  fileSize: d.Value(att.fileSize),
                  width: d.Value(att.width),
                  height: d.Value(att.height),
                  sortOrder: d.Value(att.sortOrder),
                  cloudFileId: d.Value(att.cloudFileId),
                  cloudSha256: d.Value(att.cloudSha256),
                  localSha256: d.Value(att.localSha256),
                ),
              );
            }
          }
        });
      }

      return ids;
    });
  }

  @override
  Future<void> updateTransaction({
    required int id,
    required String type,
    required double amount,
    int? categoryId,
    String? note,
    DateTime? happenedAt,
    dynamic accountId,
    String? categorySyncIdOverride,
    String? accountSyncIdOverride,
    String? toAccountSyncIdOverride,
    bool? excludeFromStats,
    bool? excludeFromBudget,
    String? currencyCode,
    double? nativeAmount,
    dynamic originalAmount,
    Map<String, dynamic>? customValues,
  }) async {
    // 处理 accountId 参数
    final d.Value<int?> accountIdValue;
    if (accountId == null) {
      accountIdValue = const d.Value.absent();
    } else if (accountId is d.Value<int?>) {
      accountIdValue = accountId;
    } else {
      accountIdValue = d.Value(accountId as int?);
    }

    // v45 原始金额三态(与 accountId 同模式):dart null = absent(不改动);
    // d.Value<double?>(null) = 用户清空;d.Value(x) = 写入。批量改备注/改分类
    // 等非金额路径不传该参数,绝不能顺手清零原始金额。
    // 清空 → 兜底写本次记账金额(产品口径:每条明细都有原始金额)。
    final d.Value<double?> originalAmountValue;
    if (originalAmount == null) {
      originalAmountValue = const d.Value.absent();
    } else if (originalAmount is d.Value<double?>) {
      originalAmountValue = originalAmount.value == null
          ? d.Value(amount)
          : originalAmount;
    } else {
      originalAmountValue = d.Value(originalAmount as double?);
    }

    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        type: d.Value(type),
        amount: d.Value(amount),
        categoryId: d.Value(categoryId),
        note: d.Value(note),
        happenedAt:
            happenedAt != null ? d.Value(happenedAt) : const d.Value.absent(),
        accountId: accountIdValue,
        categorySyncIdOverride: d.Value(categorySyncIdOverride),
        accountSyncIdOverride: d.Value(accountSyncIdOverride),
        toAccountSyncIdOverride: d.Value(toAccountSyncIdOverride),
        // null = 不更新(保持原值);非 null = 显式写入
        excludeFromStats: excludeFromStats == null
            ? const d.Value.absent()
            : d.Value(excludeFromStats),
        excludeFromBudget: excludeFromBudget == null
            ? const d.Value.absent()
            : d.Value(excludeFromBudget),
        // v30:null = 不更新(保持原快照);非 null = 显式写入
        currencyCode: currencyCode == null
            ? const d.Value.absent()
            : d.Value(currencyCode),
        nativeAmount: nativeAmount == null
            ? const d.Value.absent()
            : d.Value(nativeAmount),
        originalAmount: originalAmountValue,
        // v46 自定义字段值三态:null = 不改动(批量改备注/改分类等路径不得
        // 顺手清空);空 map = 清空(encode → null → 列写 NULL);非空 = 覆盖。
        customValuesJson: customValues == null
            ? const d.Value.absent()
            : d.Value(CustomFieldValueCodec.encode(customValues)),
      ),
    );
  }

  /// 共享账本:在本地标记 tx 的创建人 / 编辑人,让 UI 能立即展示头像。
  /// 服务端 push.py 已经会兜底注入 userId,但本地写入路径(addTransaction /
  /// updateTransaction)不知道 currentUser 是谁,需要 UI 层在写完后调一下这个
  /// 方法。
  ///   - isCreate=true:同时写 createdByUserId + lastEditedByUserId(新建场景)
  ///   - isCreate=false:只写 lastEditedByUserId(编辑场景,createdByUserId
  ///     维持 first-write-wins)
  Future<void> markTxAuthor({
    required int txId,
    required String userId,
    required bool isCreate,
  }) async {
    await (db.update(db.transactions)..where((t) => t.id.equals(txId))).write(
      TransactionsCompanion(
        createdByUserId: isCreate ? d.Value(userId) : const d.Value.absent(),
        lastEditedByUserId: d.Value(userId),
      ),
    );
  }

  @override
  Future<void> deleteTransaction(int id) async {
    // 先查出整行:syncId 用于级联清理 transaction_tag_overrides(该表用
    // transactionSyncId 文本列作主键,不能按 int id 删)。不查则删除后留下孤儿行,
    // 共享账本 Editor 视角 _hydrateSharedOverridesFull 会挂载幽灵标签。
    final tx = await (db.select(db.transactions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (tx == null) return;
    await _deleteTransactionCascade(tx);
  }

  /// 彻底删除一笔交易的级联：标签关联 → 附件(行+磁盘文件) → 共享标签
  /// override → 交易本体。[deleteTransaction] 与回收站的 purge 共用这一份，
  /// 避免"两条删除路径清理范围不一致"（历史上批量删除就漏过文件清理）。
  ///
  /// 传入 [tx] 而不是 id：回收站里的行已经不在 transactions 表，只能由
  /// payload 反序列化出来再交给我们。
  Future<void> _deleteTransactionCascade(Transaction tx) async {
    final id = tx.id;
    final syncId = tx.syncId;

    // 先删除关联的标签
    await (db.delete(db.transactionTags)
          ..where((tt) => tt.transactionId.equals(id)))
        .go();

    // 再删除关联的附件
    await _deleteAttachmentsForTransaction(id);

    // 级联清理共享标签 override(按 syncId 删)
    if (syncId != null && syncId.isNotEmpty) {
      await (db.delete(db.transactionTagOverrides)
            ..where((o) => o.transactionSyncId.equals(syncId)))
          .go();
    }

    // 最后删除交易记录
    await (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
  }

  /// 删除交易关联的所有附件（包括文件和数据库记录）
  Future<void> _deleteAttachmentsForTransaction(int transactionId) async {
    try {
      // 获取该交易的所有附件
      final attachments = await (db.select(db.transactionAttachments)
            ..where((a) => a.transactionId.equals(transactionId)))
          .get();

      if (attachments.isEmpty) return;

      // 获取附件存储目录
      final appDir = await getApplicationDocumentsDirectory();
      final attachmentDir = Directory('${appDir.path}/attachments');
      final cacheDir = await getTemporaryDirectory();
      final thumbDir = Directory('${cacheDir.path}/attachment_thumbs');

      final fileNames = attachments.map((a) => a.fileName).toSet();

      // 先删数据库记录,再按引用计数删物理文件:多笔共享同一文件时,仅当没有
      // 其他行引用该 fileName 才删物理文件,避免误删别笔还在用的图。
      await (db.delete(db.transactionAttachments)
            ..where((a) => a.transactionId.equals(transactionId)))
          .go();

      // 一次查所有 fileName 的剩余引用(批量,避免逐个 N+1 SELECT)
      final stillReferenced = <String>{};
      if (fileNames.isNotEmpty) {
        final refs = await (db.select(db.transactionAttachments)
              ..where((a) => a.fileName.isIn(fileNames.toList())))
            .get();
        for (final r in refs) {
          stillReferenced.add(r.fileName);
        }
      }

      for (final fileName in fileNames) {
        if (stillReferenced.contains(fileName)) {
          continue; // 仍有其他行引用,保留物理文件
        }

        final file = File('${attachmentDir.path}/$fileName');
        if (await file.exists()) {
          await file.delete();
          logger.debug('LocalTransactionRepository', '删除附件文件: $fileName');
        }
        final thumbName =
            '${path.basenameWithoutExtension(fileName)}_thumb.jpg';
        final thumbFile = File('${thumbDir.path}/$thumbName');
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }

      logger.info('LocalTransactionRepository',
          '已删除交易 $transactionId 的 ${attachments.length} 个附件');
    } catch (e, stackTrace) {
      logger.error('LocalTransactionRepository', '删除交易附件失败', e, stackTrace);
      // 不抛出异常，继续删除交易
    }
  }

  // --- v44 回收站（F1）---------------------------------------------------

  @override
  Future<bool> softDeleteTransaction(int id) async {
    final tx = await (db.select(db.transactions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
    if (tx == null) return false;

    // 只搬交易本体：transaction_tags / transaction_attachments /
    // transaction_tag_overrides 原地保留，恢复才是无损的，且附件文件不会被
    // 30 天孤儿 GC 回收（GC 以 transaction_attachments 行为引用依据）。
    await db.transaction(() async {
      await db.into(db.deletedTransactions).insert(DeletedTransactionsCompanion(
            txId: d.Value(tx.id),
            ledgerId: d.Value(tx.ledgerId),
            syncId: d.Value(tx.syncId),
            happenedAt: d.Value(tx.happenedAt),
            deletedAt: d.Value(DateTime.now()),
            payload: d.Value(jsonEncode(tx.toJson())),
          ));
      await (db.delete(db.transactions)..where((t) => t.id.equals(id))).go();
    });
    logger.info('LocalTransactionRepository', '交易 $id 已移入回收站');
    return true;
  }

  @override
  Future<int> softDeleteTransactions(List<int> ids) async {
    if (ids.isEmpty) return 0;
    return db.transaction(() async {
      final rows = await (db.select(db.transactions)
            ..where((t) => t.id.isIn(ids)))
          .get();
      if (rows.isEmpty) return 0;
      final now = DateTime.now();
      await db.batch((b) {
        for (final tx in rows) {
          b.insert(
            db.deletedTransactions,
            DeletedTransactionsCompanion(
              txId: d.Value(tx.id),
              ledgerId: d.Value(tx.ledgerId),
              syncId: d.Value(tx.syncId),
              happenedAt: d.Value(tx.happenedAt),
              deletedAt: d.Value(now),
              payload: d.Value(jsonEncode(tx.toJson())),
            ),
          );
        }
      });
      await (db.delete(db.transactions)..where((t) => t.id.isIn(ids))).go();
      return rows.length;
    });
  }

  @override
  Future<List<DeletedTransaction>> getDeletedTransactions(
      {int? ledgerId}) async {
    final q = db.select(db.deletedTransactions)
      ..orderBy([(t) => d.OrderingTerm.desc(t.deletedAt)]);
    if (ledgerId != null) q.where((t) => t.ledgerId.equals(ledgerId));
    return q.get();
  }

  @override
  Future<bool> restoreDeletedTransaction(int txId) async {
    final row = await (db.select(db.deletedTransactions)
          ..where((t) => t.txId.equals(txId)))
        .getSingleOrNull();
    if (row == null) return false;

    // 原 id 必须还能用：transaction_tags / transaction_attachments 是按这个
    // int id 挂着的，换个 id 落回去就等于把标签和附件丢在原地。id 被占
    // （正常路径下 AUTOINCREMENT 不会复用，防御的是导入/换库这类非常规来源）
    // 时拒绝恢复，宁可让用户先腾出位置，也不做"恢复成功但数据错位"。
    final clash = await (db.select(db.transactions)
          ..where((t) => t.id.equals(txId)))
        .getSingleOrNull();
    if (clash != null) {
      logger.warning('LocalTransactionRepository', '回收站恢复被拒: 交易 id=$txId 已被占用');
      return false;
    }

    final tx =
        Transaction.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
    await db.transaction(() async {
      await db.into(db.transactions).insert(tx);
      await (db.delete(db.deletedTransactions)
            ..where((t) => t.txId.equals(txId)))
          .go();
    });
    logger.info('LocalTransactionRepository', '交易 $txId 已从回收站恢复');
    return true;
  }

  @override
  Future<void> purgeDeletedTransaction(int txId) async {
    final row = await (db.select(db.deletedTransactions)
          ..where((t) => t.txId.equals(txId)))
        .getSingleOrNull();
    if (row == null) return;
    final tx =
        Transaction.fromJson(jsonDecode(row.payload) as Map<String, dynamic>);
    // 级联与彻底删除共用一份实现（标签行 / 附件行+磁盘文件 / override）。
    await db.transaction(() async {
      await _deleteTransactionCascade(tx);
      await (db.delete(db.deletedTransactions)
            ..where((t) => t.txId.equals(txId)))
          .go();
    });
  }

  @override
  Future<int> purgeDeletedTransactionsForLedger(int ledgerId) async {
    final rows = await (db.select(db.deletedTransactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
    for (final row in rows) {
      await purgeDeletedTransaction(row.txId);
    }
    return rows.length;
  }

  @override
  Future<Transaction?> getTransactionById(int id) async {
    return await (db.select(db.transactions)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  @override
  Future<bool> existsRecurringInstance({
    required int recurringId,
    required DateTime happenedAt,
  }) async {
    // REC-01/02：按本地日历日匹配而非精确时刻。JSON 导出 .toUtc()/导入
    // .toLocal() 跨时区恢复时精确毫秒必然失配；daily/weekly 首笔实例也可能
    // 带 startDate 的非 0 点时刻。单规则实例量有限（数千级），取回后内存比对。
    final rows = await (db.select(db.transactions)
          ..where((t) => t.recurringId.equals(recurringId)))
        .get();
    if (rows.isEmpty) return false;
    final key =
        TransactionRepository.recurringInstanceKey(recurringId, happenedAt);
    for (final t in rows) {
      final rid = t.recurringId;
      if (rid == null) continue;
      if (TransactionRepository.recurringInstanceKey(rid, t.happenedAt) ==
          key) {
        return true;
      }
    }
    return false;
  }

  @override
  Future<Map<String, List<RecurringInstanceFingerprint>>>
      getRecurringInstanceDetails(Iterable<int> recurringIds) async {
    final ids = recurringIds.toSet();
    if (ids.isEmpty) return {};
    final rows = await (db.select(db.transactions)
          ..where((t) => t.recurringId.isIn(ids)))
        .get();
    final result = <String, List<RecurringInstanceFingerprint>>{};
    for (final t in rows) {
      final rid = t.recurringId;
      if (rid == null) continue;
      result
          .putIfAbsent(
              TransactionRepository.recurringInstanceKey(rid, t.happenedAt),
              () => [])
          .add((
        syncId: t.syncId,
        amount: t.amount,
        note: t.note,
      ));
    }
    return result;
  }

  @override
  Future<int> insertTransactionCompanion(
    TransactionsCompanion item, {
    bool recordChanges = true,
  }) async {
    // 子仓库不挂 changeTracker,recordChanges 仅为接口一致保留。
    final effective =
        item.syncId == const d.Value.absent() || item.syncId.value == null
            ? item.copyWith(syncId: d.Value(_uuid.v4()))
            : item;
    return await db.into(db.transactions).insert(effective);
  }

  @override
  Stream<
      List<
          ({
            Transaction t,
            Category? category,
            Account? account,
            Account? toAccount
          })>> transactionsWithCategoryAll({
    int? ledgerId,
  }) =>
      watchTransactionsWithCategoryAll(ledgerId: ledgerId);

  @override
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
  }) async {
    final q = (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .join(_txJoins());
    final rows = await q.get();
    final out = rows
        .map((r) => (
              t: r.readTable(db.transactions),
              category: r.readTableOrNull(db.categories),
              account: r.readTableOrNull(_fromAccountTable),
              toAccount: r.readTableOrNull(_toAccountTable),
            ))
        .toList();
    return _hydrateSharedOverrides(out);
  }

  @override
  Future<List<NoteHistoryEntry>> getNoteHistory({
    required int ledgerId,
    int? categoryId,
    String? categorySyncId,
    required NoteHistorySort sort,
    int limit = 20,
  }) async {
    // 备注历史直接基于已保存交易聚合，避免维护会与同步数据脱节的缓存副本。
    final effectiveLimit = limit.clamp(1, 100).toInt();
    final whereClauses = <String>[
      'ledger_id = ?',
      'note IS NOT NULL',
      "TRIM(note) <> ''",
    ];
    final variables = <d.Variable>[d.Variable.withInt(ledgerId)];

    // 共享账本 Owner 分类以 syncId override 落库，优先使用它过滤。
    if (categorySyncId != null && categorySyncId.isNotEmpty) {
      whereClauses.add('category_sync_id_override = ?');
      variables.add(d.Variable.withString(categorySyncId));
    } else if (categoryId != null) {
      whereClauses.add('category_id = ?');
      variables.add(d.Variable.withInt(categoryId));
    }

    final orderBy = sort == NoteHistorySort.frequency
        ? 'usage_count DESC, last_used_at DESC, normalized_note ASC'
        : 'last_used_at DESC, usage_count DESC, normalized_note ASC';
    variables.add(d.Variable.withInt(effectiveLimit));

    final rows = await db
        .customSelect(
          '''
      SELECT
        TRIM(note) AS normalized_note,
        COUNT(*) AS usage_count,
        MAX(happened_at) AS last_used_at
      FROM transactions
      WHERE ${whereClauses.join(' AND ')}
      GROUP BY TRIM(note)
      ORDER BY $orderBy
      LIMIT ?
      ''',
          variables: variables,
          readsFrom: {db.transactions},
        )
        .get();

    return rows.map((row) {
      // 聚合列来自 SQLite，统一转换保证 Android、iOS 与桌面端返回类型一致。
      final usageCount = row.data['usage_count'];
      final count = usageCount is BigInt
          ? usageCount.toInt()
          : usageCount is num
              ? usageCount.toInt()
              : 0;
      return NoteHistoryEntry(
        note: row.read<String>('normalized_note'),
        usageCount: count,
      );
    }).toList();
  }

  @override
  Future<int?> getLastUsedCategoryId({
    required int ledgerId,
    required String kind,
    int scanLimit = 100,
  }) async {
    // 与 getNoteHistory 同一取径：直接从已保存交易派生，不维护可能与同步脱节的缓存副本。
    //
    // 为什么是「索引倒序游走 + K 上限」而不是 GROUP BY 全账本聚合：
    // `ledger_id` 等值 + `happened_at` 倒序由 idx_transactions_ledger_happened
    // 一次满足，窗口恒定 = 最近 K 笔（K 次索引项 + 至多 K 次回表）。
    // ⚠️ type 必须在 Dart 侧判，不能进 WHERE —— 否则 LIMIT 不再约束扫描量，
    // 上界会丢失（理由见 [quickEntryLastCategorySql] 的文档）。
    final limit = scanLimit.clamp(1, 500).toInt();
    final rows = await db.customSelect(
      quickEntryLastCategorySql,
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<int>(limit),
      ],
      readsFrom: {db.transactions},
    ).get();

    for (final row in rows) {
      // 转账与另一类型直接跳过：窗口内它们不占用记忆位。
      if (row.data['type'] != kind) continue;

      final localId = row.data['category_id'];
      if (localId is num) return localId.toInt();

      final override = row.data['category_sync_id_override'];
      // 共享账本 Owner 分类以 syncId override 落库，读取时派生负数 synthetic id。
      // 绝不持久化该值（见方法文档）。
      if (override is String && override.isNotEmpty) {
        return syntheticIdForSyncId(override);
      }

      // 两者皆空 = 这笔没有分类。**不能提前中断** ——
      // AC-R1 #4 要求继续往前找最近一笔「带分类」的交易。
    }
    return null;
  }

  @override
  Future<int> countByTypeInRange({
    required int ledgerId,
    required String type,
    required DateTime start,
    required DateTime end,
  }) async {
    final row = await db.customSelect(
      'SELECT COUNT(*) AS c FROM transactions WHERE ledger_id = ?1 AND type = ?2 AND happened_at >= ?3 AND happened_at < ?4',
      variables: [
        d.Variable<int>(ledgerId),
        d.Variable<String>(type),
        d.Variable<DateTime>(start),
        d.Variable<DateTime>(end),
      ],
      readsFrom: {db.transactions},
    ).getSingle();
    final v = row.data['c'];
    if (v is int) return v;
    if (v is BigInt) return v.toInt();
    if (v is num) return v.toInt();
    return 0;
  }

  @override
  Future<List<Transaction>> getTransactionsByLedger(int ledgerId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .get();
  }

  @override
  Future<List<Transaction>> getTransactionsByLedgerInRange({
    required int ledgerId,
    required DateTime start,
    required DateTime end,
  }) async {
    return await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBiggerOrEqualValue(start) &
              t.happenedAt.isSmallerThanValue(end))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .get();
  }

  @override
  Future<List<Transaction>> getRecentTransactions(
    int ledgerId, {
    int limit = 10,
  }) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(limit))
        .get();
  }

  @override
  Future<void> updateTransactionFields({
    required int id,
    dynamic accountId,
    dynamic toAccountId,
    String? accountSyncIdOverride,
    String? toAccountSyncIdOverride,
    bool writeAccountSyncIdOverride = false,
    bool writeToAccountSyncIdOverride = false,
  }) async {
    // accountId / toAccountId 接受 null(absent / 不更新)、int(直接写)、
    // `d.Value<int?>`(显式 null 清空)三种语义,跟 updateTransaction 对齐。
    final d.Value<int?> accountIdValue;
    if (accountId == null) {
      accountIdValue = const d.Value.absent();
    } else if (accountId is d.Value<int?>) {
      accountIdValue = accountId;
    } else {
      accountIdValue = d.Value(accountId as int?);
    }
    final d.Value<int?> toAccountIdValue;
    if (toAccountId == null) {
      toAccountIdValue = const d.Value.absent();
    } else if (toAccountId is d.Value<int?>) {
      toAccountIdValue = toAccountId;
    } else {
      toAccountIdValue = d.Value(toAccountId as int?);
    }
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(
        accountId: accountIdValue,
        toAccountId: toAccountIdValue,
        // override 写入只在调用方明确要求时才动(否则保留 Drift 老值),
        // 区别于 dart null 默认行为(=absent)。共享账本 Editor 场景:
        // synthetic 账户 → accountId=null + 这里写 syncIdOverride。
        accountSyncIdOverride: writeAccountSyncIdOverride
            ? d.Value(accountSyncIdOverride)
            : const d.Value.absent(),
        toAccountSyncIdOverride: writeToAccountSyncIdOverride
            ? d.Value(toAccountSyncIdOverride)
            : const d.Value.absent(),
      ),
    );
  }

  @override
  Future<Transaction?> getFirstTransactionByLedger(int ledgerId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.asc)
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<Transaction?> getLastTransactionByLedger(int ledgerId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ])
          ..limit(1))
        .getSingleOrNull();
  }

  @override
  Future<DateTime?> getEarliestTransactionDate() async {
    // 排除以成员身份加入的共享账本(is_shared=1 且 my_role!='owner')——与资产统计 /
    // getAccountDailyBalances 同口径(#333),否则趋势「全部」起点会被别人账本的
    // 早期流水拉前。自己 Own 的共享账本不排除。
    final sharedRows = await (db.selectOnly(db.ledgers)
          ..addColumns([db.ledgers.id])
          ..where(db.ledgers.isShared.equals(true) &
              db.ledgers.myRole.equals('owner').not()))
        .get();
    final sharedIds = sharedRows.map((r) => r.read(db.ledgers.id)!).toList();
    final row = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.isNotIn(sharedIds))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.asc)
          ])
          ..limit(1))
        .getSingleOrNull();
    return row?.happenedAt;
  }

  @override
  Future<void> updateTransactionLedger({
    required int id,
    required int ledgerId,
  }) async {
    await (db.update(db.transactions)..where((t) => t.id.equals(id))).write(
      TransactionsCompanion(ledgerId: d.Value(ledgerId)),
    );
  }

  // ==================== 日历功能相关 ====================

  @override
  Future<Map<String, (double, double)>> getDailyTotalsByMonth({
    required int ledgerId,
    required DateTime month,
  }) async {
    final startDate = DateTime(month.year, month.month, 1);
    final endDate = DateTime(month.year, month.month + 1, 0, 23, 59, 59);

    logger.debug('LocalTransactionRepository',
        'dailyTotalsByMonth 查询: ledgerId=$ledgerId, 范围: $startDate ~ $endDate');

    // 审计 U13：移除查询热路径上的调试 print 与仅为打印服务的
    // count/sample 预查询（每次打开月视图都会白跑两趟 SQL）。

    // SQL 聚合查询
    // Drift 存储 DateTime 为 Unix timestamp（秒），直接使用 strftime
    final query = '''
      SELECT
        strftime('%Y-%m-%d', happened_at, 'unixepoch', 'localtime') as date,
        SUM(CASE WHEN type = 'income' AND exclude_from_stats = 0 THEN COALESCE(native_amount, amount) ELSE 0 END) as income,
        SUM(CASE WHEN type = 'expense' AND exclude_from_stats = 0 THEN COALESCE(native_amount, amount) ELSE 0 END) as expense
      FROM transactions
      WHERE ledger_id = ?
        AND happened_at >= ?
        AND happened_at <= ?
      GROUP BY date
      ORDER BY date DESC
    ''';

    final results = await db.customSelect(
      query,
      variables: [
        d.Variable.withInt(ledgerId),
        d.Variable.withDateTime(startDate),
        d.Variable.withDateTime(endDate),
      ],
    ).get();

    final map = <String, (double, double)>{};
    for (final row in results) {
      final date = row.read<String?>('date');
      if (date == null) continue; // 跳过null日期
      // SQL 聚合值为 NULL（该日无收入/支出）时兜 0，而不是让非空
      // `read<double>` 直接抛类型错误。
      final income = row.read<double?>('income') ?? 0.0;
      final expense = row.read<double?>('expense') ?? 0.0;
      map[date] = (income, expense);
    }

    logger.debug(
        'LocalTransactionRepository', 'dailyTotalsByMonth 结果: ${map.length} 天');
    return map;
  }

  @override
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
  }) async {
    final startOfDay = DateTime(date.year, date.month, date.day);
    final endOfDay = DateTime(date.year, date.month, date.day, 23, 59, 59);

    // 查询当天的所有交易
    final transactions = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBetweenValues(startOfDay, endOfDay))
          ..orderBy([
            (t) => d.OrderingTerm(
                expression: t.happenedAt, mode: d.OrderingMode.desc)
          ]))
        .get();

    if (transactions.isEmpty) {
      return [];
    }

    final txIds = transactions.map((t) => t.id).toList();

    // 批量查询分类(一次 isIn,避免逐条 N+1)
    final categoryIds = transactions
        .where((t) => t.categoryId != null)
        .map((t) => t.categoryId!)
        .toSet();
    final categoriesMap = <int, Category>{};
    if (categoryIds.isNotEmpty) {
      final categories = await (db.select(db.categories)
            ..where((c) => c.id.isIn(categoryIds.toList())))
          .get();
      for (final category in categories) {
        categoriesMap[category.id] = category;
      }
    }

    // 批量查询标签
    final tagsMap = <int, List<Tag>>{};
    final tagRelations = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.isIn(txIds)))
        .get();

    final tagIds = tagRelations.map((r) => r.tagId).toSet();
    if (tagIds.isNotEmpty) {
      final tags = await (db.select(db.tags)
            ..where((t) => t.id.isIn(tagIds.toList())))
          .get();
      final tagsById = {for (var tag in tags) tag.id: tag};

      for (final rel in tagRelations) {
        final tag = tagsById[rel.tagId];
        if (tag != null) {
          tagsMap.putIfAbsent(rel.transactionId, () => []).add(tag);
        }
      }
    }

    // 批量查询附件
    final attachmentsMap = <int, List<TransactionAttachment>>{};
    final attachments = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.isIn(txIds)))
        .get();
    for (final attachment in attachments) {
      attachmentsMap
          .putIfAbsent(attachment.transactionId, () => [])
          .add(attachment);
    }

    // 批量查询账户
    final accountIds = transactions
        .where((t) => t.accountId != null)
        .map((t) => t.accountId!)
        .toSet();
    final accountsMap = <int, Account>{};
    if (accountIds.isNotEmpty) {
      final accounts = await (db.select(db.accounts)
            ..where((a) => a.id.isIn(accountIds.toList())))
          .get();
      for (final account in accounts) {
        accountsMap[account.id] = account;
      }
    }

    // 组装结果
    final raw = transactions.map((tx) {
      return (
        t: tx,
        category: tx.categoryId != null ? categoriesMap[tx.categoryId] : null,
        tags: tagsMap[tx.id] ?? [],
        attachments: attachmentsMap[tx.id] ?? [],
        account: tx.accountId != null ? accountsMap[tx.accountId] : null,
      );
    }).toList();
    return _hydrateSharedOverridesFull(raw);
  }

  /// §7 共享账本统一 hydration:
  /// - tx.categoryId 为空 + categorySyncIdOverride 非空 → 查 SharedLedgerCategories
  ///   构造 synthetic Category(同 _hydrateSharedCategoryOverrides)
  /// - tx.accountId 为空 + accountSyncIdOverride 非空 → 查 SharedLedgerAccounts
  ///   构造 synthetic Account
  /// - tx.tagSyncIdsOverride 不为空 → 查 TransactionTagOverrides → SharedLedgerTags
  ///   union 到 tags 列表(synthetic id<0)
  ///
  /// 日历页 / 详情页等任何返回 tx + category + tags + account 完整 tuple 的查询
  /// 都用这个 helper 兜底,跟 transaction_list 走 _hydrateSharedCategoryOverrides
  /// 一致。
  Future<
      List<
          ({
            Transaction t,
            Category? category,
            List<Tag> tags,
            List<TransactionAttachment> attachments,
            Account? account,
          })>> _hydrateSharedOverridesFull(
    List<
            ({
              Transaction t,
              Category? category,
              List<Tag> tags,
              List<TransactionAttachment> attachments,
              Account? account,
            })>
        rows,
  ) async {
    if (rows.isEmpty) return rows;

    // 收集需要 hydrate 的 syncId / tx.syncId
    final catSyncIds = <String>{};
    final accSyncIds = <String>{};
    final txSyncIds = <String>{};
    for (final r in rows) {
      final cov = r.t.categorySyncIdOverride;
      if (r.category == null && cov != null && cov.isNotEmpty) {
        catSyncIds.add(cov);
      }
      final aov = r.t.accountSyncIdOverride;
      if (r.account == null && aov != null && aov.isNotEmpty) {
        accSyncIds.add(aov);
      }
      if (r.t.syncId != null && r.t.syncId!.isNotEmpty) {
        txSyncIds.add(r.t.syncId!);
      }
    }

    // 批量查共享分类
    final sharedCatBySyncId = <String, SharedLedgerCategory>{};
    if (catSyncIds.isNotEmpty) {
      final list = await (db.select(db.sharedLedgerCategories)
            ..where((t) => t.syncId.isIn(catSyncIds.toList())))
          .get();
      for (final s in list) {
        sharedCatBySyncId[s.syncId] = s;
      }
    }

    // 批量查共享账户
    final sharedAccBySyncId = <String, SharedLedgerAccount>{};
    if (accSyncIds.isNotEmpty) {
      final list = await (db.select(db.sharedLedgerAccounts)
            ..where((t) => t.syncId.isIn(accSyncIds.toList())))
          .get();
      for (final s in list) {
        sharedAccBySyncId[s.syncId] = s;
      }
    }

    // 批量查 tag overrides + shared tags
    final tagOverridesByTxSyncId = <String, List<String>>{};
    final sharedTagBySyncId = <String, SharedLedgerTag>{};
    if (txSyncIds.isNotEmpty) {
      final overrides = await (db.select(db.transactionTagOverrides)
            ..where((t) => t.transactionSyncId.isIn(txSyncIds.toList())))
          .get();
      for (final ov in overrides) {
        tagOverridesByTxSyncId
            .putIfAbsent(ov.transactionSyncId, () => [])
            .add(ov.tagSyncId);
      }
      if (overrides.isNotEmpty) {
        final tagSids = overrides.map((o) => o.tagSyncId).toSet().toList();
        final sharedTags = await (db.select(db.sharedLedgerTags)
              ..where((t) => t.syncId.isIn(tagSids)))
            .get();
        for (final s in sharedTags) {
          sharedTagBySyncId[s.syncId] = s;
        }
      }
    }

    return rows.map((r) {
      Category? category = r.category;
      Account? account = r.account;
      List<Tag> tags = r.tags;

      if (category == null) {
        final cov = r.t.categorySyncIdOverride;
        if (cov != null && cov.isNotEmpty) {
          final s = sharedCatBySyncId[cov];
          if (s != null) {
            category = Category(
              id: syntheticIdForSyncId(s.syncId),
              name: s.name,
              kind: s.kind,
              icon: s.icon,
              sortOrder: s.sortOrder,
              parentId: null,
              level: s.level,
              iconType: s.iconType,
              customIconPath:
                  s.iconType == 'custom' && s.iconCloudSha256 != null
                      ? 'custom_icons/shared_${s.iconCloudSha256}.png'
                      : null,
              communityIconId: null,
              syncId: s.syncId,
            );
          }
        }
      }

      if (account == null) {
        final aov = r.t.accountSyncIdOverride;
        if (aov != null && aov.isNotEmpty) {
          final s = sharedAccBySyncId[aov];
          if (s != null) {
            account = Account(
              id: syntheticIdForSyncId(s.syncId),
              ledgerId: r.t.ledgerId,
              name: s.name,
              type: s.accountType,
              currency: s.currency,
              note: s.note,
              initialBalance: s.initialBalance ?? 0.0,
              sortOrder: 0,
              creditLimit: s.creditLimit,
              billingDay: s.billingDay,
              paymentDueDay: s.paymentDueDay,
              bankName: s.bankName,
              cardLastFour: s.cardLastFour,
              createdAt: DateTime.now(),
              updatedAt: DateTime.now(),
              syncId: s.syncId,
              // SharedLedgerAccounts 镜像表没有 hidden 概念(隐藏是 Owner 侧
              // 个人状态,不随共享账本镜像同步),synthetic 账户固定按「未隐藏」处理。
              hidden: false,
            );
          }
        }
      }

      final txSid = r.t.syncId;
      if (txSid != null && tagOverridesByTxSyncId.containsKey(txSid)) {
        final extra = <Tag>[];
        for (final tagSid in tagOverridesByTxSyncId[txSid]!) {
          final s = sharedTagBySyncId[tagSid];
          if (s != null) {
            extra.add(Tag(
              id: syntheticIdForSyncId(s.syncId),
              name: s.name,
              color: s.color,
              sortOrder: 0,
              createdAt: DateTime.now(),
              syncId: s.syncId,
            ));
          }
        }
        if (extra.isNotEmpty) tags = [...tags, ...extra];
      }

      return (
        t: r.t,
        category: category,
        tags: tags,
        attachments: r.attachments,
        account: account,
      );
    }).toList();
  }

  @override
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
  }) async {
    // 查询时间范围内的所有交易
    final transactions = await (db.select(db.transactions)
          ..where((t) =>
              t.ledgerId.equals(ledgerId) &
              t.happenedAt.isBetweenValues(startDate, endDate))
          ..orderBy([
            (t) => d.OrderingTerm(
                  expression: t.happenedAt,
                  mode: d.OrderingMode.desc,
                ),
          ]))
        .get();

    // 批量获取所有相关的 category, tags, attachments, account
    // 一次 isIn 查询,避免逐条 N+1(原实现 100 条交易 → 500 次 SELECT)。
    if (transactions.isEmpty) {
      return _hydrateSharedOverridesFull(const []);
    }

    final txIds = transactions.map((t) => t.id).toList();

    // 批量查询分类
    final categoryIds = transactions
        .where((t) => t.categoryId != null)
        .map((t) => t.categoryId!)
        .toSet();
    final categoriesMap = <int, Category>{};
    if (categoryIds.isNotEmpty) {
      final categories = await (db.select(db.categories)
            ..where((c) => c.id.isIn(categoryIds.toList())))
          .get();
      for (final category in categories) {
        categoriesMap[category.id] = category;
      }
    }

    // 批量查询标签关联 + 标签
    final tagsMap = <int, List<Tag>>{};
    final tagRelations = await (db.select(db.transactionTags)
          ..where((tt) => tt.transactionId.isIn(txIds)))
        .get();
    final tagIds = tagRelations.map((r) => r.tagId).toSet();
    final tagsById = <int, Tag>{};
    if (tagIds.isNotEmpty) {
      final tags = await (db.select(db.tags)
            ..where((t) => t.id.isIn(tagIds.toList())))
          .get();
      for (final tag in tags) {
        tagsById[tag.id] = tag;
      }
    }
    for (final rel in tagRelations) {
      final tag = tagsById[rel.tagId];
      if (tag != null) {
        tagsMap.putIfAbsent(rel.transactionId, () => []).add(tag);
      }
    }

    // 批量查询附件
    final attachmentsMap = <int, List<TransactionAttachment>>{};
    final attachments = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.isIn(txIds)))
        .get();
    for (final attachment in attachments) {
      attachmentsMap
          .putIfAbsent(attachment.transactionId, () => [])
          .add(attachment);
    }

    // 批量查询账户
    final accountIds = transactions
        .where((t) => t.accountId != null)
        .map((t) => t.accountId!)
        .toSet();
    final accountsMap = <int, Account>{};
    if (accountIds.isNotEmpty) {
      final accounts = await (db.select(db.accounts)
            ..where((a) => a.id.isIn(accountIds.toList())))
          .get();
      for (final account in accounts) {
        accountsMap[account.id] = account;
      }
    }

    // 组装结果(顺序与 transactions 一致)
    final result = <({
      Transaction t,
      Category? category,
      List<Tag> tags,
      List<TransactionAttachment> attachments,
      Account? account,
    })>[];
    for (final tx in transactions) {
      result.add((
        t: tx,
        category: tx.categoryId != null ? categoriesMap[tx.categoryId] : null,
        tags: tagsMap[tx.id] ?? [],
        attachments: attachmentsMap[tx.id] ?? [],
        account: tx.accountId != null ? accountsMap[tx.accountId] : null,
      ));
    }

    return _hydrateSharedOverridesFull(result);
  }

  @override
  Future<List<String>> getTransactionDatesByMonth({
    required int ledgerId,
    required DateTime month,
  }) async {
    final startDate = DateTime(month.year, month.month, 1);
    final endDate = DateTime(month.year, month.month + 1, 0, 23, 59, 59);

    final query = '''
      SELECT DISTINCT DATE(happened_at) as date
      FROM transactions
      WHERE ledger_id = ?
        AND happened_at >= ?
        AND happened_at <= ?
      ORDER BY date DESC
    ''';

    final results = await db.customSelect(
      query,
      variables: [
        d.Variable.withInt(ledgerId),
        d.Variable.withDateTime(startDate),
        d.Variable.withDateTime(endDate),
      ],
    ).get();

    return results
        .map((row) => row.read<String?>('date'))
        .where((date) => date != null)
        .cast<String>()
        .toList();
  }

  // ==================== syncId 相关 ====================

  @override
  Future<Transaction?> getTransactionBySyncId(String syncId) async {
    return await (db.select(db.transactions)
          ..where((t) => t.syncId.equals(syncId)))
        .getSingleOrNull();
  }

  @override
  Future<void> updateTransactionBySyncId({
    required String syncId,
    required String type,
    required double amount,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    required DateTime happenedAt,
    String? note,
    double? originalAmount,
    Map<String, dynamic>? customValues,
  }) async {
    await (db.update(db.transactions)..where((t) => t.syncId.equals(syncId)))
        .write(TransactionsCompanion(
      type: d.Value(type),
      amount: d.Value(amount),
      categoryId: d.Value(categoryId),
      accountId: d.Value(accountId),
      toAccountId: d.Value(toAccountId),
      happenedAt: d.Value(happenedAt),
      note: d.Value(note),
      // v45 原始金额:null = 不改动既有值(保持「全字段更新但可缺省」语义);
      // 传值则写入。
      originalAmount: originalAmount == null
          ? const d.Value.absent()
          : d.Value(originalAmount),
      // v46 自定义字段值:null = 不改动;非 null(含空 map = 清空)才写入。
      customValuesJson: customValues == null
          ? const d.Value.absent()
          : d.Value(CustomFieldValueCodec.encode(customValues)),
    ));
  }

  @override
  Future<void> deleteTransactionBySyncId(String syncId) async {
    // 先查找交易ID，以便删除关联数据
    final tx = await getTransactionBySyncId(syncId);
    if (tx != null) {
      await deleteTransaction(tx.id);
    }
  }

  @override
  Future<Map<String, int>> updateTransactionsBatchBySyncId(
    List<TransactionUpdateBySyncIdData> updates, {
    bool recordChanges = true,
  }) async {
    if (updates.isEmpty) return const {};
    return db.transaction(() async {
      await db.batch((b) {
        for (final u in updates) {
          b.update(
            db.transactions,
            TransactionsCompanion(
              type: d.Value(u.type),
              amount: d.Value(u.amount),
              categoryId: d.Value(u.categoryId),
              accountId: d.Value(u.accountId),
              toAccountId: d.Value(u.toAccountId),
              happenedAt: d.Value(u.happenedAt),
              note: d.Value(u.note),
              // 修正 BUG：此前只更新 amount 不更新 currency_code /
              // native_amount，导致单币种账本同步后 native_amount 保持旧值，
              // 统计（SUM(COALESCE(native_amount, amount))）读旧数据，
              // 表现为"明细变了但日/月合计不变"。这里按调用方提供的折算值
              // 一并写入；调用方未提供时（如旧调用方）保持本地原值。
              currencyCode: u.currencyCode == null
                  ? const d.Value.absent()
                  : d.Value(u.currencyCode),
              nativeAmount: u.nativeAmount == null
                  ? const d.Value.absent()
                  : d.Value(u.nativeAmount),
              // v45 原始金额:云端未携带(u.originalAmount == null,旧快照)→
              // absent 保留本地原值;非 null → 写入(与 currencyCode 同模式,
              // 避免旧快照缺键把本地已填值抹平)。
              originalAmount: u.originalAmount == null
                  ? const d.Value.absent()
                  : d.Value(u.originalAmount),
              // v46 自定义字段值:旧快照缺键(null)→ absent 保留本地原值;
              // 非 null(含空 map = 云端显式清空)→ 写入。
              customValuesJson: u.customValues == null
                  ? const d.Value.absent()
                  : d.Value(CustomFieldValueCodec.encode(u.customValues)),
              // 账单标记：diff 合并必须一并写入，否则"不计入统计/预算"
              // 跨设备丢失（与 native_amount 分裂同源问题）。
              excludeFromStats: d.Value(u.excludeFromStats),
              excludeFromBudget: d.Value(u.excludeFromBudget),
              // 共享账本 override：null → absent（保留本地原值），
              // 非 null → 写入（含空串"清空"语义）。与 currencyCode 同模式。
              categorySyncIdOverride: u.categorySyncIdOverride == null
                  ? const d.Value.absent()
                  : d.Value(u.categorySyncIdOverride),
              accountSyncIdOverride: u.accountSyncIdOverride == null
                  ? const d.Value.absent()
                  : d.Value(u.accountSyncIdOverride),
              toAccountSyncIdOverride: u.toAccountSyncIdOverride == null
                  ? const d.Value.absent()
                  : d.Value(u.toAccountSyncIdOverride),
            ),
            where: (t) => t.syncId.equals(u.syncId),
          );
        }
      });
      // 反查 (syncId, txId) 映射,caller 用它批量更新 tag 关联
      final syncIds = updates.map((u) => u.syncId).toList();
      final rows = await (db.select(db.transactions)
            ..where((t) => t.syncId.isIn(syncIds)))
          .get();
      final syncIdToTxId = {
        for (final tx in rows)
          if (tx.syncId != null) tx.syncId!: tx.id,
      };

      // 附件清单替换（云→本 modified 合并）：attachments == null 不动本地；
      // 非 null（含空表）以云端清单整体替换。与主表更新同事务，失败一起回滚。
      final removedFileNames = <String>{};
      for (final u in updates) {
        final list = u.attachments;
        if (list == null) continue;
        final txId = syncIdToTxId[u.syncId];
        if (txId == null) continue;
        removedFileNames
            .addAll(await _replaceAttachmentsForTransaction(txId, list));
      }
      if (removedFileNames.isNotEmpty) {
        await _gcUnreferencedAttachmentFiles(removedFileNames);
      }

      return syncIdToTxId;
    });
  }

  /// H1（audit）：为「本地无 syncId、经业务键唯一匹配到云端交易」的行回填
  /// 云端 syncId（认领语义）。见 TransactionRepository 契约注释。
  @override
  Future<bool> adoptTransactionSyncId(int txId, String syncId) async {
    if (syncId.isEmpty) return false;
    return db.transaction(() async {
      final row = await (db.select(db.transactions)
            ..where((t) => t.id.equals(txId)))
          .getSingleOrNull();
      if (row == null || (row.syncId != null && row.syncId!.isNotEmpty)) {
        return false; // 行不存在或已有身份：绝不覆盖
      }
      final occupied = await (db.select(db.transactions)
            ..where((t) => t.syncId.equals(syncId)))
          .get();
      if (occupied.isNotEmpty) return false; // 身份已被其他行占用
      await (db.update(db.transactions)..where((t) => t.id.equals(txId)))
          .write(TransactionsCompanion(syncId: d.Value(syncId)));
      return true;
    });
  }

  /// 整体替换某交易的附件元数据行。返回被移除行的 fileName 集合
  /// （物理文件是否可删由调用方统一做引用计数判定）。
  ///
  /// 逐字段等价短路：合并路径构造的 `attachments` **恒非 null**
  /// （`sync_diff_service.dart` 的 `cloud.attachments ?? const []`），于是
  /// `updateTransactionsBatchBySyncId` 里 `if (list == null) continue` 永不
  /// 跳过 —— 每笔 modified 都要「SELECT 旧行 + DELETE 全部 + INSERT 回来」，
  /// 再把移除的文件名送进 `_gcUnreferencedAttachmentFiles`（含文件系统
  /// exists/delete）。实测合并场景绝大多数 modified 只改了金额/备注，附件
  /// 清单逐字段相同；此时整段短路，结果与「先删后插」逐字节一致，但省掉
  /// 3 条 SQL/行 + 文件系统探测。
  Future<Set<String>> _replaceAttachmentsForTransaction(
    int transactionId,
    List<BatchAttachmentData> incoming,
  ) async {
    final oldRows = await (db.select(db.transactionAttachments)
          ..where((a) => a.transactionId.equals(transactionId)))
        .get();
    if (_sameAttachmentSet(oldRows, incoming)) return const {};
    await (db.delete(db.transactionAttachments)
          ..where((a) => a.transactionId.equals(transactionId)))
        .go();
    if (incoming.isNotEmpty) {
      await db.batch((b) {
        for (final a in incoming) {
          b.insert(
              db.transactionAttachments,
              TransactionAttachmentsCompanion.insert(
                transactionId: transactionId,
                fileName: a.fileName,
                originalName: d.Value(a.originalName),
                fileSize: d.Value(a.fileSize),
                width: d.Value(a.width),
                height: d.Value(a.height),
                sortOrder: d.Value(a.sortOrder),
                cloudFileId: d.Value(a.cloudFileId),
                cloudSha256: d.Value(a.cloudSha256),
                localSha256: d.Value(a.localSha256),
              ));
        }
      });
    }
    return {
      for (final r in oldRows)
        if (!incoming.any((a) => a.fileName == r.fileName)) r.fileName,
    };
  }

  /// 判断「旧附件行集合」与「云端待写入清单」是否逐字段等价（可安全跳过替换）。
  ///
  /// 以 `fileName`（内容寻址 sha256）为桶，避免 O(N²) 比对；同 fileName 的
  /// 重复行按出现顺序配对。任一字段不同即返回 false，走正常替换路径。
  static bool _sameAttachmentSet(
    List<TransactionAttachment> oldRows,
    List<BatchAttachmentData> incoming,
  ) {
    if (oldRows.length != incoming.length) return false;
    final buckets = <String, List<TransactionAttachment>>{};
    for (final r in oldRows) {
      buckets.putIfAbsent(r.fileName, () => <TransactionAttachment>[]).add(r);
    }
    for (final a in incoming) {
      final bucket = buckets[a.fileName];
      if (bucket == null || bucket.isEmpty) return false;
      final r = bucket.removeAt(0);
      if (r.originalName != a.originalName ||
          r.fileSize != a.fileSize ||
          r.width != a.width ||
          r.height != a.height ||
          r.sortOrder != a.sortOrder ||
          r.cloudFileId != a.cloudFileId ||
          r.cloudSha256 != a.cloudSha256 ||
          r.localSha256 != a.localSha256) {
        return false;
      }
    }
    return true;
  }

  /// 引用计数回收附件物理文件：仅当没有任何 transaction_attachments 行
  /// 再引用该 fileName 时才删文件与缩略图（对齐 _deleteAttachmentsForTransaction
  /// 的口径；内容寻址下多笔交易共享同一文件，误删会弄坏别笔交易）。
  Future<void> _gcUnreferencedAttachmentFiles(Set<String> candidates) async {
    if (candidates.isEmpty) return;
    try {
      final stillReferenced = <String>{};
      final refs = await (db.select(db.transactionAttachments)
            ..where((a) => a.fileName.isIn(candidates.toList())))
          .get();
      for (final r in refs) {
        stillReferenced.add(r.fileName);
      }
      if (stillReferenced.length >= candidates.length) return;

      final appDir = await getApplicationDocumentsDirectory();
      final attachmentDir = Directory('${appDir.path}/attachments');
      final thumbDir = Directory(
          '${(await getTemporaryDirectory()).path}/attachment_thumbs');
      for (final name in candidates) {
        if (stillReferenced.contains(name)) continue;
        final file = File('${attachmentDir.path}/$name');
        if (await file.exists()) {
          await file.delete();
        }
        final thumbName = '${path.basenameWithoutExtension(name)}_thumb.jpg';
        final thumbFile = File('${thumbDir.path}/$thumbName');
        if (await thumbFile.exists()) {
          await thumbFile.delete();
        }
      }
    } catch (e, st) {
      // 物理文件清理失败不影响数据正确性（孤儿文件由维护页扫描兜底）
      logger.warning('LocalTransactionRepository', '附件物理文件回收失败: $e\n$st');
    }
  }

  @override
  Future<int> deleteTransactionsBatchBySyncIds(
    List<String> syncIds, {
    bool recordChanges = true,
  }) async {
    // recordChanges 由 LocalRepository wrapper 处理(子仓库无 changeTracker)。
    if (syncIds.isEmpty) return 0;
    return db.transaction(() async {
      // 先 SELECT 拿到 tx id 列表(用来删 transactionTags / attachments 关联)
      final rows = await (db.select(db.transactions)
            ..where((t) => t.syncId.isIn(syncIds)))
          .get();
      final txIds = rows.map((r) => r.id).toList();
      if (txIds.isEmpty) return 0;
      // 删关联数据(级联)
      await (db.delete(db.transactionTags)
            ..where((t) => t.transactionId.isIn(txIds)))
          .go();
      await (db.delete(db.transactionAttachments)
            ..where((t) => t.transactionId.isIn(txIds)))
          .go();
      // 级联清理共享标签 override(按 syncId 批量删,避免孤儿行)
      await (db.delete(db.transactionTagOverrides)
            ..where((t) => t.transactionSyncId.isIn(syncIds)))
          .go();
      // 主表 DELETE WHERE IN — 一次 SQL 删 N 条
      final deleted = await (db.delete(db.transactions)
            ..where((t) => t.id.isIn(txIds)))
          .go();
      return deleted;
    });
  }

  @override
  Future<int> createAdjustmentTransaction({
    required int ledgerId,
    required int accountId,
    required double amount,
    required DateTime happenedAt,
    String? note,
  }) async {
    return await addTransaction(
      ledgerId: ledgerId,
      type: 'adjustment',
      amount: amount,
      accountId: accountId,
      happenedAt: happenedAt,
      note: note,
    );
  }
}
