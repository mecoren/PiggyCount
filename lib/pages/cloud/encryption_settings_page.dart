import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../cloud/transactions_sync_manager.dart';
import '../../domain/encryption/encryption_service.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/encryption_providers.dart';
import '../../providers/sync_providers.dart' as sync_p;
import '../../styles/tokens.dart';
import '../../widgets/biz/app_list_tile.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/encryption/password_setup_dialog.dart';
import '../../widgets/ui/dialog.dart';
import '../../widgets/ui/piggy_header.dart';
import '../../widgets/ui/toast.dart';

/// 加密设置页 — 设置 / 修改 / 重置同步加密密码
///
/// 三种状态：
/// - 未开启：显示「设置密码」入口
/// - 已开启：显示「修改密码」+「重置加密」入口
/// - 已开启但无密钥（异常状态）：显示「设置密码」+ 警示
class EncryptionSettingsPage extends ConsumerStatefulWidget {
  const EncryptionSettingsPage({super.key});

  @override
  ConsumerState<EncryptionSettingsPage> createState() =>
      _EncryptionSettingsPageState();
}

class _EncryptionSettingsPageState
    extends ConsumerState<EncryptionSettingsPage> {
  bool _busy = false;

  Future<void> _onSetPassword() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final result = await PasswordSetupDialog.showForResult(
      context,
      mode: PasswordDialogMode.setup,
    );
    if (result == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    // 强制阻塞弹窗：云端校验/全量重加密期间禁止一切页面操作，
    // 防止用户中途编辑数据或触发同步与重加密互相踩写
    final block = showBlockingProgressDialog(
      context,
      title: l10n.cloudSyncEncryptSetPassword,
      initialStatus: l10n.encryptionBlockingVerifying,
    );
    try {
      final service = ref.read(encryptionServiceProvider);
      final sync = ref.read(sync_p.syncServiceProvider);

      // 多设备加入流程：优先从云端密文头提取 salt
      // - true：新设备加入成功（云端已是密文，无需重加密）
      // - false：首设备场景（回退到 enable，需触发全量重加密）
      bool isNewDevice = false;
      bool usedEnableFromCloud = false;

      if (sync is TransactionsSyncManager) {
        // 确保 _provider 已初始化（rawStorage 才可用）
        await sync.ensureInitialized();
        final rawStorage = sync.rawStorage;
        if (rawStorage != null) {
          try {
            isNewDevice = await service.enableFromCloud(
              password: result.password,
              cloudStorage: rawStorage,
            );
            usedEnableFromCloud = true;
          } on EnableFromCloudAuthException {
            // WebDAV 401/403：凭据错误重试无效，也不能走「以首设备继续」
            // （重加密会用错误凭据失败），直接提示修正配置
            if (!mounted) return;
            await AppDialog.error(
              context,
              title: l10n.saltMismatchWebdavAuthTitle,
              message: l10n.saltMismatchWebdavAuthMessage,
            );
            return;
          } on EnableFromCloudProbeFailedException {
            // US-3: 探测失败不自动回退 enable()，改为提示用户确认。
            // 若用户确认"以首设备继续"，走 enable + reEncrypt 流程；
            // 若用户取消，则不开启加密。
            if (!mounted) return;
            final confirmed = await AppDialog.confirm<bool>(
              context,
              title: l10n.cloudSyncEncryptProbeFailedTitle,
              message: l10n.cloudSyncEncryptProbeFailedMessage,
              okLabel: l10n.cloudSyncEncryptProbeFailedContinue,
            );
            if (confirmed != true || !mounted) return;
            // 用户确认以首设备身份继续 → 走 enable 流程
            await service.enable(password: result.password);
            usedEnableFromCloud = true;
            isNewDevice = false;
          }
        }
      }

      // 回退路径：sync 非 TransactionsSyncManager 或 rawStorage 不可用
      // （如 iCloud 未登录）→ 走首设备 enable 流程
      if (!usedEnableFromCloud) {
        await service.enable(password: result.password);
      }

      // 装饰器重建 + 可选的全量重加密
      // - 首设备场景（isNewDevice=false）：reEncryptCloudAndReinit 包含
      //   全量重加密 + reinitializeForEncryption
      // - 新设备场景（isNewDevice=true）：仅 reinitializeForEncryption
      //   （云端已是密文，无需重加密）
      if (sync is TransactionsSyncManager) {
        if (!isNewDevice) {
          block.status.value = l10n.encryptionBlockingReencrypt;
          final reEncResult = await sync.reEncryptCloudAndReinit(
            encryptionService: service,
          );
          // 重加密失败时仅警告不阻塞，用户下次同步时仍可触发重加密
          // await：确保警告弹窗落定后 finally 才关阻塞弹窗，避免误 pop
          if (reEncResult != null && reEncResult.failed > 0 && mounted) {
            await AppDialog.warning(
              context,
              title: l10n.cloudSyncEncryptSetPassword,
              message: l10n.cloudSyncEncryptReencryptPartialFailed(
                reEncResult.failed,
              ),
            );
          }
        } else {
          // 新设备：云端已是密文，仅需重建装饰器
          block.status.value = l10n.encryptionBlockingReinit;
          await sync.reinitializeForEncryption();
        }
      }

      ref.read(encryptionEnabledTickProvider.notifier).state++;
      if (mounted) showToast(context, l10n.cloudSyncEncryptEnableSuccess);
    } catch (e) {
      if (mounted) {
        // await：确保错误弹窗落定后 finally 才关阻塞弹窗，避免误 pop
        await AppDialog.error(
          context,
          title: l10n.cloudSyncEncryptSetPassword,
          message: e.toString(),
        );
      }
    } finally {
      await block.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onChangePassword() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final result = await PasswordSetupDialog.showForResult(
      context,
      mode: PasswordDialogMode.change,
    );
    if (result == null || result.oldPassword == null) return;
    if (!mounted) return;

    setState(() => _busy = true);
    // 强制阻塞弹窗：改密 + 云端存量密文重加密期间禁止一切页面操作
    final block = showBlockingProgressDialog(
      context,
      title: l10n.cloudSyncEncryptChangePassword,
      initialStatus: l10n.encryptionBlockingChangePassword,
    );
    try {
      final service = ref.read(encryptionServiceProvider);
      final sync = ref.read(sync_p.syncServiceProvider);

      // 缺陷 A 修复：改密时内联重加密云端存量密文
      // 用旧密钥解密 → 新密钥加密 → 上传，确保改密后云端密文仍可解密。
      // 需要未装饰的 raw storage（装饰器会自动解密，导致双重加密）。
      ReEncryptResult? reEncResult;
      if (sync is TransactionsSyncManager) {
        await sync.ensureInitialized();
        final rawStorage = sync.rawStorage;
        if (rawStorage != null) {
          reEncResult = await service.changePasswordWithCloudReEncryption(
            oldPassword: result.oldPassword!,
            newPassword: result.password,
            cloudStorage: rawStorage,
          );
        } else {
          // rawStorage 不可用（如 iCloud 未登录）：回退到普通改密，警告用户
          // await：确保警告弹窗落定后 finally 才关阻塞弹窗，避免误 pop
          await service.changePassword(
            oldPassword: result.oldPassword!,
            newPassword: result.password,
          );
          if (mounted) {
            await AppDialog.warning(
              context,
              title: l10n.cloudSyncEncryptChangePassword,
              message: '云存储不可用，云端存量密文未能重加密。'
                  '请连接云存储后重新同步，否则云端备份将无法用新密码解密。',
            );
          }
        }
      } else {
        // 非 TransactionsSyncManager（如 SyncEngine/PiggyCount Cloud）：
        // 走普通改密。变更日志后端的加密覆盖由缺陷 B 修复处理。
        await service.changePassword(
          oldPassword: result.oldPassword!,
          newPassword: result.password,
        );
      }

      // 修改密码后强制 sync 重新初始化，让装饰器重建并使用新密钥
      if (sync is TransactionsSyncManager) {
        await sync.reinitializeForEncryption();
      }

      // 重加密部分失败时警告（不阻塞，密钥已轮换完成）
      if (reEncResult != null && reEncResult.failed > 0 && mounted) {
        await AppDialog.warning(
          context,
          title: l10n.cloudSyncEncryptChangePassword,
          message: l10n.cloudSyncEncryptReencryptPartialFailed(
            reEncResult.failed,
          ),
        );
      }

      ref.read(encryptionEnabledTickProvider.notifier).state++;
      if (mounted) showToast(context, l10n.cloudSyncEncryptChangeSuccess);
    } catch (e) {
      if (mounted) {
        await AppDialog.error(
          context,
          title: l10n.cloudSyncEncryptChangePassword,
          message: e.toString(),
        );
      }
    } finally {
      await block.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _onResetEncryption() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.cloudSyncEncryptResetConfirmTitle,
      message: l10n.cloudSyncEncryptResetConfirmMessage,
    );
    if (confirmed != true) return;
    if (!mounted) return;

    // 重置前要求用户验证密码（若已开启加密）
    final service = ref.read(encryptionServiceProvider);
    final hasKey = await service.hasActiveKey;
    if (!mounted) return;
    if (hasKey) {
      final password = await PasswordSetupDialog.showForVerify(context);
      if (password == null) return;
      final ok = await service.verifyPassword(password);
      if (!ok) {
        if (!mounted) return;
        AppDialog.error(
          context,
          title: l10n.cloudSyncEncryptResetEncryption,
          message: l10n.cloudSyncEncryptWrongPassword,
        );
        return;
      }
    }
    if (!mounted) return;

    setState(() => _busy = true);
    // 强制阻塞弹窗：重置 + 装饰器重建期间禁止一切页面操作
    final block = showBlockingProgressDialog(
      context,
      title: l10n.cloudSyncEncryptResetEncryption,
      initialStatus: l10n.encryptionBlockingReset,
    );
    try {
      await service.reset();
      // 重置后强制 sync 重新初始化，卸载加密装饰器
      final sync = ref.read(sync_p.syncServiceProvider);
      if (sync is TransactionsSyncManager) {
        await sync.reinitializeForEncryption();
      }
      ref.read(encryptionEnabledTickProvider.notifier).state++;
      if (mounted) showToast(context, l10n.cloudSyncEncryptResetSuccess);
    } catch (e) {
      if (mounted) {
        await AppDialog.error(
          context,
          title: l10n.cloudSyncEncryptResetEncryption,
          message: e.toString(),
        );
      }
    } finally {
      await block.close();
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final enabledAsync = ref.watch(encryptionEnabledProvider);
    final hasKeyAsync = ref.watch(encryptionHasActiveKeyProvider);
    final isEnabled = enabledAsync.valueOrNull ?? false;
    final hasKey = hasKeyAsync.valueOrNull ?? false;

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.cloudSyncEncryptSettings,
        showBack: true,
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // 状态展示
            SectionCard(
              borderColor: Theme.of(context).colorScheme.primary,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        isEnabled ? Icons.lock : Icons.lock_open,
                        color: PiggyTokens.textSecondary(context),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.cloudSyncEncryptTitle,
                              style: PiggyTextTokens.title(context).copyWith(
                                color: PiggyTokens.textPrimary(context),
                              ),
                            ),
                            Text(
                              l10n.cloudSyncEncryptSubtitle,
                              style: PiggyTextTokens.label(context).copyWith(
                                color: PiggyTokens.textSecondary(context),
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: isEnabled
                              ? PiggyTokens.success(context)
                                  .withValues(alpha: 0.12)
                              : Colors.grey.withValues(alpha: 0.12),
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusXs),
                        ),
                        child: Text(
                          isEnabled
                              ? l10n.cloudSyncEncryptEnabled
                              : l10n.cloudSyncEncryptDisabled,
                          style: TextStyle(
                            color: isEnabled
                                ? PiggyTokens.success(context)
                                : Colors.grey,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                  if (isEnabled) ...[
                    const SizedBox(height: 8),
                    Text(
                      l10n.cloudSyncEncryptMultiDeviceHint,
                      style: PiggyTextTokens.label(context).copyWith(
                        color: PiggyTokens.textTertiary(context),
                      ),
                    ),
                  ],
                  if (isEnabled && !hasKey) ...[
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: Theme.of(context)
                            .colorScheme
                            .error
                            .withValues(alpha: 0.08),
                        borderRadius:
                            BorderRadius.circular(PiggyDimens.radiusXs),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.warning_amber,
                              size: 16,
                              color: Theme.of(context).colorScheme.error),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              l10n.cloudSyncEncryptDecryptFailed,
                              style: PiggyTextTokens.label(context).copyWith(
                                color: Theme.of(context).colorScheme.error,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 16),
            // 操作入口
            SectionCard(
              borderColor: Theme.of(context).colorScheme.primary,
              child: Column(
                children: [
                  if (!isEnabled || !hasKey)
                    AppListTile(
                      leading: Icons.password,
                      title: l10n.cloudSyncEncryptSetPassword,
                      subtitle: l10n.cloudSyncEncryptPasswordHint,
                      onTap: _busy ? null : _onSetPassword,
                    ),
                  if (isEnabled && hasKey) ...[
                    AppListTile(
                      leading: Icons.edit,
                      title: l10n.cloudSyncEncryptChangePassword,
                      subtitle: l10n.cloudSyncEncryptPasswordHint,
                      onTap: _busy ? null : _onChangePassword,
                    ),
                    PiggyTokens.cardDivider(context),
                    AppListTile(
                      leading: Icons.delete_outline,
                      title: l10n.cloudSyncEncryptResetEncryption,
                      subtitle: l10n.cloudSyncEncryptResetConfirmTitle,
                      onTap: _busy ? null : _onResetEncryption,
                    ),
                  ],
                ],
              ),
            ),
            if (_busy)
              const Padding(
                padding: EdgeInsets.only(top: 16),
                child: Center(
                  child: SizedBox(
                    width: 24,
                    height: 24,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
