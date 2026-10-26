/// 「汇总块滑进标题栏后面后，把汇总数字收进标题栏」的折叠进度。
///
/// 资产页（净资产 / 总资产 / 总负债）、订阅管理页（年支出 / 月均 / 订阅数）
/// 共用同一套判据：汇总块底边越过标题栏下沿后，用 [window] 逻辑像素的过渡窗口
/// 淡入（0 = 隐藏，1 = 常显）。
///
/// 单独抽成纯函数便于单测：符号写反会造成「没滑上去就冒出一份重复的汇总 /
/// 滑到底也不出现」，而这类时序问题在真机上很难一眼看出来。
double pinnedSummaryProgress({
  required double blockBottom,
  required double appBarBottom,
  double window = 36,
}) {
  if (window <= 0) return blockBottom <= appBarBottom ? 1.0 : 0.0;
  return ((appBarBottom - blockBottom) / window).clamp(0.0, 1.0).toDouble();
}
