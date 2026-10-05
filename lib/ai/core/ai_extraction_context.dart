import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/base_repository.dart';
import '../providers/ai_constants.dart';

/// 喂给 AI 的账户候选:名称 + 币种。
///
/// 带币种是多币种记账的前提(.docs/multi-currency-ai A3)——AI 要能看出
/// 「Chase 是美元账户」,才可能在用户说「用我的美元卡付的」时选中它。
typedef AiAccountRef = ({String name, String currency});

/// AI 多模态记账底座 · 上下文
///
/// 把 prompt 拼装需要的「用户可用分类 / 账户 / 币种 / 自定义模板」打包成 value
/// object,由应用层显式构造后传入底座。底座只读取字段,**不**反向依赖
/// Repository / SharedPreferences。
class AiExtractionContext {
  /// 用户可用支出分类(已过滤掉有子分类的父分类)
  final List<String> expenseCategories;

  /// 用户可用收入分类
  final List<String> incomeCategories;

  /// 可用账户(名称 + 币种)。**不再按账本本位币过滤** —— 见 [AiAccountRef]。
  final List<AiAccountRef> accounts;

  /// 账本本位币(ISO 大写)。AI 未给币种时交易回落到它。
  final String ledgerCurrency;

  /// 这个账本上下文里「见得到」的币种:本位币 ∪ 账户币种。
  /// 用途有二:prompt 里列给 AI 参考;口语别名的消歧上下文
  /// (`$` 在只有 CNY/USD 的账本里就能确定是 USD)。
  final List<String> availableCurrencies;

  /// 用户自定义 prompt 模板。`null` 或空白 = 使用默认模板。
  final String? customPromptTemplate;

  /// 账户别名映射（别名 → 真实账户名）。脱敏开启时 `accounts` 里装的是
  /// `account_1…` 别名，落库前由调用方经 [deanonymizeAccountName] 映射回
  /// 真实名；关闭时为空映射。
  final Map<String, String> accountAliases;

  const AiExtractionContext({
    this.expenseCategories = const [],
    this.incomeCategories = const [],
    this.accounts = const [],
    this.ledgerCurrency = 'CNY',
    this.availableCurrencies = const [],
    this.customPromptTemplate,
    this.accountAliases = const {},
  });

  /// 无账本场景的 fallback。prompt 走 hardcoded 默认分类,至少能识别金额。
  static const AiExtractionContext fallback = AiExtractionContext();

  /// 根据当前账本查询用户可用分类 + 账户(带币种),再加载用户自定义 prompt
  /// 模板,组装成 context。
  ///
  /// 5 个调用渠道(chat / image / voice / auto-screenshot / auto-text)统一
  /// 用这个工厂,避免重复 query 与漏传字段。
  static Future<AiExtractionContext> forLedger({
    required BaseRepository repository,
    required int ledgerId,
  }) async {
    final expenseCats = await repository.getUsableCategories('expense');
    final incomeCats = await repository.getUsableCategories('income');

    final accountRefs = <AiAccountRef>[];
    var ledgerCurrency = 'CNY';
    final currencies = <String>{};
    final ledger = await repository.getLedgerById(ledgerId);
    if (ledger != null) {
      if (ledger.currency.isNotEmpty) {
        ledgerCurrency = ledger.currency.toUpperCase();
      }
      final allAccounts = await repository.getAllAccounts();
      // 账户隐藏(#240):不把隐藏账户喂给 AI 作候选 —— 隐藏账户不再作为新交易
      // 的记账目标,与手动选择器 / Web AI 候选一致。
      //
      // 多币种(A3):**不再**按 `a.currency == ledger.currency` 过滤。过滤掉外币
      // 账户会让 AI 永远看不见它们,「用我的美元卡付的」这类指令无解(#437);
      // 币种匹配下沉到 BillCreationService,按这笔交易的币种去筛。
      for (final a in allAccounts) {
        if (a.hidden) continue;
        final code =
            (a.currency.isNotEmpty ? a.currency : ledgerCurrency).toUpperCase();
        accountRefs.add((name: a.name, currency: code));
        currencies.add(code);
      }
    }
    currencies.add(ledgerCurrency);

    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(AIConstants.keyAiCustomPrompt);
    final customTemplate =
        (saved != null && saved.trim().isNotEmpty) ? saved : null;

    // 账户名脱敏（默认开启）：发给 AI 的账户名替换为 account_1… 编号，
    // 别名→真名映射随 context 返回，落库前映射回去。
    final desensitize =
        prefs.getBool(AIConstants.keyAiDesensitizeAccounts) ?? true;
    final aliases = anonymizeAccounts(accountRefs, enabled: desensitize);
    final exposedRefs = desensitize
        ? [
            for (var i = 0; i < accountRefs.length; i++)
              (name: 'account_${i + 1}', currency: accountRefs[i].currency),
          ]
        : accountRefs;

    return AiExtractionContext(
      expenseCategories: expenseCats.map((c) => c.name).toList(),
      incomeCategories: incomeCats.map((c) => c.name).toList(),
      accounts: exposedRefs,
      ledgerCurrency: ledgerCurrency,
      availableCurrencies: currencies.toList()..sort(),
      customPromptTemplate: customTemplate,
      accountAliases: aliases,
    );
  }

  /// 为账户列表生成别名映射（别名 → 真实名），供 prompt 脱敏使用。
  ///
  /// 纯函数：`enabled=false` 或空列表时返回空映射；别名按传入顺序编号。
  static Map<String, String> anonymizeAccounts(
    List<AiAccountRef> refs, {
    required bool enabled,
  }) {
    if (!enabled || refs.isEmpty) return {};
    return {
      for (var i = 0; i < refs.length; i++) 'account_${i + 1}': refs[i].name,
    };
  }

  /// 把 AI 返回的账户名映射回真实名（脱敏回解）。
  ///
  /// 别名精确命中（大小写不敏感）即还原；非别名/空值原样返回，由下游
  /// `BillCreationService` 按原有完全→模糊→类型映射流程匹配。
  static String? deanonymizeAccountName(
    String? name,
    Map<String, String> aliases,
  ) {
    if (name == null || name.isEmpty || aliases.isEmpty) return name;
    final target = name.toLowerCase().trim();
    for (final entry in aliases.entries) {
      if (entry.key.toLowerCase() == target) return entry.value;
    }
    return name;
  }
}
