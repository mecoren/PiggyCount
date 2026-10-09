// P1-5（2026-09-09）：下载内容完整性终审的回归测试。
//
// 硬校验链路（_verifyDownloadedSnapshotIntegrity）：
// - 内容非 JSON → 硬失败（CloudStorageException）；
// - 内嵌指纹与内容重算指纹一致（且**快照 version == 当前格式**）→ 放行；
// - 不一致 → 重下一次 → 自愈采用新内容；仍不一致 → 硬失败（破坏性
//   恢复吃进坏数据比阻断更危险）；
// - 无内嵌指纹（v6 前旧快照）→ 退回 metadata 软告警路径，不阻断；
// - 快照 version ≠ 当前格式（旧端/更新端写入）→ 内嵌指纹是**另一版算法**
//   算出来的、不可比对 → 转软告警不阻断（2026-10-10 修复的死循环：旧格式
//   + 两端内容确实不同时，「下载到本地」「对比合并」两入口都报内嵌指纹
//   不匹配，而重下救不了算法漂移 → 该类账本永久不可同步）。
//
// 测试走 downloadAndRestoreToCurrentLedger / downloadAndPreview 公共入口
// （真实内存库 + fake provider），不 mock 校验函数本身 —— 验证的是接线与
// 端到端语义。
import 'dart:convert';

import 'package:piggycount/cloud/sync_fingerprint.dart';
import 'package:piggycount/cloud/transactions_json.dart'
    show kSnapshotFormatVersion;
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 本文件自包含的最小 fake（与 transactions_sync_manager_test 同构，
/// 私有类不跨文件导出）。
class _FakeCloudProvider implements fcs.CloudProvider {
  @override
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

/// 可编程下载序列的 fake storage：按调用次序返回预先编排的结果。
class _ScriptedStorage implements fcs.CloudStorageService {
  /// 每次调用返回的 JSON（null 元素表示该次返回「文件不存在」）。
  final List<String?> script;
  int downloadCallCount = 0;
  Map<String, String>? lastMetadata;

  _ScriptedStorage(this.script);

