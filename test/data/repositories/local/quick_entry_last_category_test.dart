// `TransactionRepository.getLastUsedCategoryId` 契约测试（P1-E 快捷记账模式 R1）。
//
// 覆盖 requirements.md 的 AC-R1 全部 7 个场景，外加索引断言与两个边界。
//
// 本方法的记忆源刻意**从 transactions 派生**而非存 SharedPreferences：
// 依据是本仓库对「派生数据 vs 缓存副本」的既有取舍（见 getNoteHistory 的注释），
// 且共享账本的 synthetic id 由 Dart `String.hashCode` 派生，
// 跨 VM 版本/平台无稳定性保证 —— 一旦持久化，某次 Flutter 升级后
// 存下来的 id 就会指向另一个（或不存在）分类。这是正确性差异，不是性能差异。
//
// 索引断言用 `quickEntryLastCategorySql`（仓库导出的同一份 SQL），
// 而不是在测试里另抄一份字面量 —— 否则改仓库 SQL 就能骗过测试。
// 本仓库此前有「性能断言写错、实测才发现代价无上界」的教训，故把结论钉进 CI。
//
// ⚠️ 本文件在实现当天就抓到了设计文档决策 1 的一个真 bug，值得记下来：
// 设计要求「SQL 加 LIMIT 100，工作量上界 = 100 次索引项 + 至多 100 次回表」，
// 但**SQLite 的 LIMIT 约束的是结果行数，不是扫描行数**。只要 WHERE 里写着
// `type = ?`，当最近 K 笔都不是目标类型时，SQLite 必须沿索引一路回表扫描
// 直到凑满 K 行匹配记录（或扫完整个索引）—— 上界直接丢失，退化成与被否决的
// 「全账本 GROUP BY」同量级的 O(N)。
// 「scanLimit 生效」这条用例把它暴露出来（K=3 时返回了那笔支出，而按设计语义应为 null）。
// 修法：把 type 过滤移出 SQL，交给 Dart 侧 —— 这样 LIMIT 才真正等价于「只看最近 K 笔」。

