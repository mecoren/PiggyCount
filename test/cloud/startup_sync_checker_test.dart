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

  Ledger _ledger(int id, String name) => Ledger(
        id: id,
        name: name,
        currency: 'CNY',
        type: 'general',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      );

  SyncStatus _status(SyncDiff diff, {String? message}) => SyncStatus(
        diff: diff,
        localCount: 0,
        localFingerprint: 'local-fp',
        message: message,
      );

  SyncPreview _preview({
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

    test('配置为 piggycountCloud 时直接跳过（路径 B 不处理）', () async {
      deps.activeConfig = const CloudServiceConfig(
        type: CloudBackendType.piggycountCloud,
        name: 'piggycount',
        piggycountCloudBaseUrl: 'https://example.com',
      );

      await checker.runIfNeeded();

      expect(deps.getAllLedgersCalled, isFalse);
      expect(controller.state, isA<DismissedState>());
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
      deps.ledgers = [_ledger(1, 'L1')];
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.statusByLedger = {
        1: _status(SyncDiff.inSync),
        2: _status(SyncDiff.inSync),
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
        _ledger(1, 'L1'),
        _ledger(2, 'L2'),
        _ledger(3, 'L3'),
      ];
      deps.statusByLedger = {
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.inSync),
        3: _status(SyncDiff.different),
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
        _ledger(1, 'L1'),
        _ledger(2, 'L2'),
        _ledger(3, 'L3'),
      ];
      deps.statusByLedger = {
        1: _status(SyncDiff.noRemote),
        2: _status(SyncDiff.localNewer),
        3: _status(SyncDiff.notLoggedIn),
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
        _ledger(1, 'L1'),
        _ledger(2, 'L2'),
      ];
      deps.statusByLedger = {
        1: _status(SyncDiff.inSync),
        // P1-3 补强：非哨兵 error（网络/超时）绝不能静默计入"已是最新"，
        // 否则全部失败时用户被误报"已全部同步"
        2: _status(SyncDiff.error, message: 'Connection timeout'),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.lastCandidates, isEmpty);
      // 失败账本存在：进入 ErrorState 而非 DoneState
      expect(controller.state, isA<ErrorState>());
      expect((controller.state as ErrorState).message,
          contains('请检查网络后重试'));
      expect((controller.state as ErrorState).message, contains('1 个账本'));
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
        _ledger(1, 'L1'),
      ];
      // WebDAV 401/403 被识别为认证失败：处置动作是改凭据而非重试网络，
      // 文案必须区分，避免误导用户排查方向
      deps.statusByLedger = {
        1: _status(SyncDiff.error, message: 'CloudAuthException: 401 Unauthorized'),
      };
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(controller.state, isA<ErrorState>());
      expect((controller.state as ErrorState).message,
          contains('云端认证失败'));
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.statusByLedger = {2: _status(SyncDiff.cloudNewer)};
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.statusByLedger = {
        1: _status(SyncDiff.inSync),
        2: _status(SyncDiff.inSync),
      };
      deps.summaryChoice = SummaryChoice.skip;

      final states = <StartupSyncState>[];
      controller.addListener(() => states.add(controller.state));

      await checker.runIfNeeded();

      // 应该有 CheckingState 出现
      expect(states.any((s) => s is CheckingState), isTrue);
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.statusByLedger = {
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.cloudNewer),
      };
      deps.summaryChoice = SummaryChoice.applyAll;
      deps.previewByLedger = {
        1: (
          preview: _preview(added: 2, modified: 1),
          importData: const ImportData(),
          version: 6,
        ),
        2: (
          preview: _preview(deleted: 3),
          importData: const ImportData(),
          version: 6,
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
    });

    test('每次 apply 后触发 runAfterDownload', () async {
      deps.previewByLedger[2] = (
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
      );
      await checker.runIfNeeded();

      expect(deps.runAfterDownloadCallCount, 2);
    });

    test('合并成功后对每个账本回传云端（merge-then-publish）', () async {
      deps.previewByLedger[2] = (
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
      );
      await checker.runIfNeeded();

      // 只下载合并不回传时指纹永不收敛，下次启动会重复弹「云端有更新」
      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('两阶段：全部账本合并完成后才统一回传（sync_convergence_fix）',
        () async {
      deps.previewByLedger[2] = (
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
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
        1: (preview: null, importData: const ImportData(), version: 5),
        2: (preview: null, importData: const ImportData(), version: 5),
      };

      await checker.runIfNeeded();

      expect(deps.downloadAndRestoreCallCount, 2);
      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('S14: 用户拒绝 legacy 全量替换确认 → 跳过该账本不回传', () async {
      deps.previewByLedger = {
        1: (preview: null, importData: const ImportData(), version: 5),
        2: (preview: _preview(added: 1), importData: const ImportData(), version: 6),
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
        1: (preview: null, importData: const ImportData(), version: 5),
      };
      deps.legacyReplaceConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.legacyReplaceConfirmCallCount, 1);
      expect(deps.downloadAndRestoreCallCount, 1);
      expect(deps.uploadedLedgerIds, [1]);
    });

    test('preview.isEmpty 合并元数据后同样回传', () async {
      deps.previewByLedger = {
        1: (preview: _preview(), importData: const ImportData(), version: 6),
        2: (preview: _preview(), importData: const ImportData(), version: 6),
      };

      await checker.runIfNeeded();

      expect(deps.uploadedLedgerIds, [1, 2]);
    });

    test('回传失败不影响合并结果，汇总提示回传失败', () async {
      deps.uploadThrowForLedgerIds = {1};
      deps.previewByLedger[2] = (
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
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
        2: (preview: _preview(added: 1), importData: const ImportData(), version: 6),
      };

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1);
      expect(deps.uploadedLedgerIds, [2]);
    });

    test('最后状态为 DoneState 显示汇总结果', () async {
      deps.previewByLedger[2] = (
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
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
        1: (preview: null, importData: const ImportData(), version: 5),
        2: (preview: _preview(added: 1), importData: const ImportData(), version: 6),
      };

      await checker.runIfNeeded();

      expect(deps.downloadAndRestoreCallCount, 1);
      expect(deps.applyPreviewChangesCallCount, 1);
    });

    test('preview.isEmpty 的账本仍调用 applyPreviewChanges 合并元数据（G5）', () async {
      // 纯账户变更场景：交易 diff 为空，但云端 importData 携带新账户。
      // 旧行为直接 continue 导致账户永远不落库（account_metadata_sync_fix G5）。
      deps.previewByLedger = {
        1: (preview: _preview(), importData: const ImportData(), version: 6),
        2: (preview: _preview(added: 1), importData: const ImportData(), version: 6),
      };

      await checker.runIfNeeded();

      // L1 空预览也要走一次空变更 apply（元数据合并）；L2 走正常 apply
      expect(deps.applyPreviewChangesCallCount, 2);
      expect(deps.appliedForLedger[1]!, isEmpty);
      expect(deps.appliedForLedger[2]!.length, 1);
    });

    test('全部账本 preview.isEmpty 时均合并元数据并计入成功', () async {
      deps.previewByLedger = {
        1: (preview: _preview(), importData: const ImportData(), version: 6),
        2: (preview: _preview(), importData: const ImportData(), version: 6),
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
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
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
        preview: _preview(deleted: 3, selectDeleted: true),
        importData: const ImportData(),
        version: 6,
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.summaryChoice = SummaryChoice.applyAll;
      deps.previewByLedger = {
        1: (
          preview: _preview(added: 1),
          importData: const ImportData(),
          version: 6,
        ),
        2: (
          preview: _preview(added: 1),
          importData: const ImportData(),
          version: 6,
        ),
      };
    });

    test('AC-7.6: 全 cloudNewer 不弹二次确认对话框', () async {
      deps.statusByLedger = {
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.cloudNewer),
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
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.different),
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
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.cloudNewer),
      };
      deps.conflictConfirmReturn = false; // 即使取消也不应被调用

      await checker.runIfNeeded();

      expect(deps.conflictConfirmCallCount, 0);
      expect(deps.applyPreviewChangesCallCount, 2,
          reason: '无冲突候选，applyAll 不应被取消');
      expect(controller.state, isA<DoneState>());
    });

    test('AC-7.4: 多个 different 账本均不收集，仅 apply cloudNewer 账本', () async {
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2'), _ledger(3, 'L3')];
      deps.statusByLedger = {
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.different),
        3: _status(SyncDiff.different),
      };
      deps.previewByLedger = {
        1: (
          preview: _preview(added: 1),
          importData: const ImportData(),
          version: 6,
        ),
        2: (
          preview: _preview(added: 1),
          importData: const ImportData(),
          version: 6,
        ),
        3: (
          preview: _preview(added: 1),
          importData: const ImportData(),
          version: 6,
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
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.different),
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
      deps.ledgers = [_ledger(1, 'L1'), _ledger(2, 'L2')];
      deps.statusByLedger = {
        1: _status(SyncDiff.cloudNewer),
        2: _status(SyncDiff.cloudNewer),
      };
      deps.summaryChoice = SummaryChoice.confirmEach;
      deps.previewByLedger = {
        1: (
          preview: _preview(added: 2),
          importData: const ImportData(),
          version: 6,
        ),
        2: (
          preview: _preview(modified: 1),
          importData: const ImportData(),
          version: 6,
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
          preview: _preview(added: 1, deleted: 1),
          importData: const ImportData(),
          version: 6,
        ),
      };
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.cloudNewer)};
      deps.perLedgerChoice = LedgerDialogChoice.viewDetail;
      // 模拟弹窗返回：仅返回用户勾选的 added（deleted 保持未勾选）
      deps.syncPreviewReturn = [SyncChange(type: SyncChangeType.added)];

      await checker.runIfNeeded();

      expect(deps.applyPreviewChangesCallCount, 1,
          reason: '合并照常执行');
      expect(deps.uploadedLedgerIds, isEmpty,
          reason: '存在未应用的云端删除时必须跳过回传，'
              '否则本地保留的已删交易随快照复活并传播到所有设备');
    });

    test('S1 守卫：全部删除被勾选应用时正常回传', () async {
      final deletedChange =
          SyncChange(type: SyncChangeType.deleted, selected: true);
      deps.previewByLedger = {
        1: (
          preview: _preview(added: 1, deleted: 1, selectDeleted: true),
          importData: const ImportData(),
          version: 6,
        ),
      };
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.cloudNewer)};
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
        1: (preview: _preview(), importData: const ImportData(), version: 6),
        2: (preview: _preview(added: 1), importData: const ImportData(), version: 6),
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
        1: (preview: null, importData: const ImportData(), version: 5),
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
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.cloudNewer)};
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
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.cloudNewer)};
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
      deps.ledgers = [_ledger(1, 'L1')];
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
      deps.statusAfterSaltMismatch = _status(SyncDiff.cloudNewer);

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
    RemoteLedgerMeta _meta(int id, String name, {int txCount = 3}) =>
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
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.inSync), 2: _status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [_meta(2, 'Remote')];
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
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [_meta(2, 'Remote')];
      deps.newLedgersConfirmReturn = false;

      await checker.runIfNeeded();

      expect(deps.importCallCount, 0);
      expect(controller.state, isA<DoneState>());
    });

    test('US-3: discover 抛异常时静默降级，不阻塞原检查', () async {
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.cloudNewer)};
      deps.discoverThrow = Exception('list failed');
      deps.summaryChoice = SummaryChoice.skip;

      await checker.runIfNeeded();

      expect(deps.discoverCallCount, 1);
      expect(deps.importCallCount, 0);
      // 原流程继续：候选检查照常执行
      expect(deps.lastCandidates.length, 1);
    });

    test('US-3: 单个账本导入失败不影响其他账本', () async {
      deps.ledgers = [_ledger(1, 'L1')];
      deps.statusByLedger = {1: _status(SyncDiff.inSync)};
      deps.remoteLedgerMetas = [_meta(2, 'A'), _meta(3, 'B')];
      deps.importThrowForSlotKeys = {'2'};

      await checker.runIfNeeded();

      expect(deps.importCallCount, 2, reason: '两个账本都尝试导入');
      expect(deps.lastImportedMetas.length, 2);
      expect(controller.state, isA<DoneState>(),
          reason: '单个失败不影响整体流程收尾');
    });

    test('US-1: 本地零账本的全新设备也能发现云端账本', () async {
      deps.ledgers = [];
      deps.remoteLedgerMetas = [_meta(1, 'Only')];
      deps.newLedgersConfirmReturn = true;

      await checker.runIfNeeded();

      expect(deps.discoverCallCount, 1);
      expect(deps.importCallCount, 1,
          reason: '零账本设备不能在 ledgers.isEmpty 处提前跳过');
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

  Map<int, ({SyncPreview? preview, ImportData importData, int version})>
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
  Future<({SyncPreview? preview, ImportData importData, int version})?>
      downloadAndPreview(int ledgerId) async {
    if (downloadAndPreviewThrowForLedgerIds.contains(ledgerId)) {
      throw Exception('downloadAndPreview boom for ledger $ledgerId');
    }
    return previewByLedger[ledgerId];
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

  @override
  void log(String message) {
    errorLog.add(message);
  }
}
