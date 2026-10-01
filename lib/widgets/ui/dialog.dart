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

    /// 置 true 时走 iOS 警示框样式（左图口径：窄卡片 + 居中标题/说明 +
    /// 底部「取消｜确认」分栏文本按钮，确认侧 error 色），用于删除类确认；
    /// 默认 false 保持原来的 Outlined/Filled 双按钮样式，其他确认框不受影响。
    bool destructive = false,
  }) {
    final l10n = AppLocalizations.of(context);
    cancelLabel ??= l10n.commonCancel;
    okLabel ??= l10n.commonConfirm;
    if (destructive) {
      return showDialog<T>(
        context: context,
        builder: (_) => _IosAlertShell(
          title: title,
          message: message,
          cancelLabel: cancelLabel!,
          onCancel: () {
            Navigator.pop(context, false);
            if (onCancel != null) onCancel();
          },
          okLabel: okLabel!,
          onOk: () {
            Navigator.pop(context, true);
            if (onOk != null) onOk();
          },
          okColor: PiggyTokens.error(context),
        ),
      );
    }
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
      (
        label: l10n.commonCancel,
        onTap: () => Navigator.pop(context),
        primary: false
      ),
      (
        label: l10n.commonConfirm,
        onTap: () => Navigator.pop(context),
        primary: true
      ),
    ];

    return showDialog<T>(
      context: context,
      // 普通确认 / 通知统一走 iOS 外壳：单动作为单个全宽按钮，
      // 双动作为「取消｜确认」分栏（确认侧主题色，非删除类不用红）。
      // 公开 API 最多只产生 2 个动作（confirm/info/error/warning），
      // 防御性取 primary 动作当确认钮。
      builder: (ctx) {
        final all = actions ?? const [];
        final ok = all.firstWhere(
          (a) => a.primary,
          orElse: () => all.last,
        );
        final cancels = all.where((a) => !a.primary).toList();
        return _IosAlertShell(
          title: title,
          message: message,
          cancelLabel: cancels.isEmpty ? null : cancels.first.label,
          onCancel: cancels.isEmpty ? null : cancels.first.onTap,
          okLabel: ok.label,
          onOk: ok.onTap,
          limitMessageHeight: true,
        );
      },
    );
  }
}

/// 统一弹窗外壳（Widget 形态）：与 [AppDialog] 系列**同一套弹窗语言**
/// （surfaceElevated 卡片 + radiusXl 圆角 + 居中标题 + 底部横线分隔的
/// 分栏动作区），title/content/actions 由调用方自定义 —— 表单配置、帮助
/// 指南等 [AppDialog.info]/[AppDialog.confirm] 纯文本 API 表达不了的弹窗
/// 用这个：在 showDialog 的 builder 里返回它（builder 的 context 照常可用），
/// 或对话框 State.build 直接 return。
///
/// 动作区把 [actions] 当**按钮内容**等分成栏（1 个 = 全宽、2 个 = 「左｜右」
/// 各占一半、3 个及以上退回右对齐换行排布）——与 [PiggyDialogActions] 的
/// 视觉一致，所以这里传 `TextButton` 最贴口径；传 Filled/Outlined 大按钮会
/// 在分栏里被拉满整格，属于迁移残留，应改回文本按钮。
///
/// [wide]：表单 / 列表 / 富内容用宽卡片（[PiggyDimens.alertWidthWide]），
/// 窄卡片只放得下提醒类文案（与 iOS 警示框同宽）。
class AppDialogShell extends StatelessWidget {
  final Widget? title;
  final Widget? content;
  final List<Widget> actions;
  final bool wide;

  const AppDialogShell({
    super.key,
    this.title,
    this.content,
    this.actions = const [],
    this.wide = false,
  });

