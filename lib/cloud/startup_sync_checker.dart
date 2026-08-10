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

    // 3. 获取所有账本
    final ledgers = await deps.getAllLedgers();
    if (ledgers.isEmpty) {
      deps.log('StartupSyncChecker: 无账本，跳过');
      controller.dismiss();
      return;
    }

    // 4. 收集候选账本（cloudNewer / different），推送进度
    controller.startChecking(ledgers.length);
    final candidates = <LedgerCandidate>[];
    var checked = 0;
    for (final ledger in ledgers) {
      try {
        final status = await deps.getStatus(ledger.id);
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
              // 激活成功，重新执行整个检查流程
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
        }
        if (status.diff == SyncDiff.cloudNewer ||
            status.diff == SyncDiff.different) {
          // US-7: 携带 diffType 用于 SummaryView 冲突高亮 + applyAll 二次确认
          candidates.add(LedgerCandidate(
            ledger: ledger,
            status: status,
            diffType: status.diff,
          ));
        }
      } catch (e) {
        // 单账本 getStatus 失败不影响其他账本
        deps.log('StartupSyncChecker: 账本 ${ledger.name}（id=${ledger.id}）'
            'getStatus 失败: $e');
      }
      checked++;
      controller.updateCheckingProgress(checked, ledgers.length);
    }

    if (candidates.isEmpty) {
      deps.log('StartupSyncChecker: 无候选账本，跳过');
      controller.dismiss();
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

    controller.startApplying(candidates.length);

    var successCount = 0;
    var failCount = 0;
    var totalChanges = 0;
    var applied = 0;
    // 密钥恢复失败只弹一次提示，避免多个账本失败时连续弹窗
    var recoveryFailedNotified = false;

    for (final c in candidates) {
      controller.updateApplyingProgress(
        applied,
        candidates.length,
        c.ledger.name,
        totalChanges,
      );

      try {
        final previewResult = await deps.downloadAndPreview(c.ledger.id);
        if (previewResult == null) {
          // 云端无数据，跳过
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端无数据，跳过');
          applied++;
          continue;
        }

        if (previewResult.preview == null) {
          // 旧格式（v5 及以下）：走全量替换
          await deps.downloadAndRestoreToCurrentLedger(ledgerId: c.ledger.id);
          deps.runAfterDownload();
          successCount++;
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 全量替换完成');
          applied++;
          continue;
        }

        final preview = previewResult.preview!;
        if (preview.isEmpty) {
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} preview 为空，跳过');
          applied++;
          continue;
        }

        // 一键应用：所有变更都选中（selected 字段默认 true）
        final selected = preview.changes.where((ch) => ch.selected).toList();
        if (selected.isEmpty) {
          applied++;
          continue;
        }

        final result = await deps.applyPreviewChanges(
          ledgerId: c.ledger.id,
          selectedChanges: selected,
          importData: previewResult.importData,
        );
        totalChanges += result.totalCount;
        deps.runAfterDownload();
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
          // 恢复 overlay 继续剩余账本
          controller.startApplying(candidates.length);
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
          // 恢复 overlay 继续剩余账本
          controller.startApplying(candidates.length);
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

    if (failCount == 0) {
      controller.done('已合并 $successCount 个账本'
          '${totalChanges > 0 ? '，共 $totalChanges 条变更' : ''}');
    } else if (successCount == 0) {
      controller.error('全部 $failCount 个账本合并失败');
    } else {
      controller.done('已合并 $successCount 个账本，$failCount 个失败'
          '${totalChanges > 0 ? '，共 $totalChanges 条变更' : ''}');
    }
    return true;
  }

  /// 逐个确认：每个账本独立弹窗，用户可分项勾选
  ///
  /// 调用前 overlay 已被 dismiss，showDialog 接管交互。
  Future<void> _confirmEach(List<LedgerCandidate> candidates) async {
    for (final c in candidates) {
      try {
        final previewResult = await deps.downloadAndPreview(c.ledger.id);
        if (previewResult == null) {
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} 云端无数据，跳过');
          continue;
        }

        if (previewResult.preview == null) {
          // 旧格式：弹全量替换确认
          await _handleLegacyFormat(c.ledger);
          continue;
        }

        final preview = previewResult.preview!;
        if (preview.isEmpty) {
          deps.log('StartupSyncChecker: 账本 ${c.ledger.name} preview 为空，跳过');
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
            return;
          case LedgerDialogChoice.viewDetail:
            // 走同步预览弹窗
            final selected = await deps.showSyncPreviewDialog(preview);
            if (selected == null || selected.isEmpty) {
              continue;
            }
            final result = await deps.applyPreviewChanges(
              ledgerId: c.ledger.id,
              selectedChanges: selected,
              importData: previewResult.importData,
            );
            deps.runAfterDownload();
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
  }

  /// 旧格式（v5 及以下）的全量替换流程
  Future<void> _handleLegacyFormat(Ledger ledger) async {
    await deps.downloadAndRestoreToCurrentLedger(ledgerId: ledger.id);
    deps.runAfterDownload();
    deps.log('StartupSyncChecker: 账本 ${ledger.name} 旧格式全量替换完成');
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
  Future<SaltMismatchRecoveryResult> handleSaltMismatch() async {
    final encryptionService = _ref.read(encryptionServiceProvider);
    return await promptPasswordAndActivate(
      _context,
      _ref,
      service: encryptionService,
      syncManager: _syncManager,
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
  void log(String message) {
    logger.info('StartupSyncCheck', message);
  }
}
