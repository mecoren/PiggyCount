import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../services/attachment_export_import_service.dart';
import '../../providers.dart';

/// 附件预览页面
/// 用于展示即将导出或导入的附件图片和自定义图标
class AttachmentPreviewPage extends ConsumerStatefulWidget {
  final ExportPreviewData? exportData; // 导出数据（本地文件）
  final ArchivePreviewData? archiveData; // 导入数据（归档数据）
  final String title;

  const AttachmentPreviewPage({
    super.key,
    this.exportData,
    this.archiveData,
    required this.title,
  }) : assert(
          (exportData != null && archiveData == null) ||
              (exportData == null && archiveData != null),
          'Must provide either exportData or archiveData, but not both',
        );

  @override
  ConsumerState<AttachmentPreviewPage> createState() => _AttachmentPreviewPageState();
}

class _AttachmentPreviewPageState extends ConsumerState<AttachmentPreviewPage> {
  /// 当前选中的标签：'attachment' | 'customIcon'
  String _selectedTab = 'attachment';
  int? _selectedIndex;

  int get attachmentCount => widget.exportData?.attachments.length ??
      widget.archiveData?.attachments.length ??
      0;

  int get customIconCount => widget.exportData?.customIcons.length ??
      widget.archiveData?.customIcons.length ??
      0;

  int get totalCount => attachmentCount + customIconCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: widget.title,
        showBack: true,
      ),
      body: Column(
        children: [
          SizedBox(height: MediaQuery.of(context).padding.top + 56),
          // 滑动分段选择器
          if (totalCount > 0)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
              child: WaitSlidingSegmentedControl<String>(
                selected: _selectedTab,
                segments: [
                  WaitSlidingSegment(
                    value: 'attachment',
                    label: '${l10n.attachmentImportTitle} ($attachmentCount)',
                  ),
                  WaitSlidingSegment(
                    value: 'customIcon',
                    label: '自定义图标 ($customIconCount)',
                  ),
                ],
                onValueChanged: (value) =>
                    setState(() => _selectedTab = value),
              ),
            ),
          Expanded(
            child: totalCount == 0
                ? Center(
                    child: Text(
                      l10n.attachmentPreviewEmpty,
                      style: TextStyle(
                        color: BeeTokens.textSecondary(context),
                        fontSize: 14,
                      ),
                    ),
                  )
                : IndexedStack(
                    index: _selectedTab == 'attachment' ? 0 : 1,
                    children: [
                      // 附件预览
                      _buildGridView(true),
                      // 自定义图标预览
                      _buildGridView(false),
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGridView(bool isAttachment) {
    final l10n = AppLocalizations.of(context);
    final count = isAttachment ? attachmentCount : customIconCount;

    if (count == 0) {
      return Center(
        child: Text(
          l10n.attachmentPreviewEmpty,
          style: TextStyle(
            color: BeeTokens.textSecondary(context),
            fontSize: 14,
          ),
        ),
      );
    }

    return GridView.builder(
      padding: EdgeInsets.all(12.0.scaled(context, ref)),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 8.0.scaled(context, ref),
        mainAxisSpacing: 8.0.scaled(context, ref),
        childAspectRatio: 1.0,
      ),
      itemCount: count,
      itemBuilder: (context, index) {
        return _buildImageItem(context, index, isAttachment);
      },
    );
  }

  Widget _buildImageItem(BuildContext context, int index, bool isAttachment) {
    final isSelected = _selectedIndex == index;

    return GestureDetector(
      onTap: () => _showImageDetail(context, index, isAttachment),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(BeeDimens.radiusSm),
          border: isSelected
              ? Border.all(
                  color: ref.watch(primaryColorProvider),
                  width: 2,
                )
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(BeeDimens.radiusSm),
          child: _buildImage(index, isAttachment),
        ),
      ),
    );
  }

  Widget _buildImage(int index, bool isAttachment) {
    if (widget.exportData != null) {
      // 本地文件
      final file = isAttachment
          ? widget.exportData!.attachments[index]
          : widget.exportData!.customIcons[index];
      return Image.file(
        file,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: BeeTokens.surface(context),
            child: Icon(
              Icons.broken_image,
              color: BeeTokens.iconSecondary(context),
            ),
          );
        },
      );
    } else {
      // 归档数据
      final item = isAttachment
          ? widget.archiveData!.attachments[index]
          : widget.archiveData!.customIcons[index];
      return Image.memory(
        item.bytes,
        fit: BoxFit.cover,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: BeeTokens.surface(context),
            child: Icon(
              Icons.broken_image,
              color: BeeTokens.iconSecondary(context),
            ),
          );
        },
      );
    }
  }

  void _showImageDetail(BuildContext context, int index, bool isAttachment) {
    setState(() {
      _selectedIndex = index;
    });

    String fileName;
    Widget imageWidget;

    if (widget.exportData != null) {
      final file = isAttachment
          ? widget.exportData!.attachments[index]
          : widget.exportData!.customIcons[index];
      fileName = file.path.split('/').last;
      imageWidget = Image.file(file);
    } else {
      final item = isAttachment
          ? widget.archiveData!.attachments[index]
          : widget.archiveData!.customIcons[index];
      fileName = item.fileName;
      imageWidget = Image.memory(item.bytes);
    }

    showDialog(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 关闭按钮
            Align(
              alignment: Alignment.topRight,
              child: IconButton(
                icon: const Icon(Icons.close, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
            // 图片
            Flexible(
              child: InteractiveViewer(
                child: imageWidget,
              ),
            ),
            const SizedBox(height: 16),
            // 文件名
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(BeeDimens.radiusSm),
              ),
              child: Text(
                fileName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    ).then((_) {
      setState(() {
        _selectedIndex = null;
      });
    });
  }
}
