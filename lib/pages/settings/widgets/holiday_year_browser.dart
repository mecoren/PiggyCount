import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../../data/db.dart';
import '../../../l10n/app_localizations.dart';
import '../../../providers.dart';
import '../../../services/calendar/holiday_service.dart';
import '../../../styles/tokens.dart';
import '../../../widgets/biz/biz.dart';
import '../../../widgets/ui/ui.dart';

/// 节假日年份分页浏览（prd/calendar_holiday design.md §5，2026-09-29 修订）。
///
/// 单滚动视图结构（CustomScrollView）：[headerCards]（概览 / 更新设置卡）
/// 随滚动收起，年份导航行 **pin** 在收起后的顶端，年份条目为同一滚动
/// 视图的尾部 Sliver（修「下面显示不全」：不用 NestedScrollView +
/// PageView 内嵌 ListView，避免内层手势吃掉外层滚动导致顶部卡片
/// 收不起来、年份区只剩半屏）。
///
/// 交互与日历页月份翻页同口径：年份区横滑翻年 + 左右箭头 + 头部年份
/// 滚轮跳转 + 「刷新该年」（对应当前展示年份）。
class HolidayYearBrowser extends ConsumerStatefulWidget {
  const HolidayYearBrowser({
    super.key,
    required this.headerCards,
    required this.listAsync,
    required this.busy,
    required this.fetchingYear,
    required this.onFetchYear,
  });

  /// 顶部前导区（概览卡 + 更新设置卡），随外层滚动收起。
  final Widget headerCards;

  /// 全部缓存行（含预置兜底合并视图），按年份过滤后分页展示。
  final AsyncValue<List<HolidayEntry>> listAsync;

  /// 任一网络写操作进行中（禁用「刷新该年」）。
  final bool busy;

  /// 正在按年补写的年份（该年按钮显示 spinner）。
  final int? fetchingYear;

  /// 「刷新该年」回调（页面侧持有 Service 调用与 toast）。
  final Future<void> Function(int year) onFetchYear;

  @override
  ConsumerState<HolidayYearBrowser> createState() => _HolidayYearBrowserState();
}

class _HolidayYearBrowserState extends ConsumerState<HolidayYearBrowser> {
  /// 当前展示年份（边界与补写口径同源：2000 ~ 明年）。
  late int _displayYear;

  @override
  void initState() {
    super.initState();
    _displayYear = DateTime.now().year;
  }

