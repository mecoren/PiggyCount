// 启动时云端同步检查的全屏遮罩组件
//
// 设计：
// - 通过 StartupSyncController 推送状态变化
// - overlay 渲染对应状态的卡片（checking / hasUpdates / applying / done）
// - 遮罩强制阻断底层交互（AbsorbPointer + barrierDismissible:false）
// - 样式遵循 PiggyTokens 设计系统：PiggyDimens.alertWidth(Wide) 卡片宽度、
//   radiusXl 圆角、surfaceElevated 背景、PiggyShadows.card 阴影；
//   错误 / 信息两种**通知态**走 [_AlertBody]（与 AppDialog 同一套
//   「标题 + 说明 + 底部分栏按钮」版式）

import 'dart:async';

import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../styles/tokens.dart';
import '../widgets/ui/dialog.dart';
import '../widgets/ui/piggy_spinner.dart';
import 'startup_sync_checker.dart' show LedgerCandidate, SummaryChoice;
import 'sync_service.dart' show SyncDiff;

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
///
/// [infoMessage]（可空）：另有账本存在**不会自动合并**的差异（方向未知的
/// 云端账本元信息差异）时的一行提示，仅为告知，不参与任何自动动作。
class HasUpdatesState extends StartupSyncState {
  final List<LedgerCandidate> candidates;
  final Completer<SummaryChoice> completer;
  final String? infoMessage;
  HasUpdatesState(this.candidates, this.completer, {this.infoMessage});
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

/// 错误：显示错误标题 + 消息，用户需点确定关闭
///
/// 版式与 [_AlertBody]（= AppDialog 的 iOS 警示框口径），不要退回
/// 「图标 + 居中文字 + FilledButton」的自绘弹窗。
class ErrorState extends StartupSyncState {
  final String title;
  final String message;
  ErrorState({required this.title, required this.message});
}

/// 信息：无需自动合并，但要明确告诉用户「差在哪、去哪处理」。
///
/// 用于「云端账本信息与本地不同」这类**方向未知**的差异：启动检查刻意不自动
/// 合并（避免覆盖本地改动），但静默关闭会让用户看到「我的」页写着有差异、
/// 点进下载同步却一条变更都列不出来（交易级 diff 为空），只能自己猜。
class InfoState extends StartupSyncState {
  /// 标题（例：云端账本信息与本地不同）
  final String title;

  /// 明细行（例：「日常账」→「家庭账」；本地与云端逐条对照）
  final List<String> lines;

  /// 操作说明（例：启动检查不会自动合并，请到「我的 → 云同步」手动处理）
  final String action;

  InfoState({required this.title, required this.lines, required this.action});
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
  OverlayState? _overlay;
  bool _attached = false;

  /// 用户取消请求（W1）：检查阶段用户点了「取消」后置 true。
  /// 编排器在检查完成后轮询 [cancelRequested] 静默退出；overlay 侧的
  /// 迟到进度推送由 [updateCheckingProgress] 的 isCancelled 分支拦截，
  /// 不会复活已关闭的遮罩。
  bool _cancelRequested = false;

  bool get cancelRequested => _cancelRequested;

  /// 请求取消：关闭遮罩并标记取消（编排器据此静默退出检查流程）。
  /// 仅检查阶段（CheckingState）有效；下载/应用阶段涉及本地数据
  /// 一致性，不允许中途取消。
  void requestCancel() {
    if (_state is! CheckingState) return;
    _cancelRequested = true;
    _setState(DismissedState());
  }

  /// 开始新一轮检查前重置取消标记（reattach/salt 恢复重入场景）。
  void _resetCancel() => _cancelRequested = false;

  StartupSyncState get state => _state;

  void _setState(StartupSyncState s) {
    _state = s;
    notifyListeners();
    _overlayEntry?.markNeedsBuild();
  }

  /// 挂载 overlay 到指定 OverlayState
  void attach(OverlayState overlay) {
    if (_attached) return;
    _overlay = overlay;
    _overlayEntry = OverlayEntry(
      builder: (ctx) => _StartupSyncOverlayView(controller: this),
    );
    overlay.insert(_overlayEntry!);
    _attached = true;
  }

