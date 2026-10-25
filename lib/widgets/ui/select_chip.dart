import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import 'segmented_control.dart';

/// 可点选芯片（多选筛选条件 / 自定义字段的单选、多选选项）。
///
/// 与 [PiggySegmentedControl] 的一段、账户选择器的横滑芯片**同源**：装饰走
/// [piggySelectableDecoration]（选中 = 主色描边 1.5 + 12% 主色底；未选 = 中性
/// 描边 1 + 无填充），文字色走 [piggySelectableTextColor]，字号 / 字重同为
/// fs13 / w600 —— 三者并排时不出现第二套视觉语言。
///
/// 为什么不用 Material 的 `FilterChip` / `ChoiceChip`：它们吃 M3 主题默认值
/// （自带高度、留白、选中底、勾选图标与字号），既不读 `PiggyTokens` 也不随
/// 个性化主色 / 暗色模式走。洞察筛选抽屉曾因此和同一个抽屉里的 `PiggyValueRow`、
/// `PiggySegmentedControl` 明显不是一套东西。
///
/// 用法：外面套 `Wrap`（`spacing` / `runSpacing` 取 `PiggyDimens.p8`）即可；
/// 单选语义由调用方在 [onTap] 里清掉其它项，本组件只负责一格的外观与点击。
class PiggySelectChip extends StatelessWidget {
  const PiggySelectChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        // 与分段控件同高（40）而非 Chip 的 ~32：抽屉里两种「选格」对齐同一基线。
        constraints: const BoxConstraints(minHeight: 40),
        alignment: Alignment.center,
        padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p12),
        decoration: piggySelectableDecoration(context, selected: selected),
        child: Text(
          label,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs13,
            fontWeight: FontWeight.w600,
            color: piggySelectableTextColor(context, selected: selected),
          ),
        ),
      ),
    );
  }
}
