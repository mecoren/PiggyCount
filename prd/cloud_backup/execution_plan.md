# PiggyCount 云端备份模块 实现计划

> **执行方式**：按任务顺序逐个执行，每步含验证。**用户规则：未要求提交 GIT，全程不做 git commit**，以 `flutter analyze` + `flutter test` 作为每任务完成证据。
> 关联需求：`/prd/cloud_backup/requirements.md`　关联设计：`/prd/cloud_backup/design.md`

**Goal:** 在云同步页全量同步卡片下方新增「云端备份」卡片：手动/每日定时全量备份到云端 `piggycount-bak/`（每日一份 `PiggyCount-yyyy-MM-dd.zip`，含账本+附件），支持从备份列表选择恢复（双重 5 秒危险确认）。

**Architecture:** 独立 `CloudBackupService`（复用 exportTransactionsJson / importTransactionsJson / E2EE 装饰 storage）+ `BackupScheduler`（1 分钟 Timer）+ providers 装配 + cloud_sync_page 卡片。对现有代码最小侵入：`TransactionsSyncManager` 新增 `decoratedStorage()` getter；`data_import_service.dart` 抽出公共 `restoreLedgerFromJson()`。

**Tech Stack:** Flutter/Dart、drift（内存库测试）、archive（ZipEncoder/ZipDecoder，项目既有模式）、Riverpod、SharedPreferences、l10n arb ×4。

**基线：** 执行前先跑 `flutter analyze` 记录告警数（当前约 777），每个任务后不得新增。

---

### Task 1: data_import_service 抽出 restoreLedgerFromJson（TDD）

**Files:**
- Test: `test/backup/restore_ledger_from_json_test.dart`
- Modify: `lib/services/data_import_service.dart`
- Modify: `lib/cloud/transactions_sync_manager.dart`（`downloadAndRestoreToCurrentLedger` L798-825 改为调用公共函数；删除 `_clearLedgerTransactions` L877-898；新增 `decoratedStorage()`）

- [ ] **Step 1.1: 写失败测试**

```dart
// test/backup/restore_ledger_from_json_test.dart
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => await db.close());

  Future<int> addLedger(String name) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: name));

  Future<void> addTx(int ledgerId, {double amount = 10}) => db
      .into(db.transactions)
      .insert(TransactionsCompanion.insert(
          ledgerId: ledgerId, type: 'expense', amount: amount));

  test('快照整体覆盖：清空本地后导入快照内容', () async {
    final id = await addLedger('Main');
    await addTx(id, amount: 10);
    final snapshot = await exportTransactionsJson(db, id);

    // 快照后再新增一笔，恢复应回到快照时点
    await addTx(id, amount: 99);
    var rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 2);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);
    rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1);
    expect(rows.first.amount, 10);
  });

  test('P1-1 守卫：空快照拒绝覆盖非空本地账本，返回 null', () async {
    final id = await addLedger('Main');
    await addTx(id);
    // 手工构造空交易快照（复用 export 再清空 items）
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    (map['items'] as List).clear();
    final emptySnapshot = jsonEncode(map);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: emptySnapshot);
    expect(result, isNull);
    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1); // 本地数据未被清空
  });
}

// 测试辅助：解码 JSON 为 Map（避免每个测试文件重复写）
Map<String, dynamic> jsonDecodeMap(String s) =>
    (jsonDecode(s) as Map).cast<String, dynamic>();
```

注：文件顶部按编译报错补 `import 'dart:convert';` 与正确的包名（项目 package 名以 `pubspec.yaml` 的 `name:` 为准，若为 `piggycount` 之外的名称请替换 import 前缀）。

- [ ] **Step 1.2: 跑测试确认失败**

Run: `flutter test test/backup/restore_ledger_from_json_test.dart`
Expected: FAIL（`restoreLedgerFromJson` 未定义）

- [ ] **Step 1.3: 在 data_import_service.dart 实现公共函数**

在 `lib/services/data_import_service.dart` 末尾追加（并按需补 import：`../data/db.dart`、`../data/repositories/base_repository.dart`、`dart:convert`、`system/logger_service.dart`、`../cloud/transactions_json.dart`）：

```dart
/// ============================================================
/// 账本整体恢复（云同步恢复 / 云端备份恢复 共用）
/// ============================================================

/// 清空指定账本的全部交易及关联行（transactionTags /
/// transactionAttachments）。
///
/// 从 TransactionsSyncManager 迁移为公共函数：恢复是「先清空再导入」，
/// 清空逻辑必须单一事实源，避免备份/同步两条链路各自实现产生分叉。
/// 不记录 local_changes（为导入数据腾位置，不应反向回流云端）。
/// 调用方应将其与导入操作包裹在同一事务内，保证原子性。
Future<int> clearLedgerTransactions(PiggyDatabase db, int ledgerId) async {
  final txIds = await (db.selectOnly(db.transactions)
        ..addColumns([db.transactions.id])
        ..where(db.transactions.ledgerId.equals(ledgerId)))
      .map((row) => row.read(db.transactions.id)!)
      .get();

  if (txIds.isEmpty) return 0;

  await (db.delete(db.transactionTags)
        ..where((t) => t.transactionId.isIn(txIds)))
      .go();
  await (db.delete(db.transactionAttachments)
        ..where((t) => t.transactionId.isIn(txIds)))
      .go();
  final deleted = await (db.delete(db.transactions)
        ..where((t) => t.ledgerId.equals(ledgerId)))
      .go();
  logger.info('DataImport', '恢复前清空账本 $ledgerId: 删除 $deleted 笔交易');
  return deleted;
}

/// 用快照 JSON 整体恢复指定账本（清空后导入，事务原子）。
///
/// 抽取自 TransactionsSyncManager.downloadAndRestoreToCurrentLedger 中段，
/// 供云同步恢复与云端备份恢复（CloudBackupService）共用同一语义。
///
/// 返回 (inserted, deletedDup)；返回 null 表示跳过恢复：
/// - P1-1 守卫：快照不含任何交易且本地非空 → 拒绝空覆盖
///   （误上传空文件不应静默抹掉本地全部交易；确需清空走显式上传覆盖）。
///
/// [jsonStr] 必须是已解密的明文 JSON。调用方需保证 ledgerId 的本地账本已存在。
Future<({int inserted, int deletedDup})?> restoreLedgerFromJson({
  required PiggyDatabase db,
  required BaseRepository repo,
  required int ledgerId,
  required String jsonStr,
}) async {
  final remoteImport = parseJsonToImportData(jsonStr);
  if (remoteImport.transactions.isEmpty) {
    final localRows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
    if (localRows.isNotEmpty) {
      logger.warning('DataImport',
          '快照为空但本地有 ${localRows.length} 条交易，拒绝空覆盖（ledgerId=$ledgerId）');
      return null;
    }
  }

  // 清空 + 导入包裹同一事务：导入失败则清空一并回滚，本地不会被部分清空。
  // importTransactionsJson 内部事务作为 savepoint 嵌套。
  // recordChanges: false —— 恢复不应写入本地变更历史（P2-3）
  final deleted = await db.transaction(() async {
    final cleared = await clearLedgerTransactions(db, ledgerId);
    final result = await importTransactionsJson(repo, ledgerId, jsonStr,
        recordChanges: false);
    return (cleared, result);
  });

  return (inserted: deleted.$2.inserted, deletedDup: deleted.$1);
}
```

- [ ] **Step 1.4: 改造 TransactionsSyncManager**

