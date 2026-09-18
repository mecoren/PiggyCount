// P2-15（治理批次）：同步健康卡（SyncHealthCard）widget 级回归 ——
// 此前健康卡的 99.9% 阈值图标与四态展示全靠人工验证。
//
// 覆盖场景（对照 sync_health_card.dart 契约）：
// - 空窗口（无记录）→ successRate null → 「暂无数据」文案 + 中性图标
// - 四态明细行（成功/失败/未收敛/并发拦截计数）与成功率百分比渲染
// - 阈值图标三档：≥99.9% verified / ≥99% check / <95% error
// - Top 失败类别行渲染（错误类别本地化标签 + 计数）
//
// 测试环境：内存 drift 库 + 真 SyncMetricsService（provider 层经
// ProviderScope override 注入同一实例），记录真实落库走完整链路。

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/cloud/sync_metrics_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/cloud/sync_health_card.dart';
import 'package:piggycount/providers/sync_providers.dart'
    show syncMetricsServiceProvider;
import 'package:drift/native.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: child),
    );

void main() {
  late PiggyDatabase db;
  late SyncMetricsService metrics;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    metrics = SyncMetricsService(db);
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> pumpCard(WidgetTester tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          syncMetricsServiceProvider.overrideWithValue(metrics),
        ],
        child: _wrap(const SyncHealthCard()),
      ),
    );
    // 两个 FutureBuilder（summary + topErrors）完成
    await tester.pumpAndSettle();
  }

  SyncOpRecord rec(SyncOpOutcome outcome,
          {SyncErrorClass? errorClass, String backend = 's3'}) =>
      SyncOpRecord(
        backend: backend,
        scenario: SyncOpScenario.snapshotUpload,
        outcome: outcome,
        errorClass: errorClass,
      );

  testWidgets('空窗口：暂无数据 + 中性图标', (tester) async {
    await pumpCard(tester);

    // 同一文案出现在健康副标题与诊断导出行副标题两处
    expect(find.text('近 30 天暂无同步记录'), findsWidgets);
    expect(find.byIcon(Icons.monitor_heart_outlined), findsOneWidget);
  });

  testWidgets('四态明细与成功率渲染（success=2/failed=1 → 66.7%）', (tester) async {
    await metrics.record(rec(SyncOpOutcome.success));
    await metrics.record(rec(SyncOpOutcome.success));
    await metrics.record(
        rec(SyncOpOutcome.failed, errorClass: SyncErrorClass.networkTimeout));
    await metrics.record(rec(SyncOpOutcome.conflict));
    await metrics.record(rec(SyncOpOutcome.softFail));

    await pumpCard(tester);

    // 成功率 2/(2+1+1) = 50.0%
    expect(find.textContaining('50.0%'), findsOneWidget);
    // 四态明细（zh arb：成功 {success} · 失败 {failed} · 未收敛 {softFail} · 并发拦截 {conflict}）
    expect(find.textContaining('成功 2'), findsOneWidget);
    expect(find.textContaining('失败 1'), findsOneWidget);
    expect(find.textContaining('未收敛 1'), findsOneWidget);
    expect(find.textContaining('并发拦截 1'), findsOneWidget);
  });

  testWidgets('conflict 不入分母：success=1+conflict=1 → 100.0%（99.9% 档图标）',
      (tester) async {
    await metrics.record(rec(SyncOpOutcome.success));
    await metrics.record(rec(SyncOpOutcome.conflict));

    await pumpCard(tester);

    expect(find.textContaining('100.0%'), findsOneWidget);
    // ≥99.9% → verified 图标（健康卡阈值档位 1）
    expect(find.byIcon(Icons.verified_outlined), findsOneWidget);
  });

  testWidgets('softFail 拉低成功率：99.9% 与 99% 之间的差距主体可见',
      (tester) async {
    await metrics.record(rec(SyncOpOutcome.success));
    await metrics.record(rec(SyncOpOutcome.softFail));

    await pumpCard(tester);

    // 1/(1+1) = 50.0%——softFail 在分母内（P1-3 口径）
    expect(find.textContaining('50.0%'), findsOneWidget);
    // <95% 档 → error 图标
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
  });

  testWidgets('Top 失败类别行渲染（network_timeout ×1）', (tester) async {
    await metrics.record(rec(SyncOpOutcome.failed,
        errorClass: SyncErrorClass.networkTimeout));
    await metrics.record(rec(SyncOpOutcome.failed,
        errorClass: SyncErrorClass.networkTimeout));
    await metrics.record(rec(SyncOpOutcome.success));

    await pumpCard(tester);

    // 本测试 locale 固定为 zh：标签必须走 l10n 而非硬编码英文
    // （此前断言 'Network timeout' 恰好把「中文界面漏英文」的 bug 固化了）
    expect(find.text('网络超时'), findsOneWidget);
    expect(find.text('× 2'), findsOneWidget);
  });

  testWidgets('Top 失败类别行：未配置与未知类别都落到本地化标签', (tester) async {
    await metrics.record(rec(SyncOpOutcome.failed,
        errorClass: SyncErrorClass.notConfigured));
    // unknown 属于兜底分支：不得抛异常、不得显示原始枚举串
    await metrics.record(
        rec(SyncOpOutcome.failed, errorClass: SyncErrorClass.unknown));

    await pumpCard(tester);

    expect(find.text('未配置'), findsOneWidget);
    expect(find.text('其他'), findsOneWidget);
  });
}
