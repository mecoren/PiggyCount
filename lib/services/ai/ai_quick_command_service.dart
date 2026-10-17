import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart';
import '../../models/ai_quick_command.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../utils/month_range.dart';
import '../../utils/sensitive_data_masker.dart';
import '../security/sensitive_note_service.dart';
import 'package:drift/drift.dart' as drift;
import '../../data/repositories/local/local_repository.dart';

/// AI快捷指令服务
class AIQuickCommandService {
  final PiggyDatabase db;
  final int ledgerId;
  /// 读取账本每月起始日(走 repo 注入,不在本文件再扩 db 直查)
  final Future<int> Function() monthStartDayLoader;

  AIQuickCommandService({
    required this.db,
    required this.ledgerId,
    Future<int> Function()? monthStartDayLoader,
  }) : monthStartDayLoader = monthStartDayLoader ?? (() async => 1);

  /// 简单格式化金额（保留2位小数）
  String _formatAmount(double amount) {
    return amount.toStringAsFixed(2);
  }

  /// 获取指定数据类型的数据文本
  ///
  /// 数据段全部来自数据库、与 UI 文案无关，因此**不需要** `BuildContext`；
  /// 去掉它之后自由对话（[AIChatService]）也能复用同一份查账数据。
  Future<String> _getDataText(QuickCommandDataType type) async {
    switch (type) {
      case QuickCommandDataType.monthlyStats:
        return await _getMonthlyStatsText();
      case QuickCommandDataType.categoryStats:
        return await _getCategoryStatsText();
      case QuickCommandDataType.recentTransactions:
        return await _getRecentTransactionsText();
      case QuickCommandDataType.recentTrends:
        return await _getRecentTrendsText();
      case QuickCommandDataType.none:
        return '';
    }
  }

  /// 是否像「查账 / 统计分析」类问句（而不是描述一笔收支）。
  ///
  /// 只认强问句标记：`今天午餐花了50` 没有问句词，仍按记账处理；
  /// `这个月花了多少` 命中「多少」→ 走查账对话，不再被记成账。
  static bool looksLikeDataQuery(String input) {
    final text = input.trim();
    if (text.isEmpty) return false;
    const markers = <String>[
      '多少',
      '几笔',
      '统计',
      '占比',
      '趋势',
      '明细',
      '汇总',
      '分析',
      '哪几笔',
      '哪些',
      '什么',
      '怎么样',
      '如何',
      '吗',
      '？',
      '?',
      '结余',
      '储蓄率',
      '查一下',
      '查查',
      '看看',
      '帮我查',
      '花了多少',
    ];
    return markers.any(text.contains);
  }

  /// 按问句意图拼装「账本数据」上下文，供自由对话的 AI 查账使用。
  ///
  /// 只取与问句相关的数据段，避免每轮都把整本账本塞进提示词；
  /// 返回空串表示「不是查账问句」。数据段本身已带【】标题，可直接拼接。
  Future<String> buildDataContext(String userInput) async {
    if (!looksLikeDataQuery(userInput)) return '';

    final text = userInput;
    final wanted = <QuickCommandDataType>{
      // 查账总要先知道本月收支，作为所有分析的基线。
      QuickCommandDataType.monthlyStats,
    };
    if (text.contains('分类') ||
        text.contains('占比') ||
        text.contains('花在') ||
        text.contains('哪类')) {
      wanted.add(QuickCommandDataType.categoryStats);
    }
    if (text.contains('趋势') ||
        text.contains('上月') ||
        text.contains('上个月') ||
        text.contains('对比') ||
        text.contains('最近几个月') ||
        text.contains('近三个月')) {
      wanted.add(QuickCommandDataType.recentTrends);
    }
    if (text.contains('最近') ||
        text.contains('明细') ||
        text.contains('哪几笔') ||
        text.contains('记录') ||
        text.contains('流水')) {
      wanted.add(QuickCommandDataType.recentTransactions);
    }

    final parts = <String>[];
    for (final type in wanted) {
      final value = await _getDataText(type);
      if (value.trim().isNotEmpty) parts.add(value.trim());
    }
    if (parts.isEmpty) return '';
    return '【账本数据】（仅以下数据可用，回答时不得编造未提供的数字）\n'
        '${parts.join('\n\n')}';
  }