1. `downloadAndRestoreToCurrentLedger`（约 L798-825）中，把从「P1-1 空快照守卫」到「`final result = deletedDup.$2;`」的整段替换为：

```dart
      // 复用公共恢复管线（P1-1 守卫 + 事务内清空导入），
      // 与云端备份恢复（CloudBackupService）同一语义单一事实源
      final restored = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: ledgerId, jsonStr: jsonStr);
      if (restored == null) {
        return (inserted: 0, deletedDup: 0);
      }
      final result = restored.inserted;
      final deletedDupCount = restored.deletedDup;
```

并同步调整方法尾部 return 与日志（原 `deletedDup.$1` → `deletedDupCount`）：

```dart
      logger.info('CloudSync',
          '下载完成: inserted=$result, deletedDup=$deletedDupCount');
```

```dart
      return (inserted: result, deletedDup: deletedDupCount);
```

2. 删除 `_clearLedgerTransactions` 方法（约 L877-898，逻辑已迁移）。
3. 在 `rawStorage` getter 附近新增：

```dart
  /// 装饰后的 storage（E2EE 开启时上传/下载自动加解密），供云端备份等
  /// 模块复用同一加密装配。provider 未初始化/不可用（如 iCloud 未登录）
  /// 时返回 null。
  Future<fcs.CloudStorageService?> decoratedStorage() async {
    await _ensureInitialized();
    return _provider?.storage;
  }
```

- [ ] **Step 1.5: 跑测试与分析**

Run: `flutter test test/backup/restore_ledger_from_json_test.dart`
Expected: PASS（2 用例）
Run: `flutter analyze`
Expected: 告警数 ≤ 基线（`downloadAndRestoreToCurrentLedger` 相关无新告警）
Run: `flutter test test/cloud`（若目录存在）
Expected: 既有用例不回归

---

### Task 2: CloudBackupService — createBackup / listBackups（TDD）

**Files:**
- Create: `lib/cloud/backup/cloud_backup_service.dart`
- Test: `test/backup/cloud_backup_service_test.dart`

- [ ] **Step 2.1: 写失败测试（备份/列举部分）**

```dart
// test/backup/cloud_backup_service_test.dart
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/native.dart' hide toJson;
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;

import 'package:piggycount/cloud/backup/backup_scheduler.dart';
import 'package:piggycount/cloud/backup/cloud_backup_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

/// 内存假存储：记录 upload 的 path→data，list 按前缀过滤
class _FakeStorage extends fcs.NoopStorageService {
  final Map<String, String> files = {};

  @override
  Future<void> upload(
      {required String path,
      required String data,
      Map<String, String>? metadata}) async {
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
      documentsDir: () => docsDir,
    );
  });

  tearDown(() async {
    await db.close();
    await tempRoot.delete(recursive: true);
  });

  Future<int> addLedger(String name) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: name));

  Future<int> addTx(int ledgerId, {double amount = 10}) => db
      .into(db.transactions)
      .insert(TransactionsCompanion.insert(
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
            fileSize: 3,
            localSha256: const drift.Value(sha)));

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
}
```

注：`TransactionAttachmentsCompanion.insert` 必填列以编译报错为准按 `db.dart` 表定义补齐；`drift.Value` 需 `import 'package:drift/drift.dart' as drift;`。

- [ ] **Step 2.2: 跑测试确认失败**

Run: `flutter test test/backup/cloud_backup_service_test.dart`
Expected: FAIL（库文件不存在）

- [ ] **Step 2.3: 实现 CloudBackupService（含 restoreBackup 骨架）**