  @override
  Widget build(BuildContext context) {
    final width = wide ? PiggyDimens.alertWidthWide : PiggyDimens.alertWidth;
    return Dialog(
      // 宽度必须写在 Dialog 自身的 constraints 上：Dialog 默认最小宽 280，
      // 内层再套 ConstrainedBox 会被它顶到 280（窄卡片就不是 270 了）。
      constraints: BoxConstraints(minWidth: width, maxWidth: width),
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
      child: Column(
        // 供测试量宽（Dialog 自身的 render box 是全屏，量不到卡片）
        key: const ValueKey('piggyDialogCard'),
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (title != null)
            // 标题**固定**在卡片顶部、不随内容滚动：长列表弹窗（默认账户选择
            // 等）一滚标题就没了，短内容弹窗（选择分享范围）则看不出来 ——
            // 统一固定后所有弹窗的头部样式恒定一致。与底部动作区同一原则：
            // 内容超高时只有内容区滚动。
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p12,
              ),
              child: Center(
                child: IntrinsicWidth(
                  // IntrinsicWidth + Center：「纯文案标题」与「Icon + 文案」
                  // 这类 Row 标题都能在卡片里居中（DefaultTextStyle 的
                  // textAlign 管不到 Row，而 Row 默认会撑满整宽左对齐）。
                  child: DefaultTextStyle.merge(
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w600,
                          color: PiggyTokens.textPrimary(context),
                        ),
                    child: title!,
                  ),
                ),
              ),
            ),
          // 内容超高时整块滚动：标题与动作区始终留在卡片内（不复现
          // 「长文案把按钮顶出屏幕」的旧问题）。
          if (content != null)
            Flexible(
              child: SingleChildScrollView(
                padding: EdgeInsets.fromLTRB(
                  PiggyDimens.p20,
                  title != null ? 0 : PiggyDimens.p20,
                  PiggyDimens.p20,
                  PiggyDimens.p16,
                ),
                child: _alignedContent(context),
              ),
            ),
          if (actions.isNotEmpty) PiggyDialogActionsBar(actions: actions),
        ],
      ),
    );
  }

  /// 内容对齐：纯文案（[Text]）按提醒口径居中，与 [AppDialog] 的说明文案
  /// 一致；表单 / 列表 / 富内容保持调用方自己的版式，不强行改对齐。
  Widget _alignedContent(BuildContext context) {
    final c = content!;
    if (c is Text) {
      return DefaultTextStyle.merge(textAlign: TextAlign.center, child: c);
    }
    return c;
  }
}

/// 对话框底部动作区（Widget 版）：横线 + 等分栏 + 竖线，与
/// [PiggyDialogActions] 同一套视觉，区别只是这里收调用方现成的按钮 Widget
/// 而不是「文案 + 回调」。
///
/// - [AppDialogShell] 内部用它承载 `actions`；
/// - 自绘弹窗（自带标题栏 / 预览区，套不进 [AppDialogShell]）也可以直接用它
///   收尾：按顺序传 `TextButton`（需要 loading / 图标时传自定义按钮）即可，
///   末位按钮自动取主题色、其余取正文色。
///
/// 布局：2 个动作「左｜右」各占一半；3 个及以上竖排整宽行（等分会把
/// 「对比合并」这类长文案挤换行）。
class PiggyDialogActionsBar extends StatelessWidget {
  const PiggyDialogActionsBar({super.key, required this.actions});

  /// 动作按钮（按顺序从左到右 / 从上到下），**末位视作确认**取主题色。
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final hairline = Theme.of(context).colorScheme.onSurface.withValues(
          alpha: PiggyTokens.isDark(context) ? 0.15 : 0.08,
        );

