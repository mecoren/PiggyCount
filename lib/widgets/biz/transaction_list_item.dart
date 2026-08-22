import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart' as db;
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/category_icon.dart';
import '../../providers/database_providers.dart';
import '../../providers/theme_providers.dart';
import 'amount_text.dart';
import 'transaction_row_title.dart';

class TransactionListItem extends ConsumerWidget {
  final IconData icon;
  final db.Category? category; // 可选的分类对象，用于显示自定义图标
  final String title;
  final double amount;

  /// v30 多币种:交易原币种(null/等于账本本位币 → 维持无符号纯数字;
  /// 外币 → 金额前显示其币种符号,如 JP¥/US$,一眼区分原币)。
  final String? currencyCode;

  /// v30 多币种:折账本本位币快照。外币交易在金额右下角显示 ≈ 折算小字(反馈13)。
  final double? nativeAmount;
  final bool isExpense; // 决定正负号
  final bool isTransfer; // 是否为转账（转账不显示正负号）
  final bool isAdjustment; // 是否为估值调整
  final bool? hide; // 改为可选,null时使用全局状态
  final VoidCallback? onTap;
  final VoidCallback? onCategoryTap; // 点击分类图标/名称的回调
  final String? categoryName; // 分类名称，用于显示
  final String? ledgerName; // 账本名称（仅"全部账本"模式下显示标签）
  final VoidCallback? onDelete; // 删除回调
  final String? accountName; // 账户名称，用于显示
  final DateTime? happenedAt; // 交易时间，用于显示时分

  // 批量选择模式相关
  final bool isSelectionMode; // 是否处于选择模式
  final bool isSelected; // 是否被选中
  final VoidCallback? onSelectionChanged; // 选中状态改变回调
  final bool showFullDate; // 是否显示完整日期（年-月-日 时:分）

  // 标签相关
  final List<({int id, String name, String? color})>? tags; // 关联的标签
  final void Function(int tagId, String tagName)? onTagTap; // 点击标签回调

  // 附件相关
  final int attachmentCount; // 附件数量
  final VoidCallback? onAttachmentTap; // 点击附件图标回调

  final bool excludeFromStats; // 不计入收支:第二行显示「不计收支」标签
  final bool excludeFromBudget; // 不计入预算:第二行显示「不计预算」标签

  /// 交易唯一 id，用于 Dismissible key，避免同备注同金额的交易 key 碰撞
  final int transactionId;

  const TransactionListItem({
    super.key,
    required this.icon,
    this.category,
    required this.title,
    required this.amount,
    required this.transactionId,
    this.currencyCode,
    this.nativeAmount,
    required this.isExpense,
    this.isTransfer = false,
    this.isAdjustment = false,
    this.hide,
    this.onTap,
    this.onCategoryTap,
    this.categoryName,
    this.ledgerName,
    this.onDelete,
    this.accountName,
    this.happenedAt,
    this.isSelectionMode = false,
    this.isSelected = false,
    this.onSelectionChanged,
    this.showFullDate = false,
    this.tags,
    this.onTagTap,
    this.attachmentCount = 0,
    this.onAttachmentTap,
    this.excludeFromStats = false,
    this.excludeFromBudget = false,
  });

  /// 检查是否有次要信息需要显示（时间、备注、账户、标签、附件）
  bool _hasSecondaryInfo(WidgetRef ref, String? parenNote) {
    // 显示完整日期模式
    if (showFullDate && happenedAt != null) return true;

    // 显示时间（设置开启 + 有数据 + 不是00:00:00）
    final showTime = ref.watch(showTransactionTimeProvider) &&
        happenedAt != null &&
        (happenedAt!.hour != 0 ||
            happenedAt!.minute != 0 ||
            happenedAt!.second != 0);

    return showTime ||
        (parenNote != null && parenNote.isNotEmpty) ||
        accountName != null ||
        attachmentCount > 0 ||
        (tags != null && tags!.isNotEmpty) ||
        excludeFromStats ||
        excludeFromBudget;
  }