```dart
// lib/cloud/backup/cloud_backup_service.dart
import 'dart:convert';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path_provider/path_provider.dart';

import '../../data/db.dart';
import '../../data/encryption/ciphertext_format.dart';
import '../../data/repositories/base_repository.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../services/data_import_service.dart';
import '../../services/system/logger_service.dart';
import '../transactions_json.dart';

/// 云端备份文件信息（listBackups 返回）
class BackupFileInfo {
  const BackupFileInfo(
      {required this.fileName, required this.date, this.size});

  /// 云端文件名，如 PiggyCount-2026-08-16.zip
  final String fileName;

  /// 从文件名解析的备份日期（本地时区）
  final DateTime date;

  /// 字节数（后端支持时非空）
  final int? size;
}

/// 单次备份结果
typedef BackupOutcome = ({int ledgers, int attachments, String fileName});

/// 单次恢复结果
typedef RestoreOutcome =
    ({int success, int failed, int attachmentsRestored, String fileName});

/// 云端全量备份服务（/prd/cloud_backup/design.md）
///
/// 备份产物：piggycount-bak/PiggyCount-yyyy-MM-dd.zip（本地时区，当日覆盖）。
/// ZIP 内部镜像云端同步目录（ledger_<id>.json + attachments/<sha256>.bin），
/// 容器整体 base64 后经装饰 storage 传输 —— 与现有附件上传同一路径，
/// E2EE 开启时由 EncryptedCloudStorageService 透明加密（字节级同口径）。
class CloudBackupService {
  CloudBackupService({
    required this.db,
    required this.repo,
    required this.storageResolver,
    this.encryptionService,
    Future<Directory> Function()? documentsDir,
  }) : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final PiggyDatabase db;
  final BaseRepository repo;

  /// 解析装饰后 storage（E2EE 自动加解密）；生产环境传入
  /// `(syncManager as TransactionsSyncManager).decoratedStorage`。
  final Future<fcs.CloudStorageService?> Function() storageResolver;

  /// 用于防御性解密 ZIP 内意外为密文的 ledger JSON（正常流程内层恒为明文）
  final EncryptionService? encryptionService;

  final Future<Directory> Function() _documentsDir;

  /// 备份/恢复互斥锁：手动与定时共用，防止并发写云端/写本地
  bool _busy = false;

  /// 云端备份专用目录
  static const String backupDir = 'piggycount-bak';

  /// 合法备份文件名：PiggyCount-yyyy-MM-dd.zip
  static final RegExp _backupNamePattern =
      RegExp(r'^PiggyCount-(\d{4}-\d{2}-\d{2})\.zip$');

  /// ZIP 内账本条目名：ledger_<id>.json
  static final RegExp _ledgerEntryPattern = RegExp(r'^ledger_(\d+)\.json$');

  /// 生成当日备份文件名（本地时区）
  static String backupFileNameFor(DateTime now) =>
      'PiggyCount-${BackupDateUtils.formatDate(now)}.zip';

  Future<fcs.CloudStorageService> _requireStorage() async {
    final storage = await storageResolver();
    if (storage == null) {
      throw fcs.CloudSyncException('云服务不可用，请检查配置或登录状态');
    }
    return storage;
  }

  /// 创建全量备份：全部本地账本 JSON + 引用的附件二进制 → ZIP → base64 上传。
  ///
  /// 孤儿附件行（本地物理文件缺失）跳过并 warning，不阻断（对齐
  /// uploadAttachmentObjects 口径）。无本地账本抛 StateError。
  Future<BackupOutcome> createBackup({
    void Function(int done, int total)? onLedgersProgress,
    void Function(int done, int total)? onAttachmentsProgress,
  }) async {
    if (_busy) {
      throw StateError('已有备份/恢复操作正在执行');
    }
    _busy = true;
    try {
      final storage = await _requireStorage();
      final ledgers = await repo.getAllLedgers();
      if (ledgers.isEmpty) {
        throw StateError('没有可备份的账本');
      }

      final archive = Archive();

      // 1. 账本快照：exportTransactionsJson 原始产物（与同步上传完全同构）
      var done = 0;
      for (final ledger in ledgers) {
        final jsonStr = await exportTransactionsJson(db, ledger.id);
        final bytes = utf8.encode(jsonStr);
        archive.addFile(
            ArchiveFile('ledger_${ledger.id}.json', bytes.length, bytes));
        done++;
        onLedgersProgress?.call(done, ledgers.length);
      }

      // 2. 附件：全库 localSha256 去重并集，同 sha 任一物理文件作源
      //    （镜像 uploadAttachmentObjects 的定位逻辑）
      final attachments = await (db.select(db.transactionAttachments)
            ..where((a) => a.localSha256.isNotNull()))
          .get();
      final filesBySha = <String, List<String>>{};
      for (final a in attachments) {
        final sha = a.localSha256;
        if (sha == null || sha.isEmpty) continue;
        filesBySha.putIfAbsent(sha, () => []).add(a.fileName);
      }
      final appDir = await _documentsDir();
      final attDir = Directory('${appDir.path}/attachments');
      var attDone = 0;
      var attPacked = 0;
      for (final entry in filesBySha.entries) {
        String? srcPath;
        for (final name in entry.value) {
          final f = File('${attDir.path}/$name');
          if (await f.exists()) {
            srcPath = f.path;
            break;
          }
        }
        if (srcPath == null) {
          logger.warning('Backup',
              '附件本地文件缺失，跳过打包: sha256=${entry.key}');
        } else {
          final bytes = await File(srcPath).readAsBytes();
          archive.addFile(ArchiveFile(
              'attachments/${entry.key}.bin', bytes.length, bytes));
          attPacked++;
        }
        attDone++;
        onAttachmentsProgress?.call(attDone, filesBySha.length);
      }

      // 3. ZIP → base64 → 上传（upsert 语义天然实现当日覆盖）
      final zipData = ZipEncoder().encode(archive);
      final fileName = backupFileNameFor(DateTime.now());
      await storage.upload(
          path: '$backupDir/$fileName', data: base64Encode(zipData));

      logger.info('Backup',
          '备份完成: $fileName 账本=${ledgers.length} 附件=$attPacked');
      return (
        ledgers: ledgers.length,
        attachments: attPacked,
        fileName: fileName
      );
    } finally {
      _busy = false;
    }
  }

  /// 列出云端备份（仅合法命名，按日期倒序）
  Future<List<BackupFileInfo>> listBackups() async {
    final storage = await _requireStorage();
    final files = await storage.list(path: backupDir);
    final result = <BackupFileInfo>[];
    for (final f in files) {
      final m = _backupNamePattern.firstMatch(f.name);
      if (m == null) continue;
      final date = DateTime.tryParse(m.group(1)!);
      if (date == null) continue;
      result.add(
          BackupFileInfo(fileName: f.name, date: date, size: f.size));
    }
    result.sort((a, b) => b.date.compareTo(a.date));
    return result;
  }

  /// 全量覆盖恢复：下载选中备份 → 解包 → 逐账本导入（本地已有整体覆盖、
  /// 备份独有新建、本地独有保留）→ ZIP 内附件经 sha256 校验落盘。
  ///
  /// 单账本失败计数不中断（语义对齐 fullRestoreAllRemoteLedgers）。
  Future<RestoreOutcome> restoreBackup({
    required String fileName,
    void Function(int done, int total)? onProgress,
  }) async {
    if (_busy) {
      throw StateError('已有备份/恢复操作正在执行');
    }
    _busy = true;
    try {
      final storage = await _requireStorage();

      // 1. 下载 + 解码 + 解包（任一失败整体报错，不动本地数据）
      final raw = await storage.download(path: '$backupDir/$fileName');
      if (raw == null) {
        throw fcs.CloudSyncException('备份文件不存在: $fileName');
      }
      final Uint8ListLike zipBytes;
      final Archive archive;
      try {
        zipBytes = base64Decode(raw);
        archive = ZipDecoder().decodeBytes(zipBytes);
      } catch (e) {
        throw fcs.CloudSyncException('备份文件损坏，无法解析: $fileName');
      }
      final entries = {for (final f in archive) f.name: f};

      // 2. 逐账本恢复：本地已有 → restoreLedgerFromJson 整体覆盖；
      //    备份独有 → 复用 downloadRemoteLedger 的 ID 解析语义导入新建
      final localIds =
          (await db.select(db.ledgers).get()).map((l) => l.id).toSet();
      final ledgerEntries = entries.keys
          .where((n) => _ledgerEntryPattern.hasMatch(n))
          .toList()
        ..sort();
      var success = 0;
      var failed = 0;
      for (final name in ledgerEntries) {
        final remoteId =
            int.parse(_ledgerEntryPattern.firstMatch(name)!.group(1)!);
        try {
          final jsonStr = await _resolveInnerJson(
              utf8.decode(entries[name]!.content as List<int>));
          if (jsonStr == null) {
            throw fcs.CloudSyncException('备份账本密文无法解密: $name');
          }
          if (localIds.contains(remoteId)) {
            final restored = await restoreLedgerFromJson(
                db: db, repo: repo, ledgerId: remoteId, jsonStr: jsonStr);
            if (restored == null) {
              // P1-1 守卫触发：空快照拒绝覆盖非空本地账本
              throw fcs.CloudSyncException('空快照被拒绝覆盖本地账本: $name');
            }
          } else {
            final newId = await _importNewLedgerFromBackup(
                remoteId: remoteId, jsonStr: jsonStr);
            if (newId == null) {
              throw fcs.CloudSyncException('备份账本导入失败: $name');
            }
          }
          success++;
        } catch (e) {
          failed++;
          logger.warning('Backup', '恢复备份账本失败: $name - $e');
        }
        onProgress?.call(success + failed, ledgerEntries.length);
      }

      // 3. 附件落盘：镜像 drainAttachmentJobs 语义（sha256 校验必须做：
      //    内容寻址的信任根基是「路径即哈希」），数据源换为 ZIP
      final restoredAttachments = await _restoreAttachmentsFromArchive(entries);

      logger.info('Backup',
          '备份恢复完成: $fileName 成功=$success 失败=$failed 附件=$restoredAttachments');
      return (
        success: success,
        failed: failed,
        attachmentsRestored: restoredAttachments,
        fileName: fileName
      );
    } finally {
      _busy = false;
    }
  }

  /// 防御性内层密文处理：正常流程容器由装饰 storage 解密，内层恒为明文；
  /// 若遇到 BEECRYPT1: 前缀（如手工构造/异常产物）尝试用加密服务解密。
  /// 无加密服务可用时返回 null（该账本计入 failed）。
  Future<String?> _resolveInnerJson(String raw) async {
    if (!raw.startsWith(ciphertextPrefix)) return raw;
    final svc = encryptionService;
    if (svc == null) return null;
    try {
      return await svc.decrypt(raw);
    } catch (e) {
      logger.warning('Backup', '备份内层密文解密失败: $e');
      return null;
    }
  }

  /// 备份独有账本导入新建（镜像 downloadRemoteLedger 的 ID 解析语义：
  /// 同名复用 → 远程 ID 空闲复用 → 新 ID），但不触碰云端同步文件。
  Future<int?> _importNewLedgerFromBackup(
      {required int remoteId, required String jsonStr}) async {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    final name =
        (json['ledgerName'] as String?) ?? (json['name'] as String?) ?? 'Unknown';
    final currency = (json['currency'] as String?) ?? 'CNY';

    final existingByName = await (db.select(db.ledgers)
          ..where((t) => t.name.equals(name)))
        .getSingleOrNull();

    final int ledgerId;
    if (existingByName != null) {
      ledgerId = existingByName.id;
    } else {
      final existingById = await (db.select(db.ledgers)
            ..where((t) => t.id.equals(remoteId)))
          .getSingleOrNull();
      if (existingById == null) {
        ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
              id: drift.Value(remoteId),
              name: name,
              currency: drift.Value(currency),
            ));
      } else {
        ledgerId = await db.into(db.ledgers).insert(
            LedgersCompanion.insert(
                name: name, currency: drift.Value(currency)));
      }
    }

    await importTransactionsJson(repo, ledgerId, jsonStr,
        recordChanges: false);
    return ledgerId;
  }

  /// 从 ZIP 条目补齐本地缺失附件：只写缺失文件，sha256 校验不过则跳过。
  Future<int> _restoreAttachmentsFromArchive(
      Map<String, ArchiveFile> entries) async {
    final appDir = await _documentsDir();
    final attDir = Directory('${appDir.path}/attachments');
    await attDir.create(recursive: true);

    var restored = 0;
    final atts = await (db.select(db.transactionAttachments)
          ..where((a) => a.localSha256.isNotNull()))
        .get();
    for (final a in atts) {
      final sha = a.localSha256;
      if (sha == null || sha.isEmpty) continue;
      final entry = entries['attachments/$sha.bin'];
      if (entry == null) continue;
      final dest = File('${attDir.path}/${a.fileName}');
      if (await dest.exists()) continue;
      final bytes = entry.content as List<int>;
      // 校验内容哈希与内容寻址声明一致，拒绝损坏/错配对象
      final actual = crypto.sha256.convert(bytes).toString();
      if (actual != sha) {
        logger.warning('Backup', '附件 sha256 不匹配，跳过落盘: '
            'expect=$sha actual=$actual');
        continue;
      }
      await dest.writeAsBytes(bytes, flush: true);
      restored++;
    }
    return restored;
  }
}

/// base64Decode 返回类型别名（Uint8List）
typedef Uint8ListLike = List<int>;
```

