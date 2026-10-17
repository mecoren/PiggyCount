/// AI 查账（F2）数据层契约测试。
///
/// 守两件事：
/// 1. **意图分流**：查账问句不能被当成记账（否则「这个月花了多少」会被
///    `_isTransactionIntent` 的关键词 `花` 吃掉）；
/// 2. **数据上下文**：自由对话按问句意图拼出对应的数据段，且无数据时
///    仍给出「暂无」而不是空气泡。
library;

import 'package:drift/drift.dart' as d;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/data/db.dart';
import 'package:piggycount/services/ai/ai_quick_command_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  SharedPreferences.setMockInitialValues({});

  late PiggyDatabase db;
  late AIQuickCommandService service;

  setUp(() async {
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    await db.customStatement(
        "INSERT INTO ledgers (id, name, currency) VALUES (1, 'L', 'CNY')");
    service = AIQuickCommandService(db: db, ledgerId: 1);
  });

  tearDown(() async => db.close());

  Future<int> seedCategory(String name, String kind) {
    return db.into(db.categories).insert(CategoriesCompanion.insert(
          name: name,
          kind: kind,
        ));
  }

  Future<void> seedExpense({
    required double amount,
    int? categoryId,
    DateTime? happenedAt,
  }) {
    final at = happenedAt ?? DateTime.now();
    return db.into(db.transactions).insert(TransactionsCompanion.insert(
          ledgerId: 1,
          type: 'expense',
          amount: amount,
          categoryId: d.Value(categoryId),
          happenedAt: d.Value(at),
        ));
  }

  group('looksLikeDataQuery：查账问句 vs 记账描述', () {
    test('查账问句命中', () {
      for (final q in [
        '这个月花了多少',
        '本月支出统计',
        '分类占比怎么样',
        '最近几笔明细',
        '我的结余是多少',
        '帮我查一下上个月的消费',
        '最近三个月的趋势如何',
      ]) {
        expect(AIQuickCommandService.looksLikeDataQuery(q), isTrue,
            reason: '应判为查账问句：$q');
      }
    });

    test('记账描述不命中', () {
      for (final q in [
        '今天午餐花了50',
        '买了杯奶茶28块',
        '打车回家35',
        '工资到账8000',
      ]) {
        expect(AIQuickCommandService.looksLikeDataQuery(q), isFalse,
            reason: '应判为记账描述：$q');
      }
    });

    test('空串不是查账问句', () {
      expect(AIQuickCommandService.looksLikeDataQuery('   '), isFalse);
    });
  });

  group('buildDataContext：按意图拼数据段', () {
    test('非查账问句返回空串（纯聊天不把账本外发）', () async {
      expect(await service.buildDataContext('今天午餐花了50'), isEmpty);
    });

    test('无交易时仍返回「暂无」段落', () async {
      final ctx = await service.buildDataContext('这个月花了多少');
      expect(ctx, contains('【账本数据】'));
      expect(ctx, contains('本月暂无交易记录'));
    });

    test('本月统计段带出收入 / 支出 / 结余', () async {
      await seedExpense(amount: 50);
      final ctx = await service.buildDataContext('这个月花了多少');
      expect(ctx, contains('【本月统计】'));
      expect(ctx, contains('总支出: 50.00'));
    });

    test('分类问句追加分类统计段', () async {
      final food = await seedCategory('餐饮', 'expense');
      await seedExpense(amount: 30, categoryId: food);
      final ctx = await service.buildDataContext('这个月分类占比怎么样');
      expect(ctx, contains('【本月统计】'));
      expect(ctx, contains('【分类统计】'));
      expect(ctx, contains('餐饮'));
    });

    test('明细问句追加最近交易段', () async {
      final food = await seedCategory('餐饮', 'expense');
      await seedExpense(amount: 30, categoryId: food);
      final ctx = await service.buildDataContext('最近的明细记录');
      expect(ctx, contains('【最近交易】'));
    });

    test('趋势问句追加近期趋势段', () async {
      await seedExpense(amount: 30);
      final ctx = await service.buildDataContext('最近三个月趋势如何');
      expect(ctx, contains('【近期趋势】'));
    });

    test('数据段带「不得编造」约束，避免模型凭空补数', () async {
      final ctx = await service.buildDataContext('这个月花了多少');
      expect(ctx, contains('不得编造'));
    });
  });
}
