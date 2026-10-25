import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/db.dart';
import '../../l10n/app_localizations.dart';
import '../../providers.dart';
import '../../providers/custom_field_providers.dart';
import '../../data/models/analytics_amount_metric.dart';
import '../../data/models/analytics_time_metric.dart';
import '../../services/custom_field_stats_service.dart';
import '../../services/export/csv_builder.dart';
import '../../services/export/custom_field_stats_csv.dart';
import '../../services/system/logger_service.dart';
import '../../styles/tokens.dart';
import '../../widgets/analytics/field_stats_detail_view.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/ui/ui.dart';
import '../../utils/transaction_search_filter.dart';
import '../transaction/search_page.dart';

/// 「字段分析」下钻页（prd/custom_field_stats_fullchain F2）。
///
/// 数据自取：[customFieldStatsDetailProvider]（键含 ledgerId/起止/refreshTick），
/// 刻意不并入洞察页主链路 —— 分析页的区间与视角从卡片参数带入（同构参数），
/// 主链路卡片渲染零改动（R5）。
///
/// 渲染分发在 [FieldStatsDetailView]（sealed switch 穷尽）；本页只负责：
/// 字段切换 chips、空态、下钻回调透传。下钻载荷（[FieldDrillTarget]）由调用方
/// 消费——阶段 3 的筛选联动只接这个契约。
class CustomFieldAnalysisPage extends ConsumerStatefulWidget {
  const CustomFieldAnalysisPage({
    super.key,
    required this.start,
    required this.end,
    required this.type,
    this.amountMetric = AnalyticsAmountMetric.recorded,
    this.timeMetric = AnalyticsTimeMetric.happenedAt,
    this.fieldSyncId,
    this.onDrillDown,
    this.onExportCsv,
  });

  /// 统计区间（与洞察卡同构）。
  final DateTime start;
  final DateTime end;

  /// 洞察视角：'expense' | 'income' | 'balance'（balance 走支出展示兜底，
  /// 入口卡在结余视角已隐藏，正常到不了这里）。
  final String type;

  /// 金额口径（与洞察卡同源）：金额型字段的求和/分布随之切换。
  final AnalyticsAmountMetric amountMetric;

  /// 统计时间口径（与洞察卡同源）：区间按记账时间还是某个日期型自定义字段
  /// 判定。不透传的话，从洞察卡下钻进来的数字会与卡片对不上账。
  final AnalyticsTimeMetric timeMetric;

  /// 初始选中字段；null/不存在时默认第一个字段。
  final String? fieldSyncId;

  /// 下钻回调；null = 值行不可点（预览场景）。
  final FieldDrillDown? onDrillDown;

  /// 导出回调（F4）；null = 默认走系统分享落盘。测试注入捕获 CSV 行。
  final CustomFieldCsvExport? onExportCsv;

  @override
  ConsumerState<CustomFieldAnalysisPage> createState() =>
      _CustomFieldAnalysisPageState();
}

