/// rec 12 余量：**账本清空 / 删除**的页面级回归（账本页）。
///
/// 为什么已有的仓储层测试不够：`LocalRepository.deleteLedger` 的单元测试只能
/// 证明「调用它就删干净了」，而真正会伤到用户的东西在**页面接线**上：
///
///  1. **顺序契约**。`_handleDeleteLocalLedger` 里 `sync.deleteRemoteBackup` 必须
///     发生在 `repo.deleteLedger` **之前** —— 云端快照的 storage path 由账本行里的
///     `syncId` 拼出来，行删了就 fallback 到 `id.toString()`，UUID 账本一律 404、
///     快照永远清不掉（用户以为删干净了，换台设备一同步全回来了）。这条注释
///     写的正是本文件 [test] 里最核心的断言。
///  2. **三种删除语义不能串**。清空（留账本删账单）/ 仅删本地（保留云端备份，
///     可恢复）/ 彻底删（本地+云端）在 UI 上只差一个长按菜单项，接线串了就是
///     「用户以为是轻操作，实际云端副本被抹掉」—— 不可逆。
///  3. **双重危险确认不能退化成单击**。两次确认各有独立倒计时，倒计时归零前
///     确认按钮必须是禁用的；一旦有人把 `countdownSeconds` 或 disabled 逻辑改坏，
///     破坏性操作就变成一次误触即执行。
///  4. **删完之后谁负责收尾**。删当前账本要自动切到余下账本（没有余下就让
///     `currentLedgerProvider` 落空，首页胶囊回到「+ 新建账本」）；清空要顺手把
///     `cachedTransactionsProvider` 置空（否则首页继续渲染已删掉的账单）；
///     `ledgerListRefresh` / `statsRefresh` 两个 tick 都要 bump，卡片才会消失。
///
/// 用 `_RecordingSyncManager`（真实 `TransactionsSyncManager` 的子类）而不是手写
/// `SyncService` stub：页面用它做 `is TransactionsSyncManager` 的类型门禁来决定
/// 「上传」类入口是否渲染，stub 会让这些入口整批消失、测了个空壳。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs
    hide SyncStatus;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/cloud/transactions_sync_manager.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/ledger_display_item.dart';
