import 'dart:async';

import 'package:flutter/material.dart';
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 统一弹窗（基础 UI 组件）
class AppDialog {
  static Future<T?> confirm<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? cancelLabel,
    String? okLabel,
    VoidCallback? onCancel,
    VoidCallback? onOk,
  }) {
    final l10n = AppLocalizations.of(context);
    cancelLabel ??= l10n.commonCancel;
    okLabel ??= l10n.commonConfirm;
    return _show<T>(
      context,
      title: title,
      message: message,
      actions: [
        (
          label: cancelLabel,
          onTap: () {
            Navigator.pop(context, false);
            if (onCancel != null) onCancel();
          },
          primary: false,
        ),
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
        ),
      ],
    );
  }

  static Future<T?> info<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    return _show<T>(
      context,
      title: title,
      message: message,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
        ),
      ],
    );
  }

  static Future<T?> error<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    return _show<T>(
      context,
      title: title,
      message: message,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
        ),
      ],
    );
  }

  static Future<T?> warning<T>(
    BuildContext context, {
    required String title,
    required String message,
    String? okLabel,
    VoidCallback? onOk,
  }) {
    final l10n = AppLocalizations.of(context);
    okLabel ??= l10n.commonOk;
    return _show<T>(
      context,
      title: title,
      message: message,
      actions: [
        (
          label: okLabel,
          onTap: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          primary: true,
        ),
      ],
    );
  }

  static Future<T?> _show<T>(
    BuildContext context, {
    required String title,
    required String message,
    List<({String label, VoidCallback onTap, bool primary})>? actions,
  }) {
    final l10n = AppLocalizations.of(context);
    actions ??= [
      (label: l10n.commonCancel, onTap: () => Navigator.pop(context), primary: false),
      (label: l10n.commonConfirm, onTap: () => Navigator.pop(context), primary: true),
    ];


    return showDialog<T>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(ctx),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
        contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
        content: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.of(context).size.height * 0.7,
            maxWidth: MediaQuery.of(context).size.width * 0.85,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 1px 顶部高光线，呼应头部语言（onSurface α0.15 暗 / α0.08 亮）
              Align(
                alignment: Alignment.topCenter,
                child: Container(
                  height: 0.5,
                  margin: const EdgeInsets.only(bottom: 16),
                  color: Theme.of(ctx).colorScheme.onSurface.withValues(
                    alpha: PiggyTokens.isDark(ctx) ? 0.15 : 0.08,
                  ),
                ),
              ),
              Text(
                title,
                textAlign: TextAlign.center,
                style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600, color: PiggyTokens.textPrimary(ctx)),
              ),
              const SizedBox(height: 12),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    message.replaceAll('\\n', '\n'),  // 处理转义的换行符
                    textAlign: TextAlign.left,
                    style: Theme.of(ctx).textTheme.bodyMedium?.copyWith(
                      color: PiggyTokens.textSecondary(ctx),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  for (final a in actions!) ...[
                    if (!a.primary)
                      Builder(builder: (context) {
                        final primary = Theme.of(ctx).colorScheme.primary;
                        return OutlinedButton(
                          onPressed: a.onTap,
                          style: OutlinedButton.styleFrom(
                            foregroundColor: primary,
                            side: BorderSide(color: primary),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
                          ),
                          child: Text(a.label),
                        );
                      })
                    else
                      FilledButton(
                          onPressed: a.onTap,
                          style: FilledButton.styleFrom(
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
                          ),
                          child: Text(a.label)),
                    const SizedBox(width: 12),
                  ]
                ],
              ),
              const SizedBox(height: 12),
            ],
          ),
        ),
      ),
    );
  }

}

