/// 模拟器 / 真机上的端到端验证：**记账 5 分钟内继承上一笔的分类与账户**。
///
/// 运行（设备 id 用 `flutter devices` 查）：
/// ```
/// flutter test integration_test/recent_entry_inherit_test.dart \
///   -d 127.0.0.1:16384 --flavor dev
/// ```
///
/// 与 `test/widgets/quick_entry_mode_test.dart`（宿主 VM）的分工：
/// 宿主测试守**逻辑**，这里守**设备**上才暴露的东西 ——
/// 1. `transactions.created_at` 与 `idx_transactions_ledger_created` 在本机
///    **真实引擎**（Android 下是 jniLibs 里的 `libsqlcipher.so`）上确实建出来了；
/// 2. 分类位在**真机字体 / 真实屏幕尺寸**下真的显示出来了（PRD 决策 4 记过
///    「窄屏 + 大字下分类位可能被挤到只剩二三十像素」的风险，宿主测试用的
///    `FlutterTest` 字体每字宽 1em，量不出真机排版）；
/// 3. 真实的点按链路（点分类位 → 分类子界面 → 输金额 → 完成）能把一笔写进库，
///    且**再记一笔时确实继承到它** —— 整条「连续记账」链路的端到端。
///
/// 注：本文件用内存库 + ProviderScope 覆盖（与宿主测试同款），不启动整套 App ——
/// 这样窗口命中的时间基准可由用例完全控制（真实 App 里没法把 `created_at`
/// 拨到 6 分钟前，只能干等 5 分钟）。真机 App 的启动 / 迁移链路由
/// `flutter run` 实测覆盖（见 PR 说明）。
library;

