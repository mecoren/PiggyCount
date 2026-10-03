import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:piggycount/widgets/biz/piggy_icon.dart';

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import '../../services/system/update_service.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/ui_scale_extensions.dart';
import 'app_icon_page.dart';
import 'changelog_page.dart';
import 'log_center_page.dart';

import '../../utils/platform_info.dart';

/// 是否为 Google Play 版本（通过 CI 构建时 --dart-define=GOOGLE_PLAY=true 注入）
const _isGooglePlayBuild =
    bool.fromEnvironment('GOOGLE_PLAY', defaultValue: false);

/// 关于页面
class AboutPage extends ConsumerStatefulWidget {
  const AboutPage({super.key});

  @override
  ConsumerState<AboutPage> createState() => _AboutPageState();
}

class _AboutPageState extends ConsumerState<AboutPage> {
  String _versionDisplay = '';

  @override
  void initState() {
    super.initState();
    _loadVersion();
  }

  Future<void> _loadVersion() async {
    final info = await _getAppInfo();
    final versionText = info.version.startsWith('dev-')
        ? '${info.version} (${info.buildNumber})'
        : info.version;
    setState(() {
      _versionDisplay = versionText;
    });
  }

  void _showDeveloperStory(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (context) => AppDialogShell(
        wide: true,
        title: Text(l10n.aboutDeveloperStoryTitle),
        content: SingleChildScrollView(
          child: Text(
            l10n.aboutDeveloperStory,
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PiggyTokens.textSecondary(context),
                  height: 1.7,
                ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.aboutPageTitle,
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
          // ===== 顶部:图标 + 应用名 + 版本号(与原版一致)=====
          Padding(
            padding: EdgeInsets.symmetric(
              vertical: 24.0.scaled(context, ref),
            ),
            child: Column(
              children: [
                PiggyIcon(
                  size: 150.0.scaled(context, ref),
                ),
                SizedBox(height: 16.0.scaled(context, ref)),
                GestureDetector(
                  onTap: () => _showDeveloperStory(context),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        l10n.appName,
                        style:
                            Theme.of(context).textTheme.headlineSmall?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: PiggyTokens.textPrimary(context),
                                ),
                      ),
                      SizedBox(width: 4.0.scaled(context, ref)),
                      Icon(
                        Icons.auto_stories_outlined,
                        size: 18.0.scaled(context, ref),
                        color: PiggyTokens.textTertiary(context),
                      ),
                    ],
                  ),
                ),
                SizedBox(height: 8.0.scaled(context, ref)),
                Text(
                  _versionDisplay.isEmpty
                      ? l10n.aboutPageLoadingVersion
                      : _versionDisplay,
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PiggyTokens.textSecondary(context),
                      ),
                ),
              ],
            ),
          ),
          // ===== 功能卡 =====
          SettingsCard(
            children: [
              // iOS 与 Google Play 版本隐藏检查更新(走应用商店分发)
              if (!PlatformInfo.isIOS && !_isGooglePlayBuild)
                Consumer(builder: (context, ref2, child) {
                  final isLoading = ref2.watch(checkUpdateLoadingProvider);
                  final downloadProgress = ref2.watch(updateProgressProvider);

                  bool showProgress = false;
                  String title = l10n.mineCheckUpdate;
                  String? subtitle;
                  IconData icon = Icons.system_update_alt_outlined;
                  Widget? trailing;

                  if (isLoading) {
                    title = l10n.mineCheckUpdateDetecting;
                    subtitle = l10n.mineCheckUpdateSubtitleDetecting;
                    icon = Icons.hourglass_empty;
                    trailing = const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2));
                  } else if (downloadProgress.isActive) {
                    showProgress = true;
                    title = l10n.mineUpdateDownloadTitle;
                    icon = Icons.download_outlined;
                    trailing = SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          value: downloadProgress.progress,
                        ));
                  }

                  return SettingsNavItem(
                    icon: icon,
                    title: title,
                    subtitle: showProgress ? downloadProgress.status : subtitle,
                    trailing: trailing,
                    enabled: !(isLoading || showProgress),
                    onTap: (isLoading || showProgress)
                        ? null
                        : () async {
                            await UpdateService.checkUpdateWithUI(
                              context,
                              setLoading: (loading) => ref2
                                  .read(checkUpdateLoadingProvider.notifier)
                                  .state = loading,
                              setProgress: (progress, status) {
                                if (status.isEmpty) {
                                  ref2
                                      .read(updateProgressProvider.notifier)
                                      .state = UpdateProgress.idle();
                                } else {
                                  ref2
                                          .read(updateProgressProvider.notifier)
                                          .state =
                                      UpdateProgress.active(progress, status);
                                }
                              },
                            );
                          },
                  );
                }),
              SettingsNavItem(
                icon: Icons.app_shortcut,
                title: l10n.appName,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const AppIconPage(),
                    ),
                  );
                },
              ),
              SettingsNavItem(
                icon: Icons.bug_report_outlined,
                title: l10n.logCenterTitle,
                subtitle: l10n.logCenterSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const LogCenterPage(),
                    ),
                  );
                },
              ),
              SettingsNavItem(
                icon: Icons.new_releases_outlined,
                title: l10n.changelogTitle,
                subtitle: l10n.changelogSubtitle,
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const ChangelogPage()),
                  );
                },
              ),
            ],
          ),
          SizedBox(height: 8.0.scaled(context, ref)),
        ],
      ),
    );
  }
}

// -------- 工具方法：关于与更新 --------
class _AppInfo {
  final String version;
  final String buildNumber;
  final String? commit;
  final String? buildTime;
  const _AppInfo(this.version, this.buildNumber, {this.commit, this.buildTime});
}

// 优先读取 CI 注入的 dart-define（CI_VERSION/GIT_COMMIT/BUILD_TIME），否则回退 PackageInfo
Future<_AppInfo> _getAppInfo() async {
  final p = await PackageInfo.fromPlatform();
  final commit = const String.fromEnvironment('GIT_COMMIT');
  final buildTime = const String.fromEnvironment('BUILD_TIME');
  final ciVersion = const String.fromEnvironment('CI_VERSION');

  // 版本号策略：CI版本优先，本地开发显示 "dev-{pubspec版本}"
  final version =
      ciVersion.isNotEmpty ? ciVersion : 'dev-${p.version}'; // 本地开发版本标识

  return _AppInfo(version, p.buildNumber,
      commit: commit.isEmpty ? null : commit,
      buildTime: buildTime.isEmpty ? null : buildTime);
}
