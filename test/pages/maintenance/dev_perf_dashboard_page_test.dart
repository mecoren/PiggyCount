/// 性能仪表盘（debug 入口）契约：
/// - 采集器在非 release 下可用，start/stop 幂等，reset 清空；
/// - 无采样时页面给空态而不是空白页。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/maintenance/dev_perf_dashboard_page.dart';
import 'package:piggycount/services/platform/perf_metrics_collector.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() => PerfMetricsCollector.instance.stop());

  test('采集器：start/stop 幂等，reset 清空', () {
    final c = PerfMetricsCollector.instance;
    expect(PerfMetricsCollector.supported, isTrue,
        reason: '测试跑在 kReleaseMode=false，采集器应可用');
    expect(c.samples, isEmpty);

    c.start();
    expect(c.isRunning, isTrue);
    c.start(); // 幂等：重复 start 不重复注册回调
    expect(c.isRunning, isTrue);

    c.reset();
    expect(c.samples, isEmpty);

    c.stop();
    expect(c.isRunning, isFalse);
    c.stop(); // 幂等
    expect(c.isRunning, isFalse);
  });

  testWidgets('无采样时展示空态', (tester) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const DevPerfDashboardPage(),
      ),
    ));
    await tester.pump();

    expect(find.text('还没有采样'), findsOneWidget);

    // 页面用 Timer.periodic 刷新：必须显式卸载，否则测试结束会留 pending timer
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  });
}
