/// 重构后的账本列表页面
///
/// 集成本地账本 + 远程账本管理
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../providers.dart';
import '../../models/ledger_display_item.dart';
import '../../cloud/transactions_sync_manager.dart';
import '../../cloud/sync_service.dart';
import '../../cloud/sync_diff_service.dart' show SyncChange;
import '../../cloud/startup_sync_checker.dart' show StartupSyncChecker;
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/currency/currency_picker_sheet.dart';
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

/// 批量恢复确认文案中的同名多槽位明细（两次实测 §4.2 遗留缺口）。
///
/// 「全部恢复」走 downloadRemoteLedger 的同名复用语义：同名槽位依次
/// 覆盖，**本地最终只留恢复到的最后一个**（与启动检查「改名导入产生
/// 账本（2）」不同），所以措辞是「相互覆盖」而非「产生重复」。
/// 明细格式与警示弹窗/远程卡片同口径：`短ID·上传时间(条数)`。
/// 无同名槽位时返回 null（确认文案保持原样）。
String? batchRestoreDuplicateDetail(List<LedgerDisplayItem> remoteLedgers) {
  final byName = <String, List<LedgerDisplayItem>>{};
  for (final l in remoteLedgers) {
    byName.putIfAbsent(l.name, () => []).add(l);
  }
  final dupNames = [
    for (final e in byName.entries)
      if (e.value.length >= 2) e.key
  ];
  if (dupNames.isEmpty) return null;
  final dup = <String, List<LedgerDisplayItem>>{};
  // 组内按云端上传时间新者在前（与 startupSyncDuplicateSlots 展示一致）
  for (final name in dupNames) {
    dup[name] = [...byName[name]!]
      ..sort((a, b) => b.lastUpdated.compareTo(a.lastUpdated));
  }
  return dup.entries.map((e) {
    final slots = e.value
        .map((l) =>
            '${l.remoteSyncId == null ? '?' : formatSlotShortId(l.remoteSyncId!)}'
            '·${formatCloudUploadDate(l.lastUpdated)}(${l.transactionCount})')
        .join('、');
    return '${e.key}: $slots';
  }).join('；');
}

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
        logger.info(
            'Ledger', '🟢 [LedgersPage] 检测到导入完成: ledgerId=${next.ledgerId}');
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
            tooltip: AppLocalizations.of(context).tooltipRefresh,
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
    return ListView(
      padding: EdgeInsets.symmetric(
        vertical: 8.0.scaled(context, ref),
      ),
      children: [
        // 本地账本区域
        if (localLedgers.isNotEmpty) ...[
          _SectionHeader(
            title: AppLocalizations.of(context).ledgersLocal,
            trailing: localLedgers.length.toString(),
            // 「全部上传」仅快照同步类（WebDAV/S3/Supabase/iCloud）显示；
            // 未配置云服务时无上传目标，隐藏入口避免误导。与远程区
            // 「全部恢复」按钮对称。
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
                moreItems: _localLedgerMenuItems(context, ledger),
                onMoreSelected: (v) => _onLocalLedgerAction(context, ledger, v),
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
                  style: TextStyle(color: PiggyTokens.error(context)),
                ),
              ),
            )
          else
            ...remoteLedgers.map((ledger) => LedgerCard(
                  ledger: ledger,
                  onTap: () => _handleRemoteLedgerTap(context, ledger),
                  moreItems: _remoteLedgerMenuItems(context),
                  onMoreSelected: (v) =>
                      _onRemoteLedgerAction(context, ledger, v),
                )),
        ],

        SizedBox(height: 60.0.scaled(context, ref)),
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
      if (syncService is TransactionsSyncManager) {
        // remote-only 账本本地无行：不能用 pathForLedger(回退数字 id 路径,
        // 指向不存在的文件),直接按槽位 key(= 源端 syncId)拼云端路径。
        final slotKey = ledger.remoteSyncId;
        if (slotKey == null || slotKey.isEmpty) {
          throw Exception('Remote ledger slot key missing');
        }
        await syncService.downloadRemoteLedger(
          name: ledger.name,
          currency: ledger.currency,
          remotePath: 'ledger_$slotKey.json',
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

  /// 本地账本的「⋯」菜单条目（项目锚点浮层菜单，不铺遮罩色）。
  ///
  /// myRole 沿自 v24 共享账本(云端协同已下线):存量 Editor 角色的账本
  /// 隐藏 edit / clear / delete 等 owner-only 操作,仅保留预算/上传/仅删本地。
  /// 手动上传仅对快照同步类后端开放。
  ///
  /// 分组：常规操作（编辑 / 预算 / 上传）与破坏性操作（清空 / 删除）之间插一条
  /// 分隔线 —— 分隔线以下是「点了会丢数据」的那几档，不该和上传混在一列里。
  List<PiggyMenuItem> _localLedgerMenuItems(
      BuildContext context, LedgerDisplayItem ledger) {
    final l10n = AppLocalizations.of(context);
    final isOwner = ledger.myRole == 'owner';
    final canUpload = ref.read(syncServiceProvider) is TransactionsSyncManager;
    final destructive = <PiggyMenuItem>[
      if (isOwner)
        PiggyMenuItem.action(
          value: 'clear',
          icon: Icons.clear_all,
          label: l10n.ledgersClear,
          color: PiggyTokens.warning(context),
        ),
      // "仅删除本地"对 Owner 和 Editor 都可用 — 这是本地清理动作,
      // 不影响 server。Editor 用这个清掉 Owner 已删账本残留;Owner
      // 用来清不想要的本地副本但保留 server 数据。
      PiggyMenuItem.action(
        value: 'deleteLocal',
        icon: Icons.delete_outline,
        label: l10n.ledgersDeleteLocal,
        color: PiggyTokens.warning(context),
      ),
      if (isOwner)
        PiggyMenuItem.action(
          value: 'delete',
          icon: Icons.delete_forever_outlined,
          label: l10n.ledgersDelete,
          isDanger: true,
        ),
    ];
    return [
      if (isOwner)
        PiggyMenuItem.action(
          value: 'edit',
          icon: Icons.edit,
          label: l10n.ledgersEdit,
        ),
      // 预算管理入口 — 每个账本独立预算,Owner/Editor 都能看(Editor 进
      // BudgetPage 后 isEditorInShared 隐藏 + 按钮和编辑入口,只看不改)。
      PiggyMenuItem.action(
        value: 'budget',
        icon: Icons.pie_chart_outline_rounded,
        label: l10n.budgetManagement,
      ),
      // 单账本上传 — 放在破坏性操作（清空/删除）之前，与编辑类操作分组。
      if (canUpload)
        PiggyMenuItem.action(
          value: 'upload',
          icon: Icons.cloud_upload_outlined,
          label: l10n.ledgersUploadThis,
        ),
      if (destructive.isNotEmpty) const PiggyMenuItem.divider(),
      ...destructive,
    ];
  }

  /// 本地账本菜单选中后的分发（菜单自身已关闭，这里直接执行动作）。
  Future<void> _onLocalLedgerAction(
    BuildContext context,
    LedgerDisplayItem ledger,
    String action,
  ) async {
    if (!mounted || !context.mounted) return;

    if (action == 'edit') {
      await _handleEditLedger(context, ledger);
    } else if (action == 'budget') {
      // 切到长按的账本(BudgetPage 内部 watch currentLedger,不接 ledgerId 参
      // 数),再 push。语义上"从账本列表 → 长按 A → 预算管理"自然就是切到 A。
      if (ref.read(currentLedgerIdProvider) != ledger.id) {
        ref.read(currentLedgerIdProvider.notifier).state = ledger.id;
        ref.invalidate(currentLedgerProvider);
      }
      if (mounted && context.mounted) {
        await Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => const BudgetPage()),
        );
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

  /// 远程账本的「⋯」菜单条目（与本地同款外壳，只有下载 / 删除两档）。
  List<PiggyMenuItem> _remoteLedgerMenuItems(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return [
      PiggyMenuItem.action(
        value: 'download',
        icon: Icons.cloud_download,
        label: l10n.ledgersDownload,
      ),
      PiggyMenuItem.action(
        value: 'delete',
        icon: Icons.delete_forever_outlined,
        label: l10n.ledgersDeleteRemote,
        isDanger: true,
      ),
    ];
  }

  /// 远程账本菜单选中后的分发。
  Future<void> _onRemoteLedgerAction(
    BuildContext context,
    LedgerDisplayItem ledger,
    String action,
  ) async {
    if (!mounted || !context.mounted) return;
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

    if (ledgerData == null || !mounted || !context.mounted) return;

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
        builder: (dctx) => AppDialogShell(
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
    } catch (e) {
      logger.warning('LedgersPage', '改账本起始日后刷新小组件失败', e);
    }
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
    // 双重危险确认（各 5 秒倒计时）：清空账单不可恢复
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.ledgersClearTitle,
      firstMessage:
          l10n.ledgersClearMessage(translateLedgerName(context, ledger.name)),
      secondMessage: l10n.ledgersClearReconfirmMessage,
    );

    if (!confirmed || !mounted) return;

    try {
      final repo = ref.read(repositoryProvider);

      // 删账单前先收集该账本附件 fileName(删行后就查不到了)
      final attachmentFiles =
          await repo.getAttachmentFileNamesByLedger(ledger.id);
      // 删除该账本的所有账单(批量删行不删物理文件)
      await repo.clearLedgerTransactions(ledger.id);
      // 删行后精准清理这些附件的物理文件(引用计数)
      await _cleanupLedgerAttachmentFiles(attachmentFiles);

      if (!mounted || !context.mounted) return;

      // 清空缓存的交易数据（避免首页使用旧缓存）
      ref.read(cachedTransactionsProvider.notifier).state = null;

      // 触发同步状态刷新
      await PostProcessor.sync(ref, ledgerId: ledger.id);
      if (!mounted || !context.mounted) return;

      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, l10n.ledgersClearSuccess);
    } catch (e) {
      if (!mounted || !context.mounted) return;
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
    if (!mounted || !context.mounted) return;

    // 双重危险确认：仅删本地不影响云端，倒计时时间可稍短
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.ledgersDeleteLocalTitle,
      firstMessage: l10n
          .ledgersDeleteLocalMessage(translateLedgerName(context, ledger.name)),
      secondMessage: l10n.ledgersDeleteLocalReconfirmMessage,
      okLabel: l10n.commonDelete,
      countdownSeconds: 3,
    );

    if (!confirmed || !mounted) return;

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

      if (!mounted || !context.mounted) return;

      // currentLedgerProvider 已是 StreamProvider(Drift watch 自动推送),
      // 此 invalidate 仅作防御性重订阅(如流曾进入 error 态),正常路径冗余无害。
      ref.invalidate(currentLedgerProvider);
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, l10n.ledgersDeleteLocalSuccess);
    } catch (e) {
      if (!mounted || !context.mounted) return;
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
    if (!mounted || !context.mounted) return;

    // 双重危险确认（各 5 秒倒计时）：删账本含云端备份，不可恢复
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.ledgersDeleteConfirm,
      firstMessage: l10n.ledgersDeleteMessage,
      secondMessage: l10n.ledgersDeleteReconfirmMessage,
      okLabel: l10n.commonDelete,
    );

    if (!confirmed || !mounted) return;

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

      // 注：不再对被删账本触发 PostProcessor.sync。云端的快照文件已由
      // 上方 deleteRemoteBackup 删除（该调用必须发生在 deleteLedger 之前，
      // 见上方注释）；快照同步模型里没有服务端 canonical state 需要额外
      // 推送 delete 变更，旧增量引擎下线后这段调用只会对已删除的账本行
      // 触发一次注定失败的导出（被防抖链捕获记一条 error 日志，无效果）。

      if (!mounted || !context.mounted) return;

      // 同 _handleDeleteLocalLedgerOnly:显式 invalidate currentLedgerProvider,
      // 哪怕 ledgerId 没切(没其他账本可切),也得让首页胶囊重读 → 查不到行 →
      // 显示 "+ 新建账本"。
      ref.invalidate(currentLedgerProvider);
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(statsRefreshProvider.notifier).state++;

      showToast(context, AppLocalizations.of(context).ledgersDeleted);
    } catch (e) {
      if (!mounted || !context.mounted) return;
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
    final l10n = AppLocalizations.of(context);
    // 双重危险确认（各 5 秒倒计时）：删的是云端唯一副本
    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.ledgersDeleteRemoteConfirm,
      firstMessage: l10n.ledgersDeleteRemoteMessage(
          translateLedgerName(context, ledger.name)),
      secondMessage: l10n.ledgersDeleteRemoteReconfirmMessage,
    );

    if (!confirmed || !mounted || !context.mounted) return;

    try {
      showToast(context, AppLocalizations.of(context).ledgersDeleting);

      final syncService = ref.read(syncServiceProvider);
      if (syncService is! TransactionsSyncManager) {
        throw Exception('Cloud sync not available');
      }

      // remote-only 账本本地无行：按槽位 key 拼云端路径（同下载入口）
      final slotKey = ledger.remoteSyncId;
      if (slotKey == null || slotKey.isEmpty) {
        throw Exception('Remote ledger slot key missing');
      }
      await syncService.deleteRemoteLedger(remotePath: 'ledger_$slotKey.json');

      if (!mounted || !context.mounted) return;

      ref.read(ledgerListRefreshProvider.notifier).state++;

      showToast(
          context, AppLocalizations.of(context).ledgersDeleteRemoteSuccess);
    } catch (e) {
      if (!mounted || !context.mounted) return;
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

    // 同名多槽位警示：云端存在同名槽位时，全部恢复会依次相互覆盖，
    // 本地只留其一。拼进第一段确认，让用户在倒计时内看到具体名单。
    final l10n = AppLocalizations.of(context);
    final dupDetail = batchRestoreDuplicateDetail(remoteLedgers);
    var firstMessage = l10n.ledgersRestoreAllMessage(remoteLedgers.length);
    if (dupDetail != null) {
      firstMessage =
          '$firstMessage\n${l10n.ledgersRestoreAllDuplicateSlots(dupDetail)}';
    }

    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: l10n.ledgersRestoreAllTitle,
      firstMessage: firstMessage,
      secondMessage: l10n.ledgersRestoreAllReconfirmMessage,
    );

    if (!confirmed || !mounted || !context.mounted) return;

    setState(() => _isRestoring = true);

    // 强制阻塞弹窗：批量恢复期间禁止切账本/触发上传等一切页面操作，
    // 防止恢复写入与用户操作互相踩写
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
      if (syncService is TransactionsSyncManager) {
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
  /// 语义：以本地为准覆盖云端（用户已在双重危险确认中知晓覆盖警示）。
  /// 流程：双重危险确认（各 5 秒倒计时）→ **阻塞式进度弹窗**（期间禁止
  /// 一切页面操作）→ uploadAllLedgers（串行、单个失败不中断）→ 关闭弹窗
  /// → 刷新 providers → 结果弹窗。
  Future<void> _handleBatchUpload(BuildContext context) async {
    final localLedgers = ref.read(localLedgersProvider).value ?? [];

    final confirmed = await showDoubleDangerConfirmDialog(
      context,
      title: AppLocalizations.of(context).ledgersUploadAll,
      firstMessage: AppLocalizations.of(context)
          .ledgersUploadAllMessage(localLedgers.length),
      secondMessage:
          AppLocalizations.of(context).ledgersUploadAllReconfirmMessage,
    );

    if (!confirmed || !mounted || !context.mounted) return;

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
          child: AppDialogShell(
            title: Text(l10n.ledgersUploadAll),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                PiggySpinner(size: 36, color: PiggyTokens.primary(dctx)),
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
      if (mounted && context.mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      await dialogFuture;

      if (!mounted || !context.mounted) return;

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
      if (mounted && context.mounted && dialogOpen) {
        Navigator.of(context, rootNavigator: true).pop();
        dialogOpen = false;
      }
      if (!mounted || !context.mounted) return;
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
    // P1-4 softFail 可见化：单账本上传若未确认收敛（verified=false），
    // 提示差异化文案而非普通成功 —— 数据已在云端，用户无需重传。
    var unverified = false;

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
        final result = await ref
            .read(syncServiceProvider)
            .uploadCurrentLedger(ledgerId: ledger.id, force: force);
        ok = true;
        unverified = !result.verified;
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
      } else if (uploaded && unverified) {
        // softFail：数据已上云但写后校验未确认收敛 —— 明确告知而非
        // 普通成功（脏标记未清，下次 getStatus 会重新比对）
        showToast(context, AppLocalizations.of(context).mineUploadUnverified);
        ref.read(ledgerListRefreshProvider.notifier).state++;
        ref.read(syncStatusRefreshProvider.notifier).state++;
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

      if (!mounted || !context.mounted) return;
      showToast(context, AppLocalizations.of(context).ledgersCreatedSuccess);
    } catch (e) {
      if (!mounted || !context.mounted) return;
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
        return StatefulBuilder(builder: (ctx, setState) {
          // 外壳走项目弹窗语言（[AppDialogShell]）：居中标题 + 表单内容 +
          // 底部分栏动作区；不再自绘 Dialog(surfaceElevated + radiusXl) + Padding。
          return AppDialogShell(
            title: Text(title ?? AppLocalizations.of(ctx).ledgersEdit),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: nameCtrl,
                  decoration: piggyOutlinedDecoration(
                    ctx,
                    label: AppLocalizations.of(ctx).ledgersName,
                  ),
                ),
                const SizedBox(height: PiggyDimens.p12),
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
              ],
            ),
            // 底部按钮与确认框同一语言：取消｜保存分栏（保存=主题色）。
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: Text(AppLocalizations.of(ctx).commonCancel),
              ),
              TextButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: Text(
                  title == AppLocalizations.of(ctx).ledgersNew
                      ? AppLocalizations.of(ctx).ledgersCreate
                      : AppLocalizations.of(ctx).commonSave,
                ),
              ),
            ],
          );
        });
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

  /// 28 宫格月起始日选择器（复用共用 1~N 日网格抽屉）
  Future<int?> _showMonthStartDayPicker(BuildContext context,
      {required int initial}) {
    final l10n = AppLocalizations.of(context);
    return showDayOfMonthPickerSheet(
      context,
      title: l10n.ledgersMonthStartDay,
      hint: l10n.ledgersMonthStartDayHint,
      selected: initial,
    );
  }

  /// 货币选择器（统一走共用币种抽屉：国旗 + 选中高亮 + 搜索）
  Future<String?> _showCurrencyPicker(BuildContext context, {String? initial}) {
    return showCurrencyPickerSheet(
      context,
      selected: initial ?? '',
      primaryColor: ref.read(primaryColorProvider),
      title: AppLocalizations.of(context).ledgersSelectCurrency,
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
        final res = await syncService.downloadAndRestoreToCurrentLedger(
            ledgerId: ledger.id);
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
        if (!mounted || !context.mounted) return;
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

      // S1 守卫（手动入口版）：用户未勾选的云端删除（交易行 + 账户/分类/
      // 标签/预算/周期规则/汇率覆盖等实体）本轮不生效，照常 force 回传会把
      // 残留推回云端 → 删除被"复活"并传播到所有设备。判据与启动检查同源。
      final skipPublish = StartupSyncChecker.shouldSkipMergePublish(
        previewExists: previewResult.preview != null,
        unselectedDeletedCount: previewResult.preview == null
            ? 0
            : StartupSyncChecker.unselectedDeletedCount(previewResult.preview!),
      );

      // merge-then-publish：合并成功后 force 回传收敛云端指纹
      if (!skipPublish) {
        await syncService.uploadCurrentLedger(ledgerId: ledger.id, force: true);
      } else {
        // 静默跳过回传会让用户以为"同步完了" —— 必须明确告知那些没勾的
        // 删除本轮没生效（与启动检查的 publishSkippedHint 同口径）。
        logger.info(
            'LedgersPage',
            '账本 ${ledger.name} 存在未勾选的云端删除，'
                '本轮跳过回传');
      }
      await PostProcessor.sync(ref, ledgerId: ledger.id);
      ref.read(statsRefreshProvider.notifier).state++;
      ref.read(ledgerListRefreshProvider.notifier).state++;
      ref.read(syncStatusRefreshProvider.notifier).state++;

      if (!mounted || !context.mounted) return;
      showToast(
        context,
        skipPublish
            ? '${l10n.syncPreviewApplied(appliedCount)}\n${l10n.syncSkippedPublishUnselectedDelete(1)}'
            : l10n.syncPreviewApplied(appliedCount),
      );
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

    if (!mounted || !context.mounted) return;

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
              return AppDialogShell(
                wide: true,
                title: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.warning,
                        color: PiggyTokens.error(stateContext), size: 28),
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
                          color:
                              PiggyTokens.info(context).withValues(alpha: 0.12),
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
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: PiggySpinner(
                        size: 20,
                        color: PiggyTokens.primary(context),
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

                          // 下载完成后，触发刷新状态和账本列表
                          await PostProcessor.sync(ref, ledgerId: ledger.id);
                          if (!mounted || !context.mounted) return;

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
                    TextButton(
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

                          if (!mounted || !context.mounted) return;

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
