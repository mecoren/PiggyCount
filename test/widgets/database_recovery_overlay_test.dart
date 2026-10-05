// P1-6：本地库损坏恢复引导层（DatabaseRecoveryOverlay）widget 级回归。
//
// 为什么需要：DatabaseHealthService 的探测逻辑已有 13 例测试，但**没有任何
// 测试证明这块 UI 真的会出现**。探测正确却接不上 UI，等于功能不存在——
// 这类「逻辑对、接线错」的缺口只有 widget 测试能覆盖。
//
// 覆盖场景：
// - 健康 → 不占屏（不能给健康用户弹「数据可能已损坏」）
// - 损坏 → 标题 + 三个动作可见
// - 「稍后处理」→ 本会话隐藏（但不持久化，下次启动仍提示）
// - 「重置」→ 先进二次确认态，未确认前不得触碰文件
// - 不可读（与损坏区分正文）
//
// 测试环境：这里只注入 provider 结果，不碰真实文件系统——探测本身已由
// database_health_service_test 用真实文件覆盖，本文件只验证接线与交互。
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/database_health_service.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/widgets/biz/database_recovery_overlay.dart';
import 'package:piggycount/widgets/ui/piggy_spinner.dart';

/// overlay 内部返回 `Positioned.fill`，因此必须置于 Stack 中。
Widget _wrap() => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: const Scaffold(body: Stack(children: [DatabaseRecoveryOverlay()])),
    );

Future<void> pumpOverlay(
  WidgetTester tester, {
  required DbHealth health,
  String? detail,
  bool dismissed = false,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dbHealthProvider.overrideWith(
          (ref) async =>
              DbHealthResult(health, dbPath: '/tmp/x.sqlite', detail: detail),
        ),
        dbHealthDismissedProvider.overrideWith((ref) => dismissed),
      ],
      child: _wrap(),
    ),
  );
  await tester.pumpAndSettle();
}

/// 排掉忙态收尾。
///
/// 不能用 `pumpAndSettle`：它会等 [PiggySpinner] 的循环动画（永不静止），
/// 且 `_export()` 挂在真实的 path_provider / 文件系统 IO 上，fake-async 区内
/// 那个 Future 不会完成 —— 直接 `pumpAndSettle` 会超时。改用有限轮次的
/// `runAsync` 让真实 IO 跑完，再断言忙态确实退出了。
Future<void> _drainBusy(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (find.byType(PiggySpinner).evaluate().isEmpty) return;
  }
  throw StateError('忙态未在有限轮次内结束');
}

