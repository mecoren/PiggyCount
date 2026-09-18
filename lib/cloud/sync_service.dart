/// 云同步服务接口和状态模型
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart'
    show CloudSyncException;

/// M7：上传覆盖冲突 —— 快照同步是整文件覆盖语义（last-writer-wins），
/// 上传前检测到「云端快照比本地新」或「方向无法判定但内容不同」时抛出，
/// 让调用方（UI）向用户确认后再以 `force: true` 重试，而不是无声覆盖
/// 另一台设备刚同步的数据。
class CloudConflictException extends CloudSyncException {
  /// 冲突方向：'cloudNewer'（云端更新，覆盖必然丢云端数据）
  /// 或 'unknown'（时间相同内容不同，无法判定谁更新）。
  final String direction;

  CloudConflictException({required this.direction})
      : super('Upload conflict: cloud snapshot is $direction');

  bool get isCloudNewer => direction == 'cloudNewer';
}

/// M7 冲突探测结果（方案C 扩展）。
///
/// [direction] 非 null 表示探测到冲突、禁止盲传；null 表示可安全上传。
/// [cloudETag] 是探测时读到的云端 ETag（后端不支持时为 null），
/// 作为乐观并发锚点传给 [CloudSyncManager.upload] 的 `ifMatchEtag`：
/// 「探测 → 写入」之间云端被其他设备先行修改时，条件写会以
/// CloudPreconditionFailedException 显式失败，而非静默覆盖。
class UploadProbe {
  final String? direction;
  final String? cloudETag;

  const UploadProbe({this.direction, this.cloudETag});

  bool get hasConflict => direction != null;
}

// ---- 同步服务接口 ----

/// 单次上传的结果（P1-4 softFail 可见化）。
///
/// [verified] = true：写后校验确认云端指纹与本次写入一致（或后端
/// 不可校验但上传成功）—— 正常成功；
/// [verified] = false：数据已 PUT 到云端但回读指纹不一致（可能被并发
/// 覆盖/网关陈旧）—— TSM 侧已记 softFail 指标、保持脏标记，UI 应以
/// 「已上传但未确认收敛」提示而非普通成功。
typedef UploadLedgerResult = ({bool verified});

abstract class SyncService {
  /// 上传当前账本快照到云端。
  ///
  /// [bypassRestoreGuard]（P0-1 修复，默认 false）：为 true 时跳过
  /// 「恢复临界区内禁止上传」守卫。仅限**恢复/合并已完成、DB 处于一致态**
  /// 的收尾回传使用（如启动检查 merge-then-publish 阶段 2）—— 该流程
  /// 整体跑在 [SyncRestoreGuard] 临界区内，但阶段 2 执行时合并事务早已
  /// 提交，上传的快照取自完整数据，不满足「半恢复态」前提；若不豁免，
  /// 所有回传都会被 TSM-P8 守卫拒掉，指纹永不收敛 → 每次启动重复弹
  /// 「云端有更新」。**用户主动上传入口绝不允许传 true**。
  Future<UploadLedgerResult> uploadCurrentLedger(
      {required int ledgerId,
      bool force = false,
      bool bypassRestoreGuard = false});

  /// 防抖版自动上传（auto_sync 后台路径专用）。
  ///
  /// 2 秒窗口内多次触发只执行最后一次；上传进行中到达的触发会在当前
  /// 轮结束后自动补跑一轮 —— 保证「最后一次数据变更必然最终上云」。
  /// 手动上传/合并回传请用 [uploadCurrentLedger]（立即语义）。
  ///
  /// 默认实现直接透传 [uploadCurrentLedger]（无窗口收敛），供尚不需要
  /// 防抖的实现兜底；快照同步实现（TransactionsSyncManager，全量
  /// 导出+PUT 代价高）重写本方法获得 2s 窗口收敛。
  Future<void> uploadCurrentLedgerDebounced(
      {required int ledgerId,
      bool force = false,
      bool bypassRestoreGuard = false}) {
    return uploadCurrentLedger(
        ledgerId: ledgerId,
        force: force,
        bypassRestoreGuard: bypassRestoreGuard);
  }

  /// 下载并导入到当前账本
  /// 返回 (inserted, deletedDup) 二元组：
  /// - inserted: 新增条数
  /// - deletedDup: 保留字段（目前始终为0）
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId});

  Future<SyncStatus> getStatus({required int ledgerId});

  /// 主动刷新云端同步状态，返回 (fingerprint, count, exportedAt)。
  ///
  /// 实现说明（F7 契约对齐）：C-01 优化后优先读取对象元数据中的指纹
  /// （上传时写入、与内容同请求原子落盘），**不一定下载全量内容**；
  /// 仅当元数据缺失指纹时才回退下载计算。因此本方法适合「刷新展示态」，
  /// 不适合作为「怀疑云端内容与元数据脱钩（CDN 陈旧副本等）」的内容级
  /// 校验手段 —— 后者请走下载恢复/对比合并入口，它们会对下载到的明文
  /// 做交叉自检。
  ///
  /// 实现可在内部根据对比结果适度更新缓存，便于 UI 立即反映状态。
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId});

  /// 当本地数据发生变更（增删改）时调用，以便使缓存状态失效
  void markLocalChanged({required int ledgerId});

  /// 删除云端备份（若存在）。应忽略 404。
  Future<void> deleteRemoteBackup({required int ledgerId});

  /// 清除指定账本的状态缓存，下次 getStatus 会重新从云端获取
  void clearStatusCache({int? ledgerId});
}

// ---- 本地存储实现（无云同步） ----

class LocalOnlySyncService implements SyncService {
  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger(
      {required int ledgerId}) async {
    throw UnsupportedError('Cloud sync not configured');
  }

  @override
  Future<UploadLedgerResult> uploadCurrentLedger(
      {required int ledgerId,
      bool force = false,
      bool bypassRestoreGuard = false}) async {
    throw UnsupportedError('Cloud sync not configured');
  }

  @override
  Future<void> uploadCurrentLedgerDebounced(
      {required int ledgerId,
      bool force = false,
      bool bypassRestoreGuard = false}) async {
    throw UnsupportedError('Cloud sync not configured');
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async {
    return const SyncStatus(
      diff: SyncDiff.notConfigured,
      localCount: 0,
      localFingerprint: '',
      message: '__SYNC_NOT_CONFIGURED__', // 特殊标记，在UI层处理本地化
    );
  }

  @override
  void markLocalChanged({required int ledgerId}) {}

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})>
      refreshCloudFingerprint({required int ledgerId}) async {
    throw UnsupportedError('Cloud sync not configured');
  }

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    throw UnsupportedError('Cloud sync not configured');
  }

  @override
  void clearStatusCache({int? ledgerId}) {}
}

// ---- 状态模型 ----

enum SyncDiff {
  notConfigured,
  notLoggedIn,
  noRemote,
  inSync,
  localNewer,
  cloudNewer,
  different,
  error,
}

class SyncStatus {
  final SyncDiff diff;
  final int localCount;
  final int? cloudCount;
  final String localFingerprint;
  final String? cloudFingerprint;
  final DateTime? cloudExportedAt;
  final String? message; // 错误或说明

  const SyncStatus({
    required this.diff,
    required this.localCount,
    required this.localFingerprint,
    this.cloudCount,
    this.cloudFingerprint,
    this.cloudExportedAt,
    this.message,
  });
}
