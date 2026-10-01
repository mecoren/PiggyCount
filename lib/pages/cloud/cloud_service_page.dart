import 'dart:convert';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';
import '../../providers/sync_providers.dart';
import '../../providers/theme_providers.dart';
import '../../services/system/logger_service.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/ui/wait_sliding_segmented_control.dart';
import '../../widgets/biz/section_card.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../cloud/provider_factory.dart';

import '../../utils/platform_info.dart';

// GitHub配置教程链接
const _kSupabaseGuideUrl =
    'https://github.com/mecoren/PiggyCount/wiki/Supabase-%E4%BA%91%E5%90%8C%E6%AD%A5%E9%85%8D%E7%BD%AE';

/// 项目技术标识符，用作云存储默认命名空间（WebDAV 远程目录、S3 桶名等）
/// 注意：必须使用 ASCII 小写标识，不能依赖 [AppLocalizations.appName]，
/// 因为后者在中文环境下会变为 "小猪记账"，既不适合作为 URL 路径段，
/// 也不符合 S3 桶名命名规范（仅允许小写字母、数字、点、连字符）。
const _kDefaultProjectName = 'piggycount';

/// Supabase / iCloud 后端对用户隐藏（2026-09-10 同步审计：Supabase 存在
/// list() SDK 默认 limit:100 静默截断的 P0-1，iCloud 缺 Dart 层兜底）。
/// 上线口径仅开放 S3 / WebDAV 双主力后端；协议实现与存量激活用户的
/// 同步链路保留不动，待 P0 修复后将本开关改回 true 即可恢复入口。
/// 用 final 而非 const：const false 会让 if 分支触发 dead_code 告警。
final _kShowSupabaseAndICloud = false;

class CloudServicePage extends ConsumerStatefulWidget {
  const CloudServicePage({super.key});
  @override
  ConsumerState<CloudServicePage> createState() => _CloudServicePageState();
}

class _CloudServicePageState extends ConsumerState<CloudServicePage> {
  bool _testingConnection = false;
  final Map<String, bool> _connectionTestResults = {};
  bool _hasAutoTested = false;
  String _selectedTab = 'offline'; // 'offline' | 'backup'

