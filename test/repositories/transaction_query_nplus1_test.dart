// D 组回归测试:验证 getTransactionsByDateRange / getTransactionsByDate 不再
// N+1。
//
// N+1 行为计数在 Drift 下不可靠(logStatements 走 developer.log 而非 print,
// Zone 捕获不到),故 N+1 守卫改用源码契约(与 home_header_layout_test 一致):
// 断言方法体使用批量 `isIn(` 模式,而非逐条 `equals(tx.id)` 的 N+1 模式。
// 同时保留行为正确性测试(category/tags/attachments/accounts 全部回填)。
import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async => db.close());

  /// 搭建 [count] 条交易,每条挂 1 个 category、1 个 account、2 个 tag、1 个附件。
  Future<void> seed(int count) async {
    final ledgerId = await db.into(db.ledgers).insert(
          LedgersCompanion.insert(name: 'L'),
        );
    final catId = await db.into(db.categories).insert(
          CategoriesCompanion.insert(name: 'C', kind: 'expense'),
        );
    final accId = await db.into(db.accounts).insert(
          AccountsCompanion.insert(ledgerId: ledgerId, name: 'A'),
        );
    final tag1 = await db.into(db.tags).insert(TagsCompanion.insert(name: 't1'));
    final tag2 = await db.into(db.tags).insert(TagsCompanion.insert(name: 't2'));
    for (var i = 0; i < count; i++) {
      final txId = await db.into(db.transactions).insert(
            TransactionsCompanion.insert(
              ledgerId: ledgerId,
              type: 'expense',
              amount: 1.0 * i,
              categoryId: Value(catId),
              accountId: Value(accId),
              happenedAt: Value(DateTime(2026, 7, 1, 10, i)),
            ),
          );
      await db.into(db.transactionTags).insert(
            TransactionTagsCompanion.insert(transactionId: txId, tagId: tag1),
          );
      await db.into(db.transactionTags).insert(
            TransactionTagsCompanion.insert(transactionId: txId, tagId: tag2),
          );
      await db.into(db.transactionAttachments).insert(
            TransactionAttachmentsCompanion.insert(
              transactionId: txId,
              fileName: 'f$i.jpg',
            ),
          );
    }
  }

  group('getTransactionsByDateRange 正确性', () {
    test('返回每条交易的 category/tags/attachments/account', () async {
      await seed(3);
      final res = await repo.getTransactionsByDateRange(
        ledgerId: 1,
        startDate: DateTime(2026, 7, 1),
        endDate: DateTime(2026, 7, 2),
      );
      expect(res, hasLength(3));
      for (final r in res) {
        expect(r.category, isNotNull, reason: 'category 应回填');
        expect(r.account, isNotNull, reason: 'account 应回填');
        expect(r.tags, hasLength(2), reason: '每条 2 个 tag');
        expect(r.attachments, hasLength(1), reason: '每条 1 个附件');
      }
    });
  });

  group('getTransactionsByDate 正确性', () {
    test('返回当天的 category/tags/attachments/account', () async {
      await seed(2);
      final res = await repo.getTransactionsByDate(
        ledgerId: 1,
        date: DateTime(2026, 7, 1),
      );
      expect(res, hasLength(2));
      for (final r in res) {
        expect(r.category, isNotNull, reason: 'category 应回填(已批量化)');
        expect(r.tags, hasLength(2));
        expect(r.attachments, hasLength(1));
        expect(r.account, isNotNull);
      }
    });
  });

  // ===== N+1 源码契约守卫 =====
  // 当前的 N+1 模式:for (final transaction in transactions) { await db.select(...)
  // 批量化后:一次 where(id.isIn(...)) / where(transactionId.isIn(...))
  // 契约断言方法体不再含逐条 N+1 循环,且使用批量 isIn 模式。
  final source = File('lib/data/repositories/local/local_transaction_repository.dart')
      .readAsStringSync();

  group('getTransactionsByDateRange N+1 守卫(源码契约)', () {
    // 提取 getTransactionsByDateRange 方法体(到下一个 @override 或文件尾)
    final methodMatch = RegExp(
      r'getTransactionsByDateRange\(\{[^}]*\}\)\s*async\s*\{([\s\S]*?)\n\s{2}\}',
    ).firstMatch(source);
    late String methodBody;
    if (methodMatch != null) {
      methodBody = methodMatch.group(1)!;
    }

    test('方法体已提取(守卫:防止重构后方法签名变化未同步测试)', () {
      expect(methodMatch, isNotNull,
          reason: '未找到 getTransactionsByDateRange 方法体,可能已重构');
    });

    test('不再使用逐条 N+1 循环查 category/account/attachments', () {
      // N+1 标志:在 for (final transaction in transactions) 循环内 await db.select
      expect(methodBody, isNotNull);
      final hasNplus1Loop = RegExp(
        r'for\s*\(\s*final\s+transaction\s+in\s+transactions\s*\)[\s\S]*?await\s*\(\s*db\.select',
      ).hasMatch(methodBody!);
      expect(hasNplus1Loop, isFalse,
          reason: 'getTransactionsByDateRange 不得在交易循环内逐条 SELECT(N+1)');
    });

    test('使用批量 isIn 查询 transaction_tags', () {
      expect(methodBody, isNotNull);
      expect(methodBody!.contains('transactionId.isIn('), isTrue,
          reason: '应批量查 transaction_tags: where(transactionId.isIn(txIds))');
    });
  });

  group('getTransactionsByDate category N+1 守卫(源码契约)', () {
    final methodMatch = RegExp(
      r'getTransactionsByDate\(\{[^}]*\}\)\s*async\s*\{([\s\S]*?)\n\s{2}\}',
    ).firstMatch(source);
    late String methodBody;
    if (methodMatch != null) {
      methodBody = methodMatch.group(1)!;
    }

    test('不再逐条查 category(N+1)', () {
      expect(methodMatch, isNotNull,
          reason: '未找到 getTransactionsByDate 方法体,可能已重构');
      // N+1 标志:for (final tx in transactions) 内 await db.select(db.categories)
      final hasCategoryNplus1 = RegExp(
        r'for\s*\(\s*final\s+tx\s+in\s+transactions\s*\)[\s\S]*?await\s*\(\s*db\.select\(db\.categories',
      ).hasMatch(methodBody);
      expect(hasCategoryNplus1, isFalse,
          reason: 'getTransactionsByDate 不得逐条查 category(N+1),应批量化');
    });

    test('使用批量 isIn 查询 categories', () {
      expect(methodBody, isNotNull);
      // 批量化后用 c.id.isIn(categoryIds.toList()) 查 categories 表,
      // 而非逐条 c.id.equals(tx.categoryId)。
      expect(methodBody.contains('isIn(categoryIds'), isTrue,
          reason: '应批量查 categories: where(id.isIn(categoryIds))');
    });
  });
}
