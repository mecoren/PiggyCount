// 启动时云端数据拉取检查编排器的单元测试
//
// 测试策略：通过抽象 StartupSyncCheckerDeps 接口注入假实现，
// 使用真实的 StartupSyncController 监听状态变化，
// 验证 StartupSyncChecker 的编排逻辑（候选收集、汇总弹窗分支、
// 一键应用全部、逐个确认、错误隔离、幂等性），
// 不依赖真实网络 / 数据库 / UI 框架。


import 'dart:async';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide SyncStatus;
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/cloud/startup_sync_checker.dart';
import 'package:piggycount/cloud/startup_sync_overlay.dart';
import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/cloud/sync_metrics_service.dart';
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/domain/encryption/encryption_service.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeDeps deps;
  late StartupSyncController controller;
  late StartupSyncChecker checker;

  /// 状态变化监听器：当 checker 推送 HasUpdatesState 时自动完成 completer
  /// 并捕获候选账本供测试断言
  ///
  /// 支持 summaryChoiceSequence：若设置，按序列依次返回不同选择，
  /// 用于 US-7 取消后回退到 SummaryView 重新选择的场景。
  void onStateChange() {
    final state = controller.state;
    if (state is HasUpdatesState && !state.completer.isCompleted) {
      // 捕获候选账本
      deps.lastCandidates = state.candidates;
      // 捕获候选弹窗附带的「元信息差异」提示行（可空）
      deps.lastInfoMessage = state.infoMessage;
      final choice = deps.nextSummaryChoice();
      state.completer.complete(choice);
    }
  }

  setUp(() {
    deps = _FakeDeps();
    controller = StartupSyncController();
    checker = StartupSyncChecker(deps: deps, controller: controller);

    // 监听 controller 状态变化，自动响应 HasUpdatesState
    controller.addListener(onStateChange);
  });

  tearDown(() {
    controller.removeListener(onStateChange);
    controller.dispose();
  });

  Ledger ledger(int id, String name, {int monthStartDay = 1}) => Ledger(
        id: id,
        name: name,
        currency: 'CNY',
        type: 'general',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: monthStartDay,
      );

  SyncStatus status(SyncDiff diff, {String? message}) => SyncStatus(
        diff: diff,
        localCount: 0,
        localFingerprint: 'local-fp',
        message: message,
      );

  SyncPreview preview({
    int added = 0,
    int modified = 0,
    int deleted = 0,
    bool selectDeleted = false,
  }) {
    final changes = <SyncChange>[];
    for (var i = 0; i < added; i++) {
      changes.add(SyncChange(type: SyncChangeType.added));
    }
    for (var i = 0; i < modified; i++) {
      changes.add(SyncChange(type: SyncChangeType.modified));
    }
    for (var i = 0; i < deleted; i++) {
      // SYNC-05：deleted 默认不选中；需要旧行为（全选）的测试显式传入
      changes.add(SyncChange(
        type: SyncChangeType.deleted,
        selected: selectDeleted,
      ));
    }
    return SyncPreview(changes: changes);
  }

  group('跳过条件', () {
    test('配置为 local 时直接跳过，不查账本', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.local,
        name: 'local',
      );

      await checker.runIfNeeded();

      expect(deps.getAllLedgersCalled, isFalse);
      expect(deps.getStatusCallCount, 0);
      expect(controller.state, isA<DismissedState>());
      expect(deps.applyPreviewChangesCallCount, 0);
    });


    test('配置为 supabase 但 invalid 时跳过', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.supabase,
        name: 'supabase',
        // 缺少 url + anonKey → invalid
      );

      await checker.runIfNeeded();

      expect(deps.getAllLedgersCalled, isFalse);
      expect(controller.state, isA<DismissedState>());
    });

    test('账本列表为空时跳过', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [];

      await checker.runIfNeeded();

      expect(deps.getStatusCallCount, 0);
      expect(controller.state, isA<DismissedState>());
    });

    test('syncService 不是 TransactionsSyncManager 时跳过', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.syncServiceIsPathA = false;

      await checker.runIfNeeded();

      expect(deps.getStatusCallCount, 0);
      expect(controller.state, isA<DismissedState>());
    });
  });

  group('候选收集', () {
    test('所有账本 inSync 时提示全部都是最新（DoneState）', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.inSync),
        2: status(SyncDiff.inSync),
      };

      await checker.runIfNeeded();

      expect(deps.getStatusCallCount, 2);
      // 没有候选时进入 DoneState 显示"全部都是最新"提示（1.5s 后自动 dismiss）
      expect(controller.state, isA<DoneState>());
      expect((controller.state as DoneState).message,
          deps.getUpToDateMessage());
    });

    test('cloudNewer 收集为候选；different 方向未知不收集', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [
        ledger(1, 'L1'),
        ledger(2, 'L2'),
        ledger(3, 'L3'),
      ];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.inSync),
        3: status(SyncDiff.different),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      // different 源于 direction=unknown（指纹不同但时间戳相等），无法
      // 断定云端更新：不纳入候选，仅由"我的"/云同步页展示差异状态
      expect(deps.lastCandidates.length, 1);
      expect(deps.lastCandidates.map((c) => c.ledger.id), containsAll([1]));
    });

    test('noRemote / localNewer / notLoggedIn 不被收集', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [
        ledger(1, 'L1'),
        ledger(2, 'L2'),
        ledger(3, 'L3'),
      ];
      deps.statusByLedger = {
        1: status(SyncDiff.noRemote),
        2: status(SyncDiff.localNewer),
        3: status(SyncDiff.notLoggedIn),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates, isEmpty);
      // 无候选：进入 DoneState 显示"全部都是最新"提示
      expect(controller.state, isA<DoneState>());
      expect((controller.state as DoneState).message,
          deps.getUpToDateMessage());
    });

    test('error 状态计入失败账本，提示网络错误而非"已是最新"', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [
        ledger(1, 'L1'),
        ledger(2, 'L2'),
      ];
      deps.statusByLedger = {
        1: status(SyncDiff.inSync),
        // P1-3 补强：非哨兵 error（网络/超时）绝不能静默计入"已是最新"，
        // 否则全部失败时用户被误报"已全部同步"
        2: status(SyncDiff.error, message: 'Connection timeout'),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates, isEmpty);
      // 失败账本存在：进入 ErrorState 而非 DoneState
      expect(controller.state, isA<ErrorState>());
      expect((controller.state as ErrorState).message,
          contains('请检查网络后重试'));
      expect((controller.state as ErrorState).message, contains('1 个账本'));
      // 通知态走 AppDialog 版式：标题由 deps 提供（生产走 l10n）
      expect((controller.state as ErrorState).title,
          deps.getCheckFailedTitle());
    });

    test('error 状态为认证失败时提示检查云存储凭据', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [
        ledger(1, 'L1'),
      ];
      // WebDAV 401/403 被识别为认证失败：处置动作是改凭据而非重试网络，
      // 文案必须区分，避免误导用户排查方向
      deps.statusByLedger = {
        1: status(SyncDiff.error, message: 'CloudAuthException: 401 Unauthorized'),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(controller.state, isA<ErrorState>());
      expect((controller.state as ErrorState).message,
          contains('云端认证失败'));
      expect((controller.state as ErrorState).title,
          deps.getCheckFailedTitle());
    });

    test('getStatus 抛异常时该账本被跳过，其他账本继续', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {2: status(SyncDiff.cloudNewer)};
      deps.statusThrowForLedgerIds = {1};
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates.length, 1);
      expect(deps.lastCandidates.first.ledger.id, 2);
      expect(deps.errorLog, contains(predicate((s) => s.toString().contains('L1'))));
    });

    test('检查中状态推送进度', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.inSync),
        2: status(SyncDiff.inSync),
      };
      deps.summaryChoice = SummaryChoice.skip;

      final states = <StartupSyncState>[];
      controller.addListener(() => states.add(controller.state));

      await checker.runIfNeeded();

      // 应该有 CheckingState 出现
      expect(states.any((s) => s is CheckingState), isTrue);
    });

    test('W1 并行化：getStatus 真并发（同一时刻在途数 = 账本数），串行必红',
        () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: 'webdav',
        webdavUrl: 'https://webdav.example.com',
        webdavUsername: 'u',
        webdavPassword: 'p',
      );
      deps.ledgers = [
        ledger(1, 'L1'),
        ledger(2, 'L2'),
        ledger(3, 'L3'),
      ];
      deps.statusByLedger = {
        for (final l in deps.ledgers) l.id: status(SyncDiff.inSync),
      };
      deps.summaryChoice = SummaryChoice.skip;

      // 判据是「同一时刻有几个 getStatus 在途」，不是墙钟耗时。
      //
      // 为什么不再比耗时：旧写法是 3 个各挂 300ms 的真实延迟 + 一条
      // `sw.elapsed < 800ms` 上限 —— 全仓唯一一处看机器脸的断言，地板
      // 300ms、上限 800ms 只留 500ms 余量。GitHub runner（2 vCPU、两个
      // suite 抢 CPU）上这点余量被调度抖动吃掉就假红，而被测的并行性
      // 本身没问题（2026-10-05 那次 CI 的 1 例失败就长这样）。
      //
      // 现在的做法：让 3 个 getStatus 互相「等齐」——3 个同时在途才一起
      // 放行。串行实现下第 1 个永远等不齐（只能等兜底超时放行），在途数
      // 停在 1，断言**确定性**失败；并行实现下瞬间凑齐、毫秒级跑完。
      deps.getStatusBarrier = deps.ledgers.length;
      await checker.runIfNeeded();

      expect(deps.getStatusCallCount, 3);
      expect(deps.getStatusMaxInFlight, deps.ledgers.length,
          reason: '三个账本的 getStatus 必须同时在途：串行实现会让前一个白等'
              '兜底超时，W1 的并行化就等于没做');
    });

    test('W1 取消：检查阶段 requestCancel 后静默退出，不弹汇总/错误', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      // 一个 cloudNewer 候选：若取消未生效，会弹 HasUpdatesState
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.cloudNewer),
      };
      deps.getStatusDelay = const Duration(milliseconds: 100);
      deps.summaryChoice = SummaryChoice.skip;

      // 检查开始后立即取消（等首个 CheckingState 推送再触发）
      void onState() {
        if (controller.state is CheckingState) {
          controller.requestCancel();
        }
      }

      controller.addListener(onState);
      await checker.runIfNeeded();
      controller.removeListener(onState);

      expect(controller.cancelRequested, isTrue);
      expect(deps.lastCandidates, isEmpty,
          reason: '取消后不应到达 HasUpdatesState');
      expect(controller.state, isA<DismissedState>());
      expect(deps.applyPreviewChangesCallCount, 0);
    });

    test('W1 取消：updateCheckingProgress 在取消后不复活遮罩', () async {
      final controller2 = StartupSyncController();
      controller2.startChecking(3);
      controller2.requestCancel();
      controller2.updateCheckingProgress(1, 3);
      expect(controller2.state, isA<DismissedState>(),
          reason: '取消后迟到的进度回调应被拦截');
      controller2.dispose();
    });
  });

  group('一键应用全部（applyAll）', () {
    setUp(() {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.cloudNewer),
      };
      deps.summaryChoice = SummaryChoice.applyAll;
      deps.previewByLedger = {
        1: (
          preview: preview(added: 2, modified: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
        2: (
          preview: preview(deleted: 3),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
    });

    test('对每个候选账本调用 applyPreviewChanges，按默认选中态应用', () async {
      await checker.runIfNeeded();

      // L1: 2 added + 1 modified = 3 全选
      expect(deps.appliedForLedger[1]!.length, 3);
      // SYNC-05：L2 的 3 条 deleted（本地独有交易）默认不选中 →
      // 无选中变更，跳过 apply 且不进入合并/回传
      expect(deps.appliedForLedger.containsKey(2), isFalse);
      expect(deps.applyPreviewChangesCallCount, 1);
      // P3：未勾选的云端删除必须登记下来（供云同步页打「有 N 条待处理」标记）
      expect(deps.pendingCloudDeletesByLedger[2], 3,
          reason: 'P3：100% 未勾选删除的账本同样要打标记');
      expect(deps.pendingCloudDeletesByLedger[1], 0,
          reason: 'P3：无待处理删除的账本应清除标记');
    });

    test('每次 apply 后触发 runAfterDownload', () async {
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );
      await checker.runIfNeeded();

      expect(deps.runAfterDownloadCallCount, 2);
    });

    test('合并成功后对每个账本回传云端（merge-then-publish）', () async {
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );
      await checker.runIfNeeded();

      // 只下载合并不回传时指纹永不收敛，下次启动会重复弹「云端有更新」
      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('两阶段：全部账本合并完成后才统一回传（sync_convergence_fix）',
        () async {
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );
      await checker.runIfNeeded();

      // 账户/分类/标签是用户全局数据：若逐账本交错「合并→回传」，
      // 后续账本合并引入的新全局数据会让已回传账本的云端快照过期，
      // 指纹无法一轮收敛 → 每次启动都弹「云端有更新」。
      // 断言：所有 apply 先于任何 upload
      final firstUploadIdx =
          deps.callSequence.indexWhere((s) => s.startsWith('upload:'));
      expect(firstUploadIdx, greaterThanOrEqualTo(0));
      for (final s in deps.callSequence.sublist(0, firstUploadIdx)) {
        expect(s.startsWith('apply:'), isTrue,
            reason: 'upload 前不允许残留未完成的合并阶段调用: $s');
      }
      expect(deps.callSequence.where((s) => s.startsWith('apply:')).length, 2);
      expect(deps.callSequence.where((s) => s.startsWith('upload:')).length, 2);
    });

    test('preview == null 全量替换后同样回传', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
        2: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      expect(deps.downloadAndRestoreCallCount, 2);
      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('S14: 用户拒绝 legacy 全量替换确认 → 跳过该账本不回传', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
        2: (preview: preview(added: 1), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };
      deps.legacyReplaceConfirmReturn = false;

      await checker.runIfNeeded();

      expect(deps.legacyReplaceConfirmCallCount, 1,
          reason: 'S14：全量替换前必须弹确认');
      expect(deps.lastLegacyReplaceLedgerNames, ['L1']);
      expect(deps.downloadAndRestoreCallCount, 0,
          reason: '拒绝后不得执行全量替换');
      expect(deps.uploadedLedgerIds, [2], reason: '被拒账本不参与合并/回传');
    });

    test('S14: 用户确认后 legacy 全量替换照常执行', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
      };
      deps.legacyReplaceConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.legacyReplaceConfirmCallCount, 1);
      expect(deps.downloadAndRestoreCallCount, 1);
      expect(deps.uploadedLedgerIds, [1]);
    });

    test('preview.isEmpty 合并元数据后同样回传', () async {
      deps.previewByLedger = {
        1: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
        2: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('回传失败不影响合并结果，汇总提示回传失败', () async {
      deps.uploadThrowForLedgerIds = {1};
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.uploadCallCount, 2);
      expect(controller.state, isA<DoneState>());
      final done = controller.state as DoneState;
      expect(done.message, contains('已合并 2 个账本'));
      expect(done.message, contains('1 个账本回传云端失败'));
    });

    test('云端无数据的账本跳过且不回传', () async {
      // 账本 1 不设 preview → downloadAndPreview 返回 null → 跳过
      deps.previewByLedger = {
        2: (preview: preview(added: 1), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1);
      expect(deps.uploadedLedgerIds, [2]);
    });

    test('最后状态为 DoneState 显示汇总结果', () async {
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );
      await checker.runIfNeeded();

      expect(controller.state, isA<DoneState>());
      final done = controller.state as DoneState;
      expect(done.message, contains('已合并 2 个账本'));
      expect(done.message, contains('6 条变更'));
    });

    test('推送 ApplyingState 进度', () async {
      final states = <StartupSyncState>[];
      controller.addListener(() => states.add(controller.state));

      await checker.runIfNeeded();

      expect(states.any((s) => s is ApplyingState), isTrue);
    });

    test('preview == null 的账本走全量替换', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
        2: (preview: preview(added: 1), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      expect(deps.downloadAndRestoreCallCount, 1);
      expect(deps.applyPreviewChangesCallCount, 1);
    });

    test('preview.isEmpty 的账本仍调用 applyPreviewChanges 合并元数据（G5）', () async {
      // 纯账户变更场景：交易 diff 为空，但云端 importData 携带新账户。
      // 旧行为直接 continue 导致账户永远不落库（account_metadata_sync_fix G5）。
      deps.previewByLedger = {
        1: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
        2: (preview: preview(added: 1), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      // L1 空预览也要走一次空变更 apply（元数据合并）；L2 走正常 apply
      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.appliedForLedger[1]!, isEmpty);
      expect(deps.appliedForLedger[2]!.length, 1);
    });

    test('全部账本 preview.isEmpty 时均合并元数据并计入成功', () async {
      deps.previewByLedger = {
        1: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
        2: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.appliedForLedger[1]!, isEmpty);
      expect(deps.appliedForLedger[2]!, isEmpty);
      // 空预览账本也应触发数据刷新（元数据已变更）
      expect(deps.runAfterDownloadCallCount, 2);
      expect(controller.state, isA<DoneState>());
      final done = controller.state as DoneState;
      expect(done.message, contains('已合并 2 个账本'));
    });

    test('单个账本 apply 抛异常不影响其他账本，最终 DoneState 包含失败计数', () async {
      deps.applyThrowForLedgerIds = {1};
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.appliedForLedger[2]!.length, 3);
      expect(controller.state, isA<DoneState>());
      final done = controller.state as DoneState;
      expect(done.message, contains('1 个失败'));
    });

    test('downloadAndPreview 抛异常时该账本计入失败，其他账本继续', () async {
      deps.downloadAndPreviewThrowForLedgerIds = {1};
      deps.previewByLedger[2] = (
        preview: preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
        cloudFingerprint: null,
      );

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1);
      expect(deps.appliedForLedger[2]!.length, 3);
      // 1 个成功，1 个失败 → DoneState
      expect(controller.state, isA<DoneState>());
    });
  });

  group('applyAll 冲突高亮与二次确认（US-7）', () {
    setUp(() {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.summaryChoice = SummaryChoice.applyAll;
      deps.previewByLedger = {
        1: (
          preview: preview(added: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
        2: (
          preview: preview(added: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
    });

    test('AC-7.6: 全 cloudNewer 不弹二次确认对话框', () async {
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.cloudNewer),
      };
      deps.conflictConfirmReturn = true; // 即使返回 true 也不应被调用

      await checker.runIfNeeded();

      expect(deps.conflictConfirmCallCount, 0,
          reason: '全 cloudNewer 无冲突，不应弹二次确认');
      expect(deps.applyPreviewChangesCallCount, 2);
      expect(controller.state, isA<DoneState>());
    });

    test('AC-7.4: different 账本不进候选，不弹二次确认，仅 apply cloudNewer', () async {
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.different),
      };
      deps.conflictConfirmReturn = true; // 即使返回 true 也不应被调用

      await checker.runIfNeeded();

      // different（direction=unknown）不纳入候选 → 冲突确认不可达
      expect(deps.conflictConfirmCallCount, 0,
          reason: 'different 账本不是候选，不应弹二次确认');
      expect(deps.lastConflictLedgerNames, isNull);
      expect(deps.applyPreviewChangesCallCount, 1,
          reason: '仅 cloudNewer 的 L1 被 apply');
      expect(controller.state, isA<DoneState>());
    });

    test('AC-7.5: 无 different 候选时 applyAll 直接执行，不触发取消回退', () async {
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.cloudNewer),
      };
      deps.conflictConfirmReturn = false; // 即使取消也不应被调用

      await checker.runIfNeeded();

      expect(deps.conflictConfirmCallCount, 0);
      expect(deps.applyPreviewChangesCallCount, 2,
          reason: '无冲突候选，applyAll 不应被取消');
      expect(controller.state, isA<DoneState>());
    });

    test('AC-7.4: 多个 different 账本均不收集，仅 apply cloudNewer 账本', () async {
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2'), ledger(3, 'L3')];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.different),
        3: status(SyncDiff.different),
      };
      deps.previewByLedger = {
        1: (
          preview: preview(added: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
        2: (
          preview: preview(added: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
        3: (
          preview: preview(added: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
      deps.conflictConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.lastConflictLedgerNames, isNull,
          reason: 'different 账本不进候选，不触发冲突确认');
      expect(deps.applyPreviewChangesCallCount, 1,
          reason: '仅 L1（cloudNewer）被 apply');
    });

    test('AC-7.1/7.2: LedgerCandidate 携带 diffType 字段', () async {
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.different),
      };
      deps.summaryChoice = SummaryChoice.skip; // 不进入 applyAll，只验证候选构建

      await checker.runIfNeeded();

      // different 不收集：候选仅剩 cloudNewer 的 L1
      expect(deps.lastCandidates.length, 1);
      // 验证 diffType 字段已从 status.diff 填充
      final l1Candidate =
          deps.lastCandidates.firstWhere((c) => c.ledger.id == 1);
      expect(l1Candidate.diffType, SyncDiff.cloudNewer);
    });
  });

  group('逐个确认（confirmEach）', () {
    setUp(() {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.cloudNewer),
      };
      deps.summaryChoice = SummaryChoice.confirmEach;
      deps.previewByLedger = {
        1: (
          preview: preview(added: 2),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
        2: (
          preview: preview(modified: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
    });

    test('用户在每个账本弹窗选 viewDetail 时调用 showSyncPreviewDialog', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      expect(deps.showSyncPreviewDialogCallCount, 2);
      expect(deps.applyPreviewChangesCallCount, 2);
    });

    test('viewDetail 应用变更后回传该账本（merge-then-publish）', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('viewDetail 回传失败不中断后续账本', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];
      deps.uploadThrowForLedgerIds = {1};

      await checker.runIfNeeded();

      expect(deps.uploadCallCount, 2);
      expect(deps.applyPreviewChangesCallCount, 2);
    });

    test('S1 守卫：viewDetail 未勾选云端删除时跳过回传，防删除复活', () async {
      // 云端快照删除了 1 笔本地交易；用户在预览弹窗只勾选新增、未勾选删除
      deps.previewByLedger = {
        1: (
          preview: preview(added: 1, deleted: 1),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      // 模拟弹窗返回：仅返回用户勾选的 added（deleted 保持未勾选）
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1,
          reason: '合并照常执行');
      expect(deps.uploadedLedgerIds, isEmpty,
          reason: '存在未应用的云端删除时必须跳过回传，'
              '否则本地保留的已删交易随快照复活并传播到所有设备');
      // P3：逐账本登记待处理删除条数（不再只在结束文案里出现）
      expect(deps.pendingCloudDeletesByLedger[1], 1);
    });

    test('S1 守卫：全部删除被勾选应用时正常回传', () async {
      final deletedChange =
          SyncChange(type: SyncChangeType.deleted, selected: true);
      deps.previewByLedger = {
        1: (
          preview: preview(added: 1, deleted: 1, selectDeleted: true),
          importData: const ImportData(),
          version: 6,
          cloudFingerprint: null,
        ),
      };
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      // 弹窗把勾选实例原样返回（真实实现为 changes.where(selected)）
      deps.syncPreviewReturn = [
        SyncChange(type: SyncChangeType.added),
        deletedChange,
      ];

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1);
      expect(deps.uploadedLedgerIds, [1],
          reason: '删除已被应用，回传不会复活任何数据');
    });

    test('用户选 skip 时该账本不 apply，继续下一个', () async {
      deps.perLedgerChoice = LedgerDialogChoice.skip;

      await checker.runIfNeeded();

      expect(deps.showSyncPreviewDialogCallCount, 0);
      expect(deps.applyPreviewChangesCallCount, 0);
    });

    test('用户选 skipRest 时立即跳出循环，后续账本不处理', () async {
      deps.perLedgerChoice = LedgerDialogChoice.skipRest;

      await checker.runIfNeeded();

      expect(deps.perLedgerDialogCallCount, 1);
      expect(deps.applyPreviewChangesCallCount, 0);
    });

    test('preview.isEmpty 的账本不弹逐账本对话框，仍合并元数据（G5）', () async {
      // 纯账户变更：交易 diff 为空时逐账本对话框只会展示空列表（无意义），
      // 应静默走空变更 apply 完成元数据合并（account_metadata_sync_fix G5'）
      deps.previewByLedger = {
        1: (preview: preview(), importData: const ImportData(), version: 6, cloudFingerprint: null),
        2: (preview: preview(added: 1), importData: const ImportData(), version: 6, cloudFingerprint: null),
      };
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      // L1 空预览：不弹对话框，但 apply 仍被调用（空变更 = 元数据合并）
      expect(deps.perLedgerDialogCallCount, 1); // 仅 L2 弹
      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.appliedForLedger[1]!, isEmpty);
      expect(deps.appliedForLedger[2]!.length, 1);
    });

    test('showSyncPreviewDialog 返回 null 时视为取消，不 apply', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = null;

      await checker.runIfNeeded();

      expect(deps.showSyncPreviewDialogCallCount, 2);
      expect(deps.applyPreviewChangesCallCount, 0);
    });

    test('showSyncPreviewDialog 返回空列表时视为取消', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [];

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 0);
    });

    test('preview == null 时走全量替换确认流程', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5, cloudFingerprint: null),
      };
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;

      await checker.runIfNeeded();

      // 用户选 viewDetail 确认全量替换
      expect(deps.downloadAndRestoreCallCount, 1);
    });

    test('confirmEach 流程中应用成功后弹 legacy info', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      expect(deps.legacyInfoShownCount, 2);
    });

    test('confirmEach 流程中抛异常时弹 legacy error', () async {
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];
      deps.applyThrowForLedgerIds = {1};

      await checker.runIfNeeded();

      expect(deps.legacyErrorShownCount, greaterThanOrEqualTo(1));
      // L2 仍然能正常处理
      expect(deps.applyPreviewChangesCallCount, 2);
    });
  });

  group('幂等性', () {
    test('第二次调用 runIfNeeded 是 no-op', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();
      // 第一次有 HasUpdatesState（被监听器自动 skip → DismissedState）
      expect(deps.lastCandidates.length, 1);

      // 重置标志位，验证第二次调用不会再次执行
      deps.lastCandidates = [];
      await checker.runIfNeeded();

      expect(deps.lastCandidates, isEmpty);
    });
  });

  group('skip 选项', () {
    test('汇总弹窗选 skip 时不做任何 apply', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 0);
      expect(deps.downloadAndRestoreCallCount, 0);
      expect(deps.runAfterDownloadCallCount, 0);
      expect(controller.state, isA<DismissedState>());
    });
  });

  group('缺口 1: salt_mismatch 哨兵检测与恢复', () {
    setUp(() {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.summaryChoice = SummaryChoice.skip;
    });

    test('getStatus 返回 salt_mismatch_need_password 时调用 handleSaltMismatch，激活后重新检查', () async {
      // Arrange: getStatus 返回 salt_mismatch 哨兵
      deps.statusByLedger = {
        1: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        ),
      };
      // handleSaltMismatch 返回 activated（激活成功），并把状态改为 cloudNewer
      deps.handleSaltMismatchReturn = SaltMismatchRecoveryResult.activated;
      deps.statusAfterSaltMismatch = status(SyncDiff.cloudNewer);

      // Act
      await checker.runIfNeeded();

      // Assert: handleSaltMismatch 被调用了 1 次
      expect(deps.handleSaltMismatchCallCount, 1,
          reason: '检测到 salt_mismatch 应调用 handleSaltMismatch');
      // Assert: 激活后重新检查，候选账本被收集（cloudNewer）
      expect(deps.lastCandidates.length, 1,
          reason: '激活后重新检查应收集到 cloudNewer 候选');
      expect(deps.lastCandidates.first.diffType, SyncDiff.cloudNewer);
    });

    test('用户取消密码输入时不重新检查，直接返回且不弹失败提示', () async {
      // Arrange
      deps.statusByLedger = {
        1: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        ),
      };
      deps.handleSaltMismatchReturn = SaltMismatchRecoveryResult.cancelled;

      // Act
      await checker.runIfNeeded();

      // Assert: handleSaltMismatch 被调用
      expect(deps.handleSaltMismatchCallCount, 1);
      // Assert: 没有候选账本被收集
      expect(deps.lastCandidates, isEmpty);
      // Assert: controller 被 dismiss
      expect(controller.state, isA<DismissedState>());
      // Assert: 用户主动取消不弹"激活失败"提示
      expect(deps.recoveryFailedShownCount, 0,
          reason: '用户主动取消不应弹激活失败提示');
    });

    test('密码错误/激活失败时弹明确提示（而非静默退出）', () async {
      // Arrange: getStatus 返回 salt_mismatch 哨兵，且激活失败（密码错误）
      deps.statusByLedger = {
        1: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        ),
      };
      deps.handleSaltMismatchReturn = SaltMismatchRecoveryResult.failed;

      // Act
      await checker.runIfNeeded();

      // Assert: handleSaltMismatch 被调用
      expect(deps.handleSaltMismatchCallCount, 1);
      // Assert: 前端直接弹激活失败提示（而非只在设置页显示）
      expect(deps.recoveryFailedShownCount, 1,
          reason: '激活失败应在前端直接弹窗提示用户');
      // Assert: 不继续收集候选账本
      expect(deps.lastCandidates, isEmpty);
      // Assert: controller 被 dismiss
      expect(controller.state, isA<DismissedState>());
    });

    test('isRetry 模式下不再弹密码对话框（防止无限递归）', () async {
      // Arrange: 持续返回 salt_mismatch（即使激活后仍不匹配）
      deps.statusByLedger = {
        1: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        ),
      };
      // 激活后状态仍为 salt_mismatch（密码再次错误）
      deps.handleSaltMismatchReturn = SaltMismatchRecoveryResult.activated;
      deps.statusAfterSaltMismatch = SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: 'salt_mismatch_need_password',
      );

      // Act
      await checker.runIfNeeded();

      // Assert: handleSaltMismatch 只被调用 1 次（isRetry 时不再次弹窗）
      expect(deps.handleSaltMismatchCallCount, 1,
          reason: 'isRetry 模式下不应再次调用 handleSaltMismatch');
      // Assert: 没有候选账本（第二次检查仍为 error，不收集为候选）
      expect(deps.lastCandidates, isEmpty);
      expect(controller.state, isA<DismissedState>());
    });

    test('isRetry 后仍检测到哨兵时弹明确提示（而非静默退出）', () async {
      // Arrange: 激活成功（返回 activated），但激活后 getStatus 仍返回哨兵
      // （混合 salt：A 改密时云端部分文件重加密失败，激活的 salt 只匹配部分账本）
      deps.statusByLedger = {
        1: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'salt_mismatch_need_password',
        ),
        2: SyncStatus(
          diff: SyncDiff.error,
          localCount: 0,
          localFingerprint: '',
          message: 'cloud_encrypted_locally_disabled',
        ),
      };
      deps.handleSaltMismatchReturn = SaltMismatchRecoveryResult.activated;
      // 激活后仍全部是哨兵
      deps.statusAfterSaltMismatch = SyncStatus(
        diff: SyncDiff.error,
        localCount: 0,
        localFingerprint: '',
        message: 'salt_mismatch_need_password',
      );

      // Act
      await checker.runIfNeeded();

      // Assert: 输入密码后仍失败 → 前端直接弹明确提示（而非静默退出到设置页）
      expect(deps.recoveryFailedShownCount, 1,
          reason: '激活后仍密钥不匹配应明确提示用户，而非静默退出');
      expect(deps.handleSaltMismatchCallCount, 1,
          reason: 'isRetry 模式下不应再次弹密码框（防止无限递归）');
      expect(deps.lastCandidates, isEmpty);
      expect(controller.state, isA<DismissedState>());
    });
  });

  group('云端账本发现（/prd/remote_ledger_discovery）', () {
    RemoteLedgerMeta meta(int id, String name, {int txCount = 3}) =>
        RemoteLedgerMeta(
          slotKey: id.toString(),
          name: name,
          currency: 'CNY',
          monthStartDay: 1,
          txCount: txCount,
        );

    setUp(() {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
    });

    test('US-1/US-2: 发现新账本 → 弹确认 → 导入 → 重新拉取账本继续检查', () async {
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.inSync), 2: status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [meta(2, 'Remote')];
      deps.newLedgersConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.discoverCallCount, 1);
      expect(deps.newLedgersConfirmCallCount, 1);
      expect(deps.importCallCount, 1, reason: '确认后应导入 1 个新账本');
      expect(deps.lastImportedMetas.single.name, 'Remote');
      expect(deps.runAfterDownloadCallCount, greaterThanOrEqualTo(1),
          reason: '导入后应刷新 UI providers');
      // 重新拉取账本（fake 返回同一列表）→ 全部 inSync → DoneState
      expect(controller.state, isA<DoneState>());
    });

    test('US-2: 用户选择跳过时不导入，原检查流程照常', () async {
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [meta(2, 'Remote')];
      deps.newLedgersConfirmReturn = false;

      await checker.runIfNeeded();

      expect(deps.importCallCount, 0);
      expect(controller.state, isA<DoneState>());
    });

    test('US-3: discover 抛异常时静默降级，不阻塞原检查', () async {
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.discoverThrow = Exception('list failed');
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.discoverCallCount, 1);
      expect(deps.importCallCount, 0);
      // 原流程继续：候选检查照常执行
      expect(deps.lastCandidates.length, 1);
    });

    test('US-3: 单个账本导入失败不影响其他账本', () async {
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {1: status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [meta(2, 'A'), meta(3, 'B')];
      deps.importThrowForSlotKeys = {'2'};

      await checker.runIfNeeded();

      expect(deps.importCallCount, 2, reason: '两个账本都尝试导入');
      expect(deps.lastImportedMetas.length, 2);
      expect(controller.state, isA<DoneState>(),
          reason: '单个失败不影响整体流程收尾');
    });

    test('US-1: 本地零账本的全新设备也能发现云端账本', () async {
      deps.ledgers = [];
      deps.remoteLedgerMetas = [meta(1, 'Only')];
      deps.newLedgersConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.discoverCallCount, 1);
      expect(deps.importCallCount, 1,
          reason: '零账本设备不能在 ledgers.isEmpty 处提前跳过');
    });
  });

  group('startupCheck 埋点（P1-3 口径补缺）', () {
    /// 轻量记录器：实现 record 即可（summarize 等查询方法不进本组断言）。
    _RecordingMetrics setupRecording() {
      final rec = _RecordingMetrics();
      deps.metricsOverride = rec;
      return rec;
    }

    test('全部账本最新 → 记录 success 一条（backend=startup）', () async {
      final rec = setupRecording();
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {
        1: const SyncStatus(
            diff: SyncDiff.inSync, localCount: 0, localFingerprint: 'fp'),
      };

      await checker.runIfNeeded();

      expect(controller.state, isA<DoneState>());
      expect(rec.records, hasLength(1));
      final r = rec.records.single;
      expect(r.scenario, SyncOpScenario.startupCheck);
      expect(r.outcome, SyncOpOutcome.success);
      expect(r.backend, 'startup');
      expect(r.duration, isNotNull);
    });

    test('getStatus 全部失败 → 记录 failed（errorClass=network_timeout）',
        () async {
      final rec = setupRecording();
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.webdav,
        name: 'wdav',
        webdavUrl: 'https://dav.example.com',
        webdavUsername: 'u',
        webdavPassword: 'p',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusThrowForLedgerIds = {1};

      await checker.runIfNeeded();

      expect(controller.state, isA<ErrorState>());
      expect(rec.records.single.outcome, SyncOpOutcome.failed);
      expect(rec.records.single.errorClass, SyncErrorClass.networkTimeout);
    });

    test('方向未知差异（different）→ 记录 softFail 而非 success', () async {
      final rec = setupRecording();
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {
        1: const SyncStatus(
            diff: SyncDiff.different, localCount: 1, localFingerprint: 'a'),
      };

      await checker.runIfNeeded();

      // different 不弹更新、静默关闭 —— 数据未收敛，按 softFail 计量
      expect(rec.records.single.outcome, SyncOpOutcome.softFail);
    });

    test('用户在汇总弹窗选择 skip → 仍记 success（用户主动决策非失败）',
        () async {
      final rec = setupRecording();
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {
        1: const SyncStatus(
            diff: SyncDiff.cloudNewer, localCount: 0, localFingerprint: 'fp'),
      };
      deps.summaryChoiceSequence = [SummaryChoice.skip];

      await checker.runIfNeeded();

      expect(rec.records.single.outcome, SyncOpOutcome.success);
    });

    test('metrics 为 null（旧测试桩/极早期装配）→ 主流程不受任何影响',
        () async {
      deps.metricsOverride = null;
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.s3,
        name: 's3',
        s3Endpoint: 'https://s3.example.com',
        s3AccessKey: 'ak',
        s3SecretKey: 'sk',
        s3Bucket: 'b',
      );
      deps.ledgers = [ledger(1, 'L1')];
      deps.statusByLedger = {
        1: const SyncStatus(
            diff: SyncDiff.inSync, localCount: 0, localFingerprint: 'fp'),
      };

      // 不抛异常即通过（埋点旁路语义）
      await checker.runIfNeeded();
      expect(controller.state, isA<DoneState>());
    });
  });

  group('同名多槽位甄别（两次实测 §4.2 改进点）', () {
    RemoteLedgerMeta m(String slotKey, String name,
            {int txCount = 10, DateTime? uploadedAt}) =>
        RemoteLedgerMeta(
          slotKey: slotKey,
          name: name,
          currency: 'CNY',
          monthStartDay: 1,
          txCount: txCount,
          uploadedAt: uploadedAt,
        );

    test('无同名（各名唯一）→ 无警示组', () {
      final metas = [
        m('aaa', 'A'),
        m('bbb', 'B'),
      ];
      expect(StartupSyncChecker.duplicateNameGroups(metas), isEmpty);
    });

    test('同名 2 槽位 → 分组返回且按 uploadedAt 新者在前', () {
      final older = m('slot-old', '回忆',
          txCount: 800, uploadedAt: DateTime(2026, 9, 1, 10, 0));
      final newer = m('slot-new', '回忆',
          txCount: 1001, uploadedAt: DateTime(2026, 9, 10, 23, 0));
      final groups = StartupSyncChecker.duplicateNameGroups([older, newer]);

      expect(groups.keys, ['回忆']);
      expect(groups['回忆']!.first.slotKey, 'slot-new',
          reason: '新上传的排在前，供弹窗优先展示');
      expect(groups['回忆']!.last.slotKey, 'slot-old');
    });

    test('多个名称各自分组，互不混并；单槽位名称不警示', () {
      final groups = StartupSyncChecker.duplicateNameGroups([
        m('a1', 'X', uploadedAt: DateTime(2026, 9, 5)),
        m('a2', 'X', uploadedAt: DateTime(2026, 9, 6)),
        m('b1', 'Y', uploadedAt: DateTime(2026, 9, 1)),
        m('b2', 'Y', uploadedAt: DateTime(2026, 9, 2)),
        m('c1', 'Z'),
      ]);
      expect(groups.keys, containsAll(['X', 'Y']));
      expect(groups.containsKey('Z'), isFalse, reason: '单槽位名称不警示');
      expect(groups['X']!.length, 2);
      expect(groups['Y']!.length, 2);
    });

    test('uploadedAt 为 null 的槽位排在有值之后（DateTime(0) 兜底）', () {
      final noTime = m('n1', 'D');
      final hasTime = m('n2', 'D', uploadedAt: DateTime(2020, 1, 1));
      final groups = StartupSyncChecker.duplicateNameGroups([noTime, hasTime]);
      // null 兜底为 DateTime(0)，比任何真实时间都旧 → 排后
      expect(groups['D']!.first.slotKey, 'n2');
    });

    test('组名顺序按发现序稳定（首个出现的名称先输出）', () {
      final groups = StartupSyncChecker.duplicateNameGroups([
        m('y1', 'B', uploadedAt: DateTime(2026, 9, 1)),
        m('y2', 'B', uploadedAt: DateTime(2026, 9, 2)),
        m('x1', 'A', uploadedAt: DateTime(2026, 9, 1)),
        m('x2', 'A', uploadedAt: DateTime(2026, 9, 2)),
      ]);
      expect(groups.keys, ['B', 'A'],
          reason: '按首次出现顺序，与弹窗展示顺序一致');
    });
  });

  group('云端账本元信息差异：只提示、不自动合并', () {
    CloudServiceConfig s3Config() => const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 's3',
          s3Endpoint: 'https://s3.example.com',
          s3AccessKey: 'ak',
          s3SecretKey: 'sk',
          s3Bucket: 'b',
        );

    test('different + 云端账本名不同 → 信息提示列出差异，且零自动动作', () async {
      deps.activeConfig = s3Config();
      deps.ledgers = [ledger(1, '日常账')];
      deps.statusByLedger = {1: status(SyncDiff.different)};
      deps.cloudMetaByLedger = {
        1: (name: '家庭账', currency: 'CNY', monthStartDay: 1),
      };

      await checker.runIfNeeded();

      expect(controller.state, isA<InfoState>(),
          reason: '方向未知的元信息差异必须让用户看见，不能静默关闭');
      final info = controller.state as InfoState;
      expect(info.title, 'meta-diff-title');
      expect(info.lines, ['name:日常账->家庭账']);
      expect(info.action, 'meta-diff-action');

      // 关键不变量：只提示，绝不做任何自动动作（不合并 / 不上传 / 不覆盖）
      expect(deps.applyPreviewChangesCallCount, 0);
      expect(deps.uploadCallCount, 0);
      expect(deps.downloadAndRestoreCallCount, 0);
      expect(deps.lastCandidates, isEmpty);
    });

    test('different + 仅月起始日不同 → 明细含月起始日对照行', () async {
      deps.activeConfig = s3Config();
      deps.ledgers = [ledger(1, '日常账')]; // 本地 monthStartDay = 1
      deps.statusByLedger = {1: status(SyncDiff.different)};
      deps.cloudMetaByLedger = {
        1: (name: '日常账', currency: 'CNY', monthStartDay: 5),
      };

      await checker.runIfNeeded();

      expect(controller.state, isA<InfoState>());
      expect((controller.state as InfoState).lines, ['monthStart:日常账:1->5']);
    });

    test('different 但云端元信息一致 / 读不到 → 维持既有静默关闭', () async {
      deps.activeConfig = s3Config();
      deps.ledgers = [ledger(1, '日常账'), ledger(2, 'L2')];
      deps.statusByLedger = {
        1: status(SyncDiff.different), // 元信息一致 → 不提示
        2: status(SyncDiff.different), // 读取抛异常 → 拿不到，不猜
      };
      deps.cloudMetaByLedger = {
        1: (name: '日常账', currency: 'CNY', monthStartDay: 1),
      };
      deps.cloudMetaThrowForLedgerIds = {2};

      await checker.runIfNeeded();

      expect(controller.state, isA<DismissedState>(),
          reason: '没有可确证的元信息差异时不打扰用户（保持原语义）');
    });

    test('存在云更新候选时：候选弹窗附带提示行，且不新增自动动作', () async {
      deps.activeConfig = s3Config();
      deps.ledgers = [ledger(1, '待合并'), ledger(2, '日常账')];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.different),
      };
      deps.cloudMetaByLedger = {
        2: (name: '家庭账', currency: 'CNY', monthStartDay: 1),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates.map((c) => c.ledger.id), contains(1));
      // 两类排除项各占一行：账本 2 同时命中「云端元信息不同」与
      // 「direction=unknown 不纳入候选」，因此两行都要出现。
      // 2026-10-03 真机复现的误读来源：此前只报元信息差异，7 个
      // direction=unknown 账本被完全静默，用户会把「检测到 1 个账本」
      // 读成「其余账本都已最新」。
      expect(deps.lastInfoMessage, 'meta-diff-title\nunknown-diff:1',
          reason: '候选弹窗要显式说出本次不会同步哪些账本：'
              '元信息差异 + 方向未知（各一行）');
      expect(deps.lastCandidates.map((c) => c.ledger.id),
          isNot(contains(2)),
          reason: '方向未知的账本仍不得进入候选（审计 M1 不变量不变）');
    });

    test('有候选 + 仅有方向未知账本（无元信息差异）→ 仍要告知被跳过的数量', () async {
      // 真机 8 账本场景的形态：1 个 cloudNewer 进候选，7 个 direction=unknown
      // 被跳过，且它们的云端元信息与本地一致（故 metaDiff 为空）。
      // 修复前 infoMessage 为 null —— 弹窗只剩「检测到 1 个账本」，用户无从
      // 得知另外 7 个本次不会同步。修复后必须给出跳过数量。
      deps.activeConfig = s3Config();
      deps.ledgers = [
        ledger(1, '待合并'),
        ledger(2, '日常账'),
        ledger(3, '旅行账'),
      ];
      deps.statusByLedger = {
        1: status(SyncDiff.cloudNewer),
        2: status(SyncDiff.different),
        3: status(SyncDiff.different),
      };
      // 元信息与本地一致 → 不产生 metaDiff，只剩方向未知这一类排除项
      deps.cloudMetaByLedger = {
        2: (name: '日常账', currency: 'CNY', monthStartDay: 1),
        3: (name: '旅行账', currency: 'CNY', monthStartDay: 1),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates.map((c) => c.ledger.id), contains(1));
      expect(deps.lastInfoMessage, 'unknown-diff:2',
          reason: '无元信息差异时也不能静默：必须告知 2 个账本本次不会同步');
      expect(deps.lastCandidates.map((c) => c.ledger.id), isNot(contains(2)));
      expect(deps.lastCandidates.map((c) => c.ledger.id), isNot(contains(3)));
    });

    test('无任何排除项 → infoMessage 为 null（不制造无谓噪音）', () async {
      deps.activeConfig = s3Config();
      deps.ledgers = [ledger(1, '待合并')];
      deps.statusByLedger = {1: status(SyncDiff.cloudNewer)};
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastInfoMessage, isNull, reason: '候选即全部待同步账本时，弹窗不应出现附加提示行');
    });
  });
}

