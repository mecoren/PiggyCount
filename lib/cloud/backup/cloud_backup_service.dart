import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as crypto;
import 'package:drift/drift.dart' as drift;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../data/db.dart';
import '../../data/encryption/ciphertext_format.dart';
import '../../data/repositories/base_repository.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../services/data_import_service.dart';
import '../../services/system/logger_service.dart';
import '../sync_metrics_service.dart';
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
    this.metrics,
    this.metricsBackend = 'unknown',
    Future<Directory> Function()? documentsDir,
  }) : _documentsDir = documentsDir ?? getApplicationDocumentsDirectory;

  final PiggyDatabase db;
  final BaseRepository repo;

  /// 解析装饰后 storage（E2EE 自动加解密）；生产环境传入
  /// `(syncManager).decoratedStorage`。
  final Future<fcs.CloudStorageService?> Function() storageResolver;

  /// 用于防御性解密 ZIP 内意外为密文的 ledger JSON（正常流程内层恒为明文）
  final EncryptionService? encryptionService;

  /// 同步成功率本地监控（审计 P0-1）。null 时埋点 no-op。
  /// 后端标识从 storageResolver 解析到的 provider 不易获取，由调用方
  /// 在记录时传入（见 [metricsBackend]）。
  final SyncMetricsService? metrics;

  /// 指标分组用的后端标识；未设置时记 'unknown'（不影响计数，仅分组）。
  final String metricsBackend;

  Future<Directory> Function() _documentsDir;

  /// P0-1：备份场景埋点（含 backend 分组）。备份恢复的软失败
  /// （单账本 failed>0 但整体流程完成）单独计 soft_fail。
  void _recordMetrics(SyncOpOutcome outcome,
      {Object? error, Duration? duration, SyncOpScenario? scenario}) {
    final m = metrics;
    if (m == null) return;
    m.recordUnawaited(SyncOpRecord(
      backend: metricsBackend,
      scenario: scenario ?? SyncOpScenario.cloudBackup,
      outcome: outcome,
      errorClass: error == null && outcome == SyncOpOutcome.success
          ? null
          : SyncMetricsService.classifyError(error),
      duration: duration,
    ));
  }

  /// 备份/恢复互斥锁：手动与定时共用，防止并发写云端/写本地
  bool _busy = false;

  /// P1-2（2026-09-11）：恢复中断检查点 key（SharedPreferences）。
  ///
  /// 进程在恢复中途崩溃时，[SyncRestoreGuard]（内存态）随进程消亡，
  /// 重启后 DB 处于半恢复状态且无任何痕迹 —— 若此时定时备份到窗，会把
  /// 半恢复 DB 打包上传**覆盖当日好备份**。本键跨进程持久化「恢复进行
  /// 中」状态：
  /// - 恢复成功/整体失败：清除（失败时本地数据未动，见 restoreBackup
  ///   注释 —— 下载/解包失败不动本地，逐账本软失败已是终态）；
  /// - 崩溃残留：下次进程启动时调度器检查本键，存在则当日自动备份
  ///   让位（手动备份不受限），并提示用户重跑恢复（恢复是覆盖语义，
  ///   幂等重跑即自愈）。
  static const String restorePendingKey = 'cloud_backup_restore_pending';

  /// 云端备份专用目录
  static const String backupDir = 'piggycount-bak';

  /// 合法备份文件名：PiggyCount-yyyy-MM-dd.zip
  static final RegExp _backupNamePattern =
      RegExp(r'^PiggyCount-(\d{4}-\d{2}-\d{2})\.zip$');

  /// 审计修复（附件原子落盘）：恢复写盘临时文件名的进程内自增序号
  static int _restoreWriteSeq = 0;

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
    // P0-1：备份计时
    final watch = Stopwatch()..start();
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
      _recordMetrics(SyncOpOutcome.success, duration: watch.elapsed);
      return (
        ledgers: ledgers.length,
        attachments: attPacked,
        fileName: fileName
      );
    } catch (e) {
      // P0-1：备份失败计入指标（不吞异常，原样上抛由调用方呈现）
      _recordMetrics(SyncOpOutcome.failed, error: e, duration: watch.elapsed);
      rethrow;
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
      // 审计修复（S3 前缀误命中）：S3 ListObjects 的 prefix 是文本前缀，
      // 'piggycount-bak' 会同时命中 'piggycount-bak-old/...' 等兄弟目录
      // 下的对象。仅接受「裸文件名（WebDAV readDir 口径）」或「恰好位于
      // backupDir 一级之下（S3 剥离 keyPrefix 后的相对路径）」的条目；
      // 其余带路径前缀的一律过滤，避免把兄弟目录的同名 zip 展示为可恢复
      // 备份、点恢复时才报「文件不存在」。
      var rel = f.name;
      while (rel.startsWith('/')) {
        rel = rel.substring(1);
      }
      if (rel.contains('/') && !rel.startsWith('$backupDir/')) continue;
      final baseName = rel.split('/').last;
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
    // P1-2：跨进程检查点先行落盘 —— 进程崩溃时 Guard（内存态）失效，
    // 但本键存活，重启后调度器据此让位（见 [restorePendingKey] 注释）。
    // 写失败不阻断恢复（键缺失的后果只是「崩溃后少一层防护」，
    // 不比现状更差）。
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(restorePendingKey, true);
    } catch (_) {}
    // P0-1：恢复计时
    final watch = Stopwatch()..start();
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

      // 2. 逐账本恢复。
      //    H2（audit）：认领优先级改为 syncId-first。ZIP 条目名携带的是
      //    **备份端本地数字 id**，跨设备恢复时两台设备自增序列独立 —— 旧
      //    逻辑按数字 id 命中即整本覆盖，会把备份内容盖到 B 设备恰好同号
      //    的**别的账本**上，而真正同源（syncId 相同、id 不同）的账本反而
      //    被当「备份独有」新建副本。现按三级认领：
      //      ① 快照带 ledgerSyncId 且本地存在同 syncId 行 → 覆盖该行；
      //      ② 数字 id 兜底：仅当命中行 syncId 为空、或与快照身份一致
      //         （排除「同号异账本」的身份冲突覆盖）；
      //      ③ 其余视为备份独有 → 导入新建（_importNewLedgerFromBackup，
      //         内部以快照 syncId 锚定新行身份）。
      final localRows = await db.select(db.ledgers).get();
      final localById = {for (final l in localRows) l.id: l};
      final localBySnapshotSyncId = <String, Ledger>{
        for (final l in localRows)
          if (l.syncId != null && l.syncId!.isNotEmpty) l.syncId!: l,
      };
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
          final snapshot = jsonDecode(jsonStr) as Map<String, dynamic>;
          final snapshotSyncId =
              ((snapshot['ledgerSyncId'] as String?) ?? '').trim();

          Ledger? target;
          if (snapshotSyncId.isNotEmpty &&
              localBySnapshotSyncId.containsKey(snapshotSyncId)) {
            target = localBySnapshotSyncId[snapshotSyncId]; // ① 同源认领
          } else if (localById.containsKey(remoteId)) {
            final candidate = localById[remoteId]!;
            final candidateSync = (candidate.syncId ?? '').trim();
            if (candidateSync.isEmpty || candidateSync == snapshotSyncId) {
              target = candidate; // ② 无身份冲突的数字兜底
            }
          }

          if (target != null) {
            final restored = await restoreLedgerFromJson(
                db: db, repo: repo, ledgerId: target.id, jsonStr: jsonStr);
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
      // P0-1/P1-3：恢复整体流程完成但存在单账本失败 → soft_fail
      //（部分数据未收敛但非整体故障）；全成功 → success。
      _recordMetrics(
          failed > 0 ? SyncOpOutcome.softFail : SyncOpOutcome.success,
          error: failed > 0
              ? fcs.CloudStorageException('备份恢复单账本失败 $failed 个')
              : null,
          scenario: SyncOpScenario.snapshotRestore,
          duration: watch.elapsed);
      return (
        success: success,
        failed: failed,
        attachmentsRestored: restoredAttachments,
        skippedRecurring: skippedRecurring,
        fileName: fileName
      );
    } catch (e) {
      // P0-1：恢复整体失败（下载/解包失败，本地数据未动）
      _recordMetrics(SyncOpOutcome.failed,
          error: e,
          scenario: SyncOpScenario.snapshotRestore,
          duration: watch.elapsed);
      rethrow;
    } finally {
      SyncRestoreGuard.end();
      _busy = false;
      // P1-2：清除跨进程检查点。恢复走到 finally 说明流程有终态：
      // - 整体异常：下载/解包失败，本地数据未动；
      // - 正常完成：逐账本软失败已计入 failed 返回值（重跑恢复幂等，
      //   用户可按需再来一次）。
      // 两种都不是「进程崩溃残留的半恢复态」，清除让调度器恢复正常。
      // 清除失败保留键 —— 下次调度让位是保守方向，可接受。
      try {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setBool(restorePendingKey, false);
      } catch (_) {}
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

    // 审计 S12 同款口径：本地可能存在多个同名账本（legacy 数据/历史导入），
    // getSingleOrNull 会抛 "Too many elements" 直接崩掉整个备份恢复流程。
    // 取第一行复用，与 downloadRemoteLedger 的修复保持一致。
    final sameNameRows = await (db.select(db.ledgers)
          ..where((t) => t.name.equals(name)))
        .get();
    if (sameNameRows.length > 1) {
      logger.warning('Backup',
          '本地存在 ${sameNameRows.length} 个同名账本「$name」，复用第一行 (id=${sameNameRows.first.id})');
    }
    final existingByName = sameNameRows.isEmpty ? null : sameNameRows.first;

    final int ledgerId;
    if (existingByName != null) {
      ledgerId = existingByName.id;
      // H2 配套：被复用行尚无 syncId 时补锚快照身份 —— 此后云端同步槽位
      // （ledger_<syncId>.json）与发现流程才能认领同一账本。已有身份
      // （含与快照不同源）一律不覆盖。
      if ((existingByName.syncId ?? '').trim().isEmpty &&
          effectiveSyncId.isNotEmpty) {
        await (db.update(db.ledgers)..where((t) => t.id.equals(ledgerId)))
            .write(LedgersCompanion(syncId: drift.Value(effectiveSyncId)));
      }
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
      // 审计修复（原子落盘）：先写临时文件再 rename，进程中途被杀不会
      // 留下截断半截文件冒充已恢复的附件（与 drainAttachmentJobs 同口径）
      final tempPath =
          '${dest.path}.tmp.${DateTime.now().microsecondsSinceEpoch}_${_restoreWriteSeq++}';
      final tempFile = File(tempPath);
      try {
        await tempFile.writeAsBytes(bytes, flush: true);
        await tempFile.rename(dest.path);
      } catch (_) {
        try {
          if (await tempFile.exists()) await tempFile.delete();
        } catch (_) {}
        rethrow;
      }
      restored++;
    }
    return restored;
  }
}
