// 启动时云端数据拉取检查编排器
//
// 仅适用于路径 A（S3 / WebDAV / Supabase / iCloud）。
// 路径 B（PiggyCount Cloud）保持现有 _triggerInitialCloudSync 自动同步，
// 不在本编排器范围内。
//
// 设计原则：
// - 通过 StartupSyncCheckerDeps 接口注入所有外部依赖，
//   使核心编排逻辑可在无 UI / 无网络环境下单元测试。
// - 通过 StartupSyncController 推送状态变化给 overlay widget，
//   不直接调用 showDialog，解耦 UI 渲染。
// - 错误隔离：单个账本失败不影响其他账本。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../cloud/sync_diff_service.dart';
import '../cloud/sync_service.dart';
import '../cloud/transactions_sync_manager.dart';
import '../data/db.dart';
import '../domain/encryption/encryption_service.dart';
import '../l10n/app_localizations.dart';
import '../pages/cloud/encryption_dialogs.dart';
import '../pages/cloud/sync_preview_dialog.dart' as spd;
import '../providers/database_providers.dart';
import '../providers/encryption_providers.dart';
import '../providers/sync_providers.dart';
import '../services/billing/post_processor.dart';
import '../services/data_import_service.dart';
import '../services/system/logger_service.dart';
import '../styles/tokens.dart';
import '../widgets/ui/dialog.dart';
import 'startup_sync_overlay.dart';

/// 汇总弹窗三选项
enum SummaryChoice {
  /// 一键应用全部账本
  applyAll,

  /// 逐个账本确认
  confirmEach,

  /// 暂不合并
  skip,
}

/// 逐账本弹窗用户选择
enum LedgerDialogChoice {
  /// 查看详情并应用（含全量替换确认流程）
  viewDetail,

  /// 暂不合并此账本
  skip,

  /// 跳过剩余所有账本
  skipRest,
}

/// 单个候选账本（有云端更新）
///
/// [diffType] US-7: 来自 [SyncStatus.diff]，用于 SummaryView 冲突高亮 + applyAll 二次确认。
/// - [SyncDiff.cloudNewer] / [SyncDiff.localNewer]：单向覆盖，无冲突
/// - [SyncDiff.different]：双向都有改动，applyAll 全选会覆盖本地独有改动 → 需二次确认
class LedgerCandidate {
  final Ledger ledger;
  final SyncStatus status;
  final SyncDiff diffType;

  const LedgerCandidate({
    required this.ledger,
    required this.status,
    required this.diffType,
  });
}

/// 判断错误文本是否为云端认证失败（WebDAV 401/403）特征。
///
/// 覆盖：异常类型名（CloudAuthException）、中文文案（认证失败）、
/// HTTP 状态码（401/403）与常见服务器英文文案。认证失败与网络故障
/// 的用户处置动作不同（改凭据 vs 重试），汇总提示需区分。
bool _isAuthErrorText(String? text) {
  if (text == null || text.isEmpty) return false;
  final lower = text.toLowerCase();
  return text.contains('CloudAuthException') ||
      text.contains('认证失败') ||
      lower.contains('401') ||
      lower.contains('403') ||
      lower.contains('unauthorized') ||
      lower.contains('forbidden');
}

/// downloadAndPreview 返回类型别名
typedef DownloadAndPreviewResult =
    ({SyncPreview? preview, ImportData importData, int version});

/// 启动检查编排器的外部依赖接口
///
/// 抽象出来便于单元测试用假实现注入，生产环境用 WidgetRefDeps 包装。
abstract class StartupSyncCheckerDeps {
  Future<CloudServiceConfig> getActiveConfig();

  /// syncService 是否为 TransactionsSyncManager（路径 A）
  bool get isSyncServicePathA;

  Future<List<Ledger>> getAllLedgers();

  Future<SyncStatus> getStatus(int ledgerId);

  Future<DownloadAndPreviewResult?> downloadAndPreview(int ledgerId);

  Future<SyncApplyResult> applyPreviewChanges({
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  });

  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger({
    required int ledgerId,
  });

  /// 合并后回传（merge-then-publish）：上传指定账本收敛本地/云端指纹
  ///
  /// 启动检查若只下载合并不回传，指纹永不收敛，下次启动仍会判
  /// cloudNewer 重复弹「云端有更新」，因此合并成功后必须回传该账本。
  ///
  /// [force] 透传给 uploadCurrentLedger：回传发生在用户确认合并**之后**，
  /// M7 冲突拦截若在此触发会打断收敛循环（本地刚合并完，时间戳仲裁可能
  /// 仍判 cloudNewer），实现方应传 true。
  Future<void> uploadLedger({required int ledgerId, bool force = false});

  /// 云端账本发现：列出云端 ledger_*.json 中本机没有对应账本行的文件
  ///
  /// 设计见 /prd/remote_ledger_discovery/design.md。返回 meta 列表
  /// （名称/币种/起始日/条数），空列表表示云端无新账本。
  Future<List<RemoteLedgerMeta>> discoverRemoteLedgers();

  /// 导入一个发现的云端账本（保留远端 id 创建本地账本行 + 导入数据）
  ///
  /// 返回导入条数；null 表示远端 id 已被本地占用（竞态守卫），跳过。
  Future<int?> importRemoteLedger(RemoteLedgerMeta meta);

  /// 发现云端新账本后的确认弹窗：列出名称与条数，让用户决定是否下载
  ///
  /// 返回 true 下载全部；false 跳过（不导入，继续原启动检查流程）。
  Future<bool> showNewLedgersConfirmDialog(List<RemoteLedgerMeta> metas);

  /// 逐账本弹窗：显示该账本变更汇总，让用户选择 viewDetail / skip / skipRest
  ///
  /// 仅在 confirmEach 模式下使用，overlay 已暂时关闭。
  Future<LedgerDialogChoice> showPerLedgerDialog({
    required Ledger ledger,
    required SyncPreview preview,
  });

  /// 同步预览弹窗（showSyncPreviewDialog 的可 mock 接口）
  /// 返回用户选中的变更列表，null 表示取消
  ///
  /// 仅在 confirmEach 模式下使用，overlay 已暂时关闭。
  Future<List<SyncChange>?> showSyncPreviewDialog(SyncPreview preview);

