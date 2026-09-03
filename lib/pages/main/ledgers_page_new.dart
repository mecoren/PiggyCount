/// 重构后的账本列表页面
///
/// 集成本地账本 + 远程账本管理
library;

import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudBackendType;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../providers.dart';
import '../../providers/currency_providers.dart';
import '../../models/ledger_display_item.dart';
import '../../cloud/transactions_sync_manager.dart';
import '../../cloud/sync_service.dart';
import '../../cloud/sync_diff_service.dart' show SyncChange;
import '../../cloud/cloud_feature_flags.dart';
import '../../cloud/sync/sync_engine.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../cloud/member_list_page.dart';
import '../cloud/member_stats_page.dart';
import '../cloud/join_shared_ledger_page.dart';
import '../cloud/upload_conflict_helper.dart';
import '../budget/budget_page.dart';
import '../cloud/sync_preview_dialog.dart' show showSyncPreviewDialog;
import '../../styles/tokens.dart';
import '../../utils/currencies.dart';
import '../../services/attachment_service.dart';
import '../../services/system/logger_service.dart';
import '../../utils/ui_scale_extensions.dart';
import '../../utils/format_utils.dart';
import '../../services/billing/post_processor.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/budget_providers.dart';
import '../../widget/widget_manager.dart';

class LedgersPageNew extends ConsumerStatefulWidget {
  /// 进入页面后自动弹出「创建账本」对话框。用于首页账本胶囊在没账本时直接
  /// 引导用户新建,省一步点击。
  final bool autoOpenCreateDialog;

  const LedgersPageNew({super.key, this.autoOpenCreateDialog = false});

  @override
  ConsumerState<LedgersPageNew> createState() => _LedgersPageNewState();
}

class _LedgersPageNewState extends ConsumerState<LedgersPageNew> {
  bool _isRestoring = false;
  bool _isUploadingAll = false;

  @override
  void initState() {
    super.initState();
    if (widget.autoOpenCreateDialog) {
      // 等首帧渲染完再弹,否则 context 上面没 Navigator 栈无法 showDialog。
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCreateLedgerDialog(context);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentId = ref.watch(currentLedgerIdProvider);
    // 使用新的分离提供者：本地（快速）和远程（慢速）
    final localLedgersAsync = ref.watch(localLedgersProvider);
    final remoteLedgersAsync = ref.watch(remoteLedgersProvider);

    // 监听导入进度，当导入完成时自动刷新账本列表和同步状态
    ref.listen<ImportProgress>(importProgressProvider, (previous, next) {
      // 检测到导入完成（从运行中变为完成状态）
      if (previous?.running == true &&
          next.isJustCompleted &&
          next.ledgerId != null) {
        logger.info('Ledger', '🟢 [LedgersPage] 检测到导入完成: ledgerId=${next.ledgerId}');
        // 触发同步状态刷新和账本列表刷新
        PostProcessor.sync(ref, ledgerId: next.ledgerId!);
      }
    });

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context).ledgersTitle,
        // 唯一入口是首页 ledger picker 的「管理账本」按钮通过 Navigator.push
        // 进来,可以 pop。showBack=true 让用户回到首页。
        showBack: true,
        actions: [
          // 新建账本
          IconButton(
            tooltip: AppLocalizations.of(context).ledgersCreate,
            onPressed: () => _showCreateLedgerDialog(context),
            icon: Icon(Icons.add, color: PiggyTokens.textPrimary(context)),
          ),
          // 刷新
          IconButton(
            onPressed: () {
              ref.read(ledgerListRefreshProvider.notifier).state++;
            },
            icon: Icon(Icons.refresh, color: PiggyTokens.textPrimary(context)),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: _buildProgressiveList(
                context,
                ref,
                currentId,
                localLedgersAsync,
                remoteLedgersAsync,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 渐进式加载列表：先显示本地，再加载远程
  Widget _buildProgressiveList(
    BuildContext context,
    WidgetRef ref,
    int? currentId,
    AsyncValue<List<LedgerDisplayItem>> localAsync,
    AsyncValue<List<LedgerDisplayItem>> remoteAsync,
  ) {
    // 获取本地账本（快速）
    final localLedgers = localAsync.valueOrNull ?? [];
    final localError = localAsync.error;

    // 获取远程账本（慢速）
    final remoteLedgers = remoteAsync.valueOrNull ?? [];
    final remoteLoading = remoteAsync.isLoading;
    final remoteError = remoteAsync.error;

    // 如果本地也在加载中且没有缓存数据，显示全局加载
    if (localAsync.isLoading && localLedgers.isEmpty) {
      return DelayedSkeleton(
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
      );
    }

    // 如果本地加载失败，显示错误
    if (localError != null && localLedgers.isEmpty) {
      return Center(
        child: Text('${AppLocalizations.of(context).commonError}: $localError'),
      );
    }

    // 如果本地和远程都为空 — 用 AppEmpty(蜜蜂图标 + 文案)符合空态规范,
    // 下面加一个 OutlinedButton 引导新建账本(welcome 未勾默认账本 / 老用户
    // 导入配置不含账本的场景第一时间能直接动手)
    if (localLedgers.isEmpty && remoteLedgers.isEmpty && !remoteLoading) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppEmpty(text: AppLocalizations.of(context).ledgersEmpty),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => _showCreateLedgerDialog(context),
              icon: const Icon(Icons.add),
              label: Text(AppLocalizations.of(context).ledgersNew),
            ),
          ],
        ),
      );
    }

