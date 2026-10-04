/// 合并路径的**实体删除语义**回归测试。
///
/// 缺陷形状：合并路径（`applySyncChanges`）对账户 / 分类 / 标签 / 预算 /
/// 周期规则 / 手动汇率一律 **upsert-only** —— 对端删掉的实体在本地永不消失，
/// merge-then-publish 又把它们写回云端（用户视角「删掉的又出现了」），
/// 两端指纹永久不一致 → 每次启动都判 cloudNewer 反复弹「云端有更新」，
/// 而用户点「下载同步」却一条变更都点不出来。
/// 这与 D-1（分类）、S11（附件）完全同构，形状一样：**指纹说不同、diff 说无变化**。
/// 全量下载路径早有镜像删除（`_mirrorDeleteAbsentEntities`），只有合并路径漏了。
///
/// 本文件锁定的四道安全闸门 + 落地语义：
///   闸门① version < 8（��快照不带这些段，"云端缺席"没有删除语义）；
///   闸门② 该段解析损坏（`skippedItems`）→ 缺席只是解析失败，不是删除；
///   闸门③ 本地无 syncId → 本机新建，云端缺席不可信；
///   闸门④ 本地有**未推送**变更 → 用户刚动过、还没上云，缺席是信息滞后。
///         （`createAccount` / `createCategory` / `setOverride` 建行即自动生成
///          UUID syncId，所以闸门③ 挡不住"本机刚建未上传"，④ 才是真闸门。）
///   引用守卫：被交易/预算/周期/子分类/交易-标签关联引用的实体一律保留 ——
///         合并路径的交易行是**保留**的，删掉被引用实体会留悬空外键。
///   落地：默认**不勾选**（SYNC-05 删除口径），勾选后才真正删，且再算 diff 收敛。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/cloud/sync_diff_service.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late SyncDiffService service;

  final baseTime = DateTime.utc(2026, 7, 1, 10, 0, 0);

  /// 云端交易夹具。
  ///
  /// 金额/日期**刻意**与默认本地交易不同：业务键兜底配对（H1）会把内容一致
  /// 的云端行认领成本地行，随后按云端值改写本地外键 —— 本地交易的
  /// account/category/recurring 会被清空、引用自行解除，夹具就变成在测
  /// "引用被 merge 顺手修好"，而不是"引用仍在 → 拦下删除"。
  ImportTransaction cloudTx({double amount = 777}) => ImportTransaction(
        type: 'expense',
        amount: amount,
        happenedAt: baseTime.add(const Duration(days: 30)),
        syncId: 'tx-cloud',
        note: 'remote-only',
      );

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = SyncDiffService();
  });

  tearDown(() async => db.close());

  Future<void> seedLedger() => db.customStatement(
      "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");

  Future<int> seedAccount(String name, {String? syncId}) =>
      db.into(db.accounts).insert(AccountsCompanion.insert(
            ledgerId: 1,
            name: name,
            currency: const d.Value('CNY'),
            syncId: d.Value(syncId),
          ));

  Future<int> seedCategory(String name, {String? syncId, int? parentId}) =>
      db.into(db.categories).insert(CategoriesCompanion.insert(
            name: name,
            kind: 'expense',
            parentId: d.Value(parentId),
            syncId: d.Value(syncId),
          ));

  Future<int> seedTag(String name, {String? syncId}) =>
      db.into(db.tags).insert(TagsCompanion.insert(
            name: name,
            color: const d.Value('#ff0000'),
            sortOrder: const d.Value(0),
            syncId: d.Value(syncId),
          ));

  Future<int> seedBudget({String? syncId}) => db.into(db.budgets).insert(
        BudgetsCompanion.insert(
          ledgerId: 1,
          type: const d.Value('total'),
          amount: 1000,
          period: const d.Value('monthly'),
          startDay: const d.Value(1),
          syncId: d.Value(syncId),
        ),
      );

  Future<int> seedRecurring({String? syncId, int? accountId}) =>
      db.into(db.recurringTransactions).insert(
            RecurringTransactionsCompanion.insert(
              ledgerId: 1,
              type: 'expense',
              amount: 10,
              frequency: 'monthly',
              startDate: DateTime.utc(2026, 1, 1),
              accountId: d.Value(accountId),
              syncId: d.Value(syncId),
            ),
          );

  Future<int> seedOverride(String base, String quote, {String? syncId}) =>
      db.into(db.exchangeRateOverrides).insert(
            ExchangeRateOverridesCompanion.insert(
              baseCurrency: base,
              quoteCurrency: quote,
              rate: '7.1',
              syncId: d.Value(syncId),
            ),
          );

  Future<int> seedTx({
    int? categoryId,
    int? accountId,
    int? toAccountId,
    int? recurringId,
    String? syncId = 'tx-1',
  }) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
            ledgerId: 1,
            type: 'expense',
            amount: 100,
            categoryId: d.Value(categoryId),
            accountId: d.Value(accountId),
            toAccountId: d.Value(toAccountId),
            recurringId: d.Value(recurringId),
            happenedAt: d.Value(baseTime),
            syncId: d.Value(syncId),
          ));

  Future<void> linkTag(int txId, int tagId) =>
      db.into(db.transactionTags).insert(
          TransactionTagsCompanion.insert(transactionId: txId, tagId: tagId));

  /// 云端已把这些实体全删光（各段留空）的 v8 快照。
  ImportData cloudWithout({
    List<ImportAccount> accounts = const [],
    List<ImportCategory> categories = const [],
    List<ImportTag> tags = const [],
    List<ImportBudget> budgets = const [],
    List<ImportRecurring> recurrings = const [],
    List<ImportRateOverride> rateOverrides = const [],
    int? version = 8,
    Map<String, int> skippedItems = const {},
    List<ImportTransaction> transactions = const [],
  }) =>
      ImportData(
        version: version,
        accounts: accounts,
        categories: categories,
        tags: tags,
        budgets: budgets,
        recurrings: recurrings,
        rateOverrides: rateOverrides,
        transactions: transactions,
        skippedItems: skippedItems,
      );

  Future<List<SyncEntityDelete>> candidates(ImportData cloud,
      {LocalRepository? use}) async {
    final preview = await service.computeDiff(
      repo: use ?? repo,
      ledgerId: 1,
      cloudTransactions: cloud.transactions,
      cloudMeta: cloud,
    );
    expect(preview, isNotNull);
    return preview!.changes
        .where((c) => c.isEntityDelete)
        .map((c) => c.entityDelete!)
        .toList();
  }

  group('实体删除候选：四道闸门', () {
    test('闸门① 旧快照（version 缺省 / < 8）→ 一条候选都不出', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await seedCategory('餐饮', syncId: 'cat-1');
      await seedTag('报销', syncId: 'tag-1');
      await seedBudget(syncId: 'bud-1');
      await seedRecurring(syncId: 'rec-1');
      await seedOverride('CNY', 'USD', syncId: 'ro-1');

      expect(await candidates(cloudWithout(version: null)), isEmpty,
          reason: '旧快照可能根本不携带这些段，"云端缺席"没有删除语义');
      expect(await candidates(cloudWithout(version: 7)), isEmpty);
    });

    test('闸门② 该段解析损坏（skippedItems）→ 该段不出候选', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await seedTag('报销', syncId: 'tag-1');

      // tags 段有 3 条被解析跳过 → "云端没有报销标签"只是解析失败，不是删除
      final c = await candidates(cloudWithout(skippedItems: const {'tags': 3}));
      expect(c.where((e) => e.kind == SyncEntityKind.tag), isEmpty);
      expect(c.where((e) => e.kind == SyncEntityKind.account), hasLength(1),
          reason: '只跳过有损坏的那一段，其余段照常判定');
    });

    test('闸门③ 本地无 syncId → 不删（本机新建、尚未上传过）', () async {
      await seedLedger();
      await seedAccount('现金'); // syncId = null
      await seedCategory('餐饮');
      await seedTag('报销');
      await seedBudget();
      await seedRecurring();
      await seedOverride('CNY', 'USD');

      expect(await candidates(cloudWithout()), isEmpty);
    });

    test('闸门④ 本地有未推送变更 → 不删（本机刚建未上云，缺席是信息滞后）', () async {
      // 用带 ChangeTracker 的仓储，模拟真实同步环境
      final tracked = LocalRepository(db, changeTracker: ChangeTracker(db));
      // 通过仓储接口建行 → 与真实路径一致：建行即自动生成 UUID syncId
      // 并登记一条未推送 change
      await seedLedger();
      final accId = await tracked.createAccount(ledgerId: 1, name: '现金');
      final catId = await tracked.createCategory(name: '餐饮', kind: 'expense');
      await tracked.createTag(name: '报销');
      await tracked.createBudget(ledgerId: 1, type: 'total', amount: 1000);
      await tracked.setOverride(base: 'CNY', quote: 'USD', rate: '7.1');

      final rows = await db.select(db.accounts).get();
      expect(rows.single.syncId, isNotNull,
          reason: '前提：建行即自动生成 syncId —— 所以闸门③ 挡不住本场景');
      expect(accId, isPositive);
      expect(catId, isPositive);

      final c = await candidates(cloudWithout(), use: tracked);
      expect(c, isEmpty,
          reason: '这些实体都刚在本机建好、还没上云，云端快照缺席它们是'
              '**信息滞后**而不是删除 —— 删掉就是静默丢用户数据');

      // 上传成功后 markSnapshotPushed 会清空未推送队列 → 闸门放行
      await tracked.changeTracker!.markSnapshotPushed(ledgerId: 1);
      expect(await candidates(cloudWithout(), use: tracked), hasLength(5),
          reason: '已推送 = 云端见过这些实体，此时"云端没有"才是删除语义');
    });

    test('引用守卫在 apply 侧：预览照常列出被引用实体，落地时拦下并保留', () async {
      // 为什么守卫不在预览侧：「删账户 + 删它的交易」在预览那一刻交易还在，
      // 账户被引用 → 不进候选 → 用户删完交易后本地已与云端一致 → 没有未勾选
      // 的删除 → S1 守卫放行 → force 回传把账户写回云端 → 删除被复活。
      // 放到 apply 侧按"交易落库后"的引用判定，同一轮即可收敛。
      await seedLedger();
      final accA = await seedAccount('现金', syncId: 'acc-used');
      final parent = await seedCategory('餐饮', syncId: 'cat-parent');
      final child =
          await seedCategory('午餐', syncId: 'cat-child', parentId: parent);
      final usedTag = await seedTag('报销', syncId: 'tag-used');
      final rec = await seedRecurring(syncId: 'rec-used', accountId: accA);
      final tx = await seedTx(
        categoryId: child,
        accountId: accA,
        recurringId: rec,
        syncId: null, // 本地独有 → 不进交易 diff
      );
      await linkTag(tx, usedTag);
      await db.into(db.budgets).insert(BudgetsCompanion.insert(
            ledgerId: 1,
            type: const d.Value('category'),
            categoryId: d.Value(child),
            amount: 100,
            period: const d.Value('monthly'),
            startDay: const d.Value(1),
            syncId: const d.Value('bud-1'),
          ));

      final cloud = cloudWithout(transactions: [cloudTx()]);
      final c = await candidates(cloud);
      final byName = {for (final e in c) '${e.kind.name}:${e.name}': e};
      expect(byName['account:现金']?.syncId, 'acc-used',
          reason: '预览必须列出它 —— 否则这一轮无从勾选，删除无法收敛');
      expect(byName.containsKey('category:餐饮'), isTrue,
          reason: '有子分类的父分类同样列出，落地时由引用守卫处置');
      expect(byName.containsKey('tag:报销'), isTrue);

      // 勾选全部 → 本地交易的引用纹丝不动（它无 syncId，不进任何交易
      // 变更；云端那笔业务键不同，也不会被兜底配对改写）→ 仍被引用 → 拦下
      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: cloud.transactions,
        cloudMeta: cloud,
      );
      final result = await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview!.changes,
        importData: cloud,
      );
      expect(result.entityDeletedCount, 1, reason: '只有预算（无外部引用）能删，其余 5 个仍被引用');
      expect((await db.select(db.accounts).get()), hasLength(1),
          reason: '仍被交易/周期规则引用 → 保留，不留悬空外键');
      expect((await db.select(db.categories).get()), hasLength(2),
          reason: '父分类被子分类引用、子分类被交易+预算引用');
      expect((await db.select(db.tags).get()), hasLength(1));
      expect((await db.select(db.recurringTransactions).get()), hasLength(1),
          reason: '被交易 recurring_id 引用 → 保留');
      expect(await db.select(db.budgets).get(), isEmpty);
    });

    test('单轮收敛：交易删除已应用后，同轮即可删掉被它解绑的实体', () async {
      // 「删账户 + 删它的交易」是删除账户最常见的动机。若引用守卫在预览侧，
      // 这一轮账户删不掉、下一轮才有候选，且中间那轮可能被 force 回传把删除
      // 冲掉 —— 守卫在 apply 侧则一轮收敛。
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      final tx = await seedTx(accountId: 1, syncId: 'tx-1');

      // 云端：账户不在，且只有一笔**业务键不同**的远端交易（否则会被兜底配对
      // 改写本地行、把引用顺手修掉，测的就不是删除语义了）
      final cloud = cloudWithout(transactions: [cloudTx()]);
      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: cloud.transactions,
        cloudMeta: cloud,
      );
      expect(preview!.entityDeletedCount, 1, reason: '账户必须出现在预览里，否则用户无从勾选');
      expect(preview.transactionDeletedCount, 1, reason: '本地独有的交易也要一并被识别为删除候选');

      final result = await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: preview.changes,
        importData: cloud,
      );
      expect(result.deletedCount, 1);
      expect(result.entityDeletedCount, 1, reason: '交易先删 → 引用解除 → 同一轮内账户即可删除');
      expect(await db.select(db.accounts).get(), isEmpty);
      expect(tx, isPositive, reason: '确认交易行确实存在过（避免下面空断言假绿）');

      // 剩下一行必须是**云端那笔 added**，本地独有的 tx-1 已删
      final left = await db.select(db.transactions).get();
      expect(left.map((e) => e.syncId), ['tx-cloud']);

      // 收敛：再算一次没有实体删除候选
      final again = await candidates(cloud);
      expect(again, isEmpty);
    });

    test('云端仍在的实体 → 不产出候选', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await seedCategory('餐饮', syncId: 'cat-1');
      await seedTag('报销', syncId: 'tag-1');
      await seedBudget(syncId: 'bud-1');
      await seedRecurring(syncId: 'rec-1');
      await seedOverride('CNY', 'USD', syncId: 'ro-1');

      expect(
        await candidates(cloudWithout(
          accounts: const [ImportAccount(name: '现金', syncId: 'acc-1')],
          categories: const [
            ImportCategory(name: '餐饮', kind: 'expense', syncId: 'cat-1')
          ],
          tags: const [ImportTag(name: '报销', syncId: 'tag-1')],
          budgets: const [
            ImportBudget(syncId: 'bud-1', type: 'total', amount: 1000)
          ],
          recurrings: [
            ImportRecurring(
              syncId: 'rec-1',
              type: 'expense',
              amount: 10,
              frequency: 'monthly',
              interval: 1,
              startDate: DateTime.utc(2026, 1, 1),
            )
          ],
          rateOverrides: const [
            ImportRateOverride(
              baseCurrency: 'CNY',
              quoteCurrency: 'USD',
              rate: 7.1,
              syncId: 'ro-1',
            )
          ],
        )),
        isEmpty,
      );
    });

    test('不传 cloudMeta → 不产出实体候选（保持既有调用方语义）', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      final preview = await service
          .computeDiff(repo: repo, ledgerId: 1, cloudTransactions: const []);
      expect(preview!.entityDeletedCount, 0);
    });
  });

  group('实体删除的落地：默认不勾选 + 勾选即生效 + 再算收敛', () {
    test('默认不勾选 → 实体原样保留', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await seedTag('报销', syncId: 'tag-1');

      final cloud = cloudWithout();
      final preview = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud,
      );
      expect(preview!.entityDeletedCount, 2);
      for (final c in preview.changes) {
        expect(c.selected, isFalse, reason: '删除是破坏性变更，必须用户显式勾选（SYNC-05 口径）');
      }

      // 一键应用全部 → 实体删除不在 selected 里
      final selected =
          preview.changes.where((c) => c.selected).toList(growable: false);
      await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: selected,
        importData: cloud,
      );
      expect((await db.select(db.accounts).get()), hasLength(1));
      expect((await db.select(db.tags).get()), hasLength(1));
    });

    test('勾选后真正删除，且再算 diff 收敛（不再报同一批）', () async {
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await seedCategory('餐饮', syncId: 'cat-1');
      await seedTag('报销', syncId: 'tag-1');
      await seedBudget(syncId: 'bud-1');
      await seedRecurring(syncId: 'rec-1');
      await seedOverride('CNY', 'USD', syncId: 'ro-1');

      final cloud = cloudWithout();
      final first = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud,
      );
      expect(first!.entityDeletedCount, 6);
      expect(first.deletedCount, 6);
      expect(first.transactionDeletedCount, 0);

      final selected = first.changes.toList();
      final result = await service.applySyncChanges(
        repo: repo,
        ledgerId: 1,
        selectedChanges: selected,
        importData: cloud,
      );
      expect(result.entityDeletedCount, 6);
      expect(result.deletedCount, 0, reason: 'deletedCount 只统计交易行删除');
      expect(result.totalCount, 6);

      expect(await db.select(db.accounts).get(), isEmpty);
      expect(await db.select(db.categories).get(), isEmpty);
      expect(await db.select(db.tags).get(), isEmpty);
      expect(await db.select(db.budgets).get(), isEmpty);
      expect(await db.select(db.recurringTransactions).get(), isEmpty);
      expect(await db.select(db.exchangeRateOverrides).get(), isEmpty);

      // 收敛：再算一次没有实体删除候选（否则每轮都提示、点了也没用）
      final again = await service.computeDiff(
        repo: repo,
        ledgerId: 1,
        cloudTransactions: const [],
        cloudMeta: cloud,
      );
      expect(again!.entityDeletedCount, 0);
      expect(again.isEmpty, isTrue);
    });

    test('合并不写 local_changes（M3：云端权威的删除不是本地编辑）', () async {
      final tracked = LocalRepository(db, changeTracker: ChangeTracker(db));
      await seedLedger();
      await seedAccount('现金', syncId: 'acc-1');
      await db.into(db.budgets).insert(BudgetsCompanion.insert(
            ledgerId: 1,
            type: const d.Value('total'),
            amount: 1,
            period: const d.Value('monthly'),
            startDay: const d.Value(1),
          ));

      final cloud = cloudWithout();
      final result = await service.applySyncChanges(
        repo: tracked,
        ledgerId: 1,
        selectedChanges: const [],
        importData: cloud,
      );
      expect(result.entityDeletedCount, 0);

      final selected = <SyncChange>[
        SyncChange(
          type: SyncChangeType.deleted,
          entityDelete: const SyncEntityDelete(
            kind: SyncEntityKind.account,
            localId: 1,
            syncId: 'acc-1',
            name: '现金',
          ),
          selected: true,
        ),
      ];
      final r2 = await service.applySyncChanges(
        repo: tracked,
        ledgerId: 1,
        selectedChanges: selected,
        importData: cloud,
      );
      expect(r2.entityDeletedCount, 1);

      final changes = await tracked.changeTracker!.getUnpushedChanges();
      expect(changes.where((c) => c.action == 'delete'), isEmpty,
          reason: '删除来自云端权威快照，登记成待推送 change 就是幻影变更');
    });
  });
}
