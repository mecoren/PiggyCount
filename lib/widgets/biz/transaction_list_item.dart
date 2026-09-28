import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/db.dart' as db;
import '../../data/models/transaction_original_amount.dart';
import '../../l10n/app_localizations.dart';
import '../../providers/original_amount_providers.dart';
import '../../styles/tokens.dart';
import '../../widgets/ui/ui.dart';
import '../../widgets/category_icon.dart';
import '../../providers/database_providers.dart';
import '../../providers/theme_providers.dart';
import 'amount_text.dart';
import 'transaction_row_title.dart';

/// ≈折算小字可见性判定。
///
/// 必须与 AmountText 隐藏口径一致：显式 [hide] 优先，否则回落全局开关。
/// （审计 U1：旧实现只判参数 hide，calendar_page 构造时不传，
/// 全局隐藏开启后折算金额明文泄漏。）
bool nativeConversionVisible({required bool? hide, required bool globalHide}) =>
    !(hide ?? globalHide);

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

  /// v45 原始金额(用户手填)。非空且偏差达阈值时在金额下方显示「原 x.xx」
  /// 小字 —— 未填写(null)不渲染,避免整列表被噪音填满。
  final double? originalAmount;
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

  /// B1(v47):自定义字段角标(「字段名: 展示值」文本,调用方已按定义解析好)。
  /// 空/null 不渲染,避免整列表被噪音填满;放入次要信息行的竖杠分段里。
  final List<String>? customFieldBadges;

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
    this.originalAmount,
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
    this.customFieldBadges,
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
        (customFieldBadges != null && customFieldBadges!.isNotEmpty) ||
        excludeFromStats ||
        excludeFromBudget;
  }

  /// 「不计收支 / 不计预算」标记的小 pill（中性灰底，de-emphasis）
  /// 视觉对齐 TagChip(small)：pill 圆角 + 低透明度填充 + fontSize 11
  Widget _flagChip(BuildContext context, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        // UI-15：底色走 token，不再手写 white10/black06
        color: PiggyTokens.surfaceSelected(context),
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
        // InkWell 而非 GestureDetector：给出涟漪反馈（原先点了没任何视觉
        // 响应，用户不确定是否点中）。
        //
        // 内边距从 4/2 放大到 8/6 —— 触控区随 Wrap 行高一起增长，而不是
        // 硬套 48×48。理由：这是次要信息行（标签/附件计数），整行本身
        // 也有「打开交易详情」的点击；若每个内联元素各占 48dp 垂直空间，
        // 主列表每条交易会增高约 28dp，万级列表的滚动密度会被彻底破坏。
        // Material 的 48dp 下限针对独立可交互控件，不适用于行内文本级入口。
        return InkWell(
          onTap: onAttachmentTap,
          borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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
          InkWell(
            onTap: onTagTap != null ? () => onTagTap!(tag.id, tag.name) : null,
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXs),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
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

    // 组装段：文本(join 竖杠) → 自定义字段角标 → 附件 → 标签，各段之间用竖杠连接
    final segments = <Widget>[];
    if (textParts.isNotEmpty) {
      segments.add(Text(textParts.join(' | '), style: textStyle));
    }
    // B1(v47)自定义字段角标:每条一段,跟在时间|备注|账户之后。纯文本段,
    // 与次要信息同级,Wrap 溢出时自然折行。
    if (customFieldBadges != null) {
      for (final badge in customFieldBadges!) {
        segments.add(Text(badge, style: textStyle));
      }
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
    // v45 原始金额角标的口径与基准：与偏差分析页共用同一 provider，
    // 页面一改口径列表标记立刻跟随（避免"页面一套、列表另一套"）。
    // 计算与 [TransactionOriginalAmountX] 逐字同义，这里直接由已传入的
    // amount / nativeAmount / originalAmount 求出，不再另造 Transaction。
    final originalMetric = ref.watch(originalAmountMetricProvider);
    final originalBasis = ref.watch(originalAmountBasisProvider);
    final originalRecordedSide = originalMetric == OriginalAmountMetric.native
        ? (nativeAmount ?? amount)
        : amount;
    final originalSide = originalAmount == null
        ? originalRecordedSide
        : (originalMetric == OriginalAmountMetric.native && amount != 0
            ? originalAmount! * originalRecordedSide / amount
            : originalAmount!);
    final originalDiff = originalBasis == OriginalAmountBasis.recorded
        ? originalSide - originalRecordedSide
        : originalRecordedSide - originalSide;
    final originalBaseSide = originalBasis == OriginalAmountBasis.recorded
        ? originalRecordedSide
        : originalSide;
    final showOriginalBadge = originalAmount != null &&
        originalDiff.abs() >= math.max(1.0, originalBaseSide.abs() * 0.20) &&
        nativeConversionVisible(
          hide: hide,
          globalHide: ref.watch(hideAmountsProvider),
        );

    // P7：外币判定一次求出复用（此前金额主/副两处各调一次 _isForeign，
    // 每次都 watch 账本 + 两次 toUpperCase 分配，按可见行数放大）。
    final foreign = _isForeign(ref);

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
        // UI-07：金额列原来是 Flexible(flex:1)，与左侧 Expanded(flex:1)
        // 平分剩余宽度——即使金额只占 60px，文字列也被压到一半宽，
        // 次要信息（时间|备注|账户）被迫折成三四行，整页看起来"挤在一块"。
        // 改为：文字列 Expanded 独占剩余宽度；金额列不参与 flex，
        // 只用 LayoutBuilder 给它设上限（≤45% 行宽），超长时整体等比缩小。
        child: LayoutBuilder(builder: (context, constraints) {
          return Row(
            children: [
              // 选择模式下显示复选框，否则显示分类图标
              if (isSelectionMode)
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => onSelectionChanged?.call(),
                  activeColor: Theme.of(context).colorScheme.primary,
                )
              else
                // 分类图标，支持点击跳转（无背景）。
                // U2：视觉 22px 图标不变，命中热区扩到 48×48（Material 最小
                // 点按目标；列表最高频点击位）。图标中心右移 8px，尾部间隙
                // 12→4 保持图标-文字视觉间距不变。
                GestureDetector(
                  onTap: onCategoryTap,
                  behavior: HitTestBehavior.opaque,
                  child: SizedBox(
                    width: 48,
                    height: 48,
                    child: Center(
                      child: CategoryIconWidget(
                        category: category,
                        size: 22,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
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
                          // 全部账本模式：展示账本名标签（参考账户详情页）。
                          // Flexible + 单行省略：标签过长时截断而不是把标题
                          // 挤没 / 自己折成多行把行高撑爆。
                          if (ledgerName != null && ledgerName!.isNotEmpty) ...[
                            const SizedBox(width: 6),
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 6, vertical: 2),
                                decoration: BoxDecoration(
                                  color: ref
                                      .watch(primaryColorProvider)
                                      .withValues(alpha: 0.1),
                                  borderRadius: BorderRadius.circular(
                                      PiggyDimens.radiusXs),
                                ),
                                child: Text(
                                  ledgerName!,
                                  maxLines: 1,
                                  softWrap: false,
                                  overflow: TextOverflow.ellipsis,
                                  style:
                                      PiggyTextTokens.caption(context).copyWith(
                                    color: ref.watch(primaryColorProvider),
                                    fontWeight: FontWeight.w500,
                                  ),
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
              // 右侧：金额 + ≈折算小字。
              // 不参与 flex（见上方 UI-07 注释），宽度上限 45% 行宽；
              // 超长（亿级+折算行）时 FittedBox 整体等比缩小兜底，
              // 不会触发 RenderFlex overflow，也不必省略号截断金额数字。
              ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: constraints.maxWidth * 0.45,
                ),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerRight,
                  child: Column(
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
                          showCurrency: foreign,
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
                      if (foreign &&
                          nativeAmount != null &&
                          nativeAmount != amount &&
                          nativeConversionVisible(
                            hide: hide,
                            globalHide: ref.watch(hideAmountsProvider),
                          ))
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            '≈${nativeAmount!.toStringAsFixed(2)}',
                            style: PiggyTextTokens.caption(context),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      // v45 原始金额角标：仅手填且偏差达阈值才显示。
                      // 阈值/口径与 OriginalAmountInsightService 同源（20% 且 ≥1），
                      // 保证「列表能看到」与「洞察里能看到」是同一批明细；
                      // 隐藏金额开关同样遮蔽该角标（金额信息不得泄漏）。
                      if (showOriginalBadge)
                        Padding(
                          padding: const EdgeInsets.only(top: 2),
                          child: Text(
                            '${AppLocalizations.of(context).txOriginalAmountPrefix} '
                            '${originalSide.toStringAsFixed(2)}',
                            style: PiggyTextTokens.caption(context).copyWith(
                              fontSize: 10,
                              color: originalDiff >= 0
                                  ? PiggyTokens.expenseColor(context, ref)
                                  : PiggyTokens.incomeColor(context, ref),
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          );
        }),
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
          color: PiggyTokens.error(context),
          child: Icon(
            Icons.delete,
            color: PiggyTokens.textOnPrimary(context),
            size: 24,
          ),
        ),
        confirmDismiss: (direction) async {
          // 滑动到位触发确认时给一次中强度触感
          PiggyHaptics.medium();
          // 显示确认对话框（UI-01：走 l10n，避免英文环境弹中文）
          final l10n = AppLocalizations.of(context);
          return await AppDialog.confirm<bool>(
                context,
                title: l10n.deleteConfirmTitle,
                message: l10n.deleteConfirmMessage,
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
