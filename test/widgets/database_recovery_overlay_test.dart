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
          (ref) async => DbHealthResult(health, dbPath: '/tmp/x.sqlite', detail: detail),
        ),
        dbHealthDismissedProvider.overrideWith((ref) => dismissed),
      ],
      child: _wrap(),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('健康 → 不占屏（不能骚扰健康用户）', (tester) async {
    await pumpOverlay(tester, health: DbHealth.ok);

    expect(find.text('本地数据库异常'), findsNothing);
    expect(find.text('重置本地数据库'), findsNothing);
  });

  testWidgets('页级损坏 → 标题 + 三个动作，且正文为损坏口径', (tester) async {
    await pumpOverlay(tester, health: DbHealth.corrupted, detail: 'page 3 is broken');

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
}
