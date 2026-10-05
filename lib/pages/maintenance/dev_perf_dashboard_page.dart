import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../l10n/app_localizations.dart';
import '../../services/platform/perf_metrics_collector.dart';
import '../../styles/tokens.dart';
import '../../widgets/biz/app_empty.dart';
import '../../widgets/biz/section_card.dart';
import '../../widgets/ui/ui.dart';

/// 开发者性能仪表盘（仅 debug / profile 可见，release 入口不出现）。
///
/// 展示内容刻意保持最少：当前 FPS、本帧 UI / 光栅耗时、最近帧的 p90 与
/// 一条帧耗时走势。数据源是 [PerfMetricsCollector]（`addTimingsCallback`），
/// 与 `scripts/profile_cold_start.py` 的 timeline 口径一致。
class DevPerfDashboardPage extends StatefulWidget {
  const DevPerfDashboardPage({super.key});

  @override
  State<DevPerfDashboardPage> createState() => _DevPerfDashboardPageState();
}

class _DevPerfDashboardPageState extends State<DevPerfDashboardPage> {
  final PerfMetricsCollector _collector = PerfMetricsCollector.instance;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _collector.start();
    // 500ms 刷新一次即可：帧回调本身不触发 rebuild（否则就是"测量影响被测"）。
    _ticker = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // 采集器是全局单例：离开页面就停，避免被测量之外的页面持续累积样本。
    _collector.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    return Scaffold(
      backgroundColor: PiggyTokens.scaffoldBackground(context),
      extendBodyBehindAppBar: true,
      appBar: PiggyTitleBar(
        title: l10n.devPerfDashboardTitle,
        showBack: true,
        actions: [
          IconButton(
            tooltip: l10n.devPerfReset,
            onPressed: () => setState(_collector.reset),
            icon: const Icon(Icons.restart_alt),
          ),
        ],
      ),
      body: Padding(
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 80,
        ),
        child: PerfMetricsCollector.supported
            ? _buildBody(context, l10n)
            : AppEmpty(
                text: l10n.devPerfUnsupported,
                subtext: l10n.devPerfUnsupportedHint,
              ),
      ),
    );
  }

  Widget _buildBody(BuildContext context, AppLocalizations l10n) {
    final samples = _collector.samples;
    if (samples.isEmpty) {
      return AppEmpty(text: l10n.devPerfNoData, subtext: l10n.devPerfHint);
    }

    final latest = samples.last;
    final recent = samples.length > 60
        ? samples.sublist(samples.length - 60)
        : samples;
    final p90 = _percentile(
        recent.map((s) => s.totalMs).toList()..sort(), 90);
    // FPS = 最近 1s 内落格的帧数（用样本时间戳算，不用 1000/帧耗时估算）
    final windowStart = latest.at.subtract(const Duration(seconds: 1));
    final fps = samples.where((s) => !s.at.isBefore(windowStart)).length;
    final fpsColor = fps >= 55
        ? PiggyTokens.success(context)
        : (fps >= 40 ? PiggyTokens.warning(context) : PiggyTokens.error(context));

    return ListView(
      padding: const EdgeInsets.only(bottom: PiggyDimens.p24),
      children: [
        Row(
          children: [
            _metricCard(context, l10n.devPerfFps, '$fps',
                color: fpsColor, unit: 'fps'),
            _metricCard(context, l10n.devPerfUiFrame,
                latest.buildMs.toStringAsFixed(1), unit: 'ms'),
            _metricCard(context, l10n.devPerfRasterFrame,
                latest.rasterMs.toStringAsFixed(1), unit: 'ms'),
          ],
        ),
        const SizedBox(height: PiggyDimens.p12),
        SectionCard(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(l10n.devPerfRecentFrames,
                        style: PiggyTextTokens.strongTitle(context)),
                  ),
                  Text('p90 ${p90.toStringAsFixed(1)} ms',
                      style: PiggyTextTokens.label(context).copyWith(
                        color: p90 > 32
                            ? PiggyTokens.error(context)
                            : PiggyTextTokens.label(context).color,
                      )),
                ],
              ),
              const SizedBox(height: PiggyDimens.p12),
              SizedBox(
                height: 96,
                width: double.infinity,
                child: CustomPaint(
                  painter: _FrameSparklinePainter(
                    totals: samples.map((s) => s.totalMs).toList(),
                    barColor: PiggyTokens.primary(context),
                    baselineColor: PiggyTokens.divider(context),
                    budgetLine: 16.67,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: PiggyDimens.p12),
        SectionCard(
          child: Text(l10n.devPerfHint,
              style: PiggyTextTokens.label(context).copyWith(height: 1.5)),
        ),
      ],
    );
  }

  Widget _metricCard(BuildContext context, String label, String value,
      {Color? color, String? unit}) {
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: PiggyDimens.p4),
        child: SectionCard(
          padding: const EdgeInsets.symmetric(
              horizontal: PiggyDimens.p12, vertical: PiggyDimens.p16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                  style: PiggyTextTokens.caption(context),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: PiggyDimens.p4),
              Row(
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Flexible(
                    child: Text(
                      value,
                      style: PiggyTextTokens.boldTitle(context)
                          .copyWith(color: color),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (unit != null) ...[
                    const SizedBox(width: 2),
                    Text(unit, style: PiggyTextTokens.caption(context)),
                  ],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 线性插值分位（与 `scripts/profile_frames.py` 的 pct 口径同为"最近秩"）。
  double _percentile(List<double> sorted, int p) {
    if (sorted.isEmpty) return 0;
    final idx = math.min(sorted.length - 1, (p / 100.0 * sorted.length).floor());
    return sorted[idx];
  }
}

/// 最近帧耗时走势：一根柱子一帧，超 16.67ms 预算的柱体用强调色。
class _FrameSparklinePainter extends CustomPainter {
  _FrameSparklinePainter({
    required this.totals,
    required this.barColor,
    required this.baselineColor,
    required this.budgetLine,
  });

  final List<double> totals;
  final Color barColor;
  final Color baselineColor;
  final double budgetLine;

  @override
  void paint(Canvas canvas, Size size) {
    if (totals.isEmpty) return;
    final maxMs = math.max(
      budgetLine * 1.5,
      totals.reduce((a, b) => a > b ? a : b),
    );
    final barWidth = size.width / totals.length;
    final paint = Paint()..style = PaintingStyle.fill;

    // 16.67ms 预算线
    final y = size.height * (1 - budgetLine / maxMs);
    canvas.drawLine(Offset(0, y), Offset(size.width, y),
        Paint()
          ..color = baselineColor
          ..strokeWidth = 1);

    for (var i = 0; i < totals.length; i++) {
      final h = (totals[i] / maxMs).clamp(0.0, 1.0) * size.height;
      paint.color = totals[i] > budgetLine ? barColor : barColor.withValues(alpha: 0.35);
      final left = i * barWidth;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(left, size.height - h, math.max(barWidth - 1, 1), h),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FrameSparklinePainter old) =>
      old.totals.length != totals.length ||
      (totals.isNotEmpty && old.totals.last != totals.last);
}
