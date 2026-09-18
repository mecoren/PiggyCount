/// rec 12 余量：**导入（CSV → 账单）**的页面级回归。
///
/// 覆盖对象是 `ImportConfirmPage`（真正的批量导入在这里执行），以及它与账本页之间
/// 的跨页契约。为什么必须做页面级：
///
///  1. **进门门禁**。第一步（字段映射）的「下一步」有三个分支：无分类列时如果既没有
///     转账列 → 只提示并**停在原地**；有转账列 → **直接开导**（跳过分类映射）。
///     分错支 = 用户点了没反应，或者转账记录被塞进分类映射流程里空跑一轮。
///  2. **结束方式必须匹配结果**。全成功 → toast + 连关两层页面；**有失败或跳过 → 必须
///     弹「导入完成」等用户确认**，并列出被跳过的类型。静默关页 = 用户不知道有记录没导进去。
///  3. **导入窗口内必须锁死按钮**（`importing ? null : ...`），否则连点两次「开始导入」
///     会重复导入。（`NativeDatabase.memory()` 的查询在微任务里就完成，整个导入会
///     在**同一帧内**跑完 —— 用 [_SlowRepo] 制造一段假时钟可控的窗口才断言得到。）
///  4. **进度写在「根容器」**（`ProviderScope.containerOf`），页面被 pop 掉之后仍要
///     继续更新，并把 `ledgerId` 带出去 —— 账本页正是靠这个信号刷新列表（见
///     `ledgers_page_new.dart` 里对 `importProgressProvider` 的 `ref.listen`）。
///  5. **5 秒收尾**：清空全局进度 + bump `statsRefresh`/`syncStatusRefresh` +
///     invalidate `countsForLedgerProvider`。「我的」页的笔数/天数靠这一步才更新。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/ledger_display_item.dart';
import 'package:piggycount/pages/data/import_confirm_page.dart';
import 'package:piggycount/pages/data/import_page.dart' show BillSourceType;
import 'package:piggycount/pages/main/ledgers_page_new.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/import_export_providers.dart';
import 'package:piggycount/providers/statistics_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

/// 全成功：3 条有效账单，含分类列（所以第一步→第二步→开始导入）。
const _csvAllOk = '''
日期,类型,金额,分类,备注
2026-09-01,支出,12.50,餐饮,午饭
2026-09-02,收入,3000,工资,九月
2026-09-03,支出,8.00,交通,地铁
''';

/// 含一条无法识别的类型（`债务`）：会被跳过，因此必须走「导入完成」弹窗而不是 toast。
const _csvWithSkipped = '''
日期,类型,金额,分类
2026-09-01,支出,12.50,餐饮
2026-09-02,债务,100.00,欠款
''';

/// 无分类列、也无转账列 → 点「下一步」只能提示，必须停在第一步。
const _csvNoCategoryNoTransfer = '''
日期,类型,金额,备注
2026-09-01,支出,12.50,午饭
''';