/// 统一弹窗外壳（Widget 形态）：与 [AppDialog] 系列统一视觉（surfaceElevated
/// 背景 + radiusXl 圆角），title/content/actions 完全由调用方自定义 ——
/// 帮助指南、表单配置等 [AppDialog.info]/[AppDialog.confirm] 纯文本 API
/// 表达不了的弹窗用这个：在 showDialog 的 builder 里返回它（builder 的
/// context 照常可用），或对话框 State.build 直接 return。内容布局由调用方
/// 负责（沿用 Material 默认内边距，与迁移前的手写版一致）。
class AppDialogShell extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;

  const AppDialogShell({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
      title: title,
      content: content,
      actions: actions,
    );
  }
}

/// 阻塞式进度弹窗的句柄：
/// - [status] 可在弹窗存活期间随时更新底部状态文案（如"账本 2/3…"）
/// - [close] 幂等，正常/异常路径统一在 finally 中调用
class BlockingProgressDialogHandle {
  BlockingProgressDialogHandle._(
      this.status, this._navigator, this._dialogFuture);

  final ValueNotifier<String> status;
  final NavigatorState _navigator;
  final Future<void> _dialogFuture;
  bool _closed = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    // navigator 捕获自弹窗弹出时刻：即使调用方 context 已 unmount 也能安全 pop
    if (_navigator.mounted) {
      _navigator.pop();
    }
    await _dialogFuture;
    status.dispose();
  }
}

/// 展示强制阻塞进度弹窗：
/// - barrierDismissible=false 禁止点外部关闭
/// - PopScope(canPop:false) 拦截系统返回键
/// - 弹窗存活期间底层页面完全不可交互，防止同步/上传/重加密过程中
///   用户切换账本或触发并发写操作
/// - 后续 push 的交互弹窗（确认框/diff 预览等）叠在其上仍可正常操作，
///   但必须是 await 完成后才能调用 close()，否则会误关顶层弹窗
///
/// 用法：
/// ```dart
/// final block = showBlockingProgressDialog(context,
///     title: '同步', initialStatus: '正在检查云端账本…');
/// try {
///   await doSyncWork();
///   block.status.value = '新状态';
/// } finally {
///   await block.close();
/// }
/// ```
/// 高危操作双重强制确认：连弹两次 [showDangerConfirmDialog]，
/// 各带 [countdownSeconds] 倒计时，用户两次都点「确认」才放行。
/// - 第一次 [firstMessage]：说明操作范围与后果（如将删除多少数据）
/// - 第二次 [secondMessage]：强调不可恢复，给用户反悔窗口
/// 两次之间取消/倒计时期间返回键均视为放弃，返回 false。
/// 参考全量同步（fullUpload/fullDownload/restore）的既有确认模式。
Future<bool> showDoubleDangerConfirmDialog(
  BuildContext context, {
  required String title,
  required String firstMessage,
  required String secondMessage,
  String? okLabel,
  String? cancelLabel,
  int countdownSeconds = 5,
}) async {
  final first = await showDangerConfirmDialog(
    context,
    title: title,
    message: firstMessage,
    okLabel: okLabel,
    cancelLabel: cancelLabel,
    countdownSeconds: countdownSeconds,
  );
  if (!first || !context.mounted) return false;
  final second = await showDangerConfirmDialog(
    context,
    title: title,
    message: secondMessage,
    okLabel: okLabel,
    cancelLabel: cancelLabel,
    countdownSeconds: countdownSeconds,
  );
  return second;
}

/// 危险操作强制确认弹窗（用于全量覆盖等不可逆操作）：
/// - barrierDismissible=false + PopScope(canPop:false)，点外部/返回键
///   均无法关闭，用户必须在「取消」与「确认」之间显式二选一
/// - 确认按钮在 [countdownSeconds] 倒计时归零前禁用并显示剩余秒数，
///   防止破坏性操作被连续快速点击误触
///
/// 返回 true 表示用户在倒计时结束后确认；false 表示取消。
Future<bool> showDangerConfirmDialog(
  BuildContext context, {
  required String title,
  required String message,
  String? okLabel,
  String? cancelLabel,
  int countdownSeconds = 5,
}) {
  final l10n = AppLocalizations.of(context);
  return showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (dctx) => _DangerConfirmDialog(
      title: title,
      message: message,
      okLabel: okLabel ?? l10n.commonConfirm,
      cancelLabel: cancelLabel ?? l10n.commonCancel,
      countdownSeconds: countdownSeconds,
    ),
  ).then((confirmed) => confirmed ?? false);
}

