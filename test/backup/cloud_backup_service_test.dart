/// Task 2/3（/prd/cloud_backup/execution_plan.md）：
/// CloudBackupService 行为契约：
/// - createBackup：上传当日命名 ZIP，内含全部账本 JSON 与内容寻址附件；
///   同日再备覆盖同一文件（当日只留一份）；无账本抛 StateError；并发互斥
/// - listBackups：仅匹配 PiggyCount-yyyy-MM-dd.zip，按日期倒序
/// - restoreBackup：全新环境恢复 / 同 ID 覆盖 / ZIP 损坏报错不动本地 /
///   附件 sha256 不匹配跳过
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/backup/backup_scheduler.dart';
import 'package:piggycount/cloud/backup/cloud_backup_service.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

/// 内存假存储：记录 upload 的 path→data，list 按前缀过滤
class _FakeStorage extends fcs.NoopStorageService {
  final Map<String, String> files = {};

  @override
  Future<void> upload({
    required String path,
    required String data,
    Map<String, String>? metadata,
  }) async {
    files[path] = data;
  }

  @override
  Future<String?> download({required String path}) async => files[path];

  @override
  Future<bool> exists({required String path}) async => files.containsKey(path);

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    return [
      for (final e in files.entries)
        if (e.key.startsWith(prefix))
          fcs.CloudFile(
              name: e.key.substring(prefix.length),
              path: e.key,
              size: e.value.length)
    ];
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late _FakeStorage storage;
  late Directory tempRoot;
  late Directory docsDir;
  late CloudBackupService service;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    storage = _FakeStorage();
    tempRoot = await Directory.systemTemp.createTemp('pc_backup_test');
    docsDir = Directory('${tempRoot.path}/docs');
    await docsDir.create(recursive: true);
    service = CloudBackupService(
      db: db,
      repo: repo,
      storageResolver: () async => storage,
      documentsDir: () async => docsDir,
    );
  });

  tearDown(() async {
    await db.close();
    await tempRoot.delete(recursive: true);
  });

  Future<int> addLedger(String name) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: name));

  Future<int> addTx(int ledgerId, {double amount = 10}) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId, type: 'expense', amount: amount));

  Future<void> addAttachmentFile(String fileName, List<int> bytes) async {
    final d = Directory('${docsDir.path}/attachments');
    await d.create(recursive: true);
    await File('${d.path}/$fileName').writeAsBytes(bytes);
  }

  test('createBackup 上传当日命名 ZIP，内含账本 JSON 与内容寻址附件', () async {
    final id = await addLedger('Main');
    await addTx(id);
    final sha = crypto.sha256.convert([1, 2, 3]).toString();
    await addAttachmentFile('photo.jpg', [1, 2, 3]);
    final txs = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    await db.into(db.transactionAttachments).insert(
        TransactionAttachmentsCompanion.insert(
            transactionId: txs.first.id,
            fileName: 'photo.jpg',
            fileSize: const drift.Value(3),
            localSha256: drift.Value(sha)));

    final out = await service.createBackup();

    expect(out.ledgers, 1);
    expect(out.attachments, 1);
    final key =
        'piggycount-bak/PiggyCount-${BackupScheduler.formatDate(DateTime.now())}.zip';
    expect(storage.files.containsKey(key), isTrue,
        reason: '云端应有当日命名的备份文件');
    final archive = ZipDecoder().decodeBytes(base64Decode(storage.files[key]!));
    final names = archive.map((f) => f.name).toSet();
    expect(names, containsAll(['ledger_$id.json', 'attachments/$sha.bin']));
    final ledgerJson =
        utf8.decode(archive.findFile('ledger_$id.json')!.content as List<int>);
    expect((jsonDecode(ledgerJson) as Map)['ledgerName'], 'Main');
  });

  test('同日再次备份覆盖同一文件（只留一份，内容为最新）', () async {
    final id = await addLedger('Main');
    await addTx(id);
    await service.createBackup();
    await addTx(id, amount: 20);
    await service.createBackup();

    final bakKeys = storage.files.keys
        .where((k) => k.startsWith('piggycount-bak/'))
        .toList();
    expect(bakKeys.length, 1);
    final archive =
        ZipDecoder().decodeBytes(base64Decode(storage.files[bakKeys.first]!));
    final ledgerJson = utf8
        .decode(archive.findFile('ledger_$id.json')!.content as List<int>);
    expect((jsonDecode(ledgerJson) as Map)['count'], 2);
  });

  test('listBackups 仅匹配命名格式并按日期倒序', () async {
    storage.files['piggycount-bak/PiggyCount-2026-08-01.zip'] = 'eA==';
    storage.files['piggycount-bak/PiggyCount-2026-08-15.zip'] = 'eA==';
    storage.files['piggycount-bak/readme.txt'] = 'x';
    storage.files['ledger_1.json'] = '{}';

    final list = await service.listBackups();

    expect(list.length, 2);
    expect(list.first.fileName, 'PiggyCount-2026-08-15.zip');
    expect(list.last.fileName, 'PiggyCount-2026-08-01.zip');
  });

  test('无本地账本时备份抛出 StateError', () async {
    expect(() => service.createBackup(), throwsA(isA<StateError>()));
  });

  test('并发互斥：进行中再次触发抛 StateError', () async {
    final id = await addLedger('Main');
    await addTx(id);
    final second = service.createBackup();
    await expectLater(service.createBackup(), throwsA(isA<StateError>()));
    await second;
  });

  group('restoreBackup', () {
    test('P1-2 恢复检查点：恢复前置位、完成后清除（跨进程崩溃防护）', () async {
      final id = await addLedger('Main');
      await addTx(id);
      final out = await service.createBackup();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool(CloudBackupService.restorePendingKey) ?? false,
          isFalse,
          reason: '初始无检查点');

      final res = await service.restoreBackup(fileName: out.fileName);
      expect(res.failed, 0);

      // 恢复正常完成 → 检查点清除（调度器恢复正常触发）
      expect(prefs.getBool(CloudBackupService.restorePendingKey) ?? false,
          isFalse);
    });

    test('P1-2 恢复检查点：整体失败（备份损坏）也清除 —— 本地未动，无半恢复态',
        () async {
      final id = await addLedger('Main');
      await addTx(id);
      await service.createBackup();

      // 塞一个损坏备份（合法命名、非法内容）
      await storage.upload(
          path:
              '${CloudBackupService.backupDir}/PiggyCount-2026-09-11.zip',
          data: 'not-a-zip',
          metadata: null);

      final prefs = await SharedPreferences.getInstance();
      try {
        await service.restoreBackup(fileName: 'PiggyCount-2026-09-11.zip');
        fail('损坏备份应抛错');
      } on Exception {
        // 预期：备份文件损坏，无法解析
      }
      expect(prefs.getBool(CloudBackupService.restorePendingKey) ?? false,
          isFalse,
          reason: '整体失败路径本地数据未动，检查点必须清除');
    });

    test('全新环境恢复：账本与附件均落位', () async {
      // 源库备份
      final id = await addLedger('Main');
      await addTx(id, amount: 42);
      final sha = crypto.sha256.convert([9, 9]).toString();
      await addAttachmentFile('bill.png', [9, 9]);
      final txs = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(id)))
          .get();
      await db.into(db.transactionAttachments).insert(
          TransactionAttachmentsCompanion.insert(
              transactionId: txs.first.id,
              fileName: 'bill.png',
              fileSize: const drift.Value(2),
              localSha256: drift.Value(sha)));
      final out = await service.createBackup();

      // 目标库：共享同一假存储与全新 docs 目录
      final db2 = PiggyDatabase.forTesting(NativeDatabase.memory());
      final repo2 = LocalRepository(db2);
      final docsDir2 = Directory('${tempRoot.path}/docs2');
      await docsDir2.create(recursive: true);
      final service2 = CloudBackupService(
        db: db2,
        repo: repo2,
        storageResolver: () async => storage,
        documentsDir: () async => docsDir2,
      );

      final res = await service2.restoreBackup(fileName: out.fileName);

      expect(res.success, 1);
      expect(res.failed, 0);
      expect(res.attachmentsRestored, 1);
      final ledgers2 = await db2.select(db2.ledgers).get();
      expect(ledgers2.single.name, 'Main');
      final txRows = await db2.select(db2.transactions).get();
      expect(txRows.single.amount, 42);
      expect(
          await File('${docsDir2.path}/attachments/bill.png').exists(), isTrue);

      await db2.close();
    });

    test('本地已有同 ID 账本：整体覆盖回快照时点', () async {
      final id = await addLedger('Main');
      await addTx(id, amount: 10);
      final out = await service.createBackup();

      await addTx(id, amount: 99); // 快照后的本地新改动
      final res = await service.restoreBackup(fileName: out.fileName);

      expect(res.success, 1);
      final rows = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(id)))
          .get();
      expect(rows.length, 1);
      expect(rows.first.amount, 10);
    });

    test('ZIP 损坏：抛 CloudSyncException 且不动本地', () async {
      storage.files['piggycount-bak/PiggyCount-2026-08-16.zip'] = '!!!非base64!!!';
      final id = await addLedger('Main');
      await addTx(id);
      await expectLater(
          service.restoreBackup(fileName: 'PiggyCount-2026-08-16.zip'),
          throwsA(isA<fcs.CloudSyncException>()));
      final rows = await db.select(db.transactions).get();
      expect(rows.length, 1);
    });

    test('附件 sha256 不匹配：跳过落盘但账本正常恢复', () async {
      // 手工构造：账本条目来自真实导出，附件条目内容与声明 sha 不符
      final id = await addLedger('Main');
      await addTx(id);
      final jsonStr = await exportTransactionsJson(db, id);
      final archive = Archive();
      final lb = utf8.encode(jsonStr);
      archive.addFile(ArchiveFile('ledger_$id.json', lb.length, lb));
      final wrongBytes = [7, 7, 7];
      archive.addFile(ArchiveFile(
          'attachments/deadbeef.bin', wrongBytes.length, wrongBytes));
      storage.files['piggycount-bak/PiggyCount-2026-08-16.zip'] =
          base64Encode(ZipEncoder().encode(archive) ?? []);

      final res = await service.restoreBackup(
          fileName: 'PiggyCount-2026-08-16.zip');

      expect(res.success, 1);
      // 本地无对应附件行（导出时无附件），仅验证坏对象未落盘
      expect(await File('${docsDir.path}/attachments/any').exists(), isFalse);
    });
  });

  group('binary storage（真字节路径）', () {
    test('BinaryCapableStorage：上传原始 ZIP 字节（PK 魔数），云端可直接解压', () async {
      final binStorage = _BinaryFakeStorage();
      final binService = CloudBackupService(
        db: db,
        repo: repo,
        storageResolver: () async => binStorage,
        documentsDir: () async => docsDir,
      );
      final id = await addLedger('Main');
      await addTx(id, amount: 7);

      final out = await binService.createBackup();

      final key = 'piggycount-bak/${out.fileName}';
      final stored = binStorage.binFiles[key];
      expect(stored, isNotNull, reason: '二进制后端应存原始字节');
      // ZIP 魔数 PK\x03\x04：外部工具可直接打开的凭证
      expect(stored!.take(4).toList(), [0x50, 0x4B, 0x03, 0x04]);
      final archive = ZipDecoder().decodeBytes(stored);
      expect(archive.map((f) => f.name), contains('ledger_$id.json'));
    });

    test('二进制后端产物经 downloadBinary 往返恢复', () async {
      final binStorage = _BinaryFakeStorage();
      final binService = CloudBackupService(
        db: db,
        repo: repo,
        storageResolver: () async => binStorage,
        documentsDir: () async => docsDir,
      );
      final id = await addLedger('Main');
      await addTx(id, amount: 11);
      final out = await binService.createBackup();

      // 目标库：全新环境从二进制备份恢复
      final db2 = PiggyDatabase.forTesting(NativeDatabase.memory());
      final repo2 = LocalRepository(db2);
      final docsDir2 = Directory('${tempRoot.path}/docs_bin2');
      await docsDir2.create(recursive: true);
      final service2 = CloudBackupService(
        db: db2,
        repo: repo2,
        storageResolver: () async => binStorage,
        documentsDir: () async => docsDir2,
      );
      final res = await service2.restoreBackup(fileName: out.fileName);

      expect(res.success, 1);
      expect(res.failed, 0);
      final rows = await db2.select(db2.transactions).get();
      expect(rows.single.amount, 11);
      await db2.close();
    });

    test('旧版 base64 备份文件被二进制路径读回：嗅探兼容恢复', () async {
      // 源库走 base64 兜底上传（历史版本行为）
      final id = await addLedger('Main');
      await addTx(id, amount: 33);
      final out = await service.createBackup();
      final key = 'piggycount-bak/${out.fileName}';
      expect(storage.files[key], isNotNull);

      // 模拟：旧 base64 文本文件留在 WebDAV 上，新版用二进制路径读回原始字节
      final legacy = _LegacyBinaryFake(storage);
      final db2 = PiggyDatabase.forTesting(NativeDatabase.memory());
      final repo2 = LocalRepository(db2);
      final docsDir2 = Directory('${tempRoot.path}/docs_legacy');
      await docsDir2.create(recursive: true);
      final service2 = CloudBackupService(
        db: db2,
        repo: repo2,
        storageResolver: () async => legacy,
        documentsDir: () async => docsDir2,
      );
      final res = await service2.restoreBackup(fileName: out.fileName);

      expect(res.success, 1, reason: 'base64 文本字节应走嗅探分支还原');
      await db2.close();
    });

    test('listBackups 对带子目录前缀的 name 归一化（S3 口径）', () async {
      final id = await addLedger('Main');
      await addTx(id);
      await service.createBackup();

      final s3Style = _S3NameFake();
      s3Style.files.addAll(storage.files);
      final s3Service = CloudBackupService(
        db: db,
        repo: repo,
        storageResolver: () async => s3Style,
        documentsDir: () async => docsDir,
      );

      final list = await s3Service.listBackups();
      expect(list.length, 1, reason: '带 piggycount-bak/ 前缀的 name 也应被识别');
      expect(list.single.fileName, startsWith('PiggyCount-'));
      expect(list.single.fileName, endsWith('.zip'));
      expect(list.single.fileName.contains('/'), isFalse);
    });
  });
}

