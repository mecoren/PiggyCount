// 启动时云端同步检查的全屏遮罩组件
//
// 设计：
// - 通过 StartupSyncController 推送状态变化
// - overlay 渲染对应状态的卡片（checking / hasUpdates / applying / done / error）
// - 遮罩强制阻断底层交互（AbsorbPointer + barrierDismissible:false）
// - 样式遵循 BeeTokens 设计系统：圆角 16、surfaceElevated 背景、BeeShadows.card 阴影

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../styles/tokens.dart';
import 'startup_sync_checker.dart' show LedgerCandidate, SummaryChoice;

/// 启动同步状态机的状态抽象
sealed class StartupSyncState {}

/// 空闲态：未启动检查
class IdleState extends StartupSyncState {}

/// 检查中：正在逐个账本调 getStatus
class CheckingState extends StartupSyncState {
  final int checked;
  final int total;
  CheckingState({this.checked = 0, this.total = 0});
}

/// 发现更新：等待用户选择 applyAll / confirmEach / skip
class HasUpdatesState extends StartupSyncState {
  final List<LedgerCandidate> candidates;
  final Completer<SummaryChoice> completer;
  HasUpdatesState(this.candidates, this.completer);
}

/// 应用中：applyAll 模式下逐个账本应用
class ApplyingState extends StartupSyncState {
  final int applied;
  final int total;
  final String currentLedgerName;
  final int totalChanges;
  ApplyingState({
    this.applied = 0,
    this.total = 0,
    this.currentLedgerName = '',
    this.totalChanges = 0,
  });
}

/// 完成：显示成功消息后自动 dismiss
class DoneState extends StartupSyncState {
  final String message;
  DoneState(this.message);
}

/// 错误：显示错误消息，用户需点确定关闭
class ErrorState extends StartupSyncState {
  final String message;
  ErrorState(this.message);
}

/// 已关闭：overlay 应该被移除
class DismissedState extends StartupSyncState {}

/// 启动同步状态控制器
///
/// 持有当前状态并通过 ChangeNotifier 通知 overlay 重建。
/// overlay 通过 attach() 挂载到 Overlay，detach() 移除。
class StartupSyncController extends ChangeNotifier {
  StartupSyncState _state = IdleState();
  OverlayEntry? _overlayEntry;
  bool _attached = false;

  StartupSyncState get state => _state;

  void _setState(StartupSyncState s) {
    _state = s;
    notifyListeners();
    _overlayEntry?.markNeedsBuild();
  }

  /// 挂载 overlay 到指定 OverlayState
  void attach(OverlayState overlay) {
    if (_attached) return;
    _overlayEntry = OverlayEntry(
      builder: (ctx) => _StartupSyncOverlayView(controller: this),
    );
    overlay.insert(_overlayEntry!);
    _attached = true;
  }

  /// 移除 overlay
  void detach() {
    _overlayEntry?.remove();
    _overlayEntry = null;
    _attached = false;
  }

  // ===== 状态推送方法 =====

  void startChecking(int total) =>
      _setState(CheckingState(checked: 0, total: total));

  void updateCheckingProgress(int checked, int total) =>
      _setState(CheckingState(checked: checked, total: total));

  void showHasUpdates(
          List<LedgerCandidate> candidates, Completer<SummaryChoice> completer) =>
      _setState(HasUpdatesState(candidates, completer));

  void startApplying(int total) =>
      _setState(ApplyingState(applied: 0, total: total));

  void updateApplyingProgress(
          int applied, int total, String currentLedgerName, int totalChanges) =>
      _setState(ApplyingState(
        applied: applied,
        total: total,
        currentLedgerName: currentLedgerName,
        totalChanges: totalChanges,
      ));

  void done(String message) => _setState(DoneState(message));

  void error(String message) => _setState(ErrorState(message));

  void dismiss() => _setState(DismissedState());
}

/// 遮罩渲染视图
class _StartupSyncOverlayView extends StatelessWidget {
  const _StartupSyncOverlayView({required this.controller});

  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    final state = controller.state;

    // 已关闭或空闲：不渲染
    if (state is DismissedState || state is IdleState) {
      return const SizedBox.shrink();
    }

