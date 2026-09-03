import 'dart:async';

import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

/// 当前挂在 Overlay 上的 toast(entry + 到期 Timer)。
/// 全局单槽:新 toast 顶替旧 toast(替代旧实现的多条叠屏),
/// Timer 随槽一起取消,杜绝到期 remove 已被顶替 entry 的异常。
_ActiveToast? _activeToast;

/// 轻量 Toast（基础 UI 工具）：覆盖层展示，不占据布局，不顶起 FAB
void showToast(BuildContext context, String message,
    {Duration duration = const Duration(seconds: 2)}) {
  showToastOnOverlay(
    Overlay.of(context, rootOverlay: true),
    message,
    duration: duration,
    isDark: PiggyTokens.isDark(context),
  );
}

/// 用指定的 OverlayState 直接弹 Toast —— 给没有就近 BuildContext 的全局场景
/// (如 deep-link 处理:`globalNavigatorKey.currentState?.overlay`)。普通页面
/// 请用 [showToast]。注意不能用 navigator 的 context 走 [showToast],因为它在
/// Overlay 之上,`Overlay.of` 找不到祖先 Overlay 会抛 "No Overlay widget found"。
void showToastOnOverlay(OverlayState overlay, String message,
    {Duration duration = const Duration(seconds: 2), bool? isDark}) {
  final dark = isDark ?? PiggyTokens.isDark(overlay.context);

  // 顶替旧 toast:先移除其 entry 并取消其 Timer。entry.mounted 双保险,
  // 防御已被外部移除的极端情形。
  _activeToast?.dispose();
  _activeToast = null;

  final entry = OverlayEntry(
    builder: (ctx) => Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: SafeArea(
          child: Center(
            child: _ToastBody(message: message, isDark: dark),
          ),
        ),
      ),
    ),
  );
  overlay.insert(entry);

  final timer = Timer(duration, () {
    if (entry.mounted) entry.remove();
    if (identical(_activeToast?.entry, entry)) _activeToast = null;
  });
  _activeToast = _ActiveToast(entry, timer);
}

class _ActiveToast {
  final OverlayEntry entry;
  final Timer timer;
  _ActiveToast(this.entry, this.timer);

  void dispose() {
    timer.cancel();
    if (entry.mounted) entry.remove();
  }
}

/// toast 主体:淡入淡出动画(200ms in / 240ms out)。动画只包内容层,
/// Positioned.fill/IgnorePointer 结构与旧实现一致。
class _ToastBody extends StatefulWidget {
  final String message;
  final bool isDark;
  const _ToastBody({required this.message, required this.isDark});

  @override
  State<_ToastBody> createState() => _ToastBodyState();
}

class _ToastBodyState extends State<_ToastBody>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 200),
    reverseDuration: const Duration(milliseconds: 240),
  );
  late final Animation<double> _opacity =
      CurvedAnimation(parent: _controller, curve: Curves.easeOut);

  @override
  void initState() {
    super.initState();
    _controller.forward();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _opacity,
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.85),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            // 暗黑模式下添加白色阴影，提升可见度
            boxShadow: widget.isDark
                ? [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.2),
                      blurRadius: 8,
                      spreadRadius: 1,
                    ),
                  ]
                : null,
          ),
          child: Text(
            widget.message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Colors.white),
          ),
        ),
      ),
    );
  }
}
