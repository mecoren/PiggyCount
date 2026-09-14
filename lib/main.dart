import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app.dart';
import 'services/data/account_dedup_service.dart';
import 'styles/tokens.dart';
import 'widgets/ui/toast.dart';
import 'theme.dart';
import 'providers.dart';
import 'providers/currency_providers.dart';
import 'providers/font_scale_provider.dart';
import 'providers/cloud_mode_providers.dart';
import 'providers/ui_state_providers.dart';
import 'utils/notification_factory.dart';
import 'pages/auth/splash_page.dart';
import 'pages/auth/welcome_page.dart';
import 'pages/auth/app_lock_screen.dart';
import 'providers/security_providers.dart';
import 'services/system/reminder_monitor_service.dart';
import 'providers/credit_card_reminder_providers.dart';
import 'services/attachment_service.dart' show attachmentServiceProvider;
import 'services/platform/screenshot_monitor_service.dart';
import 'services/platform/image_share_handler_service.dart';
import 'services/platform/app_link_service.dart';
import 'services/system/logger_service.dart';
import 'l10n/app_localizations.dart';
import 'widget/widget_manager.dart';
import 'package:home_widget/home_widget.dart';
import 'package:app_links/app_links.dart';
import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';


/// 全局 navigator key — 给 service 层(没有 BuildContext)push 路由使用。
final GlobalKey<NavigatorState> globalNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // 图片解码缓存上限:默认 1000 条/100MB,重度用户连翻大附件时可逼近上限
  // 仍嫌过大;配合各处 cacheWidth 降采样,收紧到 500 条/50MB 足以容纳典型
  // 工作集(缩略图 + 头像 + 图标),超出按 LRU 逐出。必须首帧解码前设置。
  PaintingBinding.instance.imageCache.maximumSize = 500;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 50 << 20; // 50MB

  // 全局异常兜底:release 下未捕获异常不再只进系统日志,统一持久化到
  // 日志中心(48h 本地),用户报障时可在「日志中心」页导出给开发者定位。
  // widget_manager 渲染窗口内的临时接管(渲染完即还原)与本钩子链式兼容:
  // 它保存 prevOnError 并在渲染结束后还原,还原回来的就是这里设置的 handler。
  FlutterError.onError = (details) {
    logger.error('Zone', 'Flutter framework error: ${details.exception}',
        details.exception, details.stack);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    logger.error('Zone', 'Uncaught platform error: $error', error, stack);
    return true; // 已记录,阻止继续向上冒泡导致进程终止
  };

  // Edge-to-edge:让 Flutter 自己把内容(PrimaryHeader/皮肤)画到状态栏底下,
  // 而不是请求系统给状态栏刷色 —— 后者在部分 OEM(华为 EMUI/鸿蒙)上会被无视,
  // 导致 header 背景无法渗透到状态栏。iOS 本来就是全屏布局,不受影响。
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);

  // 初始化日志系统（确保原生日志桥接就绪）
  logger.info('App', '应用启动，日志系统已初始化');
  logger.info('App', '📱 LoggerService 已初始化');

  // 初始化时区（必须在通知服务之前，修复iOS通知问题）
  try {
    NotificationFactory.initializeTimeZone();
  } catch (e) {
    logger.warning('App', '⚠️  时区初始化失败（可能在不支持的平台上运行）: $e');
  }

  // 配置iOS App Group（widget和主app共享数据必需）
  try {
    if (Platform.isIOS) {
      await HomeWidget.setAppGroupId('group.com.wait.piggycount');
    }
  } catch (e) {
    logger.warning('App', '⚠️  HomeWidget 插件初始化失败（可能在不支持的平台上运行）: $e');
  }

  // 初始化通知服务
  try {
    final notificationUtil = NotificationFactory.getInstance();
    await notificationUtil.initialize();
  } catch (e) {
    logger.warning('App', '⚠️  通知服务初始化失败（可能在不支持的平台上运行）: $e');
  }

  // 恢复用户的记账提醒设置（关键修复：应用重启后自动恢复提醒）
  await _restoreUserReminder();

  // 启动提醒监控服务（监听应用生命周期，自动恢复丢失的提醒）
  try {
    ReminderMonitorService().startMonitoring();
  } catch (e) {
    logger.warning('App', '⚠️  提醒监控服务启动失败（可能在不支持的平台上运行）: $e');
  }

  // 创建全局ProviderContainer（需要在周期交易生成之前创建，因为需要使用 repositoryProvider）
  // observers 必须挂在这里(根容器):无 override 的全局 provider 元素都挂载
  // 于根容器,riverpod 只通知元素所属容器的 observers;历史上挂在下面
  // ProviderScope(parent: ...) 子作用域上,didUpdateProvider 从未被回调,
  // _WidgetUpdateObserver 一直是死代码(2026-07 review 发现)——启动预热/
  // 切账本触发的小组件渲染全靠它,必须真正生效。
  final container = ProviderContainer(
    observers: [_WidgetUpdateObserver()],
  );

  // 初始化应用模式（P2-10：仅规范化历史持久值，见 _initializeAppMode）
  await _initializeAppMode(container);

  // 注意：不再在启动时生成重复交易
  // 周期交易生成已移至 appSplashInitProvider 中（等待数据库完全初始化后执行）
  // await _generatePendingRecurringTransactions(container);

  // 恢复信用卡还款提醒
  try {
    final repo = container.read(repositoryProvider);
    await CreditCardReminderService.restoreAllReminders(
      getCreditCardAccounts: () => repo.getCreditCardAccounts(),
    );
  } catch (e) {
    // 静默失败，不影响启动
  }

  // 账户去重收敛（prd/account_dedup）：合并历史遗留的按账本重复账户。
  // 必须在 runApp 前完成——后续启动同步检查的指纹计算/上传导出会并发
  // 读账户表。幂等：无重复时零写入直接返回，失败仅记日志不阻塞启动。
  try {
    final db = container.read(databaseProvider);
    await AccountDedupService.run(db);
  } catch (e, st) {
    logger.warning('AccountDedup', '账户去重收敛失败(不阻塞启动): $e\n$st');
  }

  // [已删除] v1.15.0 账户独立迁移 & v2.7.1 转账分类迁移
  // 所有活跃用户已完成，Drift onUpgrade 已覆盖相关 schema 变更
  // 硬编码 SQL 重建表会导致新增字段丢失（如 sort_order），故移除

  // 注册小组件交互回调
  try {
    await WidgetManager.registerCallback();
  } catch (e) {
    logger.warning('App', '小组件回调注册失败（可能在不支持的平台上运行）: $e');
  }

  // 恢复截图自动识别设置（Android专属），传入container
  await _restoreScreenshotMonitor(container);

  // 初始化图片分享处理服务（Android专属）
  if (Platform.isAndroid) {
    _setupImageShareHandler(container);
  }

  // 启动 URL 监听（用于快捷指令/AppLink 自动记账）
  _setupUrlListener(container);

  // 启动磁盘孤立文件 GC(attachments / attachment_thumbs / custom_icons),
  // 清理历史版本遗留的文件。周期性执行（G-ORPH：一次性标志位版本让
  // 历史轮次留下的孤儿文件永远清不掉——本轮实测 A 端就留着 4 个历史
  // 轮次的孤儿附件）。低频触发：距上次成功清理 ≥30 天才跑，标志位记录
  // 上次成功时间。后台异步执行,失败不致命。
  unawaited(_runOrphanFileGcPeriodic(container));

  // 启动后台回填附件 localSha256(v34 列,attachment_binary_sync)。
  // 分批读文件算哈希,补齐后退化为空查询;失败不致命,下次启动自愈。
  unawaited(_runAttachmentShaBackfillOnce(container));

  runApp(ProviderScope(
    parent: container,
    child: const MainApp(),
  ));
}

