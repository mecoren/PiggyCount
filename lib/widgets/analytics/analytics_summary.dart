import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../styles/tokens.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/currency_providers.dart';
import '../../providers/theme_providers.dart';
import '../../utils/currencies.dart';

/// 完整数字格式：千分号 + 始终保留两位小数，不带币种符号、不压缩万/k/M。
/// 仅用于「洞察」页合计卡：用户要求展示完整金额，不要 "¥14.63万" 这种缩写。
String _formatFullPlain(double v, {bool signed = false}) {
  final abs = v.abs().toStringAsFixed(2);
  final parts = abs.split('.');
  final intPart = parts[0];
  final decPart = parts.length > 1 ? parts[1] : '00';

  // 千分号：每 3 位插入逗号
  final buf = StringBuffer();
  for (int i = 0; i < intPart.length; i++) {
    if (i > 0 && (intPart.length - i) % 3 == 0) buf.write(',');
    buf.write(intPart[i]);
  }

  final core = '${buf.toString()}.$decPart';
  if (v < 0) return '-$core';
  if (signed) return '+$core';
  return core;
}

/// 洞察页统一金额文字样式：不带币种符号、带千分号、固定两位小数。
/// 4 个指标（总额/平均/同比/结余）使用相同字号（与「收支报表」同款尺寸），
/// 确保视觉一致。
Text _summaryAmount(BuildContext context, String text, Color? color) {
  return Text(
    text,
    maxLines: 1,
    overflow: TextOverflow.ellipsis,
    style: TextStyle(
      fontSize: 16,
      height: 1.15,
      fontWeight: FontWeight.w700,
      color: color ?? PiggyTokens.textPrimary(context),
    ),
  );
}

/// 洞察页顶部合计卡片（2×2 四指标网格，参考收支报表样式）。
///
/// 四个指标：
/// - 总额：当前视角大字号金额，颜色按语义（支出/收入遵循用户配色方案）
/// - 平均：日均（月视角）/ 月均（年视角）/ 平均值（全部视角）
/// - 同比：比上年同期的增减额（月/年视角）；全部视角无上期，改为记账笔数
/// - 结余：本期收支结余（正绿负红）；结余视角第 4 格显示总支出
///
/// 每个指标前置蓝色色块 marker（参考收支报表卡片样式），无卡片阴影。
/// 支持 [hideAmounts] 隐藏金额与暗黑/浅色主题。
///
/// 数字展示规则（用户要求）：4 个金额统一字号，不带币种符号，不使用万/k/M
/// 缩写，始终保留两位小数（如 `146,300.00`）。见 [_formatFullPlain]。
class AnalyticsSummary extends ConsumerWidget {
  final String scope; // week/month/year/all
  final bool isExpense;
  final bool isBalance; // 结余视角
  final double total; // 本期总额（结余视角为结余）
  final double avg; // 平均
  final double? prevTotal; // 上期总额（同比用）；null 时同比格显示记账笔数
  final double balance; // 本期收支结余
  final int txCount; // 记账笔数
  final double? expenseTotal; // 结余视角第 4 格展示的总支出
  final Color? expenseColor; // 支出颜色（遵循用户设置）
  final Color? incomeColor; // 收入颜色（遵循用户设置）

  const AnalyticsSummary({
    super.key,
    required this.scope,
    required this.isExpense,
    required this.isBalance,
    required this.total,
    required this.avg,
    required this.balance,
    required this.txCount,
    this.prevTotal,
    this.expenseTotal,
    this.expenseColor,
    this.incomeColor,
  });

  /// 周期平均值标签：月视角=日均、年视角=月均、全部=平均值
  String _avgLabel(AppLocalizations l10n) {
    switch (scope) {
      case 'year':
        return l10n.analyticsMonthlyAvg;
      case 'all':
        return l10n.analyticsOverallAvg;
      case 'month':
      default:
        return l10n.analyticsDailyAvg;
    }
  }