  /// 「不计收支 / 不计预算」标记的小 pill（中性灰底，de-emphasis）
  /// 视觉对齐 TagChip(small)：pill 圆角 + 低透明度填充 + fontSize 11
  Widget _flagChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: PiggyTokens.isDark(context)
            ? Colors.white.withValues(alpha: 0.1)
            : Colors.black.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      ),
      child: Text(
        label,
        style: PiggyTextTokens.caption(context),
      ),
    );
  }

  /// 构建次要信息小部件（时间 | 备注 | 账户 | 标签 · 附件图标）
  ///
  /// 段与段之间用竖杠 `|` 分隔;标签为彩色可点击文本(沿用 TagChip 的取色逻辑)。
  Widget _buildSecondaryInfo(
      BuildContext context, WidgetRef ref, String? parenNote) {
    final textStyle = PiggyTextTokens.caption(context);
    final sep = Text(' | ', style: textStyle);

    // 文本段：时间 | 备注 | 账户
    final textParts = <String>[];
    if (happenedAt != null) {
      if (showFullDate) {
        // 完整日期模式
        textParts.add(
          '${happenedAt!.year}-${happenedAt!.month.toString().padLeft(2, '0')}-${happenedAt!.day.toString().padLeft(2, '0')} '
          '${happenedAt!.hour.toString().padLeft(2, '0')}:${happenedAt!.minute.toString().padLeft(2, '0')}',
        );
      } else if (ref.watch(showTransactionTimeProvider) &&
          (happenedAt!.hour != 0 ||
              happenedAt!.minute != 0 ||
              happenedAt!.second != 0)) {
        // 完整时间模式（HH:mm:ss）
        textParts.add(
          '${happenedAt!.hour.toString().padLeft(2, '0')}:${happenedAt!.minute.toString().padLeft(2, '0')}:${happenedAt!.second.toString().padLeft(2, '0')}',
        );
      }
    }
    // 备注（时间右边，竖杠分隔）
    if (parenNote != null && parenNote.isNotEmpty) {
      textParts.add(parenNote);
    }
    // 账户
    if (accountName != null) {
      textParts.add(accountName!);
    }

    // 构建附件图标部件（可点击）
    Widget buildAttachmentWidget() {
      final widget = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.image_outlined,
            size: 12,
            color: PiggyTokens.textTertiary(context),
          ),
          const SizedBox(width: 2),
          Text('$attachmentCount', style: textStyle),
        ],
      );
      if (onAttachmentTap != null) {
        return GestureDetector(
          onTap: onAttachmentTap,
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
            child: widget,
          ),
        );
      }
      return widget;
    }

    // 标签段：彩色可点击文本（保留 TagChip 的取色与点击行为）
    final tagWidgets = <Widget>[
      if (tags != null)
        for (final tag in tags!)
          GestureDetector(
            onTap: onTagTap != null ? () => onTagTap!(tag.id, tag.name) : null,
            behavior: HitTestBehavior.opaque,
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Text(
                tag.name,
                style: textStyle.copyWith(
                    color: _tagTextColor(context, tag.color)),
              ),
            ),
          ),
    ];

    // 「不计收支 / 不计预算」标签:第二行末尾的次要标签
    final flagTags = <Widget>[
      if (excludeFromStats)
        _flagChip(context, AppLocalizations.of(context).txFlagExcludedTag),
      if (excludeFromBudget)
        _flagChip(
            context, AppLocalizations.of(context).txFlagBudgetExcludedTag),
    ];

    // 组装段：文本(join 竖杠) → 附件 → 标签，各段之间用竖杠连接
    final segments = <Widget>[];
    if (textParts.isNotEmpty) {
      segments.add(Text(textParts.join(' | '), style: textStyle));
    }
    if (attachmentCount > 0) {
      segments.add(buildAttachmentWidget());
    }
    if (tagWidgets.isNotEmpty) {
      segments.addAll(tagWidgets);
    }

    final children = <Widget>[];
    for (int i = 0; i < segments.length; i++) {
      if (i > 0) children.add(sep);
      children.add(segments[i]);
    }
    children.addAll(flagTags);

    // 用 Wrap 避免次要行溢出（标签可能与附件并排）
    return Wrap(
      spacing: 6,
      runSpacing: 2,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: children,
    );
  }

  /// 标签文本颜色解析（与 TagChip._parseColor 同一取色规则）
  Color _tagTextColor(BuildContext context, String? color) {
    if (color == null || color.isEmpty) {
      return Theme.of(context).colorScheme.primary;
    }
    try {
      String hex = color;
      if (hex.startsWith('#')) hex = hex.substring(1);
      if (hex.length == 6) hex = 'FF$hex';
      return Color(int.parse(hex, radix: 16));
    } catch (_) {
      return Theme.of(context).colorScheme.primary;
    }
  }

  bool _isForeign(WidgetRef ref) {
    final cc = currencyCode;
    if (cc == null || cc.isEmpty) return false;
    final base =
        ref.watch(currentLedgerProvider).asData?.value?.currency ?? 'CNY';
    return cc.toUpperCase() != base.toUpperCase();
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // 第一行主文本 + 第二行备注。mode='note' 时 primary 即备注(parenNote=null,
    // 第二行不重复);默认 'category' 时 primary=分类名、parenNote=备注(第二行显示)。
    final composed = composeTransactionRowTitle(
      mode: ref.watch(noteDisplayModeProvider),
      categoryName: categoryName,
      title: title,
    );
    final composedParenNote = composed.parenNote;

    Widget child = InkWell(
      onTap: isSelectionMode ? onSelectionChanged : onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: 12, vertical: PiggyDimens.listRowVertical),
        child: Row(
          children: [
            // 选择模式下显示复选框，否则显示分类图标
            if (isSelectionMode)
              Checkbox(
                value: isSelected,
                onChanged: (_) => onSelectionChanged?.call(),
                activeColor: Theme.of(context).colorScheme.primary,
              )
            else
              // 分类图标，支持点击跳转（无背景）
              GestureDetector(
                onTap: onCategoryTap,
                behavior: HitTestBehavior.opaque,
                child: SizedBox(
                  width: 32,
                  height: 32,
                  child: Center(
                    child: CategoryIconWidget(
                      category: category,
                      size: 22,
                    ),
                  ),
                ),
              ),
            const SizedBox(width: 12),
            // 左侧：分类名称 + 备注 + 时间·账户
            Expanded(
              child: Padding(
                padding: const EdgeInsets.only(right: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // 第一行：分类名（备注已移到第二行时间右边，此处不再挂括号）
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            composed.primary,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: PiggyTextTokens.title(context),
                          ),
                        ),
                        // 全部账本模式：展示账本名标签（参考账户详情页）
                        if (ledgerName != null && ledgerName!.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: ref
                                  .watch(primaryColorProvider)
                                  .withValues(alpha: 0.1),
                              borderRadius:
                                  BorderRadius.circular(PiggyDimens.radiusXs),
                            ),
                            child: Text(
                              ledgerName!,
                              style: PiggyTextTokens.caption(context).copyWith(
                                color: ref.watch(primaryColorProvider),
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // 第二行：时间 | 备注 | 账户 | 标签 · 附件
                    if (_hasSecondaryInfo(ref, composedParenNote))
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _buildSecondaryInfo(
                            context, ref, composedParenNote),
                      ),
                  ],
                ),
              ),
            ),
            // 右侧：金额 + ≈折算小字
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                // 金额（转账不显示正负号）
                AmountText(
                    value: isAdjustment
                        ? amount // adjustment 直接显示原始值（含正负）
                        : isExpense
                            ? -amount
                            : amount,
                    hide: hide,
                    signed: !isTransfer, // 转账不显示正负号
                    // v30:外币交易显示其币种符号(原币语义);本位币维持纯数字
                    showCurrency: _isForeign(ref),
                    currencyCode: currencyCode,
                    decimals: 2,
                    style: PiggyTextTokens.title(context).copyWith(
                      color: isAdjustment
                          ? (amount >= 0
                              ? PiggyTokens.incomeColor(context, ref)
                              : PiggyTokens.expenseColor(context, ref))
                          : isTransfer
                              ? PiggyTokens.textPrimary(context)
                              : isExpense
                                  ? PiggyTokens.expenseColor(context, ref)
                                  : PiggyTokens.incomeColor(context, ref),
                    )),
                // ≈折算小字(标签已移到第二行,此处仅保留折算)。
                // 隐藏金额开关开启时折算同样遮蔽。
                if (_isForeign(ref) &&
                    nativeAmount != null &&
                    nativeAmount != amount &&
                    hide != true)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text(
                      '≈${nativeAmount!.toStringAsFixed(2)}',
                      style: PiggyTextTokens.caption(context),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );

    // 如果提供了删除回调，则包装在Dismissible中支持侧滑删除
    if (onDelete != null) {
      return Dismissible(
        key: ValueKey('tx_$transactionId'),
        direction: DismissDirection.endToStart,
        background: Container(
          alignment: Alignment.centerRight,
          padding: const EdgeInsets.only(right: 20),
          color: Colors.red,
          child: const Icon(
            Icons.delete,
            color: Colors.white,
            size: 24,
          ),
        ),
        confirmDismiss: (direction) async {
          // 滑动到位触发确认时给一次中强度触感
          PiggyHaptics.medium();
          // 显示确认对话框
          return await AppDialog.confirm<bool>(
                context,
                title: '确认删除',
                message: '确定要删除这笔交易吗？此操作无法撤销。',
              ) ??
              false;
        },
        onDismissed: (direction) {
          PiggyHaptics.warning();
          onDelete!();
        },
        child: child,
      );
    }

    return child;
  }
}