注：
- `ciphertextPrefix` 从 `lib/data/encryption/ciphertext_format.dart` 导入，若实际常量名不同（如 `kBeeCryptPrefix`），以该文件导出为准替换。
- 若 `NoopStorageService` 不可继承（构造受限），改为 `class _FakeStorage implements fcs.CloudStorageService` 并实现全部 6 个抽象方法。

- [ ] **Step 2.4: 跑测试确认通过**

Run: `flutter test test/backup/cloud_backup_service_test.dart`
Expected: 5 用例 PASS
Run: `flutter analyze`（≤ 基线）

---

### Task 3: CloudBackupService.restoreBackup 测试（TDD 补齐）

**Files:**
- Test: `test/backup/cloud_backup_service_test.dart`（追加用例）

- [ ] **Step 3.1: 追加恢复用例**

```dart
  group('restoreBackup', () {
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
              fileSize: 2,
              localSha256: const drift.Value(sha)));
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
        documentsDir: () => docsDir2,
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
          base64Encode(ZipEncoder().encode(archive));

      final res = await service.restoreBackup(fileName: 'PiggyCount-2026-08-16.zip');

      expect(res.success, 1);
      // 本地无对应附件行（导出时无附件），仅验证坏对象未落盘
      expect(
          await File('${docsDir.path}/attachments/any').exists(), isFalse);
    });
  });
```

（文件顶部按需补 import：`transactions_json.dart` 等）

- [ ] **Step 3.2: 跑测试**

Run: `flutter test test/backup/cloud_backup_service_test.dart`
Expected: 全部 PASS

---

### Task 4: BackupScheduler（TDD）

**Files:**
- Create: `lib/cloud/backup/backup_scheduler.dart`
- Test: `test/backup/backup_scheduler_test.dart`

- [ ] **Step 4.1: 写失败测试**

```dart
// test/backup/backup_scheduler_test.dart
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/cloud/backup/backup_scheduler.dart';

void main() {
  group('shouldTriggerNow 触发条件矩阵', () {
    final now = DateTime(2026, 8, 16, 22, 30);

    test('开关关闭 → 不触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: false,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: now),
          isFalse);
    });

    test('未到设定时间 → 不触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 23 * 60,
              lastDate: '2026-08-15',
              now: now),
          isFalse);
    });

    test('到达设定时间且当日未备 → 触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: now),
          isTrue);
    });

    test('当日已备（无论成败）→ 不再触发', () {
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-16',
              now: now),
          isFalse);
    });

    test('跨过设定时间后启动（补触发语义）', () {
      // 早上 8 点启动，昨晚 22:00 的备份窗口已过且今日未备 → 立即触发
      expect(
          BackupScheduler.shouldTriggerNow(
              enabled: true,
              scheduledMinutes: 22 * 60,
              lastDate: '2026-08-15',
              now: DateTime(2026, 8, 16, 8, 0)),
          isTrue);
    });
  });

  group('时间与日期工具', () {
    test('parseHhMm', () {
      expect(BackupScheduler.parseHhMm('22:00'), 22 * 60);
      expect(BackupScheduler.parseHhMm('00:05'), 5);
      expect(BackupScheduler.parseHhMm('bad'), 0);
    });

    test('formatHhMm / formatDate 往返', () {
      expect(BackupScheduler.formatHhMm(22 * 60), '22:00');
      expect(BackupScheduler.formatHhMm(5), '00:05');
      expect(BackupScheduler.formatDate(DateTime(2026, 8, 6)),
          '2026-08-06');
    });
  });

  test('start/dispose 幂等安全', () {
    final s = BackupScheduler(onCheck: () async {})..start();
    s.start(); // 重复 start 不重建 Timer
    s.dispose();
    s.dispose(); // 重复 dispose 安全
  });
}
```

- [ ] **Step 4.2: 跑测试确认失败**

Run: `flutter test test/backup/backup_scheduler_test.dart`
Expected: FAIL（库不存在）

- [ ] **Step 4.3: 实现**

```dart
// lib/cloud/backup/backup_scheduler.dart
import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

/// 每日定时备份调度器（/prd/cloud_backup/design.md §3.4）
///
/// 职责刻意收窄：只做周期 tick + 互斥；触发条件判定是纯静态函数
/// [shouldTriggerNow]（可单测），业务编排在 app.dart 注入的 onCheck 里。
class BackupScheduler {
  BackupScheduler({required this.onCheck});

  /// 每分钟检查一次（App 运行期间；无后台常驻能力为已声明的非目标）
  static const Duration checkInterval = Duration(minutes: 1);

  /// 每日默认触发时间（HH:mm）
  static const String defaultBackupTime = '22:00';

  final Future<void> Function() onCheck;

  Timer? _timer;
  bool _checking = false;

  void start() {
    _timer ??= Timer.periodic(checkInterval, (_) => _tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 互斥：上一次检查（含备份执行）未完成时跳过本次 tick
    if (_checking) return;
    _checking = true;
    try {
      await onCheck();
    } catch (e) {
      // 调度层吞异常：业务层已自行记录成败状态
    } finally {
      _checking = false;
    }
  }

  /// 触发条件（全部满足才触发）：
  /// 1. 开关开启
  /// 2. 当前时刻 ≥ 今日设定时间（含「启动时已过窗口」的补触发）
  /// 3. 当日尚未触发过（backup_last_date ≠ 今天，成败均算）
  @visibleForTesting
  static bool shouldTriggerNow({
    required bool enabled,
    required int scheduledMinutes,
    required String? lastDate,
    required DateTime now,
  }) {
    if (!enabled) return false;
    if (lastDate == formatDate(now)) return false;
    return _minutesOfDay(now) >= scheduledMinutes;
  }

  /// 解析 "HH:mm" 为当日分钟数；非法输入回落 0 点（当日必触发兜底）
  @visibleForTesting
  static int parseHhMm(String value) {
    final parts = value.split(':');
    final h = int.tryParse(parts.isNotEmpty ? parts[0] : '') ?? 0;
    final m = parts.length > 1 ? (int.tryParse(parts[1]) ?? 0) : 0;
    return h.clamp(0, 23) * 60 + m.clamp(0, 59);
  }

  /// 分钟数格式化为 "HH:mm"
  @visibleForTesting
  static String formatHhMm(int minutes) {
    final h = (minutes ~/ 60).clamp(0, 23);
    final m = (minutes % 60).clamp(0, 59);
    return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}';
  }

  /// 本地时区日期 → "yyyy-MM-dd"（备份文件名与 last_date 共用）
  @visibleForTesting
  static String formatDate(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static int _minutesOfDay(DateTime now) => now.hour * 60 + now.minute;
}

/// 日期工具别名（CloudBackupService 文件名生成共用同一实现）
// ignore: avoid_classes_with_only_static_members
class BackupDateUtils {
  static String formatDate(DateTime d) => BackupScheduler.formatDate(d);
}
```

