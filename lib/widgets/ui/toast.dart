import 'dart:async';

import 'package:flutter/material.dart';
import '../../styles/tokens.dart';

/// 当前挂在 Overlay 上的 toast entry。全局单槽：新 toast 顶替旧 toast
/// （替代旧实现的多条叠屏）。
///
/// **不持有 Timer**：定时器归 [_ToastBody] 的 State 所有 —— 顶替时旧 entry
/// 被 remove → 其 State dispose → 定时器随之取消，不会漏一个 timer 去操作
/// 已被顶替的 entry。
OverlayEntry? _activeToastEntry;

/// 幂等移除：到期淡出结束、以及「新 toast 顶替旧 toast」两条路径都会调它，
/// 谁先到都不会重复 remove（[OverlayEntry.remove] 重复调用会断言失败）。
void _removeToast(OverlayEntry entry) {
  if (identical(_activeToastEntry, entry)) _activeToastEntry = null;
  if (entry.mounted) entry.remove();
}

/// 轻量 Toast（基础 UI 工具）：覆盖层展示，不占据布局，不顶起 FAB。
///
/// `duration` 是在屏时长（fade-in 之后、fade-out 之前）；到期后 [_ToastBody]
/// 自己淡出并在动画结束时摘掉 entry，所以提示不会停在屏上。
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

  // 顶替旧 toast：先摘掉旧 entry（其 State dispose 会取消它自己的定时器），
  // 否则新提示会被旧提示的到期回调用旧 entry 摘掉。
  final previous = _activeToastEntry;
  if (previous != null) _removeToast(previous);

  // 先建 body 再建 entry：body 的到期回调需要 entry 本身，故 entry 用 late
  // 局部变量声明（闭包里前向引用普通局部变量会踩「初始化前读取」的编译错误）。
  late final OverlayEntry entry;
  final body = _ToastBody(
    message: message,
    isDark: dark,
    duration: duration,
    onDismissed: () => _removeToast(entry),
  );
  entry = OverlayEntry(
    builder: (ctx) => Positioned.fill(
      child: IgnorePointer(
        ignoring: true,
        child: SafeArea(
          child: Center(child: body),
        ),
      ),
    ),
  );
  _activeToastEntry = entry;
  overlay.insert(entry);
}

/// toast 主体：淡入 200ms → 停留 `duration` → 淡出 240ms → 回调摘掉自己。
///
/// 为什么到期动作放在 State 里而不是外层 Timer：State 的 [dispose] 能顺带
/// 取消未到期的定时器与动画，被顶替 / 页面销毁时都不会留下「迟到 2 秒的回调」
/// 去操作已经不在屏上的 entry。
class _ToastBody extends StatefulWidget {
  final String message;
  final bool isDark;

  /// 在屏时长（不含淡入淡出）。
  final Duration duration;
  final VoidCallback onDismissed;

  const _ToastBody({
    required this.message,
    required this.isDark,
    required this.duration,
    required this.onDismissed,
  });

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

  Timer? _holdTimer;
  bool _dismissing = false;

  @override
  void initState() {
    super.initState();
    _controller.forward();
    _holdTimer = Timer(widget.duration, _fadeOutAndDismiss);
  }

  @override
  void dispose() {
    _holdTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  /// 淡出 →（动画真正走完）→ 通知外层摘掉 entry。
  ///
  /// 不能只靠定时器直接摘 entry：那样提示是**瞬间消失**的，且一旦这个回调
  /// 被推迟（掉帧 / isolate 被 debugger 暂停 / 后台），屏上就留着一条再也
  /// 不会自己走掉的提示 —— 这正是「提示一直存在」的来源。改由动画收尾驱动，
  /// 摘除动作与可见状态始终一致。
  Future<void> _fadeOutAndDismiss() async {
    if (_dismissing || !mounted) return;
    _dismissing = true;
    try {
      // `orCancel`：被顶替 / 销毁导致动画中途取消时以 TickerCanceled 结束等待，
      // 不会像裸 TickerFuture 那样永远不完成而把本方法挂在半路。
      await _controller.reverse().orCancel;
    } on TickerCanceled {
      // entry 已由外层（顶替或页面销毁）摘除，无需再通知。
      return;
    }
    if (mounted) widget.onDismissed();
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
