import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:progressive_background_blur/progressive_background_blur.dart';

/// 渐变玻璃背景组件（无级渐变模糊）
///
/// 最初移植自 wait-home 项目，2026-10-25 重写为真·渐进模糊。
///
/// 原理（2026-10-25 重写）：
/// - [ClipRect] 限制模糊区域，避免 GPU 模糊整个屏幕（性能关键）
/// - Impeller：[ProgressiveBlur] 用 fragment shader 两遍高斯 + sigma 插值，
///   顶部 [maxSigma] 最模糊 → 底部 0 清晰，是真正的小米/iOS 式渐进模糊
/// - Skia 降级：[BackdropFilter] + 内部 [ShaderMask]（BlendMode.dstIn），
///   仅 tint 顶→底渐隐、模糊量仍均匀（Skia 不支持 shader 背景滤镜，无法渐进）
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
    this.bottomOpaque = false,
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
  /// 滚动中传 0.0~1.0 之间的值会折进渐变 mask 的 alpha（不是 Opacity 包裹）。
  /// 模糊 sigma 恒定不变，仅遮罩透明度变化，保证满帧且 backdrop 始终可读。
  final double opacity;

  /// 是否让底部保持不透明（隔绝下方组件颜色渗透）。
  ///
  /// 为 `false`（默认）时，模糊层从顶部 alpha=1.0 平滑过渡到底部 alpha=0.0，
  /// 露出原始内容（适用于 body 有滚动内容透过标题栏的场景）。
  ///
  /// 为 `true` 时，模糊层全程 alpha=1.0，tint 也全程 `maxTintOpacity`，
  /// 隔绝标题栏下方紧贴的彩色组件颜色（适用于 body 第一个组件是彩色卡片、
  /// 无滚动内容透过的场景，例如设置页/列表页）。
  final bool bottomOpaque;

  /// 叠加在模糊层之上的前景内容
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    // 未滚动时直接跳过整个 BackdropFilter，零模糊开销
    if (opacity <= 0.0) {
      return const SizedBox.shrink();
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tintColor =
        isDark ? const Color(0xFF181A22) : const Color(0xFFFFFFFF);

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

        final tintColors = bottomOpaque
            ? [
                tintColor.withValues(alpha: maxTintOpacity),
                tintColor.withValues(alpha: maxTintOpacity),
              ]
            : [
                tintColor.withValues(alpha: maxTintOpacity),
                tintColor.withValues(alpha: minTintOpacity),
              ];
        final tint = DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: tintColors,
            ),
          ),
        );

        // Impeller：fragment shader 做真·sigma 渐变（底部 0=清晰，顶部 maxSigma 最糊）。
        // Skia 降级：BackdropFilter + 内部 ShaderMask，只有 tint 渐变、模糊仍均匀。
        // 两条路径都禁止用 Opacity 包裹、或把 ShaderMask 套到 BackdropFilter 外：
        // saveLayer 会让 backdrop 读不到下层滚动内容，模糊整块失效
        // （2026-10-25 golden 探针实测 A/B 结构对比）。
        final Widget blurred;
        if (ImageFilter.isShaderFilterSupported) {
          // shader 的 sigma 单位是物理像素（包文档），必须乘 DPR 才与
          // BackdropFilter 的逻辑像素 sigma 观感一致，否则真机上模糊弱 2~3 倍，
          // 顶部该最糊的区域反而看得清文字（2026-10-25 真机实测）。
          final sigmaScale = MediaQuery.devicePixelRatioOf(context);
          final sigma = maxSigma * opacity * sigmaScale;
          blurred = ProgressiveBlur(
            sigmaStart: sigma,
            sigmaEnd: bottomOpaque ? sigma : 0,
            child: tint,
          );
        } else {
          final maskColors = bottomOpaque
              ? const [Colors.white, Colors.white]
              : const [
                  Colors.white,
                  Color(0xD9FFFFFF),
                  Colors.transparent,
                ];
          final maskStops = bottomOpaque ? null : [0.0, 0.5, 1.0];
          blurred = BackdropFilter(
            filter: ImageFilter.blur(
              sigmaX: maxSigma,
              sigmaY: maxSigma,
            ),
            child: ShaderMask(
              shaderCallback: (bounds) => LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  for (final color in maskColors)
                    color.withValues(alpha: color.a * opacity),
                ],
                stops: maskStops,
              ).createShader(bounds),
              blendMode: BlendMode.dstIn,
              child: tint,
            ),
          );
        }

        return ClipRect(
          child: Stack(
            children: [
              Positioned.fill(child: blurred),
              // 前景内容（不受渐变 alpha 影响）
              if (child != null) Positioned.fill(child: child!),
            ],
          ),
        );
      },
    );

    // 整体透明度已折进上方 mask 颜色，这里不再套 Opacity（saveLayer 会弄瞎模糊）
    return content;
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