- [ ] **Step 4.4: 跑测试**

Run: `flutter test test/backup/backup_scheduler_test.dart`
Expected: PASS

---

### Task 5: 备份 providers

**Files:**
- Create: `lib/cloud/backup/cloud_backup_providers.dart`

- [ ] **Step 5.1: 实现 providers**

```dart
// lib/cloud/backup/cloud_backup_providers.dart
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/database_providers.dart';
import '../../providers/encryption_providers.dart';
import '../../providers/sync_providers.dart'
    show syncServiceProvider, repositoryProvider;
import '../transactions_sync_manager.dart';
import 'backup_scheduler.dart';
import 'cloud_backup_service.dart';

/// 云端备份服务（仅路径 A 快照后端可用；PiggyCount Cloud / LocalOnly 为 null）
final cloudBackupServiceProvider = Provider<CloudBackupService?>((ref) {
  final sync = ref.watch(syncServiceProvider);
  if (sync is! TransactionsSyncManager) return null;
  return CloudBackupService(
    db: ref.watch(databaseProvider),
    repo: ref.watch(repositoryProvider),
    // 复用同步管理器的 E2EE 装饰 storage：备份与同步同一加密口径
    storageResolver: () => sync.decoratedStorage(),
    encryptionService: ref.watch(encryptionServiceProvider),
  );
});

/// 备份相关 UI 状态刷新 tick（手动/定时备份完成后 +1）
final backupRefreshProvider = StateProvider<int>((ref) => 0);

/// 定时备份开关（持久化 backup_auto_enabled，默认关）
final backupAutoEnabledProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getBool('backup_auto_enabled') ?? false;
});

class BackupAutoSetter {
  BackupAutoSetter(this._ref);
  final Ref _ref;
  Future<void> set(bool v) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('backup_auto_enabled', v);
    _ref.invalidate(backupAutoEnabledProvider);
  }
}

final backupAutoSetterProvider =
    Provider<BackupAutoSetter>((ref) => BackupAutoSetter(ref));

/// 每日触发时间（持久化 backup_time，默认 22:00）
final backupTimeProvider = FutureProvider.autoDispose<String>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  return prefs.getString('backup_time') ?? BackupScheduler.defaultBackupTime;
});

class BackupTimeSetter {
  BackupTimeSetter(this._ref);
  final Ref _ref;
  Future<void> set(String hhMm) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('backup_time', hhMm);
    _ref.invalidate(backupTimeProvider);
  }
}

final backupTimeSetterProvider =
    Provider<BackupTimeSetter>((ref) => BackupTimeSetter(ref));

/// 最近一次备份状态（date + ok），从未备份为 null
final lastBackupInfoProvider =
    FutureProvider.autoDispose<({String date, bool ok})?>((ref) async {
  ref.watch(backupRefreshProvider);
  final prefs = await SharedPreferences.getInstance();
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final date = prefs.getString('backup_last_date');
  if (date == null || date.isEmpty) return null;
  return (date: date, ok: prefs.getString('backup_last_result') != 'fail');
});
```

注：`repositoryProvider` 实际定义于 `database_providers.dart`，import 以编译为准调整（勿重复导入冲突）。

- [ ] **Step 5.2: 验证**

Run: `flutter analyze`
Expected: ≤ 基线

---

### Task 6: l10n 四语言文案

**Files:**
- Modify: `lib/l10n/app_en.arb` / `app_zh.arb` / `app_zh_TW.arb` / `app_ko.arb`

- [ ] **Step 6.1: 四个 arb 文件各追加 22 个 key（en 模板含占位符元数据）**

app_en.arb 追加（其他语言同 key 去掉 `@` 元数据）：

```json
  "backupCardTitle": "Cloud Backup",
  "@backupCardTitle": {},
  "backupNowTitle": "Back Up Now",
  "backupNowSubtitle": "Pack all ledgers and attachments into one daily backup in piggycount-bak",
  "backupNoLedgers": "There are no ledgers to back up.",
  "backupRunningStatus": "Creating backup…",
  "backupPackingProgress": "Packing ledger {done}/{total}…",
  "@backupPackingProgress": { "placeholders": { "done": { "type": "int" }, "total": { "type": "int" } } },
  "backupSuccessMessage": "Backup uploaded: piggycount-bak/{fileName}",
  "@backupSuccessMessage": { "placeholders": { "fileName": { "type": "String" } } },
  "backupFailedAuthMessage": "Cloud authentication failed. Please check your cloud service configuration and retry.",
  "backupFailedNetworkMessage": "Backup failed. Please check your network and retry.",
  "restoreFromBackupTitle": "Restore from Backup",
  "restoreFromBackupSubtitle": "Overwrite local data with a selected daily backup (all ledgers and attachments)",
  "backupListDialogTitle": "Loading backups…",
  "backupListEmptyMessage": "No backups found in the cloud yet.",
  "restoreConfirm1Message": "This will overwrite ALL local ledger data (accounts, categories, transactions) with the backup from {date}. Newer local changes will be lost.",
  "@restoreConfirm1Message": { "placeholders": { "date": { "type": "String" } } },
  "restoreConfirm2Message": "This operation cannot be undone. Are you sure you want to continue?",
  "restoreRunningStatus": "Restoring from backup…",
  "restoreLedgerProgress": "Restoring ledger {done}/{total}…",
  "@restoreLedgerProgress": { "placeholders": { "done": { "type": "int" }, "total": { "type": "int" } } },
  "restoreResultMessage": "Restore finished: {success} succeeded, {failed} failed.",
  "@restoreResultMessage": { "placeholders": { "success": { "type": "int" }, "failed": { "type": "int" } } },
  "backupAutoTitle": "Scheduled Backup",
  "backupAutoSubtitle": "Automatically back up once per day at the configured time (while the app is running)",
  "backupTimeTitle": "Daily Backup Time",
  "lastBackupCaption": "Last backup: {date} · {ok}",
  "@lastBackupCaption": { "placeholders": { "date": { "type": "String" }, "ok": { "type": "String" } } }
```

app_zh.arb：

