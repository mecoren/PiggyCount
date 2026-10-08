import 'dart:async';

/// 行情自动刷新调度器（v52 预留）。
///
/// 与 `BackupScheduler` / `HolidayScheduler` 同款范式：`Timer.periodic` + 互斥 +
/// **静态纯函数**判定（可单测），业务编排由调用方注入的 [onCheck] 完成
/// （见 `lib/providers/quote_providers.dart` 的接线）。
///
/// ⚠️ **默认不启动，而且现在也启动不起来**：当前唯一行情源是「手动录入」，
/// 其 `QuoteCapability.isAutomatic == false`。调用方必须先把
/// `enabled` 传成 `QuoteService.supportsAutomaticQuotes`，所以本批实际不会
/// 创建任何 Timer、不会产生任何网络请求。后期接入真实行情源后无需改这里。
class QuoteRefreshScheduler {
  QuoteRefreshScheduler({required this.onCheck, this.enabled = false});

  /// 检查间隔。行情不是分钟级需求，15 分钟粒度足够；真正的节流还有两道：
  /// 行情源的 `minRefreshInterval`（[shouldTriggerNow] 的 `minInterval`）
  /// 与调度层互斥（上一次未跑完不叠）。
  static const Duration checkInterval = Duration(minutes: 15);

  /// 是否允许启动（= 当前行情源具备自动拉取能力）
  final bool enabled;

  /// 每轮 tick 的业务编排（由调用方注入：节流判定 → QuoteService 拉取 → 失效 Provider）
  final Future<void> Function() onCheck;

  Timer? _timer;
  bool _checking = false;

  /// 启动周期检查。
  ///
  /// [enabled] 为 false 时**直接返回且不创建 Timer** —— 这是「默认关闭」的
  /// 硬保证，不依赖调用方自觉。
  void start() {
    if (!enabled) return;
    _timer ??= Timer.periodic(checkInterval, (_) => _tick());
  }

  void dispose() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _tick() async {
    // 互斥：上一轮（含网络请求）未完成时跳过本次 tick
    if (_checking) return;
    _checking = true;
    try {
      await onCheck();
    } catch (_) {
      // 调度层吞异常：业务层（QuoteService）已按 QuoteErrorKind 记录与降级
    } finally {
      _checking = false;
    }
  }

  /// 本轮是否该真的去拉行情（纯函数，可单测）。
  ///
  /// 条件：
  /// 1. [enabled]（源具备自动能力）；
  /// 2. 距上次成功拉取 ≥ [minInterval]（取行情源的 `minRefreshInterval`）；
  /// 3. 未发生时钟回拨 —— `now` 早于 `lastFetchAt` 时一律不触发，
  ///    否则 TTL / 节流窗口会被算成负数而疯狂重试。
  static bool shouldTriggerNow({
    required bool enabled,
    required DateTime? lastFetchAt,
    required Duration minInterval,
    required DateTime now,
  }) {
    if (!enabled) return false;
    if (lastFetchAt == null) return true;
    final elapsed = now.difference(lastFetchAt);
    if (elapsed.isNegative) return false;
    return elapsed >= minInterval;
  }
}