void main() {
  testWidgets('健康 → 不占屏（不能骚扰健康用户）', (tester) async {
    await pumpOverlay(tester, health: DbHealth.ok);

    expect(find.text('本地数据库异常'), findsNothing);
    expect(find.text('重置本地数据库'), findsNothing);
  });

  testWidgets('页级损坏 → 标题 + 三个动作，且正文为损坏口径', (tester) async {
    await pumpOverlay(tester,
        health: DbHealth.corrupted, detail: 'page 3 is broken');

    expect(find.text('本地数据库异常'), findsOneWidget);
    expect(find.text('导出损坏文件'), findsOneWidget);
    expect(find.text('重置本地数据库'), findsOneWidget);
    expect(find.text('稍后处理'), findsOneWidget);
    // 损坏正文必须提到「完整性校验」，与不可读正文区分开
    expect(find.textContaining('完整性校验'), findsOneWidget);
    // 原始 detail 是面向开发者的诊断串，绝不该出现在用户界面
    expect(find.textContaining('page 3 is broken'), findsNothing);
  });

  testWidgets('不可读 → 走另一套正文（提示先重启应用）', (tester) async {
    await pumpOverlay(tester, health: DbHealth.unreadable);

    expect(find.text('本地数据库异常'), findsOneWidget);
    expect(find.textContaining('无法读取本地数据库文件'), findsOneWidget);
    expect(find.textContaining('完整性校验'), findsNothing);
  });

  // ↓ R5（2026-10-05 新增）：加密库缺钥
  //
  // 回归点：加密库 + 本机无密钥原先走 `unreadable` 分支，于是用户看到
  // 「数据可能已损坏」并拿到"隔离重置"的出口 —— 那会让他把**唯一可能被解开**
  // 的密文当废数据搬走/丢掉。
  testWidgets('密钥不可得 → 走 R5 文案，不得借用「损坏」口径', (tester) async {
    await pumpOverlay(tester, health: DbHealth.keyUnavailable);

    expect(find.text('本地数据库已加密，但本机找不到密钥'), findsOneWidget);
    expect(find.textContaining('只是本机解不开'), findsOneWidget);
    // 关键：不能让用户以为数据已废
    expect(find.text('本地数据库异常'), findsNothing);
    expect(find.textContaining('完整性校验'), findsNothing);
    // 出口仍在：先导出留存，再（二次确认的）重置
    expect(find.text('导出加密文件（留存）'), findsOneWidget);
    expect(find.text('导出损坏文件'), findsNothing,
        reason: '文件没坏，说"损坏"会让用户以为导出的是废文件因而不留档');
    expect(find.text('重置本地数据库'), findsOneWidget);
  });

  testWidgets('密钥不可得 → 重置确认换成「移走唯一副本」的说法', (tester) async {
    await pumpOverlay(tester, health: DbHealth.keyUnavailable);

    await tester.tap(find.text('重置本地数据库'));
    await tester.pumpAndSettle();

    expect(find.textContaining('本机数据无从解开'), findsOneWidget);
    expect(find.textContaining('完整性校验'), findsNothing);
  });

  testWidgets('「稍后处理」→ 本会话隐藏', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted);
    expect(find.text('本地数据库异常'), findsOneWidget);

    await tester.tap(find.text('稍后处理'));
    await tester.pumpAndSettle();

    expect(find.text('本地数据库异常'), findsNothing);
  });

  testWidgets('会话已忽略 → 直接不渲染', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted, dismissed: true);

    expect(find.text('本地数据库异常'), findsNothing);
  });

  testWidgets('重置需二次确认：确认前不得出现任何「已重置」结果', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted);

    await tester.tap(find.text('重置本地数据库'));
    await tester.pumpAndSettle();

    // 进入确认态：出现确认标题与确定/取消
    expect(find.text('重置本地数据库？'), findsOneWidget);
    expect(find.text('确定'), findsOneWidget);
    expect(find.text('取消'), findsOneWidget);
    // 尚未执行：不能出现「已保留在…」这类结果文案
    expect(find.textContaining('损坏文件已保留在'), findsNothing);
  });

  testWidgets('确认态可取消，回到动作列表', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted);

    await tester.tap(find.text('重置本地数据库'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();

    expect(find.text('重置本地数据库？'), findsNothing);
    expect(find.text('导出损坏文件'), findsOneWidget);
  });

  // ↓ 忙态反馈门禁（2026-10-03 新增）
  //
  // 回归点：此前 `_busy` 期间两个动作键只是整体变灰，全屏流程**没有任何**
  // 进行中指示——用户看到的是「界面卡住了」，而这是数据疑似损坏、最需要
  // 明确反馈的场景。约定：转圈必须画在真正在跑的那个键上。

  testWidgets('导出中：导出键转圈，且不是转在重置键上', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted);

    await tester.tap(find.text('导出损坏文件'));
    await tester.pump();

    // 导出键的图标位换成转圈
    expect(
      find.descendant(
        of: find.widgetWithText(OutlinedButton, '导出损坏文件'),
        matching: find.byType(PiggySpinner),
      ),
      findsOneWidget,
    );
    // 重置键此刻不是 busy，仍是静态图标
    expect(
      find.descendant(
        of: find.widgetWithText(FilledButton, '重置本地数据库'),
        matching: find.byType(PiggySpinner),
      ),
      findsNothing,
    );

    await _drainBusy(tester);
  });

  testWidgets('忙态下三个动作键全部禁用（防连点）', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted);

    await tester.tap(find.text('导出损坏文件'));
    await tester.pump();

    for (final label in ['导出损坏文件', '重置本地数据库', '稍后处理']) {
      // 用 widgetWithText 反查具体按键（ancestor 在按钮树里会撞上 Theme 等
      // 多个祖先，拿不准命中几个）。三个动作分别是 Outlined/Filled/TextButton。
      final finder = switch (label) {
        '导出损坏文件' => find.widgetWithText(OutlinedButton, label),
        '重置本地数据库' => find.widgetWithText(FilledButton, label),
        _ => find.widgetWithText(TextButton, label),
      };
      expect(finder, findsOneWidget, reason: '「$label」按键应存在');
      final btn = tester.widget<ButtonStyleButton>(finder);
      expect(
        btn.onPressed,
        isNull,
        reason: '「$label」在忙态下必须禁用',
      );
    }

    await _drainBusy(tester);
  });
}
