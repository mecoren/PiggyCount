// 批次 A 同步修复回归测试：
//   #5 账户扩展字段（creditLimit/billingDay/paymentDueDay/bankName/
//      cardLastFour/note/hidden/syncId）在 importAccounts create + update
//      已存在两条路径下都不丢失。
//   #6 标签 syncId：importTags 返回 bySyncId 映射；importTransactions 按
//      tagSyncIds 解析（跨设备 rename 后不错挂）。
//   全链路：exportTransactionsJson → parseJsonToImportData 往返，version 8
//      带所有新字段。
import 'dart:convert';

import 'package:drift/drift.dart' show OrderingTerm;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/transactions_json.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late DataImportService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
    service = DataImportService();
  });

  tearDown(() async => db.close());

  Future<List<Account>> allAccounts() =>
      (db.select(db.accounts)..orderBy([(a) => OrderingTerm.asc(a.id)]))
          .get();

  Future<List<Tag>> allTags() =>
      (db.select(db.tags)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  Future<List<Transaction>> allTx() =>
      (db.select(db.transactions)..orderBy([(t) => OrderingTerm.asc(t.id)]))
          .get();

  group('#5 账户扩展字段', () {
    setUp(() async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    });

    test('create: 所有扩展字段必须写入 DB', () async {
      await service.importAccounts(repo, [
        ImportAccount(
          name: '招行信用卡',
          type: 'credit',
          currency: 'CNY',
          initialBalance: -5000.0,
          creditLimit: 30000.0,
          billingDay: 5,
          paymentDueDay: 25,
          bankName: '招商银行',
          cardLastFour: '1234',
          note: '主用卡',
          hidden: true,
          syncId: 'acc-sync-001',
        ),
      ]);

      final accounts = await allAccounts();
      expect(accounts.length, 1);
      final a = accounts.first;
      expect(a.name, '招行信用卡');
      expect(a.type, 'credit');
      expect(a.creditLimit, 30000.0);
      expect(a.billingDay, 5);
      expect(a.paymentDueDay, 25);
      expect(a.bankName, '招商银行');
      expect(a.cardLastFour, '1234');
      expect(a.note, '主用卡');
      expect(a.hidden, isTrue);
      expect(a.syncId, 'acc-sync-001');
    });

    test('update 已存在账户: 非 null 扩展字段必须更新到 DB', () async {
      // 先创建一个本地账户（无扩展字段）
      final localId = await repo.createAccount(
        ledgerId: 0,
        name: '招行信用卡',
        type: 'credit',
        currency: 'CNY',
      );
      // 确认初始无扩展字段
      final before = (await allAccounts()).first;
      expect(before.creditLimit, isNull);
      expect(before.billingDay, isNull);
      expect(before.hidden, isFalse);

      // 导入同账户，带扩展字段
      await service.importAccounts(repo, [
        ImportAccount(
          name: '招行信用卡',
          type: 'credit',
          currency: 'CNY',
          initialBalance: -5000.0,
          creditLimit: 30000.0,
          billingDay: 5,
          paymentDueDay: 25,
          bankName: '招商银行',
          cardLastFour: '1234',
          note: '主用卡',
          hidden: true,
        ),
      ]);

      final accounts = await allAccounts();
      expect(accounts.length, 1, reason: '不应重复创建');
      final a = accounts.first;
      expect(a.id, localId);
      expect(a.creditLimit, 30000.0);
      expect(a.billingDay, 5);
      expect(a.paymentDueDay, 25);
      expect(a.bankName, '招商银行');
      expect(a.cardLastFour, '1234');
      expect(a.note, '主用卡');
      expect(a.hidden, isTrue);
    });

    test('create + update: sortOrder 必须写入 DB', () async {
      // create 带 sortOrder
      await service.importAccounts(repo, [
        ImportAccount(name: '现金', sortOrder: 1),
        ImportAccount(name: '信用卡', sortOrder: 2),
      ]);
      final created = await allAccounts();
      final cash = created.firstWhere((a) => a.name == '现金');
      final credit = created.firstWhere((a) => a.name == '信用卡');
      expect(cash.sortOrder, 1);
      expect(credit.sortOrder, 2);

      // update 已存在账户：换 sortOrder
      await service.importAccounts(repo, [
        ImportAccount(name: '现金', sortOrder: 5),
      ]);
      final updated = await allAccounts();
      expect(updated.firstWhere((a) => a.name == '现金').sortOrder, 5,
          reason: 'update 已存在账户必须同步 sortOrder');
    });

    test('update 已存在账户: null 扩展字段保持本地原值（不清空）', () async {
      // 本地已有完整字段
      await repo.createAccount(
        ledgerId: 0,
        name: '招行信用卡',
        type: 'credit',
        currency: 'CNY',
        creditLimit: 30000.0,
        billingDay: 5,
        bankName: '招商银行',
        note: '本地备注',
      );

      // 导入同账户，扩展字段全 null（模拟老 JSON 无这些字段）
      await service.importAccounts(repo, [
        ImportAccount(
          name: '招行信用卡',
          type: 'credit',
          currency: 'CNY',
        ),
      ]);

      final a = (await allAccounts()).first;
      expect(a.creditLimit, 30000.0, reason: 'null 不应清空本地值');
      expect(a.billingDay, 5);
      expect(a.bankName, '招商银行');
      expect(a.note, '本地备注');
    });
  });

  group('#6 标签 syncId', () {
    setUp(() async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    });

    test('importTags 返回 byName + bySyncId 两个映射', () async {
      final result = await service.importTags(repo, [
        ImportTag(name: '购物', color: '#FF0000', syncId: 'tag-sync-001'),
        ImportTag(name: '餐饮', color: '#00FF00', syncId: 'tag-sync-002'),
      ]);

      expect(result.byName['购物'], isNotNull);
      expect(result.byName['餐饮'], isNotNull);
      expect(result.bySyncId['tag-sync-001'], result.byName['购物']);
      expect(result.bySyncId['tag-sync-002'], result.byName['餐饮']);
    });

    test('create 时 syncId 必须写入 DB', () async {
      await service.importTags(repo, [
        ImportTag(name: '购物', syncId: 'tag-sync-001', sortOrder: 3),
      ]);

      final tags = await allTags();
      expect(tags.length, 1);
      expect(tags.first.syncId, 'tag-sync-001');
      expect(tags.first.sortOrder, 3);
    });

    test('本地 tag 无 syncId 时:导入必须回填 DB syncId（#6 闭环）', () async {
      // 本地已有无 syncId 的标签（老数据/seed 场景）。
      // 注意:createTag 现在总是自动生成 syncId,无法构造该场景,
      // 必须用裸 SQL 插 NULL 行模拟 v7 之前创建的存量标签。
      await db.customStatement(
          "INSERT INTO tags (name, sync_id) VALUES ('购物', NULL)");

      // 导入 JSON 带 syncId 的同名标签 → 应回填本地 DB
      final result = await service.importTags(repo, [
        ImportTag(name: '购物', syncId: 'tag-sync-001'),
      ]);

      expect(result.bySyncId['tag-sync-001'], isNotNull);
      final tags = await allTags();
      expect(tags.length, 1, reason: '不应新建');
      expect(tags.first.syncId, 'tag-sync-001',
          reason: '本地 syncId 必须回填，否则下次导出 tagSyncIds 无法锚定');
    });

    test('本地 tag 已有 syncId 时:导入不覆盖已有 syncId', () async {
      await repo.createTag(name: '购物', syncId: 'existing-sync');

      await service.importTags(repo, [
        ImportTag(name: '购物', syncId: 'json-sync'),
      ]);

      final tags = await allTags();
      expect(tags.length, 1);
      expect(tags.first.syncId, 'existing-sync',
          reason: '已有 syncId 不应被 JSON 的 syncId 覆盖');
    });

    test('importTransactions 按 tagSyncIds 解析（跨设备 rename 不错挂）',
        () async {
      // 本地已有标签 "购物" syncId=tag-001
      await repo.createTag(name: '购物', syncId: 'tag-001');

      // 远端 JSON 里标签被 rename 成 "日用品"，但 syncId 仍是 tag-001
      final tagMaps = await service.importTags(repo, [
        ImportTag(name: '日用品', syncId: 'tag-001'),
      ]);
      // syncId 命中已存在标签，应更新 name 而非新建
      expect(tagMaps.bySyncId['tag-001'], isNotNull);
      expect((await allTags()).length, 1, reason: 'syncId 匹配不应新建标签');

      // 交易带 tagSyncIds=['tag-001']，应正确关联到本地标签
      await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 100,
            happenedAt: DateTime(2026, 8, 1),
            tagSyncIds: ['tag-001'],
            // tagNames 故意不匹配（模拟远端 rename 后 name 已变）
            tagNames: ['日用品'],
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: tagMaps.byName,
        tagSyncIdToId: tagMaps.bySyncId,
      );

      final txs = await allTx();
      expect(txs.length, 1);
      final txTags = await (db.select(db.transactionTags)
            ..where((t) => t.transactionId.equals(txs.first.id)))
          .get();
      expect(txTags.length, 1, reason: 'tagSyncIds 必须正确解析为关联');
    });

    test('tagSyncIds 解析必须互斥于 tagNames（不叠加误加标签）', () async {
      // 本地有两个独立标签：syncId=tag-a 的叫 "A"，另有一个同名 "B" 的
      // 独立标签 syncId=tag-b。JSON 交易 tagSyncIds=['tag-a']，tagNames 里
      // 故意放一个 syncId 解析不到的 name，验证不叠加。
      final tagA = await repo.createTag(name: 'A', syncId: 'tag-a');
      final tagB = await repo.createTag(name: 'B', syncId: 'tag-b');
      final tagMaps = await service.importTags(repo, [
        ImportTag(name: 'A', syncId: 'tag-a'),
        ImportTag(name: 'B', syncId: 'tag-b'),
      ]);

      await service.importTransactions(
        repo,
        1,
        [
          ImportTransaction(
            type: 'expense',
            amount: 100,
            happenedAt: DateTime(2026, 8, 1),
            tagSyncIds: ['tag-a'],
            tagNames: ['A', 'B'], // name 里多了 B，但 syncId 权威应只挂 A
          ),
        ],
        accountNameToId: {},
        categoryCache: {},
        tagNameToId: tagMaps.byName,
        tagSyncIdToId: tagMaps.bySyncId,
      );

      final txs = await allTx();
      expect(txs.length, 1);
      final txTags = await (db.select(db.transactionTags)
            ..where((t) => t.transactionId.equals(txs.first.id)))
          .get();
      expect(txTags.length, 1, reason: 'syncId 权威，不能因 name 叠加多加 B');
      expect(txTags.first.tagId, tagA,
          reason: '应挂 syncId 命中的 tag A，而非 name 里的 B');
      expect(txTags.first.tagId, isNot(tagB));
    });
  });

  group('JSON 导出→解析往返（version 8）', () {
    setUp(() async {
      await db.customStatement(
          "INSERT INTO ledgers (id, name, currency, month_start_day) "
          "VALUES (1, 'L', 'CNY', 1)");
      // 带扩展字段的账户
      await db.customStatement(
          "INSERT INTO accounts (id, ledger_id, name, type, currency, "
          "initial_balance, sort_order, credit_limit, billing_day, "
          "payment_due_day, bank_name, card_last_four, note, hidden, sync_id) "
          "VALUES (1, 0, '招行信用卡', 'credit', 'CNY', -5000.0, 2, 30000.0, "
          "5, 25, '招商银行', '1234', '主用卡', 1, 'acc-sync-001')");
      // 带 syncId 的标签
      await db.customStatement(
          "INSERT INTO tags (id, name, color, sync_id, sort_order) "
          "VALUES (1, '购物', '#FF0000', 'tag-sync-001', 3)");
      // 带账单标记的交易（happened_at 用 unix 秒,drift int 模式）
      await db.customStatement(
          "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, "
          "note, sync_id, exclude_from_stats, exclude_from_budget) "
          "VALUES (1, 1, 'expense', 100.0, "
          "CAST(strftime('%s','2026-08-01') AS INTEGER), '备注', "
          "'tx-sync-001', 1, 0)");
      // 交易-标签关联
      await db.customStatement(
          "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (1, 1)");
    });

    test('导出 JSON version 必须为当前格式版本', () async {
      final json = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
      final data = jsonDecode(json) as Map<String, dynamic>;
      expect(data['version'], kSnapshotFormatVersion,
          reason: 'v12：新增 savingsGoals 段后指纹口径再次变更'
              '（v11 holdings 段；v10 共享账本残留移除；v9 ledgerSyncId 身份锚点；'
              'v8 budgets/recurring/汇率覆盖 + 全量分类/标签）');
      expect(data['version'], 12,
          reason: '格式版本常量变更必须同步消费端的升级重传门控'
              '（shouldRepublishSnapshotForFormatUpgrade 已按 v12 语义复核：'
              '两端都无目标时一次性收敛，有差异时交回 diff / 合并）');
    });

    test('账户扩展字段在导出→解析后完整保留', () async {
      final json = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
      final importData = parseJsonToImportData(json);

      expect(importData.accounts.length, 1);
      final a = importData.accounts.first;
      expect(a.name, '招行信用卡');
      expect(a.type, 'credit');
      expect(a.sortOrder, 2);
      expect(a.creditLimit, 30000.0);
      expect(a.billingDay, 5);
      expect(a.paymentDueDay, 25);
      expect(a.bankName, '招商银行');
      expect(a.cardLastFour, '1234');
      expect(a.note, '主用卡');
      expect(a.hidden, isTrue);
      expect(a.syncId, 'acc-sync-001');
    });

    test('标签 syncId + sortOrder 在导出→解析后完整保留', () async {
      final json = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
      final importData = parseJsonToImportData(json);

      expect(importData.tags.length, 1);
      final t = importData.tags.first;
      expect(t.name, '购物');
      expect(t.color, '#FF0000');
      expect(t.syncId, 'tag-sync-001');
      expect(t.sortOrder, 3);
    });

    test('交易 tagSyncIds + 账单标记在导出→解析后完整保留', () async {
      final json = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
      final importData = parseJsonToImportData(json);

      expect(importData.transactions.length, 1);
      final tx = importData.transactions.first;
      expect(tx.syncId, 'tx-sync-001');
      expect(tx.excludeFromStats, isTrue);
      expect(tx.excludeFromBudget, isFalse);
      expect(tx.tagSyncIds, ['tag-sync-001'],
          reason: 'tagSyncIds 必须随 JSON 传输');
    });

    test('导入→导出闭环: 本地无 syncId 的 tag 经导入回填后再导出带 tagSyncIds',
        () async {
      // 本地已有无 syncId 的标签 + 关联交易的标签（老数据）。
      // createTag 总是生成 syncId,用裸 SQL 插 NULL 行模拟存量标签;
      // 名字避开 setUp 的 '购物',否则导入按 syncId 命中 setUp 那条,
      // 永远走不到 NULL 回填分支。
      await db.customStatement(
          "INSERT INTO tags (id, name, sync_id) VALUES (9, '餐饮', NULL)");
      await db.customStatement(
          "INSERT INTO transactions (id, ledger_id, type, amount, happened_at, sync_id) "
          "VALUES (2, 1, 'expense', 50.0, "
          "CAST(strftime('%s','2026-08-02') AS INTEGER), 'tx-sync-002')");
      await db.customStatement(
          "INSERT INTO transaction_tags (transaction_id, tag_id) VALUES (2, 9)");

      // 导入 JSON（带 syncId 的标签 + 交易带 tagSyncIds）
      await service.importTags(repo, [
        ImportTag(name: '餐饮', syncId: 'tag-sync-009'),
      ]);

      // 再次导出 → 交易 items 必须带 tagSyncIds
      final json = await exportTransactionsJson(db, 1).then((e) => e.jsonStr);
      final importData = parseJsonToImportData(json);
      final tx2 = importData.transactions.firstWhere((t) => t.syncId == 'tx-sync-002');
      expect(tx2.tagSyncIds, ['tag-sync-009'],
          reason: 'syncId 回填后导出必须带 tagSyncIds（闭环）');
    });
  });
}
