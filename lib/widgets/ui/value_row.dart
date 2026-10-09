import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';

/// 分组小标题：给字段区里的一组行起个节名（「进度来源」「日期」…）。
///
/// 2026-10-09 从搜索筛选抽屉（`lib/widgets/biz/search_filter_sheet.dart`）抽出，
/// 与 [PiggyValueRow] / `PiggySegmentedControl` 一起构成表单字段的共用语言。
class PiggySectionLabel extends StatelessWidget {
  const PiggySectionLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: PiggyTextTokens.label(context).copyWith(
        fontWeight: FontWeight.w600,
        color: PiggyTokens.textSecondary(context),
      ),
    );
  }
}

/// 「图标 + 名称 + 当前值 + 尾部槽位」的一行：表单里挑一个值（账户 / 币种 /
/// 日期 / 分类 …）的统一形态，取代旧的两行堆叠 `ListTile`（标题 + 副标题）。
///
/// 版式约定（改动前先看这段，三处细节都是被踩过的坑）：
/// - **名称不参与 flex**：若包 `Flexible`，它会与值区各分一半剩余空间，而名称
///   用不完自己那份 —— 多出来的空间会被 `Row` 丢到末尾（start 对齐），尾部图标
///   就被推到行中间、贴不到最右。
/// - **值区独享 `Expanded` 并右对齐**：值永远右缘对齐到尾槽左侧，因此不同行的值
///   右缘是一条竖线。
/// - **尾部只有一个固定槽位（32）**：`onClear` 非空 = 该槽位是清除键（警示色
///   `error`，语义是「移除」）；否则 `onTap` 非空 = 箭头；都没有（纯展示行）也
///   保留空槽，免得值右缘与其它行错位。
///
/// [valueWidget] 用于值需要自绘的场景（如走 `AmountText` 以跟随「隐藏金额」
/// 开关）；给定时优先于 [value]。
class PiggyValueRow extends StatelessWidget {
  const PiggyValueRow({
    super.key,
    required this.label,
    this.icon,
    this.value,
    this.placeholder = '',
    this.valueWidget,
    this.onTap,
    this.onClear,
    this.trailingCaption,
  });

  /// 行名（左侧）。
  final String label;

  /// 行首图标；null = 不画图标（也不留占位）。
  final IconData? icon;

  /// 当前值；null = 未设置，显示 [placeholder]。
  final String? value;

  /// 未设置时的占位文案（由调用方给，避免本组件绑死某个 l10n key）。
  final String placeholder;

  /// 值区自绘（优先于 [value]）。
  final Widget? valueWidget;

  /// 点击整行；null = 不可点（纯展示 / 只读行，不显示箭头）。
  final VoidCallback? onTap;

  /// 就地清除本行的值；null = 无值可清（不显示清除键）。
  ///
  /// 注意它**取代**箭头而不是与箭头并排：并排会白白吃掉一段宽度，把长值挤到
  /// 贴着图标（原实现踩过）。清除后行本身仍可点（继续改选别的值）。
  final VoidCallback? onClear;

  /// 行尾说明小字（如「跟随关联账户」）：用于「值被别处决定、本行只读」的场景。
  final String? trailingCaption;

  @override
  Widget build(BuildContext context) {
    final primaryColor = PiggyTokens.primary(context);
    final hasValue = valueWidget != null || value != null;

    return Material(
      color: PiggyTokens.surfaceSecondary(context),
      borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: PiggyDimens.p12,
            vertical: 12,
          ),
          child: Row(
            children: [
              if (icon != null) ...[
                Icon(icon, size: 20, color: PiggyTokens.iconSecondary(context)),
                const SizedBox(width: PiggyDimens.p12),
              ],
              Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: PiggyTextTokens.body(context)
                    .copyWith(color: PiggyTokens.textSecondary(context)),
              ),
              const SizedBox(width: PiggyDimens.p8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: valueWidget ??
                      Text(
                        hasValue ? value! : placeholder,
                        textAlign: TextAlign.right,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: PiggyTextTokens.body(context).copyWith(
                          color: hasValue
                              ? primaryColor
                              : PiggyTokens.textTertiary(context),
                          fontWeight:
                              hasValue ? FontWeight.w600 : FontWeight.w400,
                        ),
                      ),
                ),
              ),
              _buildTail(context, hasValue),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTail(BuildContext context, bool hasValue) {
    if (hasValue && onClear != null) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Semantics(
          button: true,
          label: AppLocalizations.of(context).tooltipClear,
          child: InkResponse(
            onTap: onClear,
            radius: 20,
            child: Align(
              alignment: Alignment.centerRight,
              child: Icon(
                Icons.close,
                size: 20,
                color: PiggyTokens.error(context),
              ),
            ),
          ),
        ),
      );
    }
    if (trailingCaption != null) {
      return Padding(
        padding: const EdgeInsets.only(left: PiggyDimens.p8),
        child: Text(trailingCaption!, style: PiggyTextTokens.caption(context)),
      );
    }
    if (onTap != null) {
      return SizedBox(
        width: 32,
        height: 32,
        child: Align(
          alignment: Alignment.centerRight,
          child: Icon(
            Icons.chevron_right,
            size: 20,
            color: PiggyTokens.iconTertiary(context),
          ),
        ),
      );
    }
    // 纯展示行：留同样的槽位宽度，值右缘才与可点行对齐。
    return const SizedBox(width: 32, height: 32);
  }
}