  @override
  void initState() {
    super.initState();

    // 根据当前激活的配置决定初始 Tab
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final activeAsync = ref.read(activeCloudConfigProvider);
      if (activeAsync.hasValue) {
        final active = activeAsync.value!;
        if (active.type != CloudBackendType.local) {
          setState(() => _selectedTab = 'backup');
        }
      }
      _autoTestActiveConnection();
    });
  }

  Future<void> _autoTestActiveConnection() async {
    if (_hasAutoTested) return;
    _hasAutoTested = true;

    // 多设备同步关闭时，跳过自动测试
    final prefs = await SharedPreferences.getInstance();
    final multiDevice = prefs.getBool('multi_device_sync') ?? false;
    if (!multiDevice) return;

    final activeAsync = ref.read(activeCloudConfigProvider);
    if (!activeAsync.hasValue) return;

    final active = activeAsync.value!;
    if (active.type == CloudBackendType.local || !active.valid) return;

    // 自动测试当前激活的云服务连接（静默测试，不显示对话框）
    await _testConnection(active, showDialog: false);
  }

  @override
  Widget build(BuildContext context) {
    final activeAsync = ref.watch(activeCloudConfigProvider);
    final supabaseAsync = ref.watch(supabaseConfigProvider);
    final webdavAsync = ref.watch(webdavConfigProvider);
    final s3Async = ref.watch(s3ConfigProvider);
    // 选中态边框使用用户选定的主题色（与首页「明细」外层卡片边框色保持一致）
    final primaryColor = ref.watch(primaryColorProvider);

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      body: Column(
        children: [
          activeAsync.when(
            loading: () => PiggyHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
            ),
            error: (e, _) => PiggyHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
            ),
            data: (active) => PiggyHeader(
              title: AppLocalizations.of(context).mineCloudService,
              showBack: true,
              actions: active.type != CloudBackendType.local && active.valid
                  ? [
                      IconButton(
                        icon: _testingConnection
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.wifi_find),
                        onPressed: _testingConnection
                            ? null
                            : () => _testConnection(active),
                        tooltip:
                            AppLocalizations.of(context).cloudTestConnection,
                      ),
                    ]
                  : null,
              content: active.type != CloudBackendType.local
                  ? Padding(
                      padding: const EdgeInsets.fromLTRB(0, 8, 0, 4),
                      child: _buildConnectionStatus(active),
                    )
                  : null,
            ),
          ),
          // 滑动分段选择器
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: WaitSlidingSegmentedControl<String>(
              selected: _selectedTab,
              segments: [
                WaitSlidingSegment(
                    value: 'offline',
                    label: AppLocalizations.of(context).cloudTabOffline),
                WaitSlidingSegment(
                    value: 'backup',
                    label: AppLocalizations.of(context).cloudTabBackup),
              ],
              onValueChanged: (value) => setState(() => _selectedTab = value),
            ),
          ),
          Expanded(
            child: activeAsync.when(
              loading: () => DelayedSkeleton(
                placeholder: const SizedBox.expand(),
                child: PulseSkeleton(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: const [
                        SkeletonListTile(),
                        SkeletonListTile(),
                        SkeletonListTile(),
                      ],
                    ),
                  ),
                ),
              ),
              error: (e, _) => Center(
                  child:
                      Text('${AppLocalizations.of(context).commonError}: $e')),
              data: (active) {
                if (_selectedTab == 'offline') {
                  // ===== 离线模式 =====
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      _buildServiceCard(
                        context: context,
                        icon: Icons.phone_android,
                        iconColor: PiggyTokens.brandLocal,
                        title:
                            AppLocalizations.of(context).cloudLocalStorageTitle,
                        subtitle: AppLocalizations.of(context)
                            .cloudLocalStorageSubtitle,
                        isSelected: active.type == CloudBackendType.local,
                        isDisabled: false,
                        onTap: () => _switchService(CloudBackendType.local),
                        primaryColor: primaryColor,
                      ),
                    ],
                  );
                } else {
                  // ===== 备份同步 =====
                  return ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      // 多设备同步警告
                      if (active.type != CloudBackendType.local) ...[
                        _buildMultiDeviceWarning(context),
                        const SizedBox(height: 12),
                      ],

                      // iCloud (仅 iOS)
                      if (_kShowSupabaseAndICloud &&
                          !kIsWeb &&
                          PlatformInfo.isIOS) ...[
                        _buildICloudCard(context, active,
                            isDisabled: false, primaryColor: primaryColor),
                        const SizedBox(height: 12),
                      ],

                      // WebDAV
                      webdavAsync.when(
                        loading: () => DelayedSkeleton(
                          placeholder: const SizedBox(height: 100),
                          child: PulseSkeleton(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: SkeletonBar(
                                  height: 88,
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radiusLg)),
                            ),
                          ),
                        ),
                        error: (e, _) => const SizedBox.shrink(),
                        data: (webdavCfg) => _buildServiceCard(
                          context: context,
                          icon: Icons.folder_shared,
                          iconColor: PiggyTokens.brandWebdav,
                          title: AppLocalizations.of(context)
                              .cloudCustomWebdavTitle,
                          subtitle: webdavCfg?.valid == true
                              ? webdavCfg!.obfuscatedUrl()
                              : AppLocalizations.of(context)
                                  .cloudCustomWebdavSubtitle,
                          isSelected: active.type == CloudBackendType.webdav,
                          isConfigured: webdavCfg?.valid == true,
                          isDisabled: false,
                          onTap: () => webdavCfg?.valid == true
                              ? _switchService(CloudBackendType.webdav)
                              : _configureService(CloudBackendType.webdav),
                          onConfigure: webdavCfg?.valid == true
                              ? () => _configureService(CloudBackendType.webdav)
                              : null,
                          onShowGuide: _showWebdavHelpDialog,
                          primaryColor: primaryColor,
                        ),
                      ),

                      const SizedBox(height: 12),

                      // S3
                      s3Async.when(
                        loading: () => DelayedSkeleton(
                          placeholder: const SizedBox(height: 100),
                          child: PulseSkeleton(
                            child: Padding(
                              padding: const EdgeInsets.symmetric(vertical: 6),
                              child: SkeletonBar(
                                  height: 88,
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radiusLg)),
                            ),
                          ),
                        ),
                        error: (e, _) => const SizedBox.shrink(),
                        data: (s3Cfg) => _buildServiceCard(
                          context: context,
                          icon: Icons.storage,
                          iconColor: PiggyTokens.brandS3,
                          title:
                              AppLocalizations.of(context).cloudCustomS3Title,
                          subtitle: s3Cfg?.valid == true
                              ? s3Cfg!.obfuscatedUrl()
                              : AppLocalizations.of(context)
                                  .cloudCustomS3Subtitle,
                          isSelected: active.type == CloudBackendType.s3,
                          isConfigured: s3Cfg?.valid == true,
                          isDisabled: false,
                          onTap: () => s3Cfg?.valid == true
                              ? _switchService(CloudBackendType.s3)
                              : _configureService(CloudBackendType.s3),
                          onConfigure: s3Cfg?.valid == true
                              ? () => _configureService(CloudBackendType.s3)
                              : null,
                          onShowGuide: _showS3HelpDialog,
                          primaryColor: primaryColor,
                        ),
                      ),

                      const SizedBox(height: 12),

                      // Supabase
                      if (_kShowSupabaseAndICloud)
                        supabaseAsync.when(
                          loading: () => DelayedSkeleton(
                            placeholder: const SizedBox(height: 100),
                            child: PulseSkeleton(
                              child: Padding(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 6),
                                child: SkeletonBar(
                                    height: 88,
                                    borderRadius: BorderRadius.circular(
                                        PiggyDimens.radiusLg)),
                              ),
                            ),
                          ),
                          error: (e, _) => const SizedBox.shrink(),
                          data: (supabaseCfg) => _buildServiceCard(
                            context: context,
                            icon: Icons.cloud,
                            iconColor: PiggyTokens.brandSupabase,
                            title: AppLocalizations.of(context)
                                .cloudCustomSupabaseTitle,
                            subtitle: supabaseCfg?.valid == true
                                ? supabaseCfg!.obfuscatedUrl()
                                : AppLocalizations.of(context)
                                    .cloudCustomSupabaseSubtitle,
                            isSelected:
                                active.type == CloudBackendType.supabase,
                            isConfigured: supabaseCfg?.valid == true,
                            isDisabled: false,
                            onTap: () => supabaseCfg?.valid == true
                                ? _switchService(CloudBackendType.supabase)
                                : _configureService(CloudBackendType.supabase),
                            onConfigure: supabaseCfg?.valid == true
                                ? () =>
                                    _configureService(CloudBackendType.supabase)
                                : null,
                            onShowGuide: _showSupabaseHelpDialog,
                            primaryColor: primaryColor,
                          ),
                        ),
                    ],
                  );
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildConnectionStatus(CloudServiceConfig config) {
    final testResult = _connectionTestResults[config.id];
    final Color statusColor;
    final String statusText;

    if (testResult == null) {
      // 未测试
      statusColor = PiggyTokens.warning(context);
      statusText = AppLocalizations.of(context).cloudStatusNotTested;
    } else if (testResult) {
      // 测试成功
      statusColor = PiggyTokens.success(context);
      statusText = AppLocalizations.of(context).cloudStatusNormal;
    } else {
      // 测试失败
      statusColor = PiggyTokens.error(context);
      statusText = AppLocalizations.of(context).cloudStatusFailed;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '${AppLocalizations.of(context).commonCurrent}: ${_getTypeName(config.type)}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(width: 12),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                border: Border.all(color: statusColor.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: statusColor,
                      shape: BoxShape.circle,
                    ),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    statusText,
                    style: TextStyle(
                      color: statusColor,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          config.obfuscatedUrl(),
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: PiggyTokens.textSecondary(context),
              ),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
      ],
    );
  }

  Widget _buildMultiDeviceWarning(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    return GestureDetector(
      onTap: () => _showMultiDeviceDetailDialog(context),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: PiggyTokens.warning(context).withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
          border: Border.all(
            color: PiggyTokens.warning(context).withValues(alpha: 0.3),
          ),
        ),
        child: Row(
          children: [
            Icon(
              Icons.warning_amber_rounded,
              color: PiggyTokens.warning(context),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    l10n.cloudMultiDeviceWarningTitle,
                    style: PiggyTextTokens.strongTitle(context)
                        .copyWith(fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    l10n.cloudMultiDeviceWarningMessage,
                    style: PiggyTextTokens.label(context),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.info_outline,
              color: PiggyTokens.warning(context),
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  void _showMultiDeviceDetailDialog(BuildContext context) {
    final l10n = AppLocalizations.of(context);

    showDialog(
      context: context,
      builder: (context) => AppDialogShell(
        wide: true,
        title: Row(
          children: [
            Icon(
              Icons.info_outline,
              color: PiggyTokens.primary(context),
              size: 24,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                l10n.cloudSyncGuideTitle,
                style:
                    PiggyTextTokens.strongTitle(context).copyWith(fontSize: 18),
              ),
            ),
          ],
        ),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 工作原理
                _buildGuideSection(
                  context,
                  icon: Icons.sync,
                  title: l10n.cloudSyncGuideHowItWorks,
                  items: [
                    l10n.cloudSyncGuideHowItem1,
                    l10n.cloudSyncGuideHowItem2,
                    l10n.cloudSyncGuideHowItem3,
                  ],
                ),
                const SizedBox(height: 16),
                // 正确用法
                _buildGuideSection(
                  context,
                  icon: Icons.check_circle_outline,
                  iconColor: PiggyTokens.success(context),
                  title: l10n.cloudSyncGuideCorrect,
                  items: [
                    l10n.cloudSyncGuideCorrectItem1,
                    l10n.cloudSyncGuideCorrectItem2,
                    l10n.cloudSyncGuideCorrectItem3,
                    l10n.cloudSyncGuideCorrectItem4,
                  ],
                ),
                const SizedBox(height: 16),
                // 错误用法
                _buildGuideSection(
                  context,
                  icon: Icons.cancel_outlined,
                  iconColor: PiggyTokens.error(context),
                  title: l10n.cloudSyncGuideWrong,
                  items: [
                    l10n.cloudSyncGuideWrongItem1,
                    l10n.cloudSyncGuideWrongItem2,
                    l10n.cloudSyncGuideWrongItem3,
                  ],
                ),
                const SizedBox(height: 16),
                // 已知限制
                _buildGuideSection(
                  context,
                  icon: Icons.warning_amber_rounded,
                  iconColor: PiggyTokens.warning(context),
                  title: l10n.cloudSyncGuideLimitations,
                  items: [
                    l10n.cloudSyncGuideLimitItem1,
                    l10n.cloudSyncGuideLimitItem2,
                    l10n.cloudSyncGuideLimitItem3,
                    l10n.cloudSyncGuideLimitItem4,
                  ],
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(
              l10n.cloudSyncGuideGotIt,
              style: TextStyle(
                color: PiggyTokens.primary(context),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGuideSection(
    BuildContext context, {
    required IconData icon,
    Color? iconColor,
    required String title,
    required List<String> items,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon,
                size: 18,
                color: iconColor ?? PiggyTokens.textSecondary(context)),
            const SizedBox(width: 6),
            Text(
              title,
              style: PiggyTextTokens.strongTitle(context),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(left: 24, bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('• ',
                      style: PiggyTextTokens.label(context)
                          .copyWith(fontSize: 13)),
                  Expanded(
                    child: Text(
                      item,
                      style: PiggyTextTokens.label(context)
                          .copyWith(fontSize: 13, height: 1.4),
                    ),
                  ),
                ],
              ),
            )),
      ],
    );
  }

  Widget _buildServiceCard({
    required BuildContext context,
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool isSelected,
    bool isConfigured = true,
    bool isDisabled = false,
    required VoidCallback onTap,
    VoidCallback? onConfigure,
    VoidCallback? onShowGuide,
    required Color primaryColor,
  }) {
    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        ),
        child: SectionCard(
          margin: EdgeInsets.zero,
          // 主题色边框：选中加粗，未选中细边框（与全站卡片统一）
          borderColor: primaryColor,
          borderWidth: isSelected ? 2.5 : 1.5,
          child: InkWell(
            onTap: isDisabled ? null : onTap,
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      // 图标
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: iconColor.withValues(alpha: 0.1),
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusLg),
                        ),
                        child: Icon(icon, color: iconColor, size: 24),
                      ),
                      const SizedBox(width: 16),

                      // 文字信息
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    title,
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                if (isDisabled)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: PiggyTokens.textTertiary(context)
                                          .withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(
                                          PiggyDimens.radiusSm),
                                    ),
                                    child: Text(
                                      '不可用',
                                      style: PiggyTextTokens.caption(context),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              subtitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: PiggyTokens.textSecondary(context),
                                  ),
                            ),
                          ],
                        ),
                      ),

                      // 选中标记：填充用户主题色（与边框同色，视觉一致）
                      if (isSelected && !isDisabled)
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child:
                              Icon(Icons.check, color: Colors.white, size: 18),
                        ),
                    ],
                  ),

                  // 底部按钮行
                  if (!isDisabled &&
                      ((isConfigured && onConfigure != null) ||
                          onShowGuide != null))
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          if (onShowGuide != null)
                            TextButton.icon(
                              onPressed: onShowGuide,
                              icon: const Icon(Icons.help_outline, size: 16),
                              label: Text(
                                  AppLocalizations.of(context).commonTutorial,
                                  style: const TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 4),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          if (isConfigured && onConfigure != null) ...[
                            if (onShowGuide != null) const SizedBox(width: 8),
                            TextButton.icon(
                              onPressed: onConfigure,
                              icon: const Icon(Icons.settings, size: 16),
                              label: Text(
                                  AppLocalizations.of(context).commonConfigure,
                                  style: const TextStyle(fontSize: 12)),
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 12, vertical: 8),
                                minimumSize: Size.zero,
                                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildICloudCard(BuildContext context, CloudServiceConfig active,
      {bool isDisabled = false, required Color primaryColor}) {
    final isSelected = active.type == CloudBackendType.icloud;

    return Opacity(
      opacity: isDisabled ? 0.5 : 1.0,
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
        ),
        child: SectionCard(
          margin: EdgeInsets.zero,
          // 主题色边框：选中加粗，未选中细边框（与全站卡片统一）
          borderColor: primaryColor,
          borderWidth: isSelected ? 2.5 : 1.5,
          child: InkWell(
            onTap: isDisabled
                ? null
                : () => _switchService(CloudBackendType.icloud),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  Row(
                    children: [
                      // 图标
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: PiggyTokens.brandIcloud.withValues(alpha: 0.1),
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusLg),
                        ),
                        child: Icon(Icons.cloud,
                            color: PiggyTokens.brandIcloud, size: 24),
                      ),
                      const SizedBox(width: 16),

                      // 文字信息
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'iCloud',
                                    style: Theme.of(context)
                                        .textTheme
                                        .titleMedium
                                        ?.copyWith(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                                if (isDisabled)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                        horizontal: 8, vertical: 2),
                                    decoration: BoxDecoration(
                                      color: PiggyTokens.textTertiary(context)
                                          .withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(
                                          PiggyDimens.radiusSm),
                                    ),
                                    child: Text(
                                      '不可用',
                                      style: PiggyTextTokens.caption(context),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              isSelected
                                  ? 'iCloud Drive'
                                  : AppLocalizations.of(context)
                                      .cloudIcloudSubtitle,
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: PiggyTokens.textSecondary(context),
                                  ),
                            ),
                          ],
                        ),
                      ),

                      // 选中标记：填充用户主题色（与边框同色，视觉一致）
                      if (isSelected && !isDisabled)
                        Container(
                          width: 28,
                          height: 28,
                          decoration: BoxDecoration(
                            color: primaryColor,
                            shape: BoxShape.circle,
                          ),
                          child:
                              Icon(Icons.check, color: Colors.white, size: 18),
                        ),
                    ],
                  ),

                  // 底部帮助按钮
                  if (!isDisabled)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          TextButton.icon(
                            onPressed: _showICloudHelpDialog,
                            icon: const Icon(Icons.help_outline, size: 16),
                            label: Text(
                                AppLocalizations.of(context).commonTutorial,
                                style: const TextStyle(fontSize: 12)),
                            style: TextButton.styleFrom(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              minimumSize: Size.zero,
                              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _showSupabaseHelpDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        wide: true,
        title: Row(
          children: [
            Icon(Icons.cloud, color: PiggyTokens.brandSupabase),
            const SizedBox(width: 8),
            Text(l10n.cloudSupabaseHelpTitle),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpSection(
                l10n.cloudSupabaseHelpIntro,
                [
                  l10n.cloudSupabaseHelpIntro1,
                  l10n.cloudSupabaseHelpIntro2,
                  l10n.cloudSupabaseHelpIntro3,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudSupabaseHelpSteps,
                [
                  l10n.cloudSupabaseHelpStep1,
                  l10n.cloudSupabaseHelpStep2,
                  l10n.cloudSupabaseHelpStep3,
                  l10n.cloudSupabaseHelpStep4,
                  l10n.cloudSupabaseHelpStep5,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudSupabaseHelpFaq,
                [
                  '• ${l10n.cloudSupabaseHelpFaq1}',
                  '• ${l10n.cloudSupabaseHelpFaq2}',
                  '• ${l10n.cloudSupabaseHelpFaq3}',
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PiggyTokens.brandSupabase.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: PiggyTokens.brandSupabase, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.cloudSupabaseHelpNote,
                        style: PiggyTextTokens.label(context)
                            .copyWith(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => _openGuide(_kSupabaseGuideUrl),
            child: Text(l10n.cloudDetailedTutorial),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  void _showWebdavHelpDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        wide: true,
        title: Row(
          children: [
            Icon(Icons.folder_shared, color: PiggyTokens.brandWebdav),
            const SizedBox(width: 8),
            Text(l10n.cloudWebdavHelpTitle),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpSection(
                l10n.cloudWebdavHelpIntro,
                [
                  l10n.cloudWebdavHelpIntro1,
                  l10n.cloudWebdavHelpIntro2,
                  l10n.cloudWebdavHelpIntro3,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudWebdavHelpProviders,
                [
                  l10n.cloudWebdavHelpProvider1,
                  l10n.cloudWebdavHelpProvider2,
                  l10n.cloudWebdavHelpProvider3,
                  l10n.cloudWebdavHelpProvider4,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudWebdavHelpSteps,
                [
                  l10n.cloudWebdavHelpStep1,
                  l10n.cloudWebdavHelpStep2,
                  l10n.cloudWebdavHelpStep3,
                  l10n.cloudWebdavHelpStep4,
                  l10n.cloudWebdavHelpStep5,
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PiggyTokens.brandWebdav.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: PiggyTokens.brandWebdav, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.cloudWebdavHelpNote,
                        style: PiggyTextTokens.label(context)
                            .copyWith(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  void _showICloudHelpDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        wide: true,
        title: Row(
          children: [
            Icon(Icons.cloud, color: PiggyTokens.brandIcloud),
            const SizedBox(width: 8),
            Text(l10n.cloudIcloudHelpTitle),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpSection(
                l10n.cloudIcloudHelpPrerequisites,
                [
                  l10n.cloudIcloudHelpPrereq1,
                  l10n.cloudIcloudHelpPrereq2,
                  l10n.cloudIcloudHelpPrereq3,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudIcloudHelpCheckTitle,
                [
                  l10n.cloudIcloudHelpCheck1,
                  l10n.cloudIcloudHelpCheck2,
                  l10n.cloudIcloudHelpCheck3,
                  l10n.cloudIcloudHelpCheck4,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudIcloudHelpFaqTitle,
                [
                  '• ${l10n.cloudIcloudHelpFaq1}',
                  '• ${l10n.cloudIcloudHelpFaq2}',
                  '• ${l10n.cloudIcloudHelpFaq3}',
                  '• ${l10n.cloudIcloudHelpFaq4}',
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PiggyTokens.brandIcloud.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: PiggyTokens.brandIcloud, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.cloudIcloudHelpNote,
                        style: PiggyTextTokens.label(context)
                            .copyWith(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  void _showS3HelpDialog() {
    final l10n = AppLocalizations.of(context);
    showDialog(
      context: context,
      builder: (dialogContext) => AppDialogShell(
        wide: true,
        title: Row(
          children: [
            Icon(Icons.storage, color: PiggyTokens.brandS3),
            const SizedBox(width: 8),
            Text(l10n.cloudS3HelpTitle),
          ],
        ),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildHelpSection(
                l10n.cloudS3HelpIntro,
                [
                  l10n.cloudS3HelpIntro1,
                  l10n.cloudS3HelpIntro2,
                  l10n.cloudS3HelpIntro3,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudS3HelpProviders,
                [
                  l10n.cloudS3HelpProvider1,
                  l10n.cloudS3HelpProvider2,
                  l10n.cloudS3HelpProvider3,
                  l10n.cloudS3HelpProvider4,
                  l10n.cloudS3HelpProvider5,
                  l10n.cloudS3HelpProvider6,
                  l10n.cloudS3HelpProvider7,
                ],
              ),
              const SizedBox(height: 16),
              _buildHelpSection(
                l10n.cloudS3HelpSteps,
                [
                  l10n.cloudS3HelpStep1,
                  l10n.cloudS3HelpStep2,
                  l10n.cloudS3HelpStep3,
                  l10n.cloudS3HelpStep4,
                  l10n.cloudS3HelpStep5,
                ],
              ),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: PiggyTokens.brandS3.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                ),
                child: Row(
                  children: [
                    Icon(Icons.info_outline,
                        color: PiggyTokens.brandS3, size: 20),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        l10n.cloudS3HelpNote,
                        style: PiggyTextTokens.label(context)
                            .copyWith(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: Text(l10n.commonConfirm),
          ),
        ],
      ),
    );
  }

  Widget _buildHelpSection(String title, List<String> items) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: PiggyTextTokens.strongTitle(context).copyWith(fontSize: 14),
        ),
        const SizedBox(height: 8),
        ...items.map((item) => Padding(
              padding: const EdgeInsets.only(left: 8, bottom: 4),
              child: Text(
                item,
                style: PiggyTextTokens.label(context).copyWith(fontSize: 13),
              ),
            )),
      ],
    );
  }

  Future<void> _openGuide(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      if (mounted) {
        showToast(context, AppLocalizations.of(context).cloudCannotOpenLink);
      }
    }
  }

  Future<void> _switchService(CloudBackendType type) async {
    final store = ref.read(cloudServiceStoreProvider);
    // M16：激活配置读失败（安全存储故障）时显式提示并中止切换
    final CloudServiceConfig active;
    try {
      active = await ref.read(activeCloudConfigProvider.future);
    } catch (e) {
      logger.warning('CloudService', '读取激活配置失败: $e');
      if (mounted) showToast(context, e.toString());
      return;
    }

    if (active.type == type) return; // 已经是当前类型

    // iCloud: 先检查可用性
    if (type == CloudBackendType.icloud) {
      logger.info('CloudService', '========== 开始 iCloud 诊断 ==========');
      final icloudProvider = ICloudProvider();
      try {
        // 获取详细诊断信息
        final diagnostics = await icloudProvider.getDiagnostics();
        logger.info('CloudService', 'iCloud 诊断信息:');
        diagnostics.forEach((key, value) {
          logger.info('CloudService', '  $key: $value');
        });

        final isAvailable = await icloudProvider.isAvailable();
        logger.info('CloudService', 'iCloud 可用性: $isAvailable');
        logger.info('CloudService', '========== iCloud 诊断结束 ==========');

        if (!isAvailable) {
          if (mounted) {
            // 显示更详细的错误信息
            final cloudKitStatus = diagnostics['cloudKitStatus'] ?? 'unknown';
            final containerAvailable =
                diagnostics['containerAvailable'] ?? false;
            var detailMessage =
                AppLocalizations.of(context).cloudIcloudNotAvailableMessage;
            if (cloudKitStatus == 'noAccount') {
              detailMessage = '请在设置中登录 iCloud 账号';
            } else if (!containerAvailable) {
              detailMessage = 'iCloud 容器不可用，请确保 iCloud Drive 已开启';
            }
            await AppDialog.error(
              context,
              title: AppLocalizations.of(context).cloudIcloudNotAvailableTitle,
              message: detailMessage,
            );
          }
          return;
        }
      } catch (e, stack) {
        logger.error('CloudService', 'iCloud 可用性检查失败', e, stack);
        if (mounted) {
          await AppDialog.error(
            context,
            title: AppLocalizations.of(context).cloudIcloudNotAvailableTitle,
            message: '${AppLocalizations.of(context).commonError}: $e',
          );
        }
        return;
      }
    }

    // 确认切换
    if (!mounted) return;
    final confirmed = await AppDialog.confirm(
      context,
      title: AppLocalizations.of(context).cloudSwitchConfirmTitle,
      message: AppLocalizations.of(context).cloudSwitchConfirmMessage,
    );
    if (!confirmed || !mounted) return;

    try {
      // 登出（iCloud 使用系统账号，跳过登出）
      if (active.type != CloudBackendType.icloud &&
          active.type != CloudBackendType.local) {
        try {
          final authService = await ref.read(authServiceProvider.future);
          await authService.signOut();
        } catch (_) {
          // 忽略登出错误
        }
      }

      // 激活新配置
      final success = await store.activate(type);
      if (!success &&
          type != CloudBackendType.local &&
          type != CloudBackendType.icloud) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudSwitchFailedTitle,
              message:
                  AppLocalizations.of(context).cloudSwitchFailedConfigMissing);
        }
        return;
      }

      // 延迟刷新 providers，避免在 build 阶段触发 setState
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(activeCloudConfigProvider);
        ref.invalidate(supabaseConfigProvider);
        ref.invalidate(webdavConfigProvider);
        ref.invalidate(authServiceProvider);
        ref.invalidate(syncServiceProvider);
      });

      if (mounted) {
        showToast(context,
            AppLocalizations.of(context).cloudSwitchedTo(_getTypeName(type)));
      }
    } catch (e) {
      if (mounted) {
        await AppDialog.error(context,
            title: AppLocalizations.of(context).cloudSwitchFailedTitle,
            message: '$e');
      }
    }
  }

  Future<void> _configureService(CloudBackendType type) async {
    // 根据类型显示配置对话框
    if (type == CloudBackendType.supabase) {
      await _showSupabaseConfigDialog();
    } else if (type == CloudBackendType.webdav) {
      await _showWebdavConfigDialog();
    } else if (type == CloudBackendType.s3) {
      await _showS3ConfigDialog();
    }
  }

  Future<void> _showSupabaseConfigDialog() async {
    // M16：安全存储读失败时显式提示
    final CloudServiceConfig? existing;
    try {
      existing = await ref.read(supabaseConfigProvider.future);
    } catch (e) {
      logger.warning('CloudService', '读取 Supabase 配置失败: $e');
      if (mounted) showToast(context, e.toString());
      return;
    }

    if (!mounted) return;

    final result = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => _SupabaseConfigDialog(
        initialUrl: existing?.supabaseUrl ?? '',
        initialKey: existing?.supabaseAnonKey ?? '',
        initialBucket: existing?.supabaseBucket ?? '',
      ),
    );

    if (result != null) {
      if (!mounted) return;
      final url = result['url'] as String;
      final key = result['key'] as String;
      final bucket = result['bucket'] as String;

      // 对话框已进行内联校验，此处 cfg.valid 作为防御性检查
      final cfg = CloudServiceConfig(
        type: CloudBackendType.supabase,
        name: AppLocalizations.of(context).cloudCustomSupabaseTitle,
        supabaseUrl: url,
        supabaseAnonKey: key,
        supabaseBucket:
            bucket.isEmpty ? 'piggycount-backups' : bucket, // 业务层提供默认值
      );

      if (!cfg.valid) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudConfigInvalidTitle,
              message: AppLocalizations.of(context).cloudConfigInvalidMessage);
        }
        return;
      }

      try {
        await ref.read(cloudServiceStoreProvider).saveOnly(cfg);
        ref.invalidate(supabaseConfigProvider);
        // 刷新激活配置，确保同步服务使用最新配置
        ref.invalidate(activeCloudConfigProvider);
        if (mounted) {
          showToast(context, AppLocalizations.of(context).cloudConfigSaved);
        }
      } catch (e) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudSaveFailed,
              message: e.toString());
        }
      }
    }
  }

  Future<void> _showWebdavConfigDialog() async {
    // M16：安全存储读失败时显式提示
    final CloudServiceConfig? existing;
    try {
      existing = await ref.read(webdavConfigProvider.future);
    } catch (e) {
      logger.warning('CloudService', '读取 WebDAV 配置失败: $e');
      if (mounted) showToast(context, e.toString());
      return;
    }

    if (!mounted) return;

    final result = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => _WebdavConfigDialog(
        initialUrl: existing?.webdavUrl ?? '',
        initialUsername: existing?.webdavUsername ?? '',
        initialPassword: existing?.webdavPassword ?? '',
        // 未配置过时，默认使用项目名（ASCII 标识符）作为远程目录，避免本地化名称导致路径异常
        initialPath: existing?.webdavRemotePath ?? '/$_kDefaultProjectName',
        // 清空后保存时回写到输入框的默认值
        defaultPath: '/$_kDefaultProjectName',
      ),
    );

    if (result != null) {
      if (!mounted) return;
      final url = result['url'] as String;
      final username = result['username'] as String;
      final password = result['password'] as String;
      final path = result['path'] as String;

      // 对话框已进行内联校验，此处 cfg.valid 作为防御性检查
      final cfg = CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: AppLocalizations.of(context).cloudCustomWebdavTitle,
        webdavUrl: url,
        webdavUsername: username,
        webdavPassword: password,
        webdavRemotePath: path.isEmpty ? '/' : path,
      );

      if (!cfg.valid) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudConfigInvalidTitle,
              message: AppLocalizations.of(context).cloudConfigInvalidMessage);
        }
        return;
      }

      try {
        await ref.read(cloudServiceStoreProvider).saveOnly(cfg);
        ref.invalidate(webdavConfigProvider);
        // 刷新激活配置，确保同步服务使用最新配置
        ref.invalidate(activeCloudConfigProvider);
        if (mounted) {
          showToast(context, AppLocalizations.of(context).cloudConfigSaved);
        }
      } catch (e) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudSaveFailed,
              message: e.toString());
        }
      }
    }
  }

  Future<void> _showS3ConfigDialog() async {
    // M16：安全存储读失败时显式提示
    final CloudServiceConfig? existing;
    try {
      existing = await ref.read(s3ConfigProvider.future);
    } catch (e) {
      logger.warning('CloudService', '读取 S3 配置失败: $e');
      if (mounted) showToast(context, e.toString());
      return;
    }

    if (!mounted) return;

    final result = await showModalBottomSheet<Map<String, dynamic>?>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (dialogContext) => _S3ConfigDialog(
        initialEndpoint: existing?.s3Endpoint ?? '',
        initialRegion: existing?.s3Region ?? 'us-east-1',
        initialAccessKey: existing?.s3AccessKey ?? '',
        initialSecretKey: existing?.s3SecretKey ?? '',
        // 未配置过时，默认使用项目名（ASCII 小写标识符，符合 S3 桶名规范）
        initialBucket: existing?.s3Bucket ?? _kDefaultProjectName,
        initialUseSSL: existing?.s3UseSSL ?? true,
        initialPort: existing?.s3Port,
        // 清空后保存时回写到输入框的默认值
        defaultBucket: _kDefaultProjectName,
      ),
    );

    if (result != null) {
      if (!mounted) return;
      var endpoint = result['endpoint'] as String;
      final region = result['region'] as String;
      final accessKey = result['accessKey'] as String;
      final secretKey = result['secretKey'] as String;
      final bucket = result['bucket'] as String;
      final useSSL = result['useSSL'] as bool;
      final port = result['port'] as int?;

      // 自动去除 endpoint 中的 http:// 或 https:// 前缀
      endpoint = endpoint.replaceFirst(RegExp(r'^https?://'), '');

      // 对话框已进行内联校验，此处 cfg.valid 作为防御性检查
      final cfg = CloudServiceConfig(
        type: CloudBackendType.s3,
        name: AppLocalizations.of(context).cloudCustomS3Title,
        s3Endpoint: endpoint,
        s3Region: region.isEmpty ? 'us-east-1' : region,
        s3AccessKey: accessKey,
        s3SecretKey: secretKey,
        s3Bucket: bucket,
        s3UseSSL: useSSL,
        s3Port: port,
      );

      if (!cfg.valid) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudConfigInvalidTitle,
              message: AppLocalizations.of(context).cloudConfigInvalidMessage);
        }
        return;
      }

      try {
        await ref.read(cloudServiceStoreProvider).saveOnly(cfg);
        ref.invalidate(s3ConfigProvider);
        // 刷新激活配置，确保同步服务使用最新配置
        ref.invalidate(activeCloudConfigProvider);
        if (mounted) {
          showToast(context, AppLocalizations.of(context).cloudConfigSaved);
        }
      } catch (e) {
        if (mounted) {
          await AppDialog.error(context,
              title: AppLocalizations.of(context).cloudSaveFailed,
              message: e.toString());
        }
      }
    }
  }

  String _getTypeName(CloudBackendType type) {
    switch (type) {
      case CloudBackendType.local:
        return AppLocalizations.of(context).cloudLocalStorageTitle;
      case CloudBackendType.supabase:
        return 'Supabase';
      case CloudBackendType.webdav:
        return 'WebDAV';
      case CloudBackendType.icloud:
        return 'iCloud';
      case CloudBackendType.s3:
        return 'S3';
    }
  }

  // 测试连接
  /// P1-4：后端能力静态映射（连接测试成功弹窗的透明化说明行）。
  ///
  /// 各后端能力是实现事实（随包版本演进），非运行时探测 ——
  /// 与包内 ConditionalWriteStorage/BinaryCapableStorage 的实现矩阵
  /// 对齐，改动后端实现时须同步更新此表。
  String _backendCapabilityLine(AppLocalizations l10n, CloudBackendType t) {
    // 并发保护：S3 原子条件写 / WebDAV eTag 预检近似 / 其余校验兜底
    final concurrency = switch (t) {
      CloudBackendType.s3 => l10n.cloudCapYes,
      CloudBackendType.webdav => l10n.cloudCapApprox,
      _ => l10n.cloudCapNo,
    };
    // 二进制传输：S3/WebDAV/Supabase 原生字节 / iCloud base64 文本
    //（P2-3 留待迭代：method channel 原生侧改造，无法本环境验证）
    final binary = switch (t) {
      CloudBackendType.icloud => l10n.cloudCapNo,
      _ => l10n.cloudCapYes,
    };
    return l10n.cloudCapabilityLine(concurrency, binary);
  }

  Future<void> _testConnection(CloudServiceConfig config,
      {bool showDialog = true}) async {
    if (!config.valid || config.type == CloudBackendType.local) return;

    // 在 async gap 前缓存 l10n，避免 dispose 后 context 失效
    final l10n = AppLocalizations.of(context);
    setState(() => _testingConnection = true);
    try {
      bool connectionSuccess = false;
      String? errorDetail;

      try {
        switch (config.type) {
          case CloudBackendType.local:
            break;

          case CloudBackendType.supabase:
            // Supabase 连接测试 - 查询不存在的表验证 URL 和 anon key
            // 200 或 404 表示连接正常且 key 有效，401/403 表示 key 无效
            //
            // SEC-01（对齐 provider 层 HTTPS 强制）：连接测试同样不得
            // 把 apikey/Authorization 头发往 http:// 明文链路——配置
            // 对话框尚未保存时 provider 校验管不到这里，测试路径必须
            // 自行校验 scheme。
            final supabaseScheme =
                Uri.tryParse(config.supabaseUrl!)?.scheme.toLowerCase() ?? '';
            if (supabaseScheme != 'https') {
              throw Exception('Supabase 地址必须使用 HTTPS'
                  '（当前为 ${supabaseScheme.isEmpty ? '(无协议)' : '$supabaseScheme://'}，'
                  'anonKey 将在该链路上明文传输）');
            }
            final testUrl = Uri.parse(
                '${config.supabaseUrl}/rest/v1/_piggycount_health_check?select=id&limit=1');
            final response = await http.get(
              testUrl,
              headers: {
                'apikey': config.supabaseAnonKey!,
                'Authorization': 'Bearer ${config.supabaseAnonKey}',
              },
            ).timeout(const Duration(seconds: 10));

            if (response.statusCode == 200 ||
                response.statusCode == 404 ||
                response.statusCode == 406) {
              connectionSuccess = true;
            } else if (response.statusCode == 401 ||
                response.statusCode == 403) {
              throw Exception(l10n.cloudErrorAuthFailed);
            } else {
              throw Exception(
                  l10n.cloudErrorServerStatus('${response.statusCode}'));
            }
            break;

          case CloudBackendType.webdav:
            // WebDAV 连接测试 - 发送 OPTIONS 请求
            //
            // SEC-02（两处旁路收口）：
            // ① scheme 校验——provider 层 P2-7 强制 HTTPS，但历史遗留的
            //   http:// 配置（保存于 P2-7 之前）在连接测试（含页面打开的
            //   自动测试）仍会把 Basic 凭据（即用户网盘主账号密码）明文
            //   发出。测试路径必须先校验再发请求；
            // ② 禁止重定向跟随——provider 层 S23 加固（followRedirects=
            //   false，防 3xx 把凭据原样转发到第三方域）在裸 http.Request
            //   上不生效。dart:io 默认跟随 301/302/303 并携带 Authorization
            //   头，中间人 302 即可截获凭据。这里用 http.Client 并显式
            //   关闭重定向，3xx 一律按错误呈现（与 provider 行为一致：
            //   引导用户直接填最终地址）。
            final webdavUrl = Uri.parse(config.webdavUrl!);
            if (webdavUrl.scheme.toLowerCase() != 'https') {
              throw Exception('WebDAV 地址必须使用 HTTPS'
                  '（当前为 ${webdavUrl.scheme}://，'
                  'Basic Auth 凭据将在链路上明文传输）');
            }
            final credentials = base64Encode(
              utf8.encode('${config.webdavUsername}:${config.webdavPassword}'),
            );

            final client = http.Client();
            try {
              final request = http.Request('OPTIONS', webdavUrl)
                ..followRedirects = false
                ..maxRedirects = 0
                ..headers['Authorization'] = 'Basic $credentials';

              final streamedResponse = await client
                  .send(request)
                  .timeout(const Duration(seconds: 10));
              final response = await http.Response.fromStream(streamedResponse);

              if (response.statusCode == 200 || response.statusCode == 204) {
                final davHeader = response.headers['dav'];
                if (davHeader != null ||
                    response.headers.containsKey('allow')) {
                  connectionSuccess = true;
                } else {
                  throw Exception(l10n.cloudErrorWebdavNotSupported);
                }
              } else if (response.statusCode == 401) {
                throw Exception(l10n.cloudErrorAuthFailedCredentials);
              } else if (response.statusCode == 403) {
                throw Exception(l10n.cloudErrorAccessDenied);
              } else if (response.statusCode == 404) {
                throw Exception(l10n.cloudErrorPathNotFound(webdavUrl.path));
              } else if (response.statusCode >= 300 &&
                  response.statusCode < 400) {
                // SEC-02②：不跟随重定向，3xx 直接报错（与 provider S23 一致）
                throw Exception('WebDAV 服务器返回重定向（${response.statusCode}），'
                    '请直接填写重定向后的最终地址，避免凭据被转发到第三方域名');
              } else {
                throw Exception(
                    l10n.cloudErrorServerStatus('${response.statusCode}'));
              }
            } finally {
              client.close();
            }
            break;

          case CloudBackendType.icloud:
            // iCloud 连接测试
            final icloudProvider = ICloudProvider();
            final isAvailable = await icloudProvider.isAvailable();
            if (isAvailable) {
              // 尝试初始化容器
              try {
                await icloudProvider.initialize({});
                connectionSuccess = true;
              } catch (e) {
                throw Exception('iCloud 容器初始化失败: $e');
              }
            } else {
              throw Exception('iCloud 不可用，请检查设备是否已登录 iCloud 并开启 iCloud Drive');
            }
            break;

          case CloudBackendType.s3:
            // S3 连接测试 - 尝试列出对象（ListObjects）
            try {
              // 确保 endpoint 不包含协议前缀（兼容旧配置）
              final cleanedConfig = CloudServiceConfig(
                type: config.type,
                name: config.name,
                s3Endpoint:
                    config.s3Endpoint?.replaceFirst(RegExp(r'^https?://'), ''),
                s3Region: config.s3Region,
                s3AccessKey: config.s3AccessKey,
                s3SecretKey: config.s3SecretKey,
                s3Bucket: config.s3Bucket,
                s3UseSSL: config.s3UseSSL,
                s3Port: config.s3Port,
                // 寻址方式必须随配置透传，否则连接测试与真实同步的
                // path-style / virtual-hosted 推断可能分叉
                s3ForcePathStyle: config.s3ForcePathStyle,
              );

              logger.info('CloudServicePage',
                  'S3 连接测试开始: endpoint=${cleanedConfig.s3Endpoint}, bucket=${cleanedConfig.s3Bucket}');

              final services = await createCloudServices(cleanedConfig);

              logger.info('CloudServicePage',
                  'S3 provider 创建结果: ${services.provider != null ? "成功" : "失败"}');

              if (services.provider == null) {
                throw Exception(
                    'S3 provider 初始化失败 - createCloudServices 返回 null');
              }

              // N-1 修复：测试用 provider 必须在 finally 释放 ——
              // S3Provider.dispose 会关闭底层 http.Client 连接池；此前
              // 每次连接测试（含页面打开时的自动测试）都泄漏一份连接池
              // （包内 S-M2 修过的同款问题在 UI 层复发）。
              try {
                // 实际测试连接：尝试列出 bucket 中的文件
                // 这会触发真正的 S3 API 调用，验证凭证和连接
                logger.info('CloudServicePage', 'S3 开始测试列出文件');
                await services.provider!.storage.list(path: '');

                logger.info('CloudServicePage', 'S3 连接测试成功');
                connectionSuccess = true;
              } finally {
                try {
                  await services.provider!.dispose();
                } catch (e) {
                  logger.warning(
                      'CloudServicePage', 'S3 测试 provider 释放失败（忽略）: $e');
                }
              }
            } catch (e, stackTrace) {
              logger.error('CloudServicePage', 'S3 连接测试失败: $e', e, stackTrace);
              // 提取最有用的错误信息
              String errorMsg = e.toString();
              if (errorMsg.contains('CloudConfigurationException:')) {
                errorMsg =
                    errorMsg.replaceFirst('CloudConfigurationException: ', '');
              } else if (errorMsg.contains('Exception:')) {
                errorMsg = errorMsg.replaceFirst('Exception: ', '');
              }
              throw Exception(errorMsg);
            }
            break;
        }
      } on http.ClientException catch (e) {
        connectionSuccess = false;
        errorDetail = l10n.cloudErrorNetwork(e.message);
      } on Exception catch (e) {
        connectionSuccess = false;
        errorDetail = e.toString().replaceFirst('Exception: ', '');
      } catch (e) {
        connectionSuccess = false;
        errorDetail = e.toString();
      }

      if (mounted) {
        setState(() {
          _connectionTestResults[config.id] = connectionSuccess;
        });
      }

      // 只在手动测试时显示对话框
      if (mounted && showDialog) {
        if (connectionSuccess) {
          // P1-4：连接成功时附后端能力说明 —— 把「条件写/二进制」的
          // 降级从静默变透明（Supabase/iCloud 并发保护为校验兜底、
          // iCloud 二进制为 base64 文本形态），用户在选型时可见差异。
          await AppDialog.info(context,
              title: l10n.cloudTestSuccessTitle,
              message:
                  '${l10n.cloudTestSuccessMessage}\n\n${l10n.cloudCapabilityTitle}：'
                  '${_backendCapabilityLine(l10n, config.type)}');
        } else {
          await AppDialog.error(context,
              title: l10n.cloudTestFailedTitle,
              message: errorDetail ?? l10n.cloudTestFailedMessage);
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _connectionTestResults[config.id] = false;
        });
      }
      // 只在手动测试时显示错误对话框
      if (mounted && showDialog) {
        await AppDialog.error(context,
            title: l10n.cloudTestErrorTitle, message: e.toString());
      }
    } finally {
      if (mounted) setState(() => _testingConnection = false);
    }
  }
}

