import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../ui/ui.dart';

/// AI 外发**会话级二次确认**对话框（安全加固）。
///
/// 返回 true = 用户确认本次会话允许发送；false = 用户取消。
/// 与 [ensureAiPrivacyConsent]（一次性同意的同意书）互补：本弹窗是每次会话
/// 首次外发前的一次「现在真的发？」确认，不写持久状态（会话态由
/// `AiSendConfirmGate` 持有）。
Future<bool> ensureAiSendConfirm(BuildContext context) async {
  if (!context.mounted) return false;
  final ok = await showDialog<bool>(
    context: context,
    // 二次确认必须显式选择：点外部不静默放过（用户取消 → 不发送）。
    barrierDismissible: false,
    builder: (_) => const AiSendConfirmDialog(),
  );
  return ok ?? false;
}

class AiSendConfirmDialog extends StatelessWidget {
  const AiSendConfirmDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return AppDialogShell(
      wide: true,
      title: Text(l10n.aiSendConfirmTitle),
      content: Text(
        l10n.aiSendConfirmMessage,
        style: const TextStyle(height: 1.5),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: Text(l10n.commonCancel),
        ),
        TextButton(
          onPressed: () => Navigator.pop(context, true),
          child: Text(l10n.aiSendConfirmOk),
        ),
      ],
    );
  }
}
