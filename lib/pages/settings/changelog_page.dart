import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';
import 'changelog_data.dart';
import 'changelog_detail_page.dart';

/// 更新日志列表页：按版本倒序列出每次发版，点击进入详情
class ChangelogPage extends ConsumerWidget {
  const ChangelogPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.changelogTitle,
        showBack: true,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16.0.scaled(context, ref),
          PiggyTokens.topScrollablePadding(context, extra: 16),
          16.0.scaled(context, ref),
          16.0.scaled(context, ref) + MediaQuery.of(context).padding.bottom,
        ),
        children: [
          for (final version in kChangelogVersions)
            Padding(
              padding: EdgeInsets.only(bottom: 12.0.scaled(context, ref)),
              child: SettingsCard(
                children: [
                  SettingsNavItem(
                    icon: Icons.new_releases_outlined,
                    title: 'v${version.version}',
                    subtitle: l10n.changelogVersionSubtitle(
                        version.date, version.itemCount),
                    onTap: () {
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => ChangelogDetailPage(version: version),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
