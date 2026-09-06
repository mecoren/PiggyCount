import 'package:drift/drift.dart';

import '../../data/db.dart';
import '../../cloud/sync/change_tracker.dart';
import '../system/logger_service.dart';

/// 账户去重收敛结果统计
class AccountDedupResult {
  /// 合并的账户组数（同名组内消除重复的组数）
  final int mergedGroups;

  /// 删除的重复账户行数
  final int deletedAccounts;

  /// 重定向的交易/周期交易账户引用条数（account_id + to_account_id 合计）
  final int movedRefs;

  const AccountDedupResult({
    required this.mergedGroups,
    required this.deletedAccounts,
    required this.movedRefs,
  });

  /// 无需收敛时的零结果
  static const empty =
      AccountDedupResult(mergedGroups: 0, deletedAccounts: 0, movedRefs: 0);
}

/// 账户去重收敛服务（prd/account_dedup）
///
/// 收敛历史遗留的「按账本重复账户」：旧版本每个账本会种子一套默认账户
/// （现金/储蓄卡/支付宝…，随机 syncId），累积出同名多行且 ledger_id 各异。
/// 本服务在启动引导阶段把每组同名账户合并为一行全局账户：
/// - keeper 选择：① ledger_id=0（已是全局）→ ② syncId 非空中 id 最小
///   （保住与对端设备共享的身份锚点）→ ③ id 最小
/// - 重复账户的交易引用（transactions / recurring_transactions 的
///   account_id 与 to_account_id）重定向到 keeper 后删除重复行
/// - keeper 的 ledger_id 置 0（全局化）
///
/// 幂等设计：每次启动重跑，无目标状态时零写入直接返回——可自愈
/// 「恢复旧快照再次引入重复账户」的场景，无需版本标记。
class AccountDedupService {
  AccountDedupService._();

  static const _tag = 'AccountDedup';

  /// 执行收敛。整个合并在单个事务内完成，任一步失败整体回滚，
  /// 不会留下「交易已重定向但账户未删」的半合并状态。
  ///
  /// [changeTracker] 可选(历史参数,云端协同下线后生产装配不再传入):
  /// 传入时被重定向的 recurring_transactions 行补登记 update change,
  /// 否则对端规则的账户引用仍指向已被合并掉的重复账户。
  static Future<AccountDedupResult> run(
    PiggyDatabase db, {
    ChangeTracker? changeTracker,
  }) async {
    final accounts = await db.select(db.accounts).get();

    // 按 name 分组（与快照导入的 name 兜底策略同口径）
    final byName = <String, List<Account>>{};
    for (final a in accounts) {
      byName.putIfAbsent(a.name, () => []).add(a);
    }

    // 收集需要处理的组：同名多行，或唯一行仍是 ledger scope（需全局化）
    final work = <String, List<Account>>{};
    for (final e in byName.entries) {
      final needsMerge = e.value.length > 1;
      final needsGlobalize = e.value.length == 1 && e.value.first.ledgerId != 0;
      if (needsMerge || needsGlobalize) {
        work[e.key] = e.value;
      }
    }
    if (work.isEmpty) return AccountDedupResult.empty;

    var mergedGroups = 0;
    var deletedAccounts = 0;
    var movedRefs = 0;

    await db.transaction(() async {
      for (final group in work.values) {
        // keeper 确定性排序：全局行 > syncId 非空 > id 小
        final sorted = [...group]..sort((a, b) {
            final aGlobal = a.ledgerId == 0 ? 0 : 1;
            final bGlobal = b.ledgerId == 0 ? 0 : 1;
            if (aGlobal != bGlobal) return aGlobal - bGlobal;
            final aSync = (a.syncId ?? '').isNotEmpty ? 0 : 1;
            final bSync = (b.syncId ?? '').isNotEmpty ? 0 : 1;
            if (aSync != bSync) return aSync - bSync;
            return a.id.compareTo(b.id);
          });
        final keeper = sorted.first;
        final dups = sorted.skip(1).toList();

        for (final dup in dups) {
          movedRefs += await _repoint(db, dup.id, keeper.id,
              changeTracker: changeTracker);
          await (db.delete(db.accounts)..where((a) => a.id.equals(dup.id))).go();
          deletedAccounts++;
        }

        // 唯一行但仍是账本 scope：仅全局化（holder 不变）
        if (keeper.ledgerId != 0) {
          await (db.update(db.accounts)..where((a) => a.id.equals(keeper.id)))
              .write(const AccountsCompanion(ledgerId: Value(0)));
        }
        mergedGroups++;
      }
    });

    logger.info(_tag,
        '收敛完成: 合并组=$mergedGroups 删除账户=$deletedAccounts 重定向引用=$movedRefs');
    return AccountDedupResult(
      mergedGroups: mergedGroups,
      deletedAccounts: deletedAccounts,
      movedRefs: movedRefs,
    );
  }

  /// 把 [fromId] 账户的全部引用重定向到 [toId]，返回受影响行数。
  /// 交易与周期交易两张表的 account_id / to_account_id 都要覆盖。
  /// [changeTracker] 非空时,被改写的 recurring_transactions 行补登记
  /// update change(交易路径保持既有行为,不在此登记)。
  static Future<int> _repoint(
    PiggyDatabase db,
    int fromId,
    int toId, {
    ChangeTracker? changeTracker,
  }) async {
    var count = 0;
    count += await (db.update(db.transactions)
          ..where((t) => t.accountId.equals(fromId)))
        .write(TransactionsCompanion(accountId: Value(toId)));
    count += await (db.update(db.transactions)
          ..where((t) => t.toAccountId.equals(fromId)))
        .write(TransactionsCompanion(toAccountId: Value(toId)));

    // 先取受影响规则行(syncId/ledgerId),改写后登记 update change
    final affectedRecurring = await (db.select(db.recurringTransactions)
          ..where((t) =>
              t.accountId.equals(fromId) | t.toAccountId.equals(fromId)))
        .get();
    count += await (db.update(db.recurringTransactions)
          ..where((t) => t.accountId.equals(fromId)))
        .write(RecurringTransactionsCompanion(accountId: Value(toId)));
    count += await (db.update(db.recurringTransactions)
          ..where((t) => t.toAccountId.equals(fromId)))
        .write(RecurringTransactionsCompanion(toAccountId: Value(toId)));
    if (changeTracker != null) {
      for (final r in affectedRecurring) {
        if (r.syncId == null || r.syncId!.isEmpty) continue;
        await changeTracker.recordLedgerChange(
          entityType: 'recurring',
          entityId: r.id,
          entitySyncId: r.syncId!,
          ledgerId: r.ledgerId,
          action: 'update',
        );
      }
    }
    return count;
  }
}
