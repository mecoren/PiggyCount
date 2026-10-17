import '../../ai/core/bill_info.dart';
import '../../ai/providers/ai_provider_config.dart';
import '../../ai/providers/ai_provider_factory.dart';
import '../../ai/providers/ai_provider_manager.dart';
import '../../data/repositories/base_repository.dart';
import '../../l10n/app_localizations.dart';
import '../data/tag_seed_service.dart';
import '../system/logger_service.dart';
import 'ai_bookkeeper.dart';
import 'ai_quick_command_service.dart';

/// AI 对话服务
///
/// 两种模式:
/// 1. **对话记账** —— 委托给 [AiBookkeeper.fromText],返回带卡片的 AIResponse
/// 2. **自由对话 / AI 查账** —— 查账问句先按意图拼
///    [AIQuickCommandService] 的数据上下文，再连同系统提示词调
///    [AIProviderFactory.chat]
///
/// 这个 service 现在只剩**意图判定 + 调用编排**,真正的提取/落库逻辑全在
/// [AiBookkeeper] 里。
class AIChatService {
  final BaseRepository _repo;
  final AiBookkeeper _bookkeeper;

  /// 查账数据上下文构造器（按账本 id 构造 [AIQuickCommandService]）。
  ///
  /// 为 null 时退化成「只有记账能力」的旧行为；接线见
  /// `lib/providers/ai_chat_providers.dart`。
  final AIQuickCommandService Function(int ledgerId)? quickCommandServiceFactory;

  AIChatService({
    required BaseRepository repo,
    required AiBookkeeper bookkeeper,
    this.quickCommandServiceFactory,
  })  : _repo = repo,
        _bookkeeper = bookkeeper;

  /// 验证 AI 配置是否存在(仅本地配置,不发网络请求)
  static Future<AIConfigValidationResult> validateApiKey() async {
    final config = await AIProviderManager.getProviderForCapability(
      AICapabilityType.text,
    );
    if (config == null) {
      return AIConfigValidationResult.invalid('未配置文本对话服务商');
    }
    if (!config.isValid) {
      return AIConfigValidationResult.invalid('未配置 API Key');
    }
    if (!config.supportsText) {
      return AIConfigValidationResult.invalid('未配置文本模型');
    }
    return AIConfigValidationResult.valid();
  }

  /// 处理用户消息
  Future<AIResponse> processMessage(
    String userInput, {
    required int ledgerId,
    String? languageCode,
    bool forceChat = false,
    AppLocalizations? l10n,
  }) async {
    logger.info('AIChat', '收到消息: $userInput (forceChat: $forceChat)');
    try {
      if (!forceChat && _isTransactionIntent(userInput)) {
        return await _handleTransaction(
          userInput,
          ledgerId: ledgerId,
          l10n: l10n,
        );
      }

      // 自由对话：查账问句先按意图拼一份账本数据，随系统提示词一起外发。
      // 快捷指令（forceChat）的 prompt 本身已带数据段，下面会跳过注入。
      String? dataContext;
      final factory = quickCommandServiceFactory;
      if (!forceChat && factory != null) {
        try {
          final context =
              await factory(ledgerId).buildDataContext(userInput);
          if (context.trim().isNotEmpty) dataContext = context;
        } catch (e, st) {
          // 查账数据构建失败不应阻断对话：退化成「无数据」回答。
          logger.warning('AIChat', '查账数据上下文构建失败: $e');
          logger.debug('AIChat', '$st');
        }
      }

      return await _handleFreeChat(
        userInput,
        languageCode: languageCode,
        dataContext: dataContext,
      );
    } catch (e, st) {
      logger.error('AIChat', '处理失败', e, st);
      return AIResponse.error('抱歉,处理失败,请重试');
    }
  }

  /// 撤销记账(给 UI 卡片上的「撤销」按钮用)
  Future<bool> undoTransaction(int transactionId) async {
    try {
      await _repo.deleteTransaction(transactionId);
      logger.info('AIChat', '撤销记账: id=$transactionId');
      return true;
    } catch (e, st) {
      logger.error('AIChat', '撤销失败', e, st);
      return false;
    }
  }

  // ============================================================
  // 内部
  // ============================================================

  bool _isTransactionIntent(String input) {
    // 查账问句优先走对话：否则「这个月花了多少」会被关键词 `花` 误判成记账。
    if (AIQuickCommandService.looksLikeDataQuery(input)) return false;
    final hasAmount = RegExp(r'\d+(?:\.\d+)?').hasMatch(input);
    const keywords = ['买', '花', '消费', '支付', '记账', '付', '收入', '赚', '工资'];
    final hasKeyword = keywords.any((k) => input.contains(k));
    return hasAmount || hasKeyword;
  }

  Future<AIResponse> _handleTransaction(
    String input, {
    required int ledgerId,
    AppLocalizations? l10n,
  }) async {
    logger.debug('AIChat', '识别为记账意图');
    final result = await _bookkeeper.fromText(
      text: input,
      ledgerId: ledgerId,
      billingTypes: [TagSeedService.billingTypeAi],
      l10n: l10n,
    );

    if (!result.success) {
      logger.warning('AIChat', '账单提取失败或全部无有效金额');
      return AIResponse.text(
        '抱歉,未识别到完整的记账信息。\n\n'
        '请这样说:\n'
        '• 买了杯奶茶28块\n'
        '• 今天午餐花了50\n'
        '• 打车回家花了35',
      );
    }

    logger.info('AIChat', '账单提取成功: ${result.savedCount} 笔');
    return AIResponse.billCards(
      result.savedBills,
      result.transactionIds,
      // 多币种降级提示(移植 BeeCount #437 A5):缺汇率时已按 1:1 暂记,
      // 告诉用户去统计页补折算
      note: (result.unconvertedCurrencies.isEmpty || l10n == null)
          ? null
          : l10n.aiBillingRateMissingHint(
              result.unconvertedCurrencies.join('、')),
    );
  }