```json
  "backupCardTitle": "云端备份",
  "backupNowTitle": "立即备份",
  "backupNowSubtitle": "将全部账本与附件打包为一份当日备份，存入 piggycount-bak",
  "backupNoLedgers": "没有可备份的账本。",
  "backupRunningStatus": "正在创建备份…",
  "backupPackingProgress": "正在打包账本 {done}/{total}…",
  "backupSuccessMessage": "备份已上传：piggycount-bak/{fileName}",
  "backupFailedAuthMessage": "云端认证失败，请检查云服务配置后重试。",
  "backupFailedNetworkMessage": "备份失败，请检查网络后重试。",
  "restoreFromBackupTitle": "从备份恢复",
  "restoreFromBackupSubtitle": "用选定的每日备份覆盖本地数据（全部账本与附件）",
  "backupListDialogTitle": "正在读取备份列表…",
  "backupListEmptyMessage": "云端还没有备份。",
  "restoreConfirm1Message": "将使用 {date} 的备份覆盖本地全部账本数据（账户、分类、交易），比备份更新的本地改动将丢失。",
  "restoreConfirm2Message": "此操作不可撤销，确定要继续吗？",
  "restoreRunningStatus": "正在从备份恢复…",
  "restoreLedgerProgress": "正在恢复账本 {done}/{total}…",
  "restoreResultMessage": "恢复完成：成功 {success} 个，失败 {failed} 个。",
  "backupAutoTitle": "定时备份",
  "backupAutoSubtitle": "每日在设定时间自动备份一次（仅 App 运行期间生效）",
  "backupTimeTitle": "每日备份时间",
  "lastBackupCaption": "最近备份：{date} · {ok}"
```

app_zh_TW.arb：

```json
  "backupCardTitle": "雲端備份",
  "backupNowTitle": "立即備份",
  "backupNowSubtitle": "將全部賬本與附件打包為一份當日備份，存入 piggycount-bak",
  "backupNoLedgers": "沒有可備份的賬本。",
  "backupRunningStatus": "正在建立備份…",
  "backupPackingProgress": "正在打包賬本 {done}/{total}…",
  "backupSuccessMessage": "備份已上傳：piggycount-bak/{fileName}",
  "backupFailedAuthMessage": "雲端認證失敗，請檢查雲服務設定後重試。",
  "backupFailedNetworkMessage": "備份失敗，請檢查網路後重試。",
  "restoreFromBackupTitle": "從備份還原",
  "restoreFromBackupSubtitle": "用選定的每日備份覆蓋本機資料（全部賬本與附件）",
  "backupListDialogTitle": "正在讀取備份列表…",
  "backupListEmptyMessage": "雲端還沒有備份。",
  "restoreConfirm1Message": "將使用 {date} 的備份覆蓋本機全部賬本資料（帳戶、分類、交易），比備份更新的本機變更將遺失。",
  "restoreConfirm2Message": "此操作無法復原，確定要繼續嗎？",
  "restoreRunningStatus": "正在從備份還原…",
  "restoreLedgerProgress": "正在還原賬本 {done}/{total}…",
  "restoreResultMessage": "還原完成：成功 {success} 個，失敗 {failed} 個。",
  "backupAutoTitle": "定時備份",
  "backupAutoSubtitle": "每日在設定時間自動備份一次（僅 App 執行期間生效）",
  "backupTimeTitle": "每日備份時間",
  "lastBackupCaption": "最近備份：{date} · {ok}"
```

app_ko.arb：

```json
  "backupCardTitle": "클라우드 백업",
  "backupNowTitle": "지금 백업",
  "backupNowSubtitle": "모든 장부와 첨부 파일을 당일 백업 하나로 묶어 piggycount-bak에 저장",
  "backupNoLedgers": "백업할 장부가 없습니다.",
  "backupRunningStatus": "백업 생성 중…",
  "backupPackingProgress": "장부打包 {done}/{total}…",
  "backupSuccessMessage": "백업 업로드 완료: piggycount-bak/{fileName}",
  "backupFailedAuthMessage": "클라우드 인증에 실패했습니다. 클라우드 서비스 설정을 확인하고 다시 시도하세요.",
  "backupFailedNetworkMessage": "백업에 실패했습니다. 네트워크를 확인하고 다시 시도하세요.",
  "restoreFromBackupTitle": "백업에서 복원",
  "restoreFromBackupSubtitle": "선택한 일일 백업으로 로컬 데이터를 덮어씁니다(모든 장부와 첨부 파일)",
  "backupListDialogTitle": "백업 목록 불러오는 중…",
  "backupListEmptyMessage": "클라우드에 아직 백업이 없습니다.",
  "restoreConfirm1Message": "{date} 백업으로 로컬의 모든 장부 데이터(계정, 카테고리, 거래)를 덮어씁니다. 백업 이후의 로컬 변경 사항은 사라집니다.",
  "restoreConfirm2Message": "이 작업은 되돌릴 수 없습니다. 계속하시겠습니까?",
  "restoreRunningStatus": "백업에서 복원 중…",
  "restoreLedgerProgress": "장부 복원 {done}/{total}…",
  "restoreResultMessage": "복원 완료: 성공 {success}개, 실패 {failed}개.",
  "backupAutoTitle": "예약 백업",
  "backupAutoSubtitle": "매일 설정한 시간에 자동 백업(앱 실행 중에만 동작)",
  "backupTimeTitle": "매일 백업 시간",
  "lastBackupCaption": "최근 백업: {date} · {ok}"
```

（ko 的 `backupPackingProgress` 打包一词用 "장부 압축 {done}/{total}…"）

- [ ] **Step 6.2: 重新生成本地化**

Run: `flutter gen-l10n`
Expected: 无错误；`lib/l10n/app_localizations.dart` 出现 `backupCardTitle` 等 getter

---

### Task 7: cloud_sync_page 备份卡片与处理函数

**Files:**
- Modify: `lib/pages/cloud/cloud_sync_page.dart`

- [ ] **Step 7.1: 新增 import 与忙碌标志**

顶部补：

```dart
import '../../cloud/backup/backup_scheduler.dart';
import '../../cloud/backup/cloud_backup_providers.dart';
import '../../cloud/backup/cloud_backup_service.dart';
```

（若页面已 import `flutter_cloud_sync`，复用其别名；否则补 `import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;`）

`_CloudSyncPageState` 字段区追加：

```dart
  bool backupBusy = false;
  bool restoreBusy = false;
```

- [ ] **Step 7.2: 新增处理函数**（放在 `_handleFullDownload` 之后）

