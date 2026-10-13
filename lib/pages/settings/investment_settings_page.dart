import 'package:flutter/material.dart';
import 'package:flutter_market_data/flutter_market_data.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// 「行情与投资」设置页。
///
/// 三块配置：
/// 1. **行情源**：手动录入 / 东方财富（源名走 l10n，不渲染接口层 `providerName`）；
/// 2. **自动刷新**：主开关 + 刷新频率（后台定时拉取，需自动源）；
/// 3. **立即刷新**：手动触发一次拉取，结果用 toast 反馈。
class InvestmentSettingsPage extends ConsumerStatefulWidget {
  const InvestmentSettingsPage({super.key});

  @override
  ConsumerState<InvestmentSettingsPage> createState() =>
      _InvestmentSettingsPageState();
}

class _InvestmentSettingsPageState
    extends ConsumerState<InvestmentSettingsPage> {
  bool _refreshing = false;

  Future<void> _refreshNow() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      final service = ref.read(quoteServiceProvider);
      final result = await service.refreshQuotes();
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      final String message;
      if (result.updated > 0) {
        message = l10n.investmentRefreshResultUpdated(result.updated);
      } else if (result.failed > 0) {
        message = l10n.investmentRefreshResultFailed;
      } else if (result.excluded > 0) {
        message = l10n.investmentRefreshResultExcluded(result.excluded);
      } else {
        message = l10n.investmentRefreshResultNone;
      }
      showToast(context, message);
    } catch (e) {
      // 兜底：编排层已按类别吞错，这里只防「汇率解析器等外围异常」冒泡成
      // 未捕获错误（否则用户点了按钮既没提示、又有控制台红字）。
      logger.warning('QuoteService', '手动刷新行情异常: $e');
      if (mounted) {
        showToast(context, AppLocalizations.of(context).investmentRefreshResultFailed);
      }
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _pickFrequency() async {
    final l10n = AppLocalizations.of(context);
    final current = ref.read(quoteAutoRefreshSettingsProvider).interval;
    await showPiggyOptionSheet<Duration>(
      context: context,
      title: l10n.investmentRefreshFrequencyLabel,
      selected: current,
      options: [
        for (final d in kQuoteRefreshFrequencies)
          PiggyOptionSheetItem<Duration>(
            value: d,
            title: _frequencyLabel(d, l10n),
          ),
      ],
      onSelected: (d) =>
          ref.read(quoteAutoRefreshSettingsProvider.notifier).setInterval(d),
    );
  }

  static String _frequencyLabel(Duration d, AppLocalizations l10n) {
    switch (d.inMinutes) {
      case 15:
        return l10n.investmentRefreshFrequency15m;
      case 30:
        return l10n.investmentRefreshFrequency30m;
      case 60:
        return l10n.investmentRefreshFrequency1h;
      case 240:
        return l10n.investmentRefreshFrequency4h;
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final currentId = ref.watch(quoteProviderIdProvider);
    final autoRefresh = ref.watch(quoteAutoRefreshSettingsProvider);
    final isManual = currentId == ManualQuoteProvider.id;

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.investmentSettingsTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          PiggyDimens.p16,
          PiggyTokens.topScrollablePadding(context, extra: 16),
          PiggyDimens.p16,
          PiggyDimens.p16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          SettingsSectionLabel(l10n.investmentQuoteSourceSection),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          SettingsCard(
            children: [
              for (final id in kAvailableQuoteProviderIds)
                _QuoteSourceTile(
                  providerId: id,
                  selected: id == currentId,
                  onTap: () =>
                      ref.read(quoteProviderIdProvider.notifier).select(id),
                ),
            ],
          ),
          SizedBox(height: PiggyDimens.p12.scaled(context, ref)),
          Padding(
            padding: EdgeInsets.symmetric(
                horizontal: PiggyDimens.p4.scaled(context, ref)),
            child: Text(
              l10n.investmentQuoteSourceHint,
              style: PiggyTextTokens.caption(context),
            ),
          ),

          SizedBox(height: PiggyDimens.p24.scaled(context, ref)),
          SettingsSectionLabel(l10n.investmentAutoRefreshSection),
          SizedBox(height: PiggyDimens.p8.scaled(context, ref)),
          SettingsCard(
            children: [
              SettingsToggleItem(
                icon: Icons.schedule_rounded,
                useIconBox: true,
                title: l10n.investmentAutoRefreshToggle,
                subtitle: isManual
                    ? l10n.investmentQuoteSourceManualDesc
                    : l10n.investmentAutoRefreshToggleDesc,
                value: autoRefresh.enabled,
                onChanged: (v) => ref
                    .read(quoteAutoRefreshSettingsProvider.notifier)
                    .setEnabled(v),
              ),
              SettingsNavItem(
                icon: Icons.av_timer_rounded,
                useIconBox: true,
                title: l10n.investmentRefreshFrequencyLabel,
                subtitle: _frequencyLabel(autoRefresh.interval, l10n),
                enabled: autoRefresh.enabled,
                onTap: autoRefresh.enabled ? _pickFrequency : null,
              ),
              SettingsNavItem(
                icon: Icons.sync_rounded,
                useIconBox: true,
                title: l10n.investmentRefreshNow,
                subtitle: l10n.investmentRefreshNowDesc,
                enabled: !isManual,
                onTap: (_refreshing || isManual) ? null : _refreshNow,
                trailing: _refreshing
                    ? SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: PiggyTokens.primary(context),
                        ),
                      )
                    : Icon(
                        Icons.refresh_rounded,
                        size: 20,
                        color: PiggyTokens.iconTertiary(context),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 单个行情源选项。
///
/// 直接复用设置页既有的 [SettingsNavItem]（同样的 `horizontal: 16 / vertical: 12`
/// 内边距、`bodyMedium w500` 标题、`bodySmall` 副标题、12px 涟漪圆角），只把
/// trailing 换成单选图标 —— 自绘一行会让本页与设置里其它项的行高、字号、涟漪
/// 形状对不上（设置页组件就是为这种一致性存在的）。
class _QuoteSourceTile extends StatelessWidget {
  const _QuoteSourceTile({
    required this.providerId,
    required this.selected,
    required this.onTap,
  });

  final String providerId;
  final bool selected;
  final VoidCallback onTap;

  /// 行情源 id → (l10n 文案, 图标)。新增行情源时在这里加一个 case。
  ({String title, String subtitle, IconData icon}) _texts(AppLocalizations l10n) {
    switch (providerId) {
      case 'eastmoney':
        return (
          title: l10n.investmentQuoteSourceEastmoney,
          subtitle: l10n.investmentQuoteSourceEastmoneyDesc,
          icon: Icons.query_stats_rounded,
        );
      case 'manual':
      default:
        return (
          title: l10n.investmentQuoteSourceManual,
          subtitle: l10n.investmentQuoteSourceManualDesc,
          icon: Icons.edit_note_rounded,
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final texts = _texts(l10n);

    return SettingsNavItem(
      icon: texts.icon,
      useIconBox: true, // 子页风格（与设置页其它子页一致）
      title: texts.title,
      subtitle: texts.subtitle,
      onTap: onTap,
      trailing: Icon(
        selected
            ? Icons.radio_button_checked_rounded
            : Icons.radio_button_unchecked_rounded,
        size: 20,
        color: selected
            ? PiggyTokens.primary(context)
            : PiggyTokens.textTertiary(context),
      ),
    );
  }
}