/// 无分类列但有转账列 → 点「下一步」应**直接开导**（跳过分类映射）。
const _csvTransfer = '''
日期,类型,金额,转出账户,转入账户
2026-09-01,转账,100,工资卡,支付宝
''';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late _SlowRepo repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = _SlowRepo(db);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '账本甲',
          currency: const d.Value('CNY'),
        ));
  });

  tearDown(() async => db.close());

  /// l10n 必须从**始终在树上**的元素取：`_HostPage` 是被 opaque 路由盖住的
  /// 底层页面，确认页一旦推上来它就从 Overlay 里移除了（这是 flutter_test 的
  /// 真实行为，不是 bug）；确认页自身又会在导入成功后被 pop。
  /// Navigator 永远在 `Localizations` 之下、与路由生死无关 —— 最稳。
  AppLocalizations zh(WidgetTester tester) =>
      AppLocalizations.of(tester.element(find.byType(Navigator).first));

  Future<int> txCount() async {
    final rows = await db.select(db.transactions).get();
    return rows.length;
  }

  Future<List<String>> txTypes() async {
    final rows = await db.select(db.transactions).get();
    return rows.map((t) => t.type).toList()..sort();
  }

  /// 「数据页」（`_HostPage`）的标识：导入完成后**连 pop 两层**，确认页与
  /// 导入页 stub 都已出栈，最终暴露的是它 —— 断言「回到了数据页」要找这层。
  Finder dataPageButton() => find.byKey(const Key('open-import-page'));

  /// 挂载宿主页（模拟 `DataManagementPage → ImportPage → ImportConfirmPage` 的调用链）。
  ///
  /// 必须下面还压着一层页面：导入成功后代码是**连 pop 两层**，直接把确认页当 `home`
  /// 挂载的话 pop 会把根路由弹掉，测不出「回到了上一页」。
  Future<ProviderContainer> pumpHost(
    WidgetTester tester, {
    required String csvText,
    BillSourceType billType = BillSourceType.generic,
    bool hasHeader = true,
  }) async {
    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
      // 显式给 LocalOnly：否则 syncServiceProvider 会去读安全存储/偏好配置
      syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
      remoteLedgersProvider
          .overrideWith((ref) async => const <LedgerDisplayItem>[]),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: _HostPage(
          csvText: csvText,
          billType: billType,
          hasHeader: hasHeader,
        ),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// 进入确认页，但不等解析完成（用于断言解析中间态）。
  ///
  /// 每层都要「先 build 路由、再把 300ms 转场走完」：`pump()` 零时长**不推进
  /// 假时钟**，转场不推进页面就一直在屏幕外，后续所有 tap 都会落空。
  Future<void> openConfirmPage(WidgetTester tester) async {
    Future<void> pushAndSettle(Key key) async {
      await tester.tap(find.byKey(key));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    await pushAndSettle(const Key('open-import-page'));
    await pushAndSettle(const Key('open-import-confirm'));
  }

  /// 等 `compute()` 的解析结果落地，并把路由转场走完。
  ///
  /// `_parseRowsIsolate` 跑在**真实 isolate** 上，flutter_test 的假时钟推不动它 ——
  /// 只 `pumpAndSettle` 会一直等（表现为超时）。必须用 `tester.runAsync` 把真实事件
  /// 循环转起来；等进度圈消失（= setState 已执行）后才能 `pumpAndSettle`
  /// （进度圈是无限动画，会等到超时）。
  Future<void> settleParsing(WidgetTester tester, {int rounds = 60}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      if (find.byType(CircularProgressIndicator).evaluate().isEmpty) {
        await tester.pumpAndSettle();
        return;
      }
    }
    throw StateError('CSV 解析未在 $rounds 轮内完成');
  }

  /// 有界推进（导入流程上有 Toast 与 5s 收尾定时器，不能用 pumpAndSettle）。
  Future<void> pumpFrames(
    WidgetTester tester, {
    int frames = 12,
    Duration step = const Duration(milliseconds: 300),
  }) async {
    for (var i = 0; i < frames; i++) {
      await tester.pump(step);
    }
  }

  /// 排掉导入收尾的两个定时器：5s「清空进度 + 刷新统计」与 Toast 的 2s。
  /// 不排干净 flutter_test 会以 pending timer 判失败。
  Future<void> drainImportTimers(WidgetTester tester) async {
    await pumpFrames(tester, frames: 24); // 7.2s
  }

  /// 走到第二步并点「开始导入」。
  Future<void> tapStartImport(WidgetTester tester) async {
    await tester.tap(find.text(zh(tester).importNextStep));
    await tester.pumpAndSettle();
    await tester.tap(find.text(zh(tester).importStartImport));
    await tester.pump();
  }

  group('AC-R12 解析与第一步（字段映射）门禁', () {
    testWidgets('解析中先给「准备中…」+ 进度圈，别让用户对着空白页', (tester) async {
      // 解析在真实 isolate 上，首帧必然是 parsing 状态。
      await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);

      expect(find.byType(ImportConfirmPage), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text(zh(tester).importPreparing), findsWidgets);

      // 收尾：让 isolate 结果落地，避免测试结束后才 setState（此时 DB 已 close）。
      await settleParsing(tester);
    });

    testWidgets('解析完成 → 进入字段映射步，表头自动映射到「日期/分类」等字段', (tester) async {
      await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);
      await settleParsing(tester);

      final l10n = zh(tester);
      expect(find.text(l10n.importConfirmMapping), findsOneWidget);
      expect(find.text(l10n.importCategoryMapping), findsNothing,
          reason: '初始应停在第一步，不该直接跳到分类映射');
      // 自动映射的可见证据：下拉里出现 CSV 的表头名（未匹配上时只会显示「自动识别」）。
      // 「日期」同时出现在字段标签、下拉项与预览表头三处，所以只断言「存在」。
      expect(find.text(l10n.importFieldDate), findsWidgets);
      expect(find.text(l10n.importFieldAmount), findsWidgets);
      expect(find.text('餐饮'), findsWidgets, reason: '预览表里应能看到数据行');
    });

    testWidgets('空 CSV → 明确提示「未解析到任何数据」，不崩', (tester) async {
      await pumpHost(tester, csvText: '\n\n');
      await openConfirmPage(tester);
      await settleParsing(tester);

      expect(find.text(zh(tester).importNoDataParsed), findsOneWidget);
    });

    testWidgets('无分类列且无转账列 → 点「下一步」只提示，**停在第一步**', (tester) async {
      // 分错支的表现是「点下一步没反应」或「进了空白的分类映射页」。
      await pumpHost(tester, csvText: _csvNoCategoryNoTransfer);
      await openConfirmPage(tester);
      await settleParsing(tester);

      await tester.tap(find.text(zh(tester).importNextStep));
      await pumpFrames(tester, frames: 4);

      final l10n = zh(tester);
      expect(find.text(l10n.importSelectCategoryFirst), findsOneWidget,
          reason: '要告诉用户为什么点不动，而不是静默无反应');
      expect(find.text(l10n.importCategoryMapping), findsNothing,
          reason: '没有分类列 → 不得进入分类映射步');
      expect(find.text(l10n.importConfirmMapping), findsOneWidget);
      expect(await txCount(), 0, reason: '门禁拦下了就不该有任何写入');
      await drainImportTimers(tester);
    });
  });

  group('AC-R12 第二步（分类映射）与开导分支', () {
    testWidgets('有分类列 → 进入分类映射步，列出源分类名并给「保持原名」选项', (tester) async {
      await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);
      await settleParsing(tester);

      await tester.tap(find.text(zh(tester).importNextStep));
      await tester.pumpAndSettle();

      final l10n = zh(tester);
      expect(find.text(l10n.importCategoryMapping), findsOneWidget);
      expect(find.text(l10n.importConfirmMapping), findsNothing);
      // 三个源分类名都要出现在映射列表里（少一个就少导一批）
      expect(find.text('餐饮'), findsWidgets);
      expect(find.text('工资'), findsWidgets);
      expect(find.text('交通'), findsWidgets);
      expect(find.text(l10n.importKeepOriginalName), findsWidgets,
          reason: '没有「保持原名」= 用户无法把源分类原样建到本地');
      expect(find.text(l10n.importStartImport), findsOneWidget);
      expect(find.text(l10n.importPreviousStep), findsOneWidget);
    });

    testWidgets('无分类列但有转账列 → 点「下一步」直接开导，**跳过**分类映射', (tester) async {
      await pumpHost(tester, csvText: _csvTransfer);
      await openConfirmPage(tester);
      await settleParsing(tester);

      await tester.tap(find.text(zh(tester).importNextStep));
      await tester.pump();

      expect(find.text(zh(tester).importCategoryMapping), findsNothing,
          reason: '纯转账记录没有分类，不该让用户白跑一轮分类映射');
      await drainImportTimers(tester);

      expect(await txCount(), 1);
      expect(await txTypes(), ['transfer']);
    });
  });

  group('AC-R12 导入执行窗口与结束方式', () {
    testWidgets('导入进行中：「开始导入」「上一步」必须禁用，且底部有「导入中」反馈', (tester) async {
      // 防重复导入：连点两次「开始导入」会把同一批账单导两遍。
      await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);
      await settleParsing(tester);
      await tester.tap(find.text(zh(tester).importNextStep));
      await tester.pumpAndSettle();

      await tester.tap(find.text(zh(tester).importStartImport));
      await tester.pump(); // _startImport 已 setState(importing=true)，正卡在假延迟上

      final l10n = zh(tester);
      final startFinder = find.widgetWithText(FilledButton, l10n.importStartImport);
      expect(tester.widget<FilledButton>(startFinder).onPressed, isNull,
          reason: '导入进行中还能再点 = 同一批账单被导入两次');
      final backFinder =
          find.widgetWithText(OutlinedButton, l10n.importPreviousStep);
      expect(tester.widget<OutlinedButton>(backFinder).onPressed, isNull,
          reason: '导入中回上一步会让用户以为改了映射就能重来');
      expect(find.text(l10n.importProgress(0, 0)), findsOneWidget,
          reason: '导入中要有可见反馈（否则用户以为卡死）');

      await drainImportTimers(tester);
      expect(await txCount(), 3);
    });

    testWidgets('可转后台：进度弹窗给「后台导入」，点了直接回数据页、事后不再弹提示',
        (tester) async {
      // 「后台导入」的意义就是不打断用户 —— 若弹窗没关掉或完成时又弹一次提示，
      // 用户会在数据页上莫名收到一个弹窗。
      // 用带转账列的 CSV：它有账户 → importAccounts 会 await getAllAccounts，
      // 被 [_SlowRepo] 撑开一个可观察的窗口。
      await pumpHost(tester, csvText: _csvTransfer);
      await openConfirmPage(tester);
      await settleParsing(tester);

      await tester.tap(find.text(zh(tester).importNextStep));
      await tester.pump(); // 卡在 getLedgerById 的假延迟上
      await tester.pump(const Duration(milliseconds: 400)); // 越过 → 弹进度弹窗

      final l10n = zh(tester);
      expect(find.text(l10n.importInProgress), findsOneWidget);
      expect(find.text(l10n.importBackgroundImport), findsOneWidget);
      expect(find.text(l10n.importCancelImport), findsOneWidget);

      await tester.tap(find.text(l10n.importBackgroundImport));
      await pumpFrames(tester, frames: 4);

      expect(find.byType(ImportConfirmPage), findsNothing,
          reason: '「后台导入」应直接关掉弹窗与页面');
      expect(dataPageButton(), findsOneWidget, reason: '应回到数据页继续后台导入');

      // 导入照旧完成，但页面已销毁 → 不得再弹完成提示
      await drainImportTimers(tester);
      expect(await txCount(), 1, reason: '转后台不等于取消，数据仍要导入');
      expect(find.text(zh(tester).importCompleteTitle), findsNothing,
          reason: '页面已经关了，不该在数据页上再弹一次完成弹窗');
    });

    testWidgets('全成功 → 不弹完成弹窗、给成功提示、并**连关两层页面**回到数据页', (tester) async {
      await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);
      await settleParsing(tester);
      await tapStartImport(tester);
      await pumpFrames(tester, frames: 8); // 2.4s：走完全部 await，Toast 还在

      final l10n = zh(tester);
      expect(find.text(l10n.importCompleted('', 0, 3)), findsOneWidget);
      expect(find.text(l10n.importCompleteTitle), findsNothing,
          reason: '全成功不需要弹窗打断用户');
      expect(find.byType(ImportConfirmPage), findsNothing,
          reason: '导入完成后确认页必须关掉');
      expect(dataPageButton(), findsOneWidget, reason: '应回到上一层（数据页），而不是停在半路');
      expect(tester.takeException(), isNull);
      await drainImportTimers(tester);
    });

    testWidgets('有跳过类型 → **必须弹「导入完成」等确认**，并列出跳过的类型', (tester) async {
      // 静默关页 = 用户以为 2 条全导进去了，实际只进 1 条。
      await pumpHost(tester, csvText: _csvWithSkipped);
      await openConfirmPage(tester);
      await settleParsing(tester);
      await tapStartImport(tester);
      await pumpFrames(tester, frames: 8);

      final l10n = zh(tester);
      expect(find.text(l10n.importCompleteTitle), findsOneWidget);
      expect(find.textContaining('跳过 1 条非收支记录'), findsOneWidget);
      expect(find.textContaining('债务(1)'), findsOneWidget,
          reason: '要说清是哪种类型被跳过，用户才能回去改 CSV');
      expect(find.byType(ImportConfirmPage), findsOneWidget,
          reason: '弹窗还开着，页面不得先关 —— 先关掉的话用户看不到说明');

      // 用户确认后才关页
      await tester.tap(find.widgetWithText(TextButton, l10n.commonConfirm));
      await pumpFrames(tester, frames: 6);
      expect(find.byType(ImportConfirmPage), findsNothing);
      expect(dataPageButton(), findsOneWidget);
      await drainImportTimers(tester);
    });

    testWidgets('导入真的落库：有效行入库、被跳过的类型不入库', (tester) async {
      await pumpHost(tester, csvText: _csvWithSkipped);
      await openConfirmPage(tester);
      await settleParsing(tester);
      await tapStartImport(tester);
      await pumpFrames(tester, frames: 8);
      await tester.tap(
          find.widgetWithText(TextButton, zh(tester).commonConfirm));
      await pumpFrames(tester, frames: 6);

      expect(await txCount(), 1, reason: '2 行里只有 1 行是有效收支');
      expect(await txTypes(), ['expense']);
      await drainImportTimers(tester);
    });
  });

  group('AC-R12 进度收尾与跨页刷新', () {
    testWidgets('完成后进度带 ledgerId（供账本页刷新），5 秒后清空并刷新统计', (tester) async {
      final container = await pumpHost(tester, csvText: _csvAllOk);
      await openConfirmPage(tester);
      await settleParsing(tester);
      await tapStartImport(tester);
      await pumpFrames(tester, frames: 8); // 2.4s，尚未到 5s

      final progress = container.read(importProgressProvider);
      expect(progress.running, isFalse, reason: '终态必须是「已结束」，否则「我的」页一直显示后台导入中');
      expect(progress.ledgerId, 1,
          reason: '不带 ledgerId → 账本页监听不到，列表不会刷新（新导入的账本统计是空的）');
      expect(progress.ok, 3);
      expect(progress.total, 3);

      final statsBefore = container.read(statsRefreshProvider);
      final syncBefore = container.read(syncStatusRefreshProvider);
      await pumpFrames(tester, frames: 12); // 再 3.6s，越过 5s 收尾点

      expect(container.read(importProgressProvider).total, 0,
          reason: '5s 后要清空进度，否则「我的」页永久停留在「刚导入完成」态');
      expect(container.read(statsRefreshProvider), greaterThan(statsBefore),
          reason: '不刷新统计 → 「我的」页笔数/天数还是导入前的旧值');
      expect(container.read(syncStatusRefreshProvider), greaterThan(syncBefore));
      await drainImportTimers(tester);
    });

    testWidgets('账本页监听到「导入完成」信号 → 触发同步与列表刷新（跨页契约）', (tester) async {
      // 真正把导入结果刷到账本列表上的不是导入页，而是账本页对
      // importProgressProvider 的 ref.listen；这条跨页接线断了，
      // 页面各自看着都正常，只有列表统计不动。
      final container = await pumpHost(tester, csvText: _csvAllOk);
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

      // 模拟导入进行中 → 完成
      container.read(importProgressProvider.notifier).state =
          const ImportProgress(running: true, total: 3, done: 0, ok: 0, fail: 0);
      await tester.pump();
      final listBefore = container.read(ledgerListRefreshProvider);
      final syncBefore = container.read(syncStatusRefreshProvider);

      container.read(importProgressProvider.notifier).state =
          const ImportProgress(
              running: false, total: 3, done: 3, ok: 3, fail: 0, ledgerId: 1);
      await tester.pump();

      expect(container.read(ledgerListRefreshProvider), greaterThan(listBefore),
          reason: '账本列表不刷新 → 用户看不到刚导进去的账单笔数');
      expect(container.read(syncStatusRefreshProvider), greaterThan(syncBefore));
      await pumpFrames(tester, frames: 8);
    });
  });
}