    // 构建列表（本地 + 远程）
    return _buildSplitLedgerList(
      context,
      ref,
      localLedgers,
      remoteLedgers,
      currentId,
      remoteLoading: remoteLoading,
      remoteError: remoteError,
    );
  }

  /// 构建分离的账本列表（本地 + 远程）
  Widget _buildSplitLedgerList(
    BuildContext context,
    WidgetRef ref,
    List<LedgerDisplayItem> localLedgers,
    List<LedgerDisplayItem> remoteLedgers,
    int? currentId, {
    bool remoteLoading = false,
    Object? remoteError,
  }) {
    // 共享账本是 PiggyCount Cloud 独有能力(server 端的成员管理 / WS fan-out
    // 都在 PiggyCount Cloud 后端),非 PiggyCount Cloud 用户(local / WebDAV /
    // S3 / Supabase 等)就算扫码也走不通,按钮藏起来避免误导。
    final cloudConfigAsync = ref.watch(activeCloudConfigProvider);
    // 共享账本是云端协同（PiggyCount Cloud）的独占能力；云端协同关闭时
    // （见 cloud_feature_flags.dart）不再展示「加入共享账本」入口。
    final isPiggyCountCloud = cloudConfigAsync.valueOrNull?.type ==
            CloudBackendType.piggycountCloud &&
        kPiggyCountCloudEnabled;

    return ListView(
      padding: EdgeInsets.symmetric(
        vertical: 8.0.scaled(context, ref),
      ),
      children: [
        // §7 共享账本入口 — 跟 web 端 LedgersSection 顶部"加入共享账本"
        // 按钮一致,放在列表顶部,比 header 角落 icon 显眼。
        if (isPiggyCountCloud)
          Padding(
            padding: EdgeInsets.fromLTRB(
              16.0.scaled(context, ref),
              4.0.scaled(context, ref),
              16.0.scaled(context, ref),
              8.0.scaled(context, ref),
            ),
            child: OutlinedButton.icon(
              icon: const Icon(Icons.group_add_outlined, size: 18),
              label: Text(AppLocalizations.of(context).sharedJoinPageTitle),
              onPressed: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const JoinSharedLedgerPage(),
                  ),
                );
              },
              style: OutlinedButton.styleFrom(
                minimumSize: Size(double.infinity, 40.0.scaled(context, ref)),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
                ),
              ),
            ),
          ),
        // 本地账本区域
        if (localLedgers.isNotEmpty) ...[
          _SectionHeader(
            title: AppLocalizations.of(context).ledgersLocal,
            trailing: localLedgers.length.toString(),
            // 「全部上传」仅快照同步类（WebDAV/S3/Supabase/iCloud）显示：
            // PiggyCount Cloud 是增量自动同步、未配置云服务时无上传目标，
            // 其余情况隐藏入口避免误导。与远程区「全部恢复」按钮对称。
            action: ref.watch(syncServiceProvider) is TransactionsSyncManager
                ? TextButton.icon(
                    icon: const Icon(Icons.cloud_upload, size: 18),
                    label: Text(AppLocalizations.of(context).ledgersUploadAll),
                    onPressed: _isUploadingAll
                        ? null
                        : () => _handleBatchUpload(context),
                  )
                : null,
          ),
          ...localLedgers.map((ledger) => LedgerCard(
                ledger: ledger,
                selected: !ledger.isRemoteOnly && ledger.id == currentId,
                onTap: () => _handleLocalLedgerTap(ledger),
                onLongPress: () => _showLocalLedgerActions(context, ledger),
                onMore: () => _showLocalLedgerActions(context, ledger),
              )),
        ],

        // 远程账本区域（仅在加载中或有远程账本时显示）
        if (remoteLoading ||
            remoteLedgers.isNotEmpty ||
            remoteError != null) ...[
          SizedBox(height: 16.0.scaled(context, ref)),
          _SectionHeader(
            title: AppLocalizations.of(context).ledgersRemote,
            trailing: remoteLoading ? null : remoteLedgers.length.toString(),
            action: remoteLedgers.isNotEmpty
                ? TextButton.icon(
                    icon: const Icon(Icons.cloud_download, size: 18),
                    label: Text(AppLocalizations.of(context).ledgersRestoreAll),
                    onPressed: _isRestoring
                        ? null
                        : () => _handleBatchRestore(context),
                  )
                : null,
          ),

          // 远程账本加载状态
          if (remoteLoading)
            Padding(
              padding:
                  EdgeInsets.symmetric(vertical: 24.0.scaled(context, ref)),
              child: DelayedSkeleton(
                placeholder: const SizedBox(height: 48),
                child: PulseSkeleton(
                  child: SkeletonBar(
                      height: 48,
                      borderRadius:
                          BorderRadius.circular(PiggyDimens.radiusLg)),
                ),
              ),
            )
          else if (remoteError != null)
            Padding(
              padding: EdgeInsets.all(16.0.scaled(context, ref)),
              child: Center(
                child: Text(
                  '${AppLocalizations.of(context).commonError}: $remoteError',
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            )
          else
            ...remoteLedgers.map((ledger) => LedgerCard(
                  ledger: ledger,
                  onTap: () => _handleRemoteLedgerTap(context, ledger),
                  onLongPress: () => _showRemoteLedgerActions(context, ledger),
                  onMore: () => _showRemoteLedgerActions(context, ledger),
                )),
        ],

        SizedBox(height: 60.0.scaled(context, ref)),
      ],
    );
  }

  /// 构建账本列表（旧版，保留用于兼容）
  Widget _buildLedgerList(
    BuildContext context,
    WidgetRef ref,
    List<LedgerDisplayItem> ledgers,
    int? currentId, {
    bool showLoadingOverlay = false,
  }) {
    // 分组：本地账本 vs 远程账本
    final localLedgers = ledgers.where((l) => !l.isRemoteOnly).toList();
    final remoteLedgers = ledgers.where((l) => l.isRemoteOnly).toList();

    return Stack(
      children: [
        ListView(
          padding: EdgeInsets.symmetric(
            vertical: 8.0.scaled(context, ref),
          ),
          children: [
            // 账本区域
            if (localLedgers.isNotEmpty) ...[
              _SectionHeader(
                title: AppLocalizations.of(context).ledgersLocal,
                trailing: localLedgers.length.toString(),
              ),
              ...localLedgers.map((ledger) => LedgerCard(
                    ledger: ledger,
                    selected: !ledger.isRemoteOnly && ledger.id == currentId,
                    onTap: () => _handleLocalLedgerTap(ledger),
                    onLongPress: () => _showLocalLedgerActions(context, ledger),
                    onMore: () => _showLocalLedgerActions(context, ledger),
                  )),
            ],

            // 远程账本区域
            if (remoteLedgers.isNotEmpty) ...[
              SizedBox(height: 16.0.scaled(context, ref)),
              _SectionHeader(
                title: AppLocalizations.of(context).ledgersRemote,
                trailing: remoteLedgers.length.toString(),
                action: TextButton.icon(
                  icon: const Icon(Icons.cloud_download, size: 18),
                  label: Text(AppLocalizations.of(context).ledgersRestoreAll),
                  onPressed:
                      _isRestoring ? null : () => _handleBatchRestore(context),
                ),
              ),
              ...remoteLedgers.map((ledger) => LedgerCard(
                    ledger: ledger,
                    onTap: () => _handleRemoteLedgerTap(context, ledger),
                    onLongPress: () =>
                        _showRemoteLedgerActions(context, ledger),
                    onMore: () => _showRemoteLedgerActions(context, ledger),
                  )),
            ],

            SizedBox(height: 60.0.scaled(context, ref)),
          ],
        ),

        // 加载蒙层：刷新时显示
        if (showLoadingOverlay)
          Positioned.fill(
            child: Container(
              color:
                  PiggyTokens.surfaceElevated(context).withValues(alpha: 0.7),
              child: const Center(
                child: CircularProgressIndicator(),
              ),
            ),
          ),
      ],
    );
  }

  /// 处理本地账本点击 - 切换账本或显示冲突对话框
  Future<void> _handleLocalLedgerTap(LedgerDisplayItem ledger) async {
    // 获取同步状态
    final syncStatusAsync = ref.read(syncStatusProvider(ledger.id));
    final syncStatus = syncStatusAsync.valueOrNull;

    // 检查是否有冲突
    if (syncStatus?.diff == SyncDiff.different) {
      // 显示冲突解决对话框
      await _showConflictResolutionDialog(context, ledger);
      return;
    }

    // 正常切换账本
    ref.read(currentLedgerIdProvider.notifier).state = ledger.id;
    // 清除缓存的交易数据，确保切换后刷新
    ref.invalidate(cachedTransactionsWithCategoryProvider);
    showToast(
        context,
        AppLocalizations.of(context)
            .ledgersSwitched(translateLedgerName(context, ledger.name)));
  }

  /// 处理远程账本点击 - 下载
  Future<void> _handleRemoteLedgerTap(
      BuildContext context, LedgerDisplayItem ledger) async {
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: AppLocalizations.of(context).ledgersDownloadTitle,
      message: AppLocalizations.of(context)
          .ledgersDownloadMessage(translateLedgerName(context, ledger.name)),
    );

    if (confirmed != true || !mounted || !context.mounted) return;

    // 强制阻塞弹窗：下载期间禁止切账本/触发上传等一切页面操作，
    // 防止下载恢复的写入与用户操作互相踩写
    final l10n = AppLocalizations.of(context);
    final block = showBlockingProgressDialog(
      context,
      title: l10n.ledgersDownloadTitle,
      initialStatus: l10n.ledgersDownloadOneBlockingStatus,
    );
    Object? error;
    try {
      final syncService = ref.read(syncServiceProvider);
      if (syncService is SyncEngine) {
        // PiggyCount Cloud 路径（sync_changes 增量日志模型）：
        // 1) syncLedgersFromServer 把账本行插到本地 Drift
        // 2) replayAllChanges 从 cursor=0 重拉整段 sync_changes 并幂等应用，
        //    把历史 tx/account/category/tag 挂到刚刚插好的新账本上
        //
        // 不走 `_fullPull`（整包 JSON 下载）—— 那是 S3/WebDAV 的玩法，PiggyCount
        // Cloud 的模型就是 sync_changes，所有恢复都应该走这条日志。apply 是
        // 按 entity_sync_id upsert 幂等的，重放不会产生副本。
        await syncService.syncLedgersFromServer();
        await syncService.replayAllChanges();
      } else if (syncService is TransactionsSyncManager) {
        // 老的 Supabase 路径。槽位路径按 syncId 解析（与上传同规则），
        // 不再手拼 ledger_<本地id>.json —— 数字 id 跨设备无意义。
        await syncService.downloadRemoteLedger(
          name: ledger.name,
          currency: ledger.currency,
          remotePath: await syncService.pathForLedger(ledger.id),
        );
      } else {
        throw Exception('Cloud sync not available');
      }
    } catch (e) {
      error = e;
    } finally {
      await block.close();
    }

    if (!mounted || !context.mounted) return;

    if (error != null) {
      await AppDialog.error(
        context,
        title: AppLocalizations.of(context).commonFailed,
        message: '$error',
      );
      return;
    }

    // 刷新列表和同步状态
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;

    showToast(
        context,
        AppLocalizations.of(context)
            .ledgersDownloadSuccess(translateLedgerName(context, ledger.name)));
  }

  /// 显示本地账本操作菜单
  Future<void> _showLocalLedgerActions(
      BuildContext context, LedgerDisplayItem ledger) async {
    // v24 共享账本权限矩阵(详见 .docs/shared-ledger/01-product-design.md §6):
    // - Owner / 单人账本:edit / clear / deleteLocal / delete + members 全部可用
    // - Editor(共享账本 + myRole != owner):仅 members(看成员/退出),
    //   隐藏 edit / clear / deleteLocal / delete 4 项 owner-only 操作
    final isOwner = ledger.myRole == 'owner';
    // 共享账本/成员管理是 PiggyCount Cloud 独有能力,非 PiggyCount Cloud 模式
    // (local / WebDAV / S3 / Supabase 等)直接隐藏这些入口。
    final cloudConfig = ref.read(activeCloudConfigProvider).valueOrNull;
    final isPiggyCountCloud =
        cloudConfig?.type == CloudBackendType.piggycountCloud;
    // 手动上传仅对快照同步类后端开放（PiggyCount Cloud 增量自动同步无需手动上传）
    final canUpload = ref.read(syncServiceProvider) is TransactionsSyncManager;
    final action = await showDialog<String>(
      context: context,
      builder: (dctx) {
        final primary = PiggyTokens.primary(dctx);
        return SimpleDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
          title: Text(AppLocalizations.of(context).ledgersActions),
          children: [
            if (isOwner)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dctx, 'edit'),
                child: Row(
                  children: [
                    Icon(Icons.edit, color: primary),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context).ledgersEdit),
                  ],
                ),
              ),
            // 预算管理入口 — 每个账本独立预算,Owner/Editor 都能看(Editor 进
            // BudgetPage 后 isEditorInShared 隐藏 + 按钮和编辑入口,只看不改)。
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dctx, 'budget'),
              child: Row(
                children: [
                  Icon(Icons.pie_chart_outline_rounded, color: primary),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.of(context).budgetManagement),
                ],
              ),
            ),
            // v24 共享账本:成员管理入口(任意 member 可看,owner 可邀请 / 踢人,
            // Editor 可看列表 + 退出账本)。非 PiggyCount Cloud 模式没成员概念,
            // 整个入口隐藏。
            if (isPiggyCountCloud) ...[
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dctx, 'members'),
                child: Row(
                  children: [
                    Icon(Icons.people, color: primary),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context).sharedMembersPageTitle),
                    if (ledger.isShared) ...[
                      const SizedBox(width: 6),
                      Text(
                        '(${ledger.memberCount})',
                        style: PiggyTextTokens.label(context).copyWith(
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              // 共享账本成员收支统计(简版)— 只对已同步的共享账本展示。
              if (ledger.isShared)
                SimpleDialogOption(
                  onPressed: () => Navigator.pop(dctx, 'memberStats'),
                  child: Row(
                    children: [
                      Icon(Icons.insert_chart_outlined, color: primary),
                      const SizedBox(width: 8),
                      Text(
                          AppLocalizations.of(context).sharedMembersStatsTitle),
                    ],
                  ),
                ),
            ],
            // 单账本上传 — 放在破坏性操作（清空/删除）之前，与编辑类操作分组。
            if (canUpload)
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dctx, 'upload'),
                child: Row(
                  children: [
                    Icon(Icons.cloud_upload_outlined, color: primary),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context).ledgersUploadThis),
                  ],
                ),
              ),
            if (isOwner) ...[
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dctx, 'clear'),
                child: Row(
                  children: [
                    const Icon(Icons.clear_all, color: Colors.orange),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context).ledgersClear),
                  ],
                ),
              ),
            ],
            // "仅删除本地"对 Owner 和 Editor 都可用 — 这是本地清理动作,
            // 不影响 server。Editor 用这个清掉 Owner 已删账本残留;Owner
            // 用来清不想要的本地副本但保留 server 数据。
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dctx, 'deleteLocal'),
              child: Row(
                children: [
                  const Icon(Icons.delete_outline, color: Colors.deepOrange),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.of(context).ledgersDeleteLocal),
                ],
              ),
            ),
            if (isOwner) ...[
              SimpleDialogOption(
                onPressed: () => Navigator.pop(dctx, 'delete'),
                child: Row(
                  children: [
                    Icon(Icons.delete_forever_outlined,
                        color: PiggyTokens.error(context)),
                    const SizedBox(width: 8),
                    Text(AppLocalizations.of(context).ledgersDelete),
                  ],
                ),
              ),
            ],
          ],
        );
      },
    );

    if (!mounted) return;

    if (action == 'edit') {
      await _handleEditLedger(context, ledger);
    } else if (action == 'budget') {
      // 切到长按的账本(BudgetPage 内部 watch currentLedger,不接 ledgerId 参
      // 数),再 push。语义上"从账本列表 → 长按 A → 预算管理"自然就是切到 A。
      if (ref.read(currentLedgerIdProvider) != ledger.id) {
        ref.read(currentLedgerIdProvider.notifier).state = ledger.id;
        ref.invalidate(currentLedgerProvider);
      }
      if (mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BudgetPage()),
        );
      }
    } else if (action == 'members') {
      // 跳转成员管理 — 需要 ledger.syncId(server external_id)。本地仅 ledger
      // (没 syncId,从未同步过的)无成员概念,提示用户先建云账户。
      final row = await ref.read(repositoryProvider).getLedgerById(ledger.id);
      final syncId = row?.syncId;
      if (syncId == null || syncId.isEmpty) {
        if (mounted)
          showToast(
              context, AppLocalizations.of(context).sharedRequiresCloudSync);
        return;
      }
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MemberListPage(
            ledgerExternalId: syncId,
            ledgerName: ledger.name,
          ),
        ));
      }
    } else if (action == 'memberStats') {
      // 跟成员管理同源:取 ledger.syncId 再跳 MemberStatsPage。
      final row = await ref.read(repositoryProvider).getLedgerById(ledger.id);
      final syncId = row?.syncId;
      if (syncId == null || syncId.isEmpty) {
        if (mounted)
          showToast(
              context, AppLocalizations.of(context).sharedRequiresCloudSync);
        return;
      }
      if (mounted) {
        await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => MemberStatsPage(
            ledgerExternalId: syncId,
            ledgerName: ledger.name,
          ),
        ));
      }
    } else if (action == 'upload') {
      await _handleUploadLedger(context, ledger);
    } else if (action == 'clear') {
      await _handleClearLedger(context, ledger);
    } else if (action == 'deleteLocal') {
      await _handleDeleteLocalLedgerOnly(context, ledger);
    } else if (action == 'delete') {
      await _handleDeleteLocalLedger(context, ledger);
    }
  }

  /// 显示远程账本操作菜单
  Future<void> _showRemoteLedgerActions(
      BuildContext context, LedgerDisplayItem ledger) async {
    final action = await showDialog<String>(
      context: context,
      builder: (dctx) {
        final primary = PiggyTokens.primary(dctx);
        return SimpleDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
          title: Text(AppLocalizations.of(context).ledgersActions),
          children: [
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dctx, 'download'),
              child: Row(
                children: [
                  Icon(Icons.cloud_download, color: primary),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.of(context).ledgersDownload),
                ],
              ),
            ),
            SimpleDialogOption(
              onPressed: () => Navigator.pop(dctx, 'delete'),
              child: Row(
                children: [
                  Icon(Icons.delete_forever_outlined,
                      color: PiggyTokens.error(context)),
                  const SizedBox(width: 8),
                  Text(AppLocalizations.of(context).ledgersDeleteRemote),
                ],
              ),
            ),
          ],
        );
      },
    );

    if (!mounted) return;

    if (action == 'download') {
      await _handleRemoteLedgerTap(context, ledger);
    } else if (action == 'delete') {
      await _handleDeleteRemoteLedger(context, ledger);
    }
  }

  /// 编辑账本
  Future<void> _handleEditLedger(
      BuildContext context, LedgerDisplayItem ledger) async {
    final repo = ref.read(repositoryProvider);
    final ledgerData = await repo.getLedgerById(ledger.id);

    if (ledgerData == null || !mounted) return;

    final result = await _showLedgerEditorDialog(
      context,
      title: AppLocalizations.of(context).ledgersEdit,
      initialName: ledgerData.name,
      initialCurrency: ledgerData.currency,
      initialMonthStartDay: ledgerData.monthStartDay,
    );

    if (result == null || !mounted) return;

    // v30 本位币变更:存量交易的 nativeAmount 快照是按旧本位币算的,需按新
    // 本位币全量重算(边界 5,.docs/multi-currency-ledger 02 §八)。先确认再改。
    final currencyChanged =
        result.currency.toUpperCase() != ledgerData.currency.toUpperCase();
    if (currencyChanged) {
      final stats = await repo.getLedgerStats(ledgerId: ledger.id);
      final txCount = stats.transactionCount;
      // 用 State 的 mounted/this.context:传入的参数 context 可能随编辑入口
      // 弹层一起销毁(mounted=false → 静默 return 会把整个保存吞掉)。
      if (!mounted) return;
      final l10n = AppLocalizations.of(this.context);
      final confirmed = await showDialog<bool>(
        context: this.context,
        builder: (dctx) => AlertDialog(
          title: Text(l10n.ledgerBaseCurrencyLabel),
          content: Text(
            '${l10n.ledgerCurrencyChangeRecalcHint}\n'
            '${l10n.recalcSyncCountHint(txCount)}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dctx, false),
              child: Text(AppLocalizations.of(dctx).commonCancel),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dctx, true),
              child: Text(AppLocalizations.of(dctx).commonConfirm),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    await repo.updateLedger(
      id: ledger.id,
      name: result.name.trim(),
      currency: result.currency,
      monthStartDay: result.monthStartDay,
    );

    if (currencyChanged) {
      // 先强制拉一次「以新主币种为 base」的汇率:改币种瞬间本地通常还没有
      // 这一组(汇率按本位币基准存),不拉的话重算会因缺汇率整体跳过
      // (反馈17:CNY→JPY 后旧交易折算不动)。extraQuotes 带上账本实际涉及
      // 的全部外币(无账户币种不在 usedCurrencies 里)。拉取失败也继续——
      // 缺汇率的笔退化 =amount,由 L11 横幅兜底,绝不保留旧口径错值。
      final foreign = await repo.getLedgerForeignCurrencies(ledger.id);
      await refreshExchangeRatesFromUi(ref,
          force: true,
          extraQuotes: {...foreign, ledgerData.currency.toUpperCase()});
      // 全量重算(逐笔记 change,L13);缺汇率的笔留待 L11 横幅
      final n =
          await repo.recalcNativeAmountsForLedger(ledger.id, result.currency);
      if (mounted && n > 0) {
        showToast(this.context,
            AppLocalizations.of(this.context).recalcForeignTxDone(n));
      }
    }

    // 刷新信号必须在 sync 之前发(反馈19):改主币种重算产生几百条 change,
    // push 可能耗时数十秒甚至失败,原先信号排在 await sync 之后导致首页/
    // 账本页统计长时间(或永远)显示旧数据。本地数据此刻已就绪,立即刷新。
    ref.read(ledgerListRefreshProvider.notifier).state++;
    // currentLedgerProvider 已是 StreamProvider(Drift watch 自动推送),
    // 此 invalidate 仅作防御性重订阅(如流曾进入 error 态),正常路径冗余无害。
    ref.invalidate(currentLedgerProvider);
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(budgetRefreshProvider.notifier).state++;

    // 修改账本元数据后,触发同步以更新云端(本地非 tx 写入不会自动 push)。
    // 放刷新信号之后:UI 不等 push 完成;失败也不影响本地展示(下次同步兜底)。
    try {
      await PostProcessor.sync(ref, ledgerId: ledger.id);
    } catch (e) {
      logger.warning('LedgersPage', '改账本元数据后同步失败(本地已生效,下次同步重试): $e');
    }

    // 起始日影响小部件「本月」口径,立即刷新
    try {
      final repository = ref.read(repositoryProvider);
      final colorScheme = ref.read(incomeExpenseColorSchemeProvider);
      // 没有 BuildContext,靠 languageProvider 还原当前 App 语言(见
      // widget_manager.dart resolveWidgetLocalizations 文档)。
      await WidgetManager().updateAllWidgetsLocalized(
        repository,
        ledger.id,
        ref.read(primaryColorProvider),
        explicitLocale: ref.read(languageProvider),
        colorScheme: colorScheme,
        baseCurrency: ref.read(baseCurrencyProvider),
      );
    } catch (_) {}
  }

  /// 清空 / 删除账本后,精准清理该账本关联的附件物理文件(best-effort)。
  /// 清空(clearLedgerTransactions)和删账本(deleteLedger)走批量 SQL 删行,
  /// 只删 DB 行不删物理文件;调用方在删除前先收集该账本的 fileName 传入。
  /// 按引用计数删除:其他账本/交易仍引用同一 fileName 的不会被误删。
  Future<void> _cleanupLedgerAttachmentFiles(List<String> fileNames) async {
    if (fileNames.isEmpty) return;
    try {
      await ref
          .read(attachmentServiceProvider)
          .deletePhysicalFilesIfUnreferenced(fileNames);
    } catch (e) {
      logger.warning('ledger', '清理账本附件文件失败（忽略）：$e');
    }
  }

  /// 清空账本（删除所有账单，保留账本）
  Future<void> _handleClearLedger(
      BuildContext context, LedgerDisplayItem ledger) async {
    final l10n = AppLocalizations.of(context);
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.ledgersClearTitle,
      message:
          l10n.ledgersClearMessage(translateLedgerName(context, ledger.name)),
    );

    if (confirmed != true || !mounted) return;

    try {
      final repo = ref.read(repositoryProvider);

      // 删账单前先收集该账本附件 fileName(删行后就查不到了)
      final attachmentFiles =
          await repo.getAttachmentFileNamesByLedger(ledger.id);
      // 删除该账本的所有账单(批量删行不删物理文件)
      await repo.clearLedgerTransactions(ledger.id);
      // 删行后精准清理这些附件的物理文件(引用计数)
      await _cleanupLedgerAttachmentFiles(attachmentFiles);

      if (!mounted) return;

      // 清空缓存的交易数据（避免首页使用旧缓存）
      ref.read(cachedTransactionsProvider.notifier).state = null;

      // 触发同步状态刷新
      await PostProcessor.sync(ref, ledgerId: ledger.id);

      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, l10n.ledgersClearSuccess);
    } catch (e) {
      if (!mounted) return;
      await AppDialog.error(
        context,
        title: l10n.commonFailed,
        message: '$e',
      );
    }
  }

  /// 仅删除本地账本（保留云端备份）
  Future<void> _handleDeleteLocalLedgerOnly(
      BuildContext context, LedgerDisplayItem ledger) async {
    final l10n = AppLocalizations.of(context);

    final repo = ref.read(repositoryProvider);
    final allLedgers = await repo.getAllLedgers();

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.ledgersDeleteLocalTitle,
      message: l10n
          .ledgersDeleteLocalMessage(translateLedgerName(context, ledger.name)),
    );

    if (confirmed != true || !mounted) return;

    try {
      final current = ref.read(currentLedgerIdProvider);

      // 如果删除的是当前账本,有其他账本就切一下;没有就让 currentLedger 落空
      // (currentLedgerProvider 查不到 ledger 返 null,首页胶囊回到「+ 新建账本」
      // 引导用户重新创建,符合"允许删完所有账本"的语义)。
      if (current == ledger.id) {
        final remainAfterDelete =
            allLedgers.where((l) => l.id != ledger.id).toList();
        if (remainAfterDelete.isNotEmpty) {
          ref.read(currentLedgerIdProvider.notifier).state =
              remainAfterDelete.first.id;
        }
      }

      // 删账本前先收集其附件 fileName(删行后查不到)
      final attachmentFiles =
          await repo.getAttachmentFileNamesByLedger(ledger.id);
      // 只删除本地账本，不删除云端备份
      await repo.deleteLedger(ledger.id);
      await _cleanupLedgerAttachmentFiles(attachmentFiles);

      if (!mounted) return;

      // currentLedgerProvider 已是 StreamProvider(Drift watch 自动推送),
      // 此 invalidate 仅作防御性重订阅(如流曾进入 error 态),正常路径冗余无害。
      ref.invalidate(currentLedgerProvider);
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, l10n.ledgersDeleteLocalSuccess);
    } catch (e) {
      if (!mounted) return;
      await AppDialog.error(
        context,
        title: l10n.commonFailed,
        message: '$e',
      );
    }
  }

  /// 删除本地账本
  Future<void> _handleDeleteLocalLedger(
      BuildContext context, LedgerDisplayItem ledger) async {
    final l10n = AppLocalizations.of(context);

    final repo = ref.read(repositoryProvider);
    final allLedgers = await repo.getAllLedgers();

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: l10n.ledgersDeleteConfirm,
      message: l10n.ledgersDeleteMessage,
    );

    if (confirmed != true || !mounted) return;

    try {
      final sync = ref.read(syncServiceProvider);
      final current = ref.read(currentLedgerIdProvider);
      final deletedLedgerId = ledger.id;

      // 如果删除的是当前账本,有其他账本就切一下;没有就让 currentLedger 落空
      // (首页胶囊会回到「+ 新建账本」引导,允许删完所有账本)
      if (current == deletedLedgerId) {
        final remainAfterDelete =
            allLedgers.where((l) => l.id != deletedLedgerId).toList();
        if (remainAfterDelete.isNotEmpty) {
          ref.read(currentLedgerIdProvider.notifier).state =
              remainAfterDelete.first.id;
        }
      }

      // 先调 deleteRemoteBackup:此刻 ledger 行还在,deleteRemoteBackup 内部能
      // 查到 syncId 构造正确的 storage path。如果放到 deleteLedger 之后,
      // ledger 行已被删,fallback 到 ledger.id.toString() 对 UUID 账本会
      // miss(404),storage 快照清不掉。
      try {
        await sync.deleteRemoteBackup(ledgerId: deletedLedgerId);
      } catch (e) {
        logger.warning('ledger', '删除云端备份失败（忽略）：$e');
      }

      // 删除本地账本(repo.deleteLedger 内部会捕获 syncId,登记
      // ledger_snapshot:delete + 级联 transaction:delete + budget:delete change)
      // 删账本前先收集其附件 fileName(删行后查不到)
      final attachmentFiles =
          await repo.getAttachmentFileNamesByLedger(deletedLedgerId);
      await repo.deleteLedger(deletedLedgerId);
      await _cleanupLedgerAttachmentFiles(attachmentFiles);

      // 显式触发对被删账本的 sync,把 delete change 推到 server 清掉 canonical
      // state。SyncCoordinator 的 ledgerIdResolver 拿的是新切换的 currentLedger,
      // 不会触发被删账本的 sync,不调这里 → delete change 永远 stranded → server
      // 还保留账本和它的全部记录,remote ledgers 列表里还会显示。
      // sync_engine.sync() 内部已对 ledgerRow==null 短路:跳过 hasRemote/fullPush/
      // pull,只走 _push 把 delete change 推上去。
      // ignore: unawaited_futures
      PostProcessor.sync(ref, ledgerId: deletedLedgerId);

      if (!mounted) return;

      // 同 _handleDeleteLocalLedgerOnly:显式 invalidate currentLedgerProvider,
      // 哪怕 ledgerId 没切(没其他账本可切),也得让首页胶囊重读 → 查不到行 →
      // 显示 "+ 新建账本"。
      ref.invalidate(currentLedgerProvider);
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, AppLocalizations.of(context).ledgersDeleted);
    } catch (e) {
      if (!mounted) return;
      await AppDialog.error(
        context,
        title: AppLocalizations.of(context).ledgersDeleteFailed,
        message: '$e',
      );
    }
  }

  /// 删除远程账本
  Future<void> _handleDeleteRemoteLedger(
      BuildContext context, LedgerDisplayItem ledger) async {
    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: AppLocalizations.of(context).ledgersDeleteRemoteConfirm,
      message: AppLocalizations.of(context).ledgersDeleteRemoteMessage(
          translateLedgerName(context, ledger.name)),
    );

    if (confirmed != true || !mounted) return;

    try {
      showToast(context, AppLocalizations.of(context).ledgersDeleting);

      final syncService = ref.read(syncServiceProvider);
      if (syncService is! TransactionsSyncManager) {
        throw Exception('Cloud sync not available');
      }

      // 槽位路径按 syncId 解析（与上传同规则），不手拼数字 id
      await syncService.deleteRemoteLedger(
          remotePath: await syncService.pathForLedger(ledger.id));

      if (!mounted) return;

      ref.read(ledgerListRefreshProvider.notifier).state++;

      showToast(
          context, AppLocalizations.of(context).ledgersDeleteRemoteSuccess);
    } catch (e) {
      if (!mounted) return;
      await AppDialog.error(
        context,
        title: AppLocalizations.of(context).commonFailed,
        message: '$e',
      );
    }
  }

  /// 批量恢复所有远程账本
  Future<void> _handleBatchRestore(BuildContext context) async {
    // 获取远程账本数量
    final remoteLedgersAsync = ref.read(remoteLedgersProvider);
    final remoteLedgers = remoteLedgersAsync.value ?? [];

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: AppLocalizations.of(context).ledgersRestoreAllTitle,
      message: AppLocalizations.of(context)
          .ledgersRestoreAllMessage(remoteLedgers.length),
    );

    if (confirmed != true || !mounted || !context.mounted) return;

    setState(() => _isRestoring = true);

    // 强制阻塞弹窗：批量恢复期间禁止切账本/触发上传等一切页面操作，
    // 防止恢复写入与用户操作互相踩写
    final l10n = AppLocalizations.of(context);
    final block = showBlockingProgressDialog(
      context,
      title: l10n.ledgersRestoreAllTitle,
      initialStatus: l10n.ledgersRestoreBlockingStatus,
    );
    int success = 0;
    int failed = 0;
    Object? error;
    try {
      final syncService = ref.read(syncServiceProvider);
      if (syncService is SyncEngine) {
        // PiggyCount Cloud 批量（sync_changes 日志模型）：
        // 1) syncLedgersFromServer 把所有 remote-only ledger 插到本地
        // 2) replayAllChanges 一次性从 cursor=0 重拉历史 sync_changes，apply
        //    按 entity_sync_id 幂等 upsert，把所有账本的历史统一刷回来
        // 不走 `_fullPull` 的 JSON snapshot 下载 —— 那是 S3/WebDAV 的模型。
        await syncService.syncLedgersFromServer();
        try {
          await syncService.replayAllChanges();
          success = remoteLedgers.length;
        } catch (e, st) {
          logger.warning('LedgersPage', '批量恢复远程账本失败: $e', st);
          failed = remoteLedgers.length;
        }
      } else if (syncService is TransactionsSyncManager) {
        final result = await syncService.restoreAllRemoteLedgers();
        success = result.success;
        failed = result.failed;
      } else {
        throw Exception('Cloud sync not available');
      }
    } catch (e) {
      error = e;
    } finally {
      // 先关阻塞弹窗，再展示结果/错误弹窗，避免误 pop 顶层弹窗
      await block.close();
    }

    if (!mounted || !context.mounted) return;
    setState(() => _isRestoring = false);

    if (error != null) {
      await AppDialog.error(
        context,
        title: AppLocalizations.of(context).commonFailed,
        message: '$error',
      );
      return;
    }

    // 刷新列表和同步状态
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;

    // 显示结果
    await AppDialog.info(
      context,
      title: AppLocalizations.of(context).ledgersRestoreComplete,
      message: AppLocalizations.of(context).ledgersRestoreResult(
        success,
        failed,
      ),
    );
  }

  /// 批量上传所有本地账本到云端（快照同步类后端专属）。
  ///
  /// 语义：以本地为准覆盖云端（用户已在确认弹窗中知晓覆盖警示）。
  /// 流程：确认 → **阻塞式进度弹窗**（期间禁止一切页面操作）→
  /// uploadAllLedgers（串行、单个失败不中断）→ 关闭弹窗 → 刷新 providers
  /// → 结果弹窗。
  Future<void> _handleBatchUpload(BuildContext context) async {
    final localLedgers = ref.read(localLedgersProvider).value ?? [];

    final confirmed = await AppDialog.confirm<bool>(
      context,
      title: AppLocalizations.of(context).ledgersUploadAll,
      message: AppLocalizations.of(context)
          .ledgersUploadAllMessage(localLedgers.length),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isUploadingAll = true);

    final l10n = AppLocalizations.of(context);
    // 进度用 ValueNotifier 驱动：上传循环在弹窗外异步推进，
    // ValueListenableBuilder 订阅刷新，避免捕获 StatefulBuilder 的 setState
    final progress = ValueNotifier<int>(0);
    final total = localLedgers.length;
    // 弹窗是否已弹出：异常路径下只有弹窗在台前才需要 pop，
    // 否则会误关别的路由
    var dialogOpen = false;

    try {
      final syncService = ref.read(syncServiceProvider);
      if (syncService is! TransactionsSyncManager) {
        // 按钮仅在 TransactionsSyncManager 下可见，这里防御配置中途变化
        throw Exception('Cloud sync not available');
      }

      // 强制阻塞弹窗：barrierDismissible=false 禁止点外部关闭，
      // PopScope(canPop:false) 拦截系统返回键 —— 批量上传期间用户不能做
      // 任何其他操作，防止中途切账本/触发并发同步与上传互相踩写
      final dialogFuture = showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dctx) => PopScope(
          canPop: false,
          child: AlertDialog(
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
            title: Text(l10n.ledgersUploadAll),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const CircularProgressIndicator(),
                const SizedBox(height: 16),
                ValueListenableBuilder<int>(
                  valueListenable: progress,
                  builder: (_, done, __) => Text(
                    l10n.ledgersUploadingProgress(done, total),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
      dialogOpen = true;

      final result = await syncService.uploadAllLedgers(
        onProgress: (done, _) => progress.value = done,
      );

      // 上传结束（成败皆关）：关闭进度弹窗，dialogFuture 由 pop 落定
      if (mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      await dialogFuture;

      if (!mounted) return;

      setState(() => _isUploadingAll = false);

      // 刷新列表和同步状态
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;
      ref.read(syncStatusRefreshProvider.notifier).state++;

      await AppDialog.info(
        context,
        title: AppLocalizations.of(context).ledgersUploadAllComplete,
        // 审计 A4：uploadAllLedgers 不再强制覆盖，被 M7 闸门拦下的账本
        // 单独计数并复用与页面级批量一致的「跳过冲突」文案
        message: result.conflicts > 0
            ? AppLocalizations.of(context).ledgersUploadAllConflictSkipped(
                result.success, result.conflicts)
            : AppLocalizations.of(context)
                .ledgersUploadAllResult(result.success, result.failed),
      );
    } catch (e) {
      // 异常路径也必须关掉进度弹窗，否则它会永久挡住页面
      if (mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      if (!mounted) return;
      setState(() => _isUploadingAll = false);

      await AppDialog.error(
        context,
        title: AppLocalizations.of(context).commonFailed,
        message: '$e',
      );
    } finally {
      progress.dispose();
    }
  }

  /// 上传单个本地账本到云端（长按菜单入口，快照同步类后端专属）。
  ///
  /// 通过 uploadingLedgerIdsProvider 标记上传中状态，供其他 UI
  /// （如冲突对话框）感知并避免并发上传同一账本。
  Future<void> _handleUploadLedger(
      BuildContext context, LedgerDisplayItem ledger) async {
    final uploadingIds = ref.read(uploadingLedgerIdsProvider);
    ref.read(uploadingLedgerIdsProvider.notifier).state = {
      ...uploadingIds,
      ledger.id,
    };

    // 强制阻塞弹窗：上传期间禁止切账本/编辑等一切页面操作，
    // 防止与上传快照互相踩写
    final l10n = AppLocalizations.of(context);
    Object? error;
    var uploaded = false;

    /// 单次上传尝试（自带阻塞弹窗）。CloudConflictException 会先经
    /// finally 关闭进度弹窗再上抛，让守卫在无遮拦状态下弹确认框。
    Future<bool> attempt({required bool force}) async {
      Object? err;
      var ok = false;
      final block = showBlockingProgressDialog(
        context,
        title: l10n.syncBlockingUploadTitle,
        initialStatus: l10n.ledgersUploadOneBlockingStatus,
      );
      try {
        await ref
            .read(syncServiceProvider)
            .uploadCurrentLedger(ledgerId: ledger.id, force: force);
        ok = true;
      } on CloudConflictException {
        rethrow;
      } catch (e) {
        err = e;
      } finally {
        await block.close();
      }
      if (err != null) throw err;
      return ok;
    }

    try {
      uploaded = await uploadLedgerWithConflictGuard(
        context,
        run: ({required bool force}) => attempt(force: force),
        // 冲突三选一中的「对比合并」：进入逐条 diff 预览合并，
        // 不覆盖任何一侧（方向仲裁时间戳失真时的无损出路）
        compareMerge: () async {
          await _handleCompareMergeFlow(context, ledger);
        },
      );
    } catch (e) {
      error = e;
    }

    if (mounted && context.mounted) {
      if (error != null) {
        await AppDialog.error(
          context,
          title: AppLocalizations.of(context).commonFailed,
          message: '$error',
        );
      } else if (uploaded) {
        showToast(context, AppLocalizations.of(context).mineUploadSuccess);
        ref.read(ledgerListRefreshProvider.notifier).state++;
        ref.read(syncStatusRefreshProvider.notifier).state++;
      }
    }
    // widget 已销毁时不再触碰 ref，避免 StateError
    if (mounted) {
      final ids = ref.read(uploadingLedgerIdsProvider);
      ref.read(uploadingLedgerIdsProvider.notifier).state =
          ids.where((id) => id != ledger.id).toSet();
    }
  }

  /// 显示创建账本对话框
  Future<void> _showCreateLedgerDialog(BuildContext context) async {
    final result = await _showLedgerEditorDialog(
      context,
      title: AppLocalizations.of(context).ledgersNew,
    );

    if (result == null || !mounted) return;

    try {
      final repo = ref.read(repositoryProvider);
      final newLedgerId = await repo.createLedger(
        name: result.name.trim(),
        currency: result.currency,
      );

      // 创建弹窗里也能选起始日:createLedger 不收该参数,创建后补写
      if (result.monthStartDay != 1) {
        await repo.updateLedger(
            id: newLedgerId, monthStartDay: result.monthStartDay);
      }

      // 空账本场景(welcome 未勾默认账本 / 老用户导入配置不含账本)进入此页
      // 创建第一个账本时,currentLedgerIdProvider 还指向默认值 1(无效),
      // 必须切到新账本 id 否则首页 header 胶囊继续显示「新建账本」、列表为
      // 空。已有账本时不动 currentLedger,保留用户当前所在账本。
      if (!mounted) return;
      final currentLedger = await ref.read(currentLedgerProvider.future);
      if (currentLedger == null) {
        ref.read(currentLedgerIdProvider.notifier).state = newLedgerId;
        ref.invalidate(currentLedgerProvider);
      }

      ref.read(ledgerListRefreshProvider.notifier).state++;

      // 显式触发新账本的同步。createLedger 不会切换 currentLedger,所以
      // SyncCoordinator 的 ledgerIdResolver 拿的还是旧账本,新账本的同步永
      // 远不会被自动触发。这里直接对 newLedgerId 调一次 sync,让 server 立
      // 即创建对应账本(走 sync 内的 !hasRemote → fullPush 路径)。
      // 不调的话,要等到用户切到新账本并加第一笔交易才会被动同步,违反"创
      // 建后立即可见"预期。
      // ignore: unawaited_futures
      PostProcessor.sync(ref, ledgerId: newLedgerId);

      if (!mounted) return;
      showToast(context, AppLocalizations.of(context).ledgersCreatedSuccess);
    } catch (e) {
      if (!mounted) return;
      showToast(context,
          AppLocalizations.of(context).ledgersCreateFailed(e.toString()));
    }
  }

  /// 账本编辑对话框
  Future<({String name, String currency, int monthStartDay})?>
      _showLedgerEditorDialog(
    BuildContext context, {
    String? title,
    String? initialName,
    String? initialCurrency,
    int? initialMonthStartDay,
  }) async {
    String name = initialName ?? '';
    String currency = initialCurrency ?? 'CNY';
    int monthStartDay = initialMonthStartDay ?? 1;
    final nameCtrl = TextEditingController(text: name);

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final primary = PiggyTokens.primary(ctx);
        return AlertDialog(
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
          contentPadding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
          content: StatefulBuilder(builder: (ctx, setState) {
            return Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title ?? AppLocalizations.of(ctx).ledgersEdit,
                  textAlign: TextAlign.center,
                  style: Theme.of(ctx).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtrl,
                  decoration: InputDecoration(
                    labelText: AppLocalizations.of(ctx).ledgersName,
                  ),
                ),
                const SizedBox(height: 12),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  // v30 语义升级:账本 currency = 「账本本位币」(统计折算目标),
                  // 与资产页的用户级「主币种」是两个概念,label 用本位币避免混淆。
                  title: Text(AppLocalizations.of(ctx).ledgerBaseCurrencyLabel),
                  subtitle: Text(displayCurrency(currency, context)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final picked =
                        await _showCurrencyPicker(ctx, initial: currency);
                    if (picked != null) {
                      setState(() => currency = picked);
                    }
                  },
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: Text(AppLocalizations.of(ctx).ledgersMonthStartDay),
                  subtitle: Text(monthStartDay <= 1
                      ? AppLocalizations.of(ctx).ledgersMonthStartDayNatural
                      : AppLocalizations.of(ctx)
                          .ledgersMonthStartDayValue(monthStartDay)),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () async {
                    final picked = await _showMonthStartDayPicker(ctx,
                        initial: monthStartDay);
                    if (picked != null) {
                      setState(() => monthStartDay = picked);
                    }
                  },
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    OutlinedButton(
                      onPressed: () => Navigator.pop(ctx, false),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: primary,
                        side: BorderSide(color: primary),
                      ),
                      child: Text(AppLocalizations.of(ctx).commonCancel),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => Navigator.pop(ctx, true),
                      child: Text(
                        title == AppLocalizations.of(ctx).ledgersNew
                            ? AppLocalizations.of(ctx).ledgersCreate
                            : AppLocalizations.of(ctx).commonSave,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
            );
          }),
        );
      },
    );

    if (ok == true && nameCtrl.text.trim().isNotEmpty) {
      return (
        name: nameCtrl.text.trim(),
        currency: currency,
        monthStartDay: monthStartDay
      );
    }

    return null;
  }

  /// 28宫格月起始日选择器
  Future<int?> _showMonthStartDayPicker(BuildContext context,
      {required int initial}) {
    return showModalBottomSheet<int>(
      context: context,
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(PiggyDimens.radiusXl)),
      ),
      builder: (ctx) {
        final primary = PiggyTokens.primary(ctx);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(AppLocalizations.of(ctx).ledgersMonthStartDay,
                    style: Theme.of(ctx).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(AppLocalizations.of(ctx).ledgersMonthStartDayHint,
                    style: Theme.of(ctx)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: PiggyTokens.textTertiary(ctx))),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: List.generate(28, (index) {
                    final day = index + 1;
                    final isSelected = initial == day;
                    return InkWell(
                      onTap: () => Navigator.pop(ctx, day),
                      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
                      child: Container(
                        width: 40,
                        height: 40,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusSm),
                          color: isSelected
                              ? primary.withValues(alpha: 0.12)
                              : Colors.transparent,
                          border: Border.all(
                              color: isSelected
                                  ? primary
                                  : PiggyTokens.divider(ctx)),
                        ),
                        child: Text('$day',
                            style: TextStyle(
                                color: isSelected
                                    ? primary
                                    : PiggyTokens.textPrimary(ctx))),
                      ),
                    );
                  }),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// 货币选择器
  Future<String?> _showCurrencyPicker(BuildContext context,
      {String? initial}) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: PiggyTokens.surfaceElevated(context),
      shape: const RoundedRectangleBorder(
        borderRadius:
            BorderRadius.vertical(top: Radius.circular(PiggyDimens.radiusXl)),
      ),
      builder: (bctx) {
        String query = '';
        String? selected = initial;
        return StatefulBuilder(builder: (sctx, setState) {
          final filtered = getCurrencies(context).where((c) {
            final q = query.trim();
            if (q.isEmpty) return true;
            final uq = q.toUpperCase();
            return c.code.contains(uq) || c.name.contains(q);
          }).toList();

          return Padding(
            // viewInsets 读取隔离到 KeyboardBottomInsetPadding 叶子组件：
            // 键盘动画期间仅该组件逐帧重建，不再重建整个 sheet 内容
            padding: const EdgeInsets.only(left: 16, right: 16, top: 12),
            child: KeyboardBottomInsetPadding(
              extra: 16,
              child: SizedBox(
                height: 420,
                child: Column(
                children: [
                  Container(
                    width: 36,
                    height: 4,
                    margin: const EdgeInsets.only(bottom: 8),
                    decoration: BoxDecoration(
                      color: PiggyTokens.textTertiary(context)
                          .withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  Text(
                    AppLocalizations.of(bctx).ledgersSelectCurrency,
                    style: Theme.of(bctx).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(
                      prefixIcon: const Icon(Icons.search),
                      hintText: AppLocalizations.of(bctx).ledgersSearchCurrency,
                    ),
                    onChanged: (v) => setState(() => query = v),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: ListView.builder(
                      itemCount: filtered.length,
                      itemBuilder: (_, i) {
                        final c = filtered[i];
                        final sel = c.code == selected;
                        return ListTile(
                          title: Text('${c.name} (${c.code})'),
                          trailing: sel
                              ? Icon(Icons.check,
                                  color: PiggyTokens.textPrimary(context))
                              : null,
                          onTap: () => Navigator.pop(bctx, c.code),
                        );
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
        });
      },
    );
  }

  /// 对比合并流程（方向仲裁的第三选择）：
  ///
  /// 拉取云端快照做逐条 diff 预览，用户勾选后应用到本地，
  /// 再 merge-then-publish 回传收敛指纹 —— 替代「下载覆盖 / 上传覆盖」
  /// 二选一。local_changes 时间戳因 recordChanges:false 导入失真时，
  /// 方向无法可信判定，本入口保证用户总能无损地双向合并。
  Future<void> _handleCompareMergeFlow(
      BuildContext context, LedgerDisplayItem ledger) async {
    final l10n = AppLocalizations.of(context);
    final syncService = ref.read(syncServiceProvider);
    if (syncService is! TransactionsSyncManager) return;

    final block = showBlockingProgressDialog(
      context,
      title: l10n.conflictCompareMergeAction,
      initialStatus: l10n.syncBlockingCheckCloud,
    );
    try {
      final previewResult =
          await syncService.downloadAndPreview(ledgerId: ledger.id);

      if (!mounted || !context.mounted) return;

      // 云端无数据
      if (previewResult == null) {
        await block.close();
        if (!mounted || !context.mounted) return;
        showToast(context, l10n.syncNoCloudBackupMessage);
        return;
      }

      // 旧格式（v5-）无逐条 diff 能力：确认后退回全量替换
      if (previewResult.preview == null) {
        await block.close();
        if (!mounted || !context.mounted) return;
        final confirmed = await AppDialog.confirm<bool>(
          context,
          title: l10n.syncPreviewOldFormat,
          message: l10n.syncPreviewOldFormatMessage,
        );
        if (confirmed != true || !mounted || !context.mounted) return;
        final res = await syncService
            .downloadAndRestoreToCurrentLedger(ledgerId: ledger.id);
        // merge-then-publish：全量替换后同样回传收敛指纹
        await syncService.uploadCurrentLedger(ledgerId: ledger.id, force: true);
        await PostProcessor.sync(ref, ledgerId: ledger.id);
        ref.read(statsRefreshProvider.notifier).state++;
        if (!mounted || !context.mounted) return;
        showToast(context, l10n.syncPreviewApplied(res.inserted));
        return;
      }

      final preview = previewResult.preview!;
      // 交易无 diff 但指纹不同 → 纯元数据（账户/分类/标签/预算/周期）
      // 变更：静默应用元数据合并（与启动检查 applyAll 同策略）
      List<SyncChange> selected;
      if (preview.isEmpty) {
        selected = const [];
      } else {
        // 预览弹窗不能被阻塞遮罩压住：先关阻塞框再弹预览
        await block.close();
        selected = (await showSyncPreviewDialog(
              context,
              preview: preview,
              primaryColor: ref.read(primaryColorProvider),
            )) ??
            const [];
        if (!mounted || !context.mounted) return;
        if (selected.isEmpty) return; // 用户取消或未勾选任何变更
      }

      var appliedCount = 0;
      if (selected.isNotEmpty) {
        final result = await syncService.applyPreviewChanges(
          ledgerId: ledger.id,
          selectedChanges: selected,
          importData: previewResult.importData,
        );
        appliedCount = result.totalCount;
      }

      // merge-then-publish：合并成功后 force 回传收敛云端指纹
      await syncService.uploadCurrentLedger(ledgerId: ledger.id, force: true);
      await PostProcessor.sync(ref, ledgerId: ledger.id);
      ref.read(statsRefreshProvider.notifier).state++;
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(syncStatusRefreshProvider.notifier).state++;

      if (!mounted || !context.mounted) return;
      showToast(context, l10n.syncPreviewApplied(appliedCount));
    } catch (e) {
      logger.warning('LedgersPage', '对比合并失败(ledger=${ledger.id}): $e');
      // 先收阻塞遮罩再弹错误框：错误弹窗不被压在遮罩之下
      await block.close();
      if (mounted && context.mounted) {
        await AppDialog.error(
          context,
          title: l10n.commonFailed,
          message: '$e',
        );
      }
    } finally {
      await block.close();
    }
  }

  /// 显示冲突解决对话框
  Future<void> _showConflictResolutionDialog(
      BuildContext context, LedgerDisplayItem ledger) async {
    final l10n = AppLocalizations.of(context);
    final syncService = ref.read(syncServiceProvider);

    // 获取同步状态详情
    final syncStatus = await syncService.getStatus(ledgerId: ledger.id);

    if (!mounted) return;

    final DateFormat dateFormat = DateFormat('yyyy-MM-dd HH:mm:ss');

    // isProcessing 必须声明在 StatefulBuilder 之外：
    // 声明在 builder 内会在每次 rebuild 时被重置，导致处理中
    // 按钮重新变为可点（双重触发的并发风险）
    bool isProcessing = false;

    await showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        // PopScope 拦截系统返回键：处理中（isProcessing）禁止关闭弹窗，
        // 否则用户可在下载/上传进行中返回离开，底层页面恢复可操作
        return PopScope(
          canPop: false,
          child: StatefulBuilder(
            builder: (stateContext, setState) {
              return AlertDialog(
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
                title: Row(
                  children: [
                    const Icon(Icons.warning, color: Colors.red, size: 28),
                    const SizedBox(width: 12),
                    Text(l10n.ledgersConflictTitle),
                  ],
                ),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.ledgersConflictMessage,
                        style: const TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w500),
                      ),
                      const SizedBox(height: 16),

                      // 本地信息
                      Container(
                        padding: const EdgeInsets.all(12),
                        decoration: BoxDecoration(
                          // 语义色仅作 12% 底,正文/副文用 onSurface 系,
                          // 暗色模式下高饱和实底会压垮浅色正文字(可读性)
                          color: PiggyTokens.info(context).withValues(alpha: 0.12),
                          borderRadius:
                              BorderRadius.circular(PiggyDimens.radiusSm),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              l10n.ledgersConflictLocalInfo(
                                  syncStatus.localCount),
                              style:
                                  const TextStyle(fontWeight: FontWeight.w600),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              l10n.ledgersConflictLocalFingerprint(
                                syncStatus.localFingerprint.substring(0, 8),
                              ),
                              style: TextStyle(
                                  fontSize: 12,
                                  color: PiggyTokens.textSecondary(context)),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // 云端信息
                      if (syncStatus.cloudFingerprint != null &&
                          syncStatus.cloudExportedAt != null)
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: PiggyTokens.warning(context)
                                .withValues(alpha: 0.12),
                            borderRadius:
                                BorderRadius.circular(PiggyDimens.radiusSm),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                l10n.ledgersConflictRemoteInfo(
                                    syncStatus.cloudCount ?? 0),
                                style: const TextStyle(
                                    fontWeight: FontWeight.w600),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                l10n.ledgersConflictRemoteUpdated(
                                  dateFormat.format(
                                      syncStatus.cloudExportedAt!.toLocal()),
                                ),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: PiggyTokens.textSecondary(context)),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                l10n.ledgersConflictRemoteFingerprint(
                                  syncStatus.cloudFingerprint!.substring(0, 8),
                                ),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: PiggyTokens.textSecondary(context)),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
                actions: [
                  if (isProcessing)
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 16),
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  else ...[
                    TextButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: Text(l10n.commonCancel),
                    ),
                    TextButton(
                      onPressed: () async {
                        // 先关冲突弹窗再进入对比合并流程（预览弹窗不能被压住）
                        Navigator.pop(dialogContext);
                        await _handleCompareMergeFlow(context, ledger);
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.difference_outlined, size: 18),
                          const SizedBox(width: 4),
                          Text(l10n.conflictCompareMergeAction),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () async {
                        setState(() => isProcessing = true);
                        try {
                          showToast(context, l10n.ledgersConflictDownloading);
                          final result = await syncService
                              .downloadAndRestoreToCurrentLedger(
                            ledgerId: ledger.id,
                          );

                          if (stateContext.mounted) {
                            Navigator.pop(dialogContext);
                          }

                          if (!mounted) return;

                          // 下载完成后，触发刷新状态和账本列表
                          await PostProcessor.sync(ref, ledgerId: ledger.id);

                          // 刷新统计
                          ref.read(statsRefreshProvider.notifier).state++;

                          showToast(
                            context,
                            l10n.ledgersConflictDownloadSuccess(
                                result.inserted),
                          );
                        } catch (e) {
                          setState(() => isProcessing = false);
                          if (stateContext.mounted) {
                            await AppDialog.error(
                              stateContext,
                              title: l10n.commonFailed,
                              message: '$e',
                            );
                          }
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.download, size: 18),
                          const SizedBox(width: 4),
                          Text(l10n.ledgersConflictDownload),
                        ],
                      ),
                    ),
                    FilledButton(
                        onPressed: () async {
                          setState(() => isProcessing = true);
                          try {
                            showToast(context, l10n.ledgersConflictUploading);
                            // M7：此处是冲突卡片上的「上传」按钮，用户已明确
                            // 选择以本地覆盖云端，force 跳过二次拦截
                            await syncService.uploadCurrentLedger(
                                ledgerId: ledger.id, force: true);

                          if (stateContext.mounted) {
                            Navigator.pop(dialogContext);
                          }

                          if (!mounted) return;

                          // 刷新列表和同步状态
                          ref.read(ledgerListRefreshProvider.notifier).state++;
                          ref.read(syncStatusRefreshProvider.notifier).state++;

                          showToast(context, l10n.ledgersConflictUploadSuccess);
                        } catch (e) {
                          setState(() => isProcessing = false);
                          if (stateContext.mounted) {
                            await AppDialog.error(
                              stateContext,
                              title: l10n.commonFailed,
                              message: '$e',
                            );
                          }
                        }
                      },
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.upload, size: 18),
                          const SizedBox(width: 4),
                          Text(l10n.ledgersConflictUpload),
                        ],
                      ),
                    ),
                  ],
                ],
              );
            },
          ),
        );
      },
    );
  }
}

/// 区域标题
class _SectionHeader extends ConsumerWidget {
  final String title;
  final String? trailing;
  final Widget? action;

  const _SectionHeader({
    required this.title,
    this.trailing,
    this.action,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16.0.scaled(context, ref),
        8.0.scaled(context, ref),
        16.0.scaled(context, ref),
        8.0.scaled(context, ref),
      ),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              fontSize: 16.0.scaled(context, ref),
              fontWeight: FontWeight.w600,
              color: PiggyTokens.textSecondary(context),
            ),
          ),
          if (trailing != null) ...[
            SizedBox(width: 8.0.scaled(context, ref)),
            Container(
              padding: EdgeInsets.symmetric(
                horizontal: 8.0.scaled(context, ref),
                vertical: 2.0.scaled(context, ref),
              ),
              decoration: BoxDecoration(
                color: PiggyTokens.surfaceSecondary(context),
                borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
              ),
              child: Text(
                trailing!,
                style: TextStyle(
                  fontSize: 12.0.scaled(context, ref),
                  color: PiggyTokens.textTertiary(context),
                ),
              ),
            ),
          ],
          const Spacer(),
          if (action != null) action!,
        ],
      ),
    );
  }
}