  /// 去掉 l10n 文案尾部的冒号空格（标签用于卡片网格）
  String _trimColon(String s) => s.replaceAll(RegExp(r'[\s:：]+$'), '');

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final titleWord = isBalance
        ? l10n.analyticsBalance
        : (isExpense ? l10n.analyticsExpense : l10n.analyticsIncome);
    // 周视角标签为「本周支出/本周收入」，其余为「总支出/总收入」
    final title = isBalance
        ? _trimColon(titleWord)
        : _trimColon(scope == 'week'
            ? l10n.analyticsWeekTotal(titleWord)
            : l10n.analyticsTotal(titleWord));
    final avgLabel = _avgLabel(l10n);
    // 单位：主币别（如中文环境显示「（人民币）」）
    final unit = '(${getCurrencyName(ref.watch(currentLedgerCurrencyProvider), context)})';

    // 主指标颜色：结余按正负，支出/收入按用户设置的收支配色方案
    final primaryColor = isBalance
        ? (total >= 0
            ? PiggyTokens.success(context)
            : PiggyTokens.error(context))
        : (isExpense
            ? (expenseColor ?? PiggyTokens.expenseColor(context, ref))
            : (incomeColor ?? PiggyTokens.incomeColor(context, ref)));
    final balanceColor = balance >= 0
        ? PiggyTokens.success(context)
        : PiggyTokens.error(context);
    final yoy = prevTotal != null ? total - prevTotal! : 0.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        // 参考收支报表卡片样式：纯白底、无阴影、圆角
        borderRadius: BorderRadius.circular(PiggyDimens.radius2xl),
        border: Border.all(
          color: ref.watch(primaryColorProvider),
          width: 1.5,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 第一行：总额 + 平均
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cell(
                context,
                label: title + unit,
                value: _summaryAmount(context, _formatFullPlain(total), primaryColor),
              ),
              const SizedBox(width: 16),
              _cell(
                context,
                label: avgLabel + unit,
                value: _summaryAmount(context, _formatFullPlain(avg), null),
              ),
            ],
          ),
          const SizedBox(height: 18),
          // 第二行：同比（或记账笔数）+ 结余（或总支出）
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _cell(
                context,
                label: (prevTotal != null
                        ? (scope == 'week'
                            ? l10n.analyticsComparedToLastWeek
                            : l10n.analyticsComparedToLastYear)
                        : l10n.analyticsTxCount) +
                    unit,
                value: prevTotal != null
                    ? _summaryAmount(
                        context,
                        _formatFullPlain(yoy, signed: true),
                        PiggyTokens.primary(context),
                      )
                    : _summaryAmount(context, '$txCount', null),
              ),
              const SizedBox(width: 16),
              _cell(
                context,
                label: ((isBalance && expenseTotal != null)
                        ? _trimColon(l10n.analyticsTotalExpense)
                        : _trimColon(l10n.analyticsBalance)) +
                    unit,
                value: (isBalance && expenseTotal != null)
                    ? _summaryAmount(
                        context,
                        _formatFullPlain(expenseTotal!),
                        expenseColor ??
                            PiggyTokens.expenseColor(context, ref),
                      )
                    : _summaryAmount(
                        context,
                        _formatFullPlain(balance, signed: true),
                        balanceColor,
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 单个指标格：左侧蓝色色块 marker + 小标签 + 金额
  Widget _cell(BuildContext context,
      {required String label, required Widget value}) {
    return Expanded(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 左侧蓝色色块 marker（参考收支报表卡片样式）
          Container(
            width: 3,
            height: 14,
            margin: const EdgeInsets.only(top: 4, right: 8),
            decoration: BoxDecoration(
              color: PiggyTokens.primary(context),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PiggyTokens.textSecondary(context),
                        fontSize: 11,
                      ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 4),
                // 超长金额缩小兜底，防溢出
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: value,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}