import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/database_health_service.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/database_providers.dart';
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import '../ui/piggy_spinner.dart';

/// 正在执行的恢复动作；null 表示空闲。
///
/// 不能只用一个裸 bool：导出与重置是两条互斥路径，共享 bool 时只能让整块面板
/// 一起转，看不出「到底在导出还是在重置」。这里记下具体动作，转圈才能画在
/// **真正在跑的那个按钮**上。
enum _BusyOp { export, reset }

/// 本地数据库异常时的全屏恢复引导（审计 P1-6）。
///
/// 为什么必须由这一层给出：库不可用时，应用里**所有依赖数据库的页面都渲染不出
/// 内容**（查询全部失败），用户看到的是"数据凭空消失"。因此提示不能依赖任何
/// DB 读取路径，只能挂在 `MaterialApp.builder` 的 Stack 顶层。
///
/// 为什么不用 [AppDialog]：本组件位于 `MaterialApp.builder`，其 context 在
/// Navigator **之上**，`Navigator.of` 取不到栈（项目因此才用 globalNavigatorKey）。
/// 故确认步骤与结果反馈全部内联渲染，不依赖 Navigator。
///
/// 为什么**不**提供「从云端备份恢复」入口：云端恢复本身要往本地库里写，
/// 库坏时它必然失败。正确顺序是「导出留存 → 重置 → 重启 →（重启后）云端恢复」，
/// 而最后一步应在重启后的「云服务」页做。摆一个点不通的主按钮只会让用户
/// 反复失败、失去信任，所以这里只保留前两步。
///
/// 安全边界：本组件**只读**健康状态；唯一的写操作是 [DatabaseHealthService.quarantine]，
/// 且必须经用户二次确认。它只移动、不删除，且不在此处重建数据库——重建需要
/// 进程重启，硬换库会把正在持有旧文件句柄的 provider 弄成半死状态。
class DatabaseRecoveryOverlay extends ConsumerStatefulWidget {
  const DatabaseRecoveryOverlay({super.key});

  @override
  ConsumerState<DatabaseRecoveryOverlay> createState() =>
      _DatabaseRecoveryOverlayState();
}

