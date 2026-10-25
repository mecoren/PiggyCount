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
import '../../services/export/share_poster_service.dart';
import '../../l10n/app_localizations.dart';
import '../cloud/cloud_sync_page.dart';
import '../settings/data_management_page.dart';
import '../settings/appearance_settings_page.dart';
import '../settings/holiday_settings_page.dart';
import '../settings/investment_settings_page.dart';
import '../settings/smart_billing_page.dart';
import '../settings/reminder_settings_page.dart';
import '../settings/about_page.dart';
import '../settings/custom_field_manage_page.dart';
import '../budget/budget_page.dart';
import '../transaction/recurring_transaction_page.dart';
import '../transaction/subscription_page.dart';
import '../report/amount_deviation_page.dart';
import '../report/annual_report_page.dart';
import '../report/range_report_page.dart';
import '../savings_goal/savings_goals_page.dart';
import 'package:in_app_review/in_app_review.dart';
import '../../utils/ui_scale_extensions.dart';

import '../../utils/platform_info.dart';

/// 我的页面（设置主页）
///
/// UI 改造：参考 wait-home 项目风格，使用 GlassTitleBar + ListView + 卡片化布局。
/// 头部内容（头像/问候语/统计）抽取为 ProfileCard，设置项使用 SettingsCard +
/// SettingsNavItem。所有原有功能逻辑（云同步状态、iOS 专属项等）完整保留。
class MinePage extends ConsumerWidget {
  const MinePage({super.key});

  /// 主壳 Tab 懒加载入口(见 app.dart _LazyTab):首次切到我的 Tab 才 build。
  static Widget builder(BuildContext context) => const MinePage();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authAsync = ref.watch(authServiceProvider);
    final ledgerId = ref.watch(currentLedgerIdProvider);
    // 账本设置分区:watch 当前账本行,标题中的账本名随切换/改名实时刷新
    final currentLedger = ref.watch(currentLedgerProvider).value;
    final l10n = AppLocalizations.of(context);

