import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/providers/theme_providers.dart';
import 'package:piggycount/widgets/ui/gradient_backdrop_filter.dart';
import 'package:piggycount/widgets/ui/piggy_header.dart';

/// 守门：`_PiggyHeaderShell` 的渐进模糊层由全局 `headerBlurSigmaProvider`
/// 统一控制——sigma > 0 时全部标题栏（PiggyTitleBar/PiggyHomeBar/PiggyHeader）
/// 均带模糊层；sigma = 0 时整层省略，恢复纯实色、零滤镜开销。
void main() {
  Future<void> pumpBar(
    WidgetTester tester, {
    required double sigma,
  }) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          headerBlurSigmaProvider.overrideWith((ref) => sigma),
        ],
        child: MaterialApp(
          home: Scaffold(
            extendBodyBehindAppBar: true,
            appBar: PiggyTitleBar(title: '设置'),
            body: ListView.builder(
              itemCount: 50,
              itemBuilder: (_, i) => ListTile(title: Text('条目 $i')),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('sigma > 0 时标题栏含模糊层且强度取自 Provider', (tester) async {
    await pumpBar(tester, sigma: 7.0);

    final filters = tester
        .widgetList<GradientBackdropFilter>(
          find.byType(GradientBackdropFilter),
        )
        .toList();
    expect(filters, isNotEmpty);
    expect(filters.first.maxSigma, 7.0);
  });

  testWidgets('sigma = 0 时完全省略模糊层', (tester) async {
    await pumpBar(tester, sigma: 0.0);

    expect(find.byType(GradientBackdropFilter), findsNothing);
  });
}
