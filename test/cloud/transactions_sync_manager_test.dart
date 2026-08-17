// TransactionsSyncManager 单元测试
//
// 测试策略：通过 @visibleForTesting 注入 fake CloudProvider + CloudSyncManager，
// 验证 getStatus 在异常路径下的缓存行为（US-6）与 salt 错配降级（US-2）等。
// 不依赖真实网络 / 真实云服务。

import 'dart:async';
import 'dart:convert';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';
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

  group('H2: downloadRemoteLedger 同名账本真覆盖语义', () {
    test('本地同名账本下载恢复后以云端为准，不追加翻倍', () async {
      // Arrange: 真实 LocalRepository + 本地同名账本（2 笔本地交易）
      final repo = LocalRepository(db);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));
      for (var i = 1; i <= 2; i++) {
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

      // 云端快照只有 1 笔（syncId 与本地均不同）
      final cloudJson = _ledgerJsonWithOneTx(
        ledgerId: 1,
        syncId: 'cloud-1',
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

      // Act: 下载同名账本（remoteId=1 与本地一致，避免触发换名上传分支）
      final ledgerId = await manager.downloadRemoteLedger(
          name: 'L', currency: 'CNY', remotePath: 'ledger_1.json');

      // Assert: 覆盖语义 —— 本地 2 笔被云端 1 笔替换，而非追加成 3 笔
      expect(ledgerId, 1);
      final txs = await db.select(db.transactions).get();
      expect(txs.length, 1,
          reason: 'H2：同名账本「下载恢复」应为覆盖语义（清空再导入），'
              '旧实现的追加合并会让交易翻倍');
      expect(txs.first.amount, 200.0);
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

    test('缺口 2: deletedDup 应反映清空阶段的本地独有行数', () async {
      // Arrange
      final repo = LocalRepository(db);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));
      // 本地有 3 笔独有交易（syncId 与云端不同）
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

      // 云端 JSON 含 1 笔完全不同的交易
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
      final result = await manager.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      // Assert: deletedDup 应为 3（清空的本地独有行数），而非 0
      expect(result.deletedDup, 3,
          reason: 'deletedDup 应反映清空阶段删除的本地交易行数（AC-1.3）');
      expect(result.inserted, 1,
          reason: 'inserted 应为云端导入的 1 笔');
    });
  });

  group('BUG-1 残余: disable 后密钥仍保留应从云端密文恢复', () {
    test('加密已关闭(disable)但密钥仍在 secure storage 时，恢复不应被跳过',
        () async {
      // Arrange: 用真实 LocalRepository 让 importTransactionsJson 走真实写入路径
      final repo = LocalRepository(db);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));

      final cloudJson = _ledgerJsonWithOneTx(
        ledgerId: 1,
        syncId: 'cloud-1',
        amount: 99.0,
      );

      // 合法密文：BEECRYPT1:<16字节salt>:<≥28字节payload>
      final saltB64 = base64.encode(List<int>.filled(16, 0));
      final payloadB64 = base64.encode(List<int>.filled(32, 1));
      final ciphertext = 'BEECRYPT1:$saltB64:$payloadB64';

      // 模拟 disable 后的真实状态：
      // - 云端仍是密文 → provider 未被装饰，storage.download 返回原始密文
      // - 本地加密服务 isEnabled=false（provider 不被装饰），但 hasActiveKey=true
      //   （disable 保留 secure storage 密钥），decrypt 可还原明文
      final fakeStorage = _FakeStorage(returnJson: ciphertext);
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: repo,
        encryptionService:
            _DisabledButKeyedEncryptionService(decrypted: cloudJson),
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act: 恢复云端数据（此时加密已关闭）
      final result =
          await manager.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      // Assert: 密钥仍在，应从密文解密并恢复，而非被 _decryptIfNeeded 判为不可读跳过
      expect(result.inserted, 1,
          reason: 'disable 后密钥仍保留，应从云端密文解密恢复，inserted=1');
      final txs = await db.select(db.transactions).get();
      expect(txs.length, 1,
          reason: '恢复后本地应只有云端那 1 笔交易');
      expect(txs.first.amount, 99.0,
          reason: '恢复的应是云端版本（amount=99）');
    });

  });

  group('BUG-2 残留: 从未开启加密/reset 后无密钥应引导而非静默跳过', () {
    test(
        'reset/从未开启加密后无密钥时，downloadAndRestore 应抛 CloudEncryptedLocallyDisabledException 引导开启加密',
        () async {
      // Arrange
      final repo = LocalRepository(db);
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'L',
            currency: const d.Value('CNY'),
          ));

      final saltB64 = base64.encode(List<int>.filled(16, 0));
      final payloadB64 = base64.encode(List<int>.filled(32, 1));
      final ciphertext = 'BEECRYPT1:$saltB64:$payloadB64';

      // 模拟 reset/从未开启加密后的真实状态：
      // - 云端仍是密文 → provider 未被装饰，storage.download 返回原始密文
      // - 本地 isEnabled=false 且 hasActiveKey=false（无密钥可解密）
      final fakeStorage = _FakeStorage(returnJson: ciphertext);
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: repo,
        encryptionService: _DisabledNoKeyEncryptionService(),
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act & Assert: 无密钥且云端为密文，应抛专属异常
      // （非静默返回 0,0 让用户误以为云端无数据，非 FormatException 崩溃）
      await expectLater(
        manager.downloadAndRestoreToCurrentLedger(ledgerId: 1),
        throwsA(isA<CloudEncryptedLocallyDisabledException>()),
      );
      final txs = await db.select(db.transactions).get();
      expect(txs.length, 0, reason: '异常在导入前抛出，本地不应被污染');
    });

    test(
        'getStatus 在从未开启加密且云端为密文时返回 cloud_encrypted_locally_disabled 哨兵',
        () async {
      // Arrange: 预置 ledger 行（exportTransactionsJson 计算本地指纹需要）
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'test',
            currency: const d.Value('CNY'),
          ));

      final saltB64 = base64.encode(List<int>.filled(16, 0));
      final payloadB64 = base64.encode(List<int>.filled(32, 1));
      final ciphertext = 'BEECRYPT1:$saltB64:$payloadB64';

      // 从未开启加密：isEnabled=false 且 hasActiveKey=false；云端为密文
      final fakeStorage = _FakeStorage(returnJson: ciphertext);
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: _DummyRepo(),
        encryptionService: _DisabledNoKeyEncryptionService(),
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act
      final status = await manager.getStatus(ledgerId: 1);

      // Assert: 应返回 error + 哨兵 message，供 UI 识别并引导用户开启加密
      expect(status.diff, SyncDiff.error);
      expect(status.message, 'cloud_encrypted_locally_disabled',
          reason: '从未开启加密且云端为密文应返回哨兵，而非把密文当 JSON 解析报错');
    });

    test('getStatus 在云端为明文时不误报 cloud_encrypted_locally_disabled', () async {
      // Arrange: 从未开启加密但云端是 legacy 明文 → 正常流程，不触发哨兵
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'test',
            currency: const d.Value('CNY'),
          ));

      final fakeStorage =
          _FakeStorage(returnJson: _emptyLedgerJson(ledgerId: 1));
      final fakeProvider = _FakeCloudProvider(storage: fakeStorage);

      final manager = TransactionsSyncManager(
        config: const fcs.CloudServiceConfig(
          type: fcs.CloudBackendType.supabase,
          name: 'test',
        ),
        db: db,
        repo: _DummyRepo(),
        encryptionService: _DisabledNoKeyEncryptionService(),
      );
      manager.setSyncManagerForTesting(
        syncManager: fcs.CloudSyncManager<int>(
          provider: fakeProvider,
          serializer: _NoopSerializer(),
        ),
        provider: fakeProvider,
      );

      // Act
      final status = await manager.getStatus(ledgerId: 1);

      // Assert: 明文云端不应误报哨兵（应走正常流程返回非 cloud_encrypted_locally_disabled）
      expect(status.message, isNot('cloud_encrypted_locally_disabled'),
          reason: '云端为明文时不应触发 cloud_encrypted_locally_disabled 哨兵');
    });
  });

  group('缺口 1: getStatus 在 SaltMismatchException 时返回哨兵 message', () {
    test('storage.download 抛 SaltMismatchException → message 为 salt_mismatch_need_password', () async {
      // Arrange: 用一个抛 SaltMismatchException 的 fake storage
      final fakeStorage = _SaltMismatchStorage();
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
      manager.setSyncManagerForTesting(
        syncManager: syncManager,
        provider: fakeProvider,
      );

      // 预置 ledger 行
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'test',
            currency: const d.Value('CNY'),
          ));

      // Act
      final status = await manager.getStatus(ledgerId: 1);

      // Assert: 应返回 error + 哨兵 message，而非原始异常文本
      expect(status.diff, SyncDiff.error);
      expect(status.message, 'salt_mismatch_need_password',
          reason: 'SaltMismatchException 应转为哨兵 message 供 UI 识别');
    });

    test('SaltMismatchException 哨兵状态不被缓存', () async {
      // Arrange
      final fakeStorage = _SaltMismatchStorage();
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
      manager.setSyncManagerForTesting(
        syncManager: syncManager,
        provider: fakeProvider,
      );

      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: const d.Value(1),
            name: 'test',
            currency: const d.Value('CNY'),
          ));

      // Act: 第一次调用
      final status1 = await manager.getStatus(ledgerId: 1);
      expect(status1.message, 'salt_mismatch_need_password');

      // Assert: 第二次调用应重新走完整流程（非读缓存）
      // 如果缓存了，第二次会直接返回缓存的 error 而不再调用 download
      final status2 = await manager.getStatus(ledgerId: 1);
      expect(status2.message, 'salt_mismatch_need_password',
          reason: '第二次调用应重新走流程，不应读缓存');
      expect(fakeStorage.downloadCallCount, greaterThanOrEqualTo(2),
          reason: '第二次调用应实际触发 download');
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

