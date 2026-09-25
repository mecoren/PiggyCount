import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';

/// 把 [widget] 离屏渲染为 PNG 字节 —— 分享海报类功能的统一截屏入口。
///
/// 通过 OverlayEntry 挂到屏幕外渲染。此前该逻辑在
/// share_poster_service（×3）与 annual_report_page（×2）各有一份拷贝，
/// 且 pixelRatio 不统一（3.0 vs 2.0）：同一张年报海报从不同入口分享
/// 清晰度差 33%。本 util 统一 pixelRatio=3.0、统一等待策略、统一
/// image.dispose（pixelRatio 3.0 的位图 8~15MB，不释放不会随作用域
/// 结束回收）。
///
/// 返回 null 表示渲染对象不可得（overlay 已卸载等异常路径）。
Future<Uint8List?> renderWidgetToImage(
  BuildContext context,
  Widget widget, {
  double pixelRatio = 3.0,
}) async {
  final key = GlobalKey();
  late final OverlayEntry entry;
  entry = OverlayEntry(
    builder: (context) => Positioned(
      left: -10000, // 移出屏幕外
      top: -10000,
      child: Material(
        color: Colors.transparent,
        child: RepaintBoundary(key: key, child: widget),
      ),
    ),
  );

  Overlay.of(context).insert(entry);
  try {
    // 等布局/绘制完成；中转 100ms 给图片解码等异步资源，再等一帧让
    // 资源真正上屏。替代旧实现盲等 500ms —— 慢设备上不够、快设备上白等。
    await WidgetsBinding.instance.endOfFrame;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    await WidgetsBinding.instance.endOfFrame;

    final boundary =
        key.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    final image = await boundary.toImage(pixelRatio: pixelRatio);
    try {
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } finally {
      image.dispose();
    }
  } finally {
    entry.remove();
  }
}