  /// US-7: applyAll 二次确认弹窗
  ///
  /// 当候选账本中存在 [SyncDiff.different]（本地与云端都有改动）时，
  /// applyAll 全选会用云端版本覆盖本地独有改动。
  /// 此方法在执行前提示用户确认，避免静默覆盖。
  ///
  /// [ledgerNames] 冲突账本名列表（仅 different 类型），用于在文案中展示。
  /// 返回 true 表示用户确认覆盖，false 表示取消（applyAll 中止，回退到 SummaryView）。
  Future<bool> showConflictConfirmDialog(List<String> ledgerNames);

  /// 审计 S14：旧格式（v5 及以下）全量替换前的确认弹窗
  ///
  /// 全量替换 = 清空账本 + 导入 + 镜像删除，是破坏性操作；
  /// 旧实现一键应用/逐个确认路径都直接执行无任何提示。
  /// [ledgerNames] 待全量替换的账本名列表。
  /// 返回 false 时调用方跳过该账本（不替换）。
  Future<bool> showLegacyReplaceConfirmDialog(List<String> ledgerNames);

  /// SaltMismatch 恢复：弹密码对话框 + 从云端重提取 salt 激活密钥
  ///
  /// 当 getStatus 返回 'salt_mismatch_need_password' 哨兵，
  /// 或 downloadAndPreview/downloadAndRestoreToCurrentLedger 抛出
  /// SaltMismatchException 时调用。
  ///
  /// 返回 [SaltMismatchRecoveryResult.activated] 表示激活成功，调用方应重试原操作；
  /// 返回 [SaltMismatchRecoveryResult.cancelled] 表示用户主动取消，调用方应跳过当前账本；
  /// 返回 [SaltMismatchRecoveryResult.failed] 表示密码错误/激活失败，
  /// 调用方应跳过当前账本，并明确告知用户同步未恢复。
  Future<SaltMismatchRecoveryResult> handleSaltMismatch();

  /// 密钥激活失败（密码错误等）时的兜底提示。
  ///
  /// 用于启动主流程：当 [handleSaltMismatch] 返回 failed 时，
  /// 确保用户在前端直接看到明确反馈（而非只在设置页可见错误）。
  void showRecoveryFailed();

  /// 应用变更后刷新 UI providers
  void runAfterDownload();

  /// confirmEach 模式下弹出错误提示（overlay 已关闭，直接用 showDialog）
  void showLegacyError(String message);

  /// confirmEach 模式下弹出信息提示
  void showLegacyInfo(String message);

  /// 全部账本均是最新时显示的成功提示文案
  String getUpToDateMessage();

  /// 日志
  void log(String message);
}

/// 启动时云端数据拉取检查编排器
///
/// 用法：
/// ```dart
/// final controller = StartupSyncController();
/// controller.attach(Overlay.of(context));
/// await StartupSyncChecker(
///   deps: WidgetRefDeps(ref, context),
///   controller: controller,
/// ).runIfNeeded();
/// controller.detach();
/// ```
class StartupSyncChecker {
  StartupSyncChecker({required this.deps, required this.controller});

  final StartupSyncCheckerDeps deps;
  final StartupSyncController controller;

  /// 启动级幂等标志：本次进程内只执行一次
  bool _done = false;

  /// 执行启动检查。若已执行过则直接返回。
  Future<void> runIfNeeded() async {
    if (_done) return;
    _done = true;

    try {
      await _runInternal();
    } catch (e, st) {
      deps.log('StartupSyncChecker 顶层异常: $e\n$st');
      controller.error('启动检查失败: $e');
    }
  }

  /// 单个账本 getStatus 的网络超时上限。
  ///
  /// P1-4：无超时守卫时，后端（尤其 S3/WebDAV）连接挂起会让启动检查
  /// 无限阻塞，overlay 卡死、用户无法进入 App。这里对网络调用加硬时限，
  /// 超时按"检查失败"处理（计入失败账本，绝不当成"已是最新"）。
  static const Duration _statusTimeout = Duration(seconds: 20);

  /// apply 阶段（下载快照 / 应用变更）的单次网络超时上限。
  ///
  /// 30s 对慢速 S3/WebDAV 上的大账本全量 JSON 下载不够用，超时会被
  /// 记为合并失败、下次启动继续弹「云端有更新」；apply 全程有阻塞
  /// overlay + 进度提示，放宽到 90s 不会造成无反馈的假死。
  static const Duration _applyTimeout = Duration(seconds: 90);

  /// 合并后回传（上传）的单次网络超时上限。
  ///
  /// uploadCurrentLedger 会先逐个上传附件对象再 PUT 账本 JSON，
  /// 慢速 S3 + 多附件场景 30s（旧值沿用 _applyTimeout）几乎必超时，
  /// 回传静默失败 → 云端指纹永不更新 → 每次启动都弹「云端有更新」
  /// 死循环。回传同样有阻塞 overlay，放宽到 5 分钟。
  static const Duration _publishTimeout = Duration(minutes: 5);