class _CustomFieldAnalysisPageState
    extends ConsumerState<CustomFieldAnalysisPage> {
  /// 选中字段 syncId。列表加载后校正（初始值可能指向不存在的字段）。
  String? _selectedSyncId;

  /// 当前聚合结果缓存（导出汇总表时用，避免再查一遍）。
  List<FieldStats>? _currentData;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final fields = ref.watch(customFieldStatsDetailProvider((
      ledgerId: ref.watch(currentLedgerIdProvider),
      start: widget.start,
      end: widget.end,
      refreshTick: ref.watch(statsRefreshProvider),
      amountMetric: widget.amountMetric,
      timeMetric: widget.timeMetric,
    )));

    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.customFieldAnalysisTitle,
        subtitle: _rangeText(),
        showBack: true,
        actions: [
          if (fields.value?.isNotEmpty ?? false)
            PopupMenuButton<CustomFieldCsvKind>(
              key: const Key('custom-field-export-menu'),
              tooltip: l10n.customFieldExportCsv,
              icon: const Icon(Icons.ios_share),
              onSelected: (kind) => _exportCsv(context, l10n, kind),
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: CustomFieldCsvKind.aggregate,
                  child: Text(l10n.customFieldExportAggregateCsv),
                ),
                PopupMenuItem(
                  value: CustomFieldCsvKind.detail,
                  child: Text(l10n.customFieldExportDetailCsv),
                ),
              ],
            ),
        ],
      ),
      // 标题栏避让做进列表自身 padding（不能包在 body 外），
      // 滚动内容才能穿到标题栏下方、磨砂才有内容可模糊。
      body: fields.when(
        loading: () => const Center(child: PiggySpinner()),
        // 附属页失败不吞错：落日志 + 空态（禁空 catch 约束）。
        error: (e, st) {
          logger.warning('洞察', '字段分析页聚合失败: $e\n$st');
          return AppEmpty(text: l10n.commonError);
        },
        data: (data) {
          _currentData = data;
          return _body(context, l10n, data);
        },
      ),
    );
  }

  /// 导出 CSV（F4）：聚合/明细两份，产出「表头+行」后走回调或系统分享。
  Future<void> _exportCsv(BuildContext context, AppLocalizations l10n,
      CustomFieldCsvKind kind) async {
    final rows = switch (kind) {
      CustomFieldCsvKind.aggregate => buildCustomFieldAggregateCsvRows(
          l10n: l10n,
          stats: _currentData ?? const [],
        ),
      CustomFieldCsvKind.detail => await _buildDetailRows(l10n),
    };
    if (!context.mounted) return;
    if (widget.onExportCsv != null) {
      widget.onExportCsv!(kind, rows);
      return;
    }
    await _shareCsv(context, l10n, kind, rows);
  }

  /// 明细行：区间交易 + 该账本字段定义 → 每字段一列。
  Future<List<List<dynamic>>> _buildDetailRows(AppLocalizations l10n) async {
    final repo = ref.read(repositoryProvider);
    final ledgerId = ref.read(currentLedgerIdProvider);
    final results = await Future.wait([
      repo.getDefinitionsForLedger(ledgerId),
      repo.getTransactionsByDateRange(
        ledgerId: ledgerId,
        startDate: widget.start,
        endDate: widget.end,
        timeMetric: widget.timeMetric,
      ),
    ]);
    final defs = results[0] as List<CustomFieldDefinition>;
    final txs = results[1] as List<
        ({
          Transaction t,
          Category? category,
          List<Tag> tags,
          List<TransactionAttachment> attachments,
          Account? account,
        })>;
    // 与聚合同口径：半开区间 [start, end) + 排除「不计收支」（customFieldStatsRows
    // 的 WHERE 条件），且时间轴同源（默认口径按记账时间；选了自定义字段时间
    // 口径时按该字段的日期 —— 否则屏幕上按字段日期汇总、导出的明细却按记账
    // 时间取行）。getTransactionsByDateRange 默认口径是闭区间 BETWEEN（收口到
    // 半开，避免明细行比汇总行多出边界那一笔），自定义字段时间口径本身就是
    // 半开，`inRange` 对两种口径都与取数 SQL 同义。
    final rows = [
      for (final r in txs)
        if (!r.t.excludeFromStats &&
            widget.timeMetric
                .inRange(r.t, start: widget.start, end: widget.end))
          r.t,
    ];
    return buildCustomFieldDetailCsvRows(l10n: l10n, defs: defs, txs: rows);
  }

  /// 落盘 + 系统分享：临时文件分享后即删（「临时文件不残留」约束）。
  Future<void> _shareCsv(BuildContext context, AppLocalizations l10n,
      CustomFieldCsvKind kind, List<List<dynamic>> rows) async {
    try {
      final dir = await getTemporaryDirectory();
      final stamp = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final suffix =
          kind == CustomFieldCsvKind.aggregate ? 'summary' : 'detail';
      final file =
          File('${dir.path}/piggycount_field_stats_${stamp}_$suffix.csv');
      await file.writeAsString(encodeCsvWithBom(rows));
      await SharePlus.instance.share(
        ShareParams(
            files: [XFile(file.path)], text: l10n.customFieldExportSuccess),
      );
      await file.delete();
    } catch (e) {
      logger.warning('洞察', '字段统计 CSV 导出失败: $e');
      if (context.mounted) {
        showToast(context, '${l10n.commonFailed}: $e');
      }
    }
  }

  String _rangeText() {
    final f = DateFormat('yyyy.MM.dd');
    // 右端是半开区间，展示口径取「含末日」（与区间报表一致）。
    return '${f.format(widget.start)} ~ '
        '${f.format(widget.end.subtract(const Duration(days: 1)))}';
  }

  Widget _body(
      BuildContext context, AppLocalizations l10n, List<FieldStats> data) {
    if (data.isEmpty) {
      return Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 80,
        ),
        child: AppEmpty(
          text: l10n.commonEmpty,
          subtext: l10n.customFieldAnalysisEmptySubtext,
        ),
      );
    }
    // 初始选中校正：fieldSyncId 不存在（如字段已删）时回退第一个字段。
    final selected = data.firstWhere(
      (f) => f.fieldSyncId == _selectedSyncId,
      orElse: () {
        final fallback = _pickInitial(data);
        // 首次加载校正持久化，后续重建不再反复走 fallback。
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) setState(() => _selectedSyncId = fallback.fieldSyncId);
        });
        return fallback;
      },
    );
    final dim = widget.type == 'income' ? 'income' : 'expense';
    return ListView(
      // top 含标题栏避让（双行标题栏 80dp）
      padding: EdgeInsets.fromLTRB(
        16,
        MediaQuery.of(context).padding.top + 80 + 8,
        16,
        24,
      ),
      children: [
        SingleChildScrollView(
          key: const Key('field-switch-chips'),
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              for (final f in data)
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(f.name),
                    selected: f.fieldSyncId == selected.fieldSyncId,
                    onSelected: (_) =>
                        setState(() => _selectedSyncId = f.fieldSyncId),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        FillRateRow(stats: selected),
        const SizedBox(height: 12),
        // 无人填写：提示文案而不是画一屏空图（与洞察卡「无数据自隐藏」同哲学）。
        if (selected.filledCount == 0)
          AppEmpty(
            text: l10n.commonEmpty,
            subtext: l10n.customFieldAnalysisEmptySubtext,
          )
        else
          FieldStatsDetailView(
            stats: selected,
            dim: dim,
            // 未显式给回调时默认下钻到带筛选的明细（复用现有搜索页，
            // 不开新明细页 —— design.md 决策 3）。
            onDrillDown: widget.onDrillDown ?? _drillToSearch,
          ),
      ],
    );
  }

  /// 下钻 → 打开搜索页并带该字段值条件（F3「下钻即筛选」）。
  void _drillToSearch(FieldDrillTarget target) {
    final cond = switch (target) {
      FieldDrillValue(
        :final fieldSyncId,
        :final fieldName,
        :final fieldType,
        :final value
      ) =>
        CustomFieldCondition.eq(
          fieldSyncId: fieldSyncId,
          fieldName: fieldName,
          fieldType: fieldType,
          value: value,
        ),
      FieldDrillRange(
        :final fieldSyncId,
        :final fieldName,
        :final fieldType,
        :final lower,
        :final upper
      ) =>
        CustomFieldCondition.between(
          fieldSyncId: fieldSyncId,
          fieldName: fieldName,
          fieldType: fieldType,
          lower: lower,
          upper: upper,
        ),
    };
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => SearchPage(initialCustomFieldConditions: [cond]),
      ),
    );
  }

  /// 初始字段：指定优先，否则第一个。
  FieldStats _pickInitial(List<FieldStats> data) {
    final wanted = widget.fieldSyncId;
    if (wanted != null) {
      for (final f in data) {
        if (f.fieldSyncId == wanted) return f;
      }
    }
    return data.first;
  }
}