import 'package:piggycount/pages/main/ledgers_page_new.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/statistics_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/providers/ui_state_providers.dart';
import 'package:piggycount/widgets/biz/ledger_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late _RecordingRepo repo;
  late _RecordingSyncManager sync;
  late List<String> callLog;

  setUp(() async {
    callLog = <String>[];
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = _RecordingRepo(db, callLog);
    sync = _RecordingSyncManager(db: db, repo: repo, log: callLog);
    // 两个账本：跨账本断言（切账本 / 不波及其他账本）要用
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
    // 每账本各一笔账单：清空/删除都必须连带处理它们，且不得误伤另一个账本
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: 10.0,
          happenedAt: d.Value(DateTime(2026, 9, 1)),
          syncId: const d.Value('tx-a'),
        ));
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 2,
          type: 'expense',
          amount: 20.0,
          happenedAt: d.Value(DateTime(2026, 9, 2)),
          syncId: const d.Value('tx-b'),
        ));
  });

  tearDown(() async {
    await sync.dispose();
    await db.close();
  });

  AppLocalizations zh(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(LedgersPageNew).first));

  /// 直接查库，而不是问 mock —— 破坏性操作的正确性最终只能由落库状态背书。
  Future<bool> ledgerExists(int id) async {
    final row = await (db.select(db.ledgers)..where((l) => l.id.equals(id)))
        .getSingleOrNull();
    return row != null;
  }

  Future<int> txCount(int ledgerId) async {
    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(ledgerId)))
        .get();
    return rows.length;
  }

  /// 挂载账本页。
  ///
  /// `remoteLedgersProvider` 必须覆盖：真实实现会去读云服务配置
  /// （`activeCloudConfigProvider` → 安全存储/偏好）。本组用例只关心**本地**
  /// 账本的破坏性路径，远程列表固定给空。
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

  /// 有界推进若干帧 —— 本文件一律**不**用 `pumpAndSettle` 收尾。
  ///
  /// 危险确认弹窗的「确认」按钮带 `Timer.periodic` 倒计时、Toast 有 2s 生存期，
  /// 这些都不是「会收敛的动画」，`pumpAndSettle` 要么等超时要么把待断言的东西
  /// 一起等没。按固定步长推进即可精确控制时间轴。
  Future<void> pumpFrames(
    WidgetTester tester, {
    int frames = 12,
    Duration step = const Duration(milliseconds: 300),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// 按秒推进（危险确认弹窗的倒计时是 1s 一跳的 `Timer.periodic`）。
  Future<void> elapse(WidgetTester tester, int seconds) async {
    for (var i = 0; i < seconds; i++) {
      await tester.pump(const Duration(seconds: 1));
    }
  }

  /// 只推进转场动画（pop + push 共 400ms），**刻意不足 1 秒**：
  /// 这样新弹出来的危险确认框倒计时还没跳过一秒，`_remaining` 仍是初始值，
  /// 才能断言「倒计时未结束时确认按钮禁用」。
  Future<void> settleTransition(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Finder cardFor(int id) => find.byWidgetPredicate(
        (w) => w is LedgerCard && w.ledger.id == id,
        description: 'LedgerCard(id=$id)',
      );

  /// 长按账本卡片 → 点菜单项 → 等危险确认框出现（倒计时尚在起点）。
  Future<void> openDangerDialog(
    WidgetTester tester,
    String menuLabel, {
    required int targetId,
  }) async {
    await tester.longPress(cardFor(targetId));
    await tester.pumpAndSettle();
    await tester.tap(find.text(menuLabel));
    await settleTransition(tester);
  }

  /// 走完 `showDoubleDangerConfirmDialog` 的两关（各等倒计时归零后点确认）。
  ///
  /// 刻意不中断两关之间的等待：`countdownSeconds` 与页面接线一致才有意义，
  /// 若有人把倒计时改短/改长，这里会直接表现为点不到确认按钮。
  /// [confirmLabel] 默认为「确定」；账本删除两处入口传的是红色「删除」。
  Future<void> confirmTwice(
    WidgetTester tester, {
    int countdownSeconds = 5,
    String? confirmLabel,
  }) async {
    final label = confirmLabel ?? zh(tester).commonConfirm;
    for (var gate = 0; gate < 2; gate++) {
      await elapse(tester, countdownSeconds);
      await tester.tap(find.text(label));
      await settleTransition(tester);
    }
  }

  /// 在 Toast 还活着的时候断言它。
  ///
  /// Toast 生存期 2s，而删除/清空路径的收尾断言（卡片消失、落库状态、tick）
  /// 需要推进更久 —— 一把推到底再断言文案，Toast 早没了，得到的是「找不到文案」
  /// 这种看着像功能坏了的**假失败**。所以先推到 2s 窗口内断言文案，再继续推进。
  Future<void> expectToast(WidgetTester tester, String text) async {
    await pumpFrames(tester, frames: 4);
    expect(find.text(text), findsOneWidget);
  }

  group('AC-R12 清空账本（删账单留账本）', () {
    testWidgets('第一关就取消 → 账单与账本均原封不动', (tester) async {
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersClear, targetId: 1);
      await tester.tap(find.text(zh(tester).commonCancel));
      await pumpFrames(tester, frames: 6);

      expect(await ledgerExists(1), isTrue);
      expect(await txCount(1), 1, reason: '取消后一条账单都不能少');
      expect(await txCount(2), 1);
      expect(sync.remoteBackupCalls, isEmpty);
      await drainTimers(tester);
    });

    testWidgets('只过第一关、第二关取消 → 仍然什么都不删', (tester) async {
      // 双重确认的全部价值就在这条：第一关放行**不等于**可以动手。
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersClear, targetId: 1);
      await elapse(tester, 5);
      await tester.tap(find.text(zh(tester).commonConfirm));
      await settleTransition(tester);
      await tester.tap(find.text(zh(tester).commonCancel));
      await pumpFrames(tester, frames: 6);

      expect(await txCount(1), 1,
          reason: '第二关取消 = 用户反悔，此时数据必须还在（双重确认退化成单击是本条要拦的事）');
      expect(await ledgerExists(1), isTrue);
      expect(sync.remoteBackupCalls, isEmpty);
      await drainTimers(tester);
    });

    testWidgets('两关都确认 → 账单清空、账本保留、缓存失效、tick 刷新、提示「账本已清空」', (tester) async {
      final container = await pumpPage(tester);
      // 预置首页缓存：清空后必须失效，否则首页继续渲染已经不存在的账单
      container.read(cachedTransactionsProvider.notifier).state =
          <TransactionDisplayItem>[];
      final listTickBefore = container.read(ledgerListRefreshProvider);
      final statsTickBefore = container.read(statsRefreshProvider);

      await openDangerDialog(tester, zh(tester).ledgersClear, targetId: 1);
      await confirmTwice(tester);
      await expectToast(tester, zh(tester).ledgersClearSuccess);
      await pumpFrames(tester, frames: 8);

      expect(await ledgerExists(1), isTrue, reason: '清空 ≠ 删除：账本本身必须留下');
      expect(await txCount(1), 0, reason: '账本甲账单应被清空');
      expect(await txCount(2), 1, reason: '只能清空目标账本，不得波及账本乙');
      expect(container.read(cachedTransactionsProvider), isNull,
          reason: '不清缓存 → 首页仍显示已删掉的账单，用户以为清空失败');
      expect(container.read(ledgerListRefreshProvider),
          greaterThan(listTickBefore),
          reason: '不刷新列表 → 卡片上的统计数字还是清空前的老值');
      expect(
          container.read(statsRefreshProvider), greaterThan(statsTickBefore));
      expect(sync.remoteBackupCalls, isEmpty, reason: '清空账单不该动云端备份');
      await drainTimers(tester);
    });
  });

  group('AC-R12 仅删除本地账本（云端备份必须保留）', () {
    testWidgets('确认删除 → 本地行与账单消失，且**绝不调用** deleteRemoteBackup', (tester) async {
      // 本组最核心的一条负向断言：这个入口存在的前提就是「云端那份还在」。
      // 一旦误调 deleteRemoteBackup，用户点了一个看起来可恢复的按钮，
      // 实际云端唯一副本被抹掉 —— 不可逆。
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersDeleteLocal,
          targetId: 2);
      expect(find.text(zh(tester).dangerConfirmCountdown(3)), findsOneWidget,
          reason: '「仅删本地」云端副本仍在，风险低于彻底删除 → 倒计时更短（3s）');
      await confirmTwice(tester,
          countdownSeconds: 3, confirmLabel: zh(tester).commonDelete);
      await expectToast(tester, zh(tester).ledgersDeleteLocalSuccess);
      await pumpFrames(tester, frames: 8);

      expect(await ledgerExists(2), isFalse);
      expect(await txCount(2), 0, reason: '账本行删了，其账单不能剩孤儿行');
      expect(await ledgerExists(1), isTrue);
      expect(sync.remoteBackupCalls, isEmpty,
          reason: '「仅删除本地」的语义就是云端备份保留 —— 调了就永远恢复不回来');
      expect(callLog, contains('repo.deleteLedger(2)'));
      await drainTimers(tester);
    });

    testWidgets('删的是当前账本且还有别的 → 自动切到余下第一个', (tester) async {
      final container = await pumpPage(tester);
      // riverpod 3：页面未 watch currentLedgerProvider 时它处于 paused 状态，
      // 单独 `read(.future)` 会永远停在 loading（2.x 里 read 会顺带初始化）。
      final ledgerSub = container.listen(currentLedgerProvider, (_, __) {});
      addTearDown(ledgerSub.close);
      await container.read(currentLedgerProvider.future);
      expect(container.read(currentLedgerIdProvider), 1);

      await openDangerDialog(tester, zh(tester).ledgersDeleteLocal,
          targetId: 1);
      await confirmTwice(tester,
          countdownSeconds: 3, confirmLabel: zh(tester).commonDelete);
      await pumpFrames(tester, frames: 10);

      expect(container.read(currentLedgerIdProvider), 2,
          reason: '不切账本 → 首页指向一个已不存在的账本，进账/统计全线报错');
      expect((await container.read(currentLedgerProvider.future))?.id, 2);
      expect(await ledgerExists(1), isFalse);
      await drainTimers(tester);
    });

    testWidgets('删的是唯一账本 → id 保持原地，但 currentLedger 落空（首页回「+ 新建账本」）',
        (tester) async {
      // 允许删完所有账本的语义：`currentLedgerProvider` 查不到行必须推 null，
      // 否则首页胶囊会显示一个幽灵账本。
      await repo.deleteLedger(2);
      final container = await pumpPage(tester);
      // 同上：先订阅保活再读 .future（riverpod 3 的 paused 语义）。
      final ledgerSub = container.listen(currentLedgerProvider, (_, __) {});
      addTearDown(ledgerSub.close);
      await container.read(currentLedgerProvider.future);

      await openDangerDialog(tester, zh(tester).ledgersDeleteLocal,
          targetId: 1);
      await confirmTwice(tester,
          countdownSeconds: 3, confirmLabel: zh(tester).commonDelete);
      await pumpFrames(tester, frames: 10);

      expect(container.read(currentLedgerIdProvider), 1,
          reason: '没有别的账本可切，id 只能留在原地');
      expect(await container.read(currentLedgerProvider.future), isNull,
          reason: 'currentLedgerProvider 必须推送 null，首页胶囊才会回到「+ 新建账本」');
      expect(await ledgerExists(1), isFalse);
      await drainTimers(tester);
    });
  });

  group('AC-R12 删除账本（本地 + 云端）', () {
    testWidgets('deleteRemoteBackup 必须早于 deleteLedger，且调用时账本行仍在',
        (tester) async {
      // 这是 `_handleDeleteLocalLedger` 里那条注释的可执行版本：
      // storage path 由账本行的 syncId 拼出，行删了就 fallback 到 id.toString()，
      // UUID 账本 404 → 云端快照永远清不掉，用户换台设备同步回来「已删除的账本」。
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersDelete, targetId: 2);
      await confirmTwice(tester, confirmLabel: zh(tester).commonDelete);
      await pumpFrames(tester, frames: 10);

      final remoteIdx = callLog.indexOf('sync.deleteRemoteBackup(2)');
      final localIdx = callLog.indexOf('repo.deleteLedger(2)');
      expect(remoteIdx, isNonNegative, reason: '彻底删除必须真的去删云端备份');
      expect(localIdx, isNonNegative);
      expect(remoteIdx, lessThan(localIdx),
          reason: '顺序写反 → 云端快照清不掉（见 handler 内注释）');
      expect(sync.ledgerExistedAtRemoteBackup, isTrue,
          reason: '删云端备份时账本行必须还在，否则 syncId 查不到、storage path 拼错');
      expect(await ledgerExists(2), isFalse);
      await drainTimers(tester);
    });

    testWidgets('删除成功后 → 卡片消失、tick 刷新、提示「已删除」', (tester) async {
      final container = await pumpPage(tester);
      final listTickBefore = container.read(ledgerListRefreshProvider);
      final statsTickBefore = container.read(statsRefreshProvider);
      expect(cardFor(2), findsOneWidget);

      await openDangerDialog(tester, zh(tester).ledgersDelete, targetId: 2);
      await confirmTwice(tester, confirmLabel: zh(tester).commonDelete);
      await expectToast(tester, zh(tester).ledgersDeleted);
      await pumpFrames(tester, frames: 8);

      expect(cardFor(2), findsNothing, reason: '不刷新列表 → 卡片还在，用户以为没删掉会再删一次');
      expect(cardFor(1), findsOneWidget, reason: '不得误删另一个账本');
      expect(container.read(ledgerListRefreshProvider),
          greaterThan(listTickBefore));
      expect(
          container.read(statsRefreshProvider), greaterThan(statsTickBefore));
      await drainTimers(tester);
    });
  });

  group('AC-R12 危险确认弹窗本身（两次确认 / 倒计时）', () {
    testWidgets('倒计时未结束时确认按钮禁用，归零后才放行', (tester) async {
      // 这条守的是「破坏性操作不能被一次误触执行」：只要 disabled 逻辑被改坏，
      // 两个确认关口就等价于一个，长按菜单 + 一次点击就能删账本。
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersDelete, targetId: 2);

      final l10n = zh(tester);
      final countingFinder =
          find.widgetWithText(TextButton, l10n.dangerConfirmCountdown(5));
      expect(countingFinder, findsOneWidget,
          reason: '倒计时期间按钮文案应显示剩余秒数（同步暴露给用户「还不能点」）');
      expect(tester.widget<TextButton>(countingFinder).onPressed, isNull,
          reason: '倒计时未结束 → 确认按钮必须禁用，否则双重确认退化为一次误触');
      expect(await ledgerExists(2), isTrue, reason: '此时弹窗还开着，绝不能已经开始删');

      await elapse(tester, 5);

      final readyFinder = find.widgetWithText(TextButton, l10n.commonDelete);
      expect(tester.widget<TextButton>(readyFinder).onPressed, isNotNull,
          reason: '倒计时归零后应放行');

      await tester.tap(find.text(l10n.commonCancel));
      await pumpFrames(tester, frames: 6);
      expect(await ledgerExists(2), isTrue);
      await drainTimers(tester);
    });

    testWidgets('云端备份删除失败被吞掉，本地删除照常完成', (tester) async {
      // handler 里 deleteRemoteBackup 是 try/catch 忽略的：网络抖一下不该让
      // 用户点了「删除」却什么都没发生（本地迭代不动、还得多点一次）。
      sync.failRemoteBackup = true;
      await pumpPage(tester);

      await openDangerDialog(tester, zh(tester).ledgersDelete, targetId: 2);
      await confirmTwice(tester, confirmLabel: zh(tester).commonDelete);
      await expectToast(tester, zh(tester).ledgersDeleted);
      await pumpFrames(tester, frames: 8);

      expect(sync.remoteBackupCalls, [2], reason: '云端删除被尝试过（并失败了）');
      expect(await ledgerExists(2), isFalse,
          reason: '云端删失败不能连累本地删除 —— 用户点了删除就该删掉本地');
      expect(await txCount(2), 0);
      await drainTimers(tester);
    });
  });
}

