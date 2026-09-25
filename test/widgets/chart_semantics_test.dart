/// U2「图表」这一层：趋势图必须有读屏摘要。
///
/// 为什么专门守一条：两类趋势图都是**画**出来的（fl_chart / CustomPaint +
/// TextPainter），补摘要之前语义树里一个节点都没有 —— 读屏用户切到"支出趋势"
/// 卡得到的是静默。静默不像崩溃会报错，没有断言就永远没人发现。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart' as db;
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/widgets/charts/analytics_bar_chart.dart';
import 'package:piggycount/widgets/charts/asset_composition_chart.dart';
import 'package:piggycount/widgets/charts/category_pie_chart.dart';
import 'package:piggycount/widgets/charts/line_chart.dart';

/// 只取"我们自己加的那个"摘要节点：带 label 且无 child（轴标签是带 child 的
/// Text，读屏节点由文本自身产生）。
Finder chartSummaryNode() => find.byWidgetPredicate((w) =>
    w is Semantics && w.properties.label != null && w.child == null);

String summaryLabel(WidgetTester tester) {
  final found = chartSummaryNode();
  expect(found, findsOneWidget, reason: '摘要节点必须唯一，重复标注会念两遍');
  return (tester.widgetList(found).single as Semantics).properties.label!;
}

Future<void> pump(WidgetTester tester, Widget chart) async {
  await tester.pumpWidget(ProviderScope(
    child: MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      home: Scaffold(body: SizedBox(height: 240, child: chart)),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const values = [120.0, 80.0, 200.5];
  const labels = ['3/1', '3/2', '3/3'];

  testWidgets('柱状图：整条序列摊成一句可读摘要', (tester) async {
    await pump(
      tester,
      AnalyticsBarChart(
        values: values,
        xLabels: labels,
        highlightIndex: 2,
        hideAmounts: false,
        themeColor: Colors.blue,
        isDark: false,
        onSwipeLeft: () {},
        onSwipeRight: () {},
      ),
    );

    final text = summaryLabel(tester);
    expect(text, contains('3')); // 点数
    expect(text, contains('3/1 120.00'));
    expect(text, contains('3/3 200.50'));
  });

  testWidgets('金额隐藏时摘要不泄露金额', (tester) async {
    await pump(
      tester,
      AnalyticsBarChart(
        values: values,
        xLabels: labels,
        highlightIndex: null,
        hideAmounts: true,
        themeColor: Colors.blue,
        isDark: false,
        onSwipeLeft: () {},
        onSwipeRight: () {},
      ),
    );

    final text = summaryLabel(tester);
    expect(text, contains('3/1'));
    expect(text.contains('120.00'), isFalse, reason: '隐藏金额不该从读屏漏出去');
  });

  testWidgets('折线图：双线各值都进摘要，顺序与 series 一致', (tester) async {
    await pump(
      tester,
      LineChart(
        values: const [100.0, 90.0],
        secondaryValues: const [30.0, 40.0],
        xLabels: const ['8月', '9月'],
        highlightIndex: null,
        onSwipeLeft: () {},
        onSwipeRight: () {},
        showHint: false,
        themeColor: Colors.blue,
      ),
    );

    final text = summaryLabel(tester);
    expect(text, contains('8月 100.00 / 30.00'));
    expect(text, contains('9月 90.00 / 40.00'));
  });

  testWidgets('分类饼图：各扇区名称+占比进摘要', (tester) async {
    final item = (
      id: 1,
      name: '餐饮',
      category: null as db.Category?,
      total: 60.0,
      subCategories:
          <({int id, db.Category category, String name, double total})>[],
    );
    await pump(
      tester,
      CategoryPieChart(data: [item], sum: 100.0),
    );

    final text = summaryLabel(tester);
    expect(text, contains('餐饮 60.0%'));
  });

  testWidgets('资产构成饼图：各类型名称+占比进摘要', (tester) async {
    await pump(
      tester,
      AssetCompositionChart(
        data: const [
          (type: 'cash', totalBalance: 700.0),
          (type: 'bank_card', totalBalance: 300.0),
        ],
        embedded: true,
      ),
    );

    final text = summaryLabel(tester);
    expect(text, contains('70.0%'));
    expect(text, contains('30.0%'));
  });
}
