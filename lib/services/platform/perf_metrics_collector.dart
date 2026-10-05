import 'dart:collection';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

/// 单帧采样（debug 仪表盘用）。
@immutable
class PerfFrameSample {
  const PerfFrameSample({
    required this.buildMs,
    required this.rasterMs,
    required this.at,
  });

  /// UI 线程耗时（build / layout / paint）。
  final double buildMs;

  /// 光栅（GPU）线程耗时。
  final double rasterMs;

  final DateTime at;

  /// 该帧总耗时（UI + 光栅），毫秒。
  double get totalMs => buildMs + rasterMs;
}

/// 帧耗时采集器（性能基线设施）。
///
/// 口径见 `docs/evidence/perf-baseline-2026-10-05.md`：本采集器与
/// `scripts/profile_cold_start.py` 的 timeline 解析**同口径**（UI / 光栅分列），
/// 便于「应用内看到的」与「脚本采到的」对账。
///
/// ponytail: 只做最少的事 —— 每 vsync 收一次帧回调，落进定长环形缓冲；
/// **不写盘、不建表、不上报、不建 watchdog**。release 构建下 [start] 直接
/// 空转（[supported] 为 false），零常驻成本。
class PerfMetricsCollector {
  PerfMetricsCollector._();

  /// 全局单例：采集器无状态耦合，仪表盘页面共享同一份样本。
  static final PerfMetricsCollector instance = PerfMetricsCollector._();

  /// 环形缓冲长度（约 4s@60fps，够仪表盘画满一屏）。
  static const int maxSamples = 240;

  final Queue<PerfFrameSample> _samples = Queue<PerfFrameSample>();
  bool _running = false;

  bool get isRunning => _running;

  /// release 下不支持采集（零常驻）。
  static bool get supported => !kReleaseMode;

  /// 最近样本（旧 → 新）。
  List<PerfFrameSample> get samples => List.unmodifiable(_samples);

  void start() {
    if (_running || !supported) return;
    WidgetsBinding.instance.addTimingsCallback(_onTimings);
    _running = true;
  }

  void stop() {
    if (!_running) return;
    WidgetsBinding.instance.removeTimingsCallback(_onTimings);
    _running = false;
  }

  void reset() => _samples.clear();

  void _onTimings(List<FrameTiming> timings) {
    for (final t in timings) {
      _samples.addLast(PerfFrameSample(
        buildMs: t.buildDuration.inMicroseconds / 1000.0,
        rasterMs: t.rasterDuration.inMicroseconds / 1000.0,
        at: DateTime.now(),
      ));
      while (_samples.length > maxSamples) {
        _samples.removeFirst();
      }
    }
  }
}
