import 'package:flutter/material.dart';

import '../../styles/tokens.dart';
import '../ui/ui.dart';

/// 1~N 日网格选择抽屉（账本「月起始日」/ 账户「账单日 / 还款日」共用）。
///
/// 外壳走 [PiggyPickerSheet]；点选即应用并收起，没有待提交的选中态，
/// 故顶栏只留 X + 标题（无钩子）。
Future<int?> showDayOfMonthPickerSheet(
  BuildContext context, {
  required String title,

  /// 标题下的副说明（如账本页的「选择每月哪一天作为账本起始」），可空。
  String? hint,

  /// 当前已选日期（1~[count]），无选中传 null。
  int? selected,

  /// 可选日期上限（账本月起始日与账单日均为 28，避免月末不存在的日期）。
  int count = 28,
}) {
  final primary = PiggyTokens.primary(context);
  return showPiggyPickerSheet<int>(
    context,
    builder: (_) => PiggyPickerSheet(
      title: title,
      subtitle: hint,
      maxHeight: 320,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p16),
        // Wrap 而非 GridView：格子数固定且要按卡片宽度自然折行，
        // 用 GridView 在宽屏下会被拉伸、在窄屏下需要额外约束。
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (var day = 1; day <= count; day++)
              _DayCell(
                day: day,
                isSelected: day == selected,
                primary: primary,
                onTap: () => Navigator.pop(context, day),
              ),
          ],
        ),
      ),
    ),
  );
}

/// 单个日期格：44×44 满足最小点按目标；选中用主色淡底 + 主色描边 + 主色字。
class _DayCell extends StatelessWidget {
  const _DayCell({
    required this.day,
    required this.isSelected,
    required this.primary,
    required this.onTap,
  });

  final int day;
  final bool isSelected;
  final Color primary;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      child: Container(
        width: 44,
        height: 44,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
          color: isSelected ? primary.withValues(alpha: 0.12) : null,
          border: Border.all(
            color: isSelected ? primary : PiggyTokens.border(context),
          ),
        ),
        child: Text(
          '$day',
          style: PiggyTextTokens.body(context).copyWith(
            color: isSelected ? primary : PiggyTokens.textPrimary(context),
            fontWeight: isSelected ? FontWeight.w600 : null,
          ),
        ),
      ),
    );
  }
}