class _DangerConfirmDialog extends StatefulWidget {
  const _DangerConfirmDialog({
    required this.title,
    required this.message,
    required this.okLabel,
    required this.cancelLabel,
    this.countdownSeconds = 5,
  });

  final String title;
  final String message;
  final String okLabel;
  final String cancelLabel;
  final int countdownSeconds;

  @override
  State<_DangerConfirmDialog> createState() => _DangerConfirmDialogState();
}

class _DangerConfirmDialogState extends State<_DangerConfirmDialog> {
  late int _remaining;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _remaining = widget.countdownSeconds;
    // 倒计时归零前确认按钮保持禁用；用 Timer.periodic 而非循环
    // await，保证弹窗提前关闭时能在 dispose 中取消定时器
    if (_remaining > 0) {
      _timer = Timer.periodic(const Duration(seconds: 1), (t) {
        if (!mounted) {
          t.cancel();
          return;
        }
        setState(() => _remaining--);
        if (_remaining <= 0) t.cancel();
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final errorColor = Theme.of(context).colorScheme.error;
    final enabled = _remaining <= 0;

    return PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(context),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
        title: Column(
          children: [
            Icon(Icons.warning_amber_rounded, color: errorColor, size: 36),
            const SizedBox(height: 8),
            Text(
              widget.title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w600,
                  color: PiggyTokens.textPrimary(context)),
            ),
          ],
        ),
        content: Text(
          widget.message.replaceAll('\\n', '\n'),
          textAlign: TextAlign.left,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: PiggyTokens.textSecondary(context)),
        ),
        actions: [
          OutlinedButton(
            onPressed: () => Navigator.pop(context, false),
            style: OutlinedButton.styleFrom(
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
            ),
            child: Text(widget.cancelLabel),
          ),
          const SizedBox(width: 12),
          FilledButton(
            // 倒计时未结束禁用确认；按钮文案随剩余秒数变化提示等待
            onPressed: enabled ? () => Navigator.pop(context, true) : null,
            style: FilledButton.styleFrom(
              backgroundColor: errorColor,
              disabledBackgroundColor: errorColor.withValues(alpha: 0.35),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
            ),
            child: Text(
              enabled ? widget.okLabel : l10n.dangerConfirmCountdown(_remaining),
            ),
          ),
        ],
      ),
    );
  }
}

BlockingProgressDialogHandle showBlockingProgressDialog(
  BuildContext context, {
  required String title,
  String? initialStatus,
}) {
  final status = ValueNotifier<String>(initialStatus ?? '');
  final navigator = Navigator.of(context, rootNavigator: true);
  final dialogFuture = showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (dctx) => PopScope(
      canPop: false,
      child: AlertDialog(
        backgroundColor: PiggyTokens.surfaceElevated(dctx),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
        title: Text(
          title,
          textAlign: TextAlign.center,
          style: Theme.of(dctx).textTheme.titleMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: PiggyTokens.textPrimary(dctx)),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: 16),
            ValueListenableBuilder<String>(
              valueListenable: status,
              builder: (_, s, __) => s.isEmpty
                  ? const SizedBox.shrink()
                  : Text(
                      s,
                      textAlign: TextAlign.center,
                      style: Theme.of(dctx).textTheme.bodyMedium?.copyWith(
                          color: PiggyTokens.textSecondary(dctx)),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  return BlockingProgressDialogHandle._(status, navigator, dialogFuture);
}