  /// 重新挂载 overlay（detach 后再次显示）
  ///
  /// 用于 salt_mismatch 恢复流程：先 dismiss 关掉遮罩弹密码框，
  /// 激活成功后重新挂载遮罩，让用户能看到后续检查进度/结果，
  /// 避免「输入密码后无任何反馈」的体验缺陷。
  void reattach() {
    if (_attached) return;
    final overlay = _overlay;
    if (overlay == null) return;
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

  @override
  void dispose() {
    // 资源释放：先移除 overlay entry 防止悬挂引用，再释放 ChangeNotifier
    detach();
    super.dispose();
  }

  // ===== 状态推送方法 =====

  void startChecking(int total) {
    _resetCancel();
    _setState(CheckingState(checked: 0, total: total));
  }

  void updateCheckingProgress(int checked, int total) {
    // 取消后迟到的完成回调不再推送，避免复活已关闭的遮罩
    if (_cancelRequested) return;
    _setState(CheckingState(checked: checked, total: total));
  }

  void showHasUpdates(
          List<LedgerCandidate> candidates, Completer<SummaryChoice> completer,
          {String? infoMessage}) =>
      _setState(
          HasUpdatesState(candidates, completer, infoMessage: infoMessage));

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

  void error({required String title, required String message}) =>
      _setState(ErrorState(title: title, message: message));

  /// 信息态：明确告知「差在哪、去哪处理」，**不自动消失**（用户需自行阅读
  /// 并决定是否去云同步页处理），点「确定」关闭。
  void info({
    required String title,
    required List<String> lines,
    required String action,
  }) =>
      _setState(InfoState(title: title, lines: lines, action: action));

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
    // 通知态（错误 / 信息）用窄卡片 + **零内边距**：内部 [_AlertBody] 自带
    // 文案留白，底部分栏动作区的横线与圆角裁切必须贴卡片边缘才与
    // AppDialog 一致；进度 / 候选态仍留内容留白，卡片宽度走宽档。
    final isAlert = state is ErrorState || state is InfoState;
    return Container(
      constraints: BoxConstraints(
        maxWidth: isAlert ? PiggyDimens.alertWidth : PiggyDimens.alertWidthWide,
      ),
      margin: const EdgeInsets.symmetric(horizontal: PiggyDimens.p24),
      padding:
          isAlert ? EdgeInsets.zero : const EdgeInsets.all(PiggyDimens.p24),
      decoration: BoxDecoration(
        color: PiggyTokens.surfaceElevated(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        boxShadow: PiggyShadows.card,
      ),
      child: switch (state) {
        CheckingState() => _CheckingView(state: state, controller: controller),
        HasUpdatesState() =>
          _HasUpdatesView(state: state, controller: controller),
        ApplyingState() => _ApplyingView(state: state),
        DoneState() => _DoneView(state: state, controller: controller),
        ErrorState() => _ErrorView(state: state, controller: controller),
        InfoState() => _InfoView(state: state, controller: controller),
        _ => const SizedBox.shrink(),
      },
    );
  }
}

/// 检查中视图：spinner + 进度 + 取消按钮
///
/// W1：云端不可达时并行检查仍需等待单个 _statusTimeout（约 20s），
/// 遮罩期间 App 不可操作；提供「取消」让用户先进入 App，稍后可在
/// 云同步页手动检查。仅探测阶段可取消——下载/应用涉及本地数据
/// 一致性，中途放弃风险更高。
class _CheckingView extends StatelessWidget {
  const _CheckingView({required this.state, required this.controller});
  final CheckingState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 这里原本是带 value 的 CircularProgressIndicator(checked/total)，
        // 但 [checked]/[total] 已由下方 startupSyncCheckCheckingProgress 文案
        // 明确给出，环上的进度弧是纯冗余，故改用统一的不定态 PiggySpinner，
        // 不会丢失任何进度信息。
        PiggySpinner(size: 40, color: PiggyTokens.primary(context)),
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
              ? l10n.startupSyncCheckCheckingProgress(
                  state.checked, state.total)
              : l10n.startupSyncCheckCheckingHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PiggyTokens.textSecondary(context),
              ),
        ),
        const SizedBox(height: 16),
        TextButton(
          onPressed: () => controller.requestCancel(),
          child: Text(l10n.commonCancel),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.startupSyncCheckCancelHint,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PiggyTokens.textTertiary(context),
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
                color: PiggyTokens.textSecondary(context),
              ),
        ),
        // 另有账本存在「不会自动合并」的差异（方向未知的云端账本元信息差异）：
        // 只提示，不参与任何自动动作 —— 用户可在本次合并后去云同步页处理。
        if (state.infoMessage != null) ...[
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(Icons.info_outline,
                  size: 14, color: PiggyTokens.textTertiary(context)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  state.infoMessage!,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PiggyTokens.textTertiary(context),
                      ),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        // 审计 U7：候选列表数量无上限，小屏/大字号下不可滚动 Column
        // 会纵向溢出（RenderFlex overflow）。限高 + 列表段可滚动，
        // 按钮区保持固定在滚动区外。
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                ...state.candidates.map(
                  (c) {
                    // US-7: 对 different 账本显示警告图标 + tooltip
                    // cloudNewer/localNewer 为单向覆盖，无冲突，保持原样
                    final isConflict = c.diffType == SyncDiff.different;
                    return Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Row(
                        children: [
                          Icon(
                            isConflict
                                ? Icons.warning_amber
                                : Icons.book_outlined,
                            size: 14,
                            color: isConflict
                                ? PiggyTokens.warning(context)
                                : PiggyTokens.textTertiary(context),
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              c.ledger.name,
                              style: Theme.of(context).textTheme.bodySmall,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (isConflict)
                            Tooltip(
                              message: l10n.startupSyncConflictTooltip,
                              child: Icon(
                                Icons.info_outline,
                                size: 12,
                                color: PiggyTokens.textTertiary(context),
                              ),
                            ),
                        ],
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 20),
        // 主按钮：一键应用全部
        FilledButton(
          onPressed: () => state.completer.complete(SummaryChoice.applyAll),
          child: Text(l10n.startupSyncCheckApplyAll),
        ),
        const SizedBox(height: 8),
        // 次按钮：逐个确认
        OutlinedButton(
          onPressed: () => state.completer.complete(SummaryChoice.confirmEach),
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
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 同 _CheckingView：applied/total 由下方文案承载，环只表示「在动」。
        PiggySpinner(size: 40, color: PiggyTokens.primary(context)),
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
                  color: PiggyTokens.textSecondary(context),
                ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        const SizedBox(height: 4),
        if (state.total > 0)
          Text(
            l10n.startupSyncCheckApplyingProgress(state.applied, state.total),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PiggyTokens.textTertiary(context),
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
        Icon(Icons.check_circle, color: PiggyTokens.success(context), size: 40),
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

/// 错误视图：标题 + 消息 + 确定按钮（版式见 [_AlertBody]）
class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.state, required this.controller});
  final ErrorState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    return _AlertBody(
      title: state.title,
      message: state.message,
      onOk: controller.dismiss,
    );
  }
}

/// 通知态统一版式（错误 / 信息共用）：与 `AppDialog` / `AppDialogShell`
/// 同一套弹窗语言 —— 标题 `titleLarge w600` 居中 + 说明 `bodySmall` 三级色
/// 居中 + 底部 [PiggyDialogActions] 单按钮分栏（通知类无取消侧，全宽确认钮）。
///
/// 说明区限高 + 内部滚动：失败文案可能带异常原文，不限高会把底部按钮顶出
/// 屏幕（与 `AppDialog.info/error` 的 limitMessageHeight 同一考量）。
class _AlertBody extends StatelessWidget {
  const _AlertBody({
    required this.title,
    required this.message,
    required this.onOk,
  });

  final String title;
  final String message;
  final VoidCallback onOk;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Column(
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
                      color: PiggyTokens.textPrimary(context),
                    ),
              ),
              const SizedBox(height: PiggyDimens.p8),
              Flexible(
                child: SingleChildScrollView(
                  child: Text(
                    message,
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PiggyTokens.textSecondary(context),
                        ),
                  ),
                ),
              ),
            ],
          ),
        ),
        PiggyDialogActions(
          okLabel: l10n.commonOk,
          onOk: onOk,
        ),
      ],
    );
  }
}

/// 信息视图：标题 + 差异明细 + 操作说明 + 确定按钮（版式见 [_AlertBody]）
///
/// 与 [_ErrorView] 的区别：这不是错误（检查链路本身工作正常），而是「有需要你
/// 手动处理的事」—— 故**不自动消失**（用户要读完并决定是否去云同步页处理），
/// 点「确定」关闭。
class _InfoView extends StatelessWidget {
  const _InfoView({required this.state, required this.controller});
  final InfoState state;
  final StartupSyncController controller;

  @override
  Widget build(BuildContext context) {
    // 账本数量无上限：明细逐条换行拼进说明区，由 [_AlertBody] 统一限高滚动
    // （不再需要单独的可滚动列表段）。action 无条件保留（明细为空时
    // join 结果即 action 本身），否则会丢操作说明。
    final message = <String>[...state.lines, state.action].join('\n');
    return _AlertBody(
      title: state.title,
      message: message,
      onOk: controller.dismiss,
    );
  }
}
