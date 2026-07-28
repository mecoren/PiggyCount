import 'dart:io' show Platform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../styles/tokens.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import '../../cloud/sync_service.dart';
import '../cloud/cloud_service_page.dart';
import '../../services/system/logger_service.dart';
import '../settings/help_center_page.dart';
import '../../services/export/share_poster_service.dart';
import '../../l10n/app_localizations.dart';
import '../cloud/cloud_sync_page.dart';
import '../cloud/beecount_cloud_sync_page.dart';
import '../../utils/website_urls.dart';
import '../../providers/github_star_provider.dart';
import '../settings/data_management_page.dart';
import '../settings/appearance_settings_page.dart';
import '../settings/smart_billing_page.dart';
import '../settings/automation_page.dart';
import '../settings/about_page.dart';
import '../report/annual_report_page.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:in_app_review/in_app_review.dart';
import '../../utils/ui_scale_extensions.dart';
import '../donation/donation_page.dart';

/// 我的页面（设置主页）
///
/// UI 改造：参考 wait-home 项目风格，使用 GlassTitleBar + ListView + 卡片化布局。
/// 头部内容（头像/问候语/统计）抽取为 ProfileCard，设置项使用 SettingsCard +
/// SettingsNavItem。所有原有功能逻辑（云同步状态、iOS 专属项、GitHub Star 等）完整保留。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    final l10n = AppLocalizations.of(context);

    return Scaffold(
      backgroundColor: BeeTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: GlassTitleBar(
        title: l10n.mineTitle,
        showBack: false,
        showMenu: false,
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 56 + 16,
          16,
          16 + MediaQuery.of(context).padding.bottom + 56 + 12,
        ),
        physics: const AlwaysScrollableScrollPhysics(),
        children: [
          // 头部用户信息卡片（头像 + 问候语 + 统计）
          const ProfileCard(),
          SizedBox(height: 24.0.scaled(context, ref)),

          // ── 云同步与备份 ──
          SettingsSectionLabel(l10n.mineCloudBackupSection),
          SizedBox(height: 8.0.scaled(context, ref)),
          Consumer(builder: (sectionContext, sectionRef, _) {
            final activeCfg = sectionRef.watch(activeCloudConfigProvider);

            return SettingsCard(
              children: [
                // 云服务 —— BeeCount Cloud 模式下 subtitle 带上
                // server 版本号(从 fetchServerVersion 拉的 FutureProvider),
                // 一眼看到 cloud 哪版。其它模式没版本概念,保留原文案。
                Consumer(builder: (ctx, r, _) {
                  final cloudVersion =
                      r.watch(beecountCloudServerVersionProvider).valueOrNull;
                  return SettingsNavItem(
                    icon: Icons.cloud_queue_outlined,
                    title: AppLocalizations.of(sectionContext).mineCloudService,
                    subtitle: activeCfg.when(
                      loading: () => AppLocalizations.of(sectionContext)
                          .mineCloudServiceLoading,
                      error: (e, _) =>
                          '${AppLocalizations.of(sectionContext).commonError}: $e',
                      data: (cfg) {
                        switch (cfg.type) {
                          case CloudBackendType.local:
                            return AppLocalizations.of(sectionContext)
                                .mineCloudServiceOffline;
                          case CloudBackendType.webdav:
                            return AppLocalizations.of(sectionContext)
                                .mineCloudServiceWebDAV;
                          case CloudBackendType.icloud:
                            return 'iCloud';
                          case CloudBackendType.supabase:
                            return AppLocalizations.of(sectionContext)
                                .mineCloudServiceCustom;
                          case CloudBackendType.s3:
                            return 'S3';
                          case CloudBackendType.beecountCloud:
                            return cloudVersion != null && cloudVersion.isNotEmpty
                                ? 'BeeCount Cloud v$cloudVersion'
                                : 'BeeCount Cloud';
                        }
                      },
                    ),
                    onTap: () async {
                      await Navigator.of(sectionContext).push(
                        MaterialPageRoute(
                            builder: (_) => const CloudServicePage()),
                      );
                    },
                  );
                }),
                // 同步状态
                Builder(
                  builder: (ctx) {
                    return authAsync.when(
                      loading: () => SettingsNavItem(
                        icon: Icons.cloud_sync_outlined,
                        title: AppLocalizations.of(sectionContext).mineSyncTitle,
                        trailing: const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      ),
                      error: (e, _) => SettingsNavItem(
                        icon: Icons.cloud_sync_outlined,
                        title: AppLocalizations.of(sectionContext).mineSyncTitle,
                        subtitle:
                            '${AppLocalizations.of(sectionContext).commonError}: $e',
                        enabled: false,
                      ),
                      data: (auth) => FutureBuilder<CloudUser?>(
                        future: auth.currentUser,
                        builder: (ctx, snap) {
                          if (snap.hasError) {
                            return SettingsNavItem(
                              icon: Icons.cloud_sync_outlined,
                              title: AppLocalizations.of(sectionContext)
                                  .mineSyncTitle,
                              subtitle:
                                  '${AppLocalizations.of(sectionContext).commonError}: ${snap.error}',
                              enabled: false,
                            );
                          }

                          final user = snap.data;
                          final cloudConfig =
                              sectionRef.watch(activeCloudConfigProvider);
                          final isLocalMode = cloudConfig.hasValue &&
                              cloudConfig.value!.type == CloudBackendType.local;
                          final isICloudMode = cloudConfig.hasValue &&
                              cloudConfig.value!.type ==
                                  CloudBackendType.icloud;
                          // iCloud 使用系统账号，不需要登录；其他云服务需要登录
                          final canUseCloud =
                              !isLocalMode && (isICloudMode || user != null);
                          final asyncSt =
                              sectionRef.watch(syncStatusProvider(ledgerId));
                          final cached = sectionRef
                              .watch(lastSyncStatusProvider(ledgerId));
                          final st = asyncSt.asData?.value ?? cached;

                          // 计算简化的同步状态显示
                          String subtitle = '';
                          bool showCheckIcon = false;
                          final isFirstLoad = st == null;
                          final refreshing = asyncSt.isLoading;

                          if (!isFirstLoad) {
                            switch (st.diff) {
                              case SyncDiff.notLoggedIn:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncNotLoggedIn;
                                break;
                              case SyncDiff.notConfigured:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncNotConfigured;
                                break;
                              case SyncDiff.noRemote:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncNoRemote;
                                break;
                              case SyncDiff.inSync:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncInSyncSimple;
                                showCheckIcon = true;
                                break;
                              case SyncDiff.localNewer:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncLocalNewerSimple;
                                break;
                              case SyncDiff.cloudNewer:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncCloudNewerSimple;
                                break;
                              case SyncDiff.different:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncDifferent;
                                break;
                              case SyncDiff.error:
                                subtitle = AppLocalizations.of(sectionContext)
                                    .mineSyncError;
                                break;
                            }
                          }

                          // trailing 逻辑：加载中显示 spinner，同步完成显示 check，
                          // 其他情况显示 chevron_right（即使禁用也显示，保持与原实现一致）
                          final Widget trailingWidget;
                          if (canUseCloud && (isFirstLoad || refreshing)) {
                            trailingWidget = const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            );
                          } else if (showCheckIcon) {
                            trailingWidget = Icon(
                              Icons.check_circle,
                              color:
                                  sectionRef.watch(primaryColorProvider),
                              size: 20,
                            );
                          } else {
                            trailingWidget = Icon(
                              Icons.chevron_right_rounded,
                              color:
                                  Theme.of(sectionContext)
                                      .colorScheme
                                      .onSurfaceVariant,
                            );
                          }

                          return SettingsNavItem(
                            icon: Icons.cloud_sync_outlined,
                            title: AppLocalizations.of(sectionContext)
                                .mineSyncTitle,
                            subtitle: isFirstLoad ? null : subtitle,
                            enabled: !isLocalMode,
                            trailing: trailingWidget,
                            onTap: () async {
                              // BeeCount Cloud 专属页跟老的
                              // iCloud/WebDAV/Supabase 页语义完全不同,
                              // 路由按 config.type 分叉,避免 UI 里
                              // 大段 if-else 分支。
                              final cfg = ref
                                  .read(activeCloudConfigProvider)
                                  .valueOrNull;
                              final isBeeCount = cfg != null &&
                                  cfg.type ==
                                      CloudBackendType.beecountCloud;
                              await Navigator.of(sectionContext).push(
                                MaterialPageRoute(
                                    builder: (_) => isBeeCount
                                        ? const BeeCountCloudSyncPage()
                                        : const CloudSyncPage()),
                              );
                            },
                          );
                        },
                      ),
                    );
                  },
                ),
              ],
            );
          }),
          SizedBox(height: 24.0.scaled(context, ref)),

          // ── 功能管理 ──
          SettingsSectionLabel(l10n.mineFunctionSection),
          SizedBox(height: 8.0.scaled(context, ref)),
          SettingsCard(
            children: [
              // 智能记账(共享账本入口已移到"账本管理"页 PrimaryHeader)
              SettingsNavItem(
                icon: Icons.auto_awesome_outlined,
                title: AppLocalizations.of(context).smartBilling,
                subtitle: AppLocalizations.of(context).smartBillingDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const SmartBillingPage()),
                  );
                },
              ),
              // 数据管理
              SettingsNavItem(
                icon: Icons.storage_outlined,
                title: AppLocalizations.of(context).dataManagement,
                subtitle: AppLocalizations.of(context).dataManagementDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const DataManagementPage()),
                  );
                },
              ),
              // 预算管理 已挪到「账本管理 → 长按某账本 → 预算管理」
              // (每个账本独立预算,放在账本菜单内语义更匹配)。
              // 自动化功能
              SettingsNavItem(
                icon: Icons.schedule_outlined,
                title: AppLocalizations.of(context).automation,
                subtitle: AppLocalizations.of(context).automationDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const AutomationPage()),
                  );
                },
              ),
              // 外观设置
              SettingsNavItem(
                icon: Icons.palette_outlined,
                title: AppLocalizations.of(context).appearanceSettings,
                subtitle: AppLocalizations.of(context).appearanceSettingsDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const AppearanceSettingsPage()),
                  );
                },
              ),
            ],
          ),
          SizedBox(height: 24.0.scaled(context, ref)),

          // ── 帮助与信息 ──
          SettingsSectionLabel(l10n.mineHelpSection),
          SizedBox(height: 8.0.scaled(context, ref)),
          SettingsCard(
            children: [
              SettingsNavItem(
                icon: Icons.info_outline,
                title: AppLocalizations.of(context).about,
                subtitle: AppLocalizations.of(context).aboutDesc,
                onTap: () async {
                  await Navigator.of(context).push(
                    MaterialPageRoute(builder: (_) => const AboutPage()),
                  );
                },
              ),
              // 使用帮助:默认 App 内嵌 WebView(embed 模式)。
              // 审核兜底:kHelpCenterInApp 改 false 重新打包即回退外部浏览器
              SettingsNavItem(
                icon: Icons.help_outline,
                title: AppLocalizations.of(context).mineHelp,
                subtitle: AppLocalizations.of(context).mineHelpSubtitle,
                onTap: () async {
                  if (kHelpCenterInApp) {
                    await Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => const HelpCenterPage()));
                  } else {
                    final locale = Localizations.localeOf(context);
                    await _tryOpenUrl(Uri.parse(WebsiteUrls.docs(locale)));
                  }
                },
              ),
            ],
          ),
          SizedBox(height: 24.0.scaled(context, ref)),

          // ── 支持我们 ──
          SettingsSectionLabel(l10n.mineSupportSection),
          SizedBox(height: 8.0.scaled(context, ref)),
          SettingsCard(
            children: [
              // 仅在iOS显示打赏入口
              if (Platform.isIOS)
                Consumer(
                  builder: (context, ref, _) {
                    final primaryColor = ref.watch(primaryColorProvider);
                    return SettingsNavItem(
                      icon: Icons.favorite,
                      title: AppLocalizations.of(context).donationTitle,
                      subtitle:
                          AppLocalizations.of(context).donationEntrySubtitle,
                      accentColor: primaryColor,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const DonationPage()),
                        );
                      },
                    );
                  },
                ),
              // GitHub Star
              Consumer(
                builder: (context, ref, _) {
                  final starCountAsync = ref.watch(githubStarCountProvider);
                  final starCount = starCountAsync.valueOrNull ?? 999;
                  return SettingsNavItem(
                    icon: Icons.star_outline,
                    title: AppLocalizations.of(context).mineSupportAuthor,
                    subtitle: AppLocalizations.of(context)
                        .mineSupportAuthorSubtitle(starCount.toString()),
                    onTap: () => _showGitHubStarGuide(context),
                  );
                },
              ),
              // 年度账单
              SettingsNavItem(
                icon: Icons.auto_graph_rounded,
                title: AppLocalizations.of(context).annualReportTitle,
                subtitle: AppLocalizations.of(context).annualReportEntrySubtitle,
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                        builder: (_) => const AnnualReportPage()),
                  );
                },
              ),
              // 分享海报
              SettingsNavItem(
                icon: Icons.ios_share_rounded,
                title: AppLocalizations.of(context).mineShareApp,
                subtitle: AppLocalizations.of(context).mineShareWithFriends,
                onTap: () {
                  // 打开海报轮播预览对话框（支持年度、月度、总览3种海报）
                  SharePosterService.showPosterCarouselPreview(context);
                },
              ),
              // 复制推广文案
              SettingsNavItem(
                icon: Icons.content_copy_rounded,
                title: AppLocalizations.of(context).mineCopyPromoText,
                subtitle: AppLocalizations.of(context).mineCopyPromoSubtitle,
                onTap: () async {
                  final l10n = AppLocalizations.of(context);
                  await Clipboard.setData(
                    ClipboardData(text: l10n.shareGuidanceCopyText),
                  );
                  if (context.mounted) {
                    showToast(context, l10n.shareGuidanceCopied);
                  }
                },
              ),
              // 只在iOS上显示评分入口（Android还未上架）
              if (Platform.isIOS)
                SettingsNavItem(
                  icon: Icons.star_border_rounded,
                  title: AppLocalizations.of(context).mineRateApp,
                  subtitle: AppLocalizations.of(context).mineRateAppSubtitle,
                  onTap: () => _rateApp(context),
                ),
            ],
          ),
          SizedBox(height: 32.0.scaled(context, ref)),
        ],
      ),
    );
  }
}

