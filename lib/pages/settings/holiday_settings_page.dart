import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../services/calendar/holiday_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/biz.dart';
import '../../widgets/ui/ui.dart';
import 'widgets/holiday_year_browser.dart';
import 'widgets/holiday_year_range_picker.dart';

/// 「日历与节假日」设置页（prd/calendar_holiday design.md §5）。
///
/// 缓存概览 + 立即更新 + 每月自动更新开关 + 按年份范围获取（双年滚轮抽屉）；
/// 年份条目由 [HolidayYearBrowser] 分页浏览：一页一年、横滑翻年，顶部卡片
/// 可上滚收起以最大化年份可视区（2026-09-29 修订）。
/// 全部写操作经 [HolidayService] → Repository。
class HolidaySettingsPage extends ConsumerStatefulWidget {
  const HolidaySettingsPage({super.key});

  @override
  ConsumerState<HolidaySettingsPage> createState() =>
      _HolidaySettingsPageState();
}

class _HolidaySettingsPageState extends ConsumerState<HolidaySettingsPage> {
  bool _updating = false;

  /// 正在按年补写的年份（null = 空闲）。用于禁用按钮 + 该年行内显示 spinner。
  int? _fetchingYear;

  /// 正在按年份范围补写。
  bool _fetchingRange = false;

