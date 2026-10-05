import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../data/encryption/local_db_encryption_service.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers/db_encryption_providers.dart';
import '../../../styles/tokens.dart';
import '../../../widgets/biz/section_card.dart';
import '../../../widgets/ui/dialog.dart';
import '../../../widgets/ui/toast.dart';

/// 「整库加密」开关卡片（R6 开关 + 风险告知 + 待重启提示）。
///
/// 与同页的**云端 E2EE** 是两件事：前者加密本地库文件，后者加密上传到云端的
/// 快照。文案里必须说清，否则用户会以为"开了云端加密 = 本地也加密了"。
///
/// 开关语义（见 [LocalDbEncryptionState]）：加密/解密都是**开库前的文件级迁移**，
/// 所以点完只登记意图，**重启后才生效** —— UI 如实表达，不假装已生效。
class LocalDbEncryptionSection extends ConsumerWidget {
  const LocalDbEncryptionSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final state = ref.watch(localDbEncryptionStateProvider).valueOrNull;
    // 首次读取完成前整卡不渲染：避免"先显示未开启、再跳成已开启"的闪动
    if (state == null) return const SizedBox.shrink();

    final on = state == LocalDbEncryptionState.enabled ||
        state == LocalDbEncryptionState.pendingEnable;
    // 引擎不支持 / 密钥不可得时不给点：前者点了也没用，后者点了更糟（会清库）。
    final toggleable = state != LocalDbEncryptionState.unsupported &&
        state != LocalDbEncryptionState.keyMissing;

    return SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                on ? Icons.enhanced_encryption : Icons.lock_open_outlined,
                color: on
                    ? PiggyTokens.primary(context)
                    : PiggyTokens.textSecondary(context),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      l10n.dbEncryptTitle,
                      style: PiggyTextTokens.title(context)
                          .copyWith(color: PiggyTokens.textPrimary(context)),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      l10n.dbEncryptSubtitle,
                      style: PiggyTextTokens.label(context)
                          .copyWith(color: PiggyTokens.textSecondary(context)),
                    ),
                  ],
                ),
              ),
              Switch(
                value: on,
                onChanged:
                    toggleable ? (want) => _toggle(context, ref, want) : null,
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _statusText(l10n, state),
            style: PiggyTextTokens.label(context).copyWith(
              color: state == LocalDbEncryptionState.keyMissing
                  ? Theme.of(context).colorScheme.error
                  : PiggyTokens.textSecondary(context),
            ),
          ),
        ],
      ),
    );
  }

  /// 每种状态一句实话（含"待重启"与"密钥不可得"两条最容易误导人的）。
  String _statusText(AppLocalizations l10n, LocalDbEncryptionState state) {
    switch (state) {
      case LocalDbEncryptionState.unsupported:
        return l10n.dbEncryptUnsupported;
      case LocalDbEncryptionState.disabled:
        return l10n.dbEncryptOff;
      case LocalDbEncryptionState.pendingEnable:
        return l10n.dbEncryptPendingEnable;
      case LocalDbEncryptionState.enabled:
        return l10n.dbEncryptEnabled;
      case LocalDbEncryptionState.pendingDisable:
        return l10n.dbEncryptPendingDisable;
      case LocalDbEncryptionState.keyMissing:
        return l10n.dbEncryptKeyMissing;
    }
  }

  /// 危险操作确认后才落地：开启的风险是"密钥丢了数据就没了"，关闭的风险是
  /// "落盘回到明文"。两者都值得让用户先停下来看一眼。
  Future<void> _toggle(BuildContext context, WidgetRef ref, bool enable) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await showDangerConfirmDialog(
      context,
      title: enable ? l10n.dbEncryptEnableTitle : l10n.dbEncryptDisableTitle,
      message:
          enable ? l10n.dbEncryptEnableMessage : l10n.dbEncryptDisableMessage,
      countdownSeconds: enable ? 3 : 5,
    );
    if (!confirmed || !context.mounted) return;

    try {
      final service = ref.read(localDbEncryptionServiceProvider);
      if (enable) {
        await service.enable();
      } else {
        await service.requestDisable();
      }
      ref.read(localDbEncryptionRefreshProvider.notifier).state++;
      if (context.mounted) showToast(context, l10n.dbEncryptRestartHint);
    } catch (e) {
      if (context.mounted) showToast(context, l10n.dbEncryptActionFailed);
    }
  }
}
