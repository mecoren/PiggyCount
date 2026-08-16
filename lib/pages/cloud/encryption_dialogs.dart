import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/transactions_sync_manager.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/encryption_providers.dart';
import '../../providers/sync_providers.dart';
import '../../services/system/logger_service.dart';
import '../../widgets/encryption/password_setup_dialog.dart';
import '../../widgets/ui/dialog.dart';
import 'cloud_service_page.dart';

/// SaltMismatch 恢复流程：弹密码对话框 → 从云端重提取 salt 激活密钥 → 触发 sync 重建
///
/// 用于多设备 split-brain 场景（US-2）：设备 B 本地密钥的 salt 与云端密文头中的
/// salt 不一致，说明本地密钥已过期或密码错误。本函数引导用户重新输入密码，
/// 通过 [EncryptionService.enableFromCloud] 从云端密文头提取正确的 salt，
/// 用 (password, cloud_salt) 重新派生密钥并验证（解密校验），验证通过后持久化
/// 新密钥并触发 [TransactionsSyncManager.reinitializeForEncryption] 重建装饰器。
///
/// 同步管理器解析：内部每次通过 `ref.read(syncServiceProvider)` 取**当前**
/// TransactionsSyncManager 实例，而非调用方传入的捕获实例。原因：恢复流程
/// 会因密码对话框长时间挂起，期间用户可能在云服务页修正 WebDAV 凭据
/// （provider 重建新管理器），旧实例仍持旧密码 → 探测持续 401 →
/// 「重输正确密码仍报云端探测失败」（历史 bug，本次修复）。
///
/// 流程：
/// 1. 弹密码对话框（verify 模式，仅输入密码）
/// 2. 调用 [EncryptionService.enableFromCloud]：
///    - 密码错误 → 抛 ArgumentError → 提示"密码错误"
///    - 认证失败（WebDAV 401/403）→ 抛 EnableFromCloudAuthException
///      → 提示"账号或密码错误"并可跳转云服务页修正配置
///    - 探测失败 → 抛 EnableFromCloudProbeFailedException → 提示网络错误
///    - 密文损坏 → 抛 EnableFromCloudCorruptedException → 提示密文损坏
/// 3. 成功后调用 [TransactionsSyncManager.reinitializeForEncryption]
/// 4. 刷新 [encryptionEnabledTickProvider] 触发 UI 更新
///
/// 返回值：
/// - [SaltMismatchRecoveryResult.activated]：激活成功，调用方应**最多重试一次**原同步操作
/// - [SaltMismatchRecoveryResult.cancelled]：用户主动取消密码输入，调用方不应重试
/// - [SaltMismatchRecoveryResult.failed]：密码错误/激活失败，调用方不应重试，
///   且需要明确告知用户同步未恢复（内部已弹具体错误对话框）
Future<SaltMismatchRecoveryResult> promptPasswordAndActivate(
  BuildContext context,
  WidgetRef ref, {
  required EncryptionService service,
}) async {
  final l10n = AppLocalizations.of(context);

  // 1. 弹密码对话框
  final password = await PasswordSetupDialog.showForVerify(context);
  if (password == null) {
    // 用户取消，仅记日志
    logger.info('CloudSync', 'salt_mismatch 恢复：用户取消密码输入');
    return SaltMismatchRecoveryResult.cancelled;
  }
  if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;

  // 2. 解析当前同步管理器并确保 rawStorage 可用
  //    （enableFromCloud 需要未装饰的 storage 下载密文字符串）
  final syncService = ref.read(syncServiceProvider);
  if (syncService is! TransactionsSyncManager) {
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.saltMismatchRawStorageUnavailable,
    );
    return SaltMismatchRecoveryResult.failed;
  }
  await syncService.ensureInitialized();
  if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;
  final rawStorage = syncService.rawStorage;
  if (rawStorage == null) {
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.saltMismatchRawStorageUnavailable,
    );
    return SaltMismatchRecoveryResult.failed;
  }

  // 3. 从云端重提取 salt + 验证密码 + 持久化新密钥 + 重建装饰器
  //    关键：salt_mismatch 恢复场景禁止回退 enable（allowFallbackToEnable=false）。
  //    否则云端 list 探测找不到 ledger_*.json 密文时（文件名不匹配/路径前缀等），
  //    enableFromCloud 会生成全新随机 salt 并返回 false，本地密钥与云端永远不匹配，
  //    用户输入正确密码仍持续报"密钥不匹配"（历史 bug，本次修复）。
  //
  //    强制阻塞弹窗：首次输密码后的云端校验/激活期间禁止一切页面操作；
  //    错误弹窗统一在阻塞弹窗关闭后再展示，避免 close() 的 pop 误关顶层弹窗
  final block = showBlockingProgressDialog(
    context,
    title: l10n.saltMismatchDialogTitle,
    initialStatus: l10n.encryptionBlockingVerifying,
  );
  Object? activationError;
  bool activated = false;
  try {
    try {
      activated = await service.enableFromCloud(
        password: password,
        cloudStorage: rawStorage,
        allowFallbackToEnable: false,
      );
      if (activated) {
        // 4. 重建装饰器，让下次同步使用新密钥
        //    注意：对当前解析的 syncService 实例操作；若中途 provider 已重建，
        //    新实例初始化时会按已激活的加密状态自行装配装饰器
        block.status.value = l10n.encryptionBlockingReinit;
        await syncService.reinitializeForEncryption();
      }
    } catch (e) {
      // 先记录异常，阻塞弹窗关闭后再分类弹窗
      activationError = e;
    }
  } finally {
    await block.close();
  }

  if (!activated) {
    if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;

    // 防御：allowFallbackToEnable=false 时不应返回 false；
    // 若返回（云端确实无密文），明确告知用户无法恢复
    if (activationError == null) {
      await AppDialog.error(
        context,
        title: l10n.saltMismatchDialogTitle,
        message: l10n.saltMismatchProbeFailed,
      );
      return SaltMismatchRecoveryResult.failed;
    }

    if (activationError is ArgumentError) {
      // 密码错误（解密验证失败）
      await AppDialog.error(
        context,
        title: l10n.saltMismatchDialogTitle,
        message: l10n.cloudSyncEncryptWrongPassword,
      );
      return SaltMismatchRecoveryResult.failed;
    }
    if (activationError is EnableFromCloudAuthException) {
      // 云端认证失败（WebDAV 401/403）：重试无效，引导用户去云服务页修正凭据。
      // 新设备场景核心痛点：此前被并入 ProbeFailed 报「请检查网络」，
      // 用户重输正确密码后仍失败且无从下手
      final goConfig = await AppDialog.confirm<bool>(
        context,
        title: l10n.saltMismatchWebdavAuthTitle,
        message: l10n.saltMismatchWebdavAuthMessage,
        okLabel: l10n.saltMismatchGoConfig,
      );
      if (goConfig == true && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const CloudServicePage()),
        );
      }
      return SaltMismatchRecoveryResult.failed;
    }
    if (activationError is EnableFromCloudProbeFailedException) {
      // 云端探测失败（网络/权限）
      await AppDialog.error(
        context,
        title: l10n.saltMismatchDialogTitle,
        message: l10n.saltMismatchProbeFailed,
      );
      return SaltMismatchRecoveryResult.failed;
    }
    if (activationError is EnableFromCloudCorruptedException) {
      // 云端密文损坏
      await AppDialog.error(
        context,
        title: l10n.saltMismatchDialogTitle,
        message: l10n.saltMismatchCloudCorrupted,
      );
      return SaltMismatchRecoveryResult.failed;
    }
    // 未分类异常保持原有语义：向上抛出由调用方处理
    throw activationError;
  }

  // 5. 刷新加密状态 tick，触发 UI 更新
  ref.read(encryptionEnabledTickProvider.notifier).state++;
  // 6. 刷新同步状态 tick：让 syncStatusProvider（watch 此 tick）重新拉取。
  //    否则激活后进入设置页，syncStatusProvider 仍返回激活前缓存的
  //    'salt_mismatch_need_password'，导致「输入正确密码后设置页仍报
  //    『云端备份密钥与本地不匹配』」（历史 bug，本次修复）。
  ref.read(syncStatusRefreshProvider.notifier).state++;
  //    同时清除同步状态缓存，避免 getStatus 读到旧 error（虽然 error 不缓存，
  //    但 clear 是防御性的，确保后续 getStatus 重新走完整流程）。
  syncService.clearStatusCache();

  logger.info('CloudSync', 'salt_mismatch 恢复：密钥已重新激活');
  return SaltMismatchRecoveryResult.activated;
}