import 'package:flutter_test/flutter_test.dart';
import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';
import 'package:piggycount/data/repositories/local/local_transaction_repository.dart';
import 'package:piggycount/utils/shared_ledger_picker_filter.dart';

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

  group('R1 上次分类记忆', () {
    test('AC#1 返回最近一笔带分类交易的分类', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 20,
        categoryId: traffic,
        happenedAt: DateTime(2026, 7, 5),
      );

      expect(
        await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'),
        traffic,
        reason: '应取 happened_at 最新那笔的分类',
      );
    });

    test('AC#2 支出与收入各记各的，互不覆盖', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final salary = await repo.createCategory(name: '工资', kind: 'income');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );
      await repo.addTransaction(
        ledgerId: 1,
        type: 'income',
        amount: 9999,
        categoryId: salary,
        happenedAt: DateTime(2026, 7, 9),
      );

      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), food);
      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'income'), salary);
    });

    test('AC#3 空账本返回 null 且不抛异常', () async {
      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), isNull);
      expect(await repo.getLastUsedCategoryId(ledgerId: 999, kind: 'income'), isNull);
    });

    test('AC#4 最近若干笔无分类时继续往前找，不提前中断', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );
      // 之后 3 笔都没有分类（category_id 为 NULL）
      for (var i = 2; i <= 4; i++) {
        await repo.addTransaction(
          ledgerId: 1,
          type: 'expense',
          amount: 10,
          happenedAt: DateTime(2026, 7, i),
        );
      }

      expect(
        await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'),
        food,
        reason: '碰到 NULL 分类要继续倒序找，取最近一笔**非空**分类',
      );
    });

    test('AC#4 全部无分类时返回 null', () async {
      for (var i = 1; i <= 3; i++) {
        await repo.addTransaction(
          ledgerId: 1,
          type: 'expense',
          amount: 10,
          happenedAt: DateTime(2026, 7, i),
        );
      }
      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), isNull);
    });

    test('AC#5 分类被删除后不抛异常（调用方须自行校验存在性后再预填）', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );

      await repo.deleteCategory(food);

      // 断言「不抛」而不是断言具体值 —— 删分类是否连带清 transactions.category_id
      // 取决于外键 onDelete 策略，本方法不该假设任一结果。
      // 真正的护栏在调用侧：AC-R2 #4 要求预填前逐项校验。
      final result = await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense');
      expect(result == null || result == food, isTrue, reason: '实际: $result');
    });

    test('AC#6 转账不参与统计', () async {
      final a = await repo.createAccount(ledgerId: 1, name: 'A');
      final b = await repo.createAccount(ledgerId: 1, name: 'B');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'transfer',
        amount: 50,
        accountId: a,
        toAccountId: b,
        happenedAt: DateTime(2026, 7, 9),
      );

      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), isNull);
      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'income'), isNull);
    });

    test('AC#7 新增交易后立即反映新分类（无陈旧缓存窗口）', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      final traffic = await repo.createCategory(name: '交通', kind: 'expense');

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );
      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), food);

      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: traffic,
        happenedAt: DateTime(2026, 7, 2),
      );
      expect(
        await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'),
        traffic,
        reason: '该实现不做任何缓存，写入后必须立刻可见',
      );
    });
  });

  group('R1 边界', () {
    test('跨账本隔离，不串台', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );

      expect(await repo.getLastUsedCategoryId(ledgerId: 2, kind: 'expense'), isNull);
    });

    test('共享账本 Owner 分类：读取时派生负数 synthetic id，且等于 syntheticIdForSyncId', () async {
      const override = 'owner-cat-sync-1';
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categorySyncIdOverride: override,
        happenedAt: DateTime(2026, 7, 1),
      );

      final result = await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense');

      expect(result, syntheticIdForSyncId(override));
      expect(result, lessThan(0), reason: 'synthetic id 一律负数，用于与本地正数 id 区分');
    });

    test('本地 id 与 override 同时存在时优先返回本地正数 id', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        categorySyncIdOverride: 'owner-cat-sync-1',
        happenedAt: DateTime(2026, 7, 1),
      );

      expect(await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense'), food);
    });

    test('scanLimit 生效：窗口内没有同类型交易时返回 null（退回网格，无正确性损失）', () async {
      final food = await repo.createCategory(name: '餐饮', kind: 'expense');
      await repo.addTransaction(
        ledgerId: 1,
        type: 'expense',
        amount: 10,
        categoryId: food,
        happenedAt: DateTime(2026, 7, 1),
      );
      // 之后 5 笔收入把窗口占满
      for (var i = 2; i <= 6; i++) {
        await repo.addTransaction(
          ledgerId: 1,
          type: 'income',
          amount: 10,
          happenedAt: DateTime(2026, 7, i),
        );
      }

      expect(
        await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense', scanLimit: 3),
        isNull,
        reason: '窗口只看最近 3 笔（全是收入），故 miss —— 这是设计上可接受的降级',
      );
      expect(
        await repo.getLastUsedCategoryId(ledgerId: 1, kind: 'expense', scanLimit: 100),
        food,
        reason: '窗口放大到 100 就能看到那笔支出',
      );
    });
  });

  group('R1 索引断言', () {
    test('查询命中 idx_transactions_ledger_happened，且不退化成分页全表扫', () async {
      final plan = await db
          .customSelect(
            'EXPLAIN QUERY PLAN $quickEntryLastCategorySql',
            variables: [
              // EXPLAIN 只编译不执行，绑定值本身不参与计划，给占位即可。
              const Variable<int>(1),
              const Variable<int>(100),
            ],
          )
          .get();
      final planText = plan.map((r) => r.data['detail'] as String).join('\n');

      expect(
        planText,
        contains('idx_transactions_ledger_happened'),
        reason: '「上次分类」查询必须命中复合索引。实际计划:\n$planText',
      );
      // SCAN transactions = 逐行全表扫；走索引时计划里是 SEARCH ... USING INDEX。
      expect(
        planText.contains('SCAN transactions'),
        isFalse,
        reason: '不得退化为全表扫（type/category_id 不在索引里，靠 LIMIT 兜住上界）。实际计划:\n$planText',
      );
    });
  });
}
