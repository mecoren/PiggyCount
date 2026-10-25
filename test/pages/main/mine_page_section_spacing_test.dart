import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/providers/avatar_providers.dart';
import 'package:piggycount/widgets/biz/profile_card.dart';
import 'package:piggycount/widgets/ui/gradient_backdrop_filter.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  test('我的页保留 12dp 菜单顶间距并使用折叠吸顶头部', () {
    final source = File('lib/pages/main/mine_page.dart').readAsStringSync();

    _expect(
      RegExp(
        r'SliverPersistentHeader\(\s*pinned: true,[\s\S]*?'
        r'minExtent: ProfileCard\.collapsedHeight\(context, ref\),\s*'
        r'maxExtent: ProfileCard\.expandedHeight\(context, ref\),',
      ).hasMatch(source),
      'MinePage uses a pinned collapsible profile header',
    );
    _expect(
      RegExp(
        r'SliverPadding\(\s*padding: EdgeInsets\.fromLTRB\(\s*'
        r'PiggyDimens\.p16,\s*PiggyDimens\.p12,\s*PiggyDimens\.p16,',
      ).hasMatch(source),
      'the first MinePage section uses the standard 12dp top gap',
    );
  });

  testWidgets('头部折叠时资料渐隐、统计保留且渐进模糊生效', (tester) async {
    Widget host(double progress, {double textScale = 1.0}) =>
        _profileHost(progress, textScale: textScale);

    const collapsible = ValueKey('profile-collapsible-content');
    const statistics = ValueKey('profile-statistics');

    await tester.pumpWidget(host(0));
    await tester.pumpAndSettle();
    expect(tester.widget<Opacity>(find.byKey(collapsible)).opacity, 1);
    expect(find.byKey(statistics), findsOneWidget);
    expect(find.text('1116'), findsOneWidget);
    expect(find.text('5003'), findsOneWidget);
    expect(find.byType(BackdropFilter), findsNothing);

    await tester.pumpWidget(host(0.5));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byKey(collapsible)).opacity, 0.5);
    expect(
      tester
          .widget<GradientBackdropFilter>(
            find.byType(GradientBackdropFilter),
          )
          .opacity,
      0.5,
    );

    await tester.pumpWidget(host(1));
    await tester.pump();
    expect(tester.widget<Opacity>(find.byKey(collapsible)).opacity, 0);
    expect(find.byKey(statistics), findsOneWidget);
    expect(find.byType(BackdropFilter), findsOneWidget);
    // 降级路径（Skia/测试后端）：mask 只能在 filter 内部，外套 mask 或 Opacity
    // 都会因 saveLayer 让 backdrop 失效（2026-10-25 golden 探针实测）
    expect(
      find.descendant(
        of: find.byType(BackdropFilter),
        matching: find.byType(ShaderMask),
      ),
      findsOneWidget,
    );
    expect(
      find.ancestor(
        of: find.byType(BackdropFilter),
        matching: find.byType(Opacity),
      ),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统字号放大时统计单元不溢出', (tester) async {
    // 真机 48px 统计槽位曾因系统字号高出 1px 触发底部溢出（2026-10-25）
    await tester.pumpWidget(_profileHost(1, textScale: 1.3));
    await tester.pumpAndSettle();
    expect(find.text('1116'), findsOneWidget);
    expect(find.text('5003'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('个性化设置的模糊强度接入头部模糊层', (tester) async {
    await tester.pumpWidget(_profileHost(1, blurSigma: 4.0));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<GradientBackdropFilter>(
            find.byType(GradientBackdropFilter),
          )
          .maxSigma,
      4.0,
    );
  });
}

Widget _profileHost(
  double progress, {
  double textScale = 1.0,
  double? blurSigma,
}) {
  return ProviderScope(
    overrides: [
      avatarPathProvider.overrideWith((ref) async => null),
      countsForLedgerProvider(1).overrideWith(
        (ref) async => (dayCount: 1116, txCount: 5003),
      ),
      currentBalanceProvider(1).overrideWith((ref) async => 9039346.89),
      currentLedgerProvider.overrideWith((ref) => Stream.value(null)),
      if (blurSigma != null)
        headerBlurSigmaProvider.overrideWith((ref) => blurSigma),
    ],
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(
        body: Builder(
          builder: (context) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: Align(
              alignment: Alignment.topCenter,
              child: Consumer(
                builder: (context, ref, _) {
                  final min = ProfileCard.collapsedHeight(context, ref);
                  final max = ProfileCard.expandedHeight(context, ref);
                  return SizedBox(
                    height: max - (max - min) * progress,
                    child: ProfileCard(collapseProgress: progress),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void _expect(bool condition, String description) {
  if (!condition) {
    throw StateError('Expected $description.');
  }
}
