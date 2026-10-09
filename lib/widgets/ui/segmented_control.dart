import 'package:flutter/material.dart';

import '../../styles/tokens.dart';

/// 分段控件的一个选项。
class PiggySegmentOption<T> {
  const PiggySegmentOption({required this.value, required this.label});

  final T value;
  final String label;
}

/// 等宽分段控件：2~3 个互斥选项并排，选中项 = 主色描边 + 12% 主色底。
///
/// 为什么不用 `ChoiceChip`：Chip 自带留白且各自成块，两三个并排就会显得零碎，
/// 高度也与行式字段对不齐；分段控件（同「自定义字段类型」选择器）与 [PiggyValueRow]
/// 同一套圆角与高度语言，抽屉里看起来是一整块。
///
/// 2026-10-09 从搜索筛选抽屉（附件维度）抽出，储蓄目标表单的「进度来源」复用。
class PiggySegmentedControl<T> extends StatelessWidget {
  const PiggySegmentedControl({
    super.key,
    required this.options,
    required this.selected,
    required this.onChanged,
  });

  final List<PiggySegmentOption<T>> options;

  /// 当前选中值；不在 [options] 里（含 null）= 全部未选中。
  final T? selected;

  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final primaryColor = PiggyTokens.primary(context);

    return Row(
      children: [
        for (var i = 0; i < options.length; i++) ...[
          if (i > 0) const SizedBox(width: PiggyDimens.p8),
          Expanded(
            child: _PiggySegment(
              label: options[i].label,
              selected: selected == options[i].value,
              primaryColor: primaryColor,
              onTap: () => onChanged(options[i].value),
            ),
          ),
        ],
      ],
    );
  }
}

class _PiggySegment extends StatelessWidget {
  const _PiggySegment({
    required this.label,
    required this.selected,
    required this.primaryColor,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final Color primaryColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        height: 40,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? primaryColor.withValues(alpha: 0.12) : null,
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          border: Border.all(
            color: selected ? primaryColor : PiggyTokens.border(context),
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: PiggyTextTokens.fs13,
            fontWeight: FontWeight.w600,
            color:
                selected ? primaryColor : PiggyTokens.textSecondary(context),
          ),
        ),
      ),
    );
  }
}