/// Provider observer to update widget on app start
class _WidgetUpdateObserver extends ProviderObserver {
  _WidgetUpdateObserver();
  @override
  void didUpdateProvider(
    ProviderBase provider,
    Object? previousValue,
    Object? newValue,
    ProviderContainer container,
  ) {
    // Update widget when current ledger is loaded
    if (provider == currentLedgerIdProvider && newValue != null) {
      _updateWidgetOnStart(container);
    }
  }

  /// 审计 U4：桌面小组件渲染的代际守卫。
  /// 快速连切 A→B 时两次渲染并发，慢的旧任务后完成会把 A 的数据写到
  /// 桌面。每次触发递增 generation，await 返回后落后者放弃写入。
  int _widgetRenderGeneration = 0;

  void _updateWidgetOnStart(ProviderContainer container) async {
    final myGeneration = ++_widgetRenderGeneration;
    try {
      // 先等主币种从 prefs 恢复完成再取值:本回调由 currentLedgerIdProvider
      // 首次赋值触发,与 baseCurrencyInitProvider 的异步恢复是并行的两条链,
      // 不等的话可能读到 StateProvider 的默认 'CNY',把净资产系列首轮渲成
      // 错误的 ¥ 符号,要到下一次触发才纠正(2026-07 用户实机反馈)。
      await container.read(baseCurrencyInitProvider.future);
      final repository = container.read(repositoryProvider);
      final ledgerId = container.read(currentLedgerIdProvider);
      final primaryColor = container.read(primaryColorProvider);
      final colorScheme = container.read(incomeExpenseColorSchemeProvider);
      final baseCurrency = container.read(baseCurrencyProvider);
      // 没有 BuildContext,靠 languageProvider 还原当前 App 语言(见
      // widget_manager.dart resolveWidgetLocalizations 文档)。
      final locale = container.read(languageProvider);

      if (myGeneration != _widgetRenderGeneration) {
        logger.info('App',
            '小组件渲染已有更新触发（generation=$myGeneration < $_widgetRenderGeneration），跳过过期写入');
        return;
      }

      final widgetManager = WidgetManager();
      await widgetManager.updateAllWidgetsLocalized(
        repository,
        ledgerId,
        primaryColor,
        explicitLocale: locale,
        colorScheme: colorScheme,
        baseCurrency: baseCurrency,
        // 预热:启动 / 切账本时把全部类型×尺寸的图渲染齐,这样用户随后往桌面
        // 添加任何一种小组件都立刻有图可显,不用等下一次 App 内触发渲染
        // (「添加小组件后得等一会」的修复;高频数据变化触发仍只渲已安装)。
        warmUpAllSpecs: true,
      );

      logger.info('App', '小组件数据已更新(全目录预热)');
    } catch (e) {
      logger.warning('App', '更新小组件失败（可能在不支持的平台上运行）: $e');
    }
  }
}

