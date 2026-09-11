import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

// P2-10（2026-09-11）状态注记：本文件是「云端协同下线」后的历史壳——
// AppMode 仅剩 local，App 启动路径（main._initializeAppMode）已不再
// 触碰 appModeProvider（只做 SharedPreferences 旧值规范化）。
// 保留而非删除：enum 的 fromString 仍被 main.dart 用于把历史
// `app_mode=cloud` 旧值规范化回 local；AppModeNotifier/switchMode
// 为未来模式回归预留最小实现，当前无生产消费者。

/// 应用模式枚举
///
/// 历史上还有过两个已删值:`cloud`(数据完全存 Supabase)与 PiggyCount Cloud
/// 上线后的「LocalRepository + ChangeTracker 实时推送」范式 —— 后者已随云端
/// 协同下线移除,现所有云同步走「本地优先 + 快照同步」,cloud-only 没有
/// 用户入口。
///
/// 保留 enum 而非改 bool 是为了:
/// 1) SharedPreferences 旧数据 `app_mode=cloud` 能 fallback 到 local,不崩
/// 2) 未来如果又出现"另一种模式"(比如 demo / readonly),不用再改类型
enum AppMode {
  local('本地优先模式');

  final String label;
  const AppMode(this.label);

  /// 从字符串解析,未知值(包括历史 `cloud`)统一回退到 local
  static AppMode fromString(String value) {
    return AppMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AppMode.local,
    );
  }
}

/// 当前应用模式 Provider
final appModeProvider = StateNotifierProvider<AppModeNotifier, AppMode>((ref) {
  return AppModeNotifier();
});

/// AppMode 状态管理器
class AppModeNotifier extends StateNotifier<AppMode> {
  AppModeNotifier() : super(AppMode.local) {
    _loadMode();
  }

  Future<void> _loadMode() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final modeStr = prefs.getString('app_mode');
      if (modeStr != null) {
        state = AppMode.fromString(modeStr);
      }
    } catch (e) {
      state = AppMode.local;
    }
  }

  Future<void> switchMode(AppMode mode) async {
    state = mode;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('app_mode', mode.name);
    } catch (e) {
      // 保存失败,但状态已经切换
    }
  }

  Future<void> switchToLocal() => switchMode(AppMode.local);
}