class _DatabaseRecoveryOverlayState
    extends ConsumerState<DatabaseRecoveryOverlay> {
  _BusyOp? _busyOp;

  bool get _busy => _busyOp != null;
  bool _confirmingReset = false;

  /// 内联结果反馈（不弹 dialog：见类注释）。
  String? _status;

  @override
  Widget build(BuildContext context) {
    final health = ref.watch(dbHealthProvider).valueOrNull;
    final dismissed = ref.watch(dbHealthDismissedProvider);
    // 加载中 / 健康 / 用户已选择稍后处理 → 不占屏
    if (health == null || health.isHealthy || dismissed) {
      return const SizedBox.shrink();
    }

    final l10n = AppLocalizations.of(context);
    final isCorrupted = health.health == DbHealth.corrupted;

    return Positioned.fill(
      child: Material(
        color: PiggyTokens.surfaceSecondary(context),
        child: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.storage_rounded,
                      size: 48,
                      color: PiggyTokens.warning(context),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      l10n.dbHealthCorruptTitle,
                      textAlign: TextAlign.center,
                      style: PiggyTextTokens.strongTitle(context),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      isCorrupted
                          ? l10n.dbHealthCorruptBodyCorrupted
                          : l10n.dbHealthCorruptBodyUnreadable,
                      style: PiggyTextTokens.body(context)
                          .copyWith(color: PiggyTokens.textSecondary(context)),
                    ),
                    if (_status != null) ...[
                      const SizedBox(height: 16),
                      Text(
                        _status!,
                        style: PiggyTextTokens.caption(context),
                      ),
                    ],
                    const SizedBox(height: 20),
                    if (_confirmingReset)
                      _buildResetConfirm(context, l10n)
                    else
                      _buildActions(context, l10n),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// 动作按**正确执行顺序**排列：先导出留存（只读、无风险、不可逆性最高的一步
  /// 必须先做），再重置（二次确认），最后才是「稍后处理」。
  Widget _buildActions(BuildContext context, AppLocalizations l10n) {
    final iconColor = PiggyTokens.iconPrimary(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        OutlinedButton.icon(
          onPressed: _busy ? null : _export,
          // 唯一的进行中反馈：这是一个用户会紧张的全屏流程（数据疑似损坏），
          // 按钮整体变灰会让用户以为界面卡住了。
          icon: _busyOp == _BusyOp.export
              ? PiggySpinner(size: 18, color: iconColor)
              : const Icon(Icons.ios_share_outlined),
          label: Text(l10n.dbHealthActionExport),
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed:
              _busy ? null : () => setState(() => _confirmingReset = true),
          style: FilledButton.styleFrom(
            backgroundColor: PiggyTokens.warning(context),
          ),
          icon: const Icon(Icons.restart_alt_rounded),
          label: Text(l10n.dbHealthActionReset),
        ),
        const SizedBox(height: 8),
        // 「稍后处理」只作用于本次会话：不持久化，下次启动仍提示，
        // 避免损坏被永久静默。
        TextButton(
          onPressed: _busy
              ? null
              : () => ref.read(dbHealthDismissedProvider.notifier).state = true,
          child: Text(l10n.dbHealthActionLater),
        ),
      ],
    );
  }

  Widget _buildResetConfirm(BuildContext context, AppLocalizations l10n) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          l10n.dbHealthResetConfirmTitle,
          style: PiggyTextTokens.title(context),
        ),
        const SizedBox(height: 8),
        Text(
          l10n.dbHealthResetConfirmMessage,
          style: PiggyTextTokens.body(context)
              .copyWith(color: PiggyTokens.textSecondary(context)),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _busy ? null : _reset,
          style: FilledButton.styleFrom(
            backgroundColor: PiggyTokens.warning(context),
          ),
          child: _busyOp == _BusyOp.reset
              // 重置是不可逆操作，转圈必须画在确认键本体上，不能只让面板变灰。
              ? PiggySpinner(
                  size: 18,
                  color: PiggyTokens.textOnPrimary(context),
                )
              : Text(l10n.commonConfirm),
        ),
        const SizedBox(height: 8),
        TextButton(
          onPressed:
              _busy ? null : () => setState(() => _confirmingReset = false),
          child: Text(l10n.commonCancel),
        ),
      ],
    );
  }

  Future<void> _export() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyOp = _BusyOp.export);
    try {
      final path = await DatabaseHealthService.exportCopy();
      if (path == null) {
        if (mounted) {
          setState(() => _status = l10n.dbHealthExportFailed('file not found'));
        }
        return;
      }
      await SharePlus.instance.share(ShareParams(files: [XFile(path)]));
      if (mounted) setState(() => _status = l10n.dbHealthExported(path));
    } catch (e) {
      logger.warning('DbHealth', '导出损坏数据库失败: $e');
      if (mounted) setState(() => _status = l10n.dbHealthExportFailed('$e'));
    } finally {
      if (mounted) setState(() => _busyOp = null);
    }
  }

  Future<void> _reset() async {
    final l10n = AppLocalizations.of(context);
    setState(() => _busyOp = _BusyOp.reset);
    try {
      final dir = await DatabaseHealthService.quarantine();
      if (dir == null) {
        if (mounted) {
          setState(() {
            _status = l10n.dbHealthResetFailed('file not found');
            _confirmingReset = false;
          });
        }
        return;
      }
      logger.warning('DbHealth', '用户已重置本地数据库，损坏文件保留于 $dir');
      if (mounted) {
        setState(() {
          _status = l10n.dbHealthResetDone(dir);
          _confirmingReset = false;
        });
      }
    } catch (e) {
      logger.error('DbHealth', '重置本地数据库失败', e);
      if (mounted) {
        setState(() {
          _status = l10n.dbHealthResetFailed('$e');
          _confirmingReset = false;
        });
      }
    } finally {
      if (mounted) setState(() => _busyOp = null);
    }
  }
}