  Future<void> _runInternal({bool isRetry = false}) async {
    // 1. 检查云端配置：仅路径 A（s3/webdav/supabase/icloud）+ valid 才执行
    final config = await deps.getActiveConfig();
    if (!_isPathA(config)) {
      deps.log('StartupSyncChecker: 非路径 A 配置（${config.type}），跳过');
      controller.dismiss();
      return;
    }
    if (!config.valid) {
      deps.log('StartupSyncChecker: 配置 invalid，跳过');
      controller.dismiss();
      return;
    }

    // 2. 确认 syncService 是 TransactionsSyncManager
    if (!deps.isSyncServicePathA) {
      deps.log('StartupSyncChecker: syncService 非 TransactionsSyncManager，跳过');
      controller.dismiss();
      return;
    }

    // 2.5 立即推送阻塞态：后续全程（云端账本发现/下载导入 → 逐账本
    // getStatus）都是网络取数过程，期间用户操作会与导入/检查互相踩写。
    // 放在两个本地配置守卫之后，非路径 A 用户不会看到遮罩闪现。
    // total=0 时 _CheckingView 显示不定进度条 +「请稍候...」，
    // 到第 4 步 startChecking(n) 再切换为精确进度。
    controller.startChecking(0);

    // 3. 获取所有账本
    var ledgers = await deps.getAllLedgers();

    // 3.5 云端账本发现：其他设备新建并上传的账本（ledger_N.json 中 N
    // 不在本地账本 id 集合内）本机永远看不到，这里主动发现并导入。
    // 注意：须在 ledgers.isEmpty 判断之前执行——全新设备本地零账本时
    // 恰恰最需要从云端发现。list 失败时静默降级，不阻塞原检查流程。
    ledgers = await _discoverAndImportRemoteLedgers(ledgers);

    if (ledgers.isEmpty) {
      deps.log('StartupSyncChecker: 无账本，跳过');
      controller.dismiss();
      return;
    }

    // 4. 收集候选账本（仅 cloudNewer；different 方向未知不纳入，见收集逻辑），推送进度
    controller.startChecking(ledgers.length);
    final candidates = <LedgerCandidate>[];
    // isRetry 后仍检测到哨兵的账本名（密钥激活后仍未完全恢复）
    final retrySentinelLedgers = <String>[];
    // 指纹与云端不一致但方向未知（SyncDiff.different，源于 direction=unknown）
    // 的账本名：仅记录日志，不弹"云端有更新"，差异状态由"我的"/云同步页展示
    final unknownDiffLedgers = <String>[];
    // P1-3：getStatus 失败（网络/超时/鉴权等）的账本名。
    // 失败账本绝不能静默计入"已是最新"——否则用户看到"已全部同步"
    // 但实际云端更新根本没拉取。
    final failedLedgers = <String>[];
    // 失败中是否含认证失败（WebDAV 401/403）：处置动作与网络故障不同
    // （改凭据 vs 重试），汇总文案需区分
    var sawAuthError = false;
    var checked = 0;
    for (final ledger in ledgers) {
      try {
        final status = await deps
            .getStatus(ledger.id)
            // P1-4：网络超时守卫，避免连接挂起导致启动检查无限阻塞
            .timeout(_statusTimeout);
        // 加密哨兵是全局问题（影响所有账本），首次检测到时弹密码对话框引导用户
        // 重输密码/开启加密，激活后重新检查。isRetry 防止无限递归（用户再次输入
        // 错误密码时不再弹窗）。两类哨兵均走 handleSaltMismatch（即 promptPasswordAndActivate）：
        // - salt_mismatch_need_password：已开启加密但密钥 salt 与云端密文不匹配
        // - cloud_encrypted_locally_disabled：从未开启加密/reset 后无密钥，云端为密文（BUG-2 残留）
        if ((status.message == 'salt_mismatch_need_password' ||
                status.message == 'cloud_encrypted_locally_disabled') &&
            !isRetry) {
          deps.log('StartupSyncChecker: 账本 ${ledger.name} 加密状态异常'
              '（${status.message}），引导用户恢复密钥');
          controller.dismiss();
          await Future.delayed(Duration.zero); // 让 overlay 消失
          final result = await deps.handleSaltMismatch();
          switch (result) {
            case SaltMismatchRecoveryResult.activated:
              // 激活成功，重新挂载 overlay 并重新执行整个检查流程
              controller.reattach();
              return _runInternal(isRetry: true);
            case SaltMismatchRecoveryResult.failed:
              // 密码错误/激活失败：明确告知用户同步未恢复，
              // 避免静默退出后只能到设置页看到错误
              deps.log('StartupSyncChecker: 密钥激活失败，同步未恢复');
              controller.dismiss();
              deps.showRecoveryFailed();
              return;
            case SaltMismatchRecoveryResult.cancelled:
              // 用户主动取消：不打扰，静默退出
              controller.dismiss();
              return;
          }
        } else if ((status.message == 'salt_mismatch_need_password' ||
                status.message == 'cloud_encrypted_locally_disabled') &&
            isRetry) {
          // isRetry 分支：激活成功后重试仍检测到哨兵。
          // 说明本地密钥仍与云端部分/全部密文不匹配（可能：A 设备改密时云端
          // 部分文件重加密失败形成混合 salt；或本次激活的 salt 只匹配部分账本）。
          // 不能静默跳过——用户输入密码后应有明确反馈，否则错误只在设置页可见。
          // 这里收集账本名，循环结束后统一提示（避免多账本连续弹窗）。
          deps.log('StartupSyncChecker: 账本 ${ledger.name} 密钥激活后仍'
              '加密状态异常（${status.message}），同步未完全恢复');
          retrySentinelLedgers.add(ledger.name);
          continue;
        }
        if (status.diff == SyncDiff.error) {
          // P1-3 补强：非哨兵 error 状态（fcs manager 内部捕获网络/认证/
          // 存储异常后返回 error 而非抛出）同样计入失败账本。旧实现静默
          // 跳过，全部失败时会被误报"已是最新"，新设备密码错误场景下
          // 用户完全得不到反馈。
          failedLedgers.add(ledger.name);
          if (_isAuthErrorText(status.message)) sawAuthError = true;
          deps.log('StartupSyncChecker: 账本 ${ledger.name}（id=${ledger.id}）'
              'getStatus 返回 error: ${status.message}');
        } else if (status.diff == SyncDiff.cloudNewer) {
          // US-7: 携带 diffType 用于 SummaryView 冲突高亮 + applyAll 二次确认
          candidates.add(LedgerCandidate(
            ledger: ledger,
            status: status,
            diffType: status.diff,
          ));
        } else if (status.diff == SyncDiff.different) {
          // different 源于 direction=unknown（指纹不同但时间戳/数量相等），
          // 无法断定云端一定更新：不纳入"云端有更新"候选，避免脏数据
          // 指纹永不收敛导致每次启动误弹下载提示；用户仍可在云同步页
          // 看到该账本的差异状态并手动选择上传/下载
          unknownDiffLedgers.add(ledger.name);
          deps.log('StartupSyncChecker: 账本 ${ledger.name} 与云端指纹不一致'
              '但无法判断新旧（direction=unknown），不纳入启动下载候选');
        }
      } catch (e) {
        // 单账本 getStatus 失败不影响其他账本，但必须记录失败账本，
        // 防止全部失败时被误报为"已是最新"（P1-3）
        failedLedgers.add(ledger.name);
        if (_isAuthErrorText(e.toString())) sawAuthError = true;
        deps.log('StartupSyncChecker: 账本 ${ledger.name}（id=${ledger.id}）'
            'getStatus 失败: $e');
      }
      checked++;
      controller.updateCheckingProgress(checked, ledgers.length);
    }

    if (retrySentinelLedgers.isNotEmpty) {
      // 激活后仍有账本密钥不匹配：明确告知用户，避免错误只在设置页可见。
      deps.log('StartupSyncChecker: 激活后仍有 ${retrySentinelLedgers.length} '
          '个账本密钥不匹配（${retrySentinelLedgers.join('、')}），同步未完全恢复');
      controller.dismiss();
      deps.showRecoveryFailed();
      return;
    }

    if (candidates.isEmpty) {
      // P1-3：有账本检查失败时绝不能显示"已是最新"——网络/鉴权/超时
      // 失败与"确实无更新"是两回事，必须让用户看到明确错误提示。
      if (failedLedgers.isNotEmpty) {
        deps.log('StartupSyncChecker: ${failedLedgers.length} 个账本检查失败'
            '（${failedLedgers.join('、')}），未计入候选');
        // 认证失败与网络故障分别提示：前者重试无效，需修正云存储凭据；
        // 旧实现统一报「请检查网络」会误导用户排查方向（新设备 WebDAV
        // 密码输错被当成网络问题）
        if (sawAuthError) {
          controller.error('云端认证失败（账号或密码错误），'
              '请到「我的-云同步-云服务」检查配置后重试');
        } else {
          controller.error(
              '${failedLedgers.length} 个账本同步状态检查失败'
              '（网络或超时），请检查网络后重试');
        }
        return;
      }
      // 存在方向未知的差异账本：不能宣称"已是最新"，也不阻塞用户，
      // 静默关闭；差异状态在"我的"页按账本展示，由用户手动处理。
      if (unknownDiffLedgers.isNotEmpty) {
        deps.log('StartupSyncChecker: ${unknownDiffLedgers.length} 个账本与'
            '云端数据不一致但方向未知（${unknownDiffLedgers.join('、')}），'
            '不弹更新提示，请到云同步页面手动处理');
        controller.dismiss();
        return;
      }
      deps.log('StartupSyncChecker: 无候选账本，全部都是最新');
      // 全部最新：显示完成态提示，1.5s 后自动 dismiss
      controller.done(deps.getUpToDateMessage());
      return;
    }

    deps.log('StartupSyncChecker: 发现 ${candidates.length} 个候选账本');

    // 5. 弹汇总对话框，让用户选择模式
    // US-7: 使用循环支持 applyAll 取消后回退到 SummaryView 重新选择
    while (true) {
      final completer = Completer<SummaryChoice>();
      controller.showHasUpdates(candidates, completer);
      final choice = await completer.future;

      switch (choice) {
        case SummaryChoice.skip:
          deps.log('StartupSyncChecker: 用户选择 skip，跳过所有');
          controller.dismiss();
          return;
        case SummaryChoice.applyAll:
          // US-7: _applyAll 返回 false 表示用户取消二次确认，循环回退到 SummaryView
          final completed = await _applyAll(candidates);
          if (completed) return;
          break;
        case SummaryChoice.confirmEach:
          // confirmEach 模式：先关闭 overlay，让 showDialog 接管
          controller.dismiss();
          // 等一帧让 overlay 消失，避免 dialog 被遮罩阻挡
          await Future.delayed(Duration.zero);
          await _confirmEach(candidates);
          return;
      }
    }
  }

