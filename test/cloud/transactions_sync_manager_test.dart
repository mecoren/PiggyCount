// TransactionsSyncManager 单元测试
//
// 测试策略：通过 @visibleForTesting 注入 fake CloudProvider + CloudSyncManager，
// 验证 getStatus 在异常路径下的缓存行为（US-6）与 salt 错配降级（US-2）等。
// 不依赖真实网络 / 真实云服务。

import 'dart:async';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs hide SyncStatus;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart' show SyncStatus, SyncDiff;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() async {
    await db.close();
  });

  group('US-6: getStatus 错误状态不缓存', () {
    test('第一次抛异常第二次成功时，第二次返回成功状态（非缓存错误）', () async {
      // Arrange: 构造一个 fake storage，第一次 download 抛异常，第二次返回有效 JSON
      final fakeStorage = _ThrowThenSuccessStorage(
        throwOnFirst: true,
        successJson: _emptyLedgerJson(ledgerId: 1),
      );
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);
      final syncManager = fcs.CloudSyncManager<int>(
        provider: fakeProvider,
        serializer: _NoopSerializer(),
      );

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: _DummyRepo(),
      );
      // 注入 fake syncManager，跳过真实初始化
      manager.setSyncManagerForTesting(
        syncManager: syncManager,
        provider: fakeProvider,
      );

      // 预置一个 ledger 行，让 exportTransactionsJson 能查到
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'test',
            currency: const d.Value('CNY'),
          ));

      // Act & Assert: 第一次调用应返回 error
      final status1 = await manager.getStatus(ledgerId: 1);
      expect(status1.diff, SyncDiff.error,
          reason: '第一次调用应因 storage 抛异常而返回 error');

      // Act & Assert: 第二次调用应返回非 error（证明未读缓存）
      final status2 = await manager.getStatus(ledgerId: 1);
      expect(status2.diff, isNot(SyncDiff.error),
          reason: '第二次调用应重新走完整流程并成功，不应返回缓存的 error 状态');
      expect(fakeStorage.downloadCallCount, greaterThanOrEqualTo(2),
          reason: '第二次调用应实际触发 storage.download，而非读缓存');
    });
  });

  group('US-1: downloadAndRestoreToCurrentLedger 恢复前清空账本', () {
    test('本地已有交易时，恢复云端同 syncId 交易不应产生重复行', () async {
      // Arrange: 用真实 LocalRepository 让 importTransactionsJson 走真实写入路径
      final repo = LocalRepository(db);

      // 预置账本 + 一笔本地交易（syncId=tx-1）
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));
      await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 100.0,
              happenedAt: d.Value(DateTime(2026, 7, 1)),
              syncId: const d.Value('tx-1'),
            ),
          );

      // 云端 JSON 含同一笔交易（syncId=tx-1），金额不同以便区分
      final cloudJson = _ledgerJsonWithOneTx(
        ledgerId: 1,
        syncId: 'tx-1',
        amount: 200.0,
      );

      final fakeStorage = _FakeStorage(returnJson: cloudJson);
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: repo,
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act: 恢复云端数据
      final result = await manager.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      // Assert: 本地应只有 1 笔交易（云端版本覆盖本地，不产生重复）
      final txs = await db.select(db.transactions).get();
      expect(txs.length, 1,
          reason: '恢复后本地应只有云端那 1 笔交易，不应有重复行');
      expect(txs.first.amount, 200.0,
          reason: '保留的应是云端版本（amount=200）');
      expect(result.inserted, 1);
    });

    test('本地有多笔交易时，恢复后只剩云端 JSON 中的交易', () async {
      // Arrange
      final repo = LocalRepository(db);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));
      // 本地有 3 笔交易，syncId 各不同
      for (var i = 1; i <= 3; i++) {
        await db.into(db.transactions).insert(
              TransactionsCompanion.insert(
                ledgerId: 1,
                type: 'expense',
                amount: i * 10.0,
                happenedAt: d.Value(DateTime(2026, 7, i)),
                syncId: d.Value('local-$i'),
              ),
            );
      }

      // 云端 JSON 仅含 1 笔（syncId=cloud-1），完全不同的 syncId
      final cloudJson = _ledgerJsonWithOneTx(
        ledgerId: 1,
        syncId: 'cloud-1',
        amount: 99.0,
      );

      final fakeStorage = _FakeStorage(returnJson: cloudJson);
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);
      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: repo,
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act
      await manager.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      // Assert: 本地应只剩 1 笔（云端的），本地独有的 3 笔应被清空
      final txs = await db.select(db.transactions).get();
      expect(txs.length, 1,
          reason: '恢复后本地应只剩云端 JSON 中的 1 笔交易');
      expect(txs.first.syncId, 'cloud-1');
    });
  });
}

// --- Fakes ---

/// 第一次 download 抛异常，之后返回 [successJson]
class _ThrowThenSuccessStorage implements fcs.CloudStorageService {
  final bool throwOnFirst;
  final String successJson;
  int downloadCallCount = 0;

  _ThrowThenSuccessStorage({
    required this.throwOnFirst,
    required this.successJson,
  });

  @override
  Future<String?> download({required String path}) async {
    downloadCallCount++;
    if (throwOnFirst && downloadCallCount == 1) {
      throw Exception('simulated network error');
    }
    return successJson;
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {}

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async => [];

  @override
  Future<bool> exists({required String path}) async => false;

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async {
    // 返回非 null，让 fcs.CloudSyncManager 继续走 download 路径
    return fcs.CloudFile(
      name: path,
      path: path,
      size: 100,
      lastModified: DateTime.now(),
      metadata: const {'uploadedAt': '2026-07-28T10:00:00Z'},
    );
  }
}

class _FakeCloudProvider implements fcs.CloudProvider {
  final fcs.CloudStorageService storage;
  _FakeCloudProvider({required this.storage});

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

String _emptyLedgerJson({required int ledgerId}) {
  return '{"version":6,"exportedAt":"2026-07-28T10:00:00Z",'
      '"ledgerId":$ledgerId,"ledgerName":"test","currency":"CNY","count":0,'
      '"accounts":[],"categories":[],"tags":[],"items":[]}';
}

/// 构造包含 1 笔交易的 ledger JSON（v6 格式，带 syncId）
String _ledgerJsonWithOneTx({
  required int ledgerId,
  required String syncId,
  required double amount,
}) {
  return '{"version":6,"exportedAt":"2026-07-28T10:00:00Z",'
      '"ledgerId":$ledgerId,"ledgerName":"test","currency":"CNY","count":1,'
      '"accounts":[],"categories":[],"tags":[],'
      '"items":[{"type":"expense","amount":$amount,'
      '"categoryName":null,"categoryKind":null,'
      '"happenedAt":"2026-07-01T00:00:00.000","note":"test",'
      '"tags":"","syncId":"$syncId"}]}';
}

/// 简单 fake storage：download 永远返回 [returnJson]
class _FakeStorage implements fcs.CloudStorageService {
  final String returnJson;
  _FakeStorage({required this.returnJson});

  @override
  Future<String?> download({required String path}) async => returnJson;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {}

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async => [];

  @override
  Future<bool> exists({required String path}) async => true;

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async {
    return fcs.CloudFile(
      name: path,
      path: path,
      size: 100,
      lastModified: DateTime.now(),
      metadata: const {'uploadedAt': '2026-07-28T10:00:00Z'},
    );
  }
}
