import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'picker_sheet.dart';

/// [showPiggyOptionSheet] 的单个选项条目。
///
/// [value] 为选中后回调给调用方的值；前置标识 [icon]（图标）或 [badge]
/// （原生字符徽标，如语言选择的 中/繁/EN/한）二选一，两者都为空时不占
/// 前置槽位；[desc] 为标题下方的说明副文案，可空。
class PiggyOptionSheetItem<T> {
  const PiggyOptionSheetItem({
    required this.value,
    required this.title,
    this.desc,
    this.icon,
    this.badge,
  }) : assert(
          icon == null || badge == null,
          'icon 与 badge 不能同时传（前置标识至多一个）',
        );

  final T value;
  final String title;
  final String? desc;
  final IconData? icon;
  final String? badge;
}

/// 悬浮卡片式底部抽屉单选（规范见 AGENTS.md「选择器抽屉统一口径」）：
/// 统一走 [PiggyPickerSheet]——悬浮卡片 + 顶栏 取消(X)/标题，
/// 行结构为「前置标识 + 标题/说明 + 选中勾」，不放分割线。
///
/// 选中即收起并回调 [onSelected]，由调用方负责应用，故不设确认钩子
/// （顶栏只留 X + 标题）。
/// [selected] 传当前值用于高亮；[highlightColor] 缺省取主题 primary。
Future<void> showPiggyOptionSheet<T>({
  required BuildContext context,
  required String title,
  required List<PiggyOptionSheetItem<T>> options,
  required ValueChanged<T> onSelected,
  T? selected,
  Color? highlightColor,
}) {
  final primary = highlightColor ?? PiggyTokens.primary(context);
  return showPiggyPickerSheet<void>(
    context,
    builder: (ctx) => PiggyPickerSheet(
      title: title,
      // 选项在系统大字号 / 显示缩放下可能超出卡片高度，
      // 用高度上限 + 内部滚动兜底（放不下时滚动而非溢出红条）。
      maxHeight: MediaQuery.sizeOf(ctx).height * 0.7,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // 行结构：前置裸标识 + 标题/说明 + 选中勾；
          // 高亮只给选中项，未选中行一律中性色。
          children: [
            for (final opt in options)
              _OptionRow(
                option: opt,
                isSelected: opt.value == selected,
                primaryColor: primary,
                onTap: () {
                  Navigator.pop(ctx);
                  onSelected(opt.value);
                },
              ),
          ],
        ),
      ),
    ),
  );
}

class _OptionRow<T> extends StatelessWidget {
  const _OptionRow({
    required this.option,
    required this.isSelected,
    required this.primaryColor,
    required this.onTap,
  });

  final PiggyOptionSheetItem<T> option;
  final bool isSelected;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final option = this.option;
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(
            horizontal: PiggyDimens.p16, vertical: 14),
        child: Row(
          children: [
            // 前置标识：裸图标 / 原生字符徽标，无背景盒，统一占 24px
            // 槽位居中，保证各选项标题起点同一条竖线；两者都不传时
            // （纯文字选项，如应用锁超时）不占槽位。
            if (option.icon != null || option.badge != null) ...[
              SizedBox(
                width: 24,
                child: option.icon != null
                    ? Icon(
                        option.icon,
                        size: 24,
                        color: isSelected
                            ? primaryColor
                            : PiggyTokens.iconSecondary(context),
                      )
                    : Text(
                        option.badge!,
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                  color: isSelected
                                      ? primaryColor
                                      : PiggyTokens.iconSecondary(context),
                                ),
                      ),
              ),
              const SizedBox(width: 12),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.title,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight:
                              isSelected ? FontWeight.w600 : FontWeight.w500,
                          color: isSelected
                              ? primaryColor
                              : PiggyTokens.textPrimary(context),
                        ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (option.desc != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      option.desc!,
                      // 说明副文案不随选中变色，保持次级色。
                      style: PiggyTextTokens.label(context),
                    ),
                  ],
                ],
              ),
            ),
            if (isSelected) Icon(Icons.check, size: 24, color: primaryColor),
          ],
        ),
      ),
    );
  }
}