  /// 云端账本发现环节：list 云端 → 找本机没有的账本 → 确认弹窗 → 导入
  ///
  /// 返回导入后重新拉取的本地账本列表（未发现/跳过/失败时原样返回），
  /// 供后续逐账本检查使用（新导入的账本与云端指纹一致，应为 inSync）。
  ///
  /// 降级语义（requirements.md US-3）：list 失败（网络/权限/后端不支持）
  /// 只记日志并跳过发现，绝不阻塞原启动检查流程。
  Future<List<Ledger>> _discoverAndImportRemoteLedgers(
    List<Ledger> ledgers,
  ) async {
    // 发现阶段只做 list + 逐文件下载提取元信息，复用状态检查的网络时限
    final List<RemoteLedgerMeta> metas;
    try {
      metas = await deps.discoverRemoteLedgers().timeout(_statusTimeout);
    } catch (e) {
      deps.log('StartupSyncChecker: 云端账本发现失败（降级跳过）: $e');
      return ledgers;
    }
    if (metas.isEmpty) return ledgers;

    deps.log('StartupSyncChecker: 云端发现 ${metas.length} 个新账本'
        '（${metas.map((m) => m.name).join('、')}）');

    // 弹确认窗前先关 overlay，避免遮罩挡住 dialog（沿用 confirmEach 做法）
    controller.dismiss();
    await Future.delayed(Duration.zero);
    final confirmed = await deps.showNewLedgersConfirmDialog(metas);
    controller.reattach();

    if (!confirmed) {
      deps.log('StartupSyncChecker: 用户跳过 ${metas.length} 个云端新账本');
      return ledgers;
    }

    // 导入进度复用 ApplyingState；不进 DoneState——1.5s 自动 dismiss 与
    // 后续 startChecking 的时序竞争会误关 overlay，检查流程收尾统一提示
    controller.startApplying(metas.length);
    var applied = 0;
    var imported = 0;
    for (final meta in metas) {
      try {
        final count =
            await deps.importRemoteLedger(meta).timeout(_applyTimeout);
        if (count != null) {
          imported++;
        } else {
          deps.log('StartupSyncChecker: 云端账本 ${meta.name} id 已被占用，跳过');
        }
      } catch (e) {
        deps.log('StartupSyncChecker: 导入云端账本 ${meta.name} 失败: $e');
      }
      applied++;
      controller.updateApplyingProgress(applied, metas.length, meta.name, 0);
    }
    deps.runAfterDownload();
    deps.log('StartupSyncChecker: 云端新账本导入完成 '
        '$imported/${metas.length} 个');

    // 重新拉取：新导入的账本要参与后续逐账本检查
    return await deps.getAllLedgers();
  }

  /// 阶段 2 回传守卫（致命 S1）：预览存在「用户未勾选的云端删除」时，
  /// 本地仍保留这些已删交易；照常 merge-then-publish 会把它们随快照推回
  /// 云端并传播到所有设备。代价必须是「本轮指纹不收敛」，而非复活数据。
  @visibleForTesting
  static bool shouldSkipMergePublish({
    required bool previewExists,
    required int unselectedDeletedCount,
  }) =>
      previewExists && unselectedDeletedCount > 0;

  /// 合并后回传（merge-then-publish）：上传合并结果收敛本地/云端指纹。
  ///
  /// 只下载合并不回传时，指纹永不收敛，下次启动仍判 cloudNewer
  /// 重复弹「云端有更新」。回传失败不回滚合并、不中断剩余账本，
  /// 仅返回 false 由调用方计入汇总提示（下次启动会再次提醒，可重试）。
  Future<bool> _publishAfterMerge(int ledgerId, String ledgerName) async {
    try {
      await deps
          .uploadLedger(ledgerId: ledgerId, force: true)
          .timeout(_publishTimeout);
      deps.log('StartupSyncChecker: 账本 $ledgerName 合并后回传完成');
      return true;
    } catch (e) {
      deps.log('StartupSyncChecker: 账本 $ledgerName 合并后回传失败: $e');
      return false;
    }
  }

