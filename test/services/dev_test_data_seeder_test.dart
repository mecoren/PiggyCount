import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data/dev_test_data_seeder.dart';

void main() {
  // LoggerService 构造时会注册 MethodChannel，必须先初始化 binding。
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late int ledgerId;

  const plan = DevSeedPlan(
    accounts: 10,
    categories: 20,
    tags: 10,
    customFields: 2,
    budgets: 5,
    recurring: 5,
    savingsGoals: 5,
    holdings: 5,
    transactions: 60,
    trashTransactions: 30,
    extraLedgers: 1,
    extraLedgerTransactions: 10,
    extraLedgerBudgets: 5,
    refundPairs: 3,
  );

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    ledgerId = await repo.createLedger(name: '种子测试账本', currency: 'CNY');
  });

  tearDown(() async => db.close());

  test('按计划生成各实体，且无写入失败', () async {
    final result = await DevTestDataSeeder.seed(
      repo: repo,
      ledgerId: ledgerId,
      currency: 'CNY',
      plan: plan,
    );

    expect(result.failed, 0, reason: '有实体写入失败，检查 seed 的字段映射');
    expect(result.created[DevSeedStage.accounts], plan.accounts);
    expect(result.created[DevSeedStage.categories], plan.categories);
    expect(result.created[DevSeedStage.tags], plan.tags);
    expect(result.created[DevSeedStage.customFields], plan.customFields);
    expect(
      result.created[DevSeedStage.budgets],
      plan.budgets + plan.extraLedgers * plan.extraLedgerBudgets,
    );
    expect(result.created[DevSeedStage.recurring], plan.recurring);
    expect(result.created[DevSeedStage.savingsGoals], plan.savingsGoals);
    expect(result.created[DevSeedStage.holdings], plan.holdings);
    expect(result.created[DevSeedStage.ledgers], plan.extraLedgers);

    // 当前账本：正片 60 + 退款对 3×2；额外账本 10 也计入 transactions。
    expect(
      result.created[DevSeedStage.transactions],
      plan.transactions + plan.refundPairs * 2 + plan.extraLedgerTransactions,
    );
    expect(
      (await repo.getTransactionsByLedger(ledgerId)).length,
      plan.transactions + plan.refundPairs * 2,
    );

    // 退款关联真的落到了收入行上（否则 v56 链路没被测到）。
    final txs = await repo.getTransactionsByLedger(ledgerId);
    final refunds = txs.where((t) => t.refundOfId != null).toList();
    expect(refunds.length, plan.refundPairs);
    expect(refunds.every((t) => t.type == 'income'), isTrue);

    // 自定义字段值写在交易行上。
    expect(
      txs.where((t) => (t.customValuesJson ?? '').isNotEmpty).length,
      greaterThan(0),
    );

    // 交易标签关联存在。
    final tagged = await repo.getTagsForTransactions(
      txs.map((t) => t.id).toList(),
    );
    expect(tagged.values.where((tags) => tags.isNotEmpty), isNotEmpty);

    // 总预算：预算页有总预算才渲染分类预算，必须真的建出来。
    expect(result.created[DevSeedStage.totalBudget], 1 + plan.extraLedgers);
    final total = await repo.getTotalBudget(ledgerId);
    expect(total, isNotNull);
    expect(total!.amount, DevTestDataSeeder.seedTotalBudgetAmount);

    // 回收站：软删后的行不在 transactions 里，只出现在 deleted_transactions。
    expect(result.created[DevSeedStage.trash], plan.trashTransactions);
    final trash = await repo.getDeletedTransactions(ledgerId: ledgerId);
    expect(trash.length, plan.trashTransactions);
    expect(
      txs.length,
      plan.transactions + plan.refundPairs * 2,
      reason: '回收站流水不应留在交易主表',
    );
  });

  test('产物全部带标记，清理后本机不再残留测试数据', () async {
    await DevTestDataSeeder.seed(
      repo: repo,
      ledgerId: ledgerId,
      currency: 'CNY',
      plan: plan,
    );

    final cleaned = await DevTestDataSeeder.cleanup(
      repo: repo,
      ledgerId: ledgerId,
    );
    expect(cleaned.values.fold<int>(0, (a, b) => a + b), greaterThan(0));

    bool marked(String? text) =>
        (text ?? '').startsWith(DevTestDataSeeder.marker);

    expect(await repo.getTransactionsByLedger(ledgerId), isEmpty);
    expect(
      (await repo.getAllAccounts()).where((a) => marked(a.name)),
      isEmpty,
    );
    expect(
      (await repo.getAllCategories()).where((c) => marked(c.name)),
      isEmpty,
    );
    expect((await repo.getAllTags()).where((t) => marked(t.name)), isEmpty);
    expect(
      (await repo.getDefinitionsForLedger(ledgerId))
          .where((f) => marked(f.name)),
      isEmpty,
    );
    expect((await repo.getAllBudgets(ledgerId)), isEmpty);
    expect(await repo.getDeletedTransactions(ledgerId: ledgerId), isEmpty);
    expect(await repo.getTotalBudget(ledgerId), isNull);
    expect(
      (await repo.getRecurringTransactionsByLedger(ledgerId))
          .where((r) => marked(r.note)),
      isEmpty,
    );
    expect(
      (await repo.getSavingsGoalsByLedger(ledgerId))
          .where((g) => marked(g.name)),
      isEmpty,
    );
    expect((await repo.getAllHoldings()).where((h) => marked(h.name)), isEmpty);
    expect((await repo.getAllLedgers()).length, 1);
  });

  test('重复生成不会叠数据（先清理再写入）', () async {
    await DevTestDataSeeder.seed(
      repo: repo,
      ledgerId: ledgerId,
      currency: 'CNY',
      plan: plan,
    );
    final firstCount = (await repo.getTransactionsByLedger(ledgerId)).length;

    final second = await DevTestDataSeeder.seed(
      repo: repo,
      ledgerId: ledgerId,
      currency: 'CNY',
      plan: plan,
    );

    expect(second.failed, 0);
    expect((await repo.getTransactionsByLedger(ledgerId)).length, firstCount);
    expect(
      (await repo.getDeletedTransactions(ledgerId: ledgerId)).length,
      plan.trashTransactions,
    );
    expect(
      (await repo.getAllAccounts())
          .where((a) => a.name.startsWith(DevTestDataSeeder.marker))
          .length,
      plan.accounts,
    );
  });
}
