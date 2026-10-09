import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/pages/settings/changelog_data.dart';
import 'package:piggycount/pages/settings/changelog_page.dart';
import 'package:piggycount/widgets/biz/settings_widgets.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget host() {
    return ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('zh'),
        home: const ChangelogPage(),
      ),
    );
  }

  testWidgets('列表页展示版本卡片，点击进入详情页', (tester) async {
    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final v010 = kChangelogVersions.first;
    expect(find.text('v${v010.version}'), findsOneWidget);
    // 副标题含发布日期。断言收在「最新版本卡片」内：同一天可以发多个版本，
    // 全列表 `find.textContaining(date)` 会命中多条（0.1.2 / 0.1.3 同为 2026-10-10）。
    expect(
      find.descendant(
        of: find.ancestor(
          of: find.text('v${v010.version}'),
          matching: find.byType(SettingsCard),
        ),
        matching: find.textContaining(v010.date),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('v${v010.version}'));
    await tester.pumpAndSettle();

    // 详情页：标题与摘要
    expect(find.text(v010.summary), findsOneWidget);
    // 首个分组标题可见
    expect(find.text(v010.sections.first.title), findsOneWidget);
  });

  testWidgets('详情页完整渲染全部分组与条目', (tester) async {
    // 拉高表面尺寸让 ListView 全量构建，便于断言每一条
    await tester.binding.setSurfaceSize(const Size(800, 4000));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(host());
    await tester.pumpAndSettle();

    final v010 = kChangelogVersions.first;
    await tester.tap(find.text('v${v010.version}'));
    await tester.pumpAndSettle();

    for (final section in v010.sections) {
      expect(find.text(section.title), findsOneWidget);
      for (final item in section.items) {
        expect(find.text(item), findsOneWidget);
      }
    }
  });

  test('数据契约：版本倒序、分组与条目非空', () {
    expect(kChangelogVersions, isNotEmpty);
    for (final v in kChangelogVersions) {
      expect(v.version, isNotEmpty);
      expect(v.date, isNotEmpty);
      expect(v.summary, isNotEmpty);
      expect(v.sections, isNotEmpty);
      expect(v.itemCount, greaterThan(0));
      for (final s in v.sections) {
        expect(s.title, isNotEmpty);
        expect(s.items, isNotEmpty);
        for (final item in s.items) {
          expect(item, isNotEmpty);
        }
      }
    }
    // 最新版本在前（按日期倒序）
    final dates = kChangelogVersions.map((v) => v.date).toList();
    final sorted = [...dates]..sort((a, b) => b.compareTo(a));
    expect(dates, sorted);
  });
}