class _SupabaseConfigDialog extends StatefulWidget {
  final String initialUrl;
  final String initialKey;
  final String initialBucket;

  const _SupabaseConfigDialog({
    required this.initialUrl,
    required this.initialKey,
    required this.initialBucket,
  });

  @override
  State<_SupabaseConfigDialog> createState() => _SupabaseConfigDialogState();
}

class _SupabaseConfigDialogState extends State<_SupabaseConfigDialog> {
  late final TextEditingController urlController;
  late final TextEditingController keyController;
  late final TextEditingController bucketController;

  // 内联校验错误状态：Supabase 必填字段为 URL 和 Anon Key
  bool _urlError = false;
  bool _keyError = false;

  // SEC-05：anonKey 按凭据处理（连接测试随 Authorization 头发送、
  // 持久化到安全存储），输入框与 WebDAV 密码/S3 SecretKey 同款遮蔽
  // + 眼睛切换，防肩窥/屏幕录制。
  bool obscureAnonKey = true;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.initialUrl);
    keyController = TextEditingController(text: widget.initialKey);
    bucketController = TextEditingController(text: widget.initialBucket);
  }

  @override
  void dispose() {
    urlController.dispose();
    keyController.dispose();
    bucketController.dispose();
    super.dispose();
  }

  // 校验必填字段，返回是否全部通过
  bool _validate() {
    bool hasError = false;
    setState(() {
      _urlError = urlController.text.trim().isEmpty;
      _keyError = keyController.text.trim().isEmpty;
      hasError = _urlError || _keyError;
    });
    return !hasError;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _CloudConfigSheet(
      title: l10n.cloudConfigureSupabaseTitle,
      cancelLabel: l10n.commonCancel,
      saveLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(null),
      onSave: () {
        if (_validate()) {
          Navigator.of(context).pop({
            'url': urlController.text.trim(),
            'key': keyController.text.trim(),
            'bucket': bucketController.text.trim(),
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudSupabaseUrlLabel,
              hint: l10n.cloudSupabaseUrlHint,
              errorText: _urlError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudSupabaseUrlLabel)
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {
              if (_urlError) setState(() => _urlError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: keyController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudAnonKeyLabel,
              hint: l10n.cloudSupabaseAnonKeyHintLong,
              errorText: _keyError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudAnonKeyLabel)
                  : null,
              // SEC-05：anonKey 是长效凭据（Storage 读写能力），
              // 与 WebDAV 密码/S3 SecretKey 同款遮蔽 + 眼睛切换
              suffixIcon: IconButton(
                icon: Icon(
                  obscureAnonKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                tooltip: l10n.tooltipToggleVisibility,
                onPressed: () {
                  setState(() {
                    obscureAnonKey = !obscureAnonKey;
                  });
                },
              ),
            ),
            obscureText: obscureAnonKey,
            keyboardType: TextInputType.text,
            minLines: 1,
            maxLines: 5,
            onChanged: (_) {
              if (_keyError) setState(() => _keyError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: bucketController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudSupabaseBucketLabel,
              hint: l10n.cloudSupabaseBucketHint,
            ),
            keyboardType: TextInputType.text,
          ),
        ],
      ),
    );
  }
}

// WebDAV配置对话框(独立Widget,避免controller生命周期问题)
class _WebdavConfigDialog extends StatefulWidget {
  final String initialUrl;
  final String initialUsername;
  final String initialPassword;
  final String initialPath;

  /// 远程路径为空时回写到输入框的默认值
  final String defaultPath;

  const _WebdavConfigDialog({
    required this.initialUrl,
    required this.initialUsername,
    required this.initialPassword,
    required this.initialPath,
    required this.defaultPath,
  });

  @override
  State<_WebdavConfigDialog> createState() => _WebdavConfigDialogState();
}

class _WebdavConfigDialogState extends State<_WebdavConfigDialog> {
  late final TextEditingController urlController;
  late final TextEditingController usernameController;
  late final TextEditingController passwordController;
  late final TextEditingController pathController;
  bool obscurePassword = true;

  // 内联校验错误状态：true 表示该字段有错误（为空）
  bool _urlError = false;
  bool _usernameError = false;
  bool _passwordError = false;

  @override
  void initState() {
    super.initState();
    urlController = TextEditingController(text: widget.initialUrl);
    usernameController = TextEditingController(text: widget.initialUsername);
    passwordController = TextEditingController(text: widget.initialPassword);
    pathController = TextEditingController(text: widget.initialPath);
  }

  @override
  void dispose() {
    urlController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    pathController.dispose();
    super.dispose();
  }

  // 校验必填字段，返回是否全部通过
  bool _validate() {
    bool hasError = false;
    setState(() {
      _urlError = urlController.text.trim().isEmpty;
      _usernameError = usernameController.text.trim().isEmpty;
      _passwordError = passwordController.text.trim().isEmpty;
      hasError = _urlError || _usernameError || _passwordError;
    });
    // 有错误时不弹出对话框，让用户看到内联错误提示
    return !hasError;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _CloudConfigSheet(
      title: l10n.cloudConfigureWebdavTitle,
      cancelLabel: l10n.commonCancel,
      saveLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(null),
      onSave: () {
        // 远程路径为空时回写默认值到输入框，确保用户看到实际保存的值
        if (pathController.text.trim().isEmpty) {
          pathController.text = widget.defaultPath;
        }
        if (_validate()) {
          Navigator.of(context).pop({
            'url': urlController.text.trim(),
            'username': usernameController.text.trim(),
            'password': passwordController.text.trim(),
            'path': pathController.text.trim(),
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: urlController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudWebdavUrlLabel,
              hint: l10n.cloudWebdavUrlHint,
              errorText: _urlError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudWebdavUrlLabel)
                  : null,
            ),
            onChanged: (_) {
              if (_urlError) setState(() => _urlError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: usernameController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudWebdavUsernameLabel,
              errorText: _usernameError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudWebdavUsernameLabel)
                  : null,
            ),
            onChanged: (_) {
              if (_usernameError) setState(() => _usernameError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: passwordController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudWebdavPasswordLabel,
              errorText: _passwordError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudWebdavPasswordLabel)
                  : null,
              suffixIcon: IconButton(
                icon: Icon(
                  obscurePassword
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                tooltip: l10n.tooltipTogglePassword,
                onPressed: () {
                  setState(() {
                    obscurePassword = !obscurePassword;
                  });
                },
              ),
            ),
            obscureText: obscurePassword,
            onChanged: (_) {
              if (_passwordError) setState(() => _passwordError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: pathController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudWebdavRemotePathLabel,
              hint: l10n.cloudWebdavPathHint,
            ),
          ),
        ],
      ),
    );
  }
}

// S3配置对话框(独立Widget,避免controller生命周期问题)
class _S3ConfigDialog extends StatefulWidget {
  final String initialEndpoint;
  final String initialRegion;
  final String initialAccessKey;
  final String initialSecretKey;
  final String initialBucket;
  final bool initialUseSSL;
  final int? initialPort;

  /// 存储桶名为空时回写到输入框的默认值
  final String defaultBucket;

  const _S3ConfigDialog({
    required this.initialEndpoint,
    required this.initialRegion,
    required this.initialAccessKey,
    required this.initialSecretKey,
    required this.initialBucket,
    required this.initialUseSSL,
    required this.defaultBucket,
    this.initialPort,
  });

  @override
  State<_S3ConfigDialog> createState() => _S3ConfigDialogState();
}

class _S3ConfigDialogState extends State<_S3ConfigDialog> {
  late final TextEditingController endpointController;
  late final TextEditingController regionController;
  late final TextEditingController accessKeyController;
  late final TextEditingController secretKeyController;
  late final TextEditingController bucketController;
  late final TextEditingController portController;
  late bool useSSL;
  bool obscureSecretKey = true;

  // 内联校验错误状态：S3 必填字段为 endpoint、accessKey、secretKey、bucket
  bool _endpointError = false;
  bool _accessKeyError = false;
  bool _secretKeyError = false;
  bool _bucketError = false;

  @override
  void initState() {
    super.initState();
    endpointController = TextEditingController(text: widget.initialEndpoint);
    regionController = TextEditingController(text: widget.initialRegion);
    accessKeyController = TextEditingController(text: widget.initialAccessKey);
    secretKeyController = TextEditingController(text: widget.initialSecretKey);
    bucketController = TextEditingController(text: widget.initialBucket);
    portController =
        TextEditingController(text: widget.initialPort?.toString() ?? '');
    useSSL = widget.initialUseSSL;
  }

  @override
  void dispose() {
    endpointController.dispose();
    regionController.dispose();
    accessKeyController.dispose();
    secretKeyController.dispose();
    bucketController.dispose();
    portController.dispose();
    super.dispose();
  }

  // 校验必填字段，返回是否全部通过
  bool _validate() {
    bool hasError = false;
    setState(() {
      _endpointError = endpointController.text.trim().isEmpty;
      _accessKeyError = accessKeyController.text.trim().isEmpty;
      _secretKeyError = secretKeyController.text.trim().isEmpty;
      _bucketError = bucketController.text.trim().isEmpty;
      hasError =
          _endpointError || _accessKeyError || _secretKeyError || _bucketError;
    });
    return !hasError;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return _CloudConfigSheet(
      title: l10n.cloudConfigureS3Title,
      cancelLabel: l10n.commonCancel,
      saveLabel: l10n.commonSave,
      onCancel: () => Navigator.of(context).pop(null),
      onSave: () {
        // 存储桶名为空时回写默认值到输入框，确保用户看到实际保存的值
        if (bucketController.text.trim().isEmpty) {
          bucketController.text = widget.defaultBucket;
        }
        if (_validate()) {
          final portText = portController.text.trim();
          final port = portText.isEmpty ? null : int.tryParse(portText);

          Navigator.of(context).pop({
            'endpoint': endpointController.text.trim(),
            'region': regionController.text.trim(),
            'accessKey': accessKeyController.text.trim(),
            'secretKey': secretKeyController.text.trim(),
            'bucket': bucketController.text.trim(),
            'useSSL': useSSL,
            'port': port,
          });
        }
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: endpointController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3EndpointLabel,
              hint: l10n.cloudS3EndpointHint,
              errorText: _endpointError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudS3EndpointLabel)
                  : null,
            ),
            keyboardType: TextInputType.url,
            onChanged: (_) {
              if (_endpointError) setState(() => _endpointError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: regionController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3RegionLabel,
              hint: l10n.cloudS3RegionHint,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: accessKeyController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3AccessKeyLabel,
              hint: l10n.cloudS3AccessKeyHint,
              errorText: _accessKeyError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudS3AccessKeyLabel)
                  : null,
            ),
            onChanged: (_) {
              if (_accessKeyError) setState(() => _accessKeyError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: secretKeyController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3SecretKeyLabel,
              hint: l10n.cloudS3SecretKeyHint,
              errorText: _secretKeyError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudS3SecretKeyLabel)
                  : null,
              suffixIcon: IconButton(
                icon: Icon(
                  obscureSecretKey
                      ? Icons.visibility_outlined
                      : Icons.visibility_off_outlined,
                  size: 20,
                ),
                tooltip: l10n.tooltipToggleVisibility,
                onPressed: () {
                  setState(() {
                    obscureSecretKey = !obscureSecretKey;
                  });
                },
              ),
            ),
            obscureText: obscureSecretKey,
            onChanged: (_) {
              if (_secretKeyError) setState(() => _secretKeyError = false);
            },
          ),
          const SizedBox(height: 16),
          TextField(
            controller: bucketController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3BucketLabel,
              hint: l10n.cloudS3BucketHint,
              errorText: _bucketError
                  ? l10n.fieldCannotBeEmpty(l10n.cloudS3BucketLabel)
                  : null,
            ),
            onChanged: (_) {
              if (_bucketError) setState(() => _bucketError = false);
            },
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(l10n.cloudS3UseSSLLabel),
              ),
              PiggySwitcher(
                value: useSSL,
                // 无障碍基线：开关补语义标签，读出所控制的设置项名称
                semanticLabel: l10n.cloudS3UseSSLLabel,
                onChanged: (value) {
                  setState(() {
                    useSSL = value;
                  });
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: portController,
            decoration: piggyOutlinedDecoration(
              context,
              label: l10n.cloudS3PortLabel,
              hint: l10n.cloudS3PortHint,
            ),
            keyboardType: TextInputType.number,
          ),
        ],
      ),
    );
  }
}