    return Positioned.fill(
      child: Stack(
        children: [
          // 背景层：AbsorbPointer 吸收穿透事件，阻断底层页面交互
          // 注意：AbsorbPointer 会阻止其子树接收事件，因此只能包裹背景层，
          // 不能包裹卡片层，否则按钮无法点击
          Positioned.fill(
            child: AbsorbPointer(
              child: Container(color: Colors.black.withValues(alpha: 0.55)),
            ),
          ),
          // 卡片层：不包裹在 AbsorbPointer 中，按钮可正常点击
          SafeArea(
            child: Center(
              child: _buildCard(context, state),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCard(BuildContext context, StartupSyncState state) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 360),
      margin: const EdgeInsets.symmetric(horizontal: 24),
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: BeeTokens.surfaceElevated(context),
        borderRadius: BorderRadius.circular(BeeDimens.radius16),
        boxShadow: BeeShadows.card,
      ),
      child: switch (state) {
        CheckingState() => _CheckingView(state: state),
        HasUpdatesState() => _HasUpdatesView(state: state, controller: controller),
        ApplyingState() => _ApplyingView(state: state),
        DoneState() => _DoneView(state: state, controller: controller),
        ErrorState() => _ErrorView(state: state, controller: controller),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

/// 检查中视图：spinner + 进度
class _CheckingView extends StatelessWidget {
  const _CheckingView({required this.state});
  final CheckingState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = state.total > 0 ? state.checked / state.total : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(
            value: state.total > 0 ? progress : null,
            strokeWidth: 3,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.startupSyncCheckCheckingTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        Text(
          state.total > 0
              ? l10n.startupSyncCheckCheckingProgress(state.checked, state.total)
              : l10n.startupSyncCheckCheckingHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: BeeTokens.textSecondary(context),
              ),
        ),
      ],
    );
  }
}

/// 发现更新视图：候选列表 + 三按钮
class _HasUpdatesView extends StatelessWidget {
  const _HasUpdatesView({required this.state, required this.controller});
  final HasUpdatesState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Icon(Icons.cloud_download_outlined,
                color: Theme.of(context).colorScheme.primary, size: 22),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                l10n.startupSyncCheckTitle,
                style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          l10n.startupSyncCheckSummaryMessage(state.candidates.length),
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: BeeTokens.textSecondary(context),
              ),
        ),
        const SizedBox(height: 12),
        ...state.candidates.map(
          (c) => Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Row(
              children: [
                Icon(Icons.book_outlined,
                    size: 14, color: BeeTokens.textTertiary(context)),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    c.ledger.name,
                    style: Theme.of(context).textTheme.bodySmall,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        // 主按钮：一键应用全部
        FilledButton(
          onPressed: () =>
              state.completer.complete(SummaryChoice.applyAll),
          child: Text(l10n.startupSyncCheckApplyAll),
        ),
        const SizedBox(height: 8),
        // 次按钮：逐个确认
        OutlinedButton(
          onPressed: () =>
              state.completer.complete(SummaryChoice.confirmEach),
          child: Text(l10n.startupSyncCheckConfirmEach),
        ),
        const SizedBox(height: 8),
        // 文字按钮：暂不合并
        TextButton(
          onPressed: () => state.completer.complete(SummaryChoice.skip),
          child: Text(l10n.startupSyncCheckSkip),
        ),
      ],
    );
  }
}

/// 应用中视图：spinner + 当前账本名 + 进度
class _ApplyingView extends StatelessWidget {
  const _ApplyingView({required this.state});
  final ApplyingState state;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final progress = state.total > 0 ? state.applied / state.total : 0.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: 40,
          height: 40,
          child: CircularProgressIndicator(
            value: state.total > 0 ? progress : null,
            strokeWidth: 3,
            backgroundColor:
                Theme.of(context).colorScheme.primary.withValues(alpha: 0.15),
          ),
        ),
        const SizedBox(height: 16),
        Text(
          l10n.startupSyncCheckApplyingTitle,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
        const SizedBox(height: 8),
        if (state.currentLedgerName.isNotEmpty)
          Text(
            state.currentLedgerName,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: BeeTokens.textSecondary(context),
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 4),
        if (state.total > 0)
          Text(
            l10n.startupSyncCheckApplyingProgress(state.applied, state.total),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: BeeTokens.textTertiary(context),
                ),
          ),
      ],
    );
  }
}

/// 完成视图：成功图标 + 消息
class _DoneView extends StatelessWidget {
  const _DoneView({required this.state, required this.controller});
  final DoneState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(Icons.check_circle,
            color: BeeTokens.success(context), size: 40),
        const SizedBox(height: 16),
        Text(
          state.message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
              ),
        ),
      ],
    );
  }
}

/// 错误视图：错误图标 + 消息 + 确定按钮
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.state, required this.controller});
  final ErrorState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Icon(Icons.error_outline, color: BeeTokens.error(context), size: 40),
        const SizedBox(height: 16),
        Text(
          state.message,
          textAlign: TextAlign.center,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 20),
        FilledButton(
          onPressed: () => controller.dismiss(),
          child: Text(l10n.commonOk),
        ),
      ],
    );
  }
}
