// W6/S6 回归：restoreAllRemoteLedgers 必须处于 SyncRestoreGuard 恢复临界区。
//
// 此前仅 fullRestoreAllRemoteLedgers / downloadAndRestoreToCurrentLedger
// 有守卫，批量恢复入口（ledgers_page_new 调用）遗漏 —— 批量恢复进行到
// 一半时到点的定时备份（app.dart tick 检查 SyncRestoreGuard.isBusy 让位）
// 会把半恢复态 DB 打包上传，覆盖当日好备份。
//
// 本测试通过 fake storage 在 list() 执行期间采样 SyncRestoreGuard.isBusy，
// 锁死「整个恢复流程处于临界区内、结束后释放」的语义。

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:piggycount/cloud/sync_restore_guard.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  // 全局 logger 初始化会读 SharedPreferences，缺 mock 会抛
  // MissingPluginException 且落在测试结束后（"failed after completed"）
  SharedPreferences.setMockInitialValues({});

  tearDown(() {
    // 隔离：防止用例失败时残留临界区状态污染后续用例
    while (SyncRestoreGuard.isBusy) {
      SyncRestoreGuard.end();
    }
  });

  TransactionsSyncManager buildManager(_ProbeStorage storage) {
    final db = PiggyDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final provider = _FakeCloudProvider(storage);
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
    return manager;
  }

  test('restoreAllRemoteLedgers 执行期间 SyncRestoreGuard 处于 busy', () async {
    final storage = _ProbeStorage();
    final manager = buildManager(storage);

    await manager.restoreAllRemoteLedgers();

    expect(storage.busyDuringList, isTrue,
        reason: 'list 是恢复流程第一步，此刻必须已在恢复临界区内'
            '（否则定时备份可在半恢复态打包上传）');
  });

  test('正常完成后守卫释放', () async {
    final storage = _ProbeStorage();
    final manager = buildManager(storage);

    await manager.restoreAllRemoteLedgers();

    expect(SyncRestoreGuard.isBusy, isFalse);
  });

  test('中途抛异常时守卫同样释放', () async {
    final storage = _ProbeStorage(throwOnList: true);
    final manager = buildManager(storage);

    await expectLater(
      manager.restoreAllRemoteLedgers(),
      throwsA(isA<fcs.CloudStorageException>()),
    );

    expect(SyncRestoreGuard.isBusy, isFalse,
        reason: '守卫必须用 try/finally 语义包裹，异常路径不得泄漏临界区');
  });
}

/// 记录 list() 执行时是否处于恢复临界区的探针 storage
class _ProbeStorage implements fcs.CloudStorageService {
  final bool throwOnList;
  bool busyDuringList = false;

  _ProbeStorage({this.throwOnList = false});

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    busyDuringList = SyncRestoreGuard.isBusy;
    if (throwOnList) {
      throw fcs.CloudStorageException('probe failure');
    }
    return const [];
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeCloudProvider implements fcs.CloudProvider {
  @override
  final fcs.CloudStorageService storage;
  _FakeCloudProvider(this.storage);

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