import 'dart:io';

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart' as raw_sqlite3;

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/transaction/transaction_editor_page.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/ui_state_providers.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';
import 'package:piggycount/widgets/category/category_selector.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  /// 固定的「现在」：窗口判定用注入的 `now`，不依赖设备墙钟。
  final now = DateTime.now();

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  Ledger cnyLedger() => Ledger(
        id: 1,
        name: 'L',
        currency: 'CNY',
        type: 'personal',
        createdAt: DateTime(2026, 1, 1),
        monthStartDay: 1,
      );

  /// 直接落一行交易，可显式控制**录入时刻**（`createdAt`）。
  Future<void> seedTx({
    required String type,
    required DateTime? createdAt,
    int? categoryId,
    int? accountId,
  }) {
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: type,
          amount: 10,
          categoryId: d.Value(categoryId),
          accountId: d.Value(accountId),
          createdAt: d.Value(createdAt),
          happenedAt: d.Value(createdAt ?? now),
          originalAmount: const d.Value(10),
        ));
  }

  /// 挂记账页（与生产同一入口组件）。
  ///
  /// 外层必须给一个 `Scaffold`：真机（live binding）下 `Navigator` 的每个路由
  /// 都在自己的 `LookupBoundary` 里，`CategorySelector` 的 InkWell 找不到路由
  /// **外**的 Material 就会抛 "No Material widget found"（宿主下正好能穿透，
  /// 所以宿主测试不暴露这条）。真实 App 里页面本来就在 Scaffold / 抽屉卡片之下，
  /// 这里补上就与生产一致。
  ///
  /// [settle] 为 false 时用固定时长 pump 代替 `pumpAndSettle` —— 保存过一笔之后
  /// LoggerService 的 2s 节流落盘定时器会让 `pumpAndSettle` 永不收敛（宿主测试
  /// 用 `drainLoggerTimer` 是同一回事）。
  Future<void> openEditor(
    WidgetTester tester, {
    bool quickMode = true,
    bool renderAsBottomSheet = true,
    int? initialCategoryId,
    int? editingTransactionId,
    bool settle = true,
    /// 覆盖「默认支出账户」——端到端用例靠它让第一笔自动带上账户，
    /// 就不必去猜账户选择器的 UI 文案。
    int? defaultExpenseAccountId,
  }) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        databaseProvider.overrideWithValue(db),
        currentLedgerProvider
            .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
        // 恒覆盖（不按条件增减）：Riverpod 3 的 ProviderScope 断言
        // `_debugOverridesLength == overrides.length` —— 同一棵树上两次
        // `pumpWidget` 的覆盖项数量必须一致，否则直接抛断言。
        // null = 无默认账户，同时把设备的真实 pref 隔离在测试之外。
        defaultExpenseAccountIdProvider
            .overrideWith((ref) async => defaultExpenseAccountId),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: TransactionEditorPage(
            initialKind: 'expense',
            quickAdd: true,
            quickMode: quickMode,
            initialCategoryId: initialCategoryId,
            editingTransactionId: editingTransactionId,
            renderAsBottomSheet: renderAsBottomSheet,
          ),
        ),
      ),
    ));
    if (settle) {
      await tester.pumpAndSettle();
    } else {
      // live binding 下时间是真实的：给异步初值解析（查库 + setState）留够时间。
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 900));
      await tester.pump(const Duration(milliseconds: 900));
    }
  }

  /// 分类位（金额表单内）是否有某个文本 —— 分类网格在模态表单**下面**仍在树里，
  /// 必须限定在 [AmountEditorSheet] 子树内断言。
  Finder inSheet(String text) => find.descendant(
      of: find.byType(AmountEditorSheet), matching: find.text(text));

  group('设备引擎：v55 schema 与索引', () {
    testWidgets('transactions.created_at 与 idx_transactions_ledger_created 在本机引擎上存在',
        (tester) async {
      final cols = (await db.customSelect('PRAGMA table_info(transactions)').get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(cols, contains('created_at'),
          reason: 'v55 迁移 / onCreate 必须在设备真实引擎上建出该列');

      final indexes = (await db.customSelect(
              "SELECT name FROM sqlite_master WHERE type='index' AND tbl_name='transactions'")
          .get())
          .map((r) => r.read<String>('name'))
          .toSet();
      expect(indexes, contains('idx_transactions_ledger_created'),
          reason: '窗口查询依赖的复合索引不能只在迁移里建、漏了 onCreate');
    });
  });

  group('设备端行为：5 分钟继承', () {
    testWidgets('命中窗口：分类位与账户位都继承上一笔（真机排版下真的可见）',
        (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
        accountId: cash,
      );

      await openEditor(tester);

      expect(find.byType(AmountEditorSheet), findsOneWidget);
      expect(inSheet('餐饮'), findsOneWidget,
          reason: '5 分钟内再次记账应默认继承上一笔的分类');
      expect(inSheet('现金'), findsOneWidget, reason: '账户同样继承');

      // 真机排版守卫：分类位不能因为屏幕宽度 / 字体度量被压成 0 宽。
      final chip = find
          .descendant(of: find.byType(AmountEditorSheet), matching: find.text('餐饮'))
          .first;
      expect(tester.getSize(chip).width, greaterThan(0),
          reason: '分类名必须真的占位可见（PRD 决策 4 的窄屏风险）');
    });

    testWidgets('超出 5 分钟：不继承，分类位回到「选择分类」占位', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: DateTime.now().subtract(const Duration(minutes: 6)),
        categoryId: food,
      );

      await openEditor(tester);

      expect(inSheet('选择分类'), findsOneWidget);
      expect(inSheet('餐饮'), findsNothing,
          reason: '窗口外不得预填（预填错分类的危害大于不预填）');
    });

    testWidgets('按类型隔离：上一笔是支出，切到收入不继承它的分类', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.createCategory(name: '工资', kind: 'income');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
      );

      await openEditor(tester);
      expect(inSheet('餐饮'), findsOneWidget);

      await tester.tap(find.text('收入'));
      await tester.pumpAndSettle();

      expect(inSheet('餐饮'), findsNothing,
          reason: '收入没有可继承的一笔 → 必须留占位，而不是把支出分类带过来');
      expect(inSheet('选择分类'), findsOneWidget);
    });

    testWidgets('转账不参与：切到转账出 TransferForm，且不预填上一笔的分类',
        (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
      );

      await openEditor(tester);
      await tester.tap(find.text('转账'));
      await tester.pumpAndSettle();

      expect(inSheet('餐饮'), findsNothing,
          reason: '转账没有分类语义，不得把支出的分类带过来');
    });

    testWidgets('编辑既有交易：用该笔自身的分类，不被「上一笔」覆盖', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');
      // 上一笔（窗口内）是「交通」，但被编辑的这笔是「餐饮」。
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: traffic,
      );
      final editingId = await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 20,
        categoryId: food,
        happenedAt: DateTime(2020, 1, 1),
      );

      await openEditor(tester,
          initialCategoryId: food, editingTransactionId: editingId);

      expect(inSheet('餐饮'), findsOneWidget);
      expect(inSheet('交通'), findsNothing, reason: '编辑态绝不继承「上一笔」');
    });

    testWidgets('分类网格形态（快捷开关关闭）命中窗口 → 直接进金额表单并预填',
        (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: food,
      );

      await openEditor(tester, quickMode: false);

      expect(find.byType(AmountEditorSheet), findsOneWidget,
          reason: '网格形态命中时与「小组件点分类格」同款：直落金额表单');
      expect(inSheet('餐饮'), findsOneWidget);
    });

    testWidgets('继承到的分类已被删除 → 静默不预填（不报错、不白屏）', (tester) async {
      await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(
        type: 'expense',
        createdAt: now.subtract(const Duration(minutes: 1)),
        categoryId: 999999, // 取不到实体的 id
      );

      await openEditor(tester);

      expect(inSheet('选择分类'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('批量导入 / 云恢复的行（created_at 为 NULL）不算「上一笔」', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await seedTx(type: 'expense', createdAt: null, categoryId: food);

      await openEditor(tester);

      expect(inSheet('选择分类'), findsOneWidget,
          reason: '非用户交互录入的行不参与继承');
    });
  });

  group('设备引擎：直升形态库的 50→55 升级路径', () {
    testWidgets('缺 updated_at 的旧库也能完成 v55 回填（updated_at 地雷不在设备上复现）',
        (tester) async {
      // 与 `test/data/migration_v55_test.dart` 的同名用例同构，但跑在**设备真实引擎**
      // （Android 下是 jniLibs 里那份 `libsqlcipher.so`）上。
      //
      // 库形态：user_version=50、只有 ledgers/transactions 两张表，且 transactions
      // **没有** updated_at 列（v40 块从未跑过）。v52 块会给这张表建
      // `trg_transactions_touch_updated_at`（触发器体引用 NEW.updated_at，CREATE
      // 时不校验列），v55 的存量回填 UPDATE 正是第一条撞上去的语句 —— 宿主侧实测
      // 报 `no such column: NEW.updated_at`，故 v55 块在回填前先补齐该列。
      final dir = await getTemporaryDirectory();
      final path =
          '${dir.path}/v55_heli_${DateTime.now().microsecondsSinceEpoch}.db';
      final raw = raw_sqlite3.sqlite3.open(path);
      raw.execute('CREATE TABLE ledgers (id INTEGER PRIMARY KEY NOT NULL, '
          'name TEXT NOT NULL, currency TEXT NOT NULL, type TEXT NOT NULL, '
          'created_at INTEGER NOT NULL, sync_id TEXT, '
          'month_start_day INTEGER NOT NULL)');
      raw.execute('CREATE TABLE transactions ('
          'id INTEGER PRIMARY KEY NOT NULL, ledger_id INTEGER NOT NULL, '
          'type TEXT NOT NULL, amount REAL NOT NULL, happened_at INTEGER NOT NULL, '
          'sync_id TEXT)');
      raw.execute("INSERT INTO transactions "
          "(id, ledger_id, type, amount, happened_at) "
          "VALUES (1, 1, 'expense', 10.0, 1700000000)");
      raw.execute('PRAGMA user_version = 50');
      raw.close();

      final upgraded = PiggyDatabase.forTesting(NativeDatabase(File(path)));
      addTearDown(() async {
        await upgraded.close();
        if (File(path).existsSync()) File(path).deleteSync();
      });
      await upgraded.customSelect('SELECT 1').get(); // 触发 open + onUpgrade(50→55)

      final row = await upgraded
          .customSelect('SELECT created_at FROM transactions WHERE id = 1')
          .getSingle();
      expect(row.data['created_at'], 1700000000,
          reason: 'v55 回填必须在设备引擎上成功 —— 否则老用户升级即报错、App 打不开');
    });
  });

  group('设备端端到端：连续记账链路', () {
    testWidgets('保存一笔后，再开记账页继承到刚保存的分类与账户', (tester) async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final cash = await repo.createAccount(ledgerId: 1, name: '现金');

      // ---- 第一笔：从零开始，走真实点按链路 ----
      await openEditor(tester, defaultExpenseAccountId: cash);
      expect(inSheet('选择分类'), findsOneWidget, reason: '库里没有上一笔');

      await tester.tap(find.text('选择分类'));
      await tester.pumpAndSettle();
      expect(find.byType(CategorySelector), findsWidgets,
          reason: '点分类位应弹出分类子界面');
      await tester.tap(find.text('餐饮').last);
      await tester.pumpAndSettle();

      await tester.tap(find.text('1'));
      await tester.pumpAndSettle();
      final l10n = AppLocalizations.of(
          tester.element(find.byType(TransactionEditorPage)));
      await tester.tap(find.text(l10n.commonFinish));
      // 保存后 LoggerService 的 2s 节流落盘定时器会让 pumpAndSettle 永不收敛，
      // 这里用固定时长 pump（等价于宿主测试的 drainLoggerTimer）。
      await tester.pump();
      await tester.pump(const Duration(seconds: 3));

      // ---- 落库断言：一笔，且 created_at（录入时刻）真的写进去了 ----
      final rows = await (db.select(db.transactions)
            ..where((t) => t.ledgerId.equals(1)))
          .get();
      expect(rows.length, 1, reason: '真实点按链路应写入 1 笔');
      expect(rows.single.categoryId, food);
      expect(rows.single.createdAt, isNotNull,
          reason: '用户交互录入必须写录入时刻 —— 否则下一笔继承不到');

      // ---- 第二笔：继承 ----
      final defaults = await repo.getRecentEntryDefaults(
          ledgerId: 1, kind: 'expense', now: DateTime.now());
      expect(defaults, isNotNull);
      expect(defaults!.categoryId, food);

      await openEditor(tester, settle: false);
      expect(inSheet('餐饮'), findsOneWidget,
          reason: '连续记账：再记一笔应默认上一笔的分类（本需求的核心价值）');
      expect(inSheet('现金'), findsOneWidget,
          reason: '账户同样继承（同一账户连续记账少点一次）');
    });
  });
}