/// 二进制能力假存储：uploadBinary 存原始字节（与 WebDAV/S3 同口径）
class _BinaryFakeStorage extends _FakeStorage
    implements fcs.BinaryCapableStorage {
  final Map<String, Uint8List> binFiles = {};

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    binFiles[path] = Uint8List.fromList(bytes);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async =>
      binFiles[path];

  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    // 模拟 WebDAV：name 为纯文件名
    final prefix = path.endsWith('/') ? path : '$path/';
    return [
      for (final e in binFiles.entries)
        if (e.key.startsWith(prefix))
          fcs.CloudFile(
              name: e.key.substring(prefix.length),
              path: e.key,
              size: e.value.length)
    ];
  }
}

/// 模拟旧 base64 文件存在后端、被二进制路径读回「文本字节」的场景
class _LegacyBinaryFake extends _FakeStorage
    implements fcs.BinaryCapableStorage {
  _LegacyBinaryFake(this.source);

  final _FakeStorage source;

  @override
  Future<void> uploadBinary({
    required String path,
    required List<int> bytes,
    Map<String, String>? metadata,
  }) async {
    source.files[path] = utf8.decode(bytes);
  }

  @override
  Future<Uint8List?> downloadBinary({required String path}) async {
    final text = source.files[path];
    if (text == null) return null;
    return Uint8List.fromList(utf8.encode(text));
  }
}

/// 模拟 S3 list 口径：name 只剥 keyPrefix、不剥查询子目录（带前缀）
class _S3NameFake extends _FakeStorage {
  @override
  Future<List<fcs.CloudFile>> list({required String path}) async {
    final prefix = path.endsWith('/') ? path : '$path/';
    return [
      for (final e in files.entries)
        if (e.key.startsWith(prefix))
          fcs.CloudFile(
              name: e.key, path: e.key, size: e.value.length) // 不剥前缀
    ];
  }
}
