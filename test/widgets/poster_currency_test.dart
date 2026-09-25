/// 海报金额单位跟随账本本位币（A1）回归。
///
/// 历史缺陷：三个总结海报把金额单位写死成 `l10n.sharePosterUnitYuan`
/// （zh「元」/ en·ko「CNY」），外币账本会把 `$1,234.00` 印成「1,234.00 元」，
/// 单位是错的。修复后符号来自 `getCurrencySymbol(data.currencyCode)`
/// （账本本位币）并前置到数字之前。
///
/// 本测试同时锁住两处易回归的细节：
/// - 币种符号不是「元」/ 不是币种码（否则外币账本又印错单位）；
/// - 负值拼成 `-¥1,234.56` 而不是 `¥-1,234.56`。
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/export/share_poster_types.dart';
import 'package:piggycount/widgets/posters/ledger_summary_poster.dart';
import 'package:piggycount/widgets/posters/month_summary_poster.dart';
import 'package:piggycount/widgets/posters/year_summary_poster.dart';

const _category = CategoryTotal(name: '餐饮', total: 600, percentage: 0.5);

YearSummaryPosterData _yearData({String currencyCode = 'CNY'}) =>
    YearSummaryPosterData(
      year: 2026,
      recordDays: 100,
      recordCount: 300,
      totalIncome: 5000,
      totalExpense: 1234.56,
      topExpenseCategories: const [_category],
      topIncomeCategories: const [],
      avgMonthlyExpense: 100,
      avgMonthlyIncome: 400,
      maxExpenseMonth: 6,
      maxExpenseAmount: 900,
      balance: 3765.44,
      currencyCode: currencyCode,
    );

MonthSummaryPosterData _monthData({String currencyCode = 'CNY'}) =>
    MonthSummaryPosterData(
      year: 2026,
      month: 6,
      recordCount: 30,
      totalIncome: 5000,
      totalExpense: 1234.56,
      topExpenseCategories: const [_category],
      topIncomeCategories: const [],
      avgDailyExpense: 41.15,
      balance: 3765.44,
      currencyCode: currencyCode,
    );

LedgerSummaryPosterData _ledgerData({String currencyCode = 'CNY'}) =>
    LedgerSummaryPosterData(
      ledgerName: '日常',
      recordDays: 100,
      recordCount: 300,
      totalIncome: 5000,
      totalExpense: 1234.56,
      topExpenseCategories: const [_category],
      topIncomeCategories: const [],
      firstRecordDate: DateTime(2026, 1, 1),
      lastRecordDate: DateTime(2026, 6, 30),
      balance: 3765.44,
      currencyCode: currencyCode,
    );

/// 「渲染出了空串文本」= 守卫（unit.isNotEmpty）漏了，会在数值后留一段
/// 孤零零的间距。
final Finder _emptyText = find.byWidgetPredicate(
    (w) => w is Text && (w.data ?? '').isEmpty && w.textSpan == null);