  /// 一键应用全部：跳过逐账本预览，串行 apply 所有候选账本
  ///
  /// US-7: 执行前扫描候选列表，若存在 [SyncDiff.different] 的账本，
  /// 弹出二次确认对话框提示"将用云端覆盖本地独有改动"。
  ///
  /// 返回值：
  /// - true：applyAll 已执行（无论成功/部分失败）
  /// - false：用户取消二次确认，调用方应回退到 SummaryView 让用户重新选择
  Future<bool> _applyAll(List<LedgerCandidate> candidates) async {
    // US-7: 扫描冲突账本（diffType == different）
    // cloudNewer / localNewer 为单向覆盖语义，无冲突，不触发确认
    final conflictLedgers = candidates
        .where((c) => c.diffType == SyncDiff.different)
        .map((c) => c.ledger.name)
        .toList();

    if (conflictLedgers.isNotEmpty) {
      deps.log('StartupSyncChecker: applyAll 检测到 ${conflictLedgers.length} '
          '个冲突账本（different），弹二次确认');
      final confirmed =
          await deps.showConflictConfirmDialog(conflictLedgers);
      if (!confirmed) {
        // 用户取消：返回 false，调用方循环回退到 SummaryView
        deps.log('StartupSyncChecker: 用户取消 applyAll 二次确认，回退到 SummaryView');
        return false;
      }
    }

    // 两阶段执行（sync_convergence_fix）：
    //
    // 阶段 1 逐账本「下载 + 合并」，只改本地；阶段 2 对所有合并成功的
    // 账本统一回传。旧实现逐账本交错「合并→回传」，但账户/分类/标签是
    // 用户全局数据：合并账本 N 会引入账本 N 快照里的新全局数据，让
    // 已回传的账本 1..N-1 云端快照过期（指纹缺新增的全局数据），
    // 下次启动又判 cloudNewer —— 12 个账本要弹 12 轮才能收敛。
    // 先全合并后统一回传，所有账本的云端快照都基于同一份最终全局数据，
    // 一轮即收敛。
    controller.startApplying(candidates.length * 2);

    var successCount = 0;
    var failCount = 0;
    var totalChanges = 0;
    var applied = 0;
    // merge-then-publish：合并成功但回传失败的账本数，汇总时追加提示
    var uploadFailCount = 0;
    // 密钥恢复失败只弹一次提示，避免多个账本失败时连续弹窗
    var recoveryFailedNotified = false;
    // 阶段 1 产出：合并成功的账本（id + name），供阶段 2 统一回传。
    // 致命 S1：skipPublish 标记该账本存在用户未勾选的云端删除，
    // 阶段 2 必须跳过回传以防已删交易随快照复活传播。
    final merged = <({LedgerCandidate cand, bool skipPublish})>[];

    // ---------- 阶段 1：逐账本下载 + 合并（只写本地） ----------
    for (final c in candidates) {
      controller.updateApplyingProgress(
        applied,
        candidates.length * 2,
        c.ledger.name,
        totalChanges,
      );

      try {
        final previewResult =
            await deps.downloadAndPreview(c.ledger.id).timeout(_applyTimeout);
        if (previewResult == null) {
          // 云端无数据，跳过
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端无数据，跳过');
          applied++;
          continue;
        }

        if (previewResult.preview == null) {
          // 旧格式（v5 及以下）：走全量替换
          // 审计 S14：全量替换 = 清空账本 + 导入 + 镜像删除，破坏性
          // 操作必须先经用户确认；拒绝则跳过该账本。
          final confirmed = await deps.showLegacyReplaceConfirmDialog(
            [c.ledger.name],
          );
          if (!confirmed) {
            deps.log('StartupSyncChecker: 账本 ${c.ledger.name} '
                '用户取消旧格式全量替换，跳过');
            applied++;
            continue;
          }
          await deps
              .downloadAndRestoreToCurrentLedger(ledgerId: c.ledger.id)
              .timeout(_applyTimeout);
          deps.runAfterDownload();
          merged.add((cand: c, skipPublish: false));
          successCount++;
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 全量替换完成');
          applied++;
          continue;
        }

        final preview = previewResult.preview!;
        if (preview.isEmpty) {
          // 交易无 diff 但指纹判定 cloudNewer → 通常是纯元数据（账户/分类/
          // 标签/预算/周期规则等）变更。用户已选「全部应用」，此处静默走
          // 一次空变更 apply 合并元数据；直接跳过会导致云端新数据永远
          // 不落库（G5）
          await deps
              .applyPreviewChanges(
                ledgerId: c.ledger.id,
                selectedChanges: const [],
                importData: previewResult.importData,
              )
              .timeout(_applyTimeout);
          deps.runAfterDownload();
          merged.add((cand: c, skipPublish: false));
          successCount++;
          applied++;
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} preview 为空，'
              '已合并元数据');
          continue;
        }

        // 一键应用：按各变更的默认选中态（SYNC-05：added/modified 默认
        // 选中，deleted 本地独有交易默认不选，避免破坏性变更静默执行）
        final selected = preview.changes.where((ch) => ch.selected).toList();
        if (selected.isEmpty) {
          applied++;
          continue;
        }

        final result = await deps
            .applyPreviewChanges(
              ledgerId: c.ledger.id,
              selectedChanges: selected,
              importData: previewResult.importData,
            )
            .timeout(_applyTimeout);
        totalChanges += result.totalCount;
        deps.runAfterDownload();
        final unselectedDeleted = preview.changes
            .where((ch) =>
                ch.type == SyncChangeType.deleted && !ch.selected)
            .length;
        merged.add((
          cand: c,
          skipPublish: StartupSyncChecker.shouldSkipMergePublish(
              previewExists: true, unselectedDeletedCount: unselectedDeleted),
        ));
        successCount++;
        applied++;
      } on SaltMismatchException {
        // 缺口 1: salt 不匹配，弹密码对话框引导用户重输密码
        controller.dismiss();
        await Future.delayed(Duration.zero); // 让 overlay 消失
        final result = await deps.handleSaltMismatch();
        failCount++;
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} salt 不匹配'
            '${_describeRecoveryResult(result)}');
        if (result == SaltMismatchRecoveryResult.activated) {
          // 恢复 overlay 继续剩余账本（进度总刻度不变）
          controller.startApplying(candidates.length * 2);
        } else if (result == SaltMismatchRecoveryResult.failed &&
            !recoveryFailedNotified) {
          // 密码错误/激活失败：明确提示用户同步未恢复（只弹一次）
          recoveryFailedNotified = true;
          deps.showRecoveryFailed();
        }
      } on CloudEncryptedLocallyDisabledException {
        // BUG-2 残留：云端为密文但本地未开启加密，同样走密钥恢复流程
        controller.dismiss();
        await Future.delayed(Duration.zero); // 让 overlay 消失
        final result = await deps.handleSaltMismatch();
        failCount++;
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端密文但本地未开启加密'
            '${_describeRecoveryResult(result)}');
        if (result == SaltMismatchRecoveryResult.activated) {
          // 恢复 overlay 继续剩余账本（进度总刻度不变）
          controller.startApplying(candidates.length * 2);
        } else if (result == SaltMismatchRecoveryResult.failed &&
            !recoveryFailedNotified) {
          // 密码错误/激活失败：明确提示用户同步未恢复（只弹一次）
          recoveryFailedNotified = true;
          deps.showRecoveryFailed();
        }
      } catch (e) {
        failCount++;
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} applyAll 失败: $e');
        // applyAll 模式下错误不弹独立 dialog，最终汇总提示
      }
    }

    // ---------- 阶段 2：统一回传所有合并成功的账本 ----------
    // 此时用户全局数据已是最终态，每个回传快照都包含同一份全局数据，
    // 指纹一轮收敛
    var publishSkippedCount = 0;
    for (final entry in merged) {
      controller.updateApplyingProgress(applied, candidates.length * 2,
          entry.cand.ledger.name, totalChanges);
      if (entry.skipPublish) {
        publishSkippedCount++;
        deps.log('StartupSyncChecker: 账本 ${entry.cand.ledger.name} 存在未应用的'
            '云端删除，本轮跳过回传以防删除复活（下次启动将再次提示）');
        applied++;
        continue;
      }
      if (!await _publishAfterMerge(
          entry.cand.ledger.id, entry.cand.ledger.name)) {
        uploadFailCount++;
      }
      applied++;
    }

    // 回传失败追加提示：合并已成功但指纹未收敛，下次启动会再次弹出更新提示
    final uploadFailHint = uploadFailCount > 0
        ? '；$uploadFailCount 个账本回传云端失败，下次启动可能再次提示'
        : '';
    final publishSkippedHint = publishSkippedCount > 0
        ? '；$publishSkippedCount 个账本存在你未勾选的云端删除，已跳过回传'
            '（这些删除本轮不会生效，如需删除请到云同步页手动处理）'
        : '';
    if (failCount == 0) {
      controller.done('已合并 $successCount 个账本'
          '${totalChanges > 0 ? '，共 $totalChanges 条变更' : ''}'
          '$uploadFailHint$publishSkippedHint');
    } else if (successCount == 0) {
      controller.error('全部 $failCount 个账本合并失败');
    } else {
      controller.done('已合并 $successCount 个账本，$failCount 个失败'
          '${totalChanges > 0 ? '，共 $totalChanges 条变更' : ''}'
          '$uploadFailHint$publishSkippedHint');
    }
    return true;
  }

  /// 逐个确认：每个账本独立弹窗，用户可分项勾选
  ///
  /// 调用前 overlay 已被 dismiss，showDialog 接管交互。
  ///
  /// 两阶段（sync_convergence_fix）：与 _applyAll 相同，先逐账本合并，
  /// 全部处理完后统一回传 —— 账户/分类/标签是用户全局数据，交错回传
  /// 会让先回传的账本快照被后续合并引入的全局数据失效。
  Future<void> _confirmEach(List<LedgerCandidate> candidates) async {
    // 阶段 1 产出：合并成功的账本（用户点查看详情并应用 / 空变更元数据
    // 合并 / 旧格式全量替换）。
    // 致命 S1：与 _applyAll 同款守卫 —— 用户在预览弹窗未勾选的云端删除
    // 会把已删交易留在本地，若照常回传，它们将随快照复活并传播到所有
    // 设备。skipPublish 标记该账本轮次必须跳过回传。
    final merged = <({LedgerCandidate cand, bool skipPublish})>[];
    for (final c in candidates) {
      try {
        final previewResult =
            await deps.downloadAndPreview(c.ledger.id).timeout(_applyTimeout);
        if (previewResult == null) {
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端无数据，跳过');
          continue;
        }

        if (previewResult.preview == null) {
          // 旧格式：弹全量替换确认
          final ok = await _handleLegacyFormat(c.ledger);
          if (ok) merged.add((cand: c, skipPublish: false));
          continue;
        }

        final preview = previewResult.preview!;
        if (preview.isEmpty) {
          // 同 _applyAll：纯元数据变更静默合并，不弹空列表对话框（G5'）。
          // 元数据 upsert 无破坏性，与 cloud_sync_page 手动下载策略一致
          await deps
              .applyPreviewChanges(
                ledgerId: c.ledger.id,
                selectedChanges: const [],
                importData: previewResult.importData,
              )
              .timeout(_applyTimeout);
          deps.runAfterDownload();
          merged.add((cand: c, skipPublish: false));
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} preview 为空，'
              '已合并元数据');
          continue;
        }

        // 弹逐账本汇总对话框
        final choice = await deps.showPerLedgerDialog(
          ledger: c.ledger,
          preview: preview,
        );
        switch (choice) {
          case LedgerDialogChoice.skip:
            continue;
          case LedgerDialogChoice.skipRest:
            // 用户跳过剩余：已合并的账本仍需回传收敛指纹后再退出
            await _publishMerged(merged);
            return;
          case LedgerDialogChoice.viewDetail:
            // 走同步预览弹窗（showSyncPreviewDialog 原地修改 change.selected，
            // 返回值为同一批实例的过滤列表 —— 弹窗关闭后 preview.changes 的
            // selected 标志即用户最终选择）
            final selected = await deps.showSyncPreviewDialog(preview);
            if (selected == null || selected.isEmpty) {
              continue;
            }
            final result = await deps
                .applyPreviewChanges(
                  ledgerId: c.ledger.id,
                  selectedChanges: selected,
                  importData: previewResult.importData,
                )
                .timeout(_applyTimeout);
            deps.runAfterDownload();
            // S1 守卫：统计用户未勾选的云端删除（对齐 _applyAll）
            final unselectedDeleted = preview.changes
                .where((ch) =>
                    ch.type == SyncChangeType.deleted && !ch.selected)
                .length;
            merged.add((
              cand: c,
              skipPublish: StartupSyncChecker.shouldSkipMergePublish(
                  previewExists: true,
                  unselectedDeletedCount: unselectedDeleted),
            ));
            deps.showLegacyInfo(
                '账本「${c.ledger.name}」已应用 ${result.totalCount} 条变更');
            break;
        }
      } on SaltMismatchException {
        // 缺口 1: salt 不匹配，弹密码对话框引导用户重输密码
        // confirmEach 模式下 overlay 已关闭，直接弹 dialog
        final result = await deps.handleSaltMismatch();
        switch (result) {
          case SaltMismatchRecoveryResult.activated:
            deps.showLegacyInfo('账本「${c.ledger.name}」密钥已激活，请重新检查同步');
            break;
          case SaltMismatchRecoveryResult.failed:
            // 密码错误/激活失败：明确提示用户同步未恢复
            deps.showRecoveryFailed();
            break;
          case SaltMismatchRecoveryResult.cancelled:
            deps.showLegacyError(
                _formatErrorMessage(c.ledger.name, 'salt 不匹配（用户取消）'));
            break;
        }
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} salt 不匹配'
            '${_describeRecoveryResult(result)}');
      } on CloudEncryptedLocallyDisabledException {
        // BUG-2 残留：云端为密文但本地未开启加密，同样走密钥恢复流程
        final result = await deps.handleSaltMismatch();
        switch (result) {
          case SaltMismatchRecoveryResult.activated:
            deps.showLegacyInfo('账本「${c.ledger.name}」密钥已激活，请重新检查同步');
            break;
          case SaltMismatchRecoveryResult.failed:
            // 密码错误/激活失败：明确提示用户同步未恢复
            deps.showRecoveryFailed();
            break;
          case SaltMismatchRecoveryResult.cancelled:
            deps.showLegacyError(_formatErrorMessage(
                c.ledger.name, '云端已加密但本设备未开启加密（用户取消）'));
            break;
        }
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端密文但本地未开启加密'
            '${_describeRecoveryResult(result)}');
      } catch (e) {
        deps.showLegacyError(_formatErrorMessage(c.ledger.name, e));
        deps.log('StartupSyncChecker: 账本 ${c.ledger.name} confirmEach 失败: $e');
      }
    }
    // ---------- 阶段 2：统一回传 ----------
    await _publishMerged(merged);
  }

  /// 批量回传合并成功的账本（confirmEach 阶段 2）
  ///
  /// 回传失败不中断剩余账本，仅记日志（下次启动会再次提示，可重试）。
  /// S1 守卫：存在用户未勾选的云端删除时跳过回传，防止已删交易随快照
  /// 复活传播（与 _applyAll 阶段 2 同语义）。
  Future<void> _publishMerged(
      List<({LedgerCandidate cand, bool skipPublish})> merged) async {
    for (final entry in merged) {
      if (entry.skipPublish) {
        deps.log('StartupSyncChecker: 账本 ${entry.cand.ledger.name} 存在未应用'
            '的云端删除，本轮跳过回传以防删除复活（下次启动将再次提示）');
        continue;
      }
      await _publishAfterMerge(
          entry.cand.ledger.id, entry.cand.ledger.name);
    }
  }

  /// 旧格式（v5 及以下）的全量替换流程（只合并，回传由调用方统一执行）
  Future<bool> _handleLegacyFormat(Ledger ledger) async {
    // 审计 S14：全量替换前确认（旧注释声称有弹窗但实现里从来没有）
    final confirmed =
        await deps.showLegacyReplaceConfirmDialog([ledger.name]);
    if (!confirmed) {
      deps.log('StartupSyncChecker: 账本 ${ledger.name} '
          '用户取消旧格式全量替换，跳过');
      return false;
    }
    try {
      await deps
          .downloadAndRestoreToCurrentLedger(ledgerId: ledger.id)
          .timeout(_applyTimeout);
      deps.runAfterDownload();
      deps.log('StartupSyncChecker: 账本 ${ledger.name} 旧格式全量替换完成');
      return true;
    } catch (e) {
      deps.log('StartupSyncChecker: 账本 ${ledger.name} 旧格式全量替换失败: $e');
      return false;
    }
  }

  /// 判断配置是否为路径 A
  bool _isPathA(CloudServiceConfig config) {
    switch (config.type) {
      case CloudBackendType.s3:
      case CloudBackendType.webdav:
      case CloudBackendType.supabase:
      case CloudBackendType.icloud:
        return true;
      case CloudBackendType.local:
      case CloudBackendType.piggycountCloud:
        return false;
    }
  }

  /// 格式化错误消息
  String _formatErrorMessage(String ledgerName, Object error) {
    return '账本「$ledgerName」处理失败：$error';
  }

  /// 密钥恢复结果的可读描述（用于日志）
  String _describeRecoveryResult(SaltMismatchRecoveryResult r) {
    switch (r) {
      case SaltMismatchRecoveryResult.activated:
        return '（已激活，请重新检查）';
      case SaltMismatchRecoveryResult.failed:
        return '（激活失败）';
      case SaltMismatchRecoveryResult.cancelled:
        return '（用户取消）';
    }
  }
}

