/// 记账抽屉「账户选择」的视觉契约：与「进度来源」分段控件同源。
///
/// 背景（2026-10-09）：账户芯片原先自画一套「实心主色底 + 白字」，与同一个
/// 抽屉里的 [PiggySegmentedControl]（主色描边 + 12% 主色底）像两个体系，实心蓝
/// 的视觉重量还盖过了金额位。改成两边共用 [piggySelectableDecoration] 之后，
/// 本用例把「同源」这件事**逐字段**钉住 —— 只断言「是主色」不够，将来任一侧
/// 单方面改圆角 / 线宽 / 填充比例都会被这里拦下。
///
/// 同时守住横滑语义没被视觉改动带坏：账户数不定，等宽分段放不下，必须仍能滑
/// 且点击回调正确。
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
import 'package:piggycount/widgets/ui/segmented_control.dart';

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

  /// 账户选择器 + 一个「进度来源」式的分段控件挂在同一棵树上 —— 逐字段比对
  /// 两边的装饰，就是本用例的核心。
  Widget host({int? selectedAccountId, ValueChanged<int?>? onSelected}) {
    return ProviderScope(
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        databaseProvider.overrideWithValue(db),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: Scaffold(
          body: Column(
            children: [
              AccountSelector(
                selectedAccountId: selectedAccountId,
                onAccountSelected: onSelected ?? (_) {},
                ledgerId: 1,
              ),
              PiggySegmentedControl<bool>(
                options: const [
                  PiggySegmentOption(value: false, label: '手动累计'),
                  PiggySegmentOption(value: true, label: '关联账户'),
                ],
                selected: false,
                onChanged: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
  }

  BoxDecoration decoOf(WidgetTester tester, String key) {
    final container = tester
        .widget<AnimatedContainer>(find.byKey(ValueKey('accountChip_$key')));
    return container.decoration! as BoxDecoration;
  }

  BoxDecoration segmentDecoOf(WidgetTester tester, String label) {
    final container = tester
        .widget<AnimatedContainer>(find.byKey(ValueKey('piggySegment_$label')));
    return container.decoration! as BoxDecoration;
  }

  Future<void> seed() async {
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    await repo.createAccount(ledgerId: 1, name: '招商银行');
  }

  /// 建账户 / 加载账户都会写 LoggerService，它有个 2s 节流的落盘定时器 ——
  /// 用例收尾不跑完，flutter_test 会判「树已销毁却仍有 pending timer」。
  Future<void> drainLoggerTimer(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('选中态：账户芯片的装饰与分段控件选中段逐字段相同', (tester) async {
    await seed();
    // 未选账户 → 「不选择账户」是选中态
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    expect(decoOf(tester, '不选择账户'), segmentDecoOf(tester, '手动累计'),
        reason: '账户芯片与「进度来源」分段控件必须共用 piggySelectableDecoration：'
            '颜色 / 填充 / 线宽 / 圆角任一项漂移都会被这条拦下');

    await drainLoggerTimer(tester);
  });

  testWidgets('未选态：账户芯片的装饰与分段控件未选段逐字段相同', (tester) async {
    await seed();
    await tester.pumpWidget(host(selectedAccountId: null));
    await tester.pumpAndSettle();

    expect(decoOf(tester, '招商银行'), segmentDecoOf(tester, '关联账户'),
        reason: '未选态同源（中性描边 + 无填充）');

    await drainLoggerTimer(tester);
  });

  testWidgets('选中账户 → 该芯片变选中态，且高度与分段控件同高（40）', (tester) async {
    await seed();
    final accountId = (await repo.getAllAccounts()).first.id;

    await tester.pumpWidget(host(selectedAccountId: accountId));
    await tester.pumpAndSettle();

    expect(decoOf(tester, '招商银行'), segmentDecoOf(tester, '手动累计'),
        reason: '选中的账户芯片 = 分段控件选中段的装饰');
    expect(tester.getSize(find.byKey(const ValueKey('accountChip_招商银行'))).height,
        40);
    expect(
      tester
          .getSize(find.byKey(const ValueKey('piggySegment_手动累计')))
          .height,
      40,
      reason: '两处可选格子必须同高，否则并排出现时像两套组件',
    );

    await drainLoggerTimer(tester);
  });

  testWidgets('横滑语义保留：账户多到超宽仍可滑，点击回调拿得到正确 id', (tester) async {
    await seed();
    await repo.createAccount(ledgerId: 1, name: '微信零钱');
    await repo.createAccount(ledgerId: 1, name: '支付宝余额');
    await repo.createAccount(ledgerId: 1, name: '中国银行储蓄卡');

    tester.view.physicalSize = const Size(360 * 3, 800 * 3);
    tester.view.devicePixelRatio = 3.0;
    addTearDown(tester.view.reset);

    final tapped = <int?>[];
    await tester.pumpWidget(host(onSelected: tapped.add));
    await tester.pumpAndSettle();

    final accounts = await repo.getAllAccounts();
    final target = accounts.firstWhere((a) => a.name == '支付宝余额');

    // 滑动后点最后一个账户（视觉改动不得破坏横滑与命中）
    await tester.drag(find.byType(AccountSelector), const Offset(-200, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.text('支付宝余额'));
    await tester.pump();

    expect(tapped, [target.id], reason: '点击必须回传该账户 id');

    await drainLoggerTimer(tester);
  });
}
