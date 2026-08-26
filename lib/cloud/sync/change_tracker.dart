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

  /// M2（audit）：server pull 标记专用 action 值。
  ///
  /// [recordPulledFromServer] 写入的"server 已有此实体"防重推标记此前借用
  /// 业务值 'upsert'，与真实业务变更无法区分 —— Path A 快照上传后的
  /// [cleanupPushedChanges]（7 天清理）会把这类标记当普通已推送行删掉，
  /// 之后 Path B 的 legacy backfill 扫不到它们 → 把 server 已知实体重新
  /// 登记推送（服务端幂等不丢数据，但 sync_changes 膨胀+带宽浪费）。
  /// 改用专属值后，清理可精确区分两类行的保留策略。
  ///
  /// 审计 T7：标记行不再永久豁免 —— [cleanupPushedChanges] 按
  /// markerRetention（默认 30 天）清理，见该方法注释的折中说明。
  static const String serverMarkerAction = 'server_marker';

  /// 公开 read-only 视图给 sync_engine 的 push 路径用,判断"这条 change 是否
  /// 是 user-global 类型",决定 push 时 scope 字段。
  static const Set<String> userGlobalEntityTypes = _userGlobalEntityTypes;

  /// 审计 T5：action 词汇归一化。
  ///
  /// `create` / `update` 统一收敛为 `upsert` —— push 端本就把非 delete 的
  /// action 一律按 upsert 序列化（payload 从 DB 重建，见
  /// sync_engine.dart `_doPush`），词汇差异从未承载语义，只会让 v35 部分
  /// 唯一索引 `(entity_type, entity_sync_id, action) WHERE pushed_at IS NULL`
  /// 失去去重能力：同一实体先 create 后 update 会留下两条未推送行，
  /// 推送端发两份幂等 upsert（冗余带宽）。归一化后同实体未推送行恒唯一。
  ///
  /// `delete` 与 [serverMarkerAction] 各有专属消费方，保持原值。
  static String normalizeAction(String action) {
    switch (action) {
      case 'create':
      case 'update':
        return 'upsert';
      default:
        return action;
    }
  }

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
  ///
  /// 审计 PathB-H5：由 bool 改为**深度计数器**。bool 版在两个抑制上下文
  /// 并发交错时（各自含 await 让出点），先结束者把开关还原 false，另一
  /// 上下文剩余写入全部回流成幻影变更。计数器保证嵌套/交错的进入与
  /// 退出严格配对，只有最外层退出才真正解除抑制。
  int _suppressDepth = 0;

  bool get _suppressRecording => _suppressDepth > 0;

  /// 在抑制 change 记录的上下文中执行 [action]。
  ///
  /// 供 applySyncChanges / restoreLedgerFromJson 等云→本地合并路径包裹
  /// 全程：无论内部调到哪个 repo 写方法（账户/分类/标签/交易 upsert），
  /// 都不会回流 local_changes。支持嵌套与并发交错（计数器语义）。
  Future<T> withRecordingSuppressed<T>(Future<T> Function() action) async {
    _suppressDepth++;
    try {
      return await action();
    } finally {
      _suppressDepth--;
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
    //
    // 审计 T5：写入前统一归一化 action（create/update → upsert）。
    await db.into(db.localChanges).insert(
      LocalChangesCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        entitySyncId: entitySyncId,
        ledgerId: ledgerId,
        action: normalizeAction(action),
        payloadJson: d.Value(payloadJson),
      ),
      mode: d.InsertMode.insertOrIgnore,
    );
    logger.debug('ChangeTracker', '$action $entityType($entitySyncId)');
  }

  /// 批量登记变更（batch 导入路径专用，审计 TBL-M8）。
  ///
  /// 此前 local_repository 的三个 batch 方法用裸 db.batch 直插 localChanges：
  /// - 绕过 [_suppressRecording]：抑制上下文中的调用会把云→本合并数据
  ///   反向登记为待推送幻影变更；
  /// - 绕过 InsertMode.insertOrIgnore：撞 v35 部分唯一索引时直接抛错，
  ///   整批导入失败。
  /// 统一收口到 tracker 后两条纪律与单条路径（[_insert]）完全一致。
  Future<void> recordBatch(List<LocalChangesCompanion> rows) async {
    if (_suppressRecording || rows.isEmpty) return;
    // 审计 T5：批量路径同样归一化 action，与单条路径纪律一致
    await db.batch((b) {
      for (final row in rows) {
        final normalized = row.action.present
            ? row.copyWith(action: d.Value(normalizeAction(row.action.value)))
            : row;
        b.insert(
          db.localChanges,
          normalized,
          mode: d.InsertMode.insertOrIgnore,
        );
      }
    });
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
  ///
  /// M2：action 使用专用值 [serverMarkerAction]（不再借用业务值 'upsert'），
  /// 使 [cleanupPushedChanges] 能豁免这类标记，防止防重推标记被 7 天清理
  /// 误删后触发重复推送膨胀。
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
      action: serverMarkerAction,
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

  /// 快照同步（Path A）专用：把某账本作用域的全部未推送变更标记为已推送。
  ///
  /// 语义依据：Path A 的整账本快照上传会把该账本的 ledger-scoped 变更和
  /// user-global 变更（账户/分类/标签等，每个快照都全量携带，见
  /// transactions_json.dart 导出注释）一并带到云端。因此快照上传成功后：
  /// - ledgerId 对应的 ledger-scoped 未推送行 + 全部 user-global
  ///   （ledger_id=0）未推送行都已上云，不应再留在推送队列；
  /// - 防止 local_changes 无限膨胀（此前 Path A 用户永不 markPushed，
  ///   审计 F2）；
  /// - 恢复 `_localChangeEvidence`「仅未推送行存在才可信」证据门禁的
  ///   设计语义（M1/M7）：上传完成后时间戳与内容新旧状态重新对齐。
  ///
  /// 注意：只应在**快照上传成功后**调用；SyncEngine（Path B）推送仍走
  /// [markPushed]（按 changeId 精确标记，失败行留队列重试）。
  ///
  /// 返回标记的行数。
  Future<int> markSnapshotPushed({required int ledgerId}) async {
    final now = DateTime.now();
    final count = await (db.update(db.localChanges)
          ..where((c) => c.pushedAt.isNull() &
              (c.ledgerId.equals(ledgerId) | c.ledgerId.equals(0))))
        .write(LocalChangesCompanion(pushedAt: d.Value(now)));
    if (count > 0) {
      logger.debug('ChangeTracker',
          '快照已上云，标记 ledger=$ledgerId(含 user-global) $count 条变更已推送');
    }
    return count;
  }

  /// 清理已推送的旧变更。
  ///
  /// - 业务行（create/update/upsert/delete）：[retention]（默认 7 天）
  /// - [serverMarkerAction] 标记行：[markerRetention]（默认 30 天）
  ///
  /// 审计 T7：标记行此前**永久豁免**清理 —— 每个被 pull 过的实体留一行
  /// 永不删除。其消费方只有 Path B 的 legacy backfill 防重推扫描；现在
  /// 改为更长保留窗的折中：
  /// - 窗口内行为不变（防重推保护有效）；
  /// - 过期删除后，若实体再次经 pull 会被 [recordPulledFromServer] 幂等
  ///   重建（它按 (entityType, entitySyncId) 预检去重）；最坏后果是
  ///   legacy backfill 对「窗口外且此后不再变更」的实体重推一次 ——
  ///   服务端幂等，仅带宽浪费，换取表有界增长。
  /// Path B 当前整体停用（kPiggyCountCloudEnabled=false），该折中无实际
  /// 风险敞口；开关打开前会重新评估 legacy backfill 的必要性。
  Future<int> cleanupPushedChanges({
    Duration retention = const Duration(days: 7),
    Duration markerRetention = const Duration(days: 30),
  }) async {
    final businessCutoff = DateTime.now().subtract(retention);
    final markerCutoff = DateTime.now().subtract(markerRetention);
    final count = await (db.delete(db.localChanges)
          ..where((c) =>
              c.pushedAt.isNotNull() &
              ((c.pushedAt.isSmallerThanValue(businessCutoff) &
                      c.action.equals(serverMarkerAction).not()) |
                  (c.action.equals(serverMarkerAction) &
                      c.pushedAt.isSmallerThanValue(markerCutoff)))))
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