/// 恢复用户之前设置的记账提醒
///
/// 问题场景：
/// - 应用被系统杀死后，通知任务会丢失
/// - 应用更新后，通知任务会被清除
/// - 手机重启后，通知任务需要重新设置
///
/// 解决方案：
/// - 在应用启动时检查用户是否开启了提醒
/// - 如果开启了，重新设置通知任务
Future<void> _restoreUserReminder() async {
  try {
    logger.info('App', '🔄 检查并恢复记账提醒...');
    final prefs = await SharedPreferences.getInstance();
    final isEnabled = prefs.getBool('reminder_enabled') ?? false;

    if (isEnabled) {
      final hour = prefs.getInt('reminder_hour') ?? 21;
      final minute = prefs.getInt('reminder_minute') ?? 0;
      logger.info('App', '✅ 发现用户已启用记账提醒: ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}');
      logger.info('App', '🔔 正在重新设置提醒任务...');

      try {
        final notificationUtil = NotificationFactory.getInstance();
        await notificationUtil.scheduleDailyReminder(
          id: 1001,
          title: '记账提醒',
          body: '别忘了记录今天的收支哦 💰',
          hour: hour,
          minute: minute,
        );
        logger.info('App', '✅ 记账提醒已成功恢复');
      } catch (e) {
        logger.warning('App', '❌ 记账提醒设置失败（可能在不支持的平台上运行）: $e');
      }
    } else {
      logger.info('App', 'ℹ️  用户未启用记账提醒，跳过恢复');
    }
  } catch (e) {
    logger.warning('App', '❌ 恢复记账提醒失败: $e');
    // 不抛出异常，避免影响应用启动
  }
}

