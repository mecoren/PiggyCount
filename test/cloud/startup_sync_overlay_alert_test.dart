// 启动检查遮罩「弹窗态」口径回归：通知态（错误 / 信息）与候选态（发现更新）
// 都是**弹窗**（不是进度卡），必须与 AppDialog 同一套外观 ——
// 居中标题 + 三级色说明 + 底部 [PiggyDialogActionsBar] 分栏纯文本按钮。
//
// 回归点：通知态此前是自绘的「红色错误图标 + 居中正文 + FilledButton 确定」；
// 候选态此前是自绘的「左对齐图标标题 + Filled / Outlined / Text 三个大按钮
// + p24 内边距」，与项目其余弹窗不一致。
//
// 进度态（checking / applying / done）仍是内容自绘的宽卡片，不在此断言。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/startup_sync_checker.dart'
    show LedgerCandidate, SummaryChoice;
import 'package:piggycount/cloud/startup_sync_overlay.dart';
import 'package:piggycount/cloud/sync_service.dart' show SyncDiff, SyncStatus;
import 'package:piggycount/data/db.dart' as db;
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/styles/tokens.dart';

/// 遮罩卡片：带 PiggyShadows.card 阴影的那个 Container。
///
/// 注意 [Container] 的 margin 套在 constraints **外层**，量到的宽度含左右
/// 留距，故 [_cardWidth] 扣掉 margin 才是卡片本身的宽度。
Finder _card() => find.byWidgetPredicate(
      (w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration as BoxDecoration).boxShadow == PiggyShadows.card,
    );

double _cardWidth(WidgetTester tester) =>
    tester.getSize(_card()).width - PiggyDimens.p24 * 2;

/// 卡片宽度上限（[Container] 的 constraints.maxWidth）。
double _cardMaxWidth(WidgetTester tester) =>
    tester.widget<Container>(_card()).constraints!.maxWidth;

/// 造一个候选账本：widget 级测试不需要真实数据库行，直接构造数据类。
LedgerCandidate _candidate(int id, String name) => LedgerCandidate(
      ledger: db.Ledger(
        id: id,
        name: name,
        currency: 'CNY',
        type: 'general',
        createdAt: DateTime(2026, 1, 1),
        myRole: 'owner',
        memberCount: 1,
        isShared: false,
        monthStartDay: 1,
      ),
      status: const SyncStatus(
        diff: SyncDiff.cloudNewer,
        localCount: 0,
        localFingerprint: 'local-fp',
      ),
      diffType: SyncDiff.cloudNewer,
    );

/// 挂载遮罩（attach 走 rootOverlay，与 app.dart 生产装配一致）。
///
/// attach 必须在 build 阶段之外调用（OverlayEntry.insert 会 markNeedsBuild），
/// 故用 navigatorKey 在 pumpWidget 之后挂载，而不是在 State 里做。
Future<StartupSyncController> _pumpWithOverlay(WidgetTester tester) async {
  final navKey = GlobalKey<NavigatorState>();
  await tester.pumpWidget(MaterialApp(
    navigatorKey: navKey,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    locale: const Locale('zh'),
    home: const Scaffold(body: SizedBox.shrink()),
  ));
  final controller = StartupSyncController();
  controller.attach(navKey.currentState!.overlay!);
  addTearDown(controller.dispose);
  await tester.pump();
  return controller;
}

void main() {
  testWidgets('错误态：窄卡片 + 居中标题/说明 + 单个全宽文本按钮', (tester) async {
    final controller = await _pumpWithOverlay(tester);

    controller.error(
      title: '云端更新检查失败',
      message: '云端认证失败（账号或密码错误），'
          '请到「我的-云同步-云服务」检查配置后重试',
    );
    await tester.pump();

    expect(find.text('云端更新检查失败'), findsOneWidget);
    expect(find.textContaining('云端认证失败'), findsOneWidget);

    // 与 AppDialog 一致：文本按钮，不是 Filled/Outlined 大按钮
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    expect(find.widgetWithText(TextButton, '确定'), findsOneWidget);
    // 通知态不套 iOS 图标（红色错误圈 / 信息圈）
    expect(find.byIcon(Icons.error_outline), findsNothing);

    // 窄卡片：提醒类文案用 alertWidth，与 AppDialog 警示框同宽
    expect(_cardWidth(tester), PiggyDimens.alertWidth);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(controller.state, isA<DismissedState>());
    expect(find.text('云端更新检查失败'), findsNothing);
  });

  testWidgets('信息态：明细逐条换行拼进说明区，同为窄卡片单按钮', (tester) async {
    final controller = await _pumpWithOverlay(tester);

    controller.info(
      title: '云端账本信息与本地不同',
      lines: const ['账本名：日常账 → 家庭账', '每月起始日 1 → 5'],
      action: '请到「我的 → 云同步」手动处理。',
    );
    await tester.pump();

    expect(find.text('云端账本信息与本地不同'), findsOneWidget);
    // 明细与操作说明合并为一段可滚动说明，不再是独立列表段
    expect(
      find.text('账本名：日常账 → 家庭账\n每月起始日 1 → 5\n'
          '请到「我的 → 云同步」手动处理。'),
      findsOneWidget,
    );
    expect(find.widgetWithText(TextButton, '确定'), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
    expect(_cardWidth(tester), PiggyDimens.alertWidth);

    await tester.tap(find.text('确定'));
    await tester.pump();
    expect(controller.state, isA<DismissedState>());
  });

  testWidgets('信息态：明细为空时仍保留操作说明', (tester) async {
    final controller = await _pumpWithOverlay(tester);

    controller.info(
      title: '云端账本信息与本地不同',
      lines: const [],
      action: '请到「我的 → 云同步」手动处理。',
    );
    await tester.pump();

    expect(find.text('请到「我的 → 云同步」手动处理。'), findsOneWidget);
    expect(find.text('\n请到「我的 → 云同步」手动处理。'), findsNothing);
  });

  testWidgets('候选态：居中标题 + 账本清单 + 分栏纯文本三动作', (tester) async {
    final controller = await _pumpWithOverlay(tester);
    final completer = Completer<SummaryChoice>();

    controller.showHasUpdates(
      [_candidate(1, '日常消费账本'), _candidate(2, '投资理财账本')],
      completer,
    );
    await tester.pump();

    expect(find.text('云端有更新'), findsOneWidget);
    expect(find.textContaining('检测到 2 个账本'), findsOneWidget);
    expect(find.text('日常消费账本'), findsOneWidget);

    // 与 AppDialog 一致：分栏纯文本按钮，不是 Filled/Outlined 大按钮
    expect(find.byType(FilledButton), findsNothing);
    expect(find.byType(OutlinedButton), findsNothing);
    for (final label in ['暂不合并', '逐个确认', '一键应用全部']) {
      expect(find.widgetWithText(TextButton, label), findsOneWidget);
    }

    // 候选态带账本清单 + 三动作，走宽档卡片
    expect(_cardWidth(tester), PiggyDimens.alertWidthWide);

    await tester.tap(find.text('一键应用全部'));
    await tester.pump();
    expect(await completer.future, SummaryChoice.applyAll);
  });

  testWidgets('进度态仍是宽卡片（alertWidthWide），不被窄化', (tester) async {
    final controller = await _pumpWithOverlay(tester);

    controller.startChecking(3);
    await tester.pump();

    // 卡片内容按需收缩，实际像素宽随文案浮动，故断言宽度上限（分支条件）
    expect(_cardMaxWidth(tester), PiggyDimens.alertWidthWide);
  });
}
