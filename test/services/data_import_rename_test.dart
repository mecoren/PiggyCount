/// P0 回归：账户 / 分类「改名」必须随云快照落库。
///
/// 背景：`importAccounts` / `importCategories` 命中已存在实体时都只对齐
/// `syncId`、从不回写 `name`，导致 A 端重命名账户或分类后，B 端无论走
/// 「合并应用」还是「全量下载」都拿不到新名（2026-09-26 双端实测：
/// `accounts.name` 恒为 ('现金-W2') vs ('现金')）。
///
/// 同时锁死两个易错点：
/// 1. `ImportAccount.name` / `ImportCategory.name` 是必填字段（恒非 null），
///    改名判定必须比较「云端名 vs 本地名」，不能用非 null 当信号 —— 否则
///    每轮合并都会对全部实体做无意义 UPDATE 并登记假变更。
/// 2. 目标名已被**另一条**实体占用时必须保守跳过 rename（tags 同款策略），
///    否则会产生重名脏数据 / 抢占他人 name 映射导致兜底匹配指错实体。
library;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/cloud/sync/change_tracker.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/services/data_import_service.dart';

T? _first<T>(Iterable<T> it) => it.isEmpty ? null : it.first;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late LocalRepository repo;
  late DataImportService service;

  setUp(() {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db, changeTracker: ChangeTracker(db));
    service = DataImportService();
  });

  tearDown(() async => db.close());

  Future<void> clearChanges() => db.delete(db.localChanges).go();

  Future<int> changeCount() async =>
      (await db.select(db.localChanges).get()).length;

  Future<Account?> accountBySyncId(String sid) async =>
      _first((await repo.getAllAccounts()).where((a) => a.syncId == sid));

  Future<Category?> categoryBySyncId(String sid) async =>
      _first((await repo.getAllCategories()).where((c) => c.syncId == sid));

  group('importAccounts 改名', () {
    test('syncId 命中且云端名不同 → 本地 name 落库更新', () async {
      await service.importAccounts(
          repo, [const ImportAccount(name: '现金', syncId: 'acc-cash')]);
      await clearChanges();

      await service.importAccounts(repo, [
        const ImportAccount(name: '现金-新', type: 'cash', syncId: 'acc-cash'),
      ]);

      final acc = await accountBySyncId('acc-cash');
      expect(acc!.name, '现金-新',
          reason: 'syncId 命中的账户必须接受云端改名（此前只对齐 syncId 不回写 name）');
      expect(await changeCount(), greaterThan(0),
          reason: '改名必须登记变更，否则永远推不回云端');
    });

    test('目标名已被别的账户占用 → 保守跳过，且不抢占对方 name 映射', () async {
      await service.importAccounts(repo, [
        const ImportAccount(name: '现金', syncId: 'acc-a'),
        const ImportAccount(name: '支付宝', syncId: 'acc-b'),
      ]);
      await clearChanges();

      // acc-a 想改名成「支付宝」，但该名已被 acc-b 占用
      final map = await service.importAccounts(repo, [
        const ImportAccount(name: '支付宝', type: 'cash', syncId: 'acc-a'),
      ]);

      final a = await accountBySyncId('acc-a');
      final b = await accountBySyncId('acc-b');
      expect(a!.name, '现金',
          reason: 'accounts 无 name 唯一约束，强改会破坏按 name 兜底匹配 → 必须保守跳过');
      expect(map['支付宝'], b!.id,
          reason: 'rename 被跳过时不得把目标名映射抢到自身，否则后续 name 兜底匹配指错账户');
    });

    test('云端名与本地名相同 → 不产生无意义写入', () async {
      await service.importAccounts(
          repo, [const ImportAccount(name: '现金', syncId: 'acc-a')]);
      await clearChanges();

      await service.importAccounts(
          repo, [const ImportAccount(name: '现金', syncId: 'acc-a')]);

      expect(await changeCount(), 0,
          reason: 'name 必填恒非 null，必须比出「无差异」才能避免每轮合并白写一次');
    });
  });

  group('importCategories 改名', () {
    test('syncId 命中且云端名不同 → 本地 name 落库更新', () async {
      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮', kind: 'expense', level: 1, syncId: 'cat-food'),
      ]);
      await clearChanges();

      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮-新', kind: 'expense', level: 1, syncId: 'cat-food'),
      ]);

      final cat = await categoryBySyncId('cat-food');
      expect(cat!.name, '餐饮-新', reason: 'syncId 命中的分类必须接受云端改名');
      expect(await changeCount(), greaterThan(0));
    });

    test('父分类改名后，同批二级分类仍按新 kind|name 解析到同一父', () async {
      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮', kind: 'expense', level: 1, syncId: 'cat-food'),
        const ImportCategory(
            name: '早餐',
            kind: 'expense',
            level: 2,
            parentName: '餐饮',
            syncId: 'cat-breakfast'),
      ]);

      // 快照内部自洽：父改名后，子分类的 parentName 也跟着变
      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮-新', kind: 'expense', level: 1, syncId: 'cat-food'),
        const ImportCategory(
            name: '早餐-新',
            kind: 'expense',
            level: 2,
            parentName: '餐饮-新',
            syncId: 'cat-breakfast'),
      ]);

      final parent = await categoryBySyncId('cat-food');
      final child = await categoryBySyncId('cat-breakfast');
      expect(parent!.name, '餐饮-新');
      expect(child!.name, '早餐-新');
      expect(child.parentId, parent.id,
          reason: '改名必须同步置换内存 kind|name 索引，否则子分类解析不到父会另建一条');
      final all = await repo.getAllCategories();
      expect(all.where((c) => c.level == 1 && c.name == '餐饮').length, 0,
          reason: '旧名父分类不得残留（会造成云端/本地分类集永不收敛）');
    });

    test('目标 kind|name 已被另一条分类占用 → 保守跳过改名', () async {
      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮', kind: 'expense', level: 1, syncId: 'cat-a'),
        const ImportCategory(
            name: '交通', kind: 'expense', level: 1, syncId: 'cat-b'),
      ]);

      await service.importCategories(repo, [
        const ImportCategory(
            name: '交通', kind: 'expense', level: 1, syncId: 'cat-a'),
      ]);

      expect((await categoryBySyncId('cat-a'))!.name, '餐饮',
          reason: 'categories 的 (name,kind) 是业务唯一键，改名命中他人时保守跳过');
      expect((await categoryBySyncId('cat-b'))!.name, '交通');
    });

    test('云端名与本地名相同 → 不产生无意义写入', () async {
      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮', kind: 'expense', level: 1, syncId: 'cat-a'),
      ]);
      await clearChanges();

      await service.importCategories(repo, [
        const ImportCategory(
            name: '餐饮', kind: 'expense', level: 1, syncId: 'cat-a'),
      ]);

      expect(await changeCount(), 0);
    });
  });
}