/// StartupSyncCheckerDeps 上用于 confirmEach 流程的扩展方法
///
/// confirmEach 模式下 overlay 已关闭，需要直接用 showDialog 弹窗，
/// 这两个方法封装了 showDialog 调用，避免污染核心接口。
/// 已废弃：直接放到 StartupSyncCheckerDeps 接口里。

/// 生产环境依赖：包装 WidgetRef + 现有 UI 组件
class WidgetRefDeps implements StartupSyncCheckerDeps {
  WidgetRefDeps(this._ref, this._syncManager, this._context);

  final WidgetRef _ref;
  final TransactionsSyncManager _syncManager;
  final BuildContext _context;

  @override
  Future<CloudServiceConfig> getActiveConfig() async {
    return await _ref.read(activeCloudConfigProvider.future);
  }

  @override
  bool get isSyncServicePathA => true; // 调用方已确认是 TransactionsSyncManager

  @override
  Future<List<Ledger>> getAllLedgers() async {
    return _ref.read(repositoryProvider).getAllLedgers();
  }

  @override
  Future<SyncStatus> getStatus(int ledgerId) =>
      _syncManager.getStatus(ledgerId: ledgerId);

  @override
  Future<DownloadAndPreviewResult?> downloadAndPreview(int ledgerId) =>
      _syncManager.downloadAndPreview(ledgerId: ledgerId);

