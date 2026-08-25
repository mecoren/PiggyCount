part of 'sync_engine.dart';

/// 审计 S3：实体水位存取（见 db.dart EntityChangeWatermarks 文档）。
extension SyncEngineWatermarksExt on SyncEngine {
  Future<int?> _entityWatermark(String entitySyncId) async {
    final row = await (db.select(db.entityChangeWatermarks)
          ..where((t) => t.syncId.equals(entitySyncId)))
        .getSingleOrNull();
    return row?.watermark;
  }

  Future<void> _recordEntityWatermark(String entitySyncId, int changeId) {
    return db.into(db.entityChangeWatermarks).insertOnConflictUpdate(
          EntityChangeWatermarksCompanion.insert(
              syncId: entitySyncId, watermark: changeId),
        );
  }

  /// 审计 L1：远端实体被删除后同步清除其水位行。
  ///
  /// 水位表此前只在本地删账本时清理（S9），单实体远端删除后行永久残留、
  /// 无限增长。实体既已从 server 删除，其水位不再有任何拦截意义
  /// （changeId 单调，不会再有 ≤ 旧水位的该实体变更到来）。
  Future<void> _dropEntityWatermark(String entitySyncId) async {
    await (db.delete(db.entityChangeWatermarks)
          ..where((t) => t.syncId.equals(entitySyncId)))
        .go();
  }

  /// 审计 S3b：该实体是否存在未推送的本地编辑。
  Future<bool> _hasUnpushedLocalChange(
      String entityType, String entitySyncId) async {
    final row = await (db.select(db.localChanges)
          ..where((c) =>
              c.entityType.equals(entityType) &
              c.entitySyncId.equals(entitySyncId) &
              c.pushedAt.isNull())
          ..limit(1))
        .getSingleOrNull();
    return row != null;
  }
}