```dart
  // ============ 云端备份（/prd/cloud_backup） ============

  /// 手动立即备份：阻塞进度弹窗；成败均记录当日状态（当日不再自动触发）
  Future<void> _handleBackupNow(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ledgers = await ref.read(repositoryProvider).getAllLedgers();
    if (!mounted || !context.mounted) return;
    if (ledgers.isEmpty) {
      await AppDialog.info(
          context, title: l10n.backupNowTitle, message: l10n.backupNoLedgers);
      return;
    }
    final backup = ref.read(cloudBackupServiceProvider);
    if (backup == null) {
      await AppDialog.error(
          context, title: l10n.commonFailed, message: l10n.fullSyncUnsupported);
      return;
    }

    setState(() => backupBusy = true);
    final block = showBlockingProgressDialog(
      context,
      title: l10n.backupNowTitle,
      initialStatus: l10n.backupRunningStatus,
    );
    Object? error;
    String? fileName;
    try {
      final result = await backup.createBackup(
        onLedgersProgress: (done, total) =>
            block.status.value = l10n.backupPackingProgress(done, total),
      );
      fileName = result.fileName;
    } catch (e) {
      error = e;
    } finally {
      // 先关阻塞弹窗再展示结果，避免 close 的 pop 误关顶层弹窗
      await block.close();
    }

    // 成败均写当日状态：当日不再自动触发（与定时备份同一规则）
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(
        'backup_last_date', BackupScheduler.formatDate(DateTime.now()));
    await prefs.setString('backup_last_result', error == null ? 'ok' : 'fail');

    if (mounted) {
      setState(() => backupBusy = false);
      ref.read(backupRefreshProvider.notifier).state++;
    }
    if (!mounted || !context.mounted) return;

    if (error != null) {
      // 认证失败与网络失败分开提示（对齐 startup_sync_checker 口径）
      if (error is fcs.CloudAuthException) {
        await AppDialog.error(
            context, title: l10n.commonFailed, message: l10n.backupFailedAuthMessage);
      } else {
        await AppDialog.error(
            context, title: l10n.commonFailed, message: l10n.backupFailedNetworkMessage);
      }
    } else {
      await AppDialog.info(context,
          title: l10n.backupNowTitle,
          message: l10n.backupSuccessMessage(fileName ?? ''));
    }
  }

  /// 从备份恢复（全量覆盖）：列表选择 → 双重 5 秒危险确认 → 阻塞恢复
  Future<void> _handleRestoreFromBackup(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final backup = ref.read(cloudBackupServiceProvider);
    if (backup == null) {
      await AppDialog.error(
          context, title: l10n.commonFailed, message: l10n.fullSyncUnsupported);
      return;
    }

    setState(() => restoreBusy = true);
    List<BackupFileInfo> backups;
    try {
      final block = showBlockingProgressDialog(
        context,
        title: l10n.restoreFromBackupTitle,
        initialStatus: l10n.backupListDialogTitle,
      );
      try {
        backups = await backup.listBackups();
      } finally {
        await block.close();
      }
    } catch (e) {
      if (mounted) setState(() => restoreBusy = false);
      if (context.mounted) {
        await AppDialog.error(context, title: l10n.commonFailed, message: '$e');
      }
      return;
    }
    if (!mounted || !context.mounted) return;

    if (backups.isEmpty) {
      setState(() => restoreBusy = false);
      await AppDialog.info(context,
          title: l10n.restoreFromBackupTitle,
          message: l10n.backupListEmptyMessage);
      return;
    }

    final picked = await _showBackupPicker(context, backups);
    if (picked == null || !mounted || !context.mounted) {
      if (mounted) setState(() => restoreBusy = false);
      return;
    }

    // 双重危险确认（各 5 秒倒计时）：明确告知覆盖本地数据、不可撤销
    final dateText = BackupScheduler.formatDate(picked.date);
    final first = await showDangerConfirmDialog(
      context,
      title: l10n.restoreFromBackupTitle,
      message: l10n.restoreConfirm1Message(dateText),
    );
    if (!first || !mounted || !context.mounted) {
      if (mounted) setState(() => restoreBusy = false);
      return;
    }
    final second = await showDangerConfirmDialog(
      context,
      title: l10n.restoreFromBackupTitle,
      message: l10n.restoreConfirm2Message,
    );
    if (!second || !mounted || !context.mounted) {
      if (mounted) setState(() => restoreBusy = false);
      return;
    }

    final block = showBlockingProgressDialog(
      context,
      title: l10n.restoreFromBackupTitle,
      initialStatus: l10n.restoreRunningStatus,
    );
    var success = 0;
    var failed = 0;
    Object? error;
    try {
      final result = await backup.restoreBackup(
        fileName: picked.fileName,
        onProgress: (done, total) =>
            block.status.value = l10n.restoreLedgerProgress(done, total),
      );
      success = result.success;
      failed = result.failed;
    } catch (e) {
      error = e;
    } finally {
      await block.close();
    }

    if (mounted) setState(() => restoreBusy = false);
    if (!mounted) return;

    // 恢复直接改写各账本数据：列表/统计/同步状态全部刷新（对齐全量下载）
    PostProcessor.runAfterDownload(ref);
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;

    if (!context.mounted) return;
    if (error != null) {
      await AppDialog.error(context, title: l10n.commonFailed, message: '$error');
    } else {
      await AppDialog.info(context,
          title: l10n.restoreFromBackupTitle,
          message: l10n.restoreResultMessage(success, failed));
    }
  }

  /// 备份选择列表（bottom sheet，按日期倒序）
  Future<BackupFileInfo?> _showBackupPicker(
      BuildContext context, List<BackupFileInfo> backups) {
    final l10n = AppLocalizations.of(context);
    return showModalBottomSheet<BackupFileInfo>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text(l10n.restoreFromBackupTitle,
                  style: Theme.of(ctx).textTheme.titleMedium),
            ),
            for (final b in backups)
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: Text(BackupScheduler.formatDate(b.date)),
                subtitle: b.size == null ? null : Text(_formatSize(b.size!)),
                onTap: () => Navigator.pop(ctx, b),
              ),
          ],
        ),
      ),
    );
  }

  static String _formatSize(int bytes) {
    if (bytes >= 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
    }
    if (bytes >= 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '$bytes B';
  }

  /// 定时备份时间选择
  Future<void> _pickBackupTime(BuildContext context, WidgetRef r) async {
    final cur = r.read(backupTimeProvider).asData?.value ??
        BackupScheduler.defaultBackupTime;
    final minutes = BackupScheduler.parseHhMm(cur);
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(hour: minutes ~/ 60, minute: minutes % 60),
    );
    if (picked == null) return;
    await r
        .read(backupTimeSetterProvider)
        .set(BackupScheduler.formatHhMm(picked.hour * 60 + picked.minute));
  }
```

- [ ] **Step 7.3: 插入备份卡片 UI**（全量同步卡片 `if (canUseCloud && !isPiggyCountCloud)` 的 `Padding` 之后、加密入口卡片之前）

