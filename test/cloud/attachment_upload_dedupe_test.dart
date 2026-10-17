// attachment_upload_dedupe 验收测试
//
// R1 同一 sha256 的并发上传收敛为单路（进程内、按 sha，与账本无关）
// R2 失败不写缓存、等待者拿到失败，下一轮仍重试；不同 sha 并发度保持
// R3 合并路径可观测（manager.attachmentUploadMergedCountForTest）
//
// 不依赖真实网络：_GatedStorage 用内存 Map 模拟对象存储，并可按需
// 卡住上传以构造两路并发的精确时序。

import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/base_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late Directory tempDir;
  late Directory attDir;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('att_dedupe_test');
    attDir = Directory('${tempDir.path}/attachments');
    await attDir.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  TransactionsSyncManager buildManager(_GatedStorage storage) {
    final provider = _FakeCloudProvider(storage: storage);
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

  Future<void> seedLedger(int ledgerId) async {
    await db.into(db.ledgers).insert(
          LedgersCompanion.insert(
            id: d.Value(ledgerId),
            name: 'L$ledgerId',
            currency: const d.Value('CNY'),
          ),
          mode: d.InsertMode.insertOrIgnore,
        );
  }

  /// 在指定账本插一笔交易 + 一条附件行，并落盘附件源文件。
  Future<void> seedAttachment({
    required int ledgerId,
    required String txSyncId,
    required String fileName,
    required List<int> bytes,
  }) async {
    await seedLedger(ledgerId);
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: ledgerId,
            type: 'expense',
            amount: 10.0,
            happenedAt: d.Value(DateTime(2026, 10, 17)),
            syncId: d.Value(txSyncId),
          ),
        );
    await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
            transactionId: txId,
            fileName: fileName,
            localSha256: d.Value(crypto.sha256.convert(bytes).toString()),
          ),
        );
    await File('${attDir.path}/$fileName').writeAsBytes(bytes);
  }

  Future<void> waitFor(
    bool Function() condition, {
    required String reason,
  }) async {
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) fail(reason);
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
  }

  group('R1 同一 sha256 并发上传收敛', () {
    test('两账本同时上传同 sha → 只 PUT 一次，等待路计 skipped', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachment(
          ledgerId: 1, txSyncId: 'tx-1', fileName: 'a.jpg', bytes: bytes);
      await seedAttachment(
          ledgerId: 2, txSyncId: 'tx-2', fileName: 'b.jpg', bytes: bytes);

      final storage = _GatedStorage();
      final started = Completer<void>();
      final gate = Completer<void>();
      storage.onUpload = (path) async {
        if (!started.isCompleted) started.complete();
        await gate.future;
      };
      final manager = buildManager(storage);

      final first = manager.uploadAttachmentObjects(ledgerId: 1);
      await started.future;
      final second = manager.uploadAttachmentObjects(ledgerId: 2);
      await waitFor(
        () => manager.attachmentUploadMergedCountForTest == 1,
        reason: '第二路必须合并到在途上传（R3 可观测计数）',
      );
      gate.complete();

      final r1 = await first;
      final r2 = await second;

      expect(storage.uploadCallCount, 1,
          reason: '同一 sha256 在任一时刻只能有一路 PUT（R1）');
      expect(r1.failed + r2.failed, 0, reason: '合并不等于失败');
      expect(r1.uploaded + r2.uploaded, 1, reason: '对象只由首路完成');
      expect(r1.skipped + r2.skipped, 1, reason: '等待路按跳过记账');
      expect(storage.files['attachments/$sha.bin'], isNotNull);
    });
  });

  group('R2 失败传播与重试语义', () {
    test('首路失败 → 等待路一并失败且不重复 PUT；下一轮仍重试', () async {
      final bytes = Uint8List.fromList([5, 6, 7]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachment(
          ledgerId: 1, txSyncId: 'tx-1', fileName: 'a.jpg', bytes: bytes);
      await seedAttachment(
          ledgerId: 2, txSyncId: 'tx-2', fileName: 'b.jpg', bytes: bytes);

      final storage = _GatedStorage()..failNextUploads = 1;
      final started = Completer<void>();
      final gate = Completer<void>();
      storage.onUpload = (path) async {
        if (!started.isCompleted) started.complete();
        await gate.future;
      };
      final manager = buildManager(storage);

      final first = manager.uploadAttachmentObjects(ledgerId: 1);
      await started.future;
      final second = manager.uploadAttachmentObjects(ledgerId: 2);
      await waitFor(
        () => manager.attachmentUploadMergedCountForTest == 1,
        reason: '第二路必须合并到在途上传后再放行失败',
      );
      gate.complete();

      final r1 = await first;
      final r2 = await second;

      expect(storage.uploadCallCount, 1,
          reason: '失败也不得让等待路重复 PUT');
      expect(r1.failed, 1);
      expect(r2.failed, 1, reason: '失败必须传播给等待者，不能静默吞掉');
      expect(r1.uploaded + r2.uploaded, 0);
      expect(r1.skipped + r2.skipped, 0,
          reason: '失败不能被记成「跳过」');

      // 下一轮：失败不写缓存，必须重新尝试并成功
      storage.onUpload = null;
      final retry = await manager.uploadAttachmentObjects(ledgerId: 1);
      expect(retry.uploaded, 1, reason: '下一轮同步仍会重试（R2）');
      expect(storage.uploadCallCount, 2);
      expect(storage.files['attachments/$sha.bin'], isNotNull);
    });
  });

  group('R2 不同 sha 的并发度保持', () {
    test('多个不同 sha 仍并发上传（semaphore 4 生效）', () async {
      final bytesA = Uint8List.fromList([11, 12]);
      final bytesB = Uint8List.fromList([21, 22]);
      await seedAttachment(
          ledgerId: 1, txSyncId: 'tx-a', fileName: 'a.jpg', bytes: bytesA);
      await seedAttachment(
          ledgerId: 1, txSyncId: 'tx-b', fileName: 'b.jpg', bytes: bytesB);

      final storage = _GatedStorage();
      final gate = Completer<void>();
      var active = 0;
      var maxActive = 0;
      var started = 0;
      storage.onUpload = (path) async {
        active++;
        maxActive = max(maxActive, active);
        started++;
        if (started >= 2 && !gate.isCompleted) gate.complete();
        await gate.future.timeout(const Duration(seconds: 2), onTimeout: () {});
        active--;
      };
      final manager = buildManager(storage);

      final result = await manager.uploadAttachmentObjects(ledgerId: 1);

      expect(result.uploaded, 2);
      expect(storage.uploadCallCount, 2);
      expect(maxActive, greaterThan(1),
          reason: '去重只收敛同一 sha，不同 sha 的并发度不得被串行化（R2）');
    });
  });
}