  @override
  Future<SyncApplyResult> applyPreviewChanges({
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) =>
      _syncManager.applyPreviewChanges(
        ledgerId: ledgerId,
        selectedChanges: selectedChanges,
        importData: importData,
      );

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger({
    required int ledgerId,
  }) =>
      _syncManager.downloadAndRestoreToCurrentLedger(ledgerId: ledgerId);

  @override
  Future<void> uploadLedger({required int ledgerId, bool force = false}) =>
      _syncManager.uploadCurrentLedger(ledgerId: ledgerId, force: force);

  @override
  Future<List<RemoteLedgerMeta>> discoverRemoteLedgers() =>
      _syncManager.discoverRemoteLedgers();

  @override
  Future<int?> importRemoteLedger(RemoteLedgerMeta meta) =>
      _syncManager.importRemoteLedger(meta);

  @override
  Future<bool> showNewLedgersConfirmDialog(
      List<RemoteLedgerMeta> metas) async {
    final l10n = AppLocalizations.of(_context);
    // 展示"名称(条数)"，让用户在下载前了解各账本规模
    final displayNames =
        metas.map((m) => '${m.name}(${m.txCount})').join('、');
    final result = await AppDialog.confirm<bool>(
      _context,
      title: l10n.startupSyncNewLedgersTitle,
      message: l10n.startupSyncNewLedgersMessage(metas.length, displayNames),
      okLabel: l10n.startupSyncNewLedgersOk,
      cancelLabel: l10n.startupSyncNewLedgersCancel,
    );
    return result ?? false;
  }

  @override
  Future<LedgerDialogChoice> showPerLedgerDialog({
    required Ledger ledger,
    required SyncPreview preview,
  }) async {
    final l10n = AppLocalizations.of(_context);
    final message = l10n.startupSyncCheckLedgerMessage(
      ledger.name,
      preview.addedCount,
      preview.modifiedCount,
      preview.deletedCount,
    );

    // 三按钮：跳过剩余 / 暂不合并 / 查看详情并应用
    return await showDialog<LedgerDialogChoice>(
          context: _context,
          barrierDismissible: false,
          builder: (ctx) => AlertDialog(
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            ),
            backgroundColor: PiggyTokens.surfaceElevated(ctx),
            title: Text(l10n.startupSyncCheckTitle),
            content: Text(message),
            actions: [
              OutlinedButton(
                onPressed: () =>
                    Navigator.pop(ctx, LedgerDialogChoice.skipRest),
                child: Text(l10n.startupSyncCheckSkipRest),
              ),
              OutlinedButton(
                onPressed: () => Navigator.pop(ctx, LedgerDialogChoice.skip),
                child: Text(l10n.startupSyncCheckSkip),
              ),
              FilledButton(
                onPressed: () =>
                    Navigator.pop(ctx, LedgerDialogChoice.viewDetail),
                child: Text(l10n.startupSyncCheckViewDetail),
              ),
            ],
          ),
        ) ??
        LedgerDialogChoice.skip;
  }

