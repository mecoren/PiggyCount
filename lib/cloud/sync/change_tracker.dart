import 'package:drift/drift.dart' as d;

import '../../data/db.dart';
import '../../services/system/logger_service.dart';

/// 本地变更追踪器。在 Repository 层捕获写操作,记录到 local_changes 表,
/// 同步引擎读取未推送的变更并上传到服务端。
///
/// ## Scope 契约(重要)
///
/// `local_changes.ledger_id` 字段有两层语义,取决于 entity 是否 user-global:
///
/// - **user-global**(account / category / tag):每个用户共享一份实体,**不**归
///   属于具体账本。对应变更必须记到 `ledgerId = 0`,sync_engine._push 里靠
///   `getUnpushedChangesForLedger(0)` 查到 globalChanges,搭任一账本的 sync
///   链带出去。这样用户在任何账本上触发同步,账户/分类/标签的改动都能推出。
/// - **ledger-scoped**(transaction / budget / ledger / ledger_snapshot):每条
///   变更挂在具体账本上,对应 `ledgerId = 具体账本 id`。只有用户同步这个
///   账本时 `getUnpushedChangesForLedger(ledger.id)` 才会把它推出去。
///
/// 为强制契约,**调用方不要直接调 `recordChange`**(私有内部方法),用下面
/// 两个强类型入口:
///   - [recordUserGlobalChange] — 自动挂 ledgerId=0
///   - [recordLedgerChange] — 必须传 ledgerId(非零)
///
/// 契约破坏的典型后果:account rename 被记到 `account.ledgerId`(不是 0),
/// 当前同步的账本跟 account.ledgerId 不一致时,`_push()` 两个查询都漏这条
/// orphan change → 变更永远卡本地不推。详见 PR#? (2026-04-21 修复)。
class ChangeTracker {
  final PiggyDatabase db;

  ChangeTracker(this.db);

  /// 已知的 user-global 实体类型。recordUserGlobalChange 用白名单校验防止
  /// 调用方误用(把 transaction 之类传进来也能通过,但被 assert 拦住)。
  static const Set<String> _userGlobalEntityTypes = {'account', 'category', 'tag', 'exchange_rate_override'};

  /// 公开 read-only 视图给 sync_engine 的 push 路径用,判断"这条 change 是否
  /// 是 user-global 类型",决定 push 时 scope 字段。
  static const Set<String> userGlobalEntityTypes = _userGlobalEntityTypes;

  /// 记录一条 user-global 实体(account / category / tag)的变更。
  /// 自动挂 ledgerId=0,调用方不用操心 scope 选择。
  ///
  /// 新增 user-global entity type 时改 [_userGlobalEntityTypes] 白名单即可。
  Future<void> recordUserGlobalChange({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    required String action,
    String? payloadJson,
  }) async {
    assert(
      _userGlobalEntityTypes.contains(entityType),
      'recordUserGlobalChange 只接受 user-global 实体 '
      '($_userGlobalEntityTypes),实际传入 "$entityType" —— 应该调 '
      'recordLedgerChange 并传具体 ledgerId。',
    );
    await _insert(
      entityType: entityType,
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: 0,
      action: action,
      payloadJson: payloadJson,
    );
  }

  /// 记录一条 ledger-scoped 实体(transaction / budget / ledger / ledger_snapshot)
  /// 的变更。必须传具体 ledgerId,0 通常是错的(会混进 user-global 通道)。
  Future<void> recordLedgerChange({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
    required String action,
    String? payloadJson,
  }) async {
    assert(
      !_userGlobalEntityTypes.contains(entityType),
      'recordLedgerChange 不接受 user-global 实体 '
      '($_userGlobalEntityTypes),实际传入 "$entityType" —— 应该调 '
      'recordUserGlobalChange(不传 ledgerId)。',
    );
    assert(
      ledgerId > 0,
      'recordLedgerChange 需要具体 ledgerId(>0),实际传入 $ledgerId。'
      '传 0 会落到 user-global 通道,不是本方法的契约。',
    );
    await _insert(
      entityType: entityType,
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: ledgerId,
      action: action,
      payloadJson: payloadJson,
    );
  }

  /// M3：云→本地合并（Path A）期间的全局抑制开关。
  /// 置 true 时所有 record*Change 静默跳过 —— 云端拉下来的数据若反向
  /// 登记为「本地编辑」，会污染推送队列：Cloud 引擎把幻影变更推回
  /// 服务端 / 触发无意义的重复上传。
  bool _suppressRecording = false;

  /// 在抑制 change 记录的上下文中执行 [action]。
  ///
  /// 供 applySyncChanges / restoreLedgerFromJson 等云→本地合并路径包裹
  /// 全程：无论内部调到哪个 repo 写方法（账户/分类/标签/交易 upsert），
  /// 都不会回流 local_changes。支持嵌套（内层恢复外层状态）。
  Future<T> withRecordingSuppressed<T>(Future<T> Function() action) async {
    final previous = _suppressRecording;
    _suppressRecording = true;
    try {
      return await action();
    } finally {
      _suppressRecording = previous;
    }
  }

