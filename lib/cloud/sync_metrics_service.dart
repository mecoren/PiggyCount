import 'dart:async';

import 'package:drift/drift.dart' as drift;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs;

import '../data/db.dart';
import 'sync_service.dart' show CloudConflictException;
import '../services/system/logger_service.dart';

/// 同步操作场景（审计 P0-1 核心场景口径，即 99.9% 的分母）。
enum SyncOpScenario {
  /// 快照上传（含附件对象上传；手动/防抖自动/合并回传三触发源）
  snapshotUpload,

  /// 快照恢复（downloadAndRestoreToCurrentLedger / downloadRemoteLedger /
  /// 全量恢复的逐账本单元）
  snapshotRestore,

  /// 启动检查整体一轮（发现/导入/状态/合并/回传全链）
  startupCheck,

  /// 附件后台补齐（drainAttachmentJobs 的单任务单元）
  attachmentFill,

  /// 云端备份（createBackup / restoreBackup）
  cloudBackup,

  /// 云端账本发现（discoverRemoteLedgers 整轮）
  remoteDiscovery;

  String get label {
    switch (this) {
      case SyncOpScenario.snapshotUpload:
        return 'snapshot_upload';
      case SyncOpScenario.snapshotRestore:
        return 'snapshot_restore';
      case SyncOpScenario.startupCheck:
        return 'startup_check';
      case SyncOpScenario.attachmentFill:
        return 'attachment_fill';
      case SyncOpScenario.cloudBackup:
        return 'cloud_backup';
      case SyncOpScenario.remoteDiscovery:
        return 'remote_discovery';
    }
  }
}

/// 操作结果四态。
///
/// [conflict] 不计入成功率分母 —— 412/M7 拦截是并发保护正确工作的证据
/// 而非失败；把它算失败会把「双设备正常并发使用」误报为同步质量问题。
enum SyncOpOutcome {
  success,
  failed,

  /// 审计 P1-3：操作报成功但数据未收敛（verified=false / objectMissing /
  /// 指纹交叉自检不一致 / 备份恢复单账本失败）。这是 99.9% 与 99% 之间
  /// 的差距主体，必须与 failed 分开可查。
  softFail,

  /// 并发保护触发（CloudPreconditionFailedException / CloudConflictException）
  conflict;

  String get label {
    switch (this) {
      case SyncOpOutcome.success:
        return 'success';
      case SyncOpOutcome.failed:
        return 'failed';
      case SyncOpOutcome.softFail:
        return 'soft_fail';
      case SyncOpOutcome.conflict:
        return 'conflict';
    }
  }
}

/// 错误类别（用于 Top 失败归因，非排他枚举——按优先级归类）。
enum SyncErrorClass {
  networkTimeout,
  auth,
  /// 未配置：本地还没填云端凭据、或该能力在当前平台/构建不支持。
  /// 与 [auth] 分开的理由见 [SyncMetricsService.classifyError]。
  notConfigured,
  gateway,
  precondition,
  dataCorruption,
  unknown;

  String get label {
    switch (this) {
      case SyncErrorClass.networkTimeout:
        return 'network_timeout';
      case SyncErrorClass.auth:
        return 'auth';
      case SyncErrorClass.notConfigured:
        return 'not_configured';
      case SyncErrorClass.gateway:
        return 'gateway';
      case SyncErrorClass.precondition:
        return 'precondition';
      case SyncErrorClass.dataCorruption:
        return 'data_corruption';
      case SyncErrorClass.unknown:
        return 'unknown';
    }
  }
}

/// 单条指标记录（调用方构造后交 [SyncMetricsService.record]）。
class SyncOpRecord {
  final String backend;
  final SyncOpScenario scenario;
  final SyncOpOutcome outcome;
  final SyncErrorClass? errorClass;
  final int? ledgerId;
  final int attempts;
  final Duration? duration;

  const SyncOpRecord({
    required this.backend,
    required this.scenario,
    required this.outcome,
    this.errorClass,
    this.ledgerId,
    this.attempts = 1,
    this.duration,
  });
}

/// 窗口聚合结果（健康卡展示用）。
class SyncHealthSummary {
  final int success;
  final int failed;
  final int softFail;
  final int conflict;

  const SyncHealthSummary({
    this.success = 0,
    this.failed = 0,
    this.softFail = 0,
    this.conflict = 0,
  });

  /// 核心口径：success / (success + failed + softFail)，conflict 不入分母。
  /// 分母为 0（窗口内无记录）时返回 null —— UI 显示「暂无数据」而非 0%。
  double? get successRate {
    final denom = success + failed + softFail;
    if (denom == 0) return null;
    return success / denom;
  }

  int get totalMeasured => success + failed + softFail;
}

