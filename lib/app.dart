import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'pages/main/home_page.dart';
import 'pages/main/analytics_page.dart';
import 'pages/account/accounts_page.dart';
import 'pages/budget/budget_page.dart';
import 'pages/main/mine_page.dart';
import 'pages/transaction/transaction_editor_page.dart';
import 'providers.dart';
import 'l10n/app_localizations.dart';
import 'widget/widget_manager.dart';
import 'widgets/ui/ui.dart';
import 'widgets/ui/speed_dial_fab.dart';
import 'cloud/sync_service.dart';
import 'cloud/transactions_sync_manager.dart';
import 'cloud/startup_sync_checker.dart';
import 'cloud/startup_sync_overlay.dart';
import 'cloud/backup/backup_scheduler.dart';
import 'cloud/backup/cloud_backup_providers.dart';
import 'cloud/sync_restore_guard.dart';
import 'providers/sync_providers.dart' as sp;
import 'utils/voice_billing_helper.dart';
import 'utils/image_billing_helper.dart';
import 'pages/ai/ai_chat_page.dart';
import 'services/platform/app_link_service.dart';
import 'services/platform/quick_actions_service.dart';
import 'services/system/logger_service.dart';
import 'services/security/app_lock_service.dart';
import 'providers/security_providers.dart';
import 'styles/tokens.dart';
import 'providers/avatar_providers.dart';

class PiggyApp extends ConsumerStatefulWidget {
  const PiggyApp({super.key});

  @override
  ConsumerState<PiggyApp> createState() => _PiggyAppState();
}

