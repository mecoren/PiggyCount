import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../providers.dart';
import '../../cloud/sync_service.dart';
import '../attachment_service.dart';
import '../system/budget_overspend_notifier.dart';
import '../system/logger_service.dart';

/// 数据变更后的统一后处理服务
///
/// 两类方法：
/// - `run` 系列：交易创建后使用，刷新统计 + 可选刷新标签/附件 + 同步
/// - `sync` 系列：其他数据变更后使用（分类、账户等），仅同步
class PostProcessor {
  // ============ 交易后完整处理 ============

  /// UI 层使用（WidgetRef）
  static Future<void> run(
    WidgetRef ref, {
    required int ledgerId,
    bool tags = false,
    bool attachments = false,
  }) async {
    ref.read(statsRefreshProvider.notifier).state++;
    if (tags) ref.read(tagListRefreshProvider.notifier).state++;
    if (attachments) ref.read(attachmentListRefreshProvider.notifier).state++;
    await _doSync(ref, ledgerId);
  }

  /// 后台服务使用（ProviderContainer）
  static Future<void> runC(
    ProviderContainer c, {
    required int ledgerId,
    bool tags = false,
    bool attachments = false,
  }) async {
    c.read(statsRefreshProvider.notifier).state++;
    if (tags) c.read(tagListRefreshProvider.notifier).state++;
    if (attachments) c.read(attachmentListRefreshProvider.notifier).state++;
    await _doSyncC(c, ledgerId);
  }

  /// Provider 内部使用（Ref）
  static Future<void> runR(
    Ref ref, {
    required int ledgerId,
    bool tags = false,
    bool attachments = false,
  }) async {
    ref.read(statsRefreshProvider.notifier).state++;
    if (tags) ref.read(tagListRefreshProvider.notifier).state++;
    if (attachments) ref.read(attachmentListRefreshProvider.notifier).state++;
    await _doSyncR(ref, ledgerId);
  }

  // ============ 仅同步 ============

  /// UI 层使用（WidgetRef）
  static Future<void> sync(WidgetRef ref, {required int ledgerId}) =>
      _doSync(ref, ledgerId);

  /// 后台服务使用（ProviderContainer）
  static Future<void> syncC(ProviderContainer c, {required int ledgerId}) =>
      _doSyncC(c, ledgerId);

  /// Provider 内部使用（Ref）
  static Future<void> syncR(Ref ref, {required int ledgerId}) =>
      _doSyncR(ref, ledgerId);

  // ============ 云端下载后处理（仅刷新，不触发同步） ============

  /// 云端下载后的处理：刷新统计和UI状态，但不触发同步上传
  /// UI 层使用（WidgetRef）
  static void runAfterDownload(WidgetRef ref) {
    ref.read(statsRefreshProvider.notifier).state++;
    ref.read(syncStatusRefreshProvider.notifier).state++;
    ref.read(ledgerListRefreshProvider.notifier).state++;
    ref.read(tagListRefreshProvider.notifier).state++;
    ref.read(attachmentListRefreshProvider.notifier).state++;
    // P2-1：全量下载/备份恢复（recordChanges:false 导入）不写
    // local_changes，guard 校验位不变——刷新前显式失效状态+指纹缓存，
    // 否则 getStatus 命中恢复前的旧指纹误判「本地未变」
    try {
      ref.read(syncServiceProvider).clearStatusCache();
    } catch (e) {
      logger.warning('PostProcessor', '云端下载后清理同步状态缓存失败', e);
    }
    logger.info('PostProcessor', '云端下载后刷新完成');
  }

  /// 云端下载后的处理：刷新统计和UI状态，但不触发同步上传
  /// 后台服务使用（ProviderContainer）
  static void runAfterDownloadC(ProviderContainer c) {
    c.read(statsRefreshProvider.notifier).state++;
    c.read(syncStatusRefreshProvider.notifier).state++;
    c.read(ledgerListRefreshProvider.notifier).state++;
    c.read(tagListRefreshProvider.notifier).state++;
    c.read(attachmentListRefreshProvider.notifier).state++;
    // P2-1：同 runAfterDownload——外部导入路径缓存失效
    try {
      c.read(syncServiceProvider).clearStatusCache();
    } catch (e) {
      logger.warning('PostProcessor', '云端下载后清理同步状态缓存失败', e);
    }
    logger.info('PostProcessor', '云端下载后刷新完成');
  }

  // ============ 预算超支实时推送 ============

  /// 记账后检测预算是否超支（只推 100%，同预算同周期只推一次）。
  ///
  /// 挂在三个 `_doSync*` 出口 = 覆盖全部六个记账/变更入口（`run` / `runC` /
  /// `runR` / `sync` / `syncC` / `syncR`）—— 手动编辑器保存走的是 `sync` 系列，
  /// 逐个入口插桩必漏（见 design.md §3）。
  ///
  /// 服务内部先读开关短路：关闭时只花一次偏好读，不做任何预算查询；
  /// fire-and-forget，失败只记日志（`unawaitedLog`），不阻塞记账路径。
  static void _checkBudgetOverspend(dynamic repository, int ledgerId) {
    unawaitedLog(
      BudgetOverspendNotifier(repository: repository)
          .checkAfterWrite(ledgerId: ledgerId),
      '预算超支检测',
    );
  }

  // ============ 内部同步实现 ============

