// M7：上传冲突拦截（last-writer-wins 止血）单元测试
//
// 验证 uploadCurrentLedger 在非 force 模式下的冲突判定链：
// 云端无快照 → 直接传；指纹一致 → 直接传；指纹不同且云端较新 → 抛
// CloudConflictException；force:true → 无条件放行。

import 'dart:convert';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/cloud/sync_service.dart';
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

  late PiggyDatabase db;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: 'L',
          currency: const d.Value('CNY'),
        ));
    await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 12.34,
            happenedAt: d.Value(DateTime(2026, 7, 1)),
            syncId: const d.Value('tx-1'),
          ),
        );
  });

  tearDown(() async {
    await db.close();
  });

  /// 本地快照的真实内容指纹（与 uploadCurrentLedger 内部算法同源）
  Future<String> computeLocalFingerprint() async {
    final jsonStr = await exportTransactionsJson(db, 1);
    return contentFingerprintFromMap(jsonDecode(jsonStr));
  }

  TransactionsSyncManager buildManager(_FakeConflictStorage storage) {
    final provider = _FakeProvider(storage);
    final manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.supabase,
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

  test('云端无快照（getMetadata 为 null）→ 直接上传，无冲突', () async {
    final storage = _FakeConflictStorage(metadata: null);
    final manager = buildManager(storage);

    await manager.uploadCurrentLedger(ledgerId: 1);

    expect(storage.uploadCallCount, 1, reason: 'localOnly 应直接放行上传');
  });

  test('指纹一致 → 直接上传，无冲突', () async {
    final fp = await computeLocalFingerprint();
    final storage = _FakeConflictStorage(metadata: {'fingerprint': fp});
    final manager = buildManager(storage);

    await manager.uploadCurrentLedger(ledgerId: 1);

    expect(storage.uploadCallCount, 1, reason: '内容一致是最常见快路径');
  });

  test('指纹不同且云端较新（uploadedAt 在未来）→ 抛 CloudConflictException 且不上传',
      () async {
    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'not-the-local-fingerprint',
      'uploadedAt': DateTime.now()
          .add(const Duration(days: 365))
          .toUtc()
          .toIso8601String(),
    });
    final manager = buildManager(storage);
    // 冷启动无内存墙钟也无 local_changes → localAt=null → 判 unknown；
    // 这里先 markLocalChanged 提供本地墙钟，使仲裁走「云端较新」分支
    manager.markLocalChanged(ledgerId: 1);

    await expectLater(
      manager.uploadCurrentLedger(ledgerId: 1),
      throwsA(isA<CloudConflictException>()
          .having((e) => e.isCloudNewer, 'isCloudNewer', isTrue)),
    );
    expect(storage.uploadCallCount, 0,
        reason: '冲突未确认前绝不能覆盖云端快照');
  });

  test('指纹不同但本地墙钟更新 → 正常覆盖语义放行', () async {
    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'stale-fingerprint',
      // 上传时间在过去（本地交易发生在 2026-07-01 之后、当前时间之前）
      'uploadedAt': DateTime(2026, 7, 2).toUtc().toIso8601String(),
    });
    final manager = buildManager(storage);
    manager.markLocalChanged(ledgerId: 1); // 本地墙钟 = now > uploadedAt

    await manager.uploadCurrentLedger(ledgerId: 1);

    expect(storage.uploadCallCount, 1,
        reason: '本地较新时覆盖云端是既定语义，不应拦截');
  });

  test('指纹不同且无任何墙钟可判 → 判 unknown 抛冲突', () async {
    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'different',
      'uploadedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final manager = buildManager(storage);
    // 不调用 markLocalChanged，DB 也无 local_changes → localAt=null

    await expectLater(
      manager.uploadCurrentLedger(ledgerId: 1),
      throwsA(isA<CloudConflictException>()
          .having((e) => e.isCloudNewer, 'isCloudNewer', isFalse)),
    );
    expect(storage.uploadCallCount, 0);
  });

  test('force:true → 冲突存在也无条件放行', () async {
    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'conflicting',
      'uploadedAt': DateTime.now()
          .add(const Duration(days: 365))
          .toUtc()
          .toIso8601String(),
    });
    final manager = buildManager(storage);
    manager.markLocalChanged(ledgerId: 1);

    await manager.uploadCurrentLedger(ledgerId: 1, force: true);

    expect(storage.uploadCallCount, 1, reason: '用户确认后必须能完成覆盖上传');
  });

  test('getMetadata 探测自身失败 → 放行上传（可用性优先）', () async {
    final storage = _FakeConflictStorage(metadata: null)
      ..metadataError = Exception('simulated network error');
    final manager = buildManager(storage);

    await manager.uploadCurrentLedger(ledgerId: 1);

    expect(storage.uploadCallCount, 1,
        reason: '探测失败不应阻塞上传——行为等同修复前的旧版');
  });

  test('方向仲裁：仅剩已推送的 local_changes（时间戳失真）→ 判 unknown 拦截，不放行覆盖',
      () async {
    // 场景：recordChanges:false 导入（快照恢复/fullPull）改写了本地内容，
    // 但不写 local_changes —— 表里只剩历史已推送行的陈旧时间戳。
    // 若照旧信这个时间戳判「本地较新」，会自动覆盖云端他机数据。
    await db.into(db.localChanges).insert(
          LocalChangesCompanion.insert(
            entityType: 'transaction',
            entityId: 1,
            entitySyncId: 'tx-1',
            action: 'update',
            ledgerId: 1,
            createdAt: d.Value(DateTime(2026, 7, 2)),
            pushedAt: d.Value(DateTime(2026, 7, 3)), // 已推送
          ),
        );

    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'stale-fingerprint',
      // 云端比陈旧时间戳更旧 → 旧逻辑会误判「本地较新」直接放行
      'uploadedAt': DateTime(2026, 7, 1).toUtc().toIso8601String(),
    });
    final manager = buildManager(storage);
    // 不调用 markLocalChanged：模拟冷启动后纯导入场景

    await expectLater(
      manager.uploadCurrentLedger(ledgerId: 1),
      throwsA(isA<CloudConflictException>()
          .having((e) => e.isCloudNewer, 'isCloudNewer', isFalse)),
      reason: '时间戳不可信时必须按 unknown 冲突拦截，给出对比合并入口而非静默覆盖',
    );
    expect(storage.uploadCallCount, 0);
  });

  test('方向仲裁：存在未推送 local_changes 且本地较新 → 正常放行覆盖', () async {
    await db.into(db.localChanges).insert(
          LocalChangesCompanion.insert(
            entityType: 'transaction',
            entityId: 1,
            entitySyncId: 'tx-1',
            action: 'update',
            ledgerId: 1,
            createdAt:
                d.Value(DateTime.now().subtract(const Duration(hours: 1))),
            // pushedAt 为空 = 未推送 = 时间戳可信的编辑证据
          ),
        );

    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'stale-fingerprint',
      'uploadedAt': DateTime(2026, 1, 1).toUtc().toIso8601String(),
    });
    final manager = buildManager(storage);

    await manager.uploadCurrentLedger(ledgerId: 1);

    expect(storage.uploadCallCount, 1,
        reason: '未推送行佐证本地确有新编辑，正常覆盖语义放行');
  });

  test('方向仲裁：未推送但云端更新 → cloudNewer 冲突', () async {
    await db.into(db.localChanges).insert(
          LocalChangesCompanion.insert(
            entityType: 'transaction',
            entityId: 1,
            entitySyncId: 'tx-1',
            action: 'update',
            ledgerId: 1,
            createdAt: d.Value(DateTime(2026, 1, 1)),
          ),
        );

    final storage = _FakeConflictStorage(metadata: {
      'fingerprint': 'different-fingerprint',
      'uploadedAt': DateTime.now().toUtc().toIso8601String(),
    });
    final manager = buildManager(storage);

    await expectLater(
      manager.uploadCurrentLedger(ledgerId: 1),
      throwsA(isA<CloudConflictException>()
          .having((e) => e.isCloudNewer, 'isCloudNewer', isTrue)),
    );
    expect(storage.uploadCallCount, 0);
  });
}

class _FakeConflictStorage implements fcs.CloudStorageService {
  Map<String, String>? metadata;
  Object? metadataError;
  int uploadCallCount = 0;

  _FakeConflictStorage({required this.metadata});

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async {
    if (metadataError != null) throw metadataError!;
    if (metadata == null) return null;
    return fcs.CloudFile(
      name: path,
      path: path,
      size: 100,
      lastModified: DateTime(2026, 7, 1),
      metadata: metadata,
    );
  }

  @override
  Future<String?> download({required String path}) async => null;

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    uploadCallCount++;
  }

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async => [];

  @override
  Future<bool> exists({required String path}) async => false;
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
  fcs.CloudAuthService get auth => _FakeAuth();
  @override
  Future<void> initialize(Map<String, dynamic> config) async {}
  @override
  bool validateConfig(Map<String, dynamic> config) => true;
  @override
  Future<void> dispose() async {}
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