/// 记录 `deleteLedger` 调用顺序的仓储。
///
/// 顺序契约（`sync.deleteRemoteBackup` 早于 `repo.deleteLedger`）需要**跨对象**
/// 的调用序列才能验证，所以与 [_RecordingSyncManager] 共用一个 `callLog`。
class _RecordingRepo extends LocalRepository {
  _RecordingRepo(super.db, this.log);

  final List<String> log;

  @override
  Future<void> deleteLedger(int id) async {
    log.add('repo.deleteLedger($id)');
    await super.deleteLedger(id);
  }
}

/// 记录云端删除调用并可控抛错的同步服务。
///
/// 继承**真实** `TransactionsSyncManager`：页面用 `is TransactionsSyncManager`
/// 决定云端相关入口是否渲染，手写 `SyncService` stub 会让入口整批消失。
class _RecordingSyncManager extends TransactionsSyncManager {
  _RecordingSyncManager({
    required super.db,
    required super.repo,
    required this.log,
  }) : super(
          config: const fcs.CloudServiceConfig(
            type: fcs.CloudBackendType.s3,
            name: 'test',
          ),
        );

  final List<String> log;

  /// 每次 `deleteRemoteBackup` 的 ledgerId，按调用顺序记录。
  final List<int> remoteBackupCalls = <int>[];