/// 恢复截图自动识别设置（仅Android）
///
/// 问题场景：
/// - 应用重启后，截图监听服务会丢失
/// - 需要自动恢复用户之前的设置
///
/// 解决方案：
/// - 在应用启动时检查用户是否开启了截图监听
/// - 如果开启了，重新启动监听服务
Future<void> _restoreScreenshotMonitor(ProviderContainer container) async {
  if (!Platform.isAndroid) return;

  try {
    logger.info('App', '📸 检查并恢复截图自动识别...');
    final screenshotMonitor = ScreenshotMonitorService(container);
    final isEnabled = await screenshotMonitor.isEnabled();

    if (isEnabled) {
      logger.info('App', '✅ 发现用户已启用截图自动识别');
      logger.info('App', '🔄 正在重新启动监听服务...');
      await screenshotMonitor.enable();
      logger.info('App', '✅ 截图监听服务已成功恢复');
    } else {
      logger.info('App', 'ℹ️  用户未启用截图自动识别，跳过恢复');
    }
  } catch (e) {
    logger.warning('App', '❌ 恢复截图监听失败: $e');
    // 不抛出异常，避免影响应用启动
  }
}

/// 初始化应用模式
///
/// P2-10（2026-09-11 简化）：AppMode 现仅剩 local 一个值（云端协同
/// 下线后的历史壳），唯一持久化语义是「把历史 `app_mode=cloud` 等旧值
/// 规范化回 local」——本函数只做读取 + 规范化 + 持久值校正，不再走
/// appModeProvider 的 StateNotifier 仪式（App 启动顺序里没有任何
/// 消费者依赖该 provider 状态，grep 核验仅本函数一处引用）。
/// [container] 参数保留以备未来模式恢复 provider 语义时使用（P2-10
/// 简化后本函数只操作 SharedPreferences，不再触碰 container）。
Future<void> _initializeAppMode(ProviderContainer container) async {
  try {
    logger.info('App', '⏳ 初始化应用模式...');

    final prefs = await SharedPreferences.getInstance();
    final modeStr = prefs.getString('app_mode');
    final mode = modeStr != null ? AppMode.fromString(modeStr) : AppMode.local;

    // 历史旧值（cloud 等）规范化回 local 并落盘；恒等值不写
    if (modeStr != mode.name) {
      await prefs.setString('app_mode', mode.name);
      logger.info('App', '应用模式旧值已规范化: $modeStr → ${mode.name}');
    }
    // provider 状态保持 local 初值即可（与 mode 恒等）

    logger.info('App', '✅ 应用模式已初始化: ${mode.label}');
  } catch (e, stackTrace) {
    logger.warning('App', '⚠️  应用模式初始化失败: $e');
    logger.error('Main', '应用模式初始化失败', e, stackTrace);
  }
}


/// 设置图片分享处理（Android专属）
///
/// 初始化 ImageShareHandlerService 以接收从相册或其他应用分享的图片
/// 分享的图片会自动触发记账流程
void _setupImageShareHandler(ProviderContainer container) {
  try {
    logger.info('App', '🖼️  [Android] 初始化图片分享处理服务...');

    // 初始化服务（会自动设置MethodChannel监听器）
    ImageShareHandlerService(container);

    logger.info('App', '✅ [Android] 图片分享处理服务已启动');
  } catch (e) {
    logger.error('App', '❌ [Android] 图片分享处理服务初始化失败', e);
    // 不抛出异常，避免影响应用启动
  }
}