void main() {
  setUpAll(() async {
    // 海报内的 DateFormat（MMMM / y）需要目标语言的日期符号。
    await initializeDateFormatting('zh');
    await initializeDateFormatting('ko');
  });

  /// 海报是 750×1334 的定尺画布，默认测试视口（800×600）装不下，
  /// 不放大视口会以 Column 溢出异常收场。
  Future<void> pumpPoster(WidgetTester tester, Widget poster,
      {Locale locale = const Locale('zh')}) async {
    tester.view.physicalSize = const Size(750, 1400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      home: Scaffold(body: poster),
    ));
    await tester.pump();
  }

  /// 外币账本的通用断言：出符号、不出写死的「元」/ 币种码。
  void expectForeignSymbol({required String symbol}) {
    expect(find.textContaining(symbol), findsWidgets,
        reason: '海报表头应出现账本币种符号 $symbol');
    expect(find.textContaining('元'), findsNothing,
        reason: '外币账本不得再显示「元」');
    expect(find.textContaining('CNY'), findsNothing,
        reason: '外币账本不得再显示币种码 CNY');
  }

  testWidgets('年度海报：USD 账本用 \$ 前缀金额，不出「元」', (tester) async {
    await pumpPoster(
      tester,
      YearSummaryPoster(
        data: _yearData(currencyCode: 'USD'),
        primaryColor: const Color(0xFFF5A623),
      ),
    );

    expect(find.text(r'$1,234.56'), findsOneWidget);
    expect(find.text(r'$5,000.00'), findsOneWidget);
    expectForeignSymbol(symbol: r'$');
  });

  testWidgets('月度海报：EUR 账本用 € 前缀金额，不出「元」', (tester) async {
    await pumpPoster(
      tester,
      MonthSummaryPoster(
        data: _monthData(currencyCode: 'EUR'),
        primaryColor: const Color(0xFFF5A623),
      ),
    );

    expect(find.text('€1,234.56'), findsOneWidget);
    expectForeignSymbol(symbol: '€');
  });

  testWidgets('账本海报：CNY 账本用 ¥ 前缀金额', (tester) async {
    await pumpPoster(
      tester,
      LedgerSummaryPoster(
        data: _ledgerData(currencyCode: 'CNY'),
        primaryColor: const Color(0xFFF5A623),
      ),
    );

    expect(find.text('¥1,234.56'), findsOneWidget);
    expect(find.text('¥5,000.00'), findsOneWidget);
  });

  // 守卫回归用 ko 而不是 en：两者 `sharePosterUnitCount` 都是空串，但 en 的
  // 文案在测试字体（等宽 1em/字）下会把年海报本来就很紧的几行挤到溢出，
  // 那是既有的宽度问题，不该混进守卫断言。ko 文案短，能干净地断言守卫本身。
  testWidgets('KO 账本海报：计数单位为空串时不渲染空 Text（不留孤立空隙）', (tester) async {
    await pumpPoster(
      tester,
      LedgerSummaryPoster(
        data: _ledgerData(currencyCode: 'USD'),
        primaryColor: const Color(0xFFF5A623),
      ),
      locale: const Locale('ko'),
    );

    // 天数单位 ko = '일'，照常显示；
    expect(find.text('일'), findsOneWidget);
    // 笔数单位 ko = '' → 连间距一起省掉（守卫：unit.isNotEmpty）。
    expect(_emptyText, findsNothing);
  });

  testWidgets('KO 年/月海报：计数单位为空串时不渲染空 Text', (tester) async {
    await pumpPoster(
      tester,
      YearSummaryPoster(
        data: _yearData(currencyCode: 'USD'),
        primaryColor: const Color(0xFFF5A623),
      ),
      locale: const Locale('ko'),
    );
    expect(find.text('일'), findsOneWidget);
    expect(_emptyText, findsNothing);

    await pumpPoster(
      tester,
      MonthSummaryPoster(
        data: _monthData(currencyCode: 'USD'),
        primaryColor: const Color(0xFFF5A623),
      ),
      locale: const Locale('ko'),
    );
    expect(_emptyText, findsNothing);
  });

  testWidgets('负结余：符号在负号之后（-¥1,234.56 而非 ¥-1,234.56）', (tester) async {
    await pumpPoster(
      tester,
      YearSummaryPoster(
        data: YearSummaryPosterData(
          year: 2026,
          recordDays: 1,
          recordCount: 1,
          totalIncome: 100,
          totalExpense: 1334.56,
          topExpenseCategories: const [],
          topIncomeCategories: const [],
          avgMonthlyExpense: 0,
          avgMonthlyIncome: 0,
          balance: -1234.56,
        ),
        primaryColor: const Color(0xFFF5A623),
      ),
    );

    expect(find.text('-¥1,234.56'), findsOneWidget);
    expect(find.text('¥-1,234.56'), findsNothing);
  });
}