/// 测试用的假依赖实现
class _FakeDeps implements StartupSyncCheckerDeps {
  CloudServiceConfig activeConfig = const CloudServiceConfig(
    type: CloudBackendType.local,
    name: 'local',
  );

  bool syncServiceIsPathA = true;

  List<Ledger> ledgers = const [];

  Map<int, SyncStatus> statusByLedger = {};
  Set<int> statusThrowForLedgerIds = {};
  /// W1 并行化测试：getStatus 人为延迟（模拟慢速后端）
  Duration? getStatusDelay;

  /// W1 并行化测试：让 getStatus 互相「等齐」——在途数达到该值才统一放行。
  /// 串行实现下永远凑不齐（靠 [_barrierTimeout] 兜底放行），于是
  /// [getStatusMaxInFlight] 停在 1，断言确定性失败，不依赖机器速度。
  int? getStatusBarrier;

  /// 观察到的「同一时刻在途」峰值：并行度的直接证据。
  int getStatusMaxInFlight = 0;

  int _inFlight = 0;
  Completer<void>? _barrier;

  /// 凑不齐时的兜底：到点必须放行，否则测试会一路挂到 30s 默认超时，
  /// 而不是给出「在途数不足」这条可读的失败原因。串行下 3 个账本共等
  /// 9s，离 30s 还有足够余量。
  static const Duration _barrierTimeout = Duration(seconds: 3);