/// 云服务配置底部抽屉外壳。
///
/// 悬浮卡片结构：居中标题 + 可滚动表单 + 底部 `PiggySheetActions`
/// 双等宽取消/保存按钮，供 Supabase / WebDAV / S3 三个配置表单复用，
/// 避免三份底部抽屉骨架代码重复。与加密「设置密码」抽屉
/// （`widgets/encryption/password_setup_dialog.dart`）保持同一套外壳口径。
class _CloudConfigSheet extends StatelessWidget {
  final String title;
  final Widget child;
  final String cancelLabel;
  final String saveLabel;
  final VoidCallback onCancel;
  final VoidCallback onSave;

  const _CloudConfigSheet({
    required this.title,
    required this.child,
    required this.cancelLabel,
    required this.saveLabel,
    required this.onCancel,
    required this.onSave,
  });

  @override
  Widget build(BuildContext context) {
    // 悬浮卡片式表单抽屉外壳，与加密「设置密码」抽屉
    // （widgets/encryption/password_setup_dialog.dart）同一套口径：
    // 键盘避让 → SafeArea 吃掉底部安全区 → 四周留距 → 显式 Material
    // （transparent 路由底不提供 Material 祖先，缺了 TextField 直接红屏）
    // → 卡片高度交给内容，超高（键盘弹出 / S3 长表单 / 大字号）时整卡滚动。
    return KeyboardBottomInsetPadding(
      extra: PiggyDimens.p16,
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p16),
          child: Material(
            color: PiggyTokens.surfaceElevated(context),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            clipBehavior: Clip.antiAlias,
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p20,
                PiggyDimens.p20,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    title,
                    textAlign: TextAlign.center,
                    style: PiggyTextTokens.strongTitle(context)
                        .copyWith(fontSize: 17),
                  ),
                  const SizedBox(height: PiggyDimens.p16),
                  child,
                  const SizedBox(height: PiggyDimens.p20),
                  // 底部操作：双等宽大按钮（取消描边 + 保存填充，全站统一口径）。
                  PiggySheetActions(
                    cancelLabel: cancelLabel,
                    confirmLabel: saveLabel,
                    onCancel: onCancel,
                    onConfirm: onSave,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
