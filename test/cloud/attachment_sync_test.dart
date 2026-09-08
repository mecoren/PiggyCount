// attachment_binary_sync 单元测试
//
// 覆盖快照链路(Path A)附件二进制同步的核心闭环:
// 1. 上传侧 uploadAttachmentObjects:内容寻址上传、exists 去重、孤儿跳过
// 2. 恢复侧 enqueueMissingAttachmentJobs + drainAttachmentJobs:
//    缺文件入队、下载校验落盘、已有文件不入队、损坏对象拒绝落盘
// 3. 清单→落列:快照 JSON 里的 sha256 经恢复写入 localSha256 列
//
// 不依赖真实网络:fake CloudProvider + 内存 Map storage + 临时目录
// 模拟 getApplicationDocumentsDirectory。

import 'dart:convert';
import 'dart:io';
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
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late Directory tempDir;
  late Directory attDir;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('att_sync_test');
    attDir = Directory('${tempDir.path}/attachments');
    await attDir.create(recursive: true);
    PathProviderPlatform.instance = _FakePathProvider(tempDir.path);
  });

  tearDown(() async {
    await db.close();
    await tempDir.delete(recursive: true);
  });

  /// 构造已注入 fake provider 的 manager。
  /// [repo] 缺省用 _DummyRepo;需要走真实导入路径时传 LocalRepository。
  TransactionsSyncManager buildManager(
    _MapStorage storage, {
    BaseRepository? repo,
  }) {
    final provider = _FakeCloudProvider(storage: storage);
    final manager = TransactionsSyncManager(
      config: const fcs.CloudServiceConfig(
        type: fcs.CloudBackendType.supabase,
        name: 'test',
      ),
      db: db,
      repo: repo ?? _DummyRepo(),
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

  /// 预置账本 + 一笔交易 + 一条附件行
  Future<int> seedAttachmentRow({
    required String fileName,
    required String sha256,
  }) async {
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: 'L',
          currency: const d.Value('CNY'),
        ));
    final txId = await db.into(db.transactions).insert(
          TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 10.0,
            happenedAt: d.Value(DateTime(2026, 8, 1)),
            syncId: const d.Value('tx-1'),
          ),
        );
    await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
            transactionId: txId,
            fileName: fileName,
            localSha256: d.Value(sha256),
          ),
        );
    return txId;
  }

  group('pathForAttachmentBin', () {
    test('内容寻址路径格式为 attachments/<sha256>.bin', () {
      final manager = buildManager(_MapStorage());
      expect(manager.pathForAttachmentBin('abc123'),
          'attachments/abc123.bin');
    });
  });

  group('uploadAttachmentObjects 上传侧', () {
    test('本地文件按内容寻址上传为 base64 对象', () async {
      final bytes = Uint8List.fromList([1, 2, 3, 4, 5]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'pic.jpg', sha256: sha);
      await File('${attDir.path}/pic.jpg').writeAsBytes(bytes);

      final storage = _MapStorage();
      final manager = buildManager(storage);

      final result = await manager.uploadAttachmentObjects(ledgerId: 1);

      expect(result.uploaded, 1, reason: '应上传 1 个对象');
      expect(result.failed, 0);
      // 云端对象内容必须是原始字节的 base64(与 drain 的解码口径互逆)
      expect(storage.files['attachments/$sha.bin'], base64Encode(bytes));
    });

    test('云端已存在的对象跳过(exists 去重)', () async {
      final bytes = Uint8List.fromList([9, 9, 9]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'dup.png', sha256: sha);
      await File('${attDir.path}/dup.png').writeAsBytes(bytes);

      final storage = _MapStorage()
        ..files['attachments/$sha.bin'] = base64Encode(bytes);
      final manager = buildManager(storage);

      final result = await manager.uploadAttachmentObjects(ledgerId: 1);

      expect(result.uploaded, 0, reason: '对象已在云端,不应重复上传');
      expect(result.skipped, 1);
    });

    test('同 sha 多行只上传一份(内容寻址去重)', () async {
      final bytes = Uint8List.fromList([7, 7, 7]);
      final sha = crypto.sha256.convert(bytes).toString();
      final txId = await seedAttachmentRow(
          fileName: 'a.jpg', sha256: sha);
      await File('${attDir.path}/a.jpg').writeAsBytes(bytes);
      // 第二笔交易挂同内容附件(不同文件名,内容相同)
      final tx2 = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 20.0,
              happenedAt: d.Value(DateTime(2026, 8, 2)),
              syncId: const d.Value('tx-2'),
            ),
          );
      expect(tx2, isNot(txId));
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: tx2,
              fileName: 'b.jpg',
              localSha256: d.Value(sha),
            ),
          );
      await File('${attDir.path}/b.jpg').writeAsBytes(bytes);

      final storage = _MapStorage();
      final manager = buildManager(storage);

      final result = await manager.uploadAttachmentObjects(ledgerId: 1);

      expect(result.uploaded, 1, reason: '两行同 sha 应合并为一个对象');
      expect(storage.files.length, 1);
    });

    test('本地文件缺失的孤儿行跳过且不抛错', () async {
      await seedAttachmentRow(fileName: 'ghost.jpg', sha256: 'deadbeef');

      final storage = _MapStorage();
      final manager = buildManager(storage);

      final result = await manager.uploadAttachmentObjects(ledgerId: 1);

      expect(result.uploaded, 0);
      expect(result.skipped, 1, reason: '孤儿附件行应计为跳过');
      expect(storage.files, isEmpty);
    });
  });

  group('enqueue + drain 恢复侧', () {
    test('缺文件入队,drain 下载校验后落盘', () async {
      final bytes = Uint8List.fromList([11, 22, 33]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'restored.jpg', sha256: sha);
      // 注意:本地不写文件,模拟"元数据已导入、文件缺失"

      final storage = _MapStorage()
        ..files['attachments/$sha.bin'] = base64Encode(bytes);
      final manager = buildManager(storage);

      await manager.enqueueMissingAttachmentJobs(1);
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 1, reason: '应成功补齐 1 个文件');
      final saved = File('${attDir.path}/restored.jpg');
      expect(await saved.exists(), isTrue, reason: '文件应已落盘');
      expect(await saved.readAsBytes(), bytes, reason: '落盘内容应与云端一致');
    });

    test('本地文件已存在则不入队', () async {
      final bytes = Uint8List.fromList([44, 55]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'exists.jpg', sha256: sha);
      await File('${attDir.path}/exists.jpg').writeAsBytes(bytes);

      final storage = _MapStorage();
      final manager = buildManager(storage);

      await manager.enqueueMissingAttachmentJobs(1);
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 0, reason: '文件已存在,无需补齐');
      expect(storage.downloads, isEmpty, reason: '不应发生下载');
    });

    test('云端对象损坏(sha 不匹配)拒绝落盘', () async {
      final goodBytes = Uint8List.fromList([1, 1, 1]);
      final goodSha = crypto.sha256.convert(goodBytes).toString();
      await seedAttachmentRow(fileName: 'bad.jpg', sha256: goodSha);

      // 云端对象内容与路径声明的哈希不符(损坏/错配)
      final corrupt = Uint8List.fromList([9, 9, 9, 9]);
      final storage = _MapStorage()
        ..files['attachments/$goodSha.bin'] = base64Encode(corrupt);
      final manager = buildManager(storage);

      await manager.enqueueMissingAttachmentJobs(1);
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 0, reason: '校验失败不应计为成功');
      expect(await File('${attDir.path}/bad.jpg').exists(), isFalse,
          reason: '损坏对象不得落盘');
    });
  });

  group('快照清单 → localSha256 落列', () {
    test('恢复含 attachments[].sha256 的快照后列值正确', () async {
      final repo = LocalRepository(db);
      final bytes = Uint8List.fromList([5, 6, 7, 8]);
      final sha = crypto.sha256.convert(bytes).toString();

      // 与 _ledgerJsonWithOneTx 同构的 v8 快照,attachments 带 sha256
      final cloudJson = '{"version":8,"exportedAt":"2026-08-15T10:00:00Z",'
          '"ledgerId":1,"ledgerName":"L","currency":"CNY","count":1,'
          '"accounts":[],"categories":[],"tags":[],'
          '"items":[{"type":"expense","amount":10.0,'
          '"categoryName":null,"categoryKind":null,'
          '"happenedAt":"2026-08-01T00:00:00.000","note":"n","tags":"",'
          '"syncId":"tx-1",'
          '"attachments":[{"fileName":"m.jpg","originalName":"m.jpg",'
          '"fileSize":4,"sortOrder":0,"sha256":"$sha"}]}]}';

      final storage = _MapStorage()
        ..files['ledger_1.json'] = cloudJson
        ..files['attachments/$sha.bin'] = base64Encode(bytes);
      final manager = buildManager(storage, repo: repo);

      final result =
          await manager.downloadAndRestoreToCurrentLedger(ledgerId: 1);

      expect(result.inserted, 1);
      final rows = await db.select(db.transactionAttachments).get();
      expect(rows, hasLength(1));
      expect(rows.first.localSha256, sha,
          reason: '清单 sha256 应随导入落 localSha256 列');
      expect(rows.first.fileName, 'm.jpg');
    });
  });

  group('enqueueAllMissingAttachmentJobs（审计 A2 回归：启动补扫）', () {
    test('DB 行存在但本地文件缺失 → 全量重扫入队（不依赖恢复/导入时机）', () async {
      // 模拟"上次会话恢复后进程被杀"：附件行在、文件不在、内存队列为空
      final bytes = Uint8List.fromList([1, 2, 3]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'lost.jpg', sha256: sha);

      final manager = buildManager(_MapStorage());
      final added = await manager.enqueueAllMissingAttachmentJobs();
      expect(added, 1, reason: '重启后必须有机制重新发现缺文件');

      // 云端有对象 → drain 补齐落盘
      final storage = _MapStorage()
        ..files['attachments/$sha.bin'] = base64Encode(bytes);
      final manager2 = buildManager(storage);
      expect(await manager2.enqueueAllMissingAttachmentJobs(), 1);
      expect(await manager2.drainAttachmentJobs(), 1);
      expect(
        await File('${attDir.path}/lost.jpg').readAsBytes(),
        bytes,
      );
    });

    test('本地文件已存在的行不入队', () async {
      final bytes = Uint8List.fromList([4, 5, 6]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'have.jpg', sha256: sha);
      await File('${attDir.path}/have.jpg').writeAsBytes(bytes);

      final manager = buildManager(_MapStorage());
      expect(await manager.enqueueAllMissingAttachmentJobs(), 0);
    });

    test('云端确认无此对象时 drain 丢弃、下次补扫不再空转（TSM-P2 协同）',
        () async {
      final bytes = Uint8List.fromList([7, 8, 9]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedAttachmentRow(fileName: 'never.bin', sha256: sha);

      final storage = _MapStorage(); // 云端空
      var manager = buildManager(storage);
      expect(await manager.enqueueAllMissingAttachmentJobs(), 1);
      expect(await manager.drainAttachmentJobs(), 0,
          reason: 'objectMissing 不计入成功');

      // 模拟重启后再次补扫 + drain：仍能重新入队并快速收敛，不会死循环
      manager = buildManager(storage);
      expect(await manager.enqueueAllMissingAttachmentJobs(), 1);
      expect(await manager.drainAttachmentJobs(), 0);
    });
  });

  group('drain 队尾续消费（WebDAV 报告 §6.1 回归）', () {
    /// seedAttachmentRow 固定 ledgerId=1;本组需要多账本,故提供带 id 参数版本
    Future<int> seedRowInLedger(
      int ledgerId,
      String txSyncId,
      String fileName,
      String sha256,
    ) async {
      await db.into(db.ledgers).insert(LedgersCompanion.insert(
            id: d.Value(ledgerId),
            name: 'L$ledgerId',
            currency: const d.Value('CNY'),
          ));
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 10.0,
              happenedAt: d.Value(DateTime(2026, 8, 1)),
              syncId: d.Value(txSyncId),
            ),
          );
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: fileName,
              localSha256: d.Value(sha256),
            ),
          );
      return txId;
    }

    test('drain 进行中新账本入队 → 队尾续消费,不滞留内存队列', () async {
      // 复刻生产时序:账本1 enqueue 完成后 drain 启动;drain 尚在执行时
      // 账本2 导入完成并发 enqueue,其 drain 调用被守卫吞掉。
      // 修复前:账本2 的任务滞留到进程重启;修复后:第一轮 drain 队尾续消费。
      final bytes1 = Uint8List.fromList([11, 22, 33]);
      final sha1 = crypto.sha256.convert(bytes1).toString();
      await seedRowInLedger(1, 'tx-1', 'ledger1.jpg', sha1);
      final bytes2 = Uint8List.fromList([44, 55]);
      final sha2 = crypto.sha256.convert(bytes2).toString();
      await seedRowInLedger(2, 'tx-2', 'ledger2.jpg', sha2);

      final storage = _MapStorage()
        ..files['attachments/$sha1.bin'] = base64Encode(bytes1)
        ..files['attachments/$sha2.bin'] = base64Encode(bytes2);
      final manager = buildManager(storage);

      await manager.enqueueMissingAttachmentJobs(1);
      // 在 storage 上装一个「第一次 download 时放行账本2 enqueue」的钩子,
      // 确保新任务落在 drain 的快照之后(生产缺陷的精确时序)
      storage.onDownload = () async {
        storage.onDownload = null; // 只触发一次
        await manager.enqueueMissingAttachmentJobs(2);
      };
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 2, reason: '两轮合计补齐 2 个文件');
      expect(await File('${attDir.path}/ledger1.jpg').exists(), isTrue);
      expect(
        await File('${attDir.path}/ledger2.jpg').readAsBytes(),
        bytes2,
        reason: '续消费后账本2的附件必须落盘,无需等进程重启',
      );
    });

    test('本轮失败回队的任务不触发即时重试（退避语义保留）', () async {
      // 若队尾续消费不加「排除失败回队」约束,瞬态故障会退化为无限即时
      // 重试循环。本测试固定该约束:失败任务回队后,drain 必须就此停止,
      // 等下次外部触发(启动补扫/下次同步)再重试。
      final bytes = Uint8List.fromList([13, 37]);
      final sha = crypto.sha256.convert(bytes).toString();
      await seedRowInLedger(1, 'tx-1', 'flaky.jpg', sha);

      // 云端存在但内容损坏 → 3 次重试全部校验失败 → transientFailure 回队
      final corrupt = Uint8List.fromList([9, 9, 9, 9]);
      final storage = _MapStorage()
        ..files['attachments/$sha.bin'] = base64Encode(corrupt);
      final manager = buildManager(storage);

      await manager.enqueueMissingAttachmentJobs(1);
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 0, reason: '校验失败不应计为成功');
      // 3 次重试 = 3 次下载;若退避语义被破坏,这里会远大于 3
      expect(storage.downloads.length, 3,
          reason: '失败任务回队后必须停止,不得立即再 drain');
      expect(await File('${attDir.path}/flaky.jpg').exists(), isFalse);
    });

    test('同轮既有失败回队又有新任务入队 → 只续消费新任务', () async {
      // 队尾检测的最精细场景:失败任务与新任务同时在队,续消费必须
      // 只拉新任务。断言:新任务在第二轮落盘;失败任务未被再次尝试。
      final flakyBytes = Uint8List.fromList([1, 3]);
      final flakySha = crypto.sha256.convert(flakyBytes).toString();
      await seedRowInLedger(1, 'tx-1', 'flaky.jpg', flakySha);
      final goodBytes = Uint8List.fromList([4, 2]);
      final goodSha = crypto.sha256.convert(goodBytes).toString();
      await seedRowInLedger(2, 'tx-2', 'good.jpg', goodSha);

      // flaky 在云端是损坏对象;good 正常
      final corrupt = Uint8List.fromList([9, 9, 9, 9]);
      final storage = _MapStorage()
        ..files['attachments/$flakySha.bin'] = base64Encode(corrupt)
        ..files['attachments/$goodSha.bin'] = base64Encode(goodBytes);
      final manager = buildManager(storage);

      // 账本1 先入队并启动 drain;flaky 首次下载时触发账本2 的 enqueue
      await manager.enqueueMissingAttachmentJobs(1);
      storage.onDownload = () async {
        storage.onDownload = null;
        await manager.enqueueMissingAttachmentJobs(2);
      };
      final ok = await manager.drainAttachmentJobs();

      expect(ok, 1, reason: '仅 good.jpg 在续消费轮中落盘');
      expect(await File('${attDir.path}/good.jpg').exists(), isTrue);
      // flaky 第一轮 3 次重试后回队;第二轮续消费被「排除失败回队」
      // 约束挡住,未被再次尝试。总下载 = flaky 3 次 + good 1 次。
      expect(storage.downloads.length, 4);
      expect(await File('${attDir.path}/flaky.jpg').exists(), isFalse);
    });
  });
}

/// 内存 Map 版 storage:真实记录 upload/exists/download 行为。
/// list 按路径前缀返回 files 中的对象名（对齐真实后端语义：
/// list 成功即权威，供 uploadAttachmentObjects 的批量存在性判定使用）。
class _MapStorage implements fcs.CloudStorageService {
  final Map<String, String> files = {};
  final List<String> downloads = [];

  /// 测试钩子:每次 download 前异步触发(用于把 enqueue 精确卡进
  /// drain 执行期,复刻连续导入的并发时序)。置 null 可自撤销。
  Future<void> Function()? onDownload;

  @override
  Future<String?> download({required String path}) async {
    final hook = onDownload;
    if (hook != null) await hook();
    downloads.add(path);
    return files[path];
  }

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    files[path] = data;
  }

  @override
  Future<void> delete({required String path}) async {
    files.remove(path);
  }

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    // 附件目录列举：返回该目录下的对象名（path 形如 'attachments'）
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

/// 把应用文档目录指到临时目录,隔离附件落盘位置
class _FakePathProvider extends PathProviderPlatform {
  final String documentsPath;
  _FakePathProvider(this.documentsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;
}
