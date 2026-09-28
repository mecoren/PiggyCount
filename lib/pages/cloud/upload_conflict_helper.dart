import 'package:flutter/material.dart';

import '../../cloud/sync_service.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/ui/dialog.dart';

/// M7：单账本手动上传的冲突守卫。
///
/// 先正常尝试上传；若抛出 [CloudConflictException]（云端快照更新 /
/// 方向无法判定但内容不同），弹确认对话框让用户三选一：
/// - **对比合并**（提供 [compareMerge] 时）：进入逐条 diff 预览合并，
///   不覆盖任何一侧 —— 方向仲裁时间戳失真（recordChanges:false 导入）
///   时的无损出路；
/// - **强制上传**：用户确认后以 force 重试；
/// - **取消**：返回 false 且不再抛异常。
///
/// 未提供 [compareMerge] 时保持旧二选一（强制上传 / 取消）。
///
/// 其他异常原样向上抛，由调用方既有的失败提示逻辑处理（SnackBar 等）。
/// 返回 true = 上传成功（含用户确认覆盖）。
Future<bool> uploadLedgerWithConflictGuard(
  BuildContext context, {
  required Future<void> Function({required bool force}) run,
  Future<void> Function()? compareMerge,
}) async {
  final l10n = AppLocalizations.of(context);
  try {
    await run(force: false);
    return true;
  } on CloudConflictException catch (e) {
    final message = e.isCloudNewer
        ? l10n.conflictUploadCloudNewerMessage
        : l10n.conflictUploadUnknownMessage;
    if (!context.mounted) return false;

    // 有合并能力时升级为三选一；否则保持原二选一确认框
    if (compareMerge != null) {
      final action = await showDialog<String>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => AppDialogShell(
          title: Text(l10n.conflictUploadTitle),
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, 'cancel'),
              child: Text(l10n.commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, 'merge'),
              child: Text(l10n.conflictCompareMergeAction),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dctx, 'force'),
              child: Text(l10n.conflictForceUploadAction),
            ),
          ],
        ),
      );
      if (!context.mounted) return false;
      switch (action) {
        case 'merge':
          await compareMerge();
          return false; // 合并流程自带反馈，不再走上传成功提示
        case 'force':
          await run(force: true);
          return true;
        default:
          // 用户取消：保持云端不动，本地未推送数据不受影响
          return false;
      }
    }

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.conflictUploadTitle,
      message: message,
      okLabel: l10n.conflictForceUploadAction,
    );
    if (confirmed != true) {
      // 用户取消：保持云端不动，本地未推送数据不受影响
      return false;
    }
    await run(force: true);
    return true;
  }
}