/// 设置 URL 监听（用于 AppLink）
///
/// 监听 piggycount:// URL Scheme 调用
/// 支持的URL格式:
/// - piggycount://voice - 语音记账
/// - piggycount://image - 图片记账（从相册）
/// - piggycount://camera - 拍照记账
/// - piggycount://ai-chat - AI 小助手
/// - piggycount://add?amount=100&type=expense - 自动记账
/// - piggycount://auto-billing?text=... - 文本自动记账（兼容旧版）
/// - piggycount://quick-billing - 快速记账（兼容旧版）
void _setupUrlListener(ProviderContainer container) {
  try {
    logger.info('AppLink', '初始化URL监听...');

    final appLinks = AppLinks();
    final appLinkService = AppLinkService(container);

    // 设置导航回调
    appLinkService.onNavigate = (action, {params}) {
      logger.info('AppLink', '触发导航: $action');
      if (action == AppLinkAction.newTransaction && params != null) {
        container.read(pendingNewTransactionTypeProvider.notifier).state = params.type;
        container.read(pendingNewTransactionCategoryIdProvider.notifier).state =
            params.categoryId;
      }
      if (action == AppLinkAction.open && params != null) {
        container.read(pendingOpenPageProvider.notifier).state = params.page;
      }
      container.read(pendingAppLinkActionProvider.notifier).state = action;
    };

    // 用 Navigator 的 OverlayState 直接弹 toast —— deep-link 在冷启动/任意页面
    // 处理,没有就近 BuildContext;不能用 globalNavigatorKey.currentContext
    // (它在 Overlay 之上,Overlay.of 找不到祖先 Overlay)。overlay 没就绪时退
    // 回日志(用 deep-link 的多是极客,日志中心也能看到)。
    void showAppLinkToast(String message) {
      final overlay = globalNavigatorKey.currentState?.overlay;
      if (overlay != null) {
        showToastOnOverlay(overlay, message);
      } else {
        logger.warning('AppLink', 'overlay 未就绪,toast 改记日志: $message');
      }
    }

    // 自动记账成功提示("已记录 xx 元")
    appLinkService.onShowToast = showAppLinkToast;

    // 冷启动时 uriLinkStream 会在 app 还在 Splash 预加载、provider 尚未就绪时
    // 立即吐出启动 URL。此时直接 handleUrl 会因 currentLedgerProvider 还在
    // loading 而误判"无账本"静默失败(issue #162)。因此:未 ready 先暂存,等
    // appInitState 变 ready(Splash 完成、账本已恢复、navigator 已 attach)后
    // 再统一处理。
    final pendingUris = <Uri>[];

    bool isAppReady() =>
        container.read(appInitStateProvider) == AppInitState.ready;

    Future<void> dispatch(Uri uri) async {
      try {
        final result = await appLinkService.handleUrl(uri);
        // 失败/拦截(参数不全、分类不存在等)→ toast 提醒用户。具体原因
        // _handleAddTransaction 里已记 warning 日志,这里再弹一层。
        if (!result.success && result.message != null) {
          logger.warning('AppLink', '处理URL未成功: $uri -> ${result.message}');
          showAppLinkToast(result.message!);
        }
      } catch (e, st) {
        logger.error('AppLink', '处理URL异常: $uri', e, st);
      }
    }

    void flushPendingUris() {
      if (pendingUris.isEmpty) return;
      final uris = List<Uri>.from(pendingUris);
      pendingUris.clear();
      logger.info('AppLink', '应用已就绪,处理暂存的 ${uris.length} 个URL');
      for (final uri in uris) {
        dispatch(uri);
      }
    }

    // app 变 ready 时,flush 冷启动期间暂存的 URL
    container.listen<AppInitState>(appInitStateProvider, (prev, next) {
      if (next == AppInitState.ready) flushPendingUris();
    });

    // 监听URL(冷启动初始链接 + 应用在后台时的后续链接都走这里)
    appLinks.uriLinkStream.listen((uri) {
      logger.info('AppLink', '收到URL: $uri');
      if (isAppReady()) {
        dispatch(uri);
      } else {
        logger.info('AppLink', '应用未就绪,暂存冷启动URL: $uri');
        pendingUris.add(uri);
      }
    }, onError: (err) {
      logger.error('AppLink', 'URL监听错误', err);
    });

    // 注意：不使用 getInitialLink/getLatestLink，因为它们会缓存旧链接
    // 只依赖 uriLinkStream，它会在应用通过 URL 启动时立即触发

    logger.info('AppLink', 'URL监听已启动');
  } catch (e) {
    logger.error('AppLink', 'URL监听初始化失败', e);
    // 不抛出异常，避免影响应用启动
  }
}

class NoGlowScrollBehavior extends MaterialScrollBehavior {
  const NoGlowScrollBehavior();
  @override
  Widget buildOverscrollIndicator(
      BuildContext context, Widget child, ScrollableDetails details) {
    return child; // 去除 Android 上的发光效果，避免顶部出现一抹红
  }
}

/// 应用主题缓存（按 platform + primary 记忆）。
///
/// 此前 [MainApp.build] 每次执行都无条件构建 3 个完整 ThemeData
/// （lightTheme ×1 + darkTheme ×2），而 build 又因全量订阅 MediaQuery
/// 在键盘弹出动画期间每帧触发 —— 真机上键盘动画因此逐帧卡顿。
/// 主题仅取决于 (platform, primary)，此处做单条目记忆化后，
/// 键盘等高频 rebuild 不再重复支付 ThemeData 构建成本。
class _AppThemes {
  _AppThemes._(this.light, this.dark);