    // 头部背景与页面背景一致(亮色淡蓝 / 暗色深蓝灰)，
    // 状态栏图标随主题切换以保证可见性。
    final isDark = PiggyTokens.isDark(context);
    SystemChrome.setSystemUIOverlayStyle(
      (isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark)
          .copyWith(
        statusBarColor: Colors.transparent,
      ),
    );

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      body: CustomScrollView(
        physics: const AlwaysScrollableScrollPhysics(),
        slivers: [
          SliverPersistentHeader(
            pinned: true,
            delegate: _ProfileHeaderDelegate(
              minExtent: ProfileCard.collapsedHeight(context, ref),
              maxExtent: ProfileCard.expandedHeight(context, ref),
            ),
          ),
          SliverPadding(
            padding: EdgeInsets.fromLTRB(
              PiggyDimens.p16,
              PiggyDimens.p12,
              PiggyDimens.p16,
              PiggyDimens.p16 + MediaQuery.of(context).padding.bottom + 56 + 12,
            ),
            sliver: SliverList(
              delegate: SliverChildListDelegate([
                // ── 云同步与备份 ──
                SettingsSectionLabel(l10n.mineCloudBackupSection),
                SizedBox(height: 8.0.scaled(context, ref)),
                Consumer(builder: (sectionContext, sectionRef, _) {
                  final activeCfg = sectionRef.watch(activeCloudConfigProvider);

                  return SettingsCard(
                    children: [
                      SettingsNavItem(
                        icon: Icons.cloud_queue_outlined,
                        title: AppLocalizations.of(sectionContext)
                            .mineCloudService,
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
                            }
                          },
                        ),
                        onTap: () async {
                          await Navigator.of(sectionContext).push(
                            MaterialPageRoute(
                                builder: (_) => const CloudServicePage()),
                          );
                        },
                      ),
                      // 同步状态
                      Builder(
                        builder: (ctx) {
                          return authAsync.when(
                            loading: () => SettingsNavItem(
                              icon: Icons.cloud_sync_outlined,
                              title: AppLocalizations.of(sectionContext)
                                  .mineSyncTitle,
                              trailing: PiggySpinner(
                                size: 20,
                                color: PiggyTokens.primary(sectionContext),
                              ),
                            ),
                            error: (e, _) => SettingsNavItem(
                              icon: Icons.cloud_sync_outlined,
                              title: AppLocalizations.of(sectionContext)
                                  .mineSyncTitle,
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
                                    cloudConfig.value!.type ==
                                        CloudBackendType.local;
                                final isICloudMode = cloudConfig.hasValue &&
                                    cloudConfig.value!.type ==
                                        CloudBackendType.icloud;
                                // iCloud 使用系统账号，不需要登录；其他云服务需要登录
                                final canUseCloud = !isLocalMode &&
                                    (isICloudMode || user != null);
                                final asyncSt = sectionRef
                                    .watch(syncStatusProvider(ledgerId));
                                final cached = sectionRef
                                    .watch(lastSyncStatusProvider(ledgerId));
                                final st = asyncSt.asData?.value ?? cached;

                                // 计算简化的同步状态显示
                                String subtitle = '';
                                bool showCheckIcon = false;
                                final isFirstLoad = st == null;
                                final refreshing = asyncSt.isLoading;

                                // 刷新期间不回退显示缓存的旧状态（可能是过时
                                // 的"已同步"），改显"同步中"，避免与启动检查
                                // 的"云端有更新"提示互相矛盾
                                if (refreshing) {
                                  subtitle = AppLocalizations.of(sectionContext)
                                      .mineSyncChecking;
                                } else if (!isFirstLoad) {
                                  switch (st.diff) {
                                    case SyncDiff.notLoggedIn:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncNotLoggedIn;
                                      break;
                                    case SyncDiff.notConfigured:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncNotConfigured;
                                      break;
                                    case SyncDiff.noRemote:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncNoRemote;
                                      break;
                                    case SyncDiff.inSync:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncInSyncSimple;
                                      showCheckIcon = true;
                                      break;
                                    case SyncDiff.localNewer:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncLocalNewerSimple;
                                      break;
                                    case SyncDiff.cloudNewer:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncCloudNewerSimple;
                                      break;
                                    case SyncDiff.different:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncDifferent;
                                      break;
                                    case SyncDiff.error:
                                      subtitle =
                                          AppLocalizations.of(sectionContext)
                                              .mineSyncError;
                                      break;
                                  }
                                }

                                // trailing 逻辑：加载中显示 spinner，同步完成显示 check，
                                // 其他情况显示 chevron_right（即使禁用也显示，保持与原实现一致）
                                final Widget trailingWidget;
                                if (canUseCloud &&
                                    (isFirstLoad || refreshing)) {
                                  trailingWidget = PiggySpinner(
                                    size: 20,
                                    color: PiggyTokens.primary(sectionContext),
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
                                    color: Theme.of(sectionContext)
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
                                    await Navigator.of(sectionContext).push(
                                      MaterialPageRoute(
                                          builder: (_) =>
                                              const CloudSyncPage()),
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

                // ── 账本设置（操作对象 = 当前账本，随账本切换；
                //    收敛原账本长按预算/数据管理自定义字段/自动化周期与订阅/
                //    功能管理储蓄目标等分散入口，见 prd/ledger_settings_section）──
                if (currentLedger != null) ...[
                  SettingsSectionLabel(
                      l10n.ledgerSettingsSectionTitle(currentLedger.name)),
                  SizedBox(height: 8.0.scaled(context, ref)),
                  SettingsCard(
                    children: [
                      // 账本信息 — 与账本页长按「编辑」共用 editLedgerInfo
                      // 全流程（本位币变更确认 + nativeAmount 重算 + 同步）。
                      SettingsNavItem(
                        icon: Icons.info_outline,
                        title: l10n.ledgerInfoItemTitle,
                        subtitle: l10n.ledgerInfoItemSubtitle,
                        onTap: () => editLedgerInfo(context, ref,
                            ledgerId: currentLedger.id),
                      ),
                      // 预算管理（每个账本独立预算，页面隐式当前账本）
                      SettingsNavItem(
                        icon: Icons.pie_chart_outline_rounded,
                        title: l10n.budgetManagement,
                        subtitle: l10n.budgetSetupHint,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const BudgetPage()),
                          );
                        },
                      ),
                      // 自定义字段（账本级：字段定义按 ledgerId 隔离）
                      SettingsNavItem(
                        icon: Icons.playlist_add_outlined,
                        title: l10n.customFieldManageTitle,
                        subtitle: l10n.customFieldManageSubtitle,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const CustomFieldManagePage()),
                          );
                        },
                      ),
                      // 周期记账（页面为跨账本列表、行上标注账本名 — 需求 R1，
                      // 新建默认落在当前账本）
                      SettingsNavItem(
                        icon: Icons.repeat,
                        title: l10n.mineRecurringTransactions,
                        subtitle: l10n.mineRecurringTransactionsSubtitle,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) =>
                                    const RecurringTransactionPage()),
                          );
                        },
                      ),
                      // 订阅管理（当前账本周期账单的派生视图）
                      SettingsNavItem(
                        icon: Icons.subscriptions_outlined,
                        title: l10n.mineSubscriptionManagement,
                        subtitle: l10n.mineSubscriptionManagementSubtitle,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const SubscriptionPage()),
                          );
                        },
                      ),
                      // 储蓄目标（v53：目标的激励层，与预算的约束层互为镜像）
                      SettingsNavItem(
                        icon: Icons.savings_outlined,
                        title: l10n.savingsGoalPageTitle,
                        subtitle: l10n.savingsGoalEmptyHint,
                        onTap: () async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                                builder: (_) => const SavingsGoalsPage()),
                          );
                        },
                      ),
                    ],
                  ),
                  SizedBox(height: 24.0.scaled(context, ref)),
                ],

                // ── 功能管理 ──
                SettingsSectionLabel(l10n.mineFunctionSection),
                SizedBox(height: 8.0.scaled(context, ref)),
                SettingsCard(
                  children: [
                    // 智能记账
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
                    // 记账提醒（原「自动化功能」中间页只剩这一项，
                    // 2026-10-12 壳页面清理后入口上移直达，见 prd/engineering_debt_cleanup）
                    SettingsNavItem(
                      icon: Icons.notifications_active_outlined,
                      title: l10n.mineReminderSettings,
                      subtitle: l10n.mineReminderSettingsSubtitle,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const ReminderSettingsPage()),
                        );
                      },
                    ),
                    // 外观设置
                    SettingsNavItem(
                      icon: Icons.palette_outlined,
                      title: AppLocalizations.of(context).appearanceSettings,
                      subtitle:
                          AppLocalizations.of(context).appearanceSettingsDesc,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AppearanceSettingsPage()),
                        );
                      },
                    ),
                    // 日历与节假日
                    SettingsNavItem(
                      icon: Icons.calendar_month_outlined,
                      title: AppLocalizations.of(context).holidaySettingsTitle,
                      subtitle:
                          AppLocalizations.of(context).holidaySettingsDesc,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const HolidaySettingsPage()),
                        );
                      },
                    ),
                    // 行情与投资（v52：行情源预留入口 + 投资持仓说明）
                    SettingsNavItem(
                      icon: Icons.trending_up_outlined,
                      title:
                          AppLocalizations.of(context).investmentSettingsTitle,
                      subtitle:
                          AppLocalizations.of(context).investmentSettingsDesc,
                      onTap: () async {
                        await Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const InvestmentSettingsPage()),
                        );
                      },
                    ),
                    // 储蓄目标已移至「账本设置」分区（按账本隔离的数据）
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
                  ],
                ),
                SizedBox(height: 24.0.scaled(context, ref)),

                // ── 支持我们 ──
                SettingsSectionLabel(l10n.mineSupportSection),
                SizedBox(height: 8.0.scaled(context, ref)),
                SettingsCard(
                  children: [
                    // 年度账单
                    SettingsNavItem(
                      icon: Icons.auto_graph_rounded,
                      title: AppLocalizations.of(context).annualReportTitle,
                      subtitle: AppLocalizations.of(context)
                          .annualReportEntrySubtitle,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AnnualReportPage()),
                        );
                      },
                    ),
                    // 自定义区间报表（F2：任意起止 + 环比/同比 + 标签维度）
                    SettingsNavItem(
                      icon: Icons.date_range_outlined,
                      title: AppLocalizations.of(context).rangeReportTitle,
                      subtitle:
                          AppLocalizations.of(context).rangeReportEntrySubtitle,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const RangeReportPage()),
                        );
                      },
                    ),
                    // v45 金额偏差分析（原始金额 vs 记账金额）
                    SettingsNavItem(
                      icon: Icons.insights_outlined,
                      title: AppLocalizations.of(context).amountDeviationTitle,
                      subtitle: AppLocalizations.of(context)
                          .amountDeviationEntrySubtitle,
                      onTap: () {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                              builder: (_) => const AmountDeviationPage()),
                        );
                      },
                    ),
                    // 分享海报
                    SettingsNavItem(
                      icon: Icons.ios_share_rounded,
                      title: AppLocalizations.of(context).mineShareApp,
                      subtitle:
                          AppLocalizations.of(context).mineShareWithFriends,
                      onTap: () {
                        // 打开海报轮播预览对话框（支持年度、月度、总览3种海报）
                        SharePosterService.showPosterCarouselPreview(context);
                      },
                    ),
                    // 复制推广文案
                    SettingsNavItem(
                      icon: Icons.content_copy_rounded,
                      title: AppLocalizations.of(context).mineCopyPromoText,
                      subtitle:
                          AppLocalizations.of(context).mineCopyPromoSubtitle,
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
                    if (PlatformInfo.isIOS)
                      SettingsNavItem(
                        icon: Icons.star_border_rounded,
                        title: AppLocalizations.of(context).mineRateApp,
                        subtitle:
                            AppLocalizations.of(context).mineRateAppSubtitle,
                        onTap: () => _rateApp(context),
                      ),
                  ],
                ),
                SizedBox(height: 32.0.scaled(context, ref)),
              ]),
            ),
          ),
        ],
      ),
    );
  }
}

class _ProfileHeaderDelegate extends SliverPersistentHeaderDelegate {
  _ProfileHeaderDelegate({required this.minExtent, required this.maxExtent});

  @override
  final double minExtent;

  @override
  final double maxExtent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) {
    final distance = maxExtent - minExtent;
    final progress = distance == 0
        ? 0.0
        : (shrinkOffset / distance).clamp(0.0, 1.0).toDouble();
    return ProfileCard(collapseProgress: progress);
  }

  @override
  bool shouldRebuild(_ProfileHeaderDelegate oldDelegate) =>
      minExtent != oldDelegate.minExtent || maxExtent != oldDelegate.maxExtent;
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
    if (PlatformInfo.isIOS) {
      await inAppReview.openStoreListing(
        appStoreId: '6754611670', // PiggyCount的App Store ID
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
