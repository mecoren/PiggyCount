/// 账户详情页「更新估值」弹窗的回归（2026-10-08 真机红屏实测修复）。
///
/// 缺陷形状：controller 建在调用方方法里、`await showDialog(...)` 之后立刻
/// `dispose()`。`showDialog` 的 future 在 `Navigator.pop` 那一刻就完成，**早于
/// 退场动画结束**；紧接着键盘收起改 `MediaQuery.viewInsets`、`autofocus` 的输入框
/// 还会因失焦重建一次 —— 这两次重建都会再读一次 controller，于是 debug 下抛
/// `A TextEditingController was used after being disposed`，弹窗内直接红屏。
///
/// 本用例锁死：输入 → 确定 → 值真的落库，且整个退场过程**不得**抛异常。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/account/account_detail_page.dart';
import 'package:piggycount/providers/database_providers.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
  });

  tearDown(() async => db.close());

  testWidgets('更新估值：输入 → 确定 → 落库，退场动画不得触发 controller 已释放断言',
      (tester) async {
    final accountId = await repo.createAccount(
      ledgerId: 1,
      name: '投资理财',
      type: 'investment',
      currency: 'CNY',
      initialBalance: 100,
    );
    final account = (await repo.getAccount(accountId))!;

    final container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      repositoryProvider.overrideWithValue(repo),
    ]);
    addTearDown(container.dispose);

    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: AccountDetailPage(account: account),
      ),
    ));
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
        tester.element(find.byType(AccountDetailPage).first));

    // 无持仓 → 估值卡保留手工估值入口
    await tester.tap(find.text(l10n.valuationUpdateValue));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField).last, '8888');
    await tester.pump();
    await tester.tap(find.text(l10n.commonOk));
    await tester.pumpAndSettle();

    // ① 值真的写库（经 Repository，记 user-global change）
    final saved = (await repo.getAccount(accountId))!;
    expect(saved.initialBalance, 8888);

    // ② 整个弹窗生命周期不得有异常（旧实现在这里红屏）
    expect(tester.takeException(), isNull,
        reason: 'controller 必须由弹窗自己持有并在元素卸载后释放；'
            '在 await showDialog 之后立刻 dispose 会撞上退场重建');

    // ③ 卸载页面并推进时间，清掉 drift / LoggerService 的挂起定时器
    //    （见 AGENTS.md Riverpod 3 迁移注意 #8）
    await tester.pumpWidget(const SizedBox.shrink());
    container.dispose();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 1));
    await tester.pump(const Duration(seconds: 3));
  });
}