  final ThemeData light;
  final ThemeData dark;

  static _AppThemes? _cached;
  static TargetPlatform? _cachedPlatform;
  static Color? _cachedPrimary;

  factory _AppThemes.of(TargetPlatform platform, Color primary) {
    final cached = _cached;
    if (cached != null && _cachedPlatform == platform && _cachedPrimary == primary) {
      return cached;
    }
    final created = _AppThemes._(
      _buildLightTheme(platform, primary),
      _buildDarkTheme(platform, primary),
    );
    _cached = created;
    _cachedPlatform = platform;
    _cachedPrimary = primary;
    return created;
  }

  /// ⭐ 亮色主题
  /// 注意：scaffoldBackgroundColor / dividerColor / cardTheme.color 已在
  /// PiggyTheme.lightTheme 中通过 PiggyTokens 静态常量统一设置，这里不再覆盖。
  /// 仅覆盖动态主色（primaryColor / colorScheme.primary）等需要 Riverpod 驱动的属性。
  static ThemeData _buildLightTheme(TargetPlatform platform, Color primary) {
    final base = PiggyTheme.lightTheme(platform: platform);
    final baseTextTheme = base.textTheme;
    return base.copyWith(
      textTheme: baseTextTheme,
      colorScheme: base.colorScheme.copyWith(primary: primary),
      primaryColor: primary,
      listTileTheme: ListTileThemeData(
        dense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        iconColor: PiggyTokens.primaryTextStatic,
      ),
      dialogTheme: base.dialogTheme.copyWith(
        backgroundColor: PiggyTokens.cardBackgroundLightStatic,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
        titleTextStyle: baseTextTheme.titleMedium?.copyWith(
            color: PiggyTokens.primaryTextStatic, fontWeight: FontWeight.w600),
        contentTextStyle:
            baseTextTheme.bodyMedium?.copyWith(color: PiggyTokens.secondaryTextStatic),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          foregroundColor: primary,
          textStyle: baseTextTheme.labelLarge,
        ),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          foregroundColor: primary,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: primary,
          foregroundColor: Colors.white,
          elevation: 0,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusLg)),
        ),
      ),
      floatingActionButtonTheme: base.floatingActionButtonTheme.copyWith(
        backgroundColor: primary,
        foregroundColor: Colors.white,
      ),
      bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
        selectedItemColor: primary,
        type: BottomNavigationBarType.fixed,
      ),
      cardTheme: base.cardTheme.copyWith(
        color: PiggyTokens.cardBackgroundLightStatic,
        elevation: 0,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(PiggyDimens.radiusXl)),
        margin: EdgeInsets.zero,
      ),
      switchTheme: PiggyTheme.switchThemeData(primary, isDark: false),
    );
  }

  /// ⭐ 暗黑主题（使用动态主题色）
  ///
  /// 注意：此前 darkTheme 在同一表达式内被调用两次，这里只构建一次。
  static ThemeData _buildDarkTheme(TargetPlatform platform, Color primary) {
    final darkBase = PiggyTheme.darkTheme(platform: platform);
    return darkBase.copyWith(
      colorScheme: darkBase.colorScheme.copyWith(primary: primary),
      primaryColor: primary,
      switchTheme: PiggyTheme.switchThemeData(primary, isDark: true),
    );
  }
}

class MainApp extends ConsumerWidget {
  const MainApp({super.key});