  /// 获取本月统计数据文本
  Future<String> _getMonthlyStatsText() async {
    try {
      final now = DateTime.now();
      final sd = await monthStartDayLoader();
      final range = periodContaining(now, sd);
      final startOfMonth = range.start;
      final endOfMonth = range.end;

      // 获取本月交易记录
      final transactions = await (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(startOfMonth) &
                t.happenedAt.isSmallerThanValue(endOfMonth)))
          .get();

      if (transactions.isEmpty) {
        return '本月暂无交易记录';
      }

      // 统计收支
      double totalIncome = 0;
      double totalExpense = 0;
      for (final t in transactions) {
        if (t.type == 'income') {
          totalIncome += t.nativeAmount ?? t.amount;
        } else if (t.type == 'expense') {
          totalExpense += t.nativeAmount ?? t.amount;
        }
      }

      final balance = totalIncome - totalExpense;
      final savingsRate = totalIncome > 0 ? (balance / totalIncome * 100) : 0;

      return '''
【本月统计】
- 总收入: ${_formatAmount(totalIncome)}
- 总支出: ${_formatAmount(totalExpense)}
- 结余: ${_formatAmount(balance)}
- 储蓄率: ${savingsRate.toStringAsFixed(1)}%
- 交易笔数: ${transactions.length}笔
''';
    } catch (e) {
      return '获取月度统计数据失败: $e';
    }
  }

  /// 获取分类统计数据文本
  Future<String> _getCategoryStatsText() async {
    try {
      final now = DateTime.now();
      final sd = await monthStartDayLoader();
      final range = periodContaining(now, sd);
      final startOfMonth = range.start;
      final endOfMonth = range.end;

      // 获取本月支出交易
      final transactions = await (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.type.equals('expense') &
                t.happenedAt.isBiggerOrEqualValue(startOfMonth) &
                t.happenedAt.isSmallerThanValue(endOfMonth)))
          .get();

      if (transactions.isEmpty) {
        return '本月暂无支出记录';
      }

      // 按分类统计
      final categoryTotals = <int, double>{};
      for (final t in transactions) {
        if (t.categoryId != null) {
          categoryTotals[t.categoryId!] =
          (categoryTotals[t.categoryId!] ?? 0) + (t.nativeAmount ?? t.amount);
        }
      }

      // 获取分类名称并排序
      final categoryList = <String>[];
      final totalExpense = transactions.fold<double>(
          0, (sum, t) => sum + (t.nativeAmount ?? t.amount));

      final sortedEntries = categoryTotals.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      for (final entry in sortedEntries.take(10)) {
        final category = await (db.select(db.categories)
              ..where((c) => c.id.equals(entry.key)))
            .getSingleOrNull();

        if (category != null) {
          final percentage = (entry.value / totalExpense * 100).toStringAsFixed(1);
          categoryList.add('- ${category.name}: ${_formatAmount(entry.value)} ($percentage%)');
        }
      }

      return '''
【分类统计】(前10)
${categoryList.join('\n')}
''';
    } catch (e) {
      return '获取分类统计数据失败: $e';
    }
  }

  /// 获取最近交易记录文本
  Future<String> _getRecentTransactionsText() async {
    try {
      // 获取最近30天的交易
      final now = DateTime.now();
      final thirtyDaysAgo = now.subtract(const Duration(days: 30));

      final transactions = await (db.select(db.transactions)
            ..where((t) =>
                t.ledgerId.equals(ledgerId) &
                t.happenedAt.isBiggerOrEqualValue(thirtyDaysAgo))
            ..orderBy([(t) => drift.OrderingTerm.desc(t.happenedAt)])
            ..limit(20))
          .get();

      if (transactions.isEmpty) {
        return '最近30天暂无交易记录';
      }

      final list = <String>[];
      // 备注敏感标记：外发前把敏感备注替换为固定掩码（设备本地标记）
      final sensitiveIds = await const SensitiveNoteService().load();
      for (final t in transactions) {
        String? categoryName;
        if (t.categoryId != null) {
          final category = await (db.select(db.categories)
                ..where((c) => c.id.equals(t.categoryId!)))
              .getSingleOrNull();
          categoryName = category?.name;
        }

        final date = t.happenedAt.toString().substring(0, 10);
        final typeStr = t.type == 'income' ? '收入' : '支出';
        final amountStr = _formatAmount(t.amount);
        final maskedNote =
            SensitiveDataMasker.maskNoteIf(sensitiveIds.contains(t.id), t.note);
        final noteStr = maskedNote.isNotEmpty ? ' ($maskedNote)' : '';

        list.add('- $date $typeStr $amountStr ${categoryName ?? ""}$noteStr');
      }

      return '''
【最近交易】(最近20笔)
${list.join('\n')}
''';
    } catch (e) {
      return '获取最近交易记录失败: $e';
    }
  }

  /// 获取近期趋势数据文本
  Future<String> _getRecentTrendsText() async {
    try {
      final now = DateTime.now();
      final sd = await monthStartDayLoader();
      final trends = <String>[];
      final nowLabel = labelForDate(now, sd);

      // 获取最近3个记账周期的数据
      for (int i = 0; i < 3; i++) {
        final label = DateTime(nowLabel.year, nowLabel.month - i, 1);
        final r = periodForLabel(label.year, label.month, sd);
        final month = r.start;
        final nextMonth = r.end;

        final transactions = await (db.select(db.transactions)
              ..where((t) =>
                  t.ledgerId.equals(ledgerId) &
                  t.happenedAt.isBiggerOrEqualValue(month) &
                  t.happenedAt.isSmallerThanValue(nextMonth)))
            .get();

        double income = 0;
        double expense = 0;
        for (final t in transactions) {
          if (t.type == 'income') {
            income += t.nativeAmount ?? t.amount;
          } else if (t.type == 'expense') {
            expense += t.nativeAmount ?? t.amount;
          }
        }

        final monthStr = '${month.year}年${month.month}月';
        trends.add('- $monthStr: 收入${_formatAmount(income)}, 支出${_formatAmount(expense)}');
      }

      return '''
【近期趋势】
${trends.join('\n')}
''';
    } catch (e) {
      return '获取近期趋势数据失败: $e';
    }
  }

  /// 生成完整的Prompt
  Future<String> generatePrompt(
    AIQuickCommand command,
    BuildContext context,
  ) async {
    // 获取prompt模板
    final l10n = AppLocalizations.of(context);
    final String promptTemplate;

    // 根据promptTemplateKey获取模板
    switch (command.promptTemplateKey) {
      case 'aiQuickCommandFinancialHealthPrompt':
        promptTemplate = l10n.aiQuickCommandFinancialHealthPrompt;
        break;
      case 'aiQuickCommandMonthlyExpensePrompt':
        promptTemplate = l10n.aiQuickCommandMonthlyExpensePrompt;
        break;
      case 'aiQuickCommandCategoryAnalysisPrompt':
        promptTemplate = l10n.aiQuickCommandCategoryAnalysisPrompt;
        break;
      case 'aiQuickCommandBudgetPlanningPrompt':
        promptTemplate = l10n.aiQuickCommandBudgetPlanningPrompt;
        break;
      case 'aiQuickCommandAbnormalExpensePrompt':
        promptTemplate = l10n.aiQuickCommandAbnormalExpensePrompt;
        break;
      case 'aiQuickCommandSavingTipsPrompt':
        promptTemplate = l10n.aiQuickCommandSavingTipsPrompt;
        break;
      default:
        promptTemplate = command.promptTemplateKey;
    }

    // 获取所需数据
    final dataMap = <String, String>{};
    for (final dataType in command.requiredData) {
      final key = dataType.name;
      final value = await _getDataText(dataType);
      dataMap[key] = value;
    }

    // 填充模板
    String result = promptTemplate;
    for (final entry in dataMap.entries) {
      result = result.replaceAll('[${entry.key}]', entry.value);
    }

    return result;
  }
}

/// Provider for AIQuickCommandService
final aiQuickCommandServiceProvider = Provider.family<AIQuickCommandService, int>((ref, ledgerId) {
  final repo = ref.watch(repositoryProvider);
  // 注意: AIQuickCommandService 需要直接访问 PiggyDatabase 实例进行查询
  return AIQuickCommandService(
    db: (repo as LocalRepository).db,
    ledgerId: ledgerId,
    monthStartDayLoader: () async {
      final l = await repo.getLedgerById(ledgerId);
      return (l?.monthStartDay ?? 1).clamp(1, 28);
    },
  );
});