  Map<int,
          ({SyncPreview? preview, ImportData importData, int version,
              String? cloudFingerprint})>
      previewByLedger = {};
  Set<int> downloadAndPreviewThrowForLedgerIds = {};

  Set<int> applyThrowForLedgerIds = {};

  SummaryChoice summaryChoice = SummaryChoice.skip;
  /// US-7: 选择序列，用于测试取消后回退到 SummaryView 的场景
  /// 若非空，nextSummaryChoice 按序列依次返回；用尽后回退到 summaryChoice
  List<SummaryChoice>? summaryChoiceSequence;
  int _summaryChoiceIndex = 0;
  LedgerDialogChoice perLedgerChoice = LedgerDialogChoice.skip;
  List<SyncChange>? syncPreviewReturn;

  /// 返回下一次 HasUpdatesState 的用户选择
  /// 优先使用 summaryChoiceSequence，用尽后回退到 summaryChoice
  SummaryChoice nextSummaryChoice() {
    if (summaryChoiceSequence != null &&
        _summaryChoiceIndex < summaryChoiceSequence!.length) {
      return summaryChoiceSequence![_summaryChoiceIndex++];
    }
    return summaryChoice;
  }

  // US-7: applyAll 二次确认 mock
  /// 控制二次确认对话框返回值（true=确认，false=取消）
  bool conflictConfirmReturn = true;
  /// 二次确认对话框调用次数
  int conflictConfirmCallCount = 0;
  /// 最近一次传入二次确认对话框的账本名列表
  List<String>? lastConflictLedgerNames;

