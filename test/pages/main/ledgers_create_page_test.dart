/// 账本页「创建第一个账本」路径的回归（riverpod 3 迁移配套）。
///
/// 背景：riverpod 3 里 `read(streamProvider.future)` 在**没有任何活跃订阅**时会
/// 永远停在 loading（2.x 的 read 会顺带初始化 provider，所以不会暴露）。账本页
/// 自身只用 read / invalidate 触碰 `currentLedgerProvider`，是否已有活跃订阅
/// 取决于当时页面上还有哪些组件在 watch 它 —— 一旦在某个页面栈组合下没人
/// watch，用户在空账本场景点「创建」就会永久卡住（不报错、不落库、无提示）。
/// 因此创建路径显式做了 `listenManual` 订阅保活。
///
/// 本用例覆盖这条路径的**端到端**行为（账本落库 + 自动切到新账本 id）；它同时
/// 证明「空库 + 只挂载账本页」这一组合下不会卡死（30s 超时兜底）。
/// 保活本身是防御性的 —— 实测该组合下即使没有保活也能通过，因为页面上的
/// 其它 provider 依赖链恰好初始化了它。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/models/ledger_display_item.dart';
import 'package:piggycount/pages/main/ledgers_page_new.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  testWidgets(
    '空库创建第一个账本：无人 watch currentLedgerProvider 也必须收敛（不卡死）',
    (tester) async {
      final container = ProviderContainer(overrides: [
        databaseProvider.overrideWithValue(db),
        repositoryProvider.overrideWithValue(repo),
        remoteLedgersProvider
            .overrideWith((ref) async => const <LedgerDisplayItem>[]),
      ]);
      addTearDown(container.dispose);
      // 预热本地列表：页面首帧就要渲染（空库 → 渲染「新建账本」按钮）
      await container.read(localLedgersProvider.future);

      await tester.pumpWidget(UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          // autoOpenCreateDialog：免去找按钮，直接进创建弹窗
          home: const LedgersPageNew(autoOpenCreateDialog: true),
        ),
      ));
      await tester.pumpAndSettle();

      final l10n = AppLocalizations.of(
          tester.element(find.byType(LedgersPageNew).first));

      await tester.enterText(find.byType(TextField).first, '我的账本');
      await tester.pump();
      await tester.tap(find.text(l10n.ledgersCreate));
      // 关键面：创建路径里 `read(currentLedgerProvider.future)` 必须拿到值并
      // 返回，否则这里会一直等下去（整个用例以超时失败）。
      await tester.pumpAndSettle();

      final ledgers = await db.select(db.ledgers).get();
      expect(ledgers, hasLength(1), reason: '账本必须落库');
      expect(ledgers.single.name, '我的账本');
      expect(container.read(currentLedgerIdProvider), ledgers.single.id,
          reason: '创建第一个账本后必须切到新账本，否则首页胶囊一直显示「新建账本」');

      // Toast / Logger 都带定时器，收尾必须跑完，否则会以「树已销毁却仍有
      // pending timer」判失败。
      await tester.pump(const Duration(seconds: 3));
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}
