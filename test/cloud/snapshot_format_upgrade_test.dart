// v10 快照格式升级（强一致方案）单元测试
//
// 背景：v10 移除共享账本残留键，**内容指纹算法随之改变** —— 同一份内容在
// v9 与 v10 下算出不同指纹。云端若仍是旧版本 App 写入的 v9 快照，本机新算法
// 指纹与云端存量指纹永远不相等：状态卡永久显示「有差异」、启动检查每轮把该
// 账本判为方向未知而不处理（反复提示但永不收敛）。
//
// 方案（用户决策）：格式版本 9 → 10，遇到版本不一致时判定为「升级后一次
// 全量重传」——把云端改写为当前格式，两端口径随即一致、正常收敛。
//
// 本文件验证三条不变量：
// 1. 旧格式 + 内容与本地一致 → 判定需要重传（uploadCurrentLedger 非 force
//    路径也直接放行，不再要求用户二选一）；
// 2. 旧格式但内容确实不同 → 判定不重传，冲突拦截语义原样保留
//    （绝不自动覆盖对端可能更新的数据）；
// 3. 云端已是当前格式 → 零下载跳过（升级只在过渡期发生一次）。

import 'dart:convert';

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

  /// 本地导出 JSON 的解析形态。直接复用它作为云端内容，就构造出
  /// 「内容与本地完全一致」的云端快照（连 exportedAt 等旁路字段都同源）。
  Future<Map<String, dynamic>> localPayload() async {
    final jsonStr = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
    return jsonDecode(jsonStr) as Map<String, dynamic>;
  }

  /// 模拟「旧版本 App 写入的 v9 快照」：version=9 + 旧算法指纹字面量。
  ///
  /// 内容仍与本地一致 —— 差异只在指纹口径，这正是升级窗口的真实形态。
  /// [mutate] 用于制造「内容确实不同」的对照组。
  Future<String> legacyV9Snapshot({
    void Function(Map<String, dynamic> payload)? mutate,
    int version = 9,
  }) async {
    final payload = await localPayload();
    payload['version'] = version;
    payload['contentFingerprint'] = 'legacy-algorithm-fingerprint';
    mutate?.call(payload);
    return jsonEncode(payload);
  }

  TransactionsSyncManager buildManager(_UpgradeStorage storage) {
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

  group('shouldRepublishSnapshotForFormatUpgrade：判定', () {
    test('云端 v9 旧格式 + 内容与本地一致 → 判定需要一次性全量重传', () async {
      final storage = _UpgradeStorage(
        metadata: const {'fingerprint': 'legacy-algorithm-fingerprint'},
        snapshot: await legacyV9Snapshot(),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isTrue,
        reason: '指纹不相等纯属算法口径（v10 删键），内容其实一致 → 重传即收敛',
      );
      expect(storage.downloadCallCount, 1, reason: 'metadata 无版本标注 → 下载读内嵌 version');
      expect(storage.uploadCallCount, 0, reason: '判定是只读的，上传由调用方编排');
    });

    test('云端 v9 旧格式但内容确实不同 → 不重传（绝不自动覆盖对端数据）', () async {
      final storage = _UpgradeStorage(
        metadata: const {'fingerprint': 'legacy-algorithm-fingerprint'},
        snapshot: await legacyV9Snapshot(
          mutate: (p) => p['ledgerName'] = '别的设备改过的账本名',
        ),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
        reason: '账本名进指纹（M2）→ 重算指纹不等即视为真实数据差异，交回冲突/合并流程',
      );
    });

    test('云端已是当前格式（metadata snapshotVersion=10）→ 零下载跳过', () async {
      final storage = _UpgradeStorage(
        metadata: const {
          'snapshotVersion': '$kSnapshotFormatVersion',
          'fingerprint': 'whatever',
        },
        snapshot: await legacyV9Snapshot(version: kSnapshotFormatVersion),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
      );
      expect(storage.downloadCallCount, 0,
          reason: '升级只发生一次；已收敛账本每轮启动不应付下载成本');
    });

    test('metadata 无标注但内嵌已是 v10（网关剥头）→ 不重传', () async {
      final storage = _UpgradeStorage(
        metadata: const {'fingerprint': 'whatever'},
        snapshot: await legacyV9Snapshot(version: kSnapshotFormatVersion),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
        reason: '内嵌 version 才是权威：metadata 缺失不能反推「旧格式」',
      );
      expect(storage.downloadCallCount, 1);
    });

    test('云端无备份 → 不重传（首次上传走各自路径）', () async {
      final storage = _UpgradeStorage(metadata: null, snapshot: null);
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
      );
      expect(storage.downloadCallCount, 0);
    });

    test('云端不可读（下载抛异常）→ 降级为不处理，不抛出', () async {
      final storage = _UpgradeStorage(metadata: const {'fingerprint': 'x'})
        ..downloadError = Exception('simulated network error');
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
        reason: '本地数据未变，判定失败下次启动重试即可，不该成为新的失败点',
      );
    });

    test('旧格式判据与「重算指纹」共用当前算法：旧快照残留键不污染结果', () async {
      // 模拟真实 v9 内容：带共享账本时代的 override 键（v10 已从白名单移除），
      // 白名单式指纹函数忽略它们 → 重算值仍与本地相等 → 判定需要重传。
      final storage = _UpgradeStorage(
        metadata: const {'fingerprint': 'legacy-algorithm-fingerprint'},
        snapshot: await legacyV9Snapshot(mutate: (p) {
          final items = (p['items'] as List).cast<Map<String, dynamic>>();
          if (items.isNotEmpty) {
            items.first['categorySyncIdOverride'] = 'shared-era-category-sync-id';
          }
        }),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isTrue,
        reason: 'v9 残留键不在当前指纹白名单内 → 不影响「内容是否一致」的判定',
      );
    });
  });

  group('上传路径：旧格式 + 内容一致不再要求用户二选一', () {
    test('云端 v9 旧格式 + 内容一致 + 云端时间戳更新 → 直接放行上传（不抛冲突）', () async {
      final storage = _UpgradeStorage(
        metadata: {
          'fingerprint': 'legacy-algorithm-fingerprint',
          // 云端时间戳在未来：若仍按旧逻辑做方向仲裁，冷启动会判 unknown
          // 冲突 → 用户被要求二选一（正是要消除的「反复弹差异」）
          'uploadedAt': DateTime.now()
              .add(const Duration(days: 365))
              .toUtc()
              .toIso8601String(),
        },
        snapshot: await legacyV9Snapshot(),
      );
      final manager = buildManager(storage);

      await manager.uploadCurrentLedger(ledgerId: 1);

      expect(storage.uploadCallCount, 1,
          reason: '格式升级窗口内，内容一致的重传不该让用户做覆盖/合并决策');
    });

    test('云端 v9 旧格式但内容确实不同 → 仍按冲突拦截（安全语义不变）', () async {
      final storage = _UpgradeStorage(
        metadata: {
          'fingerprint': 'legacy-algorithm-fingerprint',
          'uploadedAt': DateTime.now()
              .add(const Duration(days: 365))
              .toUtc()
              .toIso8601String(),
        },
        snapshot: await legacyV9Snapshot(mutate: (p) {
          final items = (p['items'] as List).cast<Map<String, dynamic>>();
          items.first['amount'] = 999.99;
        }),
      );
      final manager = buildManager(storage);

      await expectLater(
        manager.uploadCurrentLedger(ledgerId: 1),
        throwsA(isA<CloudConflictException>()),
      );
      expect(storage.uploadCallCount, 0,
          reason: '内容确实不同 → 绝不能借「格式升级」名义静默覆盖对端数据');
    });
  });

  group('导出格式版本', () {
    test('快照 version 常量与写入一致（v11）', () async {
      final payload = await localPayload();
      expect(payload['version'], kSnapshotFormatVersion);
      expect(kSnapshotFormatVersion, 11,
          reason: '格式版本变更必须同步审查消费端的升级门控语义；'
              'v11 = 新增 holdings 段（指纹白名单同步加 holdingCanon）');
    });

    test('v11：本地有持仓时，云端 v10 快照（无持仓段）不会被误判为「仅格式升级」', () async {
      // 先在「本地没有持仓」的状态下导出 payload，去掉 holdings 键 —— 这就
      // 是一份真实的 v10 云端快照（v10 的导出端根本没有这一节）。
      final v10Payload = await localPayload();
      v10Payload.remove('holdings');
      v10Payload['version'] = 10;
      v10Payload['contentFingerprint'] = 'legacy-algorithm-fingerprint';

      // 再让本地长出一条持仓
      await db.into(db.accounts).insert(AccountsCompanion.insert(
            ledgerId: 0,
            name: '投资账户',
            type: const d.Value('investment'),
          ));
      await db.customStatement(
          "INSERT INTO holdings (account_id, name, currency, quantity, "
          "unit_cost, unit_price, auto_quote, sort_order, sync_id) "
          "VALUES (1, '贵州茅台', 'CNY', 100, 1500, 1680, 0, 0, 'h-sync-001')");

      final storage = _UpgradeStorage(
        metadata: const {'fingerprint': 'legacy-algorithm-fingerprint'},
        snapshot: jsonEncode(v10Payload),
      );
      final manager = buildManager(storage);

      expect(
        await manager.shouldRepublishSnapshotForFormatUpgrade(ledgerId: 1),
        isFalse,
        reason: '按 v11 重算云端指纹（无持仓）≠ 本地指纹（有持仓）→ 内容确实不同，'
            '必须交回既有的冲突 / 合并流程，绝不借「格式升级」名义自动覆盖对端数据',
      );
    });

    test('v9 旧快照仍可完整解析（向后兼容）', () async {
      final importData = parseJsonToImportData(await legacyV9Snapshot());
      expect(importData.transactions.length, 1);
      expect(importData.version, 9);
    });
  });
}

class _UpgradeStorage implements fcs.CloudStorageService {
  Map<String, String>? metadata;
  String? snapshot;
  Object? downloadError;
  int downloadCallCount = 0;
  int uploadCallCount = 0;
  Map<String, String>? lastUploadMetadata;

  _UpgradeStorage({required this.metadata, this.snapshot});

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async {
    if (metadata == null) return null;
    return fcs.CloudFile(
      name: path,
      path: path,
      size: snapshot?.length ?? 0,
      lastModified: DateTime(2026, 7, 1),
      metadata: metadata,
    );
  }

  @override
  Future<String?> download({required String path}) async {
    downloadCallCount++;
    if (downloadError != null) throw downloadError!;
    return snapshot;
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    uploadCallCount++;
    lastUploadMetadata = metadata;
  }

  @override
  Future<void> delete({required String path}) async {}

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async => [];

  @override
  Future<bool> exists({required String path}) async => snapshot != null;
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
