import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 图片 / 海报预览弹窗的**共用外壳**（Widget 形态）。
///
/// 这类弹窗的视觉语言是「透明弹层底 + 无卡片容器 + 预览区自适应高度 + 可选
/// 底部操作区」—— 它们要的是「让图片尽量大」，套项目卡片外壳反而缩小预览面积。
/// 项目此前没有这一类的共用件，海报预览（3 处）、年度报表预览、附件大图预览
/// 各写一遍透明 `Dialog` + 悬浮关闭钮 + 黑色说明胶囊（≈150 行重复样板）。
/// 本组件把外壳收成一处，各调用方只提供预览区本体与操作区。
///
/// 约定：
/// - 预览区 [preview] 由调用方自备（`Image.memory` / `InteractiveViewer` /
///   `PageView` …），本组件只负责限高与居中；
/// - 关闭走系统返回 / 点遮罩（`barrierDismissible` 默认 true）即可，故**不再**
///   自绘悬浮关闭钮；
/// - 说明文案（文件名等）走 [caption]，统一黑色半透明胶囊。
class PiggyImagePreviewDialog extends StatelessWidget {
  const PiggyImagePreviewDialog({
    super.key,
    required this.preview,
    this.caption,
    this.overlay,
    this.actions,
    this.maxPreviewHeight = 600,
    this.horizontalInset = 16,
  });

  /// 预览区本体（图片 / 可缩放图片 / 轮播）。
  final Widget preview;

  /// 可选说明文案（如文件名），显示在预览区下方的黑色半透明胶囊里。
  final String? caption;

  /// 可选：叠在预览区**之上**的控件（轮播指示器、「隐藏收入」浮层按钮等）。
  final Widget? overlay;

  /// 可选底部操作区（分享 / 保存等按钮行）。为空则不渲染。
  final Widget? actions;

  /// 预览区高度上限。
  final double maxPreviewHeight;

  /// 弹窗水平留距（默认 16；轮播预览用 20）。
  final double horizontalInset;

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: EdgeInsets.symmetric(
        horizontal: horizontalInset,
        vertical: 40,
      ),
      elevation: 0,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Stack(
              children: [
                ConstrainedBox(
                  constraints: BoxConstraints(maxHeight: maxPreviewHeight),
                  child: preview,
                ),
                if (overlay != null) overlay!,
              ],
            ),
          ),
          if (caption != null) ...[
            const SizedBox(height: PiggyDimens.p16),
            Container(
              padding: const EdgeInsets.symmetric(
                horizontal: PiggyDimens.p12,
                vertical: PiggyDimens.p8,
              ),
              decoration: BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
              ),
              child: Text(
                caption!,
                style: const TextStyle(color: Colors.white, fontSize: PiggyTextTokens.fs12),
                textAlign: TextAlign.center,
              ),
            ),
          ],
          if (actions != null) ...[
            const SizedBox(height: PiggyDimens.p16),
            actions!,
          ],
        ],
      ),
    );
  }
}

/// 以统一外壳弹出图片预览弹窗，返回用户是否点过某个动作（默认 null）。
Future<T?> showPiggyImagePreview<T>(
  BuildContext context, {
  required Uint8List imageBytes,
  String? caption,
  double maxPreviewHeight = 600,
  Widget? actions,
}) {
  return showDialog<T>(
    context: context,
    builder: (_) => PiggyImagePreviewDialog(
      caption: caption,
      maxPreviewHeight: maxPreviewHeight,
      actions: actions,
      preview: Image.memory(imageBytes, fit: BoxFit.contain),
    ),
  );
}