/// 可卡住上传的内存对象存储，用于构造两路并发的精确时序。
class _GatedStorage implements fcs.CloudStorageService {
  final Map<String, String> files = {};
  int uploadCallCount = 0;
  int listCallCount = 0;

  /// 接下来 N 次上传直接失败（模拟服务端竞态/网络错误）。
  int failNextUploads = 0;

  /// 每次 upload 前异步触发；可在此阻塞以制造并发窗口。
  Future<void> Function(String path)? onUpload;

  @override
  Future<String?> download({required String path}) async => files[path];

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    uploadCallCount++;
    final hook = onUpload;
    if (hook != null) await hook(path);
    if (failNextUploads > 0) {
      failNextUploads--;
      throw fcs.CloudStorageException('upload failed (simulated)');
    }
    files[path] = data;
  }

  @override
  Future<void> delete({required String path}) async {
    files.remove(path);
  }

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    listCallCount++;
    final prefix = path.isEmpty ? '' : '$path/';
    return files.keys
        .where((k) => k.startsWith(prefix))
        .map((k) => fcs.CloudFile(
              name: k.substring(prefix.length),
              path: k,
            ))
        .toList();
  }

  @override
  Future<bool> exists({required String path}) async => files.containsKey(path);

  @override
  Future<fcs.CloudFile?> getMetadata({required String path}) async => null;
}

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

class _DummyRepo implements BaseRepository {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakePathProvider extends PathProviderPlatform {
  final String documentsPath;
  _FakePathProvider(this.documentsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