/// 同步成功率本地监控服务（审计 P0-1）。
///
/// 隐私约束（PRIVACY.md「零遥测/零分析/不运营服务器」承诺）下的设计：
/// - 纯本地测量：sync_op_log 表只存本机，不上云、不自动外发；
/// - 仅记结构化字段（backend/scenario/outcome/errorClass/attempts/
///   duration），不落用户内容（账本名/备注/凭据一概不进表）；
/// - 30 天滚动窗口自动清理（与 local_changes 的 7 天清理同思路）。
///
/// 记录失败绝不阻断同步主流程 —— 指标是旁路观察，观测缺口优于业务失败。
class SyncMetricsService {
  final PiggyDatabase db;

  /// 指标保留窗口（滚动清理）。窗口外数据无诊断价值且累积无界。
  static const Duration retention = Duration(days: 30);

  SyncMetricsService(this.db);

  /// 记录一次操作结果。fire-and-forget 安全：任何 DB 异常只记 warning。
  Future<void> record(SyncOpRecord r) async {
    try {
      await db.into(db.syncOpLog).insert(SyncOpLogCompanion.insert(
            backend: r.backend,
            scenario: r.scenario.label,
            outcome: r.outcome.label,
            errorClass: drift.Value(r.errorClass?.label),
            ledgerId: drift.Value(r.ledgerId),
            attempts: drift.Value(r.attempts <= 0 ? 1 : r.attempts),
            durationMs: drift.Value(
                r.duration?.inMilliseconds.clamp(0, 1 << 31)),
          ));
    } catch (e) {
      logger.warning('SyncMetrics', '指标落库失败(忽略,不阻断同步): $e');
    }
  }

  /// 异步记录的便捷入口（unawaited 语义；内部已吞错，绝不抛出）。
  void recordUnawaited(SyncOpRecord r) {
    unawaited(record(r));
  }

  /// 聚合指定窗口的成功率（可按后端过滤；backend 为 null 汇总全部）。
  Future<SyncHealthSummary> summarize({
    Duration window = const Duration(days: 30),
    String? backend,
  }) async {
    try {
      final since = DateTime.now().subtract(window);
      final query = db.selectOnly(db.syncOpLog)
        ..addColumns([
          db.syncOpLog.outcome,
          db.syncOpLog.id.count(),
        ])
        ..where(db.syncOpLog.ts.isBiggerThanValue(since));
      if (backend != null) {
        query.where(db.syncOpLog.backend.equals(backend));
      }
      query.groupBy([db.syncOpLog.outcome]);

      final rows = await query.get();
      var success = 0, failed = 0, soft = 0, conflict = 0;
      for (final row in rows) {
        final outcome = row.read(db.syncOpLog.outcome) ?? '';
        final count = row.read(db.syncOpLog.id.count()) ?? 0;
        switch (outcome) {
          case 'success':
            success = count;
          case 'failed':
            failed = count;
          case 'soft_fail':
            soft = count;
          case 'conflict':
            conflict = count;
        }
      }
      return SyncHealthSummary(
          success: success, failed: failed, softFail: soft, conflict: conflict);
    } catch (e) {
      logger.warning('SyncMetrics', '指标聚合查询失败(返回空): $e');
      return const SyncHealthSummary();
    }
  }

  /// 窗口内 Top 失败错误类别（诊断归因用）。返回按次数降序的
  /// (errorClass, count) 列表，仅统计 failed/soft_fail 行。
  Future<List<({String errorClass, int count})>> topErrorClasses({
    Duration window = const Duration(days: 30),
    int limit = 5,
  }) async {
    try {
      final since = DateTime.now().subtract(window);
      final query = db.selectOnly(db.syncOpLog)
        ..addColumns([
          db.syncOpLog.errorClass,
          db.syncOpLog.id.count(),
        ])
        ..where(db.syncOpLog.ts.isBiggerThanValue(since) &
            db.syncOpLog.outcome.isIn(['failed', 'soft_fail']))
        ..groupBy([db.syncOpLog.errorClass])
        ..orderBy([
          drift.OrderingTerm.desc(db.syncOpLog.id.count()),
        ])
        ..limit(limit);
      final rows = await query.get();
      return rows
          .map((row) => (
                errorClass: row.read(db.syncOpLog.errorClass) ?? 'unknown',
                count: row.read(db.syncOpLog.id.count()) ?? 0,
              ))
          .toList();
    } catch (e) {
      logger.warning('SyncMetrics', 'Top 错误类别查询失败(返回空): $e');
      return const [];
    }
  }

