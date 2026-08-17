import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync/src/core/database_service.dart';
import 'package:flutter_cloud_sync/src/manager/database_sync_manager.dart';

/// P2：离线队列最小加固
///
/// 1. processOfflineQueue 重入保护：status listener / insert 回调在执行期间
///    再次触发时，第二次调用被跳过（返回 0），不重复 removeFirst/insert。
/// 2. insert 幂等预检：data 含 id 且服务端 getById 已有同 id 行 → 跳过 insert
///    （首次 insert 已写入但响应丢失/超时后重试不产生重复记录）。
void main() {
  group('P2: offline queue hardening', () {
    test('重入保护：insert 期间触发的二次 processOfflineQueue 被跳过', () async {
      DatabaseSyncManager? mgrRef;
      final fake = _FakeDatabaseService(
        onInsert: () async {
          await mgrRef?.processOfflineQueue();
        },
      );
      final mgr = DatabaseSyncManager(databaseService: fake);
      mgrRef = mgr;

      mgr.queueOperation(PendingSyncOperation(
        id: 'op-1',
        type: SyncOperationType.insert,
        table: 'transactions',
        data: {'id': 'rec-1', 'amount': 100},
        timestamp: DateTime.now(),
      ));

      final count = await mgr.processOfflineQueue();

      // insert 期间 reentrant 调用被重入保护跳过 → insert 只被调一次
      expect(fake.insertCallCount, 1,
          reason: 'P2：重入保护应跳过并发调用，insert 不得重复执行');
      expect(count, 1);
    });

    test('insert 幂等预检：服务端已有同 id → 跳过 insert 视为成功', () async {
      final fake = _FakeDatabaseService(existingIds: {'rec-1'});
      final mgr = DatabaseSyncManager(databaseService: fake);

      mgr.queueOperation(PendingSyncOperation(
        id: 'op-1',
        type: SyncOperationType.insert,
        table: 'transactions',
        data: {'id': 'rec-1', 'amount': 100},
        timestamp: DateTime.now(),
      ));

      final count = await mgr.processOfflineQueue();

      // 幂等跳过：getById 命中 → insert 未被调用，但操作视为成功完成
      expect(fake.insertCallCount, 0,
          reason: 'P2：服务端已有同 id 行应跳过 insert（幂等重放不重复）');
      expect(fake.getByIdCallCount, greaterThanOrEqualTo(1));
      expect(count, 1, reason: '幂等跳过的操作计为成功');
    });
  });
}

/// 仅实现测试所需方法的 fake：insert 计数 + 可选 reentrant 回调；
/// getById 按 existingIds 返回已存在记录。
class _FakeDatabaseService implements CloudDatabaseService {
  _FakeDatabaseService({this.onInsert, Set<String>? existingIds})
      : existingIds = existingIds ?? {};

  final Future<void> Function()? onInsert;
  // 必须可变：insert 成功后会 add(id)，const {} 会抛 UnsupportedError
  final Set<String> existingIds;
  int insertCallCount = 0;
  int getByIdCallCount = 0;

  @override
  Future<Map<String, dynamic>> insert({
    required String table,
    required Map<String, dynamic> data,
    bool autoInjectUserId = true,
  }) async {
    insertCallCount++;
    final id = data['id']?.toString();
    if (id != null) existingIds.add(id);
    if (onInsert != null) await onInsert!();
    return data;
  }

  @override
  Future<Map<String, dynamic>?> getById({
    required String table,
    required String id,
  }) async {
    getByIdCallCount++;
    if (existingIds.contains(id)) return {'id': id};
    return null;
  }

  // 以下方法测试不涉及
  @override
  Future<Map<String, dynamic>> update({
    required String table,
    required String id,
    required Map<String, dynamic> data,
    bool autoFilterByUser = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> delete({
    required String table,
    required String id,
    bool autoFilterByUser = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> query({
    required String table,
    List<QueryFilter>? filters,
    String? orderBy,
    bool descending = false,
    int? limit,
    int? offset,
    bool autoFilterByUser = true,
  }) =>
      throw UnimplementedError();

  @override
  Stream<DatabaseEvent> subscribe({
    required String table,
    List<QueryFilter>? filters,
    String event = '*',
  }) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> batchInsert({
    required String table,
    required List<Map<String, dynamic>> data,
    bool autoInjectUserId = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> batchUpdate({
    required String table,
    required List<Map<String, dynamic>> data,
    String idField = 'id',
    bool autoFilterByUser = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> batchDelete({
    required String table,
    required List<QueryFilter> filters,
    bool autoFilterByUser = true,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<Map<String, dynamic>>> rawQuery(
    String queryName, {
    Map<String, dynamic>? params,
  }) =>
      throw UnimplementedError();
}
