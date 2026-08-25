import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../../data/encryption/ciphertext_format.dart';
import '../../data/repositories/base_repository.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../services/data_import_service.dart';
import '../../services/system/logger_service.dart';
import '../sync_restore_guard.dart';
import '../transactions_json.dart';
import 'backup_scheduler.dart';

/// 云端备份文件信息（listBackups 返回）
class BackupFileInfo {
  const BackupFileInfo({required this.fileName, required this.date, this.size});

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
/// [skippedRecurring] 恢复侧周期实例去重跳过数（REC-05：同规则同日且
/// syncId 或金额+备注相同才算真重复；>0 意味着有同日多笔交易未恢复，
/// UI 必须显式提示，不允许静默丢数）。
typedef RestoreOutcome = (
    {int success,
    int failed,
    int attachmentsRestored,
    int skippedRecurring,
    String fileName});

/// 云端全量备份服务（/prd/cloud_backup/design.md）
///
/// 备份产物：piggycount-bak/PiggyCount-yyyy-MM-dd.zip（本地时区，当日覆盖）。
/// ZIP 内部镜像云端同步目录（`ledger_<id>.json` + `attachments/<sha256>.bin`），
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
  /// `(syncManager).decoratedStorage`。
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

  /// ZIP 内账本条目名：`ledger_<id>.json`
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
          logger.warning('Backup', '附件本地文件缺失，跳过打包: sha256=${entry.key}');
        } else {
          final bytes = await File(srcPath).readAsBytes();
          archive.addFile(ArchiveFile(
              'attachments/${entry.key}.bin', bytes.length, bytes));
          attPacked++;
        }
        attDone++;
        onAttachmentsProgress?.call(attDone, filesBySha.length);
      }

      // 3. ZIP → 二进制上传（upsert 语义天然实现当日覆盖）。
      //    WebDAV/S3 走真字节路径（云端文件可直接用 ZIP 工具打开）；
      //    其余后端 base64 兜底；E2EE 由装饰器加密为与同步文件同格式密文。
      final zipData = ZipEncoder().encode(archive);
      if (zipData == null) {
        throw StateError('备份压缩失败');
      }
      final fileName = backupFileNameFor(DateTime.now());
      await storage.uploadBinaryOrFallback(
          path: '$backupDir/$fileName', bytes: zipData);

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
  ///
  /// 各后端 list 返回的 name 口径不一：WebDAV 是纯文件名，
  /// S3 等只剥 keyPrefix 不剥查询子目录 → 带 `piggycount-bak/` 前缀。
  /// 统一取 basename 归一化后再匹配，两类后端行为一致。
  Future<List<BackupFileInfo>> listBackups() async {
    final storage = await _requireStorage();
    final files = await storage.list(path: backupDir);
    logger.info('Backup',
        '备份目录原始列表: ${files.map((f) => f.name).toList()}');
    final result = <BackupFileInfo>[];
    for (final f in files) {
      final baseName = f.name.split('/').last;
      final m = _backupNamePattern.firstMatch(baseName);
      if (m == null) continue;
      final date = DateTime.tryParse(m.group(1)!);
      if (date == null) continue;
      result.add(BackupFileInfo(fileName: baseName, date: date, size: f.size));
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
    // W6：备份恢复属破坏性全量替换，进入 SyncRestoreGuard 恢复临界区，
    // 让定时备份（app.dart 每轮 tick 检查 isBusy）让位，避免半恢复态
    // DB 被打包上传覆盖当日好备份。begin/end 配对等价于 Guard.run。
    SyncRestoreGuard.begin();
    try {
      final storage = await _requireStorage();

      // 1. 下载原始字节 + 解包（任一失败整体报错，不动本地数据）。
      //    嗅探兼容两种历史格式：真 ZIP（新二进制路径 / 加密装饰器产物）
      //    与 base64 文本（旧版备份及未实现 BinaryCapableStorage 的后端）。
      final rawBytes = await storage.downloadBinaryOrFallback(
          path: '$backupDir/$fileName');
      if (rawBytes == null) {
        throw fcs.CloudSyncException('备份文件不存在: $fileName');
      }
      final Archive archive;
      try {
        archive = ZipDecoder().decodeBytes(_decodeBackupBytes(rawBytes));
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
      var skippedRecurring = 0;
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
            skippedRecurring += restored.skippedRecurring;
          } else {
            final imported = await _importNewLedgerFromBackup(
                remoteId: remoteId, jsonStr: jsonStr);
            if (imported == null) {
              throw fcs.CloudSyncException('备份账本导入失败: $name');
            }
            skippedRecurring += imported.skippedRecurring;
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
          '备份恢复完成: $fileName 成功=$success 失败=$failed 附件=$restoredAttachments 跳过recurring重复=$skippedRecurring');
      if (skippedRecurring > 0) {
        logger.warning('Backup',
            '恢复时有 $skippedRecurring 笔同日周期实例被判重跳过（同规则同日且syncId或金额+备注相同）。'
            '若源端存在同日多笔合法交易，请核对明细。');
      }
      return (
        success: success,
        failed: failed,
        attachmentsRestored: restoredAttachments,
        skippedRecurring: skippedRecurring,
        fileName: fileName
      );
    } finally {
      SyncRestoreGuard.end();
      _busy = false;
    }
  }

  /// 备份字节嗅探：ZIP 魔数（PK\x03\x04）直接采用；否则视为 base64 文本
  /// （历史版本 / 未实现二进制能力的后端产物）解码还原为 ZIP 字节。
  /// base64 是纯 ASCII，utf8.decode 不会失败；解码失败由调用方兜底报错。
  static List<int> _decodeBackupBytes(Uint8List raw) {
    const zipMagic = [0x50, 0x4B, 0x03, 0x04];
    if (raw.length >= 4) {
      var isZip = true;
      for (var i = 0; i < 4; i++) {
        if (raw[i] != zipMagic[i]) {
          isZip = false;
          break;
        }
      }
      if (isZip) return raw;
    }
    return base64Decode(utf8.decode(raw).trim());
  }

  /// 防御性内层密文处理：正常流程容器由装饰 storage 解密，内层恒为明文；
  /// 若遇到密文格式（如手工构造/异常产物）尝试用加密服务解密。
  /// 无加密服务可用时返回 null（该账本计入 failed）。
  Future<String?> _resolveInnerJson(String raw) async {
    if (!CiphertextFormat.isEncrypted(raw)) return raw;
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
  ///
  /// syncId 锚定：v9 快照携带 ledgerSyncId 时优先采用（与云端同步槽位
  /// 身份一致，恢复后 push/发现流程能认领同一账本）；旧快照缺失时生成
  /// UUID 兜底 —— 账本行没有 syncId 会退回数字 id 身份，跨设备撞号。
  Future<({int ledgerId, int skippedRecurring})?> _importNewLedgerFromBackup(
      {required int remoteId, required String jsonStr}) async {
    final json = jsonDecode(jsonStr) as Map<String, dynamic>;
    final name =
        (json['ledgerName'] as String?) ?? (json['name'] as String?) ?? 'Unknown';
    final currency = (json['currency'] as String?) ?? 'CNY';
    final snapshotSyncId = (json['ledgerSyncId'] as String?)?.trim();
    final effectiveSyncId = (snapshotSyncId != null && snapshotSyncId.isNotEmpty)
        ? snapshotSyncId
        : const Uuid().v4();

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
              syncId: drift.Value(effectiveSyncId),
            ));
      } else {
        ledgerId = await db.into(db.ledgers).insert(LedgersCompanion.insert(
            name: name,
            currency: drift.Value(currency),
            syncId: drift.Value(effectiveSyncId)));
      }
    }

    final importResult = await importTransactionsJson(repo, ledgerId, jsonStr,
        recordChanges: false);
    return (ledgerId: ledgerId, skippedRecurring: importResult.skippedRecurring);
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
        logger.warning('Backup',
            '附件 sha256 不匹配，跳过落盘: expect=$sha actual=$actual');
        continue;
      }
      await dest.writeAsBytes(bytes, flush: true);
      restored++;
    }
    return restored;
  }
}
