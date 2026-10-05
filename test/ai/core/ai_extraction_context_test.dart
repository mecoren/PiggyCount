import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:piggycount/ai/core/ai_extraction_context.dart';
import 'package:piggycount/ai/providers/ai_constants.dart';
import 'package:piggycount/data/db.dart';
import 'package:piggycount/data/repositories/local/local_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late PiggyDatabase db;
  late LocalRepository repo;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = PiggyDatabase.forTesting(NativeDatabase.memory());
    repo = LocalRepository(db);
  });

  tearDown(() async {
    await db.close();
  });

  test('forLedger 返回的分类包含用户可用分类', () async {
    final ledgerId = await repo.createLedger(name: 'test');
    final catA = await repo.createCategory(
      name: '自定义餐饮',
      kind: 'expense',
    );
    final catB = await repo.createCategory(name: '副业收入', kind: 'income');

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.expenseCategories, contains('自定义餐饮'));
    expect(ctx.incomeCategories, contains('副业收入'));
    expect(catA, greaterThan(0));
    expect(catB, greaterThan(0));
  });

  test('forLedger 加载用户自定义 prompt 模板', () async {
    SharedPreferences.setMockInitialValues({
      AIConstants.keyAiCustomPrompt: '自定义模板内容',
    });
    final ledgerId = await repo.createLedger(name: 'test');

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.customPromptTemplate, '自定义模板内容');
  });

  test('空白自定义模板视为未配置', () async {
    SharedPreferences.setMockInitialValues({
      AIConstants.keyAiCustomPrompt: '   ',
    });
    final ledgerId = await repo.createLedger(name: 'test');

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.customPromptTemplate, isNull);
  });

  // 智能记账多币种(.docs/multi-currency-ai A3):账户候选**不再**按账本本位币
  // 过滤 —— 过滤掉外币账户,AI 就永远匹配不到它们,「用我的美元卡付的」这类
  // 指令无解(#437)。改为全量喂给 AI 并标注币种,由 BillCreationService 按
  // 这笔的币种去匹配。
  test('accounts 包含外币账户,并带上各自币种', () async {
    // 脱敏关闭：断言真实名 + 币种标注的原始口径
    SharedPreferences.setMockInitialValues({
      AIConstants.keyAiDesensitizeAccounts: false,
    });
    final cnyLedgerId = await repo.createLedger(name: '人民币', currency: 'CNY');
    await repo.createAccount(
      ledgerId: cnyLedgerId,
      name: '招行 CNY',
      currency: 'CNY',
    );
    await repo.createAccount(
      ledgerId: cnyLedgerId,
      name: 'PayPal USD',
      currency: 'USD',
    );

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: cnyLedgerId,
    );

    final names = ctx.accounts.map((a) => a.name).toList();
    expect(names, contains('招行 CNY'));
    expect(names, contains('PayPal USD'));
    expect(
      ctx.accounts.firstWhere((a) => a.name == 'PayPal USD').currency,
      'USD',
    );
  });

  test('隐藏账户仍然被排除(#240 回归锁)', () async {
    // 脱敏关闭：断言真实名维度的排除语义
    SharedPreferences.setMockInitialValues({
      AIConstants.keyAiDesensitizeAccounts: false,
    });
    final ledgerId = await repo.createLedger(name: '人民币', currency: 'CNY');
    final hiddenId = await repo.createAccount(
      ledgerId: ledgerId,
      name: '已隐藏',
      currency: 'CNY',
    );
    await repo.setAccountHidden(hiddenId, true);

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.accounts.map((a) => a.name), isNot(contains('已隐藏')));
  });

  test('ledgerCurrency / availableCurrencies 反映账本与账户币种', () async {
    final ledgerId = await repo.createLedger(name: '人民币', currency: 'CNY');
    await repo.createAccount(
      ledgerId: ledgerId,
      name: 'PayPal',
      currency: 'USD',
    );

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.ledgerCurrency, 'CNY');
    expect(ctx.availableCurrencies, containsAll(<String>['CNY', 'USD']));
  });

  test('AiExtractionContext.fallback 是常量,字段全空', () {
    const ctx = AiExtractionContext.fallback;
    expect(ctx.expenseCategories, isEmpty);
    expect(ctx.incomeCategories, isEmpty);
    expect(ctx.accounts, isEmpty);
    expect(ctx.customPromptTemplate, isNull);
    expect(ctx.ledgerCurrency, 'CNY');
    expect(ctx.accountAliases, isEmpty);
  });

  test('脱敏默认开启：账户名替换为编号，别名可映射回真名', () async {
    SharedPreferences.setMockInitialValues({});
    final ledgerId = await repo.createLedger(name: '人民币', currency: 'CNY');
    await repo.createAccount(
      ledgerId: ledgerId,
      name: '张三的工资卡',
      currency: 'CNY',
    );
    await repo.createAccount(
      ledgerId: ledgerId,
      name: 'PayPal USD',
      currency: 'USD',
    );

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    final names = ctx.accounts.map((a) => a.name).toList();
    expect(names, containsAll(<String>['account_1', 'account_2']));
    expect(names.join(' '), isNot(contains('张三')));
    // 币种标注保留：按币种指定账户仍可命中
    expect(
      ctx.accounts.firstWhere((a) => a.name == 'account_2').currency,
      'USD',
    );
    // 别名→真名映射完整，可回解
    expect(ctx.accountAliases['account_1'], '张三的工资卡');
    expect(ctx.accountAliases['account_2'], 'PayPal USD');
    expect(
      AiExtractionContext.deanonymizeAccountName(
          'account_2', ctx.accountAliases),
      'PayPal USD',
    );
  });

  test('脱敏关闭：账户名原文透传，别名映射为空', () async {
    SharedPreferences.setMockInitialValues({
      AIConstants.keyAiDesensitizeAccounts: false,
    });
    final ledgerId = await repo.createLedger(name: '人民币', currency: 'CNY');
    await repo.createAccount(
      ledgerId: ledgerId,
      name: '招行 CNY',
      currency: 'CNY',
    );

    final ctx = await AiExtractionContext.forLedger(
      repository: repo,
      ledgerId: ledgerId,
    );

    expect(ctx.accounts.map((a) => a.name), contains('招行 CNY'));
    expect(ctx.accountAliases, isEmpty);
  });

  test('deanonymizeAccountName 非别名/空值原样返回', () {
    const aliases = {'account_1': '招行', 'account_2': 'PayPal'};
    expect(
      AiExtractionContext.deanonymizeAccountName('ACCOUNT_1', aliases),
      '招行',
    );
    expect(
      AiExtractionContext.deanonymizeAccountName('微信零钱', aliases),
      '微信零钱',
    );
    expect(AiExtractionContext.deanonymizeAccountName(null, aliases), isNull);
    expect(AiExtractionContext.deanonymizeAccountName('', aliases), '');
    expect(AiExtractionContext.deanonymizeAccountName('account_1', {}),
        'account_1');
  });

  test('anonymizeAccounts 纯函数：关闭/空列表返回空映射', () {
    expect(
      AiExtractionContext.anonymizeAccounts(const [], enabled: true),
      isEmpty,
    );
    expect(
      AiExtractionContext.anonymizeAccounts(
        const [(name: '招行', currency: 'CNY')],
        enabled: false,
      ),
      isEmpty,
    );
  });
}
