/// 记账抽屉「合并属性行」的契约（2026-10-09）。
///
/// 改前账户、标签各占一行（账户 40 高 + 标签 ~36 高 + 8 间距 ≈ 84dp）。合并成
/// `[账户芯片][标签区（吃剩余）][图片][旗标]` 之后，本用例锁三件事：
///
///   1. **真的在同一行**：账户芯片与「选择标签」的垂直中心对齐，账户芯片右边界
///      到标签区左边界只有 12px 间距（不是两行）；
///   2. **账户区按内容取宽**：账户少时它只占内容宽（不是 55% 的固定份额）——
///      否则标签区会被挤到右边、中间留一条谁都不用的缝；
///   3. **账户多时压到上界**：超长账户列表不许把标签区挤没，且行高不膨胀。
library;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/account_selector.dart';
import 'package:piggycount/widgets/biz/amount_editor_sheet.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    SharedPreferences.setMockInitialValues({});
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

  Widget host() => ProviderScope(
        overrides: [
          repositoryProvider.overrideWithValue(repo),
          databaseProvider.overrideWithValue(db),
          currentLedgerProvider
              .overrideWith((ref) => Stream<Ledger?>.value(cnyLedger())),
        ],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: AmountEditorSheet(
              categoryName: '餐饮',
              displayCategory: null,
              initialDate: DateTime(2026, 9, 18),
              showAccountPicker: true,
              ledgerId: 1,
              onSubmit: (_) {},
            ),
          ),
        ),
      );

  String tagPlaceholder(WidgetTester tester) => AppLocalizations.of(
        tester.element(find.byType(AmountEditorSheet)),
      ).tagSelectTitle;

  Future<void> drainLoggerTimer(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  testWidgets('账户与标签在同一行：垂直居中、水平只隔一个 p12', (tester) async {
    await seedLedger();
    await repo.createAccount(ledgerId: 1, name: '招商银行');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final chip = find.byKey(const ValueKey('accountChip_招商银行'));
    final tag = find.text(tagPlaceholder(tester));
    expect(chip, findsOneWidget);
    expect(tag, findsOneWidget);

    expect((tester.getCenter(chip).dy - tester.getCenter(tag).dy).abs(),
        lessThanOrEqualTo(2.0),
        reason: '两条属性行必须真的合并成一行（垂直中心对齐）');
    expect(tester.getRect(tag).left - tester.getRect(chip).right,
        inInclusiveRange(12.0, 18.0),
        reason: '账户芯片右边界到标签区只应有一个 p12 间距（外加列表左右 2px 内边距）');

    await drainLoggerTimer(tester);
  });

  testWidgets('账户少时账户区按内容取宽（不是 55% 的固定份额）', (tester) async {
    await seedLedger();
    await repo.createAccount(ledgerId: 1, name: '招商银行');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final sheetWidth = tester.getSize(find.byType(AmountEditorSheet)).width;
    final rowWidth = sheetWidth - 32; // 表单左右各 p16
    final accountWidth = tester.getSize(find.byType(AccountSelector)).width;

    expect(accountWidth, greaterThan(0));
    expect(accountWidth, lessThan(rowWidth * 0.4),
        reason: '两个芯片（不选择账户 + 招商银行）只占内容宽；'
            '若这里接近 55% 就说明又退回了固定份额，标签区被推到右边留缝');

    await drainLoggerTimer(tester);
  });

  testWidgets('账户多且名字长 → 账户区压到 55% 上界，标签区仍可见，行高不膨胀',
      (tester) async {
    await seedLedger();
    for (final name in [
      '招商银行储蓄卡',
      '中国银行信用卡',
      '微信零钱通余额',
      '支付宝余额宝',
      '工商银行工资卡',
    ]) {
      await repo.createAccount(ledgerId: 1, name: name);
    }

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final sheetWidth = tester.getSize(find.byType(AmountEditorSheet)).width;
    final rowWidth = sheetWidth - 32;
    final accountSize = tester.getSize(find.byType(AccountSelector));

    expect(accountSize.width, lessThanOrEqualTo(rowWidth * 0.55 + 1),
        reason: '账户区上界 = 55% 行宽，超出由内部横滑消化');
    expect(accountSize.width, greaterThan(rowWidth * 0.5),
        reason: '账户多时应该吃满上界（内容宽远大于上界）');
    expect(find.text(tagPlaceholder(tester)), findsOneWidget,
        reason: '账户再多也不许把标签入口挤没');
    expect(accountSize.height, 40,
        reason: '合并行高收敛到账户芯片的 40：比原来的两条行（84）省下 ~44dp');

    await drainLoggerTimer(tester);
  });

  testWidgets('账户功能关闭 → 只剩标签行，且不再渲染账户选择器', (tester) async {
    SharedPreferences.setMockInitialValues({'account_feature_enabled': false});
    await seedLedger();
    await repo.createAccount(ledgerId: 1, name: '招商银行');

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(find.byType(AccountSelector), findsNothing);
    expect(find.text(tagPlaceholder(tester)), findsOneWidget,
        reason: '没有账户区时标签行仍然在，并且自己撑满整行');

    await drainLoggerTimer(tester);
  });
}