  // 调用记录
  bool getAllLedgersCalled = false;
  int getStatusCallCount = 0;
  List<LedgerCandidate> lastCandidates = [];
  int applyPreviewChangesCallCount = 0;
  /// 跨方法调用顺序（'apply:N' / 'upload:N'），验证两阶段时序：
  /// 全部 apply 必须先于任何 upload（用户全局数据统一后回传才收敛）
  List<String> callSequence = [];
  Map<int, List<SyncChange>> appliedForLedger = {};
  int downloadAndRestoreCallCount = 0;
  // merge-then-publish mock：合并后回传的调用记录与失败注入
  Set<int> uploadThrowForLedgerIds = {};
  int uploadCallCount = 0;
  List<int> uploadedLedgerIds = [];
  int runAfterDownloadCallCount = 0;
  int showSyncPreviewDialogCallCount = 0;
  int perLedgerDialogCallCount = 0;
  int legacyInfoShownCount = 0;
  int legacyErrorShownCount = 0;
  List<String> errorLog = [];
  /// 最近一次候选弹窗附带的「元信息差异」提示行（可空）
  String? lastInfoMessage;

  // SaltMismatch 处理记录
  int handleSaltMismatchCallCount = 0;
  SaltMismatchRecoveryResult handleSaltMismatchReturn =
      SaltMismatchRecoveryResult.cancelled;
  /// 密钥激活失败兜底提示调用次数
  int recoveryFailedShownCount = 0;
  /// 若非 null，handleSaltMismatch 返回 activated 时把所有账本状态替换为此值
  /// （模拟激活密钥后 getStatus 返回正常状态）
  SyncStatus? statusAfterSaltMismatch;

