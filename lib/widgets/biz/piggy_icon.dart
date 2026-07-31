import 'package:flutter/material.dart';

/// 应用图标 widget。
///
/// 历史上基于 `assets/piggy.svg`（SVG + currentColor 着色），
/// 现已改为统一的透明背景 PNG 主图标 `assets/icon/icon_master.png`，
/// 不再支持主题色着色（新图标本身为彩色插画）。
class PiggyIcon extends StatelessWidget {
  final double size;

  const PiggyIcon({super.key, this.size = 256});

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      'assets/icon/icon_master.png',
      width: size,
      height: size,
      fit: BoxFit.contain,
    );
  }
}