  @override
  Future<String?> download({required String path}) async {
    final i = downloadCallCount < script.length ? downloadCallCount : script.length - 1;
    downloadCallCount++;
    return script[i];
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
    // metadata 软告警路径会读取它；返回空 metadata 让旧快照路径静默通过
    return fcs.CloudFile(
      name: path,
      path: path,
      size: 100,
      lastModified: DateTime.now(),
      metadata: const {},
    );
  }
}

/// 构造带自洽内嵌指纹的快照（同 exportTransactionsJson 的写入形态）。
///
/// [version] 默认**当前格式** —— 只有上传侧与本机同版算法时「内嵌 vs 重算」
/// 才可比；传旧版本（或 null 表示缺键）即进入「不可比对」分支，内嵌值可以
/// 故意写成旧算法口径（见下方案例）。
String _snapshotWithTx({
  required int ledgerId,
  required String note,
  int? version = kSnapshotFormatVersion,
}) {
  final payload = <String, dynamic>{
    if (version != null) 'version': version,
    'exportedAt': '2026-09-09T00:00:00Z',
    'ledgerId': ledgerId,
    'ledgerName': 'test',
    'currency': 'CNY',
    'count': 1,
    'accounts': const [],
    'categories': const [],
    'tags': const [],
    'items': [
      {
        'type': 'expense',
        'amount': 12.5,
        'categoryName': null,
        'categoryKind': null,
        'happenedAt': '2026-07-01T00:00:00.000',
        'note': note,
        'tags': '',
        'syncId': 'tx-1',
      }
    ],
  };
  payload['contentFingerprint'] = contentFingerprintFromMap(payload);
  return jsonEncode(payload);
}

/// 旧格式快照：内嵌指纹按**旧版算法**写出（与当前算法重算值必然不等）。
String _legacySnapshot({required int ledgerId, required String note}) {
  final map = jsonDecode(
    _snapshotWithTx(ledgerId: ledgerId, note: note, version: 9),
  ) as Map<String, dynamic>;
  map['contentFingerprint'] = 'legacy-algorithm-fingerprint';
  return jsonEncode(map);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  /// 装配被测 TSM（注入 fake provider，跳过真实云初始化）。
  TransactionsSyncManager buildTsm(fcs.CloudStorageService storage) {
    final provider = _FakeCloudProvider(storage: storage);
    final syncManager = fcs.CloudSyncManager<int>(
      provider: provider,
      serializer: _NoopSerializer(),
    );
    final tsm = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.supabase,
        name: 'test',
      ),
      db: db,
      repo: repo,
    );
    tsm.setSyncManagerForTesting(
      syncManager: syncManager,
      provider: provider,
    );
    return tsm;
  }

  Future<void> seedLedger(int id) async {
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: d.Value(id),
          name: 'test',
          currency: const d.Value('CNY'),
        ));
  }

  group('P1-5: downloadAndRestoreToCurrentLedger 完整性终审', () {
    test('内嵌指纹自洽 → 放行并正常恢复', () async {
      await seedLedger(1);
      final tsm = buildTsm(_ScriptedStorage([_snapshotWithTx(ledgerId: 1, note: 'ok')]));

      final result = await tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1);
      expect(result.inserted, 1);
    });

    test('内容非 JSON → 硬失败（不再走软告警静默恢复）', () async {
      await seedLedger(1);
      final tsm = buildTsm(_ScriptedStorage(['not-json-at-all{']));

      await expectLater(
        tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1),
        throwsA(isA<fcs.CloudStorageException>()),
      );
    });

    test('内嵌指纹与内容不符 → 重下自愈（第二次内容自洽则采用新内容）',
        () async {
      await seedLedger(1);
      // 第一次：篡改内容但保留原快照的指纹（模拟网关截断/陈旧副本）
      final good = _snapshotWithTx(ledgerId: 1, note: 'good');
      final goodMap = jsonDecode(good) as Map<String, dynamic>;
      final goodFp = goodMap['contentFingerprint'] as String;
      final badMap = jsonDecode(good) as Map<String, dynamic>;
      badMap['items'][0]['note'] = 'tampered'; // 内容变了
      badMap['contentFingerprint'] = goodFp; // 指纹没跟上 → 不匹配
      final bad = jsonEncode(badMap);

      final storage = _ScriptedStorage([bad, good]);
      final tsm = buildTsm(storage);

      final result = await tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1);
      // 重下自愈后采用第二次的自洽内容
      expect(storage.downloadCallCount, 2);
      expect(result.inserted, 1);
    });

    test('重下后仍不一致 → 硬失败，拒绝恢复', () async {
      await seedLedger(1);
      final bad1 = _snapshotWithTx(ledgerId: 1, note: 'a');
      final bad1Map = jsonDecode(bad1) as Map<String, dynamic>;
      bad1Map['contentFingerprint'] = 'deadbeef'; // 与内容永不匹配
      final bad2 = _snapshotWithTx(ledgerId: 1, note: 'b');
      final bad2Map = jsonDecode(bad2) as Map<String, dynamic>;
      bad2Map['contentFingerprint'] = 'deadbeef';

      final storage = _ScriptedStorage([jsonEncode(bad1Map), jsonEncode(bad2Map)]);
      final tsm = buildTsm(storage);

      await expectLater(
        tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1),
        throwsA(isA<fcs.CloudStorageException>()),
      );
      expect(storage.downloadCallCount, 2, reason: '首次 + 单次重下');
    });

    test('旧快照（无内嵌指纹）→ 不阻断，走 metadata 软告警兼容路径', () async {
      await seedLedger(1);
      final snap = _snapshotWithTx(ledgerId: 1, note: 'legacy');
      final map = jsonDecode(snap) as Map<String, dynamic>;
      map.remove('contentFingerprint'); // v6 时代老快照无此键

      final tsm = buildTsm(_ScriptedStorage([jsonEncode(map)]));

      final result = await tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1);
      expect(result.inserted, 1, reason: '无内嵌指纹的老快照必须保持可恢复'
          '（M2 指纹算法升级的迁移窗口兼容）');
    });

    test('旧格式快照（version < 当前格式）→ 内嵌指纹不可比对，放行恢复', () async {
      await seedLedger(1);
      // 真机复刻：云端是旧版 App 写的 v9 快照，内嵌指纹由当时那版算法算出。
      // v10/v11/v12 都改过指纹算法值 —— 拿当前算法重算必然不等，而这与
      // 「内容损坏」无关。
      final storage = _ScriptedStorage([
        _legacySnapshot(ledgerId: 1, note: 'v9-cloud'),
      ]);
      final tsm = buildTsm(storage);

      final result = await tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      expect(result.inserted, 1,
          reason: '硬失败会让这类账本的「下载到本地」永久不可用');
      expect(storage.downloadCallCount, 1,
          reason: '不可比对时不该白白重下一次 —— 算法漂移重下多少次都一样');
    });

    test('快照缺 version 键但含内嵌指纹 → 同样按不可比对处理，放行', () async {
      await seedLedger(1);
      final snap = _snapshotWithTx(ledgerId: 1, note: 'no-version', version: null);
      final map = jsonDecode(snap) as Map<String, dynamic>;
      map['contentFingerprint'] = 'unknown-algorithm-fingerprint';

      final storage = _ScriptedStorage([jsonEncode(map)]);
      final tsm = buildTsm(storage);

      final result = await tsm.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      expect(result.inserted, 1);
      expect(storage.downloadCallCount, 1);
    });
  });

  group('P1-5: downloadAndPreview 完整性终审', () {
    test('预览链路同样拒绝篡改快照', () async {
      await seedLedger(1);
      final bad = _snapshotWithTx(ledgerId: 1, note: 'x');
      final badMap = jsonDecode(bad) as Map<String, dynamic>;
      badMap['contentFingerprint'] = 'wrong-fp';
      final good = _snapshotWithTx(ledgerId: 1, note: 'y');

      final storage = _ScriptedStorage([jsonEncode(badMap), good]);
      final tsm = buildTsm(storage);

      final result = await tsm.downloadAndPreview(ledgerId: 1);
      expect(result, isNotNull, reason: '重下自愈后预览正常可用');
      expect(storage.downloadCallCount, 2);
    });

    test('旧格式快照（不可比对）→ 预览链路也放行（修「对比合并」永久报不一致）',
        () async {
      await seedLedger(1);
      final storage = _ScriptedStorage([
        _legacySnapshot(ledgerId: 1, note: 'v9-preview'),
      ]);
      final tsm = buildTsm(storage);

      final result = await tsm.downloadAndPreview(ledgerId: 1);

      expect(result, isNotNull,
          reason: '冲突框里「对比合并」走的就是预览链路，阻断等于把用户的出路全堵死');
      expect(storage.downloadCallCount, 1);
    });
  });
}