/// 模拟加密层 salt 不匹配：download 永远抛 SaltMismatchException
class _SaltMismatchStorage implements fcs.CloudStorageService {
  int downloadCallCount = 0;

  @override
  Future<String?> download({required String path}) async {
    downloadCallCount++;
    throw const SaltMismatchException(
      '密文 salt 与当前密钥不匹配',
      ciphertextSaltBase64: 'AAAAAAAAAAAAAAAAAAAAAA==',
    );
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

/// 模拟「已关闭加密(disable)但密钥仍保留」的加密服务：
/// isEnabled=false（provider 不被装饰），hasActiveKey=true（secure storage 有密钥），
/// decrypt 把 BEECRYPT1: 密文还原为预置的明文 JSON。
class _DisabledButKeyedEncryptionService implements EncryptionService {
  final String decrypted;
  _DisabledButKeyedEncryptionService({required this.decrypted});

  @override
  Future<bool> get isEnabled => Future.value(false);

  @override
  Future<bool> get hasActiveKey => Future.value(true);

  @override
  Future<String> decrypt(String ciphertext) async => decrypted;

  // 其余方法测试中不会触发
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

/// 模拟「reset 后密钥清空」的加密服务：
/// isEnabled=false 且 hasActiveKey=false → 本地确实无法解密。
class _DisabledNoKeyEncryptionService implements EncryptionService {
  @override
  Future<bool> get isEnabled => Future.value(false);

  @override
  Future<bool> get hasActiveKey => Future.value(false);

  // 其余方法测试中不会触发
  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}
