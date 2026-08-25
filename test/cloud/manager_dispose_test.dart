// F5 回归：TransactionsSyncManager.dispose 必须释放底层 provider
// （关闭 WebDAV dio / S3 http.Client 连接池），并使实例进入不可用态。
//
// syncServiceProvider 在云配置变更时重建实例，此前旧实例无人释放，
// 每次切换云配置都泄漏一个 HTTP 客户端。

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late _DisposeTrackingProvider provider;
  late TransactionsSyncManager manager;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    provider = _DisposeTrackingProvider();
    manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.webdav,
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
  });

  tearDown(() async {
    await db.close();
  });

  test('dispose 释放底层 provider', () async {
    expect(provider.disposed, isFalse);
    await manager.dispose();
    expect(provider.disposed, isTrue,
        reason: 'dispose 必须透传到底层 provider（关闭 HTTP 连接池）');
  });

  test('dispose 后 getStatus 返回「云服务不可用」而非崩溃', () async {
    await manager.dispose();
    final st = await manager.getStatus(ledgerId: 1);
    expect(st.diff, SyncDiff.notLoggedIn);
    expect(st.message, contains('云服务不可用'));
  });

  test('dispose 幂等：重复调用不抛错', () async {
    await manager.dispose();
    await manager.dispose();
    expect(provider.disposedCount, 1,
        reason: 'provider 已置空，第二次 dispose 不应再触发底层释放');
  });
}

class _DisposeTrackingProvider implements fcs.CloudProvider {
  bool disposed = false;
  int disposedCount = 0;

  @override
  fcs.CloudStorageService get storage => _storage;
  final fcs.CloudStorageService _storage = _NoopStorage();

  @override
  String get providerId => 'fake';
  @override
  String get providerName => 'Fake';
  @override
  fcs.CloudAuthService get auth => _FakeAuth();
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {
    disposed = true;
    disposedCount++;
  }
}

class _NoopStorage implements fcs.CloudStorageService {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeAuth implements fcs.CloudAuthService {
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
