/// 自定义字段值桶共享视图（`CustomFieldStatsView`）契约测试。
///
/// 该视图从 `range_report_page.dart` 的 `_customFieldStats/_customFieldValueRows`
/// 抽出，供区间报表与洞察页共用。保护四件事：
/// 1. 按维度（dim）金额降序取桶，金额展示取同维度值；
/// 2. topN=8，超出合并「其他」（金额/笔数求和）；
/// 3. 笔数走 `analyticsTxCountShort`，金额走 `AmountText`（showCurrency + 紧凑格式）；
/// 4. 空字段列表渲染为空（调用方负责「非空才出卡」）。
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/providers.dart';
import 'package:piggycount/services/custom_field_stats_service.dart';
import 'package:piggycount/widgets/biz/amount_text.dart';
import 'package:piggycount/widgets/analytics/custom_field_stats_view.dart';

CustomFieldFieldStats field(
  String name, {
  required Map<String, ({double income, double expense, int count})> buckets,
}) {
  return CustomFieldFieldStats(
    fieldSyncId: 'f-$name',
    name: name,
    fieldType: 'amount',
    buckets: buckets,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppLocalizations l10n;

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('zh'));
  });

  Widget host(List<CustomFieldFieldStats> fields, String dim) {
    return ProviderScope(
      // AmountText(showCurrency) 会 watch 当前账本；注入假流避免真实 drift
      // QueryStream —— 它在树释放时排零位定时器，触发「A Timer is still pending」。
      overrides: [
        currentLedgerProvider.overrideWith((ref) => Stream<Ledger?>.value(null)),
      ],
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: CustomFieldStatsView(fields: fields, dim: dim),
        ),
      ),
    );
  }

  List<double> amounts(WidgetTester tester) => tester
      .widgetList<AmountText>(find.byType(AmountText))
      .map((w) => w.value)
      .toList();

  /// pump + 推完首帧排下的零位定时器（drift 流取消 / Logger 节流），
  /// 否则收尾断言触发「A Timer is still pending」（项目记忆既有坑）。
  Future<void> pumpHost(
      WidgetTester tester, List<CustomFieldFieldStats> fields, String dim) async {
    await tester.pumpWidget(host(fields, dim));
    await tester.pump(const Duration(seconds: 3));
  }

  testWidgets('支出维度：按 expense 降序渲染值桶行（标签/笔数/金额）',
      (tester) async {
    await pumpHost(tester, [
      field('渠道', buckets: {
        '微信': (income: 0, expense: 300, count: 3),
        '支付宝': (income: 0, expense: 100, count: 1),
      }),
    ], 'expense');

    expect(find.text('渠道'), findsOneWidget);
    // 降序：微信在前
    expect(
        tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .toList()
            .indexOf('微信'),
        lessThan(tester
            .widgetList<Text>(find.byType(Text))
            .map((w) => w.data)
            .toList()
            .indexOf('支付宝')));
    expect(amounts(tester), [300, 100]);
    expect(find.text(l10n.analyticsTxCountShort(3)), findsOneWidget);
    expect(find.text(l10n.analyticsTxCountShort(1)), findsOneWidget);
  });

  testWidgets('收入维度：金额与排序都取 income', (tester) async {
    await pumpHost(tester, [
      field('渠道', buckets: {
        'A': (income: 50, expense: 900, count: 1),
        'B': (income: 70, expense: 10, count: 1),
      }),
    ], 'income');

    final texts = tester
        .widgetList<Text>(find.byType(Text))
        .map((w) => w.data)
        .toList();
    expect(texts.indexOf('B'), lessThan(texts.indexOf('A')));
    expect(amounts(tester), [70, 50]);
  });

  testWidgets('topN=8：第 9 桶起合并「其他」，金额与笔数求和', (tester) async {
    final buckets = <String, ({double income, double expense, int count})>{
      for (var i = 1; i <= 9; i++)
        'v$i': (income: 0, expense: i * 100.0, count: i),
    };
    await pumpHost(tester, [field('f', buckets: buckets)], 'expense');

    // 8 行 topN + 1 行「其他」
    expect(amounts(tester).length, 9);
    // 降序前 8：900..200
    expect(amounts(tester).take(8),
        [900.0, 800.0, 700.0, 600.0, 500.0, 400.0, 300.0, 200.0]);
    // 其他 = v1（100 元、1 笔）
    expect(amounts(tester).last, 100.0);
    expect(find.text(l10n.commonOther), findsOneWidget);
    expect(find.text(l10n.analyticsTxCountShort(1)), findsOneWidget);
  });

  testWidgets('空字段列表：渲染为空', (tester) async {
    await pumpHost(tester, const [], 'expense');

    expect(find.byType(AmountText), findsNothing);
    expect(find.byType(Text), findsNothing);
  });
}
