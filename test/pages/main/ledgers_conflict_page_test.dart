/// rec 12 余量：**同步冲突**的页面级回归（账本页）。
///
/// 为什么已有的 `test/widgets/upload_conflict_guard_test.dart` 不够：
/// 那个文件测的是冲突守卫**组件本身**（三选一弹框的返回值语义）。而真正会
/// 伤到用户的东西在**页面接线**上，组件测试一条都覆盖不到：
///
///  1. **进度弹窗必须先关再弹确认框**。`_handleUploadLedger` 的 `attempt()` 里
///     `finally { await block.close(); }` + `rethrow` 是刻意写的顺序 —— 阻塞遮罩
///     是 `barrierDismissible: false` 的全屏弹窗，顺序写反用户根本点不到确认框
///     （表现为「点了上传没反应」），组件测试看不见这条。
///  2. **谁负责刷新**。上传成功后 `ledgerListRefresh` + `syncStatusRefresh` 各
///     +1，卡片状态才会消失；漏掉就是「上传成功但界面还显示冲突」，用户会重复点。
///  3. **softFail 的差异化文案**（`verified=false` → 「已上传但未确认收敛」而非
///     「已上传」）—— 只有页面里那三个分支合起来才成立。
///  4. **无冲突时不得弹冲突框**。误报的代价是全量用户被吓一次。
///
/// 用 `_RecordingSyncManager`（真实 `TransactionsSyncManager` 的子类）而不是
/// 手写 `SyncService` stub：页面用它做 `is TransactionsSyncManager` 的类型门禁
/// 来决定「上传」入口是否出现，stub 会让这些入口整批消失、测了个空壳。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs hide SyncStatus;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_diff_service.dart' show SyncPreview;
import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/ledger_display_item.dart';
import 'package:piggycount/pages/main/ledgers_page_new.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/services/data_import_service.dart' show ImportData;
import 'package:piggycount/widgets/biz/ledger_card.dart';
import 'package:piggycount/widgets/ui/dialog.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late _RecordingSyncManager sync;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    sync = _RecordingSyncManager(db: db, repo: repo);
    // 两个账本：跨账本切账本断言要用（切到**另一个**账本才有可观测变化）
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '账本甲',
          currency: const d.Value('CNY'),
        ));
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(2),
          name: '账本乙',
          currency: const d.Value('CNY'),
        ));
  });

  tearDown(() async {
    await sync.dispose();
    await db.close();
  });

  AppLocalizations zh(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(LedgersPageNew).first));

  /// 挂载账本页。
  ///
  /// `remoteLedgersProvider` 必须覆盖：真实实现会去读云服务配置
  /// （`activeCloudConfigProvider` → 安全存储/偏好）。本组用例只关心**本地**
  /// 账本上的冲突路径，远程列表固定给空。
  Future<ProviderContainer> pumpPage(WidgetTester tester) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      syncServiceProvider.overrideWithValue(sync),
      remoteLedgersProvider
          .overrideWith((ref) async => const <LedgerDisplayItem>[]),
    ]);
    addTearDown(container.dispose);
    // 预热本地列表：页面首帧就要渲染卡片，否则拿到 loading 态只剩骨架屏
    await container.read(localLedgersProvider.future);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const LedgersPageNew(),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// Toast 与 LoggerService 都带 2s 定时器，用例收尾必须跑完，
  /// 否则 flutter_test 会以「树已销毁却仍有 pending timer」判失败。
  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  /// 有界推进若干帧 —— 上传路径上**不能**用 `pumpAndSettle`。
  ///
  /// 单账本上传期间 `uploadingLedgerIdsProvider` 里有本账本 id，`LedgerCard` 据此
  /// 挂一个「上传中」进度圈；该 id 的移除在 `_handleUploadLedger` 的 `finally` 里，
  /// 而 `await` 此刻正卡在确认框上等用户选择 —— 即**上传确实还没结束**，进度圈是
  /// 刻意保留的。进度圈属无限动画，`pumpAndSettle` 会一直等到假时钟超时（实测
  /// 直接 `pumpAndSettle timed out`）。所以这里按固定步长推进，而不是等它 settle。
  ///
  /// 默认 12 × 300ms：足够覆盖「关阻塞遮罩 → 弹确认框」的全部转场，且顺手把
  /// LoggerService 的 2s 节流落盘定时器跑完。
  Future<void> pumpFrames(
    WidgetTester tester, {
    int frames = 12,
    Duration step = const Duration(milliseconds: 300),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  Finder cardFor(int id) => find.byWidgetPredicate(
        (w) => w is LedgerCard && w.ledger.id == id,
        description: 'LedgerCard(id=$id)',
      );

  group('AC-R12 冲突卡片（点账本卡片）', () {
    testWidgets('无冲突时点账本 → 不弹冲突框，正常切账本', (tester) async {
      sync.statusDiff = SyncDiff.inSync;
      final container = await pumpPage(tester);

      await tester.tap(cardFor(2));
      await tester.pumpAndSettle();

      expect(find.text(zh(tester).ledgersConflictTitle), findsNothing,
          reason: '误报冲突的代价是全量用户被吓一次 —— 非冲突状态绝不能进冲突分支');
      expect(container.read(currentLedgerIdProvider), 2,
          reason: '应走正常切账本分支');
      await drainTimers(tester);
    });

    testWidgets('有冲突时点账本 → 弹冲突解决框（含下载/上传/对比合并）', (tester) async {
      sync.statusDiff = SyncDiff.different;
      await pumpPage(tester);

      await tester.tap(cardFor(2));
      await tester.pumpAndSettle();

      final l10n = zh(tester);
      expect(find.text(l10n.ledgersConflictTitle), findsOneWidget);
      expect(find.text(l10n.ledgersConflictDownload), findsOneWidget);
      expect(find.text(l10n.ledgersConflictUpload), findsOneWidget);
      expect(find.text(l10n.conflictCompareMergeAction), findsOneWidget);
    });

    testWidgets('冲突框「上传到云端」= 用户已明确选择覆盖 → force 上传并刷新列表与状态',
        (tester) async {
      // 这条守的是「上传成功但卡片不消失」类问题：卡片可见性来自
      // syncStatusProvider，只有 bump 了刷新计数用户才看得到状态变化、
      // 才不会对着同一张卡片反复点。
      sync.statusDiff = SyncDiff.different;
      final container = await pumpPage(tester);
      final listTickBefore = container.read(ledgerListRefreshProvider);
      final statusTickBefore = container.read(syncStatusRefreshProvider);

      await tester.tap(cardFor(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text(zh(tester).ledgersConflictUpload));
      await tester.pumpAndSettle();

      expect(sync.uploadForces, [true],
          reason: '冲突框上的上传是用户显式选择本地覆盖云端，必须 force');
      expect(container.read(ledgerListRefreshProvider), greaterThan(listTickBefore),
          reason: '不刷新列表 = 卡片仍显示冲突，用户会重复上传');
      expect(container.read(syncStatusRefreshProvider),
          greaterThan(statusTickBefore));
      await drainTimers(tester);
    });

    testWidgets('冲突框「取消」→ 云端本地均不动，不发起任何上传/下载', (tester) async {
      sync.statusDiff = SyncDiff.different;
      await pumpPage(tester);

      await tester.tap(cardFor(2));
      await tester.pumpAndSettle();
      await tester.tap(find.text(zh(tester).commonCancel));
      await tester.pumpAndSettle();

      expect(sync.uploadForces, isEmpty, reason: '取消后不得有任何上传');
      expect(sync.restoreCalls, 0, reason: '取消后不得有任何下载覆盖');
      expect(sync.mergePreviewCalls, 0);
    });
  });

  group('AC-R12 单账本上传的冲突守卫（长按菜单 → 上传到云端）', () {
    /// 长按卡片 → 操作菜单 →「上传到云端」。返回后菜单应已关闭。
    ///
    /// 菜单本身（`SimpleDialog`）可以 `pumpAndSettle`；点进去之后一律有界推进
    /// （见 [pumpFrames]）——**成功路径也一样**，因为成功/softFail 的 toast 有 2s
    /// 生存期，用 1.5s 有界推进才能既走完转场又让 toast 还在屏上。
    Future<void> tapUploadFromMenu(WidgetTester tester, int id) async {
      await tester.longPress(cardFor(id));
      await tester.pumpAndSettle();
      await tester.tap(find.text(zh(tester).ledgersUploadThis));
      await pumpFrames(tester, frames: 5);
    }

    testWidgets('遇冲突 → 弹三选一，且**阻塞进度弹窗已关闭**', (tester) async {
      // 这是本文件最核心的一条：阻塞遮罩 barrierDismissible=false，
      // 若 attempt() 的 finally close 顺序被改坏，确认框会压在遮罩之下 ——
      // 用户看到「检测到同步冲突」却点不动任何按钮，且没有任何报错。
      sync.statusDiff = SyncDiff.inSync;
      sync.conflictOnFirstTry = true;
      await pumpPage(tester);

      await tapUploadFromMenu(tester, 2);

      final l10n = zh(tester);
      expect(sync.uploadForces, [false],
          reason: '首次是普通上传（不带 force），冲突由后端抛回');
      expect(find.text(l10n.conflictUploadTitle), findsOneWidget);
      expect(find.text(l10n.syncBlockingUploadTitle), findsNothing,
          reason: '阻塞进度弹窗必须在弹确认框之前关掉，否则确认框点不动');
      expect(
        find.descendant(
          of: find.byType(AppDialogShell),
          matching: find.byType(CircularProgressIndicator),
        ),
        findsNothing,
        reason: '确认框里不该还挂着进度圈（= 遮罩没关）',
      );
    });

    testWidgets('三选一选「覆盖上传」→ force 重试一次并提示已上传', (tester) async {
      sync.statusDiff = SyncDiff.inSync;
      sync.conflictOnFirstTry = true;
      final container = await pumpPage(tester);
      final listTickBefore = container.read(ledgerListRefreshProvider);

      await tapUploadFromMenu(tester, 2);
      await tester.tap(find.text(zh(tester).conflictForceUploadAction));
      await pumpFrames(tester, frames: 5);

      expect(sync.uploadForces, [false, true],
          reason: '用户确认覆盖后应以 force 重试且只重试一次');
      expect(find.text(zh(tester).mineUploadSuccess), findsOneWidget);
      expect(container.read(ledgerListRefreshProvider), greaterThan(listTickBefore));
      await drainTimers(tester);
    });

    testWidgets('三选一选「取消」→ 不重试，云端不动', (tester) async {
      sync.statusDiff = SyncDiff.inSync;
      sync.conflictOnFirstTry = true;
      await pumpPage(tester);

      await tapUploadFromMenu(tester, 2);
      await tester.tap(find.text(zh(tester).commonCancel));
      await pumpFrames(tester, frames: 5);

      expect(sync.uploadForces, [false],
          reason: '取消后不得重试（重试 = 静默覆盖云端，正是本守卫要拦的事）');
      expect(find.text(zh(tester).mineUploadSuccess), findsNothing);
      await drainTimers(tester);
    });

    testWidgets('三选一选「对比合并」→ 进入合并流程（走 downloadAndPreview）',
        (tester) async {
      sync.statusDiff = SyncDiff.inSync;
      sync.conflictOnFirstTry = true;
      await pumpPage(tester);

      await tapUploadFromMenu(tester, 2);
      await tester.tap(find.text(zh(tester).conflictCompareMergeAction));
      await pumpFrames(tester, frames: 5);

      expect(sync.mergePreviewCalls, 1,
          reason: '「对比合并」必须真的进合并流程，不能只是关掉弹窗');
      expect(sync.uploadForces, [false],
          reason: '合并流程不覆盖云端 → 不得以 force 补传');
      // 本用例让 downloadAndPreview 返回 null（云端无数据）→ 走兜底提示，
      // 顺带证明「云端没有备份」这条分支有反馈、不静默
      expect(find.text(zh(tester).syncNoCloudBackupMessage), findsOneWidget);
      await drainTimers(tester);
    });

    testWidgets('softFail（verified=false）→ 提示「已上传但未确认收敛」而非普通成功',
        (tester) async {
      // P1-4 的页面级落点：数据已在云端、脏标记未清，文案必须区别于成功，
      // 否则用户以为一切正常、下次启动又看到「云端有更新」。
      sync.statusDiff = SyncDiff.inSync;
      sync.verified = false;
      final container = await pumpPage(tester);
      final listTickBefore = container.read(ledgerListRefreshProvider);

      await tapUploadFromMenu(tester, 2);

      final l10n = zh(tester);
      expect(find.text(l10n.mineUploadUnverified), findsOneWidget);
      expect(find.text(l10n.mineUploadSuccess), findsNothing,
          reason: '未确认收敛不能报普通成功');
      expect(container.read(ledgerListRefreshProvider), greaterThan(listTickBefore),
          reason: 'softFail 仍属「已上传」，列表与状态同样要刷新');
      await drainTimers(tester);
    });

    testWidgets('上传成功（verified=true）→ 普通成功提示', (tester) async {
      sync.statusDiff = SyncDiff.inSync;
      await pumpPage(tester);

      await tapUploadFromMenu(tester, 2);

      expect(find.text(zh(tester).mineUploadSuccess), findsOneWidget);
      expect(zh(tester).mineUploadSuccess, isNot(zh(tester).mineUploadUnverified),
          reason: '两种结果的文案必须能区分（否则这条断言本身失效）');
      await drainTimers(tester);
    });
  });
}

/// 记录调用并可控返回值的同步服务。
///
/// 继承**真实** `TransactionsSyncManager`：页面用 `is TransactionsSyncManager`
/// 决定「上传」入口是否渲染，手写 `SyncService` stub 会让入口整批消失。
/// 被覆盖的四个方法恰好是页面唯一会用到的四个，其余一律不触发（真实实现依赖
/// 云端 provider，测试里没有）。
class _RecordingSyncManager extends TransactionsSyncManager {
  _RecordingSyncManager({required super.db, required super.repo})
      : super(
          config: const fcs.CloudServiceConfig(
            type: fcs.CloudBackendType.s3,
            name: 'test',
          ),
        );

  /// `getStatus` 返回的差异判定。页面用它决定「点账本 → 冲突框 or 切账本」。
  SyncDiff statusDiff = SyncDiff.inSync;

  /// 上传返回值里的 `verified`。false = softFail（已 PUT 但回读指纹不一致）。
  bool verified = true;

  /// true：不带 force 的上传抛 `CloudConflictException`（模拟云端较新的冲突）。
  bool conflictOnFirstTry = false;

  /// 每次上传的 force 实参，按调用顺序记录。
  final List<bool> uploadForces = <bool>[];
  int restoreCalls = 0;
  int mergePreviewCalls = 0;

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async => SyncStatus(
        diff: statusDiff,
        localCount: 2,
        cloudCount: 3,
        // 页面在冲突框里取 localFingerprint 前 8 位展示（substring(0, 8)），
        // 必须给足长度，否则是拿假数据测出假崩溃
        localFingerprint: 'aaaaaaaa111111112222222233333333',
        cloudFingerprint: 'bbbbbbbb111111112222222233333333',
        cloudExportedAt: DateTime(2026, 9, 1, 10),
      );

  @override
  Future<UploadLedgerResult> uploadCurrentLedger({
    required int ledgerId,
    bool force = false,
    bool bypassRestoreGuard = false,
  }) async {
    uploadForces.add(force);
    if (!force && conflictOnFirstTry) {
      // 与生产同源：云端更新方向的冲突（文案走 conflictUploadCloudNewerMessage）
      throw CloudConflictException(direction: 'cloudNewer');
    }
    return (verified: verified);
  }

  @override
  Future<({int inserted, int deletedDup})> downloadAndRestoreToCurrentLedger({
    required int ledgerId,
  }) async {
    restoreCalls++;
    return (inserted: 0, deletedDup: 0);
  }

  @override
  Future<
      ({
        SyncPreview? preview,
        ImportData importData,
        int version,
        String? cloudFingerprint
      })?> downloadAndPreview({required int ledgerId}) async {
    mergePreviewCalls++;
    // 云端无数据：合并流程的兜底分支（有提示、不静默、不崩）
    return null;
  }
}