```dart
                            // 云端备份卡片（仅路径 A，与全量同步卡片同口径）
                            if (canUseCloud && !isPiggyCountCloud)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SectionCard(
                                  margin: EdgeInsets.zero,
                                  child: Column(
                                    children: [
                                      AppListTile(
                                        leading: Icons.backup_outlined,
                                        title: AppLocalizations.of(context)
                                            .backupNowTitle,
                                        subtitle: AppLocalizations.of(context)
                                            .backupNowSubtitle,
                                        enabled: !uploadBusy &&
                                            !downloadBusy &&
                                            !fullUploadBusy &&
                                            !fullDownloadBusy &&
                                            !backupBusy &&
                                            !restoreBusy &&
                                            !isFirstLoad &&
                                            !refreshing,
                                        trailing: backupBusy
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2))
                                            : null,
                                        onTap: () =>
                                            _handleBackupNow(context),
                                      ),
                                      PiggyTokens.cardDivider(context),
                                      AppListTile(
                                        leading: Icons.restore,
                                        title: AppLocalizations.of(context)
                                            .restoreFromBackupTitle,
                                        subtitle: AppLocalizations.of(context)
                                            .restoreFromBackupSubtitle,
                                        enabled: !uploadBusy &&
                                            !downloadBusy &&
                                            !fullUploadBusy &&
                                            !fullDownloadBusy &&
                                            !backupBusy &&
                                            !restoreBusy &&
                                            !isFirstLoad &&
                                            !refreshing,
                                        trailing: restoreBusy
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child: CircularProgressIndicator(
                                                    strokeWidth: 2))
                                            : null,
                                        onTap: () =>
                                            _handleRestoreFromBackup(context),
                                      ),
                                      PiggyTokens.cardDivider(context),
                                      // 定时备份开关 + 时间 + 最近状态
                                      Consumer(builder: (ctx, r, _) {
                                        final auto = r.watch(
                                                backupAutoEnabledProvider)
                                                .asData
                                                ?.value ??
                                            false;
                                        final time = r
                                                .watch(backupTimeProvider)
                                                .asData
                                                ?.value ??
                                            BackupScheduler
                                                .defaultBackupTime;
                                        final last = r
                                            .watch(lastBackupInfoProvider)
                                            .asData
                                            ?.value;
                                        return Column(
                                          children: [
                                            PiggySwitchListTile(
                                              title: Text(
                                                  AppLocalizations.of(context)
                                                      .backupAutoTitle),
                                              subtitle: Text(
                                                  AppLocalizations.of(context)
                                                      .backupAutoSubtitle),
                                              value: auto,
                                              onChanged: (v) => r
                                                  .read(
                                                      backupAutoSetterProvider)
                                                  .set(v),
                                            ),
                                            if (auto) ...[
                                              PiggyTokens.cardDivider(
                                                  context),
                                              AppListTile(
                                                leading: Icons.schedule,
                                                title:
                                                    AppLocalizations.of(context)
                                                        .backupTimeTitle,
                                                subtitle: time,
                                                enabled: !backupBusy &&
                                                    !restoreBusy,
                                                onTap: () => _pickBackupTime(
                                                    context, r),
                                              ),
                                            ],
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      16, 8, 16, 12),
                                              child: Align(
                                                alignment:
                                                    Alignment.centerLeft,
                                                child: Text(
                                                  AppLocalizations.of(context)
                                                      .lastBackupCaption(
                                                    last?.date ?? '-',
                                                    (last?.ok ?? false)
                                                        ? AppLocalizations.of(
                                                                context)
                                                            .commonSuccess
                                                        : AppLocalizations.of(
                                                                context)
                                                            .commonFailed,
                                                  ),
                                                  style: Theme.of(context)
                                                      .textTheme
                                                      .bodySmall
                                                      ?.copyWith(
                                                          color: Theme.of(
                                                                  context)
                                                              .colorScheme
                                                              .onSurfaceVariant),
                                                ),
                                              ),
                                            ),
                                          ],
                                        );
                                      }),
                                    ],
                                  ),
                                ),
                              ),
```

同时给全量同步卡片两个 `AppListTile` 的 `enabled` 条件追加 `!backupBusy && !restoreBusy`（8 标志互斥）。

注：`commonSuccess` 若不存在，用现有通用「成功」文案 key 替换（查 arb 后确定，如 `fullUploadSuccessMessage` 不合适则新增 `backupStatusOk`/`backupStatusFail` 两个 key 并同步四语言）。

- [ ] **Step 7.4: 验证**

Run: `flutter analyze`
Expected: ≤ 基线（无未定义 getter/方法）
Run: `flutter test test/backup`
Expected: PASS

---

### Task 8: app.dart 挂载定时调度器

**Files:**
- Modify: `lib/app.dart`

- [ ] **Step 8.1: 挂载**

1. import 区补：

```dart
import 'package:shared_preferences/shared_preferences.dart';

import 'cloud/backup/backup_scheduler.dart';
import 'cloud/backup/cloud_backup_providers.dart';
```

（`SharedPreferences` 已 import 则跳过；logger 已可用）

2. State 字段追加：

```dart
  BackupScheduler? _backupScheduler;
```

3. `initState` 的 `addPostFrameCallback` 内、`_triggerStartupSyncCheck();` 之后追加：

```dart
      // 每日定时备份：1 分钟粒度检查，触发条件在闭包内判定
      _backupScheduler =
          BackupScheduler(onCheck: _runScheduledBackupCheck)..start();
```

4. 新增方法：

```dart
  /// 定时备份检查（BackupScheduler 每分钟调用）：
  /// 开关开启 && 到达设定时间 && 当日未触发 && 云服务就绪 → 后台非阻塞执行。
  /// 成败均写 backup_last_date（当日不重试，失败状态显示在卡片供手动补救）。
  /// 云服务未就绪（LocalOnly 等待期等）不写 last_date，下一分钟重查。
  Future<void> _runScheduledBackupCheck() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('backup_auto_enabled') ?? false)) return;
      final timeStr =
          prefs.getString('backup_time') ?? BackupScheduler.defaultBackupTime;
      final last = prefs.getString('backup_last_date');
      final now = DateTime.now();
      if (!BackupScheduler.shouldTriggerNow(
        enabled: true,
        scheduledMinutes: BackupScheduler.parseHhMm(timeStr),
        lastDate: last,
        now: now,
      )) {
        return;
      }

      final backup = ref.read(cloudBackupServiceProvider);
      if (backup == null) return; // 云未就绪：不计为当日已备

      try {
        await backup.createBackup();
        await prefs.setString('backup_last_result', 'ok');
        logger.info('Backup', '定时备份完成');
      } catch (e) {
        await prefs.setString('backup_last_result', 'fail');
        logger.warning('Backup', '定时备份失败: $e');
      }
      await prefs.setString(
          'backup_last_date', BackupScheduler.formatDate(now));
      if (mounted) {
        ref.read(backupRefreshProvider.notifier).state++;
      }
    } catch (e) {
      logger.warning('Backup', '定时备份检查异常: $e');
    }
  }
```

5. `dispose()` 内追加（若无 dispose 则新增）：

```dart
    _backupScheduler?.dispose();
    _backupScheduler = null;
```

- [ ] **Step 8.2: 验证**

Run: `flutter analyze`
Expected: ≤ 基线

---

### Task 9: 回归验证

- [ ] **Step 9.1: 全量测试**

Run: `flutter test`
Expected: 新增用例全 PASS；既有用例无回归（重点关注 startup_sync_checker / encryption / 同步相关）

- [ ] **Step 9.2: 分析基线对比**

Run: `flutter analyze`
Expected: 告警数 ≤ 执行前基线

- [ ] **Step 9.3: 手工冒烟（可选，需真机/模拟器）**

1. 配置 WebDAV → 云同步页出现「云端备份」卡片（PiggyCount Cloud 模式不出现）
2. 立即备份 → 阻塞进度 → 成功提示；WebDAV 端 `piggycount-bak/PiggyCount-当日.zip` 存在
3. 再点一次 → 同名文件被覆盖（云端仅一份）
4. 开启定时备份设 1 分钟后的时间（HH:mm）→ 等待触发 → 卡片「最近备份」更新
5. 从备份恢复 → 列表 → 两次 5 秒确认 → 恢复完成统计；账本/交易/附件回滚到备份时点

---

## 计划自查结论

- **需求覆盖**：FR-1→Task 7；FR-2/3/4→Task 2；FR-5→Task 7（阻塞弹窗）；FR-6→Task 4+8；FR-7→Task 7；FR-8→Task 1+2；FR-9→Task 6。US-1/2/3 验收标准均有对应任务。
- **类型一致性**：`CloudBackupService.createBackup/listBackups/restoreBackup`、`BackupScheduler.shouldTriggerNow/parseHhMm/formatHhMm/formatDate/defaultBackupTime`、providers 名称在 Task 2/4/5/7/8 间已交叉核对一致。
- **风险注记**：测试中 `TransactionAttachmentsCompanion.insert` 必填列、`ciphertextPrefix` 常量名、`commonSuccess` key 以实际代码为准（各任务内已标注核对方式）。
