import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../services/attachment_export_import_service.dart';
import '../../services/system/logger_service.dart' show unawaitedLog;
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
  ConsumerState<AttachmentPreviewPage> createState() =>
      _AttachmentPreviewPageState();
}

class _AttachmentPreviewPageState extends ConsumerState<AttachmentPreviewPage> {
  /// 当前选中的标签：'attachment' | 'customIcon'
  String _selectedTab = 'attachment';
  int? _selectedIndex;

  int get attachmentCount =>
      widget.exportData?.attachments.length ??
      widget.archiveData?.attachments.length ??
      0;

  int get customIconCount =>
      widget.exportData?.customIcons.length ??
      widget.archiveData?.customIcons.length ??
      0;

  int get totalCount => attachmentCount + customIconCount;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: widget.title,
        showBack: true,
      ),
      body: Column(
        children: [
          SizedBox(height: PiggyTokens.topScrollablePadding(context)),
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
                    label: l10n.attachmentCustomIcons(customIconCount),
                  ),
                ],
                onValueChanged: (value) => setState(() => _selectedTab = value),
              ),
            ),
          Expanded(
            child: totalCount == 0
                ? Center(
                    child: Text(
                      l10n.attachmentPreviewEmpty,
                      style: PiggyTextTokens.body(context)
                          .copyWith(color: PiggyTokens.textSecondary(context)),
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
          style: PiggyTextTokens.body(context)
              .copyWith(color: PiggyTokens.textSecondary(context)),
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
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          border: isSelected
              ? Border.all(
                  color: ref.watch(primaryColorProvider),
                  width: 2,
                )
              : null,
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          child: _buildImage(index, isAttachment),
        ),
      ),
    );
  }

  Widget _buildImage(int index, bool isAttachment) {
    // 3 列网格格位约 = 屏宽/3,按该宽度×dpr 解码即可,原图直解在批量
    // 导出场景下会把数百张图各数十 MB 的解码内存叠进 imageCache。
    final cellPx = (MediaQuery.sizeOf(context).width / 3 *
            MediaQuery.devicePixelRatioOf(context))
        .round();
    if (widget.exportData != null) {
      // 本地文件
      final file = isAttachment
          ? widget.exportData!.attachments[index]
          : widget.exportData!.customIcons[index];
      return Image.file(
        file,
        fit: BoxFit.cover,
        cacheWidth: cellPx,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: PiggyTokens.surface(context),
            child: Icon(
              Icons.broken_image,
              color: PiggyTokens.iconSecondary(context),
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
        cacheWidth: cellPx,
        errorBuilder: (context, error, stackTrace) {
          return Container(
            color: PiggyTokens.surface(context),
            child: Icon(
              Icons.broken_image,
              color: PiggyTokens.iconSecondary(context),
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
      // 弹窗全屏查看:按屏幕宽×dpr 解码足够( Dialog 内容宽 ≤ 屏宽)。
      imageWidget = Image.file(
        file,
        cacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round(),
      );
    } else {
      final item = isAttachment
          ? widget.archiveData!.attachments[index]
          : widget.archiveData!.customIcons[index];
      fileName = item.fileName;
      imageWidget = Image.memory(
        item.bytes,
        cacheWidth:
            (MediaQuery.sizeOf(context).width *
                    MediaQuery.devicePixelRatioOf(context))
                .round(),
      );
    }

    // P1-B：大图弹窗关闭后清理选中态；fire-and-forget 链异常落日志，
    // 并补 mounted 守卫（弹窗未关而页面先销毁时 setState 会抛错）
    // 外壳走项目图片预览统一件（[PiggyImagePreviewDialog]）：透明底 + 限高
    // 预览区 + 文件名胶囊，不再自绘 Dialog + 悬浮关闭钮（点遮罩/返回即可关）
    unawaitedLog(
      showDialog<void>(
        context: context,
        builder: (_) => PiggyImagePreviewDialog(
          caption: fileName,
          preview: InteractiveViewer(child: imageWidget),
        ),
      ).then((_) {
        if (!mounted) return;
        setState(() {
          _selectedIndex = null;
        });
      }),
      '附件大图预览关闭回执',
    );
  }
}