  @override
  Future<List<SyncChange>?> showSyncPreviewDialog(SyncPreview preview) {
    return spd.showSyncPreviewDialog(
      _context,
      preview: preview,
      primaryColor: Theme.of(_context).colorScheme.primary,
    );
  }

  @override
  Future<bool> showConflictConfirmDialog(List<String> ledgerNames) async {
    final l10n = AppLocalizations.of(_context);
    // 文案：仅显示前 3 个账本名 + "等 N 个"，避免大量账本时文案过长
    final displayNames = ledgerNames.length > 3
        ? '${ledgerNames.sublist(0, 3).join('、')} '
            '${l10n.startupSyncConflictAndMore(ledgerNames.length - 3)}'
        : ledgerNames.join('、');
    final message = l10n.startupSyncConflictConfirmMessage(
      ledgerNames.length,
      displayNames,
    );
    final result = await AppDialog.confirm<bool>(
      _context,
      title: l10n.startupSyncConflictConfirmTitle,
      message: message,
      okLabel: l10n.startupSyncConflictConfirmOk,
      cancelLabel: l10n.startupSyncConflictConfirmCancel,
    );
    return result ?? false;
  }

  @override
  Future<bool> showLegacyReplaceConfirmDialog(List<String> ledgerNames) async {
    final l10n = AppLocalizations.of(_context);
    // 审计 S14：复用手动下载页的旧格式全量替换文案（口径一致）
    final result = await AppDialog.confirm<bool>(
      _context,
      title: l10n.syncPreviewOldFormat,
      message: l10n.syncPreviewOldFormatMessage,
    );
    return result ?? false;
  }

  @override
  Future<SaltMismatchRecoveryResult> handleSaltMismatch() async {
    final encryptionService = _ref.read(encryptionServiceProvider);
    // 注意：不传本类捕获的 _syncManager —— promptPasswordAndActivate 内部
    // 会从 provider 重新解析最新实例，避免用户中途改 WebDAV 凭据后
    // 仍用旧密码探测（陈旧管理器历史 bug）
    return await promptPasswordAndActivate(
      _context,
      _ref,
      service: encryptionService,
    );
  }

  @override
  void showRecoveryFailed() {
    final l10n = AppLocalizations.of(_context);
    AppDialog.error<void>(
      _context,
      title: l10n.saltMismatchDialogTitle,
      message: l10n.startupSyncRecoveryFailedHint,
    );
  }

  @override
  void runAfterDownload() {
    PostProcessor.runAfterDownload(_ref);
  }

  @override
  void showLegacyError(String message) {
    final l10n = AppLocalizations.of(_context);
    AppDialog.error<void>(
      _context,
      title: l10n.startupSyncCheckTitle,
      message: message,
    );
  }

  @override
  void showLegacyInfo(String message) {
    final l10n = AppLocalizations.of(_context);
    AppDialog.info<void>(
      _context,
      title: l10n.startupSyncCheckTitle,
      message: message,
    );
  }

  @override
  String getUpToDateMessage() =>
      AppLocalizations.of(_context).startupSyncCheckUpToDate;

  @override
  void log(String message) {
    logger.info('StartupSyncCheck', message);
  }
}
