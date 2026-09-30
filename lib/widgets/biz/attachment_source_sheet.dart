import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../ui/ui.dart';

/// 附件来源选择抽屉（拍照 / 从相册选择）——附件三处入口共用。
///
/// 外壳走 [PiggyPickerSheet]（悬浮卡片 + 顶栏 X/标题）；点选即执行并收起，
/// 没有待提交的选中态，故不设确认钩子。回调由调用方给出，各自负责
/// 后续的拍照 / 选图与落库（抽屉本身不持有状态）。
Future<void> showAttachmentSourceSheet(
  BuildContext context, {
  required VoidCallback onTakePhoto,
  required VoidCallback onPickFromGallery,
}) {
  final l10n = AppLocalizations.of(context);
  return showPiggyPickerSheet<void>(
    context,
    builder: (ctx) => PiggyPickerSheet(
      title: l10n.attachmentAdd,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.camera_alt),
            title: Text(l10n.attachmentTakePhoto),
            onTap: () {
              Navigator.pop(ctx);
              onTakePhoto();
            },
          ),
          ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(l10n.attachmentChooseFromGallery),
            onTap: () {
              Navigator.pop(ctx);
              onPickFromGallery();
            },
          ),
        ],
      ),
    ),
  );
}