class _PiggyAppState extends ConsumerState<PiggyApp>
    with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final _pages = const [
    HomePage(),
    AnalyticsPage(),
    AccountsPage(asTab: true),
    MinePage(),
  ];

  // 双击检测：记录最后一次点击的时间和索引
  DateTime? _lastTapTime;
  int? _lastTappedIndex;

  // 双击返回退出：记录最后一次返回键按下时间
  DateTime? _lastBackPressTime;

  // AppLink 监听订阅
  ProviderSubscription<AppLinkAction?>? _appLinkSubscription;

  // 同步完成提示气泡(增量同步)相关状态
  ProviderSubscription<int>? _snapshotSyncToastSubscription;
  Timer? _syncToastTimer;
  int _syncToastPushed = 0;
  int _syncToastPulled = 0;

  // 快捷操作服务
  final QuickActionsService _quickActionsService = QuickActionsService();

  // 防止 AppLink 动作重复执行（使用静态变量，跨实例共享）
  static bool _isHandlingAppLink = false;
  static DateTime? _lastAppLinkHandleTime;

  // 记账按钮相关状态
  late AnimationController _expandController;
  late Animation<double> _expandAnimation;
  int? _hoveredIndex;
  OverlayEntry? _overlayEntry;
  final GlobalKey _centerButtonKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    // 初始化记账按钮动画控制器
    _expandController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _expandAnimation = CurvedAnimation(
      parent: _expandController,
      curve: Curves.easeOut,
    );

    // 后台刷新账本同步状态
    _refreshLedgersStatusInBackground();
    // 同步完成时弹出提示气泡(数据变更 / 其它操作触发增量同步后给用户反馈)
    _setupSyncCompletionToast();
    // 延迟监听 AppLink，确保 context 可用
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _setupAppLinkListener();
      _setupQuickActions();
      // 启动时检查云端更新
      _triggerStartupSyncCheck();
      // 每日定时备份：1 分钟粒度检查，触发条件在闭包内判定
      _backupScheduler = BackupScheduler(onCheck: _runScheduledBackupCheck)
        ..start();
    });
  }

  /// 启动时云端数据拉取检查是否已触发（PiggyApp 实例级幂等标志）
  ///
  /// 用于避免 microtask 触发与 listenManual 触发重复执行。
  /// StartupSyncChecker 内部也有 _done 标志，但因每次创建新实例，
  /// 这里在 PiggyApp 层加一道闸门。
  bool _startupSyncCheckTriggered = false;

  /// 当前启动检查的 controller（用于在 dispose 时清理 overlay）
  StartupSyncController? _startupSyncController;

  /// 每日定时备份调度器（App 运行期间每分钟检查一次）
  BackupScheduler? _backupScheduler;

  /// 启动时云端数据拉取检查（仅路径 A：S3/WebDAV/Supabase/iCloud）
  ///
  /// 与 _refreshLedgersStatusInBackground 并行执行，等 syncServiceProvider 就绪为
  /// TransactionsSyncManager 后触发；若启动时已是 TransactionsSyncManager 则立即触发。
  /// 通过 overlay 全屏阻断用户交互，检查完成或用户确认后关闭。
  void _triggerStartupSyncCheck() {
    Future.microtask(() async {
      if (_startupSyncCheckTriggered) return;
      try {
        final syncService = ref.read(sp.syncServiceProvider);
        if (syncService is! TransactionsSyncManager) {
          // syncService 尚未就绪（LocalOnlySyncService），等 listenManual 兜底
          return;
        }
        if (!mounted) return;
        _startupSyncCheckTriggered = true;
        await _runStartupSyncCheck(syncService);
      } catch (e, st) {
        logger.warning('StartupSyncCheck', '启动检查失败: $e\n$st');
      }
    });

    // 兜底：syncServiceProvider 从 LocalOnly 变成 TransactionsSyncManager 时再触发一次
    ref.listenManual<SyncService>(
      sp.syncServiceProvider,
      (prev, next) {
        // 仅在从非 TransactionsSyncManager 变为 TransactionsSyncManager 时触发
        if (prev is TransactionsSyncManager) return;
        if (next is! TransactionsSyncManager) return;
        if (_startupSyncCheckTriggered) return;
        _startupSyncCheckTriggered = true;
        Future.microtask(() async {
          if (!mounted) return;
          try {
            await _runStartupSyncCheck(next);
          } catch (e, st) {
            logger.warning('StartupSyncCheck', '启动检查失败（listen 触发）: $e\n$st');
          }
        });
      },
    );
  }

  /// 定时备份检查（BackupScheduler 每分钟调用）：
  /// 开关开启 && 到达设定时间 && 当日定时未触发 && 云服务就绪 → 后台非阻塞执行。
  /// 去重 key 用 backup_auto_last_date（仅定时写入）：手动备份不占用当日
  /// 自动名额，到点仍会执行一次（用最新数据覆盖当日文件）。
  /// 成败均写 auto key（当日不重试，失败状态显示在卡片供手动补救）。
  /// 云服务未就绪（LocalOnly 等待期等）不写 key，下一分钟重查。
  Future<void> _runScheduledBackupCheck() async {
    // 审计 S6：启动恢复/全量同步进行中时本轮备份让位——半恢复态 DB
    // 打包上传会覆盖当日好备份。下一分钟重查。
    if (SyncRestoreGuard.isBusy) {
      logger.info('Backup', '恢复进行中，本轮定时备份跳过');
      return;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!(prefs.getBool('backup_auto_enabled') ?? false)) return;
      final timeStr =
          prefs.getString('backup_time') ?? BackupScheduler.defaultBackupTime;
      final autoLast = prefs.getString('backup_auto_last_date');
      final now = DateTime.now();
      if (!BackupScheduler.shouldTriggerNow(
        enabled: true,
        scheduledMinutes: BackupScheduler.parseHhMm(timeStr),
        lastDate: autoLast,
        now: now,
      )) {
        return;
      }

      final backup = ref.read(cloudBackupServiceProvider);
      if (backup == null) return; // 云未就绪：不计为当日已备

      final today = BackupScheduler.formatDate(now);
      try {
        await backup.createBackup();
        await prefs.setString('backup_last_result', 'ok');
        logger.info('Backup', '定时备份完成');
      } catch (e) {
        await prefs.setString('backup_last_result', 'fail');
        logger.warning('Backup', '定时备份失败: $e');
      }
      // 显示用 last_date 与定时去重 auto key 都要写
      await prefs.setString('backup_last_date', today);
      await prefs.setString('backup_auto_last_date', today);
      if (mounted) {
        ref.read(backupRefreshProvider.notifier).state++;
      }
    } catch (e) {
      logger.warning('Backup', '定时备份检查异常: $e');
    }
  }

  /// 执行启动检查：创建 controller + overlay，运行 checker，管理生命周期
  Future<void> _runStartupSyncCheck(TransactionsSyncManager syncService) async {
    final controller = StartupSyncController();
    _startupSyncController = controller;

    // 监听 controller 状态变化，管理 overlay 生命周期
    controller.addListener(() {
      final state = controller.state;
      if (state is DoneState) {
        // 完成态：1.5 秒后自动 dismiss
        Future.delayed(const Duration(milliseconds: 1500), () {
          if (controller.state is! DismissedState) {
            controller.dismiss();
          }
        });
      } else if (state is DismissedState) {
        // 已关闭：detach overlay
        controller.detach();
        _startupSyncController = null;
      }
    });

    // 挂载 overlay 到全局 Overlay
    final overlay = Overlay.of(context, rootOverlay: true);
    controller.attach(overlay);

    // 运行检查（审计 S6：恢复临界区内定时备份让位，避免打包半恢复态 DB）
    await SyncRestoreGuard.run(
      () => StartupSyncChecker(
        deps: WidgetRefDeps(ref, syncService, context),
        controller: controller,
      ).runIfNeeded(),
    );
  }

  /// 设置快捷操作
  void _setupQuickActions() {
    logger.info('QuickActions', 'PiggyApp: 设置快捷操作服务...');
    _quickActionsService.onNavigate = (action) {
      if (mounted) {
        logger.info('QuickActions', 'PiggyApp: 执行快捷操作 $action');
        _handleAppLinkAction(action);
      }
    };
    _quickActionsService.initialize();
    // 处理可能在初始化前就触发的快捷操作
    _quickActionsService.processPendingAction();
    logger.info('QuickActions', 'PiggyApp: 快捷操作服务已设置');
  }

  /// 设置 AppLink 监听
  void _setupAppLinkListener() {
    logger.info('AppLink', 'PiggyApp: 设置 AppLink 监听...');
    _appLinkSubscription = ref.listenManual<AppLinkAction?>(
      pendingAppLinkActionProvider,
      (previous, next) {
        logger.info('AppLink',
            'PiggyApp: 监听触发 previous=$previous, next=$next, mounted=$mounted');
        if (next != null && mounted) {
          // 不在此处直接 push：冷启动 / 厂商主题变更(themeChanged)会重建页面树,
          // 此刻多半处于 inactive/hidden,push 的路由会被丢弃(deep-link「没打开」根因)。
          // 改为持久化待处理深链,等 ready + 前台 resumed 后在最终页面树上认领打开。
          _persistPendingDeepLink(
            next,
            ref.read(pendingNewTransactionTypeProvider),
            categoryId: ref.read(pendingNewTransactionCategoryIdProvider),
            page: ref.read(pendingOpenPageProvider),
          );
          ref.read(pendingAppLinkActionProvider.notifier).state = null;
          _drainPendingDeepLink(trigger: 'listener');
        }
      },
      fireImmediately: true,
    );
    logger.info('AppLink', 'PiggyApp: AppLink 监听已设置');
  }

  /// 订阅同步完成信号,在「本地数据变更 / 其它操作触发的同步」完成后弹出
  /// 提示气泡,让用户明确感知云端已同步,避免"改了数据不知道有没有存到云端"。
  ///
  /// TransactionsSyncManager(S3 / WebDAV / Supabase 快照同步)不发射事件流,
  /// 由 PostProcessor 在「数据变更后的自动上传」成功时 bump
  /// [sp.snapshotSyncCompletedProvider](手动上传走 cloud_sync_page 已有弹窗,
  /// 不走这里,避免双重提示)。
  void _setupSyncCompletionToast() {
    // 快照同步完成信号:upload 成功 → 弹「已同步」提示。
    _snapshotSyncToastSubscription = ref.listenManual<int>(
      sp.snapshotSyncCompletedProvider,
      (previous, next) {
        if (next == 0 || next == previous) return;
        if (!mounted) return;
        final l10n = AppLocalizations.of(context);
        showToast(context, l10n.mineUploadSuccessMessage);
      },
    );
  }

  /// 聚合 push/pull 计数值,并在短窗口结束时统一弹一次完成 toast。
  ///
  /// 说明:同一轮同步里 push 与 pull 可能先后到达,若各自立即弹 toast 会连续
  /// 弹两条;这里把 500ms 内到达的事件累加,等安静后一次性展示
  /// `cloudSyncComplete(pushed, pulled)`(该 l10n key 各语言已就绪,符合现有
  /// 文案规范)。toast 本身自动 2s 后消失,不会占布局。
  void _scheduleSyncCompletionToast(
      {required int pushed, required int pulled}) {
    _syncToastPushed += pushed;
    _syncToastPulled += pulled;
    _syncToastTimer?.cancel();
    _syncToastTimer = Timer(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      final l10n = AppLocalizations.of(context);
      showToast(
        context,
        l10n.cloudSyncComplete(_syncToastPushed, _syncToastPulled),
      );
      _syncToastPushed = 0;
      _syncToastPulled = 0;
    });
  }

  /// 后台刷新账本同步状态
  void _refreshLedgersStatusInBackground() {
    // 启动同步走 `Future.microtask` 而**不是** `addPostFrameCallback`。
    // 历史:之前为了首屏更快试过 addPostFrameCallback,首帧渲染完才开始 sync,
    // 代价是 sync 完成后 bump 一堆 refresh ticker → home 已渲染好的内容触发
    // 二次 cascade rebuild。改回 microtask:让 sync 在首屏渲染之前就开始跑,
    // 跟首屏渲染叠加成单次"加载",没有"先显示后又刷新"的二次绘制感。
    Future.microtask(() async {
      try {
        final syncService = ref.read(syncServiceProvider);
        if (syncService is TransactionsSyncManager) {
          await syncService.refreshAllLedgersStatus();
          ref.read(ledgerListRefreshProvider.notifier).state++;
        }
      } catch (e) {
        // 静默失败,不影响 App 启动
      }
    });
  }

  /// 处理「桌面长按图标快捷项」的动作:立即执行,带 1s 防抖去重。
  /// (URL deep-link / 桌面小组件走 _persistPendingDeepLink → _drainPendingDeepLink
  ///  的「重建可恢复」路径;两条路径最终都汇到 [_openDeepLink] 统一派发。)
  void _handleAppLinkAction(AppLinkAction action) {
    // 防止重复执行（使用时间戳和标志双重检查）
    final now = DateTime.now();
    if (_isHandlingAppLink ||
        (_lastAppLinkHandleTime != null &&
            now.difference(_lastAppLinkHandleTime!) <
                const Duration(seconds: 1))) {
      logger.info('AppLink', 'PiggyApp: 忽略重复的动作 $action');
      return;
    }
    _isHandlingAppLink = true;
    _lastAppLinkHandleTime = now;

    // 延迟重置标志，允许下一次动作
    Future.delayed(const Duration(seconds: 1), () {
      _isHandlingAppLink = false;
    });

    String? type;
    int? categoryId;
    String? page;
    if (action == AppLinkAction.newTransaction) {
      type = ref.read(pendingNewTransactionTypeProvider) ?? 'expense';
      categoryId = ref.read(pendingNewTransactionCategoryIdProvider);
      ref.read(pendingNewTransactionTypeProvider.notifier).state = null;
      ref.read(pendingNewTransactionCategoryIdProvider.notifier).state = null;
    } else if (action == AppLinkAction.open) {
      page = ref.read(pendingOpenPageProvider);
      ref.read(pendingOpenPageProvider.notifier).state = null;
    }
    _openDeepLink(action, type, categoryId: categoryId, page: page);
  }

  // ——— 深链「重建可恢复」打开 ———
  // 背景:部分厂商(如 ColorOS)在浏览器→App 拉起 deep-link 时会触发主题变更
  // (onConfigurationChanged: themeChanged),导致页面树/Activity 重建;若在重建前就
  // push,路由会被丢弃,用户看到「没打开」。做法:把待打开的深链持久化(跨重建/重置
  // 存活),等 appInitState==ready 且生命周期 resumed(前台稳定)后,在最终页面树上认领
  // 打开,认领即清除并去重,确保只打开一次。
  static const String _kPendingDeepLink = 'pending_deeplink_action';
  int? _lastDrainedDeepLinkTs;
  Timer? _drainTimer;

  void _persistPendingDeepLink(
    AppLinkAction action,
    String? type, {
    int? categoryId,
    String? page,
  }) {
    SharedPreferences.getInstance().then((p) {
      p.setString(
          _kPendingDeepLink,
          jsonEncode({
            'action': action.name,
            'type': type,
            if (categoryId != null) 'categoryId': categoryId,
            if (page != null) 'page': page,
            'ts': DateTime.now().millisecondsSinceEpoch,
          }));
    }).catchError((_) {});
  }

  void _drainPendingDeepLink({String trigger = ''}) {
    if (!mounted) return;
    if (ref.read(appInitStateProvider) != AppInitState.ready) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;
    // 重建有时在 resumed 之后还会再发生一次:延迟一拍再认领,只在「存活过这段缓冲期」的
    // 最终页面树上打开。若本页在缓冲期内被销毁(重建),timer 随 dispose 取消,新页面会
    // 重新排程,自然落到稳定的页面树上。
    _drainTimer?.cancel();
    _drainTimer =
        Timer(const Duration(milliseconds: 700), () => _executeDrain(trigger));
  }

  Future<void> _executeDrain(String trigger) async {
    if (!mounted) return;
    // 必须就绪 + 前台稳定:冷启动/主题变更的重建窗口(inactive/hidden)里打开会被丢弃
    if (ref.read(appInitStateProvider) != AppInitState.ready) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed)
      return;

    SharedPreferences prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final raw = prefs.getString(_kPendingDeepLink);
    if (raw == null) return;

    Map<String, dynamic> data;
    try {
      data = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      await prefs.remove(_kPendingDeepLink);
      return;
    }
    final ts = (data['ts'] as num?)?.toInt() ?? 0;
    final ageMs = DateTime.now().millisecondsSinceEpoch - ts;
    // 过期(>20s)或时间异常 → 丢弃,避免历史深链在普通启动时误触发
    if (ageMs < 0 || ageMs > 20000) {
      await prefs.remove(_kPendingDeepLink);
      return;
    }
    // 同一条只认领一次(listener / resumed 多次触发去重)
    if (_lastDrainedDeepLinkTs == ts) return;

    AppLinkAction? action;
    final actionName = data['action'] as String?;
    for (final a in AppLinkAction.values) {
      if (a.name == actionName) {
        action = a;
        break;
      }
    }
    if (action == null) {
      await prefs.remove(_kPendingDeepLink);
      return;
    }

    // 认领成功:打标 + 清持久化,再打开(用根 Navigator,落在最终稳定的页面树上)
    _lastDrainedDeepLinkTs = ts;
    await prefs.remove(_kPendingDeepLink);
    if (!mounted) return;
    final type = data['type'] as String?;
    final categoryId = (data['categoryId'] as num?)?.toInt();
    final page = data['page'] as String?;
    logger.info('AppLink',
        'PiggyApp: drain($trigger) 打开深链 $action type=$type categoryId=$categoryId page=$page');
    _openDeepLink(action, type, categoryId: categoryId, page: page);
  }

  /// AppLink 动作的唯一派发出口:快捷项([_handleAppLinkAction])与
  /// URL deep-link / 小组件([_executeDrain])两条路径共用,避免分叉。
  ///
  /// [categoryId] 仅 [AppLinkAction.newTransaction] 使用(小组件「快速记账」
  /// 预填分类);[page] 仅 [AppLinkAction.open] 使用(小组件「净资产/预算/
  /// 最近交易」卡片点击落地页,见 [_openPageForDeepLink])。
  void _openDeepLink(
    AppLinkAction action,
    String? type, {
    int? categoryId,
    String? page,
  }) {
    final nav = Navigator.of(context, rootNavigator: true);
    switch (action) {
      case AppLinkAction.voice:
        VoiceBillingHelper.startVoiceBilling(context, ref);
        break;
      case AppLinkAction.image:
        ImageBillingHelper.pickImageForBilling(context, ref);
        break;
      case AppLinkAction.camera:
        ImageBillingHelper.openCameraForBilling(context, ref);
        break;
      case AppLinkAction.aiChat:
        nav.push(MaterialPageRoute(builder: (_) => const AIChatPage()));
        break;
      case AppLinkAction.newTransaction:
        // 小组件「快速记账」点分类格携带 categoryId 时,预填该分类(见
        // TransactionEditorPage.initialCategoryId);普通「记一笔」categoryId 为 null。
        nav.push(MaterialPageRoute(
          builder: (_) => TransactionEditorPage(
            initialKind: type ?? 'expense',
            quickAdd: true,
            initialCategoryId: categoryId,
          ),
        ));
        break;
      case AppLinkAction.open:
        _openPageForDeepLink(nav, page);
        break;
      default:
        break;
    }
  }

  /// 小组件「净资产 / 预算 / 最近交易」卡片点击 → `piggycount://open?page=` 的
  /// 落地页路由。detail(最近交易)先落统计页,后续可按需换成专门的明细列表页。
  void _openPageForDeepLink(NavigatorState nav, String? page) {
    switch (page) {
      case 'assets':
        nav.push(MaterialPageRoute(builder: (_) => const AccountsPage()));
        break;
      case 'budget':
        nav.push(MaterialPageRoute(builder: (_) => const BudgetPage()));
        break;
      case 'detail':
        // 最近交易 / 仪表盘主体 → 首页明细列表:App 没有独立的明细页,首页
        // 就是完整账单流,切回主壳首页 tab 而不是 push 页面。(此前误映射到
        // 洞察/统计页,真机反馈"点小组件进了洞察页"。)
        nav.popUntil((route) => route.isFirst);
        ref.read(bottomTabIndexProvider.notifier).state = 0;
        break;
      default:
        logger.warning('AppLink', 'open 未知 page: $page');
        break;
    }
  }

  @override
  void dispose() {
    _drainTimer?.cancel();
    _appLinkSubscription?.close();
    _snapshotSyncToastSubscription?.close();
    _syncToastTimer?.cancel();
    _backupScheduler?.dispose();
    _backupScheduler = null;
    _removeOverlay();
    _startupSyncController?.detach();
    _startupSyncController = null;
    _expandController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _onLongPressStart(LongPressStartDetails details) {
    PiggyHaptics.medium();
    _expandController.forward();
    _showOverlay();
  }

  void _onLongPressMoveUpdate(LongPressMoveUpdateDetails details) {
    _updateHoveredIndex(details.globalPosition);
  }

  void _onLongPressEnd(LongPressEndDetails details) {
    final centerActions = [
      SpeedDialAction(
        icon: Icons.camera_alt_rounded,
        label: AppLocalizations.of(context).fabActionCamera,
        onTap: () => ImageBillingHelper.openCameraForBilling(context, ref),
      ),
      SpeedDialAction(
        icon: Icons.photo_library_rounded,
        label: AppLocalizations.of(context).fabActionGallery,
        onTap: () => ImageBillingHelper.pickImageForBilling(context, ref),
      ),
      SpeedDialAction(
        icon: Icons.mic_rounded,
        label: AppLocalizations.of(context).fabActionVoice,
        onTap: () => VoiceBillingHelper.startVoiceBilling(context, ref),
      ),
    ];

    if (_hoveredIndex != null && _hoveredIndex! < centerActions.length) {
      final action = centerActions[_hoveredIndex!];
      if (action.enabled && action.onTap != null) {
        action.onTap!();
      }
    }

    _dismissOverlay();
  }

  void _dismissOverlay() {
    _hoveredIndex = null;
    _expandController.reverse();
    _removeOverlay();
  }

  void _showOverlay() {
    final RenderBox? renderBox =
        _centerButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final position = renderBox.localToGlobal(Offset.zero);
    final size = renderBox.size;

    _overlayEntry = OverlayEntry(
      builder: (context) => _SpeedDialOverlay(
        buttonPosition: position,
        buttonSize: size,
        actions: [
          SpeedDialAction(
            icon: Icons.camera_alt_rounded,
            label: AppLocalizations.of(context).fabActionCamera,
            onTap: () => ImageBillingHelper.openCameraForBilling(context, ref),
          ),
          SpeedDialAction(
            icon: Icons.photo_library_rounded,
            label: AppLocalizations.of(context).fabActionGallery,
            onTap: () => ImageBillingHelper.pickImageForBilling(context, ref),
          ),
          SpeedDialAction(
            icon: Icons.mic_rounded,
            label: AppLocalizations.of(context).fabActionVoice,
            onTap: () => VoiceBillingHelper.startVoiceBilling(context, ref),
          ),
        ],
        animation: _expandAnimation,
        hoveredIndex: _hoveredIndex,
        backgroundColor: ref.read(primaryColorProvider),
        onDismiss: _dismissOverlay,
      ),
    );

    Overlay.of(context).insert(_overlayEntry!);
  }

  void _updateHoveredIndex(Offset globalPosition) {
    final RenderBox? renderBox =
        _centerButtonKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox == null) return;

    final buttonPosition = renderBox.localToGlobal(Offset.zero);
    final buttonSize = renderBox.size;
    final buttonCenter = Offset(
      buttonPosition.dx + buttonSize.width / 2,
      buttonPosition.dy + buttonSize.height / 2,
    );

    final angles = [210.0, 270.0, 330.0];
    const distance = 85.0;
    const buttonRadius = 26.0;

    int? newHoveredIndex;
    for (int i = 0; i < 3 && i < angles.length; i++) {
      final angle = angles[i];
      final radians = angle * math.pi / 180;
      final offsetX = distance * math.cos(radians);
      final offsetY = distance * math.sin(radians);

      final actionCenter = Offset(
        buttonCenter.dx + offsetX,
        buttonCenter.dy + offsetY,
      );

      final distanceToButton = (globalPosition - actionCenter).distance;

      if (distanceToButton <= buttonRadius) {
        newHoveredIndex = i;
        break;
      }
    }

    if (newHoveredIndex != _hoveredIndex) {
      if (newHoveredIndex != null) PiggyHaptics.selection();
      setState(() {
        _hoveredIndex = newHoveredIndex;
      });
      _overlayEntry?.markNeedsBuild();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.inactive) {
      // 多任务切换时显示隐私模糊屏（仅在应用锁启用时）
      if (ref.read(appLockEnabledProvider)) {
        ref.read(showPrivacyScreenProvider.notifier).state = true;
      }
    } else if (state == AppLifecycleState.paused) {
      // 系统拖拽/侧边栏弹出时，强制关闭扇形菜单
      _dismissOverlay();
      // 记录进入后台时间
      AppLockService.recordBackgroundTime();
    } else if (state == AppLifecycleState.resumed) {
      // 移除隐私模糊屏
      ref.read(showPrivacyScreenProvider.notifier).state = false;
      // 检查是否需要锁定
      _checkAppLockOnResume();
      // 当app从后台恢复到前台时，更新小组件数据
      _updateWidget();
      // 前台稳定后认领待处理深链(冷启动/主题变更重建后,在最终页面树上打开)
      _drainPendingDeepLink(trigger: 'resumed');
    }
  }

  @override
  void didChangePlatformBrightness() {
    super.didChangePlatformBrightness();
    // 系统明暗切换时重渲小组件:图片渲染方案不会随系统主题自动重绘(原生壳
    // 只是展示一张静态 PNG),渲染时机全靠 App 侧触发。小组件明暗跟随**系统**
    // 而非 App 内主题设置(行业惯例,桌面是系统的地盘;widget_manager 渲染
    // 批次内取 PlatformDispatcher.platformBrightness),这里监听的正是系统
    // 明暗变化——App 在前台/存活时系统切换明暗,桌面组件立刻换肤,而不是
    // 等下一次记账/前台恢复才刷新。
    _updateWidget();
  }

  Future<void> _checkAppLockOnResume() async {
    final shouldLock = await AppLockService.shouldLockOnResume();
    if (shouldLock && mounted) {
      ref.read(isAppLockedProvider.notifier).state = true;
    }
  }

  Future<void> _updateWidget() async {
    try {
      final repository = ref.read(repositoryProvider);
      final ledgerId = ref.read(currentLedgerIdProvider);
      final primaryColor = ref.read(primaryColorProvider);
      final colorScheme = ref.read(incomeExpenseColorSchemeProvider);
      final baseCurrency = ref.read(baseCurrencyProvider);

      final widgetManager = WidgetManager();
      // 前台恢复路径也走本地化封装,让小组件文案跟随 App 语言(与
      // main.dart / theme_providers 等无 context 调用点一致,靠 languageProvider
      // 还原 locale,不依赖 async 后可能失效的 BuildContext)。
      await widgetManager.updateAllWidgetsLocalized(
        repository,
        ledgerId,
        primaryColor,
        explicitLocale: ref.read(languageProvider),
        colorScheme: colorScheme,
        baseCurrency: baseCurrency,
      );
      logger.info('App', 'App恢复前台，小组件数据已更新');
    } catch (e) {
      logger.warning('App', '更新小组件失败: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final idx = ref.watch(bottomTabIndexProvider);
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final avatarPath = ref.watch(avatarPathProvider).asData?.value;

    // 性能关键点：这里绝不能读取全量 MediaQuery.of —— 键盘弹出动画期间
    // viewInsets/padding 每帧变化，全量订阅会让主页 Scaffold（含 IndexedStack
    // 的四个 Tab 页与底部导航栏）逐帧整页重建。底部栏的安全区高度已下沉到
    // _PiggyBottomBar 内部的叶子组件中窄粒度订阅，键盘动画只重建那一小块。

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (bool didPop, Object? result) {
        if (didPop) return;

        final now = DateTime.now();

        if (_lastBackPressTime == null ||
            now.difference(_lastBackPressTime!) > const Duration(seconds: 2)) {
          _lastBackPressTime = now;
          showToast(context, l10n.commonPressAgainToExit);
        } else {
          SystemNavigator.pop();
        }
      },
      child: Stack(
        children: [
          Scaffold(
            extendBody: false, // 底部栏贴底固定，为内容预留空间
            body: IndexedStack(
              index: idx,
              children: _pages,
            ),
            bottomNavigationBar: _PiggyBottomBar(
              currentIndex: idx,
              primaryColor: primaryColor,
              isDark: isDark,
              l10n: l10n,
              avatarPath: avatarPath,
              centerButtonKey: _centerButtonKey,
              onTabTap: (index) {
                PiggyHaptics.selection();
                final now = DateTime.now();
                if (_lastTappedIndex == index &&
                    _lastTapTime != null &&
                    now.difference(_lastTapTime!) <
                        const Duration(milliseconds: 300)) {
                  if (index == 0) {
                    ref.read(homeScrollToTopProvider.notifier).state++;
                  }
                  _lastTapTime = null;
                  _lastTappedIndex = null;
                } else {
                  _lastTapTime = now;
                  _lastTappedIndex = index;
                  ref.read(bottomTabIndexProvider.notifier).state = index;
                }
              },
              onCenterTap: () {
                // 新建记账：底部抽屉弹出（参考 wait-home 影视新增抽屉）
                showTransactionFormBottomSheet(
                  context,
                  initialKind: 'expense',
                );
              },
              onCenterLongPressStart: _onLongPressStart,
              onCenterLongPressMoveUpdate: _onLongPressMoveUpdate,
              onCenterLongPressEnd: _onLongPressEnd,
            ),
          ),
          // 开发模式下的记账按钮（与底部菜单一致配色，仅图标）
          if (kDebugMode)
            Positioned(
              right: 16,
              bottom: 100,
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () {
                  // 与底部中间记账按钮 onCenterTap 行为一致
                  showTransactionFormBottomSheet(
                    context,
                    initialKind: 'expense',
                  );
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: PiggyTokens.tabBarBackground(context),
                    shape: BoxShape.circle,
                    boxShadow: PiggyTokens.tabBarShadow,
                  ),
                  child: Icon(
                    Icons.add_circle_outline,
                    size: 24,
                    color: primaryColor,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Telegram 风格悬浮胶囊底部导航栏
class _PiggyBottomBar extends StatelessWidget {
  final int currentIndex;
  final Color primaryColor;
  final bool isDark;
  final AppLocalizations l10n;
  final String? avatarPath;
  final GlobalKey centerButtonKey;
  final ValueChanged<int> onTabTap;
  final VoidCallback onCenterTap;
  final GestureLongPressStartCallback onCenterLongPressStart;
  final GestureLongPressMoveUpdateCallback onCenterLongPressMoveUpdate;
  final GestureLongPressEndCallback onCenterLongPressEnd;

  const _PiggyBottomBar({
    required this.currentIndex,
    required this.primaryColor,
    required this.isDark,
    required this.l10n,
    this.avatarPath,
    required this.centerButtonKey,
    required this.onTabTap,
    required this.onCenterTap,
    required this.onCenterLongPressStart,
    required this.onCenterLongPressMoveUpdate,
    required this.onCenterLongPressEnd,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = PiggyTokens.tabBarBackground(context);
    // UI-08：未选中色走 token，不再绕过主题体系
    final inactiveColor = PiggyTokens.iconSecondary(context);

    const barHeight = 56.0;

    return _PiggyBottomBarSafeAreaHeight(
      barHeight: barHeight,
      child: ClipRect(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            decoration: BoxDecoration(
              color: bgColor,
              border: Border(
                top: BorderSide(
                  color: PiggyTokens.cardInnerDividerColor(context),
                  width: 0.5,
                ),
              ),
              boxShadow: PiggyTokens.tabBarShadow,
            ),
            child: Column(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      _buildTabItem(context, 0, Icons.receipt_long_outlined,
                          Icons.receipt_long, l10n.tabHome, inactiveColor),
                      _buildTabItem(context, 1, Icons.pie_chart_outline_rounded,
                          Icons.pie_chart_rounded, l10n.tabInsights, inactiveColor),
                      // 中间记账按钮（作为 Tab 样式）
                      _buildCenterTabItem(context, inactiveColor),
                      _buildTabItem(
                          context,
                          2,
                          Icons.account_balance_wallet_outlined,
                          Icons.account_balance_wallet,
                          l10n.tabAssets,
                          inactiveColor),
                      _buildAvatarTabItem(context, 3, l10n.tabMine, inactiveColor),
                    ],
                  ),
                ),
                const _PiggyBottomBarSafeArea(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTabItem(
      BuildContext context,
      int index,
      IconData icon,
      IconData activeIcon,
      String label,
      Color inactiveColor) {
    final isActive = index == currentIndex;
    final iconColor = isActive ? primaryColor : inactiveColor;

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTabTap(index),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(isActive ? activeIcon : icon, color: iconColor, size: 22),
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  // UI-07：字号走 caption token（10），颜色/字重按激活态覆写
                  style: PiggyTextTokens.caption(context).copyWith(
                    color: isActive ? primaryColor : inactiveColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCenterTabItem(BuildContext context, Color inactiveColor) {
    return Expanded(
      child: GestureDetector(
        key: centerButtonKey,
        behavior: HitTestBehavior.opaque,
        onTap: onCenterTap,
        onLongPressStart: onCenterLongPressStart,
        onLongPressMoveUpdate: onCenterLongPressMoveUpdate,
        onLongPressEnd: onCenterLongPressEnd,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.add_circle_outline, color: inactiveColor, size: 22),
              const SizedBox(height: 1),
              Text(
                l10n.tabRecord,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                softWrap: false,
                textScaler: TextScaler.noScaling,
                // UI-07：同上
                style: PiggyTextTokens.caption(context),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarTabItem(
      BuildContext context, int index, String label, Color inactiveColor) {
    final isActive = index == currentIndex;
    final hasAvatar = avatarPath != null;

    Widget iconWidget;
    if (hasAvatar) {
      iconWidget = Container(
        width: 24,
        height: 24,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: isActive ? Border.all(color: primaryColor, width: 1.5) : null,
          image: DecorationImage(
            image: FileImage(File(avatarPath!)),
            fit: BoxFit.cover,
          ),
        ),
      );
    } else {
      iconWidget = Icon(
          isActive ? Icons.person_rounded : Icons.person_outline_rounded,
          color: isActive ? primaryColor : inactiveColor,
          size: 24);
    }

    return Expanded(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onTabTap(index),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                iconWidget,
                const SizedBox(height: 1),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  textScaler: TextScaler.noScaling,
                  // UI-07：同上
                  style: PiggyTextTokens.caption(context).copyWith(
                    color: isActive ? primaryColor : inactiveColor,
                    fontWeight: isActive ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 底部导航栏总高度（barHeight + 安全区高度）。
///
/// 独立读取 [MediaQuery.paddingOf] 以隔离 rebuild 范围：键盘弹出/收起动画期间
/// padding.bottom 每帧变化，仅此叶子组件逐帧重建，
/// 不会向上传播重建 PiggyApp / Scaffold / IndexedStack 各 Tab 页。
class _PiggyBottomBarSafeAreaHeight extends StatelessWidget {
  const _PiggyBottomBarSafeAreaHeight({required this.barHeight, required this.child});

  final double barHeight;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: barHeight + MediaQuery.paddingOf(context).bottom,
      child: child,
    );
  }
}

/// 底部导航栏内容下方的安全区占位（手势条区域）。
///
/// 同样独立读取 [MediaQuery.paddingOf]，把键盘动画期间的逐帧变化
/// 隔离在这个叶子组件内，Row 内容不受影响。
class _PiggyBottomBarSafeArea extends StatelessWidget {
  const _PiggyBottomBarSafeArea();

  @override
  Widget build(BuildContext context) {
    return SizedBox(height: MediaQuery.paddingOf(context).bottom);
  }
}

/// 扇形菜单覆盖层
class _SpeedDialOverlay extends StatelessWidget {
  final Offset buttonPosition;
  final Size buttonSize;
  final List<SpeedDialAction> actions;
  final Animation<double> animation;
  final int? hoveredIndex;
  final Color backgroundColor;
  final VoidCallback? onDismiss;

  const _SpeedDialOverlay({
    required this.buttonPosition,
    required this.buttonSize,
    required this.actions,
    required this.animation,
    required this.hoveredIndex,
    required this.backgroundColor,
    this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final buttonCenter = Offset(
      buttonPosition.dx + buttonSize.width / 2,
      buttonPosition.dy + buttonSize.height / 2,
    );

    final angles = [210.0, 270.0, 330.0];
    const distance = 85.0;

    return AnimatedBuilder(
      animation: animation,
      builder: (context, child) {
        if (animation.value == 0) {
          return const SizedBox.shrink();
        }

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                onTap: onDismiss,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.3 * animation.value),
                ),
              ),
            ),
            for (int i = 0; i < actions.length && i < angles.length; i++)
              Builder(builder: (context) {
                final angle = angles[i];
                final radians = angle * math.pi / 180;
                final progress = animation.value;
                final offsetX = progress * distance * math.cos(radians);
                final offsetY = progress * distance * math.sin(radians);

                const btnSize = 48.0;
                final left = buttonCenter.dx + offsetX - btnSize / 2;
                final top = buttonCenter.dy + offsetY - btnSize / 2;

                final isEnabled = actions[i].enabled;
                final bgColor =
                    isEnabled ? backgroundColor : Colors.grey.shade400;
                final isHovered = i == hoveredIndex;

                return Positioned(
                  left: left,
                  top: top,
                  child: Transform.scale(
                    scale: progress,
                    child: Opacity(
                      opacity: progress,
                      child: AnimatedScale(
                        scale: isHovered ? 1.2 : 1.0,
                        duration: const Duration(milliseconds: 150),
                        child: Material(
                          color: bgColor,
                          shape: const CircleBorder(),
                          elevation: isHovered ? 8 : 4,
                          child: Container(
                            width: btnSize,
                            height: btnSize,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: isHovered
                                  ? Border.all(color: Colors.white, width: 3)
                                  : null,
                            ),
                            child: Icon(
                              actions[i].icon,
                              color: Colors.white,
                              size: 24,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              }),
          ],
        );
      },
    );
  }
}