  /// 低层 insert,不对外暴露。路径统一:所有 record*Change 走这条,行为
  /// (日志 / insert 语义)一处维护。
  Future<void> _insert({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
    required String action,
    String? payloadJson,
  }) async {
    // M3：云→本地合并路径抑制期间直接丢弃 —— 这些写入来自云端快照，
    // 不是用户编辑，回流推送队列只会产生幻影变更。
    if (_suppressRecording) return;
    // F2 加固: insertOrIgnore —— 同 (entity_type, entity_sync_id, action) 的
    // 未推送重复 insert 静默合并(保留首条),由 v35 部分唯一索引(WHERE
    // pushed_at IS NULL)兜底。已推送行退出部分索引,二次编辑可正常插入。
    // push 路径从 DB 重建 payload(见 _serializeEntityForPush),不读
    // payloadJson,合并不丢数据。
    await db.into(db.localChanges).insert(
      LocalChangesCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        entitySyncId: entitySyncId,
        ledgerId: ledgerId,
        action: action,
        payloadJson: d.Value(payloadJson),
      ),
      mode: d.InsertMode.insertOrIgnore,
    );
    logger.debug('ChangeTracker', '$action $entityType($entitySyncId)');
  }

  /// 登记一个**从 server pull 拉下来**的实体在本地的状态。
  ///
  /// 写入一条 `local_changes` 行,**pushedAt 设为 now**(表示"server 已有此
  /// 实体,本地不需要再推")。
  ///
  /// 目的:fullPush 路径上 [SyncEngine._backfillLegacyUserGlobalChanges]
  /// 通过扫 local_changes 来识别"哪些 user-global 实体已知"。pull apply 进
  /// 来的实体如果不登记,legacy backfill 会误判为"v18→v19 老数据"并补登记 →
  /// 第二台设备同步时把 server 已有的 user-global 实体重新推一遍 → server
  /// sync_changes 表 2x 膨胀。
  ///
  /// **幂等**:同一 (entityType, entitySyncId) 多次调用只插一次(同 entity
  /// 通过 apply update 多次也不会挤爆表)。
  Future<void> recordPulledFromServer({
    required String entityType,
    required int entityId,
    required String entitySyncId,
    required int ledgerId,
  }) async {
    final existing = await (db.select(db.localChanges)
          ..where((c) =>
              c.entityType.equals(entityType) &
              c.entitySyncId.equals(entitySyncId))
          ..limit(1))
        .getSingleOrNull();
    if (existing != null) return;

    final now = DateTime.now();
    await db.into(db.localChanges).insert(LocalChangesCompanion.insert(
      entityType: entityType,
      entityId: entityId,
      entitySyncId: entitySyncId,
      ledgerId: ledgerId,
      action: 'upsert',
      pushedAt: d.Value(now),
    ));
    logger.debug('ChangeTracker',
        'pulled-from-server marker: $entityType($entitySyncId)');
  }

  /// 获取所有未推送的变更
  Future<List<LocalChange>> getUnpushedChanges() async {
    return await (db.select(db.localChanges)
          ..where((c) => c.pushedAt.isNull())
          ..orderBy([(c) => d.OrderingTerm.asc(c.id)]))
        .get();
  }

  /// 获取指定账本的未推送变更
  Future<List<LocalChange>> getUnpushedChangesForLedger(int ledgerId) async {
    return await (db.select(db.localChanges)
          ..where((c) => c.pushedAt.isNull() & c.ledgerId.equals(ledgerId))
          ..orderBy([(c) => d.OrderingTerm.asc(c.id)]))
        .get();
  }

  /// 标记变更已推送
  Future<void> markPushed(List<int> changeIds) async {
    if (changeIds.isEmpty) return;
    final now = DateTime.now();
    await (db.update(db.localChanges)
          ..where((c) => c.id.isIn(changeIds)))
        .write(LocalChangesCompanion(pushedAt: d.Value(now)));
    logger.debug('ChangeTracker', '标记 ${changeIds.length} 条变更已推送');
  }

  /// 清理已推送的旧变更（保留最近 7 天）
  Future<int> cleanupPushedChanges({Duration retention = const Duration(days: 7)}) async {
    final cutoff = DateTime.now().subtract(retention);
    final count = await (db.delete(db.localChanges)
          ..where((c) => c.pushedAt.isNotNull() & c.pushedAt.isSmallerThanValue(cutoff)))
        .go();
    if (count > 0) {
      logger.info('ChangeTracker', '清理 $count 条已推送的旧变更');
    }
    return count;
  }

  /// 获取未推送变更数量
  Future<int> getUnpushedCount() async {
    final result = await (db.select(db.localChanges)
          ..where((c) => c.pushedAt.isNull()))
        .get();
    return result.length;
  }
}
