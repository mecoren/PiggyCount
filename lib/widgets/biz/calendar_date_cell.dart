import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart' show HolidayEntry;
import '../../l10n/app_localizations.dart';
import '../../styles/tokens.dart';
import '../../utils/lunar/chinese_almanac.dart';

/// 日历视图的单个日期格（orbit 结构 + 小米日历风格）。
///
/// 日历页（`calendar_page.dart`）与区间选择器（`range_picker_sheet.dart`）
/// 共用同一份：节假日底色 / 休·班徽标 / 农历节气副标签的口径散在两处画两套，
/// 改一次必然漂移。
///
/// 布局三层：整格内缩底色块（Stack 底层）→ 数字 / 副标签 / 金额 → 右上角
/// 休·班徽标（`Positioned` 叠加，**不占布局高度**，也就不会挤压副标签）。
/// 内容整组垂直居中；副标签与金额整块套 `FittedBox(scaleDown)` 兜底系统
/// 大字号，保证 AC-A8「不出现 RenderFlex 溢出」。
class PiggyDateCell extends ConsumerWidget {
  const PiggyDateCell({
    super.key,
    required this.day,
    required this.primaryColor,
    this.holiday,
    this.totals,
    this.isSelected = false,
    this.isToday = false,
    this.isInRange = false,
    this.isOutside = false,
    this.isDisabled = false,
  });

  /// 该格日期（公历零点）。
  final DateTime day;

  /// 主题色：选中实心块 / 今天字色 / 区间中间日浅底。
  final Color primaryColor;

  /// 节假日本地缓存命中项；null = 普通日。[HolidayEntry.isHoliday] 为 false
  /// 时表示**调休补班**（周末要上班）。
  final HolidayEntry? holiday;

  /// 当日收支合计；为 null 则不画金额行（区间选择器、补位格都走 null）。
  final ({double income, double expense})? totals;

  /// 选中（实心主色）：日历页 = 单选日；区间选择器 = 区间两端。
  final bool isSelected;

  /// 今天（浅主色底 + 主色字）。
  final bool isToday;

  /// 落在已选区间中间（非两端）：浅主色底，让「一段范围」一眼可见。
  final bool isInRange;

  /// 补位格（上/下月溢出到本月的日期）：一律弱化。
  final bool isOutside;

  /// 越界日（早于 firstDay / 晚于 lastDay）：同补位格处理，且不带徽标。
  final bool isDisabled;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final totals = this.totals ?? (income: 0.0, expense: 0.0);
    final hasTransaction = totals.income > 0 || totals.expense > 0;

    // 补位格 / 越界日：不染周末色、不带徽标与金额
    final faded = isOutside || isDisabled;
    final isOffDay = !faded && (holiday?.isHoliday ?? false); // 法定放假（含调休假）
    // 调休补班（周末上班）
    final isWorkday = !faded && holiday != null && !holiday!.isHoliday;
    final isWeekend =
        day.weekday == DateTime.saturday || day.weekday == DateTime.sunday;

    final infoColor = PiggyTokens.info(context);
    final warningColor = PiggyTokens.warning(context);

    // 「休息日识别色」的判定口径：放假（含国庆落在工作日的那些天）与真正的
    // 周末都算；补班日虽然落在周六/周日但要上班，按工作日处理，不染蓝。
    final isRestDay = isOffDay || (isWeekend && !isWorkday);

    // 底色优先级（小米口径）：选中实心主色 > 今天浅主色底 > 区间浅主色底 >
    // 放假日浅底 > 补班压暗底 > 无底；选中块同时压过节假日识别底
    final Color? fillColor;
    if (isSelected) {
      fillColor = primaryColor;
    } else if (isToday) {
      fillColor = primaryColor.withValues(alpha: 0.12);
    } else if (isInRange) {
      fillColor = primaryColor.withValues(alpha: 0.10);
    } else if (isOffDay) {
      fillColor = infoColor.withValues(alpha: 0.10);
    } else if (isWorkday) {
      fillColor = warningColor.withValues(alpha: 0.07);
    } else {
      fillColor = null;
    }

    // 数字色（AC-A2/A5/A9）：补位/越界弱化 > 选中实心块白字 > 今天主色 >
    // 休息日识别色 > 常规色
    final Color numberColor;
    if (faded) {
      numberColor = PiggyTokens.textTertiary(context).withValues(alpha: 0.3);
    } else if (isSelected) {
      numberColor = Colors.white;
    } else if (isToday) {
      numberColor = primaryColor;
    } else if (isRestDay) {
      numberColor = infoColor;
    } else {
      numberColor = PiggyTokens.textPrimary(context);
    }

