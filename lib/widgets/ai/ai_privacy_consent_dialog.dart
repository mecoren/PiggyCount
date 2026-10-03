import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../ai/privacy/ai_privacy_consent.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/ai_privacy_consent_providers.dart';
import '../ui/ui.dart';

/// 确保已取得"AI 第三方数据共享"的同意。
///
/// 已同意 → 直接返回 true;未同意 → 弹出不可绕过的同意页,
/// 用户点「同意并开启」返回 true 并落库,点「取消」返回 false。
Future<bool> ensureAiPrivacyConsent(BuildContext context, WidgetRef ref) async {
  if (await AiPrivacyConsentStore.isConsented()) return true;
  if (!context.mounted) return false;
  final agreed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AiPrivacyConsentDialog(),
      ) ??
      false;
  if (agreed) {
    await ref.read(aiPrivacyConsentProvider.notifier).accept();
  }
  return agreed;
}

class AiPrivacyConsentDialog extends ConsumerWidget {
  const AiPrivacyConsentDialog({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return AppDialogShell(
      wide: true,
      title: Text(l10n.aiConsentTitle),
      // 正文本身即完整告知（发给谁 / 发什么 / 用途 / 第三方按其隐私政策处理），
      // 不再挂「隐私政策」外链页（原 privacy_policy_page 已整体下线）。
      content: SingleChildScrollView(
        child: Text(l10n.aiConsentBody, style: const TextStyle(height: 1.5)),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.aiConsentAgree),
        ),
      ],
    );
  }
}
