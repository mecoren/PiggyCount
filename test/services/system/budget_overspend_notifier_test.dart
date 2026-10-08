// 预算超支实时推送：只推 100% / 同周期只推一次 / 跨周期恢复 / 开关短路 /
// 水位清理 / ID 段隔离。
//
// 预算口径（含 exclude_from_budget 排除、子分类归并、账本 monthStartDay 周期）
// 由既有预算仓储测试钉住，本文件只证明「超支判定 → 推送 → 去重水位」这条链。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/system/budget_overspend_notifier.dart';
import 'package:piggycount/services/system/recurring_due_reminder_service.dart';

import '../../support/fake_notification_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;
  late FakeNotificationUtil notifications;
  late int diningCategoryId;

  const ledgerId = 1;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    notifications = FakeNotificationUtil();

    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(ledgerId),
          name: '账本',
          currency: const d.Value('CNY'),
          syncId: const d.Value('ledger-1'),
        ));
    diningCategoryId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
  });

  tearDown(() async => db.close());

  BudgetOverspendNotifier notifier() => BudgetOverspendNotifier(
        repository: repo,
        notificationUtil: notifications,
      );

  Future<void> enableSwitch(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBudgetOverspendReminderEnabledKey, enabled);
  }

  /// 建「总预算 1000 + 餐饮分类预算 500」。
  Future<({int totalId, int categoryId})> seedBudgets() async {
    final totalId = await repo.createBudget(
      ledgerId: ledgerId,
      type: 'total',
      amount: 1000,
    );
    final categoryBudgetId = await repo.createBudget(
      ledgerId: ledgerId,
      type: 'category',
      categoryId: diningCategoryId,
      amount: 500,
    );
    return (totalId: totalId, categoryId: categoryBudgetId);
  }

  Future<void> spend(double amount, {DateTime? at}) async {
    await repo.addTransaction(
      ledgerId: ledgerId,
      type: 'expense',
      amount: amount,
      categoryId: diningCategoryId,
      happenedAt: at ?? DateTime.now(),
    );
  }

  /// 当前周期起始日（账本 monthStartDay = 1 → 自然月）。
  DateTime currentPeriodStart() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, 1);
  }

  group('通知 ID 段', () {
    test('4000 + budgetId 落在 4000..4999，不与其它段重叠', () {
      expect(BudgetOverspendNotifier.notificationIdFor(1), 4001);
      // 段容量前提：budgetId < 1000（见 notificationIdFor 文档）
      expect(BudgetOverspendNotifier.notificationIdFor(999), lessThan(5000));
      expect(BudgetOverspendNotifier.notificationIdBase, 4000);
    });

    test('避开既有段：1001 每日提醒 / 1000~1999 自动记账 / 2000 信用卡 / 3000 到期提醒',
        () {
      final id = BudgetOverspendNotifier.notificationIdFor(1);
      expect(BudgetOverspendNotifier.notificationIdBase, greaterThanOrEqualTo(4000));
      expect(id, isNot(1001));
      expect(id, isNot(2001));
      // 到期提醒段（3000..3999）不得与超支段（4000..) 交叠
      expect(
        RecurringDueReminderService.notificationIdBase,
        lessThan(BudgetOverspendNotifier.notificationIdBase),
      );
    });
  });

  test('开关关闭 → 一次都不推，且不写水位', () async {
    await seedBudgets();
    await spend(1200);

    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(notifications.shown, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs
          .getKeys()
          .where((k) => k.startsWith(BudgetOverspendNotifier.watermarkPrefix)),
      isEmpty,
    );
  });

  test('未超支 → 不推', () async {
    await enableSwitch(true);
    await seedBudgets();
    await spend(100);

    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(notifications.shown, isEmpty);
  });

  test('超支 → 总预算与分类预算各推一条，ID = 4000 + budgetId', () async {
    await enableSwitch(true);
    final ids = await seedBudgets();
    await spend(1200);

    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(notifications.shown, hasLength(2));
    expect(
      notifications.shown.map((e) => e.id).toSet(),
      {
        BudgetOverspendNotifier.notificationIdFor(ids.totalId),
        BudgetOverspendNotifier.notificationIdFor(ids.categoryId),
      },
    );
    // 分类预算那条带分类名；总预算那条走通用名
    final bodies = notifications.shown.map((e) => e.body).join('\n');
    expect(bodies, contains('餐饮'));

    // 当前周期水位已写
    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getBool(BudgetOverspendNotifier.watermarkKey(
          ids.totalId, currentPeriodStart())),
      isTrue,
    );
  });

  test('同一周期重复检测 → 只推一次', () async {
    await enableSwitch(true);
    await seedBudgets();
    await spend(1200);

    await notifier().checkAfterWrite(ledgerId: ledgerId);
    await notifier().checkAfterWrite(ledgerId: ledgerId);
    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(notifications.shown, hasLength(2), reason: '水位命中后不得重复推送');
  });

  test('跨周期 → 再次可推，并清掉旧周期水位', () async {
    await enableSwitch(true);
    final ids = await seedBudgets();
    await spend(1200);

    // 伪造「上一周期已推过」
    final prefs = await SharedPreferences.getInstance();
    final staleKey = BudgetOverspendNotifier.watermarkKey(
      ids.totalId,
      DateTime(2026, 1, 1),
    );
    await prefs.setBool(staleKey, true);

    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(
      notifications.shown.map((e) => e.id),
      contains(BudgetOverspendNotifier.notificationIdFor(ids.totalId)),
      reason: '旧周期水位不得拦住新周期推送',
    );
    expect(prefs.getBool(staleKey), isNull, reason: '旧周期水位应被清理');
  });

  test('已停用的分类预算不参与超支判定', () async {
    await enableSwitch(true);
    final ids = await seedBudgets();
    await repo.updateBudget(ids.categoryId, enabled: false);
    await spend(600);

    await notifier().checkAfterWrite(ledgerId: ledgerId);

    expect(
      notifications.shown.map((e) => e.id),
      isNot(contains(BudgetOverspendNotifier.notificationIdFor(ids.categoryId))),
    );
  });
}