    // 选中格是实心主色，副标签 / 金额文字一律转白（AC-A6：不得用彩色，
    // 否则在主色底上对比度不足）；今天未选中只是浅底，金额保留语义色
    final onSolidColor = Colors.white.withValues(alpha: 0.9);

    // 副标签：公历节日 > 农历节日 > 节气 > 农历日（初一显示月名）。
    // 小米口径：补位格也弱显农历（与数字同灰阶），徽标 / 金额仍不渲染
    final subLabel = ChineseAlmanac.daySubLabel(day);

    // fit: StackFit.expand 不可省：table_calendar 会把 builder 产物再套一层
    // `Stack(fit: loose, alignment: markersAlignment)`（table_calendar.dart:695），
    // 松约束下本 Stack 会缩到「内容固有尺寸」——底色块随之塌成一条内容宽、
    // 整行高的窄胶囊，徽标也被挤到数字上。expand 让本 Stack 撑满整格
    // （单元格宽来自 Table 的 tight 宽度，高来自 rowHeight），底色块与徽标
    // 才回到「整格块 + 右上角」的设计口径。
    return Stack(
      fit: StackFit.expand,
      children: [
        // 底色层：整格内缩 1px 的圆角色块（与 orbit 的 inset 色块同口径）
        Positioned.fill(
          child: Container(
            margin: const EdgeInsets.all(1),
            decoration: BoxDecoration(
              color: fillColor,
              borderRadius: BorderRadius.circular(PiggyDimens.radiusLg),
            ),
          ),
        ),
        // 内容层
        Padding(
          padding: const EdgeInsets.fromLTRB(1, 3, 1, 2),
          child: Column(
            // 整组内容垂直居中(小米口径):数字 + 副标签 + 金额作为一组
            // 落在格子中线,选中实心块内不再出现「字挤在顶、底下大片空」
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(
                '${day.day}',
                style: TextStyle(
                  color: numberColor,
                  fontSize: 18,
                  fontWeight:
                      isSelected || isToday ? FontWeight.w700 : FontWeight.w600,
                  height: 1.0,
                ),
              ),
              // 副标签 + 收支金额:整块可等比缩小,宽/高任意一边超出都被兜住。
              // 用 Flexible(loose) 而非 Expanded —— Expanded 会把数字顶回格顶,
              // 破坏居中;loose 下内容取固有高度,超出的部分仍被钳住由
              // FittedBox 缩小,溢出兜底语义不变
              if (subLabel != null || (!faded && hasTransaction))
                Flexible(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.center,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (subLabel != null)
                          Text(
                            subLabel,
                            style: TextStyle(
                              color: isSelected
                                  ? onSolidColor
                                  : faded
                                      ? PiggyTokens.textTertiary(context)
                                          .withValues(alpha: 0.3)
                                      : PiggyTokens.textSecondary(context),
                              fontSize: 10,
                              height: 1.0,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        if (!faded && hasTransaction) ...[
                          if (totals.expense > 0)
                            Text(
                              _formatAmount(totals.expense, isExpense: true),
                              style: TextStyle(
                                color: isSelected
                                    ? onSolidColor
                                    : PiggyTokens.expenseColor(context, ref),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          if (totals.income > 0)
                            Text(
                              _formatAmount(totals.income, isExpense: false),
                              style: TextStyle(
                                color: isSelected
                                    ? onSolidColor
                                    : PiggyTokens.incomeColor(context, ref),
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                                height: 1.1,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                        ],
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        // 休 / 班徽标：绝对定位叠加在右上角（AC-A4），不进 Column 布局
        if (!faded && holiday != null)
          Positioned(
            top: 1,
            right: 1,
            child: _HolidayBadge(
              label: isOffDay ? l10n.holidayBadgeOff : l10n.holidayBadgeWork,
              color: isOffDay ? infoColor : warningColor,
            ),
          ),
      ],
    );
  }

  /// 金额缩写：>= 1万 用 w、>= 1千 用 k，支出带 `-`、收入带 `+`
  static String _formatAmount(double value, {required bool isExpense}) {
    final sign = isExpense ? '-' : '+';
    if (value >= 10000) return '$sign${(value / 10000).toStringAsFixed(1)}w';
    if (value >= 1000) return '$sign${(value / 1000).toStringAsFixed(1)}k';
    return '$sign${value.toInt()}';
  }
}

/// 右上角休·班圆徽标：14px 圆底、白字 9px（AC-A4）
class _HolidayBadge extends StatelessWidget {
  const _HolidayBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 14,
      height: 14,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle),
      child: Text(
        label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 9,
          fontWeight: FontWeight.w600,
          height: 1.0,
        ),
      ),
    );
  }
}
