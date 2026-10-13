/// PDF 报表取数（`PdfReportService.loadData`）的口径回归：**报表的数必须跟界面上
/// 看到的对得上**（报销 / 对账场景，用户会拿 PDF 跟首页核对）。
///
/// 这里钉住「区间 / 排除项 / 转账 / 层级聚合 / 桶粒度」这几处最容易各错一半的
/// 地方，全部跑在 Drift 内存库上（真跑 SQL，不是 mock）。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/l10n/app_localizations.dart';
import 'package:piggycount/services/export/pdf_report_service.dart';
import 'package:piggycount/services/export/pdf_report_types.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final zh = lookupAppLocalizations(const Locale('zh'));

  late PiggyDatabase db;
  late LocalRepository repo;

  /// 分类：餐饮（一级）/ 交通（餐饮的子分类，验证层级聚合）/ 工资（收入）
  late int diningId;
  late int transportId;
  late int salaryId;
  late int cashAccountId;
  late int bankAccountId;

  /// Drift 的 DateTime 列往返后是 UTC 瞬间，报表侧再 `toLocal()`。
  /// 断言「哪一天」时先归一到日期，避免依赖运行机器的时区。
  DateTime dayOf(DateTime dt) {
    final local = dt.toLocal();
    return DateTime(local.year, local.month, local.day);
  }

  Future<int> insertTx({
    required String type,
    required double amount,
    required DateTime at,
    int? categoryId,
    int? accountId,
    int? toAccountId,
    bool excludeFromStats = false,
    double? nativeAmount,
    String? note,
  }) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: type,
            amount: amount,
            categoryId: d.Value(categoryId),
            accountId: d.Value(accountId),
            toAccountId: d.Value(toAccountId),
            happenedAt: d.Value(at),
            excludeFromStats: d.Value(excludeFromStats),
            nativeAmount: d.Value(nativeAmount),
            note: d.Value(note),
            syncId: d.Value('tx-$type-${at.millisecondsSinceEpoch}-$amount'),
          ));

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '家用账本',
          currency: const d.Value('cny'),
          syncId: const d.Value('ledger-1'),
        ));

    diningId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    transportId = await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: '交通',
        kind: 'expense',
        parentId: d.Value(diningId),
        level: const d.Value(2)));
    salaryId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: '工资', kind: 'income'));
    cashAccountId = await db.into(db.accounts).insert(AccountsCompanion.insert(
        ledgerId: 1,
        name: '现金',
        currency: const d.Value('CNY')));
    bankAccountId = await db.into(db.accounts).insert(AccountsCompanion.insert(
        ledgerId: 1,
        name: '招商银行',
        currency: const d.Value('CNY')));

    // 区间内（2026-10-01 ~ 2026-11-01）
    await insertTx(
        type: 'expense',
        amount: 200,
        at: DateTime(2026, 10, 3),
        categoryId: diningId,
        accountId: bankAccountId,
        note: '聚餐');
    await insertTx(
        type: 'expense',
        amount: 100,
        at: DateTime(2026, 10, 8),
        categoryId: transportId,
        accountId: cashAccountId);
    await insertTx(
        type: 'income',
        amount: 1000,
        at: DateTime(2026, 10, 5),
        categoryId: salaryId,
        accountId: bankAccountId);
    // 无分类支出（要落「未分类」而不是消失）
    await insertTx(
        type: 'expense',
        amount: 50,
        at: DateTime(2026, 10, 9),
        accountId: cashAccountId);
    // 转账：不计入收支合计与笔数，但明细里要在（拼「转出 → 转入」）
    await insertTx(
        type: 'transfer',
        amount: 500,
        at: DateTime(2026, 10, 10),
        accountId: bankAccountId,
        toAccountId: cashAccountId);
    // 外币交易：本位币快照参与统计（口径 COALESCE(native_amount, amount)）
    await insertTx(
        type: 'expense',
        amount: 30,
        nativeAmount: 210,
        at: DateTime(2026, 10, 11),
        categoryId: diningId,
        accountId: bankAccountId);
    // 「不计收支」：合计与明细都不该收（否则表里求和 ≠ 合计）
    await insertTx(
        type: 'expense',
        amount: 9999,
        at: DateTime(2026, 10, 12),
        categoryId: diningId,
        accountId: bankAccountId,
        excludeFromStats: true);
    // 窗口外干扰项
    await insertTx(
        type: 'expense',
        amount: 8888,
        at: DateTime(2026, 11, 2),
        categoryId: diningId,
        accountId: bankAccountId);
  });

  tearDown(() async => db.close());

  Future<PdfReportData> load({
    DateTime? start,
    DateTime? end,
  }) =>
      PdfReportService.loadData(
        repo,
        ledgerId: 1,
        start: start ?? DateTime(2026, 10, 1),
        end: end ?? DateTime(2026, 11, 1),
        l10n: zh,
      );

  test('收支合计、笔数与明细同口径：排除「不计收支」与区间外，转账不进合计', () async {
    final data = await load();

    expect(data.ledgerName, '家用账本');
    expect(data.currencyCode, 'CNY', reason: '账本存的是小写 cny，报表统一大写');
    expect(data.income, 1000);
    expect(data.expense, 200 + 100 + 50 + 210, reason: '外币按本位币快照 210 计');
    expect(data.txCount, 5, reason: '4 笔支出 + 1 笔收入；转账与「不计收支」都不算');
    expect(data.balance, 1000 - 560);
    expect(data.days, 31);
    expect(data.dailyAvgExpense, closeTo(560 / 31, 0.0001));
  });

  test('明细：时间升序、含转账、无分类兜底为 null、外币取本位币金额', () async {
    final data = await load();

    expect(data.entries.map((e) => e.type).toList(),
        ['expense', 'income', 'expense', 'expense', 'transfer', 'expense']);
    expect(data.entries.map((e) => dayOf(e.at)).toList(), [
      DateTime(2026, 10, 3),
      DateTime(2026, 10, 5),
      DateTime(2026, 10, 8),
      DateTime(2026, 10, 9),
      DateTime(2026, 10, 10),
      DateTime(2026, 10, 11),
    ]);
    expect(data.entries.first.note, '聚餐');
    expect(data.entries.first.categoryName, '餐饮');
    expect(data.entries.first.accountName, '招商银行');

    final transfer = data.entries.firstWhere((e) => e.type == 'transfer');
    expect(transfer.accountName, '招商银行 → 现金');
    expect(transfer.categoryName, isNull);

    // 无分类 → null（排版层补「未分类」，与分类排行的名字一致）
    final uncategorized = data.entries.firstWhere((e) => e.amount == 50);
    expect(uncategorized.categoryName, isNull);
    expect(data.entries.any((e) => e.categoryName == '默认分类'), isFalse);

    final foreign =
        data.entries.firstWhere((e) => dayOf(e.at) == DateTime(2026, 10, 11));
    expect(foreign.amount, 210, reason: '本位币口径：native_amount 优先');
  });

  test('分类排行：二级并进一级、按金额降序、名称可展示', () async {
    final data = await load();

    expect(data.expenseCategories.map((c) => c.name).toList(), ['餐饮', '未分类']);
    // 餐饮 = 200（10/3） + 210（10/11 外币） + 100（交通，二级并进父分类）
    expect(data.expenseCategories[0].total, 510);
    expect(data.expenseCategories[0].count, 3);
    expect(data.expenseCategories[1].total, 50);
    expect(data.incomeCategories.single.name, '工资');
    expect(data.incomeCategories.single.total, 1000);
  });

  test('趋势桶：短区间按日补零连续，且与合计对得上', () async {
    final data = await load();

    expect(data.byMonth, isFalse);
    expect(data.buckets.length, 31);
    expect(dayOf(data.buckets.first.bucket), DateTime(2026, 10, 1));
    expect(data.buckets[0].expense, 0, reason: '无记账的日子补 0');
    expect(data.buckets[2].expense, 200, reason: '10/3');
    expect(data.buckets[4].income, 1000, reason: '10/5');
    expect(data.buckets[10].expense, 210, reason: '10/11 外币按本位币');
    expect(data.buckets.fold<double>(0, (a, b) => a + b.expense),
        closeTo(data.expense, 0.0001));
    expect(data.buckets.fold<double>(0, (a, b) => a + b.income),
        closeTo(data.income, 0.0001));
    // 「不计收支」那笔不进趋势
    expect(data.buckets.any((b) => b.expense >= 9999), isFalse);
  });

  test('超 31 天的区间自动并月：桶标签是每月 1 号，金额并进所属月', () async {
    // 8/1 ~ 11/1（92 天）：刚好 3 个月桶，且 11/2 那笔干扰项在窗口外
    final data = await load(start: DateTime(2026, 8, 1), end: DateTime(2026, 11, 1));

    expect(data.byMonth, isTrue);
    expect(data.buckets.map((b) => dayOf(b.bucket)).toList(),
        [DateTime(2026, 8, 1), DateTime(2026, 9, 1), DateTime(2026, 10, 1)]);
    expect(data.buckets[0].expense, 0);
    expect(data.buckets[1].expense, 0);
    expect(data.buckets[2].expense, closeTo(data.expense, 0.0001));
    expect(data.expense, 560, reason: '11/2 那笔在窗口外');
  });
}