    /// 与 [PiggyDialogActions] 同一配色口径：**末位动作 = 确认**（主题色），
    /// 其余 = 取消类（正文色）；按钮文字统一 bodyLarge（与 AppDialog 一致）。
    /// 调用方在 `Text.style` 里写死的颜色优先（如删除类的 error 色）。
    Widget slot(int index, Widget child) {
      final isOk = index == actions.length - 1;
      return TextButtonTheme(
        data: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: isOk
                ? PiggyTokens.primary(context)
                : PiggyTokens.textPrimary(context),
            textStyle: Theme.of(context).textTheme.bodyLarge,
          ),
        ),
        child: child,
      );
    }

    // 3 个及以上动作（如冲突处理的「取消 / 对比合并 / 强制上传」）竖向排成
    // 整宽行：等分横排会把「对比合并」这类长文案挤到换行，竖向与 iOS 警示框
    // 多动作时的观感一致。
    final Widget rows;
    if (actions.length > 2) {
      rows = Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < actions.length; i++) ...[
            if (i > 0) Container(height: 1, color: hairline),
            SizedBox(height: 48, child: slot(i, actions[i])),
          ],
        ],
      );
    } else {
      rows = IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (var i = 0; i < actions.length; i++) ...[
              if (i > 0) Container(width: 1, color: hairline),
              Expanded(
                child: SizedBox(height: 48, child: slot(i, actions[i])),
              ),
            ],
          ],
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 1, color: hairline),
        ClipRRect(
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(PiggyDimens.radiusXl),
            bottomRight: Radius.circular(PiggyDimens.radiusXl),
          ),
          child: rows,
        ),
      ],
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
/// - iOS 警示框外观：窄卡片 + 居中标题/说明 + 底部「取消｜确认」分栏
///   文本按钮（左图口径），危险侧用 error 色，代替原来的警告图标 +
///   Outlined/Filled 大按钮
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
    final enabled = _remaining <= 0;

    return PopScope(
      canPop: false,
      child: _IosAlertShell(
        title: widget.title,
        message: widget.message,
        cancelLabel: widget.cancelLabel,
        onCancel: () => Navigator.pop(context, false),
        // 倒计时未结束禁用确认；按钮文案随剩余秒数变化提示等待
        okLabel:
            enabled ? widget.okLabel : l10n.dangerConfirmCountdown(_remaining),
        onOk: enabled ? () => Navigator.pop(context, true) : null,
        okColor: PiggyTokens.error(context),
      ),
    );
  }
}

/// 对话框底部 iOS 分栏操作区（左图口径）：横线 +「取消｜确认」左右
/// 等宽文本按钮 + 中间竖线，确认侧默认主题 primary、危险类传 error。
///
/// [_IosAlertShell] 与表单类弹窗（如账本编辑框）共用：表单内容区保持
/// 宽卡片（窄卡片塞不下输入框/导航行），只有底部按钮语言统一。
class PiggyDialogActions extends StatelessWidget {
  const PiggyDialogActions({
    super.key,
    this.cancelLabel,
    this.onCancel,
    required this.okLabel,
    required this.onOk,
    this.okColor,
  }) : assert(
          (cancelLabel == null) == (onCancel == null),
          'cancelLabel 与 onCancel 必须同时传或同时不传（单按钮模式两者皆空）',
        );

  /// 为空 = 单按钮模式：底部单个全宽确认钮，无竖线。
  final String? cancelLabel;
  final VoidCallback? onCancel;
  final String okLabel;
  final VoidCallback? onOk;

  /// 确认钮颜色：空 = 主题 primary；危险类调用方传 error。
  final Color? okColor;