  // 根据初始化状态和欢迎页面状态决定显示哪个页面
  Widget _getHomePage(AppInitState initState, WidgetRef ref) {
    // 首先检查是否需要显示欢迎页面
    final shouldShowWelcome = ref.watch(shouldShowWelcomeProvider);
    if (shouldShowWelcome) {
      return const WelcomePage();
    }

    // 欢迎页面完成后，根据初始化状态显示对应页面
    if (initState != AppInitState.ready) {
      return const SplashPage();
    }

    // 检查是否需要显示锁屏
    final isLocked = ref.watch(isAppLockedProvider);
    if (isLocked) {
      return const AppLockScreen();
    }

    return const PiggyApp();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 首先检查是否需要显示欢迎页面
    ref.watch(welcomeCheckProvider);

    // 检查应用初始化状态
    final initState = ref.watch(appInitStateProvider);
    final selectedLanguage = ref.watch(languageProvider);

    // 如果是启屏状态，启动初始化
    if (initState == AppInitState.splash) {
      ref.watch(appSplashInitProvider);
    }

    // 周期交易生成已统一在 appSplashInitProvider 中处理

    final primary = ref.watch(primaryColorProvider);
    final platform = Theme.of(context).platform; // 当前平台
    // 主题走记忆化缓存（见 _AppThemes）：键盘弹出等高频 rebuild 不再重复构建 ThemeData
    final themes = _AppThemes.of(platform, primary);

    // init font scale persistence
    ref.watch(fontScaleInitProvider);
    final customScale = ref.watch(effectiveFontScaleProvider);

    // Clamp 系统字体缩放，避免部分设备设置 1.5+ 造成 UI 溢出。
    //
    // 性能关键点：这里只订阅 textScaler（MediaQuery.textScalerOf），
    // 绝不能订阅全量 MediaQuery —— 键盘弹出/收起动画期间 viewInsets 每帧变化，
    // 全量订阅会导致本 widget（含整棵 MaterialApp 子树）逐帧重建，
    // 是真机键盘动画卡顿的主要 UI 线程开销之一。
    // 缩放覆盖在下方 builder 中应用；builder 位于 MaterialApp 内部，
    // 即使随 insets 每帧执行也只有一个轻量 MediaQuery 包裹层的成本。
    final clamped =
        MediaQuery.textScalerOf(context).clamp(minScaleFactor: 0.85, maxScaleFactor: 1.15);
    final combinedScale = clamped.scale(customScale); // returns double
    final newScaler = TextScaler.linear(combinedScale);
    return MaterialApp(
      navigatorKey: globalNavigatorKey,
      onGenerateTitle: (context) => AppLocalizations.of(context).appTitle,
      scrollBehavior: const NoGlowScrollBehavior(),
      debugShowCheckedModeBanner: false,
      theme: themes.light,   // ⭐ 亮色主题（缓存）
      darkTheme: themes.dark, // ⭐ 暗黑主题（使用动态主题色，缓存）
      themeMode: ref.watch(themeModeProvider),         // ⭐ 使用 provider 支持手动切换
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('en'),
        Locale('zh'),
        Locale('zh', 'TW'),
        Locale('ko'),
      ],
      locale: selectedLanguage,
      builder: (context, child) {
        final showPrivacy = ref.watch(showPrivacyScreenProvider);
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: newScaler),
          child: Stack(
            children: [
              child ?? const SizedBox.shrink(),
              if (showPrivacy)
                Positioned.fill(
                  child: BackdropFilter(
                    filter: ImageFilter.blur(sigmaX: 30, sigmaY: 30),
                    child: Container(
                      color: Colors.black.withValues(alpha: 0.3),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.lock_outline_rounded,
                        size: 64,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      // 显式命名根路由，便于路由日志与 popUntil 精确识别
      home: _getHomePage(initState, ref),
      onGenerateRoute: (settings) {
        if (settings.name == Navigator.defaultRouteName ||
            settings.name == '/') {
          return MaterialPageRoute(
              builder: (_) => _getHomePage(initState, ref),
              settings: const RouteSettings(name: '/'));
        }
        return null;
      },
    );
  }
}

/// 周期性磁盘孤立文件清理 —— 清历史版本遗留的:
///   - `attachments/*.jpg` + `attachment_thumbs/*.jpg`:历史 sync pull 删交易时
///     只删表行不清磁盘,或者用户端在某版本之前没有完整清理的附件
///   - `custom_icons/*.png`:旧版 deleteCategory 只删分类行,customIconPath 指向
///     的本地图标文件遗留
///
/// G-ORPH（双后端实测反馈）：旧实现 `orphan_file_gc_v1_done` 标志位守卫的
/// 一次性 GC，历史轮次留下的孤儿文件永远清不掉。改为低频周期任务：
/// 距上次成功清理 ≥[interval] 才执行（SharedPreferences 记录上次成功时间，
/// 旧一次性标志位视为「刚跑过」，30 天后自然重新纳入周期）。失败全部
/// try/catch 吞掉 —— 这是 nice-to-have,不应 block app 启动。
Future<void> _runOrphanFileGcPeriodic(ProviderContainer container) async {
  const flagKey = 'orphan_file_gc_v1_done';
  const lastRunKey = 'orphan_file_gc_last_run';
  const interval = Duration(days: 30);
  try {
    final prefs = await SharedPreferences.getInstance();
    // 旧版本（一次性 GC）用户：迁移为「上次运行 = 现在」，30 天后进入周期
    if (prefs.getBool(flagKey) == true && prefs.getInt(lastRunKey) == null) {
      await prefs.setInt(
          lastRunKey, DateTime.now().millisecondsSinceEpoch);
    }
    final lastRun = prefs.getInt(lastRunKey);
    if (lastRun != null &&
        DateTime.now().millisecondsSinceEpoch - lastRun <
            interval.inMilliseconds) {
      return;
    }

    final db = container.read(databaseProvider);

    // 给主线程让路,启动关键路径先跑完
    await Future.delayed(const Duration(seconds: 3));

    var attCleaned = 0;
    var thumbCleaned = 0;
    var iconCleaned = 0;

    // --- attachments / attachment_thumbs ---
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final attDir = Directory('${appDir.path}/attachments');
      if (await attDir.exists()) {
        final usedNames = <String>{
          for (final row in await db.select(db.transactionAttachments).get())
            row.fileName,
        };
        await for (final entity in attDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedNames.contains(name)) {
            try {
              await entity.delete();
              attCleaned++;
            } catch (e) {
              logger.warning('OrphanGC', 'unlink attachment failed $name: $e');
            }
          }
        }
      }

      final cacheDir = await getTemporaryDirectory();
      final thumbDir = Directory('${cacheDir.path}/attachment_thumbs');
      if (await thumbDir.exists()) {
        // 缩略图命名规则:`<basename(fileName)>_thumb.jpg`
        final usedThumbNames = <String>{
          for (final row in await db.select(db.transactionAttachments).get())
            '${p.basenameWithoutExtension(row.fileName)}_thumb.jpg',
        };
        await for (final entity in thumbDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedThumbNames.contains(name)) {
            try {
              await entity.delete();
              thumbCleaned++;
            } catch (_) {/* best effort */}
          }
        }
      }
    } catch (e, st) {
      logger.warning('OrphanGC', 'attachment scan failed: $e\n$st');
    }

    // --- custom_icons ---
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final iconDir = Directory('${appDir.path}/custom_icons');
      if (await iconDir.exists()) {
        final usedIconNames = <String>{};
        final categoryRows = await (db.select(db.categories)
              ..where((c) => c.customIconPath.isNotNull()))
            .get();
        for (final row in categoryRows) {
          final cp = row.customIconPath;
          if (cp != null && cp.trim().isNotEmpty) {
            usedIconNames.add(p.basename(cp));
          }
        }
        await for (final entity in iconDir.list()) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!usedIconNames.contains(name)) {
            try {
              await entity.delete();
              iconCleaned++;
            } catch (e) {
              logger.warning('OrphanGC', 'unlink custom icon failed $name: $e');
            }
          }
        }
      }
    } catch (e, st) {
      logger.warning('OrphanGC', 'custom_icons scan failed: $e\n$st');
    }

    // 成功才写时间戳：中途异常下次启动重试（不写 lastRunKey）
    await prefs.setInt(
        lastRunKey, DateTime.now().millisecondsSinceEpoch);
    await prefs.setBool(flagKey, true);
    logger.info(
      'OrphanGC',
      '周期清理完成 attachments=$attCleaned thumbs=$thumbCleaned icons=$iconCleaned',
    );
  } catch (e, st) {
    // 任何异常都不该影响 app 启动。下次启动还会重试(因为没写 lastRunKey)。
    logger.warning('OrphanGC', '周期清理异常(下次启动重试): $e\n$st');
  }
}

/// 启动后台回填附件 localSha256(v34 列,attachment_binary_sync)。
///
/// 让路启动关键路径(与 OrphanGC 同款 3s 延迟);内部自带分批与异常
/// 兜底,这里再包一层 try/catch 保证绝不 block runApp 之后的流程。
Future<void> _runAttachmentShaBackfillOnce(ProviderContainer container) async {
  try {
    await Future.delayed(const Duration(seconds: 3));
    await container.read(attachmentServiceProvider).backfillLocalSha256();
  } catch (e, st) {
    logger.warning('Startup', '附件 localSha256 回填异常(下次启动重试): $e\n$st');
  }
}