  /// 任一网络写操作进行中：三处入口共用一个闸门，避免 meta 记账交叉覆盖。
  bool get _busy => _updating || _fetchingYear != null || _fetchingRange;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final listAsync = ref.watch(holidayListProvider);
    final metaAsync = ref.watch(holidayMetaProvider);
    final meta = metaAsync.valueOrNull;

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(title: l10n.holidaySettingsTitle, showBack: true),
      body: HolidayYearBrowser(
        listAsync: listAsync,
        busy: _busy,
        fetchingYear: _fetchingYear,
        onFetchYear: _fetchYear,
        headerCards: Padding(
          padding: EdgeInsets.fromLTRB(
            16,
            PiggyTokens.topScrollablePadding(context) + 8,
            16,
            4,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SettingsSectionLabel(l10n.holidayCacheOverview),
              const SizedBox(height: 8),
              SettingsCard(
                children: [
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: listAsync.when(
                      data: (rows) => _buildOverview(context, l10n, rows, meta),
                      loading: () => Text(
                        l10n.holidayCacheOverview,
                        style: PiggyTextTokens.label(context),
                      ),
                      error: (_, __) => Text(
                        l10n.holidayLoadFailed,
                        style: PiggyTextTokens.label(context)
                            .copyWith(color: PiggyTokens.error(context)),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── 更新设置 ──
              SettingsCard(
                children: [
                  // 立即更新
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                    child: SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _busy ? null : () => _updateNow(l10n),
                        icon: _updating
                            ? const SizedBox(
                                width: 16,
                                height: 16,
                                child:
                                    CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.refresh, size: 20),
                        label: Text(_updating
                            ? l10n.holidayUpdating
                            : l10n.holidayUpdateNow),
                      ),
                    ),
                  ),
                  // 每月自动更新
                  SettingsToggleItem(
                    icon: Icons.update_outlined,
                    title: l10n.holidayAutoUpdate,
                    subtitle: l10n.holidayAutoUpdateDesc,
                    value: meta?.autoEnabled ?? true,
                    onChanged: (value) => _setAutoEnabled(value),
                  ),
                  // 按年份范围获取（历史年份补写入口，AC-E2 2026-09-29 修订）
                  SettingsNavItem(
                    icon: Icons.event_available_outlined,
                    title: l10n.holidayFetchByYear,
                    subtitle: l10n.holidayFetchByYearDesc,
                    onTap: _busy ? null : _pickYearRange,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 概览文本：条数 / 覆盖年份 / 上次成功 / 连续失败（>0 才显示）。
  Widget _buildOverview(BuildContext context, AppLocalizations l10n,
      List<HolidayEntry> rows, HolidayUpdateMetaData? meta) {
    final off = rows.where((r) => r.isHoliday).length;
    final work = rows.length - off;
    final years = rows.map((r) => r.year).toSet().toList()..sort();
    final range = years.isEmpty
        ? '-'
        : (years.length == 1
            ? '${years.first}'
            : '${years.first}–${years.last}');
    final lastUpdate = (meta == null || meta.lastUpdateMs <= 0)
        ? l10n.holidayNeverUpdated
        : l10n.holidayLastUpdate(_formatDateTime(meta.lastUpdateMs));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(l10n.holidayCacheCount(rows.length, off, work),
            style: PiggyTextTokens.body(context)),
        const SizedBox(height: 6),
        Text(l10n.holidayCoverYears(range),
            style: PiggyTextTokens.label(context)),
        const SizedBox(height: 4),
        Text(lastUpdate, style: PiggyTextTokens.label(context)),
        if (meta != null && meta.failureCount > 0) ...[
          const SizedBox(height: 4),
          Text(
            l10n.holidayFailureCount(meta.failureCount),
            style: PiggyTextTokens.label(context)
                .copyWith(color: PiggyTokens.error(context)),
          ),
        ],
      ],
    );
  }

  /// 「按年份范围获取」：双年滚轮选起止年份 → 逐年联网补写（AC-E2 修订）。
  Future<void> _pickYearRange() async {
    final now = DateTime.now();
    final range = await showHolidayYearRangePicker(
      context,
      minYear: HolidayService.yearMin,
      maxYear: HolidayService.yearMax(now),
    );
    if (range == null || !mounted) return;
    await _fetchYearRange(range.startYear, range.endYear);
  }

  /// 按范围逐年补写：并发拉取 + 进度弹窗 + 可取消；单年失败跳过不中止，
  /// 连续传输失败熔断（见 [HolidayService.fetchYearRange]）；收尾 toast
  /// 汇总成功 / 无数据 / 失败，全失败时报具体原因便于排查。
  /// 已成功年份保留（Service 口径）；单年范围退化用单年文案。
  Future<void> _fetchYearRange(int start, int end) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    setState(() => _fetchingRange = true);
    final total = end - start + 1;
    final done = ValueNotifier<int>(0);
    var cancelled = false;
    var dialogOpen = false;
    // 进度弹窗：取消只置旗，弹窗由收尾统一关闭（任务仍在后台跑，
    // 野指针风险由 mounted 守卫）。
    if (mounted) {
      dialogOpen = true;
      unawaited(
        showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (dialogContext) => AppDialogShell(
            title: Text(l10n.holidayFetchByYear),
            content: ValueListenableBuilder<int>(
              valueListenable: done,
              builder: (_, v, __) => Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  LinearProgressIndicator(value: total <= 0 ? null : v / total),
                  const SizedBox(height: 12),
                  Text('$v / $total', textAlign: TextAlign.center),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => cancelled = true,
                child: Text(l10n.commonCancel),
              ),
            ],
          ),
        ).whenComplete(() => dialogOpen = false),
      );
    }
    try {
      final result = await ref.read(holidayServiceProvider).fetchYearRange(
            start,
            end,
            onProgress: (d, _) => done.value = d,
            shouldCancel: () => cancelled,
          );
      if (!mounted) return;
      ref.invalidate(holidayListProvider);
      ref.invalidate(holidayMetaProvider);
      if (result.cancelled &&
          result.updated == 0 &&
          result.noData == 0 &&
          result.failedYears.isEmpty) {
        return; // 取消且颗粒无收：静默
      }
      if (result.failedYears.isNotEmpty &&
          result.updated == 0 &&
          result.noData == 0) {
        // 全失败（含熔断）：报原因而不是只报个数，否则用户无从排查
        // （如断网时此前只显示「0 个成功、N 个失败」）。
        final cause = result.firstError;
        showToast(
          context,
          cause == null
              ? l10n.holidayFetchRangePartial(0, result.failedYears.length)
              : l10n.holidayFetchYearFailed(HolidayService.shortError(cause)),
        );
      } else if (result.failedYears.isNotEmpty) {
        // 单年失败已跳过不中止：汇总「成功 N + 失败 M」即可
        showToast(
            context,
            l10n.holidayFetchRangePartial(
                result.updated, result.failedYears.length));
      } else if (start == end) {
        showToast(
          context,
          result.noData == 1
              ? l10n.holidayYearNoData(start)
              : l10n.holidayFetchYearDone(start),
        );
      } else if (result.noData == 0) {
        showToast(context, l10n.holidayFetchRangeDone(result.updated));
      } else {
        showToast(context,
            l10n.holidayFetchRangeDoneNoData(result.updated, result.noData));
      }
    } finally {
      if (mounted) setState(() => _fetchingRange = false);
      if (dialogOpen && mounted) {
        Navigator.of(context).pop();
      }
      done.dispose();
    }
  }

  /// 按年补写缓存（年份导航「刷新该年」入口）：`rowCount == 0` 表示该年线上
  /// 无数据，按成功处理但提示「该年无数据」（AC-E7）。
  Future<void> _fetchYear(int year) async {
    final l10n = AppLocalizations.of(context);
    if (_busy) return;
    setState(() => _fetchingYear = year);
    try {
      final result = await ref.read(holidayServiceProvider).fetchYear(year);
      if (!mounted) return;
      ref.invalidate(holidayListProvider);
      ref.invalidate(holidayMetaProvider);
      showToast(
        context,
        result.rowCount == 0
            ? l10n.holidayYearNoData(year)
            : l10n.holidayFetchYearDone(year),
      );
    } catch (e) {
      if (!mounted) return;
      showToast(context, l10n.holidayFetchYearFailed(_shortError(e)));
    } finally {
      if (mounted) setState(() => _fetchingYear = null);
    }
  }

  Future<void> _updateNow(AppLocalizations l10n) async {
    if (_busy) return;
    setState(() => _updating = true);
    try {
      await ref.read(holidayServiceProvider).updateNow();
      if (!mounted) return;
      ref.invalidate(holidayListProvider);
      ref.invalidate(holidayMetaProvider);
      showToast(context, l10n.holidayUpdateSuccess);
    } catch (e) {
      if (!mounted) return;
      showToast(context, l10n.holidayUpdateFailed(_shortError(e)));
    } finally {
      if (mounted) setState(() => _updating = false);
    }
  }

  /// 提示文案里的错误占位：DioException 的 toString 过长（含请求细节），
  /// 只取异常类型名，保证 toast 一行可读。
  String _shortError(Object e) =>
      e is HolidayFetchException ? e.message : e.runtimeType.toString();

  Future<void> _setAutoEnabled(bool value) async {
    await ref.read(holidayServiceProvider).setAutoEnabled(value);
    ref.invalidate(holidayMetaProvider);
  }

  /// epoch ms → 'yyyy-MM-dd HH:mm'（本地时区）。不用 intl：避免依赖
  /// 日期符号表的 locale 初始化，且该格式在中英韩下均可读。
  static String _formatDateTime(int ms) {
    final d = DateTime.fromMillisecondsSinceEpoch(ms);
    String two(int v) => v.toString().padLeft(2, '0');
    return '${d.year}-${two(d.month)}-${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}';
  }
}
