import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../providers.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/biz/amount_text.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/biz/section_card.dart';
import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../services/data/recurring_transaction_service.dart';
import '../../services/system/logger_service.dart';
import '../../utils/category_utils.dart';
import '../../styles/tokens.dart';
import 'recurring_transaction_edit_page.dart';

class RecurringTransactionPage extends ConsumerWidget {
  const RecurringTransactionPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recurringTransactionsAsync =
        ref.watch(allRecurringTransactionsProvider);

    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: AppLocalizations.of(context)!.recurringTransactionTitle,
        showBack: true,
        actions: [
          IconButton(
            onPressed: () => _addRecurringTransaction(context, ref),
            icon: const Icon(Icons.add),
            tooltip: AppLocalizations.of(context)!.recurringTransactionAdd,
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: PiggyTokens.topScrollablePadding(context),
        ),
        child: Column(
          children: [
            Expanded(
              child: RefreshIndicator(
                onRefresh: () async {
                  PiggyHaptics.light();
                  ref.invalidate(allRecurringTransactionsProvider);
                  try {
                    await ref.read(allRecurringTransactionsProvider.future);
                  } catch (_) {
                    // 失败保持静默，错误分支由 when 展示
                  }
                },
                child: recurringTransactionsAsync.when(
                  // skipLoading*: 下拉刷新后保留旧数据渲染，避免整页闪 loading
                  skipLoadingOnReload: true,
                  skipLoadingOnRefresh: true,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (error, stack) => Center(
                    child: Text('Error: $error'),
                  ),
                  data: (recurringTransactions) {
                    if (recurringTransactions.isEmpty) {
                      return AppEmpty(
                        text: AppLocalizations.of(context)!
                            .recurringTransactionEmpty,
                        subtext: AppLocalizations.of(context)!
                            .recurringTransactionEmptyHint,
                        icon: Icons.repeat,
                      );
                    }

                    return ListView.builder(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 16),
                      // AlwaysScrollable: 内容不满一屏时也能下拉刷新
                      physics: const AlwaysScrollableScrollPhysics(),
                      itemCount: recurringTransactions.length +
                          1, // +1 for usage guide card
                      itemBuilder: (context, index) {
                        // 第一个显示使用说明卡片
                        if (index == 0) {
                          return Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _UsageGuideCard(),
                          );
                        }
                        // 后续显示周期记账卡片
                        final recurring = recurringTransactions[index - 1];
                        return _RecurringTransactionCard(recurring: recurring);
                      },
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _addRecurringTransaction(BuildContext context, WidgetRef ref) async {
    final result = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => const RecurringTransactionEditPage(),
      ),
    );
    // 如果返回 true，表示数据已更改，强制刷新列表
    if (result == true) {
      ref.invalidate(allRecurringTransactionsProvider);
    }
  }
}

class _RecurringTransactionCard extends ConsumerWidget {
  final RecurringTransaction recurring;

  const _RecurringTransactionCard({required this.recurring});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final repo = ref.watch(repositoryProvider);
    final primaryColor = ref.watch(primaryColorProvider);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: PiggyTokens.surface(context),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
        // 主题色细边框（与统计页图表卡片统一），用边框替代阴影
        border: Border.all(
          color: recurring.enabled ? primaryColor : PiggyTokens.border(context),
          width: 1.5,
        ),
        boxShadow: null,
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () async {
            final result = await Navigator.of(context).push<bool>(
              MaterialPageRoute(
                builder: (_) =>
                    RecurringTransactionEditPage(recurring: recurring),
              ),
            );
            // 如果返回 true，表示数据已更改，强制刷新列表
            if (result == true) {
              ref.invalidate(allRecurringTransactionsProvider);
            }
          },
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                // 左侧：类型指示条
                Container(
                  width: 3,
                  height: 48,
                  decoration: BoxDecoration(
                    color: recurring.type == 'expense'
                        ? PiggyTokens.error(context)
                        : recurring.type == 'income'
                            ? PiggyTokens.success(context)
                            : primaryColor,
                    borderRadius: BorderRadius.circular(1.5),
                  ),
                ),
                const SizedBox(width: 12),
                // 中间：信息区域
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 第一行：分类名称
                      recurring.type == 'transfer'
                          ? Text(
                              AppLocalizations.of(context)!.transferTitle,
                              style: PiggyTextTokens.strongTitle(context)
                                  .copyWith(fontSize: 16),
                            )
                          : FutureBuilder<Category?>(
                              future: _getCategory(ref, recurring.categoryId),
                              builder: (context, snapshot) {
                                final categoryName = snapshot.data?.name ?? '';
                                return Text(
                                  CategoryUtils.getDisplayName(
                                      categoryName, context),
                                  style: PiggyTextTokens.strongTitle(context)
                                      .copyWith(fontSize: 16),
                                );
                              },
                            ),
                      const SizedBox(height: 6),
                      // 第二行：账本 + 频率 + 时间
                      Row(
                        children: [
                          // 账本
                          FutureBuilder<Ledger?>(
                            future: _getLedger(ref, recurring.ledgerId),
                            builder: (context, snapshot) {
                              final ledgerName = snapshot.data?.name ?? '';
                              return Text(
                                ledgerName,
                                style: PiggyTextTokens.label(context).copyWith(
                                    color: PiggyTokens.textTertiary(context)),
                              );
                            },
                          ),
                          Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '·',
                              style: PiggyTextTokens.label(context).copyWith(
                                  color: PiggyTokens.textTertiary(context)),
                            ),
                          ),
                          // 频率
                          Text(
                            _getFrequencyDescription(context),
                            style: PiggyTextTokens.label(context).copyWith(
                                color: PiggyTokens.textTertiary(context)),
                          ),
                          // 下次生成时间（如果有）
                          if (recurring.lastGeneratedDate != null) ...[
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 6),
                              child: Text(
                                '·',
                                style: PiggyTextTokens.label(context).copyWith(
                                    color: PiggyTokens.textTertiary(context)),
                              ),
                            ),
                            Icon(
                              Icons.access_time,
                              size: 11,
                              color: primaryColor,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              DateFormat.Md()
                                  .format(recurring.lastGeneratedDate!),
                              style: TextStyle(
                                fontSize: 12,
                                color: primaryColor,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ],
                      ),
                      // 备注（如果有）
                      if (recurring.note != null &&
                          recurring.note!.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        Text(
                          recurring.note!,
                          style: PiggyTextTokens.caption(context).copyWith(
                            color: PiggyTokens.textSecondary(context),
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                // 右侧：金额 + 开关
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 金额
                    AmountText(
                      value: recurring.type == 'expense'
                          ? -recurring.amount
                          : recurring.amount,
                      signed: recurring.type != 'transfer',
                      decimals: 2,
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: recurring.type == 'expense'
                            ? PiggyTokens.error(context)
                            : recurring.type == 'income'
                                ? PiggyTokens.success(context)
                                : PiggyTokens.textPrimary(context),
                      ),
                    ),
                    const SizedBox(height: 2),
                    // 开关：PiggySwitcher（参考 wait-home WaitSwitcher 视觉规格）
                    PiggySwitcher(
                      value: recurring.enabled,
                      onChanged: (value) async {
                        try {
                          await repo.toggleRecurringTransaction(
                              recurring.id, value);

                          // 给Realtime一点时间触发更新
                          await Future.delayed(
                              const Duration(milliseconds: 100));

                          ref.invalidate(allRecurringTransactionsProvider);
                        } catch (e, stackTrace) {
                          logger.warning(
                              'RecurringPage', '切换周期记账失败: $e', stackTrace);
                          // 审计 U5：失败必须回滚开关并提示，否则 UI 呈现
                          // 「已开启/关闭」而 DB 实际未变（假成功）
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                  content: Text(
                                      '${AppLocalizations.of(context)!.commonFailed}: $e')),
                            );
                          }
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _getFrequencyDescription(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final frequency = RecurringFrequency.fromString(recurring.frequency);
    final interval = recurring.interval;

    if (interval == 1) {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionDaily;
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionWeekly;
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionMonthly;
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionYearly;
      }
    } else {
      switch (frequency) {
        case RecurringFrequency.daily:
          return l10n.recurringTransactionEveryNDays(interval);
        case RecurringFrequency.weekly:
          return l10n.recurringTransactionEveryNWeeks(interval);
        case RecurringFrequency.monthly:
          return l10n.recurringTransactionEveryNMonths(interval);
        case RecurringFrequency.yearly:
          return l10n.recurringTransactionEveryNYears(interval);
      }
    }
  }

  Future<Category?> _getCategory(WidgetRef ref, int? categoryId) async {
    if (categoryId == null) return null;
    final repo = ref.read(repositoryProvider);
    return await repo.getCategoryById(categoryId);
  }

  Future<Ledger?> _getLedger(WidgetRef ref, int ledgerId) async {
    final repo = ref.read(repositoryProvider);
    return await repo.getLedgerById(ledgerId);
  }
}

/// 使用说明卡片
class _UsageGuideCard extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final primaryColor = ref.watch(primaryColorProvider);

    return SectionCard(
      margin: EdgeInsets.zero,
      borderColor: primaryColor,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline,
            size: 20,
            color: primaryColor,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  l10n.recurringTransactionUsageTitle,
                  style: PiggyTextTokens.strongTitle(context),
                ),
                const SizedBox(height: 6),
                Text(
                  l10n.recurringTransactionUsageContent,
                  style: PiggyTextTokens.label(context).copyWith(
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
