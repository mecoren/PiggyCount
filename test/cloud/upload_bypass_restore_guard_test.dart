// P0-1 回归：merge-then-publish 收尾回传不得被 SyncRestoreGuard 拒掉。
//
// 背景（审计发现）：app.dart 用 SyncRestoreGuard.run 包住整个
// StartupSyncChecker.runIfNeeded()，而阶段 2（合并后统一回传）经
// deps.uploadLedger → TransactionsSyncManager.uploadCurrentLedger 调用，
// 其 TSM-P8 守卫在临界区内无条件抛「正在从云端恢复数据」→ 全部回传
// 失败 → 指纹永不收敛 → 每次启动重复弹「云端有更新」死循环。
//
// 修复：uploadCurrentLedger 增加 bypassRestoreGuard 参数（收尾回传豁免
// 通道），StartupSyncCheckerDeps.uploadLedger 实现方（WidgetRefDeps）传
// true。本测试锁死三个语义：
// 1. 临界区内普通上传仍被拒绝（守卫不被修复破坏）；
// 2. 临界区内 bypassRestoreGuard:true 的上传放行（死循环根因消除）；
// 3. 临界区外普通上传不受影响。

import 'package:piggycount/cloud/sync_restore_guard.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  setUp(() {
    while (SyncRestoreGuard.isBusy) {
      SyncRestoreGuard.end();
    }
  });

  test('恢复临界区内：普通上传被拒，bypassRestoreGuard 回传放行', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: 'L',
          currency: const d.Value('CNY'),
          syncId: const d.Value('sync-1'),
        ));

    final storage = _CountingStorage();
    final provider = _FakeProvider(storage);
    final manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.s3,
        name: 'test',
      ),
      db: db,
      repo: _DummyRepo(),
    );
    manager.setSyncManagerForTesting(
      syncManager: fcs.CloudSyncManager<int>(
        provider: provider,
        serializer: _NoopSerializer(),
      ),
      provider: provider,
    );

    await SyncRestoreGuard.run(() async {
      // 1. 普通上传（用户语义）在临界区内必须仍被拒绝
      await expectLater(
        manager.uploadCurrentLedger(ledgerId: 1),
        throwsA(isA<fcs.CloudSyncException>()),
        reason: 'TSM-P8 守卫不得因修复而失效：半恢复态 DB 依然禁止上传',
      );
      expect(storage.uploadCallCount, 0, reason: '被拒上传不得触达云端');

      // 2. P0-1 收尾回传豁免：同临界区内放行（合并事务已提交的一致态）
      await manager.uploadCurrentLedger(
          ledgerId: 1, force: true, bypassRestoreGuard: true);
      expect(storage.uploadCallCount, 1,
          reason: 'merge-then-publish 阶段 2 回传在临界区内必须成功 —— '
              '否则指纹永不收敛，每次启动重复弹「云端有更新」（P0-1 根因）');
    });
  });

  test('临界区外：普通上传不受豁免参数影响（默认放行路径回归）', () async {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: 'L',
          currency: const d.Value('CNY'),
          syncId: const d.Value('sync-1'),
        ));

    final storage = _CountingStorage();
    final provider = _FakeProvider(storage);
    final manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.s3,
        name: 'test',
      ),
      db: db,
      repo: _DummyRepo(),
    );
    manager.setSyncManagerForTesting(
      syncManager: fcs.CloudSyncManager<int>(
        provider: provider,
        serializer: _NoopSerializer(),
      ),
      provider: provider,
    );

    // 临界区外不传豁免参数：走默认守卫检查（不 busy → 放行）
    await manager.uploadCurrentLedger(ledgerId: 1);
    expect(storage.uploadCallCount, 1);
  });
}

/// 计数型 storage：只关心 upload 是否触达云端
class _CountingStorage implements fcs.CloudStorageService {
  int uploadCallCount = 0;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    uploadCallCount++;
  }

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async => const [];

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async => null;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeProvider implements fcs.CloudProvider {
  @override
  final fcs.CloudStorageService storage;
  _FakeProvider(this.storage);

  @override
  String get providerId => 'fake';
  @override
  String get providerName => 'Fake';
  @override
  fcs.CloudAuthService get auth => _FakeAuthService();
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
}

class _FakeAuthService implements fcs.CloudAuthService {
  @override
  Future<fcs.CloudUser?> get currentUser async =>
      const fcs.CloudUser(id: 'test-user');
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NoopSerializer implements fcs.DataSerializer<int> {
  @override
  Future<String> serialize(int data) async => '';
  @override
  Future<int> deserialize(String data) async => 0;
  @override
  String fingerprint(String data) => '';
}

class _DummyRepo implements BaseRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