  @override
  Future<CloudServiceConfig> getActiveConfig() async => activeConfig;

  @override
  bool get isSyncServicePathA => syncServiceIsPathA;

  @override
  Future<List<Ledger>> getAllLedgers() async {
    getAllLedgersCalled = true;
    return ledgers;
  }

  @override
  Future<SyncStatus> getStatus(int ledgerId) async {
    getStatusCallCount++;
    final barrier = getStatusBarrier;
    if (barrier != null) {
      _inFlight++;
      if (_inFlight > getStatusMaxInFlight) getStatusMaxInFlight = _inFlight;
      _barrier ??= Completer<void>();
      if (_inFlight >= barrier && !_barrier!.isCompleted) _barrier!.complete();
      // 凑不齐就等到点放行：让断言去报「在途数不足」，而不是挂到超时。
      await _barrier!.future.timeout(_barrierTimeout, onTimeout: () {});
      _inFlight--;
    }
    if (getStatusDelay != null) {
      await Future.delayed(getStatusDelay!);
    }
    if (statusThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('getStatus boom for ledger $ledgerId');
    }
    return statusByLedger[ledgerId] ??
        SyncStatus(
          diff: SyncDiff.inSync,
          localCount: 0,
          localFingerprint: '',
        );
  }

  @override
  Future<
      ({SyncPreview? preview, ImportData importData, int version,
          String? cloudFingerprint})?> downloadAndPreview(int ledgerId) async {
    if (downloadAndPreviewThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('downloadAndPreview boom for ledger $ledgerId');
    }
    return previewByLedger[ledgerId];
  }

