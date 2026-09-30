import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_providers.dart';
import '../../styles/tokens.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../widgets/ui/ui.dart';
import 'changelog_data.dart';

/// 更新日志详情页：版本摘要 + 按功能域分组的变更条目
class ChangelogDetailPage extends ConsumerWidget {
  const ChangelogDetailPage({super.key, required this.version});

  final ChangelogVersion version;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final primary = ref.watch(primaryColorProvider);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: 'v${version.version}',
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
          Text(
            version.date,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: PiggyTokens.textSecondary(context),
                ),
          ),
          SizedBox(height: 4.0.scaled(context, ref)),
          Text(
            version.summary,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PiggyTokens.textPrimary(context),
                  height: 1.6,
                ),
          ),
          SizedBox(height: 16.0.scaled(context, ref)),
          for (final section in version.sections) ...[
            Row(
              children: [
                Icon(section.icon,
                    size: 18.0.scaled(context, ref), color: primary),
                SizedBox(width: 8.0.scaled(context, ref)),
                Text(
                  section.title,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                        color: primary,
                        fontWeight: FontWeight.w600,
                      ),
                ),
              ],
            ),
            SizedBox(height: 8.0.scaled(context, ref)),
            for (final item in section.items)
              Padding(
                padding: EdgeInsets.only(
                  left: 26.0.scaled(context, ref),
                  bottom: 8.0.scaled(context, ref),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 6.0.scaled(context, ref),
                      height: 6.0.scaled(context, ref),
                      margin: EdgeInsets.only(
                        top: 7.0.scaled(context, ref),
                      ),
                      decoration: BoxDecoration(
                        color: PiggyTokens.textSecondary(context)
                            .withValues(alpha: 0.4),
                        shape: BoxShape.circle,
                      ),
                    ),
                    SizedBox(width: 10.0.scaled(context, ref)),
                    Expanded(
                      child: Text(
                        item,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                              color: PiggyTokens.textPrimary(context),
                              height: 1.5,
                            ),
                      ),
                    ),
                  ],
                ),
              ),
            SizedBox(height: 12.0.scaled(context, ref)),
          ],
        ],
      ),
    );
  }
}
