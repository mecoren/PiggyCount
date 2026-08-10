import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/transactions_sync_manager.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/encryption_providers.dart';
import '../../services/system/logger_service.dart';
import '../../widgets/encryption/password_setup_dialog.dart';
import '../../widgets/ui/dialog.dart';

/// SaltMismatch 恢复流程：弹密码对话框 → 从云端重提取 salt 激活密钥 → 触发 sync 重建
///
/// 用于多设备 split-brain 场景（US-2）：设备 B 本地密钥的 salt 与云端密文头中的
/// salt 不一致，说明本地密钥已过期或密码错误。本函数引导用户重新输入密码，
/// 通过 [EncryptionService.enableFromCloud] 从云端密文头提取正确的 salt，
/// 用 (password, cloud_salt) 重新派生密钥并验证（解密校验），验证通过后持久化
/// 新密钥并触发 [TransactionsSyncManager.reinitializeForEncryption] 重建装饰器。
///
/// 流程：
/// 1. 弹密码对话框（verify 模式，仅输入密码）
/// 2. 调用 [EncryptionService.enableFromCloud]：
///    - 密码错误 → 抛 ArgumentError → 提示"密码错误"
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
  required TransactionsSyncManager syncManager,
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

  // 2. 确保 rawStorage 可用（enableFromCloud 需要未装饰的 storage 下载密文字符串）
  await syncManager.ensureInitialized();
  if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;
  final rawStorage = syncManager.rawStorage;
  if (rawStorage == null) {
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.saltMismatchRawStorageUnavailable,
    );
    return SaltMismatchRecoveryResult.failed;
  }

  // 3. 从云端重提取 salt + 验证密码 + 持久化新密钥
  try {
    await service.enableFromCloud(
      password: password,
      cloudStorage: rawStorage,
    );
  } on ArgumentError {
    // 密码错误（解密验证失败）
    if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.cloudSyncEncryptWrongPassword,
    );
    return SaltMismatchRecoveryResult.failed;
  } on EnableFromCloudProbeFailedException {
    // 云端探测失败（网络/权限）
    if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.saltMismatchProbeFailed,
    );
    return SaltMismatchRecoveryResult.failed;
  } on EnableFromCloudCorruptedException {
    // 云端密文损坏
    if (!context.mounted) return SaltMismatchRecoveryResult.cancelled;
    await AppDialog.error(
      context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.saltMismatchCloudCorrupted,
    );
    return SaltMismatchRecoveryResult.failed;
  }

  // 4. 重建装饰器，让下次同步使用新密钥
  await syncManager.reinitializeForEncryption();
  // 5. 刷新加密状态 tick，触发 UI 更新
  ref.read(encryptionEnabledTickProvider.notifier).state++;

  logger.info('CloudSync', 'salt_mismatch 恢复：密钥已重新激活');
  return SaltMismatchRecoveryResult.activated;
}
