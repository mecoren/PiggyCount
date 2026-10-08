import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';

/// 「行情与投资」设置页（v52 预留）。
///
/// 当前只有一项可配：**行情源**（唯一选项是「手动录入」）。
/// 这个页面存在的意义是把「后期接实时行情」的入口先建好 —— 那时只需在
/// `kAvailableQuoteProviderIds` 里加一个 id 并实现对应 `QuoteProvider` 子包，
/// 选项会自动出现在这里，无需改本页。
///
/// 文案全部走 l10n；**不渲染接口层的 `providerName`**（那是开发者可读名，
/// 直接显示会让中文界面出现英文源名）。
class InvestmentSettingsPage extends ConsumerWidget {
  const InvestmentSettingsPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final currentId = ref.watch(quoteProviderIdProvider);

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
