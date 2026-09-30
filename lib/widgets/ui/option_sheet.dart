import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// [showPiggyOptionSheet] 的单个选项条目。
///
/// [value] 为选中后回调给调用方的值；前置标识 [icon]（图标）与 [badge]
/// （原生字符徽标，如语言选择的 中/繁/EN/한）必须二选一；[desc] 为标题
/// 下方的说明副文案，可空。
class PiggyOptionSheetItem<T> {
  const PiggyOptionSheetItem({
    required this.value,
    required this.title,
    this.desc,
    this.icon,
    this.badge,
  }) : assert(
          (icon == null) != (badge == null),
          'icon 与 badge 必须二选一作为前置标识',
        );

  final T value;
  final String title;
  final String? desc;
  final IconData? icon;
  final String? badge;
}

/// 悬浮卡片式底部抽屉单选（规范见 AGENTS.md「少选项单选弹窗」）：
/// 透明弹层底 + 四周留距（左右/底部 p16）+ Material 四角圆角卡片 +
/// 小号居中灰标题 +「前置标识 + 标题/说明 + 选中勾」行，不放分割线。
///
/// 选中即收起并回调 [onSelected]，由调用方负责应用（无确认按钮）。
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
  return showModalBottomSheet<void>(
    context: context,
    // 卡片由 builder 内的 Material 自绘（四角圆角 + 四周留间距），
    // 弹层底本身透明。
    backgroundColor: Colors.transparent,
    builder: (ctx) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            PiggyDimens.p16,
            0,
            PiggyDimens.p16,
            PiggyDimens.p16,
          ),
          // 透明路由底不提供 Material 祖先，InkWell 必须显式包 Material。
          child: Material(
            color: PiggyTokens.surfaceElevated(ctx),
            borderRadius: BorderRadius.circular(PiggyDimens.radiusXl),
            clipBehavior: Clip.antiAlias,
            // 标题 + 选项在系统大字号 / 显示缩放下可能超出卡片高度，
            // 包一层可滚动容器兜底（放不下时滚动而非溢出红条）。
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // 标题区：小号居中、次级色。
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      PiggyDimens.p16,
                      PiggyDimens.p16,
                      PiggyDimens.p16,
                      PiggyDimens.p12,
                    ),
                    child: Text(
                      title,
                      textAlign: TextAlign.center,
                      style: Theme.of(ctx).textTheme.labelLarge?.copyWith(
                            color: PiggyTokens.textSecondary(ctx),
                          ),
                    ),
                  ),
                  // 行结构：前置裸标识 + 标题/说明 + 选中勾；
                  // 高亮只给选中项，未选中行一律中性色。
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
        ),
      );
    },
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
            // 槽位居中，保证各选项标题起点同一条竖线。
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
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                            color: isSelected
                                ? primaryColor
                                : PiggyTokens.iconSecondary(context),
                          ),
                    ),
            ),
            const SizedBox(width: 12),
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
            if (isSelected)
              Icon(Icons.check, size: 24, color: primaryColor),
          ],
        ),
      ),
    );
  }
}
