/// Task 1（/prd/cloud_backup/execution_plan.md）：
/// 公共账本整体恢复函数 restoreLedgerFromJson 的行为契约。
///
/// 抽取自 TransactionsSyncManager.downloadAndRestoreToCurrentLedger，
/// 供云同步恢复与云端备份恢复共用同一语义：
/// 1. 快照整体覆盖（清空后导入，事务原子）
/// 2. P1-1 守卫：空快照拒绝覆盖非空本地账本
library;

import 'dart:convert';

import 'package:drift/drift.dart' as drift;
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

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  Future<int> addLedger(String name) =>
      db.into(db.ledgers).insert(LedgersCompanion.insert(name: name));

  Future<void> addTx(int ledgerId, {double amount = 10}) =>
      db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: ledgerId, type: 'expense', amount: amount));

  test('快照整体覆盖：清空本地后导入快照内容', () async {
    final id = await addLedger('Main');
    await addTx(id, amount: 10);
    final snapshot = await exportTransactionsJson(db, id);

    // 快照后再新增一笔，恢复应回到快照时点
    await addTx(id, amount: 99);
    var rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 2);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);
    rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1);
    expect(rows.first.amount, 10);
  });

  test('P1-1 守卫：空快照拒绝覆盖非空本地账本，返回 null', () async {
    final id = await addLedger('Main');
    await addTx(id);
    // 手工构造空交易快照（复用 export 再清空 items）
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    (map['items'] as List).clear();
    final emptySnapshot = jsonEncode(map);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: emptySnapshot);
    expect(result, isNull);
    final rows = await (db.select(db.transactions)
          ..where((t) => t.ledgerId.equals(id)))
        .get();
    expect(rows.length, 1); // 本地数据未被清空
  });

  test('H3 镜像删除：v8 快照中已删除的预算/周期规则本地同步消失', () async {
    final id = await addLedger('Main');
    // 本地造一条预算 + 一条周期规则（带 syncId，模拟曾同步过的实体）
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
        ledgerId: id, amount: 100,
        syncId: const drift.Value('bud-removed')));
    await db.into(db.recurringTransactions).insert(
        RecurringTransactionsCompanion.insert(
            ledgerId: id, type: 'expense', amount: 10,
            frequency: 'monthly', startDate: DateTime(2026, 1, 1),
            syncId: const drift.Value('rec-removed')));

    // 云端快照：预算只剩 bud-kept，周期为空（rec-removed 已在云端删除）
    final snapshot = jsonEncode({
      'version': 8,
      'ledgerName': 'Main',
      'currency': 'CNY',
      'accounts': [],
      'categories': [],
      'tags': [],
      'budgets': [
        {'syncId': 'bud-kept', 'type': 'total', 'amount': 50,
         'period': 'monthly', 'startDay': 1, 'enabled': true},
      ],
      'recurring': [],
      'items': [],
    });

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);

    final budgets = await (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(id)))
        .get();
    expect(budgets.map((b) => b.syncId), ['bud-kept'],
        reason: 'bud-removed 应被镜像删除');

    final recs = await (db.select(db.recurringTransactions)
          ..where((r) => r.ledgerId.equals(id)))
        .get();
    expect(recs, isEmpty, reason: 'rec-removed 应被镜像删除');
  });

  test('H3 版本守卫：v7 快照不触发镜像删除（防旧快照误删）', () async {
    final id = await addLedger('Main');
    await db.into(db.budgets).insert(BudgetsCompanion.insert(
        ledgerId: id, amount: 100,
        syncId: const drift.Value('bud-legacy')));
    final snapshot = jsonEncode({
      'version': 7, 'ledgerName': 'Main', 'currency': 'CNY', 'items': [],
    });
    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    final budgets = await (db.select(db.budgets)
          ..where((b) => b.ledgerId.equals(id)))
        .get();
    expect(budgets, isNotEmpty, reason: 'v7 旧快照不含 budgets 数组，不得误删本地预算');
  });

  test('H3 分类镜像：无引用且不在云端的分类被删，被引用的保留', () async {
    final id = await addLedger('Main');
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: '餐饮', kind: 'expense', syncId: const drift.Value('cat-kept')));
    await db.into(db.categories).insert(CategoriesCompanion.insert(
        name: '孤儿', kind: 'expense', syncId: const drift.Value('cat-orphan')));
    // 快照携带 cat-kept + 一笔引用餐饮的交易；cat-orphan 不在云端
    final snapshot = jsonEncode({
      'version': 8, 'ledgerName': 'Main', 'currency': 'CNY',
      'categories': [
        {'name': '餐饮', 'kind': 'expense', 'syncId': 'cat-kept'},
      ],
      'items': [
        {'type': 'expense', 'amount': 1, 'categoryName': '餐饮',
         'happenedAt': '2026-08-01T00:00:00.000Z', 'syncId': 'tx-1'},
      ],
    });
    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    final cats = await db.select(db.categories).get();
    expect(cats.map((c) => c.syncId), contains('cat-kept'));
    expect(cats.map((c) => c.syncId), isNot(contains('cat-orphan')),
        reason: '不在云端且无引用的孤儿分类应被镜像删除');
  });

  test('H3 标签镜像：不在云端且无交易关联的标签被删', () async {
    final id = await addLedger('Main');
    await db.into(db.tags).insert(TagsCompanion.insert(
        name: '老标签', syncId: const drift.Value('tag-orphan')));
    await db.into(db.tags).insert(TagsCompanion.insert(
        name: '云端标签', syncId: const drift.Value('tag-kept')));
    final snapshot = jsonEncode({
      'version': 8, 'ledgerName': 'Main', 'currency': 'CNY',
      'tags': [
        {'name': '云端标签', 'syncId': 'tag-kept'},
      ],
      'items': [],
    });
    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    final tags = await db.select(db.tags).get();
    expect(tags.map((t) => t.syncId), isNot(contains('tag-orphan')));
    expect(tags.map((t) => t.syncId), contains('tag-kept'));
  });

  test('H3 账户镜像：无引用且不在云端的账户被删（F4 复活循环修复）', () async {
    final id = await addLedger('Main');
    await db.into(db.accounts).insert(AccountsCompanion.insert(
        ledgerId: id, name: '云端账户',
        syncId: const drift.Value('acc-kept')));
    await db.into(db.accounts).insert(AccountsCompanion.insert(
        ledgerId: id, name: '孤儿账户',
        syncId: const drift.Value('acc-orphan')));
    final snapshot = jsonEncode({
      'version': 8,
      'ledgerName': 'Main',
      'currency': 'CNY',
      'accounts': [
        {'name': '云端账户', 'syncId': 'acc-kept'},
      ],
      'categories': [],
      'tags': [],
      'items': [],
    });

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);

    final accs = await db.select(db.accounts).get();
    expect(accs.map((a) => a.syncId), contains('acc-kept'));
    expect(accs.map((a) => a.syncId), isNot(contains('acc-orphan')),
        reason: '云端已删且本地无引用的账户必须镜像删除，'
            '否则指纹 G4 使两端永久 outOfSync 并在回传时复活该账户');
  });

  test('H3 账户镜像：被交易引用的账户即使不在云端也保留（引用守卫）', () async {
    final main = await addLedger('Main');
    final other = await addLedger('Other');
    final accId = await db.into(db.accounts).insert(AccountsCompanion.insert(
        ledgerId: main, name: '被引用账户',
        syncId: const drift.Value('acc-used')));
    // 另一账本的交易仍引用该账户 —— 全局引用守卫必须保住它
    await db.into(db.transactions).insert(TransactionsCompanion.insert(
        ledgerId: other, type: 'expense', amount: 5,
        accountId: drift.Value(accId)));

    final snapshot = jsonEncode({
      'version': 8, 'ledgerName': 'Main', 'currency': 'CNY',
      'accounts': [], 'categories': [], 'tags': [], 'items': [],
    });
    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: main, jsonStr: snapshot);

    final accs = await db.select(db.accounts).get();
    expect(accs.map((a) => a.syncId), contains('acc-used'),
        reason: '引用守卫：仍有交易引用的账户不得被镜像删除');
  });

  test('v9 回填：快照带 ledgerSyncId 且本地行缺失时补写 sync_id', () async {
    final id = await addLedger('Main'); // 无 syncId（legacy 行）
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    // 模拟 v9 快照：源端账本身份
    map['version'] = 9;
    map['ledgerSyncId'] = '0f1e2d3c-4b5a-6789-abcd-ef0123456789';
    final snapshot = jsonEncode(map);

    final result = await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    expect(result, isNotNull);

    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(id)))
        .getSingle();
    expect(row.syncId, '0f1e2d3c-4b5a-6789-abcd-ef0123456789',
        reason: 'v9：恢复端必须回填账本行的 sync_id，'
            '否则纯快照用户的账本永远没有跨设备身份');
  });

  test('v9 身份冲突：本地已有不同 syncId 时保留本地不覆盖', () async {
    final id = await db.into(db.ledgers).insert(LedgersCompanion.insert(
        name: 'Main', syncId: const drift.Value('local-identity')));
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    map['version'] = 9;
    map['ledgerSyncId'] = 'cloud-other-identity';
    final snapshot = jsonEncode(map);

    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: snapshot);
    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(id)))
        .getSingle();
    expect(row.syncId, 'local-identity',
        reason: '本地 syncId 可能已被 Cloud 引擎锚定 server external_id，'
            '恢复不得静默改写身份（撕裂 push/pull 映射）');
  });

  test('v8- 旧快照无 ledgerSyncId 时保持现状不回填', () async {
    final id = await addLedger('Main');
    final map = jsonDecodeMap(await exportTransactionsJson(db, id));
    map['version'] = 8;
    map.remove('ledgerSyncId');

    await restoreLedgerFromJson(
        db: db, repo: repo, ledgerId: id, jsonStr: jsonEncode(map));
    final row = await (db.select(db.ledgers)
          ..where((l) => l.id.equals(id)))
        .getSingle();
    expect(row.syncId, isNull);
  });
}

/// 测试辅助：解码 JSON 为 Map（避免每个测试文件重复写）
Map<String, dynamic> jsonDecodeMap(String s) =>
    (jsonDecode(s) as Map).cast<String, dynamic>();