  /// P3：本轮各账本「未勾选的云端删除」条数（0 表示已清空标记）
  final pendingCloudDeletesByLedger = <int, int>{};

  @override
  void recordPendingCloudDeletes(int ledgerId, int count) {
    pendingCloudDeletesByLedger[ledgerId] = count;
  }

  @override
  Future<SyncApplyResult> applyPreviewChanges({
    required int ledgerId,
    required List<SyncChange> selectedChanges,
    required ImportData importData,
  }) async {
    applyPreviewChangesCallCount++;
    callSequence.add('apply:$ledgerId');
    if (applyThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('applyPreviewChanges boom for ledger $ledgerId');
    }
    appliedForLedger[ledgerId] = selectedChanges;
    return SyncApplyResult(
      addedCount: selectedChanges
          .where((c) => c.type == SyncChangeType.added)
          .length,
      modifiedCount: selectedChanges
          .where((c) => c.type == SyncChangeType.modified)
          .length,
      deletedCount: selectedChanges
          .where((c) => c.type == SyncChangeType.deleted)
          .length,
    );
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger({
    required int ledgerId,
  }) async {
    downloadAndRestoreCallCount++;
    return (inserted: 0, deletedDup: 0);
  }

  @override
  Future<void> uploadLedger({required int ledgerId, bool force = false}) async {
    uploadCallCount++;
    callSequence.add('upload:$ledgerId');
    uploadedLedgerIds.add(ledgerId);
    if (uploadThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('uploadLedger boom for ledger $ledgerId');
    }
  }

  // ============ 审计 H6：回传前新鲜度校验 mock ============

  /// refreshCloudFingerprint 返回的云端指纹（缺省 = 拿不到，调用方降级放行）
  Map<int, String?> refreshCloudFingerprintByLedger = {};

  /// refreshCloudFingerprint 调用记录
  List<int> refreshCloudFingerprintCallIds = [];

  @override
  Future<({String? fingerprint, int? count, DateTime? exportedAt})?>
      refreshCloudFingerprint(int ledgerId) async {
    refreshCloudFingerprintCallIds.add(ledgerId);
    if (!refreshCloudFingerprintByLedger.containsKey(ledgerId)) return null;
    final fp = refreshCloudFingerprintByLedger[ledgerId];
    return (fingerprint: fp, count: null, exportedAt: null);
  }

  // ============ 云端账本发现 mock ============

  /// discoverRemoteLedgers 返回的远端账本元信息（默认空 = 无新账本）
  List<RemoteLedgerMeta> remoteLedgerMetas = const [];

  /// discoverRemoteLedgers 抛异常（模拟 list 失败降级）
  Object? discoverThrow;

  /// 确认弹窗返回值（默认 true = 下载）
  bool newLedgersConfirmReturn = true;

  /// 确认弹窗调用次数
  int newLedgersConfirmCallCount = 0;

  /// importRemoteLedger 返回值（null = id 被占用跳过）
  int? importRemoteLedgerReturn = 0;

  /// importRemoteLedger 抛异常的账本 slotKey 集合
  Set<String> importThrowForSlotKeys = {};

  int discoverCallCount = 0;
  int importCallCount = 0;
  List<RemoteLedgerMeta> lastImportedMetas = [];

  @override
  Future<List<RemoteLedgerMeta>> discoverRemoteLedgers() async {
    discoverCallCount++;
    if (discoverThrow != null) throw discoverThrow!;
    return remoteLedgerMetas;
  }

  @override
  Future<int?> importRemoteLedger(RemoteLedgerMeta meta) async {
    importCallCount++;
    lastImportedMetas.add(meta);
    if (importThrowForSlotKeys.contains(meta.slotKey)) {
      throw Exception('import failed for ${meta.slotKey}');
    }
    return importRemoteLedgerReturn;
  }

  @override
  Future<bool> showNewLedgersConfirmDialog(List<RemoteLedgerMeta> metas) async {
    newLedgersConfirmCallCount++;
    return newLedgersConfirmReturn;
  }

  @override
  Future<LedgerDialogChoice> showPerLedgerDialog({
    required Ledger ledger,
    required SyncPreview preview,
  }) async {
    perLedgerDialogCallCount++;
    return perLedgerChoice;
  }

  @override
  Future<List<SyncChange>?> showSyncPreviewDialog(SyncPreview preview) async {
    showSyncPreviewDialogCallCount++;
    return syncPreviewReturn;
  }

  @override
  Future<bool> showConflictConfirmDialog(List<String> ledgerNames) async {
    conflictConfirmCallCount++;
    lastConflictLedgerNames = List<String>.from(ledgerNames);
    return conflictConfirmReturn;
  }

  int legacyReplaceConfirmCallCount = 0;
  List<String> lastLegacyReplaceLedgerNames = const [];
  bool legacyReplaceConfirmReturn = true;

  @override
  Future<bool> showLegacyReplaceConfirmDialog(List<String> ledgerNames) async {
    legacyReplaceConfirmCallCount++;
    lastLegacyReplaceLedgerNames = List<String>.from(ledgerNames);
    return legacyReplaceConfirmReturn;
  }

  @override
  Future<SaltMismatchRecoveryResult> handleSaltMismatch() async {
    handleSaltMismatchCallCount++;
    if (handleSaltMismatchReturn == SaltMismatchRecoveryResult.activated &&
        statusAfterSaltMismatch != null) {
      // 模拟激活密钥后 getStatus 返回正常状态
      for (final id in statusByLedger.keys.toList()) {
        statusByLedger[id] = statusAfterSaltMismatch!;
      }
    }
    return handleSaltMismatchReturn;
  }

  @override
  void showRecoveryFailed() {
    recoveryFailedShownCount++;
  }

  @override
  void runAfterDownload() => runAfterDownloadCallCount++;

  @override
  void showLegacyError(String message) {
    legacyErrorShownCount++;
    errorLog.add(message);
  }

  @override
  void showLegacyInfo(String message) {
    legacyInfoShownCount++;
  }

  @override
  String getUpToDateMessage() => 'All ledgers up to date (test)';

  /// 检查失败通用标题（生产走 l10n，见 WidgetRefDeps）——
  /// 断言只关心「进入了失败态」，不关心标题排版文案。
  @override
  String getCheckFailedTitle() => 'check-failed-title (test)';

  /// 云端账本元信息（ledgerId → 云端名称/本位币/月起始日）。
  ///
  /// 缺省为空 = 拿不到（等价于老快照/网关剥头）→ 检查器不产生任何提示。
  Map<int, CloudLedgerMeta> cloudMetaByLedger = {};
  /// 读取元信息抛异常：验证「读不到只降级、不影响主流程」
  Set<int> cloudMetaThrowForLedgerIds = {};
  int fetchCloudMetaCallCount = 0;

  @override
  Future<CloudLedgerMeta?> fetchCloudLedgerMeta(int ledgerId) async {
    fetchCloudMetaCallCount++;
    if (cloudMetaThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('fetchCloudLedgerMeta boom for ledger $ledgerId');
    }
    return cloudMetaByLedger[ledgerId];
  }

  /// 提示文案用固定字面量（生产走 l10n，见 WidgetRefDeps）——
  /// 断言只关心「提示了什么数据」，不关心排版文案。
  @override
  ({String title, List<String> lines, String action}) getMetaDiffTexts(
      List<MetaDiffLedger> diffs) {
    final lines = <String>[];
    for (final d in diffs) {
      if (d.localName != d.cloudName) {
        lines.add('name:${d.localName}->${d.cloudName}');
      }
      if (d.localMonthStartDay != d.cloudMonthStartDay) {
        lines.add('monthStart:${d.localName}:'
            '${d.localMonthStartDay}->${d.cloudMonthStartDay}');
      }
    }
    return (title: 'meta-diff-title', lines: lines, action: 'meta-diff-action');
  }

  @override
  String getUnknownDiffHint(int count) => 'unknown-diff:$count';

  /// P1-3 埋点补缺：测试桩默认无 metrics（no-op 埋点）。
  /// 需要断言指标写入的用例覆写本 getter 注入记录器。
  _RecordingMetrics? metricsOverride;

  @override
  SyncMetricsService? get metrics => metricsOverride;

  @override
  void log(String message) {
    errorLog.add(message);
  }
}

/// P1-3 埋点测试记录器：只实现 record（runIfNeeded 的 finally 只调它）；
/// 其余成员按接口要求提供空实现。db 字段提供不可用占位（本记录器
/// 不落库），retention 常量经类静态成员继承不可行（implements），显式补。
class _RecordingMetrics implements SyncMetricsService {
  final records = <SyncOpRecord>[];

  @override
  PiggyDatabase get db =>
      throw UnsupportedError('recording stub has no db');

  @override
  Future<void> record(SyncOpRecord r) async => records.add(r);

  @override
  void recordUnawaited(SyncOpRecord r) => records.add(r);

  @override
  Future<SyncHealthSummary> summarize(
      {Duration window = const Duration(days: 30), String? backend}) async {
    return const SyncHealthSummary();
  }

  @override
  Future<List<({String errorClass, int count})>> topErrorClasses(
      {Duration window = const Duration(days: 30), int limit = 5}) async {
    return const [];
  }

  @override
  Future<int> cleanupExpired() async => 0;

  @override
  Future<List<Map<String, dynamic>>> exportJson(
      {Duration window = const Duration(days: 30)}) async {
    return const [];
  }
}