  @override
  Widget build(BuildContext context) {
    // 整页单一纵向滚动：顶部卡片可上滚收起，年份导航 pin 住，
    // 年份条目跟在后面。横滑手势翻年（与日历页月份翻页同口径）。
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        // 左滑（velocity < 0）看下一年，右滑看上一年；阈值防误触。
        if (velocity < -200) {
          _switchYear(1);
        } else if (velocity > 200) {
          _switchYear(-1);
        }
      },
      child: CustomScrollView(
        slivers: [
          SliverToBoxAdapter(child: widget.headerCards),
          SliverPersistentHeader(
            pinned: true,
            delegate: _YearHeaderDelegate(
              height: 52,
              child: _buildYearHeader(context),
            ),
          ),
          _buildYearSlivers(context),
        ],
      ),
    );
  }

  /// 年份导航行（对齐日历页头部）：左右箭头翻年 + 居中年份（点开年滚轮跳转）
  /// + 右侧「刷新该年」（对应当前展示年份，AC-E3 入口随分页化移到这里）。
  Widget _buildYearHeader(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final primaryColor = ref.watch(primaryColorProvider);
    final now = DateTime.now();
    final canPrev = _displayYear > HolidayService.yearMin;
    final canNext = _displayYear < HolidayService.yearMax(now);
    return Container(
      color: PiggyTokens.scaffoldBackground(context),
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 4),
      child: Row(
        children: [
          IconButton(
            onPressed: canPrev ? () => _switchYear(-1) : null,
            icon: Icon(Icons.chevron_left, color: primaryColor),
          ),
          Expanded(
            child: InkWell(
              onTap: _pickYear,
              borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Flexible(
                      child: Text(
                        DateFormat.y(Localizations.localeOf(context).toString())
                            .format(DateTime(_displayYear)),
                        style: PiggyTextTokens.strongTitle(context),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Icon(Icons.arrow_drop_down,
                        size: 20, color: PiggyTokens.textPrimary(context)),
                  ],
                ),
              ),
            ),
          ),
          IconButton(
            onPressed: canNext ? () => _switchYear(1) : null,
            icon: Icon(Icons.chevron_right, color: primaryColor),
          ),
          _buildYearRefreshButton(context, l10n, primaryColor),
        ],
      ),
    );
  }

  /// 「刷新该年」：就地重新拉取**当前展示**年份（AC-E3）。
  Widget _buildYearRefreshButton(
      BuildContext context, AppLocalizations l10n, Color primaryColor) {
    final busy = widget.fetchingYear == _displayYear;
    return IconButton(
      onPressed: widget.busy ? null : () => widget.onFetchYear(_displayYear),
      tooltip: l10n.holidayUpdateYear,
      icon: busy
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : Icon(
              Icons.refresh,
              color: widget.busy
                  ? PiggyTokens.iconSecondary(context)
                  : primaryColor,
            ),
    );
  }

  /// 当前展示年份的条目 Sliver：与外层同一滚动视图，年份区不再被压扁。
  Widget _buildYearSlivers(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return widget.listAsync.when(
      skipLoadingOnReload: true,
      data: (rows) {
        final yearRows = rows.where((r) => r.year == _displayYear).toList();
        if (yearRows.isEmpty) {
          return SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Center(
                child: Text(l10n.holidayYearNoData(_displayYear),
                    style: PiggyTextTokens.label(context),
                    textAlign: TextAlign.center),
              ),
            ),
          );
        }
        return SliverPadding(
          padding: EdgeInsets.fromLTRB(
            16,
            4,
            16,
            16 + MediaQuery.of(context).padding.bottom,
          ),
          sliver: SliverToBoxAdapter(
            child: SettingsCard(
              children: [
                for (final r in yearRows) _buildEntryRow(context, l10n, r),
              ],
            ),
          ),
        );
      },
      loading: () => const SliverToBoxAdapter(
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          ),
        ),
      ),
      error: (_, __) => SliverToBoxAdapter(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Center(
            child: Text(l10n.holidayLoadFailed,
                style: PiggyTextTokens.label(context)
                    .copyWith(color: PiggyTokens.error(context)),
                textAlign: TextAlign.center),
          ),
        ),
      ),
    );
  }

  Widget _buildEntryRow(
      BuildContext context, AppLocalizations l10n, HolidayEntry entry) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          HolidayBadge(isHoliday: entry.isHoliday),
          const SizedBox(width: 12),
          Text(
            entry.date.length == 10 ? entry.date.substring(5) : entry.date,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w500),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              entry.name,
              style: PiggyTextTokens.label(context),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  /// 箭头翻年（±1），直接切换展示年份（单滚动视图内原地换内容）。
  void _switchYear(int offset) {
    final target = _displayYear + offset;
    if (target < HolidayService.yearMin ||
        target > HolidayService.yearMax(DateTime.now())) {
      return;
    }
    setState(() => _displayYear = target);
  }

  /// 头部年份点开年滚轮跳转（与日历页「年月 ▾」同范式，边界 2000 ~ 明年）。
  Future<void> _pickYear() async {
    final now = DateTime.now();
    final picked = await showWheelDatePicker(
      context,
      initial: DateTime(_displayYear),
      mode: WheelDatePickerMode.y,
      minDate: DateTime(HolidayService.yearMin),
      maxDate: DateTime(HolidayService.yearMax(now), 12, 31),
    );
    if (picked == null || !mounted) return;
    setState(() => _displayYear = picked.year);
  }
}

/// 钉住的年份导航行（固定高度，内容整体随页面重建刷新）。
class _YearHeaderDelegate extends SliverPersistentHeaderDelegate {
  _YearHeaderDelegate({required this.child, required this.height});

  final Widget child;
  final double height;

  @override
  Widget build(
          BuildContext context, double shrinkOffset, bool overlapsContent) =>
      child;

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _YearHeaderDelegate oldDelegate) => true;
}

/// 休 / 班 徽标（设置页列表用）：放假 = 主色系 info 色，补班 = 警示橙。
///
/// 与日历日格徽标同源配色（design.md §3），两处均取语义 token，
/// 不新增裸色值，暗黑自动切换。
class HolidayBadge extends StatelessWidget {
  const HolidayBadge({super.key, required this.isHoliday});

  final bool isHoliday;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final color =
        isHoliday ? PiggyTokens.info(context) : PiggyTokens.warning(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(PiggyDimens.radiusSm),
      ),
      child: Text(
        isHoliday ? l10n.holidayBadgeOff : l10n.holidayBadgeWork,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
        maxLines: 1,
      ),
    );
  }
}