  /// 构造自由对话的系统提示词。
  ///
  /// 旧版在这里写死「统计、查询等功能暂不支持」，与快捷指令「把数据塞进
  /// prompt 让 AI 分析」的用法直接冲突 —— AI 收到数据却被告知不要回答。
  /// 现在改成：**有数据就只依据数据回答，没数据就引导用快捷指令**，
  /// 同时明确「查账问句不是记账」。
  String _buildSystemPrompt(String? languageCode, String? dataContext) {
    final isZh = (languageCode ?? '').startsWith('zh');
    final buffer = StringBuffer();
    if (isZh) {
      buffer.write(
        '你是小猪记账的 AI 财务助手，既帮助用户记账，也能基于用户账本数据做查账与统计分析。\n'
        '规则：\n'
        '1. 如果下方提供了「账本数据」，回答必须只使用这些数据，不得编造金额、分类或记录；数据不足时直接说明缺什么。\n'
        '2. 如果用户询问统计/查询但数据为空，告诉用户可以用下方的快捷指令（本月支出总结、分类占比分析等）发起查询，或补充时间范围。\n'
        '3. 不要把查账问句当成记账；只有用户明确描述一笔收支时，才引导记账。\n'
        '4. 金额保留两位小数，回答简洁，用中文回复。\n',
      );
    } else {
      buffer.write(
        "You are PiggyCount's AI financial assistant. You help with bookkeeping and also answer questions about the user's ledger data.\n"
        'Rules:\n'
        '1. If ledger data is provided below, answer using only that data. Never invent amounts, categories or transactions. If the data is insufficient, say what is missing.\n'
        '2. If the user asks for statistics but no data is provided, tell them to use the quick-command buttons (monthly summary, category breakdown, etc.) or to specify a time range.\n'
        '3. Do not treat a data question as a bookkeeping request; only guide bookkeeping when the user clearly describes a transaction.\n'
        "4. Keep amounts to two decimals and answer concisely in the user's language.\n",
      );
    }
    if (dataContext != null && dataContext.trim().isNotEmpty) {
      buffer
        ..write('\n')
        ..write(dataContext);
    }
    return buffer.toString();
  }

  Future<AIResponse> _handleFreeChat(
    String input, {
    String? languageCode,
    String? dataContext,
  }) async {
    logger.info('AIChat',
        '开始自由对话 (语言: ${languageCode ?? "默认"}, 查账数据: ${dataContext != null ? "有" : "无"})');
    try {
      final systemPrompt = _buildSystemPrompt(languageCode, dataContext);

      final response = await AIProviderFactory.chat(
        input,
        systemPrompt: systemPrompt,
        logTag: 'AIChat',
      );
      logger.info('AIChat', '对话响应成功');
      return AIResponse.text(response);
    } on AIException catch (e) {
      logger.warning('AIChat', '对话响应失败: ${e.message}');
      if (e.message.contains('配置无效')) {
        return AIResponse.error(
          '需要配置 API Key 才能使用对话功能。\n\n前往 设置 > AI设置 进行配置。',
        );
      }
      return AIResponse.error('AI服务暂时不可用,请稍后重试');
    } catch (e, st) {
      logger.error('AIChat', '自由对话失败', e, st);
      return AIResponse.error('网络连接失败,请检查网络');
    }
  }
}

/// AI 配置验证结果
class AIConfigValidationResult {
  final bool isValid;
  final String? errorMessage;

  AIConfigValidationResult({
    required this.isValid,
    this.errorMessage,
  });

  factory AIConfigValidationResult.valid() {
    return AIConfigValidationResult(isValid: true);
  }

  factory AIConfigValidationResult.invalid(String message) {
    return AIConfigValidationResult(isValid: false, errorMessage: message);
  }
}

/// AI 对话响应模型
class AIResponse {
  final String type; // 'text' | 'bill_card' | 'error'
  final String text;

  /// 所有识别到的账单(单笔/多笔都用 list)
  final List<BillInfo> bills;

  /// 与 [bills] 一一对应的交易 ID
  final List<int> transactionIds;

  AIResponse({
    required this.type,
    required this.text,
    this.bills = const [],
    this.transactionIds = const [],
  });

  /// 首个 BillInfo(兼容写入 messages.transactionId 列)
  BillInfo? get billInfo => bills.isNotEmpty ? bills.first : null;

  /// 首个交易 ID
  int? get transactionId =>
      transactionIds.isNotEmpty ? transactionIds.first : null;

  factory AIResponse.text(String text) =>
      AIResponse(type: 'text', text: text);

  /// 多笔/单笔统一入口。bills 与 txIds 必须等长且非空。
  ///
  /// [note] 附加在成功文案后的一行提示(目前用于多币种「缺汇率按 1:1 暂记」)。
  factory AIResponse.billCards(List<BillInfo> bills, List<int> txIds,
      {String? note}) {
    assert(bills.length == txIds.length && bills.isNotEmpty,
        'bills/txIds 必须等长且非空');
    final n = bills.length;
    final base = n == 1 ? '✅ 记账成功' : '✅ 已记账 $n 笔';
    return AIResponse(
      type: 'bill_card',
      text: (note == null || note.isEmpty) ? base : '$base\n$note',
      bills: List.unmodifiable(bills),
      transactionIds: List.unmodifiable(txIds),
    );
  }

  factory AIResponse.error(String message) =>
      AIResponse(type: 'error', text: message);
}
