import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../transaction/recurring_transaction_page.dart';
import '../settings/reminder_settings_page.dart';
import '../../l10n/app_localizations.dart';

/// 自动化功能二级页面
class AutomationPage extends ConsumerWidget {
  const AutomationPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.automationPageTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 56 + 16,
          16,
          16 + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          SettingsCard(
            children: [
              // 周期记账
              SettingsNavItem(
                icon: Icons.repeat,
                title: l10n.mineRecurringTransactions,
                subtitle: l10n.mineRecurringTransactionsSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const RecurringTransactionPage()),
                  );
                },
              ),
              // 记账提醒
              SettingsNavItem(
                icon: Icons.notifications_outlined,
                title: l10n.mineReminderSettings,
                subtitle: l10n.mineReminderSettingsSubtitle,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const ReminderSettingsPage()),
                  );
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
