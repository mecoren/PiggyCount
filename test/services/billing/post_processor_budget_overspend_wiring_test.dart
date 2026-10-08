// PostProcessor 接线契约：预算超支检测必须挂在 `_doSync*` 公共出口上
// （六个公开方法 run/runC/runR/sync/syncC/syncR 全收敛于此），且开关关闭时
// 不做任何预算聚合查询 —— 记账主路径的常态开销只能是「一次偏好读」。
//
// 这里用「记录 getBudgetOverview 调用次数」的仓储探针证明接线真的生效，
// 不依赖通知插件（非 Android/iOS 宿主上 NotificationFactory 会抛异常）。

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/budget_repository.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/providers/database_providers.dart';
import 'package:piggycount/providers/sync_providers.dart';
import 'package:piggycount/services/billing/post_processor.dart';
import 'package:piggycount/services/system/budget_overspend_notifier.dart';

/// 只记录「预算概览查询次数」的仓储探针。
class _SpyRepository extends LocalRepository {
  _SpyRepository(super.db);

  int overviewCalls = 0;

  @override
  Future<BudgetOverview> getBudgetOverview(int ledgerId, DateTime month) {
    overviewCalls++;
    return super.getBudgetOverview(ledgerId, month);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late _SpyRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = _SpyRepository(db);
    await db.into(db.ledgers).insert(LedgersCompanion.insert(
          id: const d.Value(1),
          name: '账本',
          currency: const d.Value('CNY'),
          syncId: const d.Value('ledger-1'),
        ));
  });

  tearDown(() async => db.close());

  ProviderContainer buildContainer() {
    final container = ProviderContainer(
      retry: (_, __) => null,
      overrides: [
        repositoryProvider.overrideWithValue(repo),
        syncServiceProvider.overrideWithValue(LocalOnlySyncService()),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  /// 等 fire-and-forget 的检测链路跑完（in-memory 库，通常一两帧即可）。
  Future<void> settle() async {
    for (var i = 0; i < 100 && repo.overviewCalls == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    // 无论是否命中，都再让事件循环空转一轮，避免遗留未完成的异步
    await Future<void>.delayed(Duration.zero);
  }

  test('开关关闭：sync 出口不做预算查询（主路径零额外开销）', () async {
    final container = buildContainer();

    await PostProcessor.syncC(container, ledgerId: 1);
    await settle();

    expect(repo.overviewCalls, 0);
  });

  test('开关开启：sync 出口触发预算聚合（接线生效）', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBudgetOverspendReminderEnabledKey, true);
    final container = buildContainer();

    await PostProcessor.syncC(container, ledgerId: 1);
    await settle();

    expect(
      repo.overviewCalls,
      greaterThan(0),
      reason: 'sync 系列也必须触发检测（手动记账编辑器走的就是 sync）',
    );
  });

  test('开关开启 + 超支：链路完整跑到通知层仍不向记账路径抛异常', () async {
    // 非 Android/iOS 宿主上 NotificationFactory.getInstance() 会抛
    // UnsupportedError —— 服务内部必须吞掉它（降级为「没提醒」而不是「记账失败」）。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(kBudgetOverspendReminderEnabledKey, true);
    final container = buildContainer();
    final categoryId = await db
        .into(db.categories)
        .insert(CategoriesCompanion.insert(name: '餐饮', kind: 'expense'));
    await repo.createBudget(ledgerId: 1, type: 'total', amount: 1000);
    await repo.addTransaction(
      ledgerId: 1,
      type: 'expense',
      amount: 5000,
      categoryId: categoryId,
      happenedAt: DateTime.now(),
    );

    await PostProcessor.syncC(container, ledgerId: 1);
    await settle();

    expect(repo.overviewCalls, greaterThan(0));
  });
}