/// 尝试使用多种方式打开URL，提供更好的兼容性
Future<bool> _tryOpenUrl(Uri url) async {
  try {
    // 方式1: 默认外部应用打开
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalApplication);
      return true;
    }

    // 方式2: 浏览器内打开
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.externalNonBrowserApplication);
      return true;
    }

    // 方式3: 平台默认方式
    if (await canLaunchUrl(url)) {
      await launchUrl(url, mode: LaunchMode.platformDefault);
      return true;
    }

    logger.error('MinePage', '无法打开URL: $url');
    return false;
  } catch (e) {
    logger.error('MinePage', '打开URL失败: $url', e);
    return false;
  }
}

/// 显示 GitHub Star 引导弹窗
void _showGitHubStarGuide(BuildContext context) {
  final l10n = AppLocalizations.of(context);
  final screenHeight = MediaQuery.of(context).size.height;

  showDialog(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(l10n.githubStarGuideTitle),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxHeight: screenHeight * 0.5,
        ),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                l10n.githubStarGuideContent,
                style: TextStyle(
                  color: Colors.grey[600],
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 16),
              // 引导图片
              ClipRRect(
                borderRadius: BorderRadius.circular(BeeDimens.radiusSm),
                child: Image.asset(
                  'assets/images/github_star_guide.png',
                  fit: BoxFit.contain,
                ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            _tryOpenUrl(Uri.parse('https://github.com/TNT-Likely/BeeCount'));
          },
          child: Text(l10n.githubStarGuideButton),
        ),
      ],
    ),
  );
}

/// 请求应用评分
///
/// iOS系统对原生评分弹窗有限制：
/// 1. 每365天最多弹出3次
/// 2. 模拟器上不显示
/// 3. 用户可在系统设置中禁用
///
/// 因此直接打开App Store评分页面更可靠
Future<void> _rateApp(BuildContext context) async {
  try {
    final InAppReview inAppReview = InAppReview.instance;

    // 直接打开应用商店评分页面（更可靠，不受系统限制）
    if (Platform.isIOS) {
      await inAppReview.openStoreListing(
        appStoreId: '6754611670', // BeeCount的App Store ID
      );
      logger.info('MinePage', '已打开App Store评分页面');
    } else {
      // Android会自动打开Google Play（如果已上架）
      await inAppReview.openStoreListing();
      logger.info('MinePage', '已打开Google Play评分页面');
    }
  } catch (e) {
    logger.error('MinePage', '打开评分失败', e);
    // 失败时不显示错误提示，静默失败
  }
}
