import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;

import '../../providers.dart';
import '../../providers/encryption_providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../services/billing/post_processor.dart';
import '../../cloud/sync_service.dart';
import '../../cloud/transactions_sync_manager.dart';
import '../../cloud/backup/backup_scheduler.dart';
import '../../cloud/backup/cloud_backup_providers.dart';
import '../../cloud/backup/cloud_backup_service.dart';
import '../../domain/encryption/encryption_service.dart';
import '../auth/login_page.dart';
import 'encryption_dialogs.dart';
import 'encryption_settings_page.dart';
import 'sync_preview_dialog.dart';

/// 云同步与备份二级页面 - 包含所有同步操作
class CloudSyncPage extends ConsumerStatefulWidget {
  const CloudSyncPage({super.key});

  @override
  ConsumerState<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends ConsumerState<CloudSyncPage> {
  bool uploadBusy = false;
  bool downloadBusy = false;
  bool fullUploadBusy = false;
  bool fullDownloadBusy = false;
  bool backupBusy = false;
  bool restoreBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;

      // 仅在多设备同步开关开启时，清除状态缓存并强制刷新
      final prefs = await SharedPreferences.getInstance();
      final multiDevice = prefs.getBool('multi_device_sync') ?? false;
      if (!multiDevice || !mounted) return;
      final sync = ref.read(syncServiceProvider);
      final ledgerId = ref.read(currentLedgerIdProvider);
      sync.clearStatusCache(ledgerId: ledgerId);
      ref.read(syncStatusRefreshProvider.notifier).state++;
    });
  }

  Future<void> _onRefresh() async {
    final sync = ref.read(syncServiceProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    sync.clearStatusCache(ledgerId: ledgerId);
    ref.read(syncStatusRefreshProvider.notifier).state++;
    // 等待状态刷新完成
    await ref.read(syncStatusProvider(ledgerId).future);
  }

  /// 加密恢复：弹密码对话框 + 从云端重提取 salt 激活密钥
  ///
  /// 处理两类加密哨兵，均走 [promptPasswordAndActivate]（弹密码 → enableFromCloud
  /// → 重建装饰器）恢复：
  /// - 'salt_mismatch_need_password'：已开启加密但密钥 salt 与云端密文不匹配
  /// - 'cloud_encrypted_locally_disabled'：从未开启加密/reset 后无密钥，云端为密文
  ///   （BUG-2 残留修复）
  ///
  /// 激活成功后清除状态缓存并刷新，让 UI 反映新的同步状态。
  /// 激活失败（取消/密码错误）则不做任何操作。
  Future<void> _handleEncryptionRecovery({
    required int ledgerId,
  }) async {
    final encryptionService = ref.read(encryptionServiceProvider);
    // promptPasswordAndActivate 内部从 provider 解析最新同步管理器，
    // 避免使用本页 build 时捕获的旧实例（用户可能刚改过 WebDAV 凭据）
    final result = await promptPasswordAndActivate(
      context,
      ref,
      service: encryptionService,
    );
    if (result != SaltMismatchRecoveryResult.activated || !mounted) return;
    // 激活成功：对当前管理器清除缓存并刷新状态（相当于重试一次 getStatus）
    final syncNow = ref.read(syncServiceProvider);
    if (syncNow is TransactionsSyncManager) {
      syncNow.clearStatusCache(ledgerId: ledgerId);
    }
    ref.read(syncStatusRefreshProvider.notifier).state++;
  }

  /// 全量上传：以本地所有账本覆盖云端同名账本（云端独有账本保留）。
  ///
  /// 流程与现有上传按钮一致（串行 uploadCurrentLedger、单个失败不中断），
  /// 区别是入口为危险操作：双重强制确认（各 5 秒倒计时）后才执行。
  Future<void> _handleFullUpload(BuildContext context, SyncService sync) async {
    final l10n = AppLocalizations.of(context);
    final ledgers = await ref.read(repositoryProvider).getAllLedgers();
    if (!mounted || !context.mounted) return;
    if (ledgers.isEmpty) {
      await AppDialog.info(context,
          title: l10n.fullUploadTitle, message: l10n.fullUploadNoLedgers);
      return;
    }

    // 两次强制确认：第一次说明覆盖范围，第二次强调不可恢复
    final first = await showDangerConfirmDialog(
      context,
      title: l10n.fullUploadTitle,
      message: l10n.fullUploadConfirm1Message(ledgers.length),
    );
    if (!first || !mounted || !context.mounted) return;
    final second = await showDangerConfirmDialog(
      context,
      title: l10n.fullUploadTitle,
      message: l10n.fullUploadConfirm2Message,
    );
    if (!second || !mounted || !context.mounted) return;

    setState(() => fullUploadBusy = true);
    // 标记全部账本为上传中，供账本卡片显示上传状态（模式同现有上传）
    final uploadingIds = ref.read(uploadingLedgerIdsProvider);
    ref.read(uploadingLedgerIdsProvider.notifier).state = {
      ...uploadingIds,
      ...ledgers.map((l) => l.id),
    };

    final block = showBlockingProgressDialog(
      context,
      title: l10n.fullUploadTitle,
      initialStatus: l10n.fullUploadBlockingStatus,
    );
    var success = 0;
    var failed = 0;
    Object? error;
    try {
      // 串行逐账本上传：单个失败不中断整批（语义对齐现有上传按钮）
      for (final ledger in ledgers) {
        try {
          await sync.uploadCurrentLedger(ledgerId: ledger.id);
          success++;
        } catch (e) {
          failed++;
        }
        block.status.value =
            l10n.ledgersUploadingProgress(success + failed, ledgers.length);
      }
    } catch (e) {
      error = e;
    } finally {
      // 先关阻塞弹窗再展示结果，避免 close 的 pop 误关顶层弹窗
      await block.close();
    }

    // 成败都要清理：解除上传中标记与忙碌状态
    final ids = ref.read(uploadingLedgerIdsProvider);
    ref.read(uploadingLedgerIdsProvider.notifier).state =
        ids.where((id) => !ledgers.any((l) => l.id == id)).toSet();
    if (mounted) setState(() => fullUploadBusy = false);
    if (!mounted) return;

    // 刷新账本列表与全部账本同步状态
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;

    if (!context.mounted) return;
    if (error != null) {
      await AppDialog.error(context,
          title: l10n.commonFailed, message: '$error');
    } else {
      await AppDialog.info(
        context,
        title: l10n.fullUploadTitle,
        message: failed == 0
            ? l10n.fullUploadSuccessMessage
            : l10n.ledgersUploadAllResult(success, failed),
      );
    }
  }

  /// 全量下载：以云端所有账本覆盖本地（本地独有账本保留）。
  ///
  /// 双重危险确认后走 fullRestoreAllRemoteLedgers：
  /// 已存在账本整体覆盖（downloadAndRestoreToCurrentLedger）、
  /// 云端独有账本导入新建（downloadRemoteLedger）。
  Future<void> _handleFullDownload(
      BuildContext context, SyncService sync) async {
    final l10n = AppLocalizations.of(context);
    if (sync is! TransactionsSyncManager) {
      await AppDialog.error(context,
          title: l10n.commonFailed, message: l10n.fullSyncUnsupported);
      return;
    }

    // 两次强制确认：第一次说明覆盖范围，第二次强调不可恢复
    final first = await showDangerConfirmDialog(
      context,
      title: l10n.fullDownloadTitle,
      message: l10n.fullDownloadConfirm1Message,
    );
    if (!first || !mounted || !context.mounted) return;
    final second = await showDangerConfirmDialog(
      context,
      title: l10n.fullDownloadTitle,
      message: l10n.fullDownloadConfirm2Message,
    );
    if (!second || !mounted || !context.mounted) return;

    setState(() => fullDownloadBusy = true);
    final block = showBlockingProgressDialog(
      context,
      title: l10n.fullDownloadTitle,
      initialStatus: l10n.fullDownloadBlockingStatus,
    );
    var success = 0;
    var failed = 0;
    Object? error;
    try {
      final result = await sync.fullRestoreAllRemoteLedgers(
        onProgress: (done, total) =>
            block.status.value = l10n.syncBlockingDownloadLedger(done, total),
      );
      success = result.success;
      failed = result.failed;
    } catch (e) {
      error = e;
    } finally {
      await block.close();
    }

    if (mounted) setState(() => fullDownloadBusy = false);
    if (!mounted) return;

    // 全量下载直接改写各账本数据：列表/统计/同步状态全部刷新
    PostProcessor.runAfterDownload(ref);
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;

    if (!context.mounted) return;
    if (error != null) {
      await AppDialog.error(context,
          title: l10n.commonFailed, message: '$error');
    } else {
      await AppDialog.info(
        context,
        title: l10n.fullDownloadTitle,
        message: l10n.fullDownloadResult(success, failed),
      );
    }
  }

  // ============ 云端备份（/prd/cloud_backup） ============

  /// 手动立即备份：阻塞进度弹窗；成败均记录当日状态（当日不再自动触发）
  Future<void> _handleBackupNow(BuildContext context) async {
    final l10n = AppLocalizations.of(context);
    final ledgers = await ref.read(repositoryProvider).getAllLedgers();
    if (!mounted || !context.mounted) return;
    if (ledgers.isEmpty) {
      await AppDialog.info(context,
          title: l10n.backupNowTitle, message: l10n.backupNoLedgers);
      return;
    }
    final backup = ref.read(cloudBackupServiceProvider);
    if (backup == null) {
      await AppDialog.error(context,
          title: l10n.commonFailed, message: l10n.fullSyncUnsupported);
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
      if (error is CloudAuthException) {
        await AppDialog.error(context,
            title: l10n.commonFailed, message: l10n.backupFailedAuthMessage);
      } else {
        await AppDialog.error(context,
            title: l10n.commonFailed, message: l10n.backupFailedNetworkMessage);
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
      await AppDialog.error(context,
          title: l10n.commonFailed, message: l10n.fullSyncUnsupported);
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
      await AppDialog.error(context,
          title: l10n.commonFailed, message: '$error');
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

  @override
  Widget build(BuildContext context) {
    final authAsync = ref.watch(authServiceProvider);
    final sync = ref.watch(syncServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);

    if (ledgerId == 0) {
      return Scaffold(
        backgroundColor: PiggyTokens.scaffoldBackground(context),
        extendBodyBehindAppBar: true,
        appBar: PiggyTitleBar(
          title: AppLocalizations.of(context).cloudSyncPageTitle,
          subtitle: AppLocalizations.of(context).cloudSyncPageSubtitle,
          showBack: true,
          topPadding: 8,
        ),
        body: Padding(
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 80,
          ),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Text(
                    AppLocalizations.of(context).aiOcrNoLedger,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: PiggyTokens.textSecondary(context),
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context).cloudSyncPageTitle,
        subtitle: AppLocalizations.of(context).cloudSyncPageSubtitle,
        showBack: true,
        topPadding: 8,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 80,
        ),
        child: Column(
          children: [
            Expanded(
              child: authAsync.when(
                loading: () => DelayedSkeleton(
                  placeholder: const SizedBox.expand(),
                  child: PulseSkeleton(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        children: const [
                          SkeletonListTile(),
                          SkeletonListTile(),
                          SkeletonListTile(),
                        ],
                      ),
                    ),
                  ),
                ),
                error: (e, _) => Center(
                  child:
                      Text('${AppLocalizations.of(context).commonError}: $e'),
                ),
                data: (auth) => FutureBuilder<CloudUser?>(
                  future: auth.currentUser,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return DelayedSkeleton(
                        placeholder: const SizedBox.expand(),
                        child: PulseSkeleton(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              children: const [
                                SkeletonListTile(),
                                SkeletonListTile(),
                                SkeletonListTile(),
                              ],
                            ),
                          ),
                        ),
                      );
                    }

                    final user = snap.data;
                    final cloudConfig = ref.watch(activeCloudConfigProvider);
                    final isLocalMode = cloudConfig.hasValue &&
                        cloudConfig.value!.type == CloudBackendType.local;
                    final isPiggyCountCloud = cloudConfig.hasValue &&
                        cloudConfig.value!.type ==
                            CloudBackendType.piggycountCloud;
                    final needsLogin = cloudConfig.hasValue &&
                        (cloudConfig.value!.type == CloudBackendType.supabase ||
                            cloudConfig.value!.type ==
                                CloudBackendType.piggycountCloud);
                    // Supabase 和 PiggyCount Cloud 需要登录，其他云服务（iCloud/S3/WebDAV）使用配置文件认证
                    final canUseCloud =
                        !isLocalMode && (!needsLogin || user != null);

                    final asyncSt = ref.watch(syncStatusProvider(ledgerId));
                    final cached = ref.watch(lastSyncStatusProvider(ledgerId));
                    final st = asyncSt.asData?.value ?? cached;

                    final isFirstLoad = st == null;
                    final refreshing = asyncSt.isLoading;
                    bool inSync = false;
                    bool notLoggedIn = false;

                    // 计算同步状态显示
                    String subtitle = '';
                    IconData icon = Icons.sync_outlined;

                    // 刷新期间不回退显示缓存的旧状态（可能是过时的
                    // "已同步"），改显"同步中"，避免与启动检查的
                    // "云端有更新"提示互相矛盾
                    if (refreshing) {
                      subtitle = AppLocalizations.of(context).mineSyncChecking;
                    } else if (!isFirstLoad) {
                      switch (st.diff) {
                        case SyncDiff.notLoggedIn:
                          subtitle =
                              AppLocalizations.of(context).mineSyncNotLoggedIn;
                          icon = Icons.lock_outline;
                          notLoggedIn = true;
                          break;
                        case SyncDiff.notConfigured:
                          subtitle = AppLocalizations.of(context)
                              .mineSyncNotConfigured;
                          icon = Icons.cloud_off_outlined;
                          break;
                        case SyncDiff.noRemote:
                          subtitle =
                              AppLocalizations.of(context).mineSyncNoRemote;
                          icon = Icons.cloud_queue_outlined;
                          break;
                        case SyncDiff.inSync:
                          subtitle = AppLocalizations.of(context)
                              .mineSyncInSync(st.localCount);
                          icon = Icons.verified_outlined;
                          inSync = true;
                          break;
                        case SyncDiff.localNewer:
                          subtitle = AppLocalizations.of(context)
                              .mineSyncLocalNewer(st.localCount);
                          icon = Icons.upload_outlined;
                          break;
                        case SyncDiff.cloudNewer:
                          subtitle =
                              AppLocalizations.of(context).mineSyncCloudNewer;
                          icon = Icons.download_outlined;
                          break;
                        case SyncDiff.different:
                          subtitle =
                              AppLocalizations.of(context).mineSyncDifferent;
                          icon = Icons.change_circle_outlined;
                          break;
                        case SyncDiff.error:
                          String? localizedMessage;
                          if (st.message != null) {
                            switch (st.message!) {
                              case '__SYNC_NOT_CONFIGURED__':
                                localizedMessage = AppLocalizations.of(context)
                                    .syncNotConfiguredMessage;
                                break;
                              case '__SYNC_NOT_LOGGED_IN__':
                                localizedMessage = AppLocalizations.of(context)
                                    .syncNotLoggedInMessage;
                                break;
                              case '__SYNC_CLOUD_BACKUP_CORRUPTED__':
                                localizedMessage = AppLocalizations.of(context)
                                    .syncCloudBackupCorruptedMessage;
                                break;
                              case '__SYNC_NO_CLOUD_BACKUP__':
                                localizedMessage = AppLocalizations.of(context)
                                    .syncNoCloudBackupMessage;
                                break;
                              case '__SYNC_ACCESS_DENIED__':
                                localizedMessage = AppLocalizations.of(context)
                                    .syncAccessDeniedMessage;
                                break;
                              case 'salt_mismatch_need_password':
                                localizedMessage = AppLocalizations.of(context)
                                    .saltMismatchNeedPasswordHint;
                                break;
                              case 'cloud_encrypted_locally_disabled':
                                localizedMessage = AppLocalizations.of(context)
                                    .cloudEncryptedLocallyDisabledHint;
                                break;
                              default:
                                localizedMessage = st.message;
                            }
                          }
                          subtitle = localizedMessage ??
                              AppLocalizations.of(context).mineSyncError;
                          icon = Icons.error_outline;
                          break;
                      }
                    }

                    return RefreshIndicator(
                        onRefresh: _onRefresh,
                        child: ListView(
                          padding: const EdgeInsets.all(16),
                          children: [
                            // 提示文案（仅非 PiggyCount Cloud 模式显示）
                            if (!isPiggyCountCloud)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: Text(
                                  AppLocalizations.of(context).cloudSyncHint,
                                  style: PiggyTextTokens.label(context)
                                      .copyWith(
                                          color: PiggyTokens.textTertiary(
                                              context)),
                                ),
                              ),
                            // 同步操作 Section
                            SectionCard(
                              margin: EdgeInsets.zero,
                              borderColor: ref.watch(primaryColorProvider),
                              child: Column(
                                children: [
                                  // 同步状态
                                  AppListTile(
                                    leading: icon,
                                    title: AppLocalizations.of(context)
                                        .mineSyncTitle,
                                    subtitle: isFirstLoad ? null : subtitle,
                                    enabled: canUseCloud &&
                                        !isFirstLoad &&
                                        !refreshing &&
                                        !uploadBusy &&
                                        !downloadBusy &&
                                        !fullUploadBusy &&
                                        !fullDownloadBusy,
                                    trailing: (canUseCloud &&
                                            (isFirstLoad ||
                                                refreshing ||
                                                uploadBusy ||
                                                downloadBusy))
                                        ? const SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                                strokeWidth: 2))
                                        : null,
                                    onTap: (isFirstLoad ||
                                            !canUseCloud ||
                                            refreshing ||
                                            uploadBusy ||
                                            downloadBusy)
                                        ? null
                                        : () async {
                                            if (!context.mounted) return;
                                            // 加密哨兵：触发密码重输/开启加密流程而非显示详情
                                            // - salt_mismatch_need_password：已开启加密但 salt 不匹配
                                            // - cloud_encrypted_locally_disabled：从未开启加密/reset 后无密钥（BUG-2）
                                            if (st.message ==
                                                    'salt_mismatch_need_password' ||
                                                st.message ==
                                                    'cloud_encrypted_locally_disabled') {
                                              await _handleEncryptionRecovery(
                                                ledgerId: ledgerId,
                                              );
                                              return;
                                            }
                                            final lines = <String>[
                                              AppLocalizations.of(context)
                                                  .mineSyncLocalRecords(
                                                      st.localCount),
                                              if (st.cloudCount != null)
                                                AppLocalizations.of(context)
                                                    .mineSyncCloudRecords(
                                                        st.cloudCount!),
                                              if (st.cloudExportedAt != null)
                                                AppLocalizations.of(context)
                                                    .mineSyncCloudLatest(DateFormat(
                                                            'yyyy-MM-dd HH:mm:ss')
                                                        .format(st
                                                            .cloudExportedAt!
                                                            .toLocal())),
                                              AppLocalizations.of(context)
                                                  .mineSyncLocalFingerprint(
                                                      st.localFingerprint),
                                              if (st.cloudFingerprint != null)
                                                AppLocalizations.of(context)
                                                    .mineSyncCloudFingerprint(
                                                        st.cloudFingerprint!),
                                              if (st.message != null)
                                                () {
                                                  String localizedMessage =
                                                      st.message!;
                                                  switch (st.message!) {
                                                    case '__SYNC_NOT_CONFIGURED__':
                                                      localizedMessage =
                                                          AppLocalizations.of(
                                                                  context)
                                                              .syncNotConfiguredMessage;
                                                      break;
                                                    case '__SYNC_NOT_LOGGED_IN__':
                                                      localizedMessage =
                                                          AppLocalizations.of(
                                                                  context)
                                                              .syncNotLoggedInMessage;
                                                      break;
                                                    case '__SYNC_CLOUD_BACKUP_CORRUPTED__':
                                                      localizedMessage =
                                                          AppLocalizations.of(
                                                                  context)
                                                              .syncCloudBackupCorruptedMessage;
                                                      break;
                                                    case '__SYNC_NO_CLOUD_BACKUP__':
                                                      localizedMessage =
                                                          AppLocalizations.of(
                                                                  context)
                                                              .syncNoCloudBackupMessage;
                                                      break;
                                                    case '__SYNC_ACCESS_DENIED__':
                                                      localizedMessage =
                                                          AppLocalizations.of(
                                                                  context)
                                                              .syncAccessDeniedMessage;
                                                      break;
                                                  }
                                                  return AppLocalizations.of(
                                                          context)
                                                      .mineSyncMessage(
                                                          localizedMessage);
                                                }(),
                                            ];
                                            await AppDialog.info(context,
                                                title:
                                                    AppLocalizations.of(context)
                                                        .mineSyncDetailTitle,
                                                message: lines.join('\n'));
                                          },
                                  ),
                                  // ===== PiggyCount Cloud 模式：同步状态 + 登录（无需手动操作） =====
                                  if (isPiggyCountCloud) ...[
                                    // 登录（未登录时显示登录入口）
                                    Consumer(builder: (ctx, r, _) {
                                      final userNow = user;
                                      final cfg = r
                                          .watch(activeCloudConfigProvider)
                                          .valueOrNull;
                                      final cachedEmail =
                                          cfg?.piggycountCloudEmail ?? '';
                                      final cachedPassword =
                                          cfg?.piggycountCloudPassword ?? '';
                                      final hasCachedCredentials =
                                          cachedEmail.isNotEmpty &&
                                              cachedPassword.isNotEmpty;
                                      if (userNow != null) {
                                        // 已登录：仅显示账号信息，不提供退出
                                        return Column(
                                          children: [
                                            PiggyTokens.cardDivider(context),
                                            AppListTile(
                                              leading:
                                                  Icons.verified_user_outlined,
                                              title: userNow.email ??
                                                  AppLocalizations.of(context)
                                                      .mineLoggedInEmail,
                                            ),
                                          ],
                                        );
                                      }
                                      // 未登录：如果 config 里有保存的邮密,直接给"重新登录"
                                      // 按钮,不需要跳登录页;否则才显示老的跳登录页入口。
                                      if (hasCachedCredentials) {
                                        return Column(
                                          children: [
                                            PiggyTokens.cardDivider(context),
                                            AppListTile(
                                              leading: Icons.refresh,
                                              title:
                                                  AppLocalizations.of(context)
                                                      .cloudReloginTitle,
                                              subtitle: cachedEmail,
                                              onTap: () async {
                                                final providerAsync = ref.read(
                                                    piggycountCloudProviderInstance);
                                                final provider =
                                                    providerAsync.valueOrNull;
                                                if (provider == null) {
                                                  showToast(
                                                      context,
                                                      AppLocalizations.of(
                                                              context)
                                                          .cloudReloginFailed);
                                                  return;
                                                }
                                                try {
                                                  await provider.auth
                                                      .signInWithEmail(
                                                    email: cachedEmail,
                                                    password: cachedPassword,
                                                  );
                                                  if (!context.mounted) return;
                                                  showToast(
                                                      context,
                                                      AppLocalizations.of(
                                                              context)
                                                          .cloudReloginSuccess);
                                                  ref
                                                      .read(
                                                          syncStatusRefreshProvider
                                                              .notifier)
                                                      .state++;
                                                  ref
                                                      .read(statsRefreshProvider
                                                          .notifier)
                                                      .state++;
                                                } catch (e) {
                                                  if (!context.mounted) return;
                                                  showToast(context,
                                                      '${AppLocalizations.of(context).cloudReloginFailed}: $e');
                                                }
                                              },
                                            ),
                                          ],
                                        );
                                      }
                                      // 没凭证时,走原来的登录页
                                      return Column(
                                        children: [
                                          PiggyTokens.cardDivider(context),
                                          AppListTile(
                                            leading: Icons.login,
                                            title: AppLocalizations.of(context)
                                                .mineLoginTitle,
                                            subtitle:
                                                AppLocalizations.of(context)
                                                    .mineLoginSubtitle,
                                            onTap: () async {
                                              await Navigator.of(context).push(
                                                  MaterialPageRoute(
                                                      builder: (_) =>
                                                          const LoginPage()));
                                              if (!mounted) return;
                                              ref
                                                  .read(
                                                      syncStatusRefreshProvider
                                                          .notifier)
                                                  .state++;
                                              ref
                                                  .read(statsRefreshProvider
                                                      .notifier)
                                                  .state++;
                                            },
                                          ),
                                        ],
                                      );
                                    }),
                                  ],
                                  // ===== 其他 Provider 模式：上传/下载按钮 =====
                                  if (!isPiggyCountCloud) ...[
                                    PiggyTokens.cardDivider(context),
                                    // 上传
                                    AppListTile(
                                      leading: Icons.cloud_upload_outlined,
                                      title: AppLocalizations.of(context)
                                          .mineUploadTitle,
                                      subtitle: isFirstLoad
                                          ? null
                                          : !canUseCloud
                                              ? AppLocalizations.of(context)
                                                  .mineUploadNeedCloudService
                                              : notLoggedIn
                                                  ? AppLocalizations.of(context)
                                                      .mineUploadNeedLogin
                                                  : uploadBusy
                                                      ? AppLocalizations.of(
                                                              context)
                                                          .mineUploadInProgress
                                                      : (refreshing
                                                          ? AppLocalizations.of(
                                                                  context)
                                                              .mineUploadRefreshing
                                                          : (inSync
                                                              ? AppLocalizations
                                                                      .of(context)
                                                                  .mineUploadSynced
                                                              : null)),
                                      enabled: canUseCloud &&
                                          !inSync &&
                                          !notLoggedIn &&
                                          !uploadBusy &&
                                          !downloadBusy &&
                                          !fullUploadBusy &&
                                          !fullDownloadBusy &&
                                          !isFirstLoad &&
                                          !refreshing,
                                      trailing: (uploadBusy ||
                                              refreshing ||
                                              (isFirstLoad && canUseCloud))
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2))
                                          : null,
                                      onTap: () async {
                                        setState(() => uploadBusy = true);
                                        final l10n =
                                            AppLocalizations.of(context);

                                        // 全量上传语义：上传所有本地账本，
                                        // 而非仅当前账本（首次同步需把全部
                                        // 数据推上云，与帮助文案承诺一致）
                                        final ledgers = await ref
                                            .read(repositoryProvider)
                                            .getAllLedgers();
                                        if (!context.mounted) return;
                                        final uploadingIds = ref
                                            .read(uploadingLedgerIdsProvider);
                                        // 标记全部账本为上传中，
                                        // 供账本卡片显示上传状态
                                        ref
                                            .read(uploadingLedgerIdsProvider
                                                .notifier)
                                            .state = {
                                          ...uploadingIds,
                                          ...ledgers.map((l) => l.id),
                                        };

                                        // 进度用 ValueNotifier 驱动（模式同
                                        // 账本管理页 _handleBatchUpload），
                                        // 避免捕获 StatefulBuilder 的 setState
                                        final progress = ValueNotifier<int>(0);
                                        // 弹窗是否已弹出：异常路径下只有弹窗
                                        // 在台前才需要 pop，否则会误关别的路由
                                        var dialogOpen = false;

                                        try {
                                          // 强制阻塞弹窗：上传期间禁止一切
                                          // 页面操作，防止中途切账本/触发
                                          // 并发同步与上传互相踩写
                                          final dialogFuture = showDialog<void>(
                                            context: context,
                                            barrierDismissible: false,
                                            builder: (dctx) => PopScope(
                                              canPop: false,
                                              child: AlertDialog(
                                                shape: RoundedRectangleBorder(
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                            PiggyDimens
                                                                .radiusXl)),
                                                title:
                                                    Text(l10n.ledgersUploadAll),
                                                content: Column(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    const CircularProgressIndicator(),
                                                    const SizedBox(height: 16),
                                                    ValueListenableBuilder<int>(
                                                      valueListenable: progress,
                                                      builder: (_, done, __) =>
                                                          Text(
                                                        l10n.ledgersUploadingProgress(
                                                            done,
                                                            ledgers.length),
                                                        textAlign:
                                                            TextAlign.center,
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          );
                                          dialogOpen = true;

                                          // 串行逐账本上传：单个失败不中断
                                          // 整批（语义对齐 uploadAllLedgers）
                                          var success = 0;
                                          var failed = 0;
                                          for (final ledger in ledgers) {
                                            try {
                                              await sync.uploadCurrentLedger(
                                                  ledgerId: ledger.id);
                                              success++;
                                            } catch (e) {
                                              failed++;
                                            }
                                            progress.value++;
                                          }

                                          // 关闭进度弹窗（成败皆关）
                                          if (context.mounted && dialogOpen) {
                                            Navigator.of(context,
                                                    rootNavigator: true)
                                                .pop();
                                            dialogOpen = false;
                                          }
                                          await dialogFuture;
                                          if (!context.mounted) return;

                                          // 刷新账本列表与全部账本同步状态
                                          ref
                                              .read(ledgerListRefreshProvider
                                                  .notifier)
                                              .state++;
                                          ref
                                              .read(syncStatusRefreshProvider
                                                  .notifier)
                                              .state++;

                                          await AppDialog.info(context,
                                              title:
                                                  AppLocalizations.of(context)
                                                      .mineUploadSuccess,
                                              message: failed == 0
                                                  ? AppLocalizations.of(context)
                                                      .mineUploadSuccessMessage
                                                  : AppLocalizations.of(context)
                                                      .ledgersUploadAllResult(
                                                          success, failed));
                                        } catch (e) {
                                          // 异常路径也必须关掉进度弹窗，
                                          // 否则它会永久挡住页面
                                          if (context.mounted && dialogOpen) {
                                            Navigator.of(context,
                                                    rootNavigator: true)
                                                .pop();
                                            dialogOpen = false;
                                          }
                                          if (!context.mounted) return;
                                          await AppDialog.info(context,
                                              title:
                                                  AppLocalizations.of(context)
                                                      .commonFailed,
                                              message: '$e');
                                        } finally {
                                          if (mounted) {
                                            setState(() => uploadBusy = false);
                                          }
                                          // 移除本批账本的上传中标记
                                          final ids = ref
                                              .read(uploadingLedgerIdsProvider);
                                          ref
                                                  .read(
                                                      uploadingLedgerIdsProvider
                                                          .notifier)
                                                  .state =
                                              ids
                                                  .where((id) => !ledgers
                                                      .any((l) => l.id == id))
                                                  .toSet();
                                          progress.dispose();
                                        }
                                      },
                                    ),
                                    PiggyTokens.cardDivider(context),
                                    // 下载
                                    AppListTile(
                                      leading: Icons.cloud_download_outlined,
                                      title: AppLocalizations.of(context)
                                          .mineDownloadTitle,
                                      subtitle: isFirstLoad
                                          ? null
                                          : !canUseCloud
                                              ? AppLocalizations.of(context)
                                                  .mineDownloadNeedCloudService
                                              : notLoggedIn
                                                  ? AppLocalizations.of(context)
                                                      .mineUploadNeedLogin
                                                  : (refreshing
                                                      ? AppLocalizations.of(
                                                              context)
                                                          .mineUploadRefreshing
                                                      : (inSync
                                                          ? AppLocalizations.of(
                                                                  context)
                                                              .mineUploadSynced
                                                          : null)),
                                      enabled: canUseCloud &&
                                          !inSync &&
                                          !notLoggedIn &&
                                          !downloadBusy &&
                                          !isFirstLoad &&
                                          !refreshing &&
                                          !uploadBusy &&
                                          !fullUploadBusy &&
                                          !fullDownloadBusy,
                                      trailing: (downloadBusy ||
                                              refreshing ||
                                              (isFirstLoad && canUseCloud))
                                          ? const SizedBox(
                                              width: 20,
                                              height: 20,
                                              child: CircularProgressIndicator(
                                                  strokeWidth: 2))
                                          : null,
                                      onTap: () async {
                                        setState(() => downloadBusy = true);
                                        final l10n =
                                            AppLocalizations.of(context);
                                        // 强制阻塞弹窗：整个下载同步期间
                                        //（含逐账本网络调用）禁止底层页面操作，
                                        // 防止中途切账本/触发并发上传互相踩写；
                                        // 确认/diff 预览等交互弹窗叠在其上
                                        // 仍可正常操作
                                        final block =
                                            showBlockingProgressDialog(
                                          context,
                                          title: l10n.syncBlockingDownloadTitle,
                                          initialStatus:
                                              l10n.syncBlockingCheckCloud,
                                        );
                                        var totalInserted = 0;
                                        var aborted = false;
                                        String? errorMessage;
                                        try {
                                          // 尝试使用 diff 预览模式
                                          final syncManager =
                                              sync is TransactionsSyncManager
                                                  ? sync
                                                  : null;

                                          if (syncManager != null) {
                                            // 1) 云端账本发现：新设备上云端有、
                                            // 本地没有对应账本行的文件，不先导入
                                            // 的话逐账本合并永远覆盖不到它们
                                            //（语义对齐启动检查的发现流程）
                                            try {
                                              final metas = await syncManager
                                                  .discoverRemoteLedgers();
                                              if (metas.isNotEmpty &&
                                                  context.mounted) {
                                                final displayNames = metas
                                                    .map((m) =>
                                                        '${m.name}(${m.txCount})')
                                                    .join('、');
                                                final confirmed =
                                                    await AppDialog.confirm<
                                                            bool>(
                                                          context,
                                                          title: l10n
                                                              .startupSyncNewLedgersTitle,
                                                          message: l10n
                                                              .startupSyncNewLedgersMessage(
                                                                  metas.length,
                                                                  displayNames),
                                                          okLabel: l10n
                                                              .startupSyncNewLedgersOk,
                                                          cancelLabel: l10n
                                                              .startupSyncNewLedgersCancel,
                                                        ) ??
                                                        false;
                                                if (confirmed) {
                                                  for (final meta in metas) {
                                                    try {
                                                      await syncManager
                                                          .importRemoteLedger(
                                                              meta);
                                                    } catch (_) {
                                                      // 单个账本导入失败不中断其余账本
                                                    }
                                                  }
                                                }
                                              }
                                            } catch (_) {
                                              // 发现失败降级：
                                              // 不影响本地账本的逐账本合并
                                            }

                                            // 2) 遍历所有本地账本逐个预览合并
                                            //（新导入账本与云端一致，preview
                                            // 为空会自动跳过）
                                            final ledgers = await ref
                                                .read(repositoryProvider)
                                                .getAllLedgers();
                                            // 加密恢复只尝试一次：salt 问题是
                                            // 全局的，激活失败后继续逐账本走
                                            // 只会重复弹同样的错误
                                            var recoveryAttempted = false;

                                            var ledgerIndex = 0;
                                            // 两阶段（sync_convergence_fix）：
                                            // 先逐账本合并，全部完成后统一回传。
                                            // 账户/分类/标签是用户全局数据，
                                            // 交错「合并→回传」会让先回传账本
                                            // 的云端快照被后续合并引入的全局
                                            // 数据失效，指纹一轮无法收敛
                                            final mergedLedgerIds = <int>[];
                                            for (final ledger in ledgers) {
                                              ledgerIndex++;
                                              block.status.value = l10n
                                                  .syncBlockingDownloadLedger(
                                                      ledgerIndex,
                                                      ledgers.length);
                                              try {
                                                // 指纹已一致的账本直接跳过:
                                                // 数据无变化时免去逐账本全量
                                                // JSON 下载(下载慢的主因),
                                                // 状态检查(HEAD 级)代价远低
                                                // 于全量下载+diff
                                                final st =
                                                    await syncManager.getStatus(
                                                        ledgerId: ledger.id);
                                                if (st.diff ==
                                                    SyncDiff.inSync) {
                                                  continue;
                                                }
                                                final previewResult =
                                                    await syncManager
                                                        .downloadAndPreview(
                                                  ledgerId: ledger.id,
                                                );

                                                if (!context.mounted) return;
                                                // 云端无数据，跳过
                                                if (previewResult == null) {
                                                  continue;
                                                }

                                                if (previewResult.preview !=
                                                    null) {
                                                  // v6+ 格式，diff 预览
                                                  final preview =
                                                      previewResult.preview!;
                                                  if (preview.isEmpty) {
                                                    // 交易无 diff 时仍要合并
                                                    // 云端账户/分类/标签元数据:
                                                    // 纯账户变更场景下这是账户
                                                    // 落地的唯一入口(静默合并,
                                                    // 不弹框——元数据 upsert
                                                    // 无破坏性,无需用户确认)
                                                    block.status.value = l10n
                                                        .syncBlockingApplying;
                                                    await syncManager
                                                        .applyPreviewChanges(
                                                      ledgerId: ledger.id,
                                                      selectedChanges: const [],
                                                      importData: previewResult
                                                          .importData,
                                                    );
                                                    // merge-then-publish:
                                                    // 只记录待回传,循环结束
                                                    // 后统一上传收敛云端指纹
                                                    mergedLedgerIds
                                                        .add(ledger.id);
                                                    continue;
                                                  }
                                                  final selected =
                                                      await showSyncPreviewDialog(
                                                    context,
                                                    preview: preview,
                                                    primaryColor: ref.read(
                                                        primaryColorProvider),
                                                  );

                                                  if (selected == null ||
                                                      selected.isEmpty) {
                                                    continue;
                                                  }
                                                  block.status.value =
                                                      l10n.syncBlockingApplying;
                                                  final result =
                                                      await syncManager
                                                          .applyPreviewChanges(
                                                    ledgerId: ledger.id,
                                                    selectedChanges: selected,
                                                    importData: previewResult
                                                        .importData,
                                                  );
                                                  totalInserted +=
                                                      result.totalCount;
                                                  // merge-then-publish:
                                                  // 交易合并同样只记录待回传
                                                  mergedLedgerIds
                                                      .add(ledger.id);
                                                } else {
                                                  // 旧格式（v5 及以下），
                                                  // 全量替换（逐账本确认）
                                                  final confirmed =
                                                      await AppDialog.confirm<
                                                              bool>(
                                                            context,
                                                            title: l10n
                                                                .syncPreviewOldFormat,
                                                            message: l10n
                                                                .syncPreviewOldFormatMessage,
                                                          ) ??
                                                          false;

                                                  if (confirmed &&
                                                      context.mounted) {
                                                    final res = await sync
                                                        .downloadAndRestoreToCurrentLedger(
                                                            ledgerId:
                                                                ledger.id);
                                                    totalInserted +=
                                                        res.inserted;
                                                    // 全量替换同样是合并,
                                                    // 需要回传收敛指纹
                                                    mergedLedgerIds
                                                        .add(ledger.id);
                                                  }
                                                }
                                              } on SaltMismatchException {
                                                // salt 不匹配：弹密码对话框引导
                                                // 用户重新输入密码，激活成功后
                                                // 可再次点击下载重试当前账本
                                                if (recoveryAttempted) {
                                                  aborted = true;
                                                  break;
                                                }
                                                recoveryAttempted = true;
                                                if (context.mounted) {
                                                  await _handleEncryptionRecovery(
                                                    ledgerId: ledger.id,
                                                  );
                                                }
                                              } on CloudEncryptedLocallyDisabledException {
                                                // BUG-2 残留：云端为密文但本地
                                                // 未开启加密，同样走密钥恢复流程
                                                if (recoveryAttempted) {
                                                  aborted = true;
                                                  break;
                                                }
                                                recoveryAttempted = true;
                                                if (context.mounted) {
                                                  await _handleEncryptionRecovery(
                                                    ledgerId: ledger.id,
                                                  );
                                                }
                                              } catch (_) {
                                                // 单个账本失败不中断其余账本
                                              }
                                            }

                                            // ---------- 阶段 2：统一回传 ----------
                                            // 此时用户全局数据已是最终态，
                                            // 每个回传快照包含同一份全局数据，
                                            // 云端指纹一轮收敛；只合并不回传
                                            // 时下次启动仍会判 cloudNewer
                                            // 反复弹「云端有更新」
                                            for (final ledgerId
                                                in mergedLedgerIds) {
                                              block.status.value =
                                                  l10n.syncBlockingApplying;
                                              try {
                                                await syncManager
                                                    .uploadCurrentLedger(
                                                  ledgerId: ledgerId,
                                                );
                                              } catch (_) {
                                                // 回传失败不中断其余账本:
                                                // 下次启动会再次提醒,可重试
                                              }
                                            }
                                          } else {
                                            // 非 TransactionsSyncManager：
                                            // 遍历所有账本走全量恢复
                                            final ledgers = await ref
                                                .read(repositoryProvider)
                                                .getAllLedgers();
                                            var inserted = 0;
                                            var ledgerIndex = 0;
                                            for (final ledger in ledgers) {
                                              ledgerIndex++;
                                              block.status.value = l10n
                                                  .syncBlockingDownloadLedger(
                                                      ledgerIndex,
                                                      ledgers.length);
                                              try {
                                                final res = await sync
                                                    .downloadAndRestoreToCurrentLedger(
                                                        ledgerId: ledger.id);
                                                inserted += res.inserted;
                                              } catch (_) {
                                                // 单个账本失败不中断其余账本
                                              }
                                            }
                                            totalInserted = inserted;
                                          }
                                        } catch (e) {
                                          errorMessage = '$e';
                                        } finally {
                                          // 先关阻塞弹窗再展示结果：
                                          // 错误/结果弹窗若在阻塞弹窗存活时
                                          // 弹出且未被 await 完，close() 的
                                          // pop 会误关顶层弹窗
                                          await block.close();
                                          if (mounted) {
                                            setState(
                                                () => downloadBusy = false);
                                          }
                                        }

                                        if (!mounted) return;
                                        // 刷新列表与全部账本同步状态
                                        PostProcessor.runAfterDownload(ref);
                                        ref
                                            .read(ledgerListRefreshProvider
                                                .notifier)
                                            .state++;
                                        ref
                                            .read(syncStatusRefreshProvider
                                                .notifier)
                                            .state++;
                                        if (!context.mounted) return;

                                        if (errorMessage != null) {
                                          await AppDialog.error(context,
                                              title:
                                                  AppLocalizations.of(context)
                                                      .commonFailed,
                                              message: errorMessage);
                                        } else if (aborted) {
                                          // 密钥激活未成功：明确告知同步
                                          // 未恢复，避免用户误以为已完成
                                          await AppDialog.error(context,
                                              title: l10n.commonFailed,
                                              message: l10n
                                                  .startupSyncRecoveryFailedHint);
                                        } else {
                                          await AppDialog.info(context,
                                              title: l10n.mineDownloadComplete,
                                              message: l10n.mineDownloadResult(
                                                  totalInserted));
                                        }
                                      },
                                    ),
                                    // 登录/登出 (仅 Supabase 需要，其他云服务使用配置文件认证)
                                    if (!isLocalMode &&
                                        cloudConfig.value!.type ==
                                            CloudBackendType.supabase)
                                      Consumer(builder: (ctx, r, _) {
                                        final userNow = user;
                                        final cloudConfig =
                                            r.watch(activeCloudConfigProvider);

                                        // 根据云服务类型显示不同的用户信息
                                        String getUserDisplayName() {
                                          if (userNow == null) {
                                            return AppLocalizations.of(context)
                                                .mineLoginTitle;
                                          }

                                          if (cloudConfig.hasValue &&
                                              cloudConfig.value!.type ==
                                                  CloudBackendType.webdav) {
                                            // WebDAV: 显示用户名（去掉 @webdav 后缀）
                                            return userNow.id;
                                          } else {
                                            // Supabase: 显示邮箱
                                            return userNow.email ??
                                                AppLocalizations.of(context)
                                                    .mineLoggedInEmail;
                                          }
                                        }

                                        return Column(
                                          children: [
                                            PiggyTokens.cardDivider(context),
                                            AppListTile(
                                              leading: userNow == null
                                                  ? Icons.login
                                                  : Icons
                                                      .verified_user_outlined,
                                              title: getUserDisplayName(),
                                              subtitle: userNow == null
                                                  ? AppLocalizations.of(context)
                                                      .mineLoginSubtitle
                                                  : AppLocalizations.of(context)
                                                      .mineLogoutSubtitle,
                                              onTap: () async {
                                                // 提前缓存 l10n，避免 async gap 后 context 失效
                                                final l10n =
                                                    AppLocalizations.of(
                                                        context);
                                                if (userNow == null) {
                                                  await Navigator.of(context)
                                                      .push(MaterialPageRoute(
                                                          builder: (_) =>
                                                              const LoginPage()));
                                                  if (!mounted) return;
                                                  ref
                                                      .read(
                                                          syncStatusRefreshProvider
                                                              .notifier)
                                                      .state++;
                                                  ref
                                                      .read(statsRefreshProvider
                                                          .notifier)
                                                      .state++;
                                                } else {
                                                  final confirmed =
                                                      await AppDialog.confirm<
                                                              bool>(
                                                            context,
                                                            title: l10n
                                                                .mineLogoutConfirmTitle,
                                                            message: l10n
                                                                .mineLogoutConfirmMessage,
                                                            okLabel: l10n
                                                                .mineLogoutButton,
                                                            cancelLabel: l10n
                                                                .commonCancel,
                                                          ) ??
                                                          false;

                                                  if (confirmed) {
                                                    try {
                                                      final authService =
                                                          await ref.read(
                                                              authServiceProvider
                                                                  .future);
                                                      await authService
                                                          .signOut();

                                                      // 刷新认证服务和同步服务以触发状态更新
                                                      if (!mounted) return;
                                                      ref.invalidate(
                                                          authServiceProvider);
                                                      ref.invalidate(
                                                          syncServiceProvider);

                                                      ref
                                                          .read(
                                                              syncStatusRefreshProvider
                                                                  .notifier)
                                                          .state++;
                                                      ref
                                                          .read(
                                                              statsRefreshProvider
                                                                  .notifier)
                                                          .state++;
                                                    } catch (e) {
                                                      if (!mounted) return;
                                                      await AppDialog.error(
                                                        context,
                                                        title:
                                                            l10n.commonFailed,
                                                        message: '$e',
                                                      );
                                                    }
                                                  }
                                                }
                                              },
                                            ),
                                          ],
                                        );
                                      }),
                                    // 自动同步 (非 PiggyCount Cloud 的其他云服务)
                                    if (!isLocalMode)
                                      Consumer(builder: (ctx, r, _) {
                                        final autoSync =
                                            r.watch(autoSyncValueProvider);
                                        final setter =
                                            r.read(autoSyncSetterProvider);
                                        final value =
                                            autoSync.asData?.value ?? false;
                                        final can = canUseCloud;

                                        return Column(
                                          children: [
                                            PiggyTokens.cardDivider(context),
                                            PiggySwitchListTile(
                                              title: Text(
                                                  AppLocalizations.of(context)
                                                      .mineAutoSyncTitle),
                                              subtitle: can
                                                  ? Text(AppLocalizations.of(
                                                          context)
                                                      .mineAutoSyncSubtitle)
                                                  : Text(AppLocalizations.of(
                                                          context)
                                                      .mineAutoSyncNeedLogin),
                                              value: can ? value : false,
                                              onChanged: can
                                                  ? (v) async {
                                                      await setter.set(v);
                                                    }
                                                  : null,
                                            ),
                                          ],
                                        );
                                      }),
                                  ],
                                ],
                              ),
                            ),
                            // 全量覆盖同步（仅路径 A 快照后端）：
                            // PiggyCount Cloud 的 sync_changes 日志模型
                            // 没有「整本快照覆盖」语义，不展示此卡片
                            if (canUseCloud && !isPiggyCountCloud)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SectionCard(
                                  margin: EdgeInsets.zero,
                                  borderColor: ref.watch(primaryColorProvider),
                                  child: Column(
                                    children: [
                                      // 全量上传
                                      AppListTile(
                                        leading: Icons.cloud_upload,
                                        title: AppLocalizations.of(context)
                                            .fullUploadTitle,
                                        subtitle: AppLocalizations.of(context)
                                            .fullUploadSubtitle,
                                        enabled: !uploadBusy &&
                                            !downloadBusy &&
                                            !fullUploadBusy &&
                                            !fullDownloadBusy &&
                                            !backupBusy &&
                                            !restoreBusy &&
                                            !isFirstLoad &&
                                            !refreshing,
                                        trailing: fullUploadBusy
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : null,
                                        onTap: () =>
                                            _handleFullUpload(context, sync),
                                      ),
                                      PiggyTokens.cardDivider(context),
                                      // 全量下载
                                      AppListTile(
                                        leading: Icons.cloud_download,
                                        title: AppLocalizations.of(context)
                                            .fullDownloadTitle,
                                        subtitle: AppLocalizations.of(context)
                                            .fullDownloadSubtitle,
                                        enabled: !uploadBusy &&
                                            !downloadBusy &&
                                            !fullUploadBusy &&
                                            !fullDownloadBusy &&
                                            !backupBusy &&
                                            !restoreBusy &&
                                            !isFirstLoad &&
                                            !refreshing,
                                        trailing: fullDownloadBusy
                                            ? const SizedBox(
                                                width: 20,
                                                height: 20,
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : null,
                                        onTap: () =>
                                            _handleFullDownload(context, sync),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            // 云端备份卡片（仅路径 A，与全量同步卡片同口径）
                            if (canUseCloud && !isPiggyCountCloud)
                              Padding(
                                padding: const EdgeInsets.only(top: 12),
                                child: SectionCard(
                                  margin: EdgeInsets.zero,
                                  borderColor: ref.watch(primaryColorProvider),
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
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : null,
                                        onTap: () => _handleBackupNow(context),
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
                                                child:
                                                    CircularProgressIndicator(
                                                        strokeWidth: 2))
                                            : null,
                                        onTap: () =>
                                            _handleRestoreFromBackup(context),
                                      ),
                                      PiggyTokens.cardDivider(context),
                                      // 定时备份开关 + 时间 + 最近状态
                                      Consumer(builder: (ctx, r, _) {
                                        final auto = r
                                                .watch(
                                                    backupAutoEnabledProvider)
                                                .asData
                                                ?.value ??
                                            false;
                                        final time = r
                                                .watch(backupTimeProvider)
                                                .asData
                                                ?.value ??
                                            BackupScheduler.defaultBackupTime;
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
                                              PiggyTokens.cardDivider(context),
                                              AppListTile(
                                                leading: Icons.schedule,
                                                title:
                                                    AppLocalizations.of(context)
                                                        .backupTimeTitle,
                                                subtitle: time,
                                                enabled:
                                                    !backupBusy && !restoreBusy,
                                                onTap: () =>
                                                    _pickBackupTime(context, r),
                                              ),
                                            ],
                                            Padding(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                      16, 8, 16, 12),
                                              child: Align(
                                                alignment: Alignment.centerLeft,
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
                            // 同步加密入口（仅路径 A：S3/WebDAV/Supabase/iCloud）
                            // 路径 B（PiggyCount Cloud）服务端需做 LWW 合并与共享账本，不加密
                            if (canUseCloud && !isPiggyCountCloud)
                              Consumer(builder: (ctx, r, _) {
                                final encEnabledAsync =
                                    r.watch(encryptionEnabledProvider);
                                final encEnabled =
                                    encEnabledAsync.valueOrNull ?? false;
                                return Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: SectionCard(
                                    margin: EdgeInsets.zero,
                                    borderColor: r.watch(primaryColorProvider),
                                    child: AppListTile(
                                      leading: encEnabled
                                          ? Icons.lock
                                          : Icons.lock_open,
                                      title: AppLocalizations.of(context)
                                          .cloudSyncEncryptTitle,
                                      subtitle: encEnabled
                                          ? AppLocalizations.of(context)
                                              .cloudSyncEncryptMultiDeviceHint
                                          : AppLocalizations.of(context)
                                              .cloudSyncEncryptSubtitle,
                                      trailing: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 8,
                                          vertical: 4,
                                        ),
                                        decoration: BoxDecoration(
                                          color: encEnabled
                                              ? PiggyTokens.success(context)
                                                  .withValues(alpha: 0.12)
                                              : PiggyTokens.textTertiary(
                                                      context)
                                                  .withValues(alpha: 0.12),
                                          borderRadius: BorderRadius.circular(
                                              PiggyDimens.radiusXs),
                                        ),
                                        child: Text(
                                          encEnabled
                                              ? AppLocalizations.of(context)
                                                  .cloudSyncEncryptEnabled
                                              : AppLocalizations.of(context)
                                                  .cloudSyncEncryptDisabled,
                                          style: TextStyle(
                                            color: encEnabled
                                                ? PiggyTokens.success(context)
                                                : PiggyTokens.textTertiary(
                                                    context),
                                            fontSize: 12,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      onTap: () {
                                        Navigator.of(context).push(
                                          MaterialPageRoute(
                                            builder: (_) =>
                                                const EncryptionSettingsPage(),
                                          ),
                                        );
                                      },
                                    ),
                                  ),
                                );
                              }),
                          ],
                        ));
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