  /// `deleteRemoteBackup` 被调用**那一刻**账本行是否还在。
  ///
  /// 这是页面注释「此刻 ledger 行还在,deleteRemoteBackup 内部能查到 syncId 构造
  /// 正确的 storage path」的可执行版本 —— 直接查库取样，不依赖 mock 时序。
  bool? ledgerExistedAtRemoteBackup;

  /// true：云端删除抛异常（模拟网络/权限失败）。
  bool failRemoteBackup = false;

  @override
  Future<void> deleteRemoteBackup({required int ledgerId}) async {
    remoteBackupCalls.add(ledgerId);
    log.add('sync.deleteRemoteBackup($ledgerId)');
    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(ledgerId)))
        .getSingleOrNull();
    ledgerExistedAtRemoteBackup = row != null;
    if (failRemoteBackup) throw Exception('cloud delete failed');
  }

  @override
  Future<SyncStatus> getStatus({required int ledgerId}) async => SyncStatus(
        diff: SyncDiff.inSync,
        localCount: 1,
        cloudCount: 1,
        // 页面在冲突框里取指纹前 8 位展示（substring(0, 8)），必须给足长度
        localFingerprint: 'aaaaaaaa111111112222222233333333',
        cloudFingerprint: 'aaaaaaaa111111112222222233333333',
        cloudExportedAt: DateTime(2026, 9, 1, 10),
      );
}
