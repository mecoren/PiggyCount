import 'dart:ui';

import 'package:flutter/material.dart';

/// 渐变玻璃背景组件（无级渐变模糊）
///
/// 移植自 wait-home 项目。使用单一 [BackdropFilter] 配合 [ShaderMask]
/// （BlendMode.dstIn）实现无级渐变模糊，避免条带式分段的视觉割裂。
///
/// 原理：
/// - [ClipRect] 限制模糊区域，避免 GPU 模糊整个屏幕（性能关键）
/// - [BackdropFilter] 以 [maxSigma] 模糊背景
/// - [ShaderMask] + [BlendMode.dstIn] 用垂直渐变控制 alpha（顶全显 → 底透明），
///   使模糊层从顶部完整可见平滑过渡到底部完全透明，露出原始内容
/// - 叠加垂直渐变 tint 增强磨砂质感
class GradientBackdropFilter extends StatelessWidget {
  const GradientBackdropFilter({
    super.key,
    this.maxSigma = 20.0,
    this.minSigma = 2.0,
    this.bandCount = _Defaults.bandCount,
    this.maxTintOpacity = _Defaults.maxTintOpacity,
    this.minTintOpacity = _Defaults.minTintOpacity,
    this.opacity = 1.0,
    this.child,
  });

  /// 顶部（最强）模糊 sigma
  final double maxSigma;

  /// 底部（最弱）模糊 sigma（保留参数兼容性，无级模式下由 ShaderMask 渐变控制）
  final double minSigma;

  /// 条带数量（保留参数兼容性，无级模式下不使用）
  final int bandCount;

  /// 顶部 tint 不透明度
  final double maxTintOpacity;

  /// 底部 tint 不透明度
  final double minTintOpacity;

  /// 整体不透明度（0.0=完全透明跳过模糊，1.0=完全显示）。
  ///
  /// 用于滚动驱动渐显：未滚动时传 0.0 跳过 BackdropFilter 计算；
  /// 滚动中传 0.0~1.0 之间的值由 Opacity widget 控制整体显隐。
  /// 模糊 sigma 恒定不变，仅整体透明度变化，保证满帧。
  final double opacity;

  /// 叠加在模糊层之上的前景内容
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // 未滚动时直接跳过整个 BackdropFilter，零模糊开销
    if (opacity <= 0.0) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tintColor = isDark
        ? const Color(0xFF181A22)
        : const Color(0xFFFFFFFF);

    final content = LayoutBuilder(
      builder: (context, constraints) {
        // 无界高度约束时回退为单层模糊，避免 Stack 的 Positioned 断言失败
        if (!constraints.maxHeight.isFinite) {
          return ClipRect(
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: maxSigma,
                sigmaY: maxSigma,
              ),
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: tintColor.withValues(alpha: maxTintOpacity),
                ),
                child: child,
              ),
            ),
          );
        }

        // 无级渐变模糊：ClipRect + BackdropFilter + ShaderMask(dstIn)
        return ClipRect(
          child: Stack(
            children: [
              // 层 1：全模糊背景 + ShaderMask 渐变 alpha（顶全显 → 底透明）
              Positioned.fill(
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: maxSigma,
                    sigmaY: maxSigma,
                  ),
                  child: ShaderMask(
                    shaderCallback: (bounds) => const LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.white,
                        Color(0xD9FFFFFF), // 顶部 1.0 → 中部 0.85 平滑过渡
                        Colors.transparent,
                      ],
                      stops: [0.0, 0.5, 1.0],
                    ).createShader(bounds),
                    blendMode: BlendMode.dstIn,
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            tintColor.withValues(alpha: maxTintOpacity),
                            tintColor.withValues(alpha: minTintOpacity),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              // 层 2：前景内容（不受渐变 alpha 影响）
              if (child != null) Positioned.fill(child: child!),
            ],
          ),
        );
      },
    );

    // opacity == 1.0 时无需 Opacity 包裹，减少一层 widget
    if (opacity >= 1.0) {
      return content;
    }

    // 渐显过程中用 Opacity 控制整体透明度（Impeller 硬件加速）
    return Opacity(opacity: opacity, child: content);
  }
}

/// [GradientBackdropFilter] 默认值集中管理
class _Defaults {
  _Defaults._();

  /// 条带数量（保留参数兼容性，无级模式下不使用）
  static const int bandCount = 4;

  /// 顶部 tint 不透明度
  static const double maxTintOpacity = 0.20;

  /// 底部 tint 不透明度
  static const double minTintOpacity = 0.0;
}