  @override
  Widget build(BuildContext context) {
    final hairline = Theme.of(context).colorScheme.onSurface.withValues(
          alpha: PiggyTokens.isDark(context) ? 0.15 : 0.08,
        );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(height: 1, color: hairline),
        ClipRRect(
          borderRadius: const BorderRadius.only(
            bottomLeft: Radius.circular(PiggyDimens.radiusXl),
            bottomRight: Radius.circular(PiggyDimens.radiusXl),
          ),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (cancelLabel != null)
                  Expanded(
                    child: _DialogActionButton(
                      label: cancelLabel!,
                      color: PiggyTokens.textPrimary(context),
                      onPressed: onCancel,
                    ),
                  ),
                if (cancelLabel != null) Container(width: 1, color: hairline),
                Expanded(
                  child: _DialogActionButton(
                    label: okLabel,
                    color: okColor ?? PiggyTokens.primary(context),
                    onPressed: onOk,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/// iOS 风格警示框外壳（左图口径）：窄卡片 + 标题/说明居中 + 底部
/// [PiggyDialogActions] 分栏按钮。
///
/// 共用方：[_DangerConfirmDialog]（确认侧 error 色 + 倒计时）、
/// `AppDialog.confirm(destructive: true)`（确认侧 error 色）、
/// `AppDialog` 普通确认 / 通知（确认侧主题 primary 色，删除类以外
/// 的确认框只有这一种长相）。
class _IosAlertShell extends StatelessWidget {
  const _IosAlertShell({
    required this.title,
    required this.message,
    this.cancelLabel,
    this.onCancel,
    required this.okLabel,
    required this.onOk,
    this.okColor,
    this.limitMessageHeight = false,
  }) : assert(
          (cancelLabel == null) == (onCancel == null),
          'cancelLabel 与 onCancel 必须同时传或同时不传（单按钮模式两者皆空）',
        );

  final String title;
  final String message;

  /// 为空 = 单按钮模式（通知类）：底部单个全宽确认钮，无竖线。
  final String? cancelLabel;
  final VoidCallback? onCancel;
  final String okLabel;
  final VoidCallback? onOk;

  /// 确认钮颜色：空 = 主题 primary；危险类调用方传 error。
  final Color? okColor;

  /// 说明区限高 + 内部滚动（info/error 文案可能很长，如异常原文，
  /// 不限高会把按钮顶出屏幕）。
  final bool limitMessageHeight;

  @override
  Widget build(BuildContext context) {
    final messageText = Text(
      message.replaceAll('\\n', '\n'),
      textAlign: TextAlign.center,
      style: Theme.of(context)
          .textTheme
          .bodySmall
          ?.copyWith(color: PiggyTokens.textSecondary(context)),
    );
    // iOS 警示框结构（左图口径）：标题 + 说明居中，横线下是按钮区。
    return Dialog(
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: PiggyDimens.alertWidth),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p16,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                        color: PiggyTokens.textPrimary(context)),
                  ),
                  const SizedBox(height: PiggyDimens.p8),
                  if (limitMessageHeight)
                    ConstrainedBox(
                      constraints: BoxConstraints(
                        maxHeight: MediaQuery.of(context).size.height * 0.5,
                      ),
                      child: SingleChildScrollView(child: messageText),
                    )
                  else
                    messageText,
                ],
              ),
            ),
            PiggyDialogActions(
              cancelLabel: cancelLabel,
              onCancel: onCancel,
              okLabel: okLabel,
              onOk: onOk,
              okColor: okColor,
            ),
          ],
        ),
      ),
    );
  }
}

/// 对话框底部文本按钮：无填充无描边，颜色区分语义（取消=正文色，
/// 确认=主题色/危险色），禁用态（倒计时）用三级文字色。
///
/// 注意：文字颜色必须显式写进 [Text.style] —— `bodyLarge` 自带
/// onSurface 默认色，会盖掉按钮 [foregroundColor]（此前「删除」红字
/// 不显示就是这个原因）。
class _DialogActionButton extends StatelessWidget {
  const _DialogActionButton({
    required this.label,
    required this.color,
    required this.onPressed,
  });

  final String label;
  final Color color;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final effectiveColor =
        onPressed == null ? PiggyTokens.textTertiary(context) : color;
    return TextButton(
      onPressed: onPressed,
      style: TextButton.styleFrom(
        foregroundColor: color,
        disabledForegroundColor: PiggyTokens.textTertiary(context),
        padding: const EdgeInsets.symmetric(vertical: PiggyDimens.p12),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: const RoundedRectangleBorder(),
      ),
      child: Text(
        label,
        textAlign: TextAlign.center,
        style: Theme.of(context)
            .textTheme
            .bodyLarge
            ?.copyWith(color: effectiveColor),
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
      // 与其余弹窗同一套外壳语言（居中标题 + 项目卡片），进度态无动作区
      child: AppDialogShell(
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
                      style: Theme.of(dctx)
                          .textTheme
                          .bodyMedium
                          ?.copyWith(color: PiggyTokens.textSecondary(dctx)),
                    ),
            ),
          ],
        ),
      ),
    ),
  );
  return BlockingProgressDialogHandle._(status, navigator, dialogFuture);
}
