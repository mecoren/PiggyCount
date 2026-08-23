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
