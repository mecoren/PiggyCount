import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../cloud/sync_metrics_service.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/sync_providers.dart'
    show syncMetricsServiceProvider, syncStatusRefreshProvider;
import '../../providers/theme_providers.dart' show primaryColorProvider;
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/app_list_tile.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/ui/ui.dart';

/// 同步健康卡（审计 P0-1）：近 30 天核心同步场景成功率的本地聚合展示。
///
/// 口径：success / (success + failed + soft_fail)；conflict（并发保护
/// 拦截）单独展示不计入分母；soft_fail（操作成功但数据未收敛，如写后
/// 校验不一致/附件对象云端缺失）单独展示 —— 它是 99.9% 与 99% 之间的
/// 差距主体，用户无需理解内部机制也能看到「同步质量在下降」。
///
/// 隐私（PRIVACY.md 零遥测承诺）：全部数据来自本机 sync_op_log 表，
/// 不上云不自动外发；「导出诊断数据」是唯一出机通道，由用户主动触发
/// 且内容只有结构化指标（无账本名/凭据/内容）。
class SyncHealthCard extends ConsumerWidget {
  const SyncHealthCard({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    // 与页内其他状态卡同源：手动刷新 tick 驱动重聚合
    ref.watch(syncStatusRefreshProvider);
    final metrics = ref.watch(syncMetricsServiceProvider);
    final summaryFuture = metrics.summarize();
    final topErrorsFuture = metrics.topErrorClasses(limit: 3);

    return SectionCard(
      margin: EdgeInsets.zero,
      borderColor: ref.watch(primaryColorProvider),
      child: Column(
        children: [
          FutureBuilder<SyncHealthSummary>(
            future: summaryFuture,
            builder: (context, snap) {
              final data = snap.data;
              final rate = data?.successRate;
              return AppListTile(
                leading: _healthIcon(rate, snap.hasError),
                title: l10n.syncHealthTitle,
                subtitle: _subtitle(context, l10n, data, snap.hasError),
              );
            },
          ),
          FutureBuilder<List<({String errorClass, int count})>>(
            future: topErrorsFuture,
            builder: (context, snap) {
              final top = snap.data ?? const [];
              if (top.isEmpty) return const SizedBox.shrink();
              return Column(
                children: [
                  PiggyTokens.cardDivider(context),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            l10n.syncHealthTopErrors,
                            style: PiggyTextTokens.label(context).copyWith(
                                color: PiggyTokens.textTertiary(context)),
                          ),
                        ),
                      ],
                    ),
                  ),
                  for (final e in top)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 2, 16, 2),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              _errorClassLabel(context, e.errorClass),
                              style: PiggyTextTokens.caption(context),
                            ),
                          ),
                          Text('× ${e.count}',
                              style: PiggyTextTokens.caption(context)),
                        ],
                      ),
                    ),
                ],
              );
            },
          ),
          PiggyTokens.cardDivider(context),
          AppListTile(
            leading: Icons.terminal_outlined,
            title: l10n.syncHealthExport,
            subtitle: l10n.syncHealthEmpty,
            onTap: () => _exportDiagnostics(context, ref),
          ),
        ],
      ),
    );
  }

  IconData _healthIcon(double? rate, bool hasError) {
    if (hasError) return Icons.monitor_heart_outlined;
    if (rate == null) return Icons.monitor_heart_outlined;
    if (rate >= 0.999) return Icons.verified_outlined;
    if (rate >= 0.99) return Icons.check_circle_outline;
    if (rate >= 0.95) return Icons.warning_amber_outlined;
    return Icons.error_outline;
  }

  String? _subtitle(BuildContext context, AppLocalizations l10n,
      SyncHealthSummary? data, bool hasError) {
    if (hasError) return l10n.syncHealthEmpty;
    if (data == null) return null; // 加载中
    if (data.successRate == null) return l10n.syncHealthEmpty;
    final pct = '${(data.successRate! * 100).toStringAsFixed(1)}%';
    return '${l10n.syncHealthRate(pct)}\n'
        '${l10n.syncHealthDetail(data.success, data.failed, data.softFail, data.conflict)}';
  }

  String _errorClassLabel(BuildContext context, String cls) {
    switch (cls) {
      case 'network_timeout':
        return 'Network timeout';
      case 'auth':
        return 'Authentication';
      case 'gateway':
        return 'Remote / gateway';
      case 'precondition':
        return 'Concurrency';
      case 'data_corruption':
        return 'Data integrity';
      default:
        return 'Other';
    }
  }

  /// 诊断导出：sync_op_log 30 天窗口 → JSON 文件 → 系统分享面板。
  /// 文件写入应用文档目录（导出后由分享面板交付，文件本身可被后续导出
  /// 覆盖，不构成残留泄漏面）。
  Future<void> _exportDiagnostics(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context);
    final metrics = ref.read(syncMetricsServiceProvider);
    try {
      final rows = await metrics.exportJson();
      final dir = await getApplicationDocumentsDirectory();
      final ts = DateTime.now().toIso8601String().replaceAll(':', '-');
      final file = File('${dir.path}/piggycount-sync-metrics-$ts.json');
      await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schema': 1,
            'exportedAt': DateTime.now().toUtc().toIso8601String(),
            'note': 'Local sync operation metrics only. No user content.',
            'records': rows,
          }),
          flush: true);
      await Share.shareXFiles([XFile(file.path)]);
      if (context.mounted) {
        await AppDialog.info(context,
            title: l10n.syncHealthTitle,
            message: l10n.syncHealthExported(file.path));
      }
    } catch (e) {
      logger.warning('SyncMetrics', '诊断导出失败: $e');
      if (context.mounted) {
        await AppDialog.error(context,
            title: l10n.syncHealthTitle,
            message: l10n.syncHealthExportFailed('$e'));
      }
    }
  }
}