  static Future<void> _doSync(WidgetRef ref, int ledgerId) async {
    _checkBudgetOverspend(ref.read(repositoryProvider), ledgerId);
    final sync = ref.read(syncServiceProvider);
    try {
      sync.markLocalChanged(ledgerId: ledgerId);
    } catch (e) {
      logger.warning('PostProcessor', '标记本地变更失败，可能影响下次同步判断', e);
    }

    ref.read(syncStatusRefreshProvider.notifier).state++;
    ref.read(ledgerListRefreshProvider.notifier).state++;

    // 其他 provider：检查 auto_sync 开关
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('auto_sync') ?? false) {
      final refresh = ref.read(syncStatusRefreshProvider.notifier);
      // 快照同步完成信号：供主壳监听弹「已同步」toast。手动上传（cloud_sync_page
      // 等）已有自己的弹窗，这里只覆盖「数据变更后自动同步」路径，避免双重提示。
      final syncDone = ref.read(snapshotSyncCompletedProvider.notifier);
      Future(() async {
        try {
          // 防抖版自动上传（2s 窗口 + pending 补跑）：连续记账时每次编辑
          // 不再各自触发一次全量快照导出+PUT，收敛为最后一次。手动上传
          // 入口不受影响（仍走直传）。
          await sync.uploadCurrentLedgerDebounced(ledgerId: ledgerId);
          refresh.state++;
          syncDone.state++;
          logger.info('PostProcessor', '后台同步完成', 'ledgerId=$ledgerId');
        } on CloudConflictException catch (e) {
          // M7：auto 路径无人值守，不能弹窗也不能盲目覆盖——静默跳过本次
          // 自动上传并刷新状态，UI 卡片会显示 cloudNewer/outOfSync，
          // 由用户在云页面手动选择「下载」或「覆盖上传」
          logger.warning('PostProcessor', '后台同步检测到云端有更新，跳过自动上传', e);
          refresh.state++;
        } catch (e) {
          logger.error('PostProcessor', '后台同步失败', e);
        }
      });
    }
  }

  static Future<void> _doSyncC(ProviderContainer c, int ledgerId) async {
    _checkBudgetOverspend(c.read(repositoryProvider), ledgerId);
    final sync = c.read(syncServiceProvider);
    try {
      sync.markLocalChanged(ledgerId: ledgerId);
    } catch (e) {
      logger.warning('PostProcessor', '标记本地变更失败，可能影响下次同步判断', e);
    }

    c.read(syncStatusRefreshProvider.notifier).state++;
    c.read(ledgerListRefreshProvider.notifier).state++;

    // 其他 provider：检查 auto_sync 开关
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('auto_sync') ?? false) {
      final refresh = c.read(syncStatusRefreshProvider.notifier);
      // 快照同步完成信号：供主壳监听弹「已同步」toast。手动上传（cloud_sync_page
      // 等）已有自己的弹窗，这里只覆盖「数据变更后自动同步」路径，避免双重提示。
      final syncDone = c.read(snapshotSyncCompletedProvider.notifier);
      Future(() async {
        try {
          await sync.uploadCurrentLedgerDebounced(ledgerId: ledgerId);
          refresh.state++;
          syncDone.state++;
          logger.info('PostProcessor', '后台同步完成', 'ledgerId=$ledgerId');
        } on CloudConflictException catch (e) {
          // M7：auto 路径无人值守，不能弹窗也不能盲目覆盖——静默跳过本次
          // 自动上传并刷新状态，UI 卡片会显示 cloudNewer/outOfSync，
          // 由用户在云页面手动选择「下载」或「覆盖上传」
          logger.warning('PostProcessor', '后台同步检测到云端有更新，跳过自动上传', e);
          refresh.state++;
        } catch (e) {
          logger.error('PostProcessor', '后台同步失败', e);
        }
      });
    }
  }

  static Future<void> _doSyncR(Ref ref, int ledgerId) async {
    _checkBudgetOverspend(ref.read(repositoryProvider), ledgerId);
    final sync = ref.read(syncServiceProvider);
    try {
      sync.markLocalChanged(ledgerId: ledgerId);
    } catch (e) {
      logger.warning('PostProcessor', '标记本地变更失败，可能影响下次同步判断', e);
    }

    ref.read(syncStatusRefreshProvider.notifier).state++;
    ref.read(ledgerListRefreshProvider.notifier).state++;

    // 其他 provider：检查 auto_sync 开关
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('auto_sync') ?? false) {
      final refresh = ref.read(syncStatusRefreshProvider.notifier);
      // 快照同步完成信号：供主壳监听弹「已同步」toast。手动上传（cloud_sync_page
      // 等）已有自己的弹窗，这里只覆盖「数据变更后自动同步」路径，避免双重提示。
      final syncDone = ref.read(snapshotSyncCompletedProvider.notifier);
      Future(() async {
        try {
          await sync.uploadCurrentLedgerDebounced(ledgerId: ledgerId);
          refresh.state++;
          syncDone.state++;
          logger.info('PostProcessor', '后台同步完成', 'ledgerId=$ledgerId');
        } on CloudConflictException catch (e) {
          // M7：auto 路径无人值守，不能弹窗也不能盲目覆盖——静默跳过本次
          // 自动上传并刷新状态，UI 卡片会显示 cloudNewer/outOfSync，
          // 由用户在云页面手动选择「下载」或「覆盖上传」
          logger.warning('PostProcessor', '后台同步检测到云端有更新，跳过自动上传', e);
          refresh.state++;
        } catch (e) {
          logger.error('PostProcessor', '后台同步失败', e);
        }
      });
    }
  }
}
