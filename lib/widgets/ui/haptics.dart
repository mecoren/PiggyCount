import 'package:flutter/services.dart';

/// 触感反馈统一入口。
///
/// 全应用触感策略:
/// - [selection]: 轻量选择类操作(Tab 切换、picker 滚动、segment 切换)
/// - [light]:    轻交互确认(按钮点击、菜单弹出、卡片展开)
/// - [medium]:   中等强度反馈(滑动删除确认、长按菜单呼出、SpeedDial 展开)
/// - [success]:  重要动作完成(保存成功、刷新完成),iOS 上为一次轻击
/// - [warning]:  破坏性/警示操作(删除执行、清空数据)
///
/// 所有方法内部吞掉平台异常,保证在不支持触感的设备上静默降级。
abstract final class PiggyHaptics {
  static void selection() => _run(() => HapticFeedback.selectionClick());

  static void light() => _run(() => HapticFeedback.lightImpact());

  static void medium() => _run(() => HapticFeedback.mediumImpact());

  /// 成功双击触感(iOS Taptic 双脉冲;Android 为两次轻击)。
  static Future<void> success() async {
    try {
      await HapticFeedback.vibrate();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await HapticFeedback.lightImpact();
    } catch (_) {}
  }

  /// 警示三连击,用于破坏性操作确认。
  static Future<void> warning() async {
    try {
      for (var i = 0; i < 3; i++) {
        await HapticFeedback.mediumImpact();
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }
    } catch (_) {}
  }

  static void _run(void Function() fn) {
    try {
      fn();
    } catch (_) {}
  }
}