/// 宿主页（模拟 `DataManagementPage`）→ 模拟 `ImportPage`（stub）→ 确认页。
///
/// 导入完成后代码是**连 pop 两层**，所以确认页之下必须还压着一层页面：
/// 直接把确认页 push 在 home 之上的话，第二下 pop 会把 home 也弹掉
/// （Navigator 变空），「回到了上一页」这个断言就测不出来。
class _HostPage extends StatelessWidget {
  const _HostPage({
    required this.csvText,
    required this.billType,
    required this.hasHeader,
  });

  final String csvText;
  final BillSourceType billType;
  final bool hasHeader;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('open-import-page'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => _ImportPageStub(
                csvText: csvText,
                billType: billType,
                hasHeader: hasHeader,
              ),
            ),
          ),
          child: const Text('打开导入页'),
        ),
      ),
    );
  }
}

/// 模拟 `ImportPage`：真实页面会走 FilePicker，页面级测试不依赖它。
/// 只负责承载「选择文件后进入确认页」这一步，确认页之下有它，
/// 导入完成后的两层 pop 才有落点。
class _ImportPageStub extends StatelessWidget {
  const _ImportPageStub({
    required this.csvText,
    required this.billType,
    required this.hasHeader,
  });

  final String csvText;
  final BillSourceType billType;
  final bool hasHeader;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: TextButton(
          key: const Key('open-import-confirm'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => ImportConfirmPage(
                csvText: csvText,
                hasHeader: hasHeader,
                billType: billType,
              ),
            ),
          ),
          child: const Text('打开导入确认页'),
        ),
      ),
    );
  }
}

/// 给关键 await 加一段**假时钟可控**的延迟，把导入窗口撑到可观察。
///
/// 背景：`NativeDatabase.memory()` 的查询在同一条微任务链上就完成了，整个
/// `_startImport` 会在**同一帧内**从「开始」跑到「连 pop 两层」—— 进度提示、
/// 「导入中」文案、按钮禁用都来不及渲染，任何断言都会变成随机 flaky。
/// 延迟点选的是 `_startImport` 里第一个 await（`getLedgerById`）与
/// `importData → importAccounts` 里的第一个 await（`getAllAccounts`），
/// 于是「点开始导入」后依次能观察到：底部导入中 → 进度弹窗。
class _SlowRepo extends LocalRepository {
  _SlowRepo(super.db);

  static const _window = Duration(milliseconds: 300);

  @override
  Future<Ledger?> getLedgerById(int id) async {
    await Future<void>.delayed(_window);
    return super.getLedgerById(id);
  }

  @override
  Future<List<Account>> getAllAccounts() async {
    await Future<void>.delayed(_window);
    return super.getAllAccounts();
  }
}
