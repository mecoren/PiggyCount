/// v52 投资持仓仓储契约（HoldingsRepository / LocalRepository 委托层）。
///
/// 重点保护四件事：
/// 1. **user-global 作用域**：所有变更必须记到 `local_changes.ledger_id = 0`
///    （持仓与账户同款跨账本），记错会让变更卡在本地永不推送；
/// 2. **行情缓存列是本地专有**：写 quote_price / quote_fetched_at /
///    quote_source_id **不得**产生任何 local_changes（否则行情刷新会持续
///    制造上传噪声并污染跨设备指纹）；
/// 3. **删除账户级联删除持仓**：否则留下悬空 accountId 的孤儿持仓；
/// 4. tracker 注入 null 时（快照链路正常装配就是无 tracker）优雅跳过、不抛。
library;

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late ChangeTracker tracker;
  late LocalRepository repo;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    tracker = ChangeTracker(db);
    repo = LocalRepository(db, changeTracker: tracker);
  });

  tearDown(() async {
    await db.close();
  });

  var nameSeq = 0;

  Future<int> createInvestmentAccount() => repo.createAccount(
        ledgerId: 0,
        name: '投资账户-${nameSeq++}',
        type: 'investment',
      );

  /// 清空已产生的变更，只观察被测动作。
  Future<void> clearChanges() async {
    await tracker.markPushed(
      (await tracker.getUnpushedChanges()).map((c) => c.id).toList(),
    );
  }

  /// 取持仓的 syncId（删除类用例必须在动手前先取）。
  Future<String> syncIdOf(int holdingId) async {
    final row = await repo.getHolding(holdingId);
    expect(row, isNotNull, reason: '取 syncId 前持仓应存在');
    return row!.syncId!;
  }

  /// 断言某持仓实体有一条未推送变更，且在 user-global 通道（ledger_id = 0）。
  Future<void> expectHoldingChange(String syncId, String action) async {
    final changes = await tracker.getUnpushedChangesForLedger(0);
    final hit = changes.where((c) =>
        c.entityType == 'holding' &&
        c.entitySyncId == syncId &&
        c.action == action);
    expect(
      hit,
      isNotEmpty,
      reason: 'holding($syncId) 必须登记 $action 变更到 user-global 通道'
          '（ledger_id=0），实际未推送变更: '
          '${changes.map((c) => '${c.entityType}/${c.action}@${c.ledgerId}').toList()}',
    );
    expect(hit.first.ledgerId, 0,
        reason: '持仓是 user-global 实体，ledger_id 必须是 0');
  }

  group('创建 / 读取', () {
    test('创建：自动补 syncId + ledgerId=0，可按账户读回', () async {
      final accountId = await createInvestmentAccount();

      final id = await repo.createHolding(
        accountId: accountId,
        name: '贵州茅台',
        symbol: '600519',
        market: 'SH',
        assetClass: 'stock',
        currency: 'CNY',
        quantity: 100,
        unitCost: 1500,
        unitPrice: 1680,
      );

      final row = await repo.getHolding(id);
      expect(row, isNotNull);
      expect(row!.accountId, accountId);
      expect(row.name, '贵州茅台');
      expect(row.symbol, '600519');
      expect(row.market, 'SH');
      expect(row.assetClass, 'stock');
      expect(row.quantity, 100);
      expect(row.unitCost, 1500);
      expect(row.unitPrice, 1680);
      expect(row.autoQuote, isFalse, reason: '默认不参与行情刷新');
      expect(row.ledgerId, 0, reason: '持仓是 user-global 实体');
      expect(row.syncId, isNotNull);
      expect(row.syncId!.isNotEmpty, isTrue);
      expect(row.quotePrice, isNull, reason: '从未拉到过行情');
    });

    test('创建登记 holding 的 upsert 变更（user-global 通道）', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
        accountId: accountId,
        name: '沪深300ETF',
        currency: 'CNY',
      );

      await expectHoldingChange(await syncIdOf(id), 'upsert');
    });

    test('getHoldingsByAccount 只返回该账户的持仓，按 sortOrder / id 排序', () async {
      final a = await createInvestmentAccount();
      final b = await createInvestmentAccount();

      final a2 = await repo.createHolding(
          accountId: a, name: 'A-2', currency: 'CNY', sortOrder: 2);
      final a1 = await repo.createHolding(
          accountId: a, name: 'A-1', currency: 'CNY', sortOrder: 1);
      await repo.createHolding(accountId: b, name: 'B-1', currency: 'CNY');

      final list = await repo.getHoldingsByAccount(a);
      expect(list.map((h) => h.id).toList(), [a1, a2],
          reason: '按 sortOrder 升序；账户 b 的持仓不得混入');
    });

    test('getAllHoldings 按 id 稳定排序（快照导出可比性）', () async {
      final accountId = await createInvestmentAccount();
      final first = await repo.createHolding(
          accountId: accountId, name: 'X', currency: 'CNY');
      final second = await repo.createHolding(
          accountId: accountId, name: 'Y', currency: 'CNY');

      final all = await repo.getAllHoldings();
      expect(all.map((h) => h.id).toList(), [first, second]);
    });

    test('watchHoldingsByAccount 随写入推进', () async {
      final accountId = await createInvestmentAccount();
      final stream = repo.watchHoldingsByAccount(accountId);

      final first = await stream.first;
      expect(first, isEmpty);

      await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY');
      final second = await stream.first;
      expect(second, hasLength(1));
    });
  });

  group('更新 / 删除', () {
    test('改份额与净值登记 upsert 变更', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY', quantity: 1);
      await clearChanges();

      await repo.updateHolding(id, quantity: 200, unitPrice: 3.5);

      final row = await repo.getHolding(id);
      expect(row!.quantity, 200);
      expect(row.unitPrice, 3.5);
      expect(row.name, '基金', reason: 'null 参数不得改动其它字段');
      await expectHoldingChange(row.syncId!, 'upsert');
    });

    test('clearOptionalFields 清空 symbol / market / note', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
        accountId: accountId,
        name: '比特币',
        symbol: 'BTC',
        market: 'CRYPTO',
        note: '冷钱包',
        currency: 'CNY',
      );

      await repo.updateHolding(id, clearOptionalFields: true);

      final row = await repo.getHolding(id);
      expect(row!.symbol, isNull);
      expect(row.market, isNull);
      expect(row.note, isNull);
      expect(row.name, '比特币', reason: '必填字段不受 clear 影响');
    });

    test('删除登记 delete 变更并移除行', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY');
      final syncId = await syncIdOf(id);
      await clearChanges();

      await repo.deleteHolding(id);

      expect(await repo.getHolding(id), isNull);
      await expectHoldingChange(syncId, 'delete');
    });

    test('排序批量更新逐条登记 upsert（排序参与快照指纹）', () async {
      final accountId = await createInvestmentAccount();
      final a = await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY');
      final b = await repo.createHolding(
          accountId: accountId, name: 'B', currency: 'CNY');
      await clearChanges();

      await repo.updateHoldingSortOrders([
        (id: a, sortOrder: 1),
        (id: b, sortOrder: 0),
      ]);

      final list = await repo.getHoldingsByAccount(accountId);
      expect(list.map((h) => h.name).toList(), ['B', 'A']);
      await expectHoldingChange(await syncIdOf(a), 'upsert');
      await expectHoldingChange(await syncIdOf(b), 'upsert');
    });
  });

  group('行情缓存（本地专有列）', () {
    test('writeQuoteCache 写入三列但**不产生任何 local_changes**', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY', unitPrice: 2.0);
      await clearChanges();
      final before = await tracker.getUnpushedChanges();
      expect(before, isEmpty);

      await repo.writeQuoteCache(
        id,
        price: 2.35,
        fetchedAt: DateTime(2026, 10, 8, 15, 0),
        sourceId: 'eastmoney',
      );

      final row = await repo.getHolding(id);
      expect(row!.quotePrice, 2.35);
      expect(row.quoteFetchedAt, DateTime(2026, 10, 8, 15, 0));
      expect(row.quoteSourceId, 'eastmoney');
      expect(row.unitPrice, 2.0, reason: '手填净值不得被行情写入覆盖');

      expect(
        await tracker.getUnpushedChanges(),
        isEmpty,
        reason: '行情缓存是本地专有列，写它绝不能制造待推送变更',
      );
    });

    test('clearQuoteCache 只清缓存列、保留手填净值', () async {
      final accountId = await createInvestmentAccount();
      final id = await repo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY', unitPrice: 2.0);
      await repo.writeQuoteCache(id, price: 2.35, sourceId: 'eastmoney');
      await clearChanges();

      await repo.clearQuoteCache();

      final row = await repo.getHolding(id);
      expect(row!.quotePrice, isNull);
      expect(row.quoteSourceId, isNull);
      expect(row.unitPrice, 2.0);
      expect(await tracker.getUnpushedChanges(), isEmpty);
    });

    test('按 sourceId 定向清理：只清该源的缓存', () async {
      final accountId = await createInvestmentAccount();
      final a = await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY');
      final b = await repo.createHolding(
          accountId: accountId, name: 'B', currency: 'CNY');
      await repo.writeQuoteCache(a, price: 1, sourceId: 'eastmoney');
      await repo.writeQuoteCache(b, price: 2, sourceId: 'yahoo');

      await repo.clearQuoteCache(sourceId: 'eastmoney');

      expect((await repo.getHolding(a))!.quotePrice, isNull);
      expect((await repo.getHolding(b))!.quotePrice, 2);
    });
  });

  group('口径判定与级联', () {
    test('hasHoldings / getAccountIdsWithHoldings', () async {
      final empty = await createInvestmentAccount();
      final holding = await createInvestmentAccount();
      await repo.createHolding(
          accountId: holding, name: '基金', currency: 'CNY');

      expect(await repo.hasHoldings(empty), isFalse);
      expect(await repo.hasHoldings(holding), isTrue);
      expect(await repo.getAccountIdsWithHoldings(), {holding});
    });

    test('删除账户级联删除该账户持仓，并逐条登记 delete', () async {
      final accountId = await createInvestmentAccount();
      final a = await repo.createHolding(
          accountId: accountId, name: 'A', currency: 'CNY');
      final b = await repo.createHolding(
          accountId: accountId, name: 'B', currency: 'CNY');
      final keepAccount = await createInvestmentAccount();
      final keep = await repo.createHolding(
          accountId: keepAccount, name: 'K', currency: 'CNY');
      final syncA = await syncIdOf(a);
      final syncB = await syncIdOf(b);
      await clearChanges();

      await repo.deleteAccount(accountId);

      expect(await repo.getHolding(a), isNull, reason: '不得留下悬空 accountId 的孤儿');
      expect(await repo.getHolding(b), isNull);
      expect(await repo.getHolding(keep), isNotNull, reason: '其它账户持仓不受影响');
      await expectHoldingChange(syncA, 'delete');
      await expectHoldingChange(syncB, 'delete');
    });
  });

  group('无 tracker（快照链路装配）', () {
    test('增删改与行情缓存写入都优雅跳过变更登记、不抛', () async {
      final noTrackerRepo = LocalRepository(db);
      final accountId = await createInvestmentAccount();

      final id = await noTrackerRepo.createHolding(
          accountId: accountId, name: '基金', currency: 'CNY');
      await noTrackerRepo.updateHolding(id, quantity: 5);
      await noTrackerRepo.writeQuoteCache(id, price: 1.5);
      await noTrackerRepo.updateHoldingSortOrders([(id: id, sortOrder: 0)]);
      await noTrackerRepo.deleteHolding(id);

      final holdingChanges = (await tracker.getUnpushedChanges())
          .where((c) => c.entityType == 'holding');
      expect(holdingChanges, isEmpty,
          reason: '无 tracker 时不得登记任何持仓变更，也不得抛');
    });
  });
}