  /// 滚动清理：删除窗口外的旧行。建议与 local_changes 清理同批调用
  /// （如快照上传成功后的 unawaited cleanup），近零成本。
  Future<int> cleanupExpired() async {
    try {
      final cutoff = DateTime.now().subtract(retention);
      final count = await (db.delete(db.syncOpLog)
            ..where((s) => s.ts.isSmallerThanValue(cutoff)))
          .go();
      if (count > 0) {
        logger.info('SyncMetrics', '清理 $count 条过期同步指标');
      }
      return count;
    } catch (e) {
      logger.warning('SyncMetrics', '指标清理失败(忽略): $e');
      return 0;
    }
  }

  /// 诊断导出：把窗口内全部指标行导出为可分享的 JSON 映射列表
  /// （维护页「诊断包」用；只含结构化字段，无用户内容）。
  Future<List<Map<String, dynamic>>> exportJson({
    Duration window = const Duration(days: 30),
  }) async {
    try {
      final since = DateTime.now().subtract(window);
      final rows = await (db.select(db.syncOpLog)
            ..where((s) => s.ts.isBiggerThanValue(since))
            ..orderBy([(s) => drift.OrderingTerm.asc(s.id)]))
          .get();
      return rows
          .map((r) => {
                'ts': r.ts.toIso8601String(),
                'backend': r.backend,
                'scenario': r.scenario,
                'outcome': r.outcome,
                'errorClass': r.errorClass,
                'ledgerId': r.ledgerId,
                'attempts': r.attempts,
                'durationMs': r.durationMs,
              })
          .toList();
    } catch (e) {
      logger.warning('SyncMetrics', '诊断导出失败(返回空): $e');
      return const [];
    }
  }

  /// 异常 → 错误类别归因（埋点调用方复用，保证全链路口径一致）。
  ///
  /// 优先级：条件写/冲突 → 未配置 → 认证 → 超时 → 网关 5xx → 数据损坏 → unknown。
  static SyncErrorClass classifyError(Object? e) {
    if (e == null) return SyncErrorClass.unknown;
    if (e is fcs.CloudPreconditionFailedException ||
        e is CloudConflictException) {
      return SyncErrorClass.precondition;
    }
    // 未配置**必须**排在认证之前：两者对用户都表现为「拿不到凭据」，
    // 但修复动作完全相反——未配置要去「云服务」页填地址与密钥，认证失败
    // 才是去改密码。误判成认证会让用户反复改密码却永远修不好。
    if (e is fcs.CloudConfigurationException || e is UnsupportedError) {
      return SyncErrorClass.notConfigured;
    }
    // CloudNotAuthenticatedException 与 CloudAuthException 是**兄弟**而非父子
    // （两者都直接 extends CloudSyncException）。Supabase 后端与 manager 的
    // 「未登录」门禁抛的是前者，漏判会让「没登录」掉进 unknown → 归因卡显示
    // 「其他」，把用户引向错误的处置方向。两者用户动作一致：去登录/查凭据。
    if (e is fcs.CloudAuthException ||
        e is fcs.CloudNotAuthenticatedException) {
      return SyncErrorClass.auth;
    }
    final text = e.toString().toLowerCase();
    // 文案兜底：兜住「无专用异常类型、只在 message 里带语义」的路径。
    // 注意本分支只覆盖**非 auth 类**输入——上面的类型判断已先行返回。
    // 故 transactions_sync_manager 刻意包成 CloudAuthException 的
    // `'cloud encrypted locally disabled'` 落到 auth（该处调用方明确要
    // auth 口径，见其「手动指定 auth」注释）；这里的 `locally disabled`
    // 只对裸 Exception('...locally disabled') 生效。
    if (text.contains('未配置') ||
        text.contains('not configured') ||
        text.contains('locally disabled')) {
      return SyncErrorClass.notConfigured;
    }
    if (text.contains('timed out') ||
        text.contains('timeout') ||
        text.contains('超时')) {
      return SyncErrorClass.networkTimeout;
    }
    // 网关类：兼容网关的 400/501/NotImplemented 特征（S3-W2 先例）
    if (text.contains('notimplemented') ||
        text.contains('not implemented') ||
        text.contains('http 5') ||
        text.contains('http 400')) {
      return SyncErrorClass.gateway;
    }
    // 数据损坏：完整性校验 / sha256 不匹配 / JSON 解析失败
    if (text.contains('完整性校验失败') ||
        text.contains('指纹不匹配') ||
        text.contains('sha256 不匹配') ||
        text.contains('invalid base64') ||
        text.contains('损坏')) {
      return SyncErrorClass.dataCorruption;
    }
    if (e is fcs.CloudStorageException) {
      // 已知存储异常但无更精确特征 → 归网关/远端故障
      return SyncErrorClass.gateway;
    }
    return SyncErrorClass.unknown;
  }
}
