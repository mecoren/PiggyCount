import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../utils/platform_info.dart';
import '../system/logger_service.dart';

/// 防截屏 / 防录屏开关（Android `FLAG_SECURE`）。
///
/// **默认开启**：窗口内容不进系统截屏、录屏、投屏，也不进最近任务缩略图。
/// 原生侧实现见 `android/app/src/main/kotlin/com/wait/piggycount/MainActivity.kt`
/// 的 `applyScreenshotProtection`。
///
/// 用户可在「设置 → 外观设置 → 应用锁 → 防截屏保护」自行关闭，用于远程协助、
/// 投屏演示等需要采集画面的场景。开关值持久化在 `SharedPreferences`
/// （键 [keyEnabled]，默认 true），冷启动由 `securityInitProvider` 读回并同步给原生窗口。
///
/// iOS 无同等开关（靠前后台切换模糊屏缓解），[setEnabled] 在非 Android 平台
/// 只落库、不下发原生调用。
class ScreenshotProtectionService {
  static const _channel = MethodChannel('com.wait.piggycount/security');

  /// `SharedPreferences` 键；缺省即「开启保护」。
  static const keyEnabled = 'screenshot_protection_enabled';

  /// 当前是否开启防截屏保护（默认开启）。
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(keyEnabled) ?? true;
  }

  /// 写入开关并把结果同步给原生窗口。
  static Future<void> setEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(keyEnabled, enabled);
    await apply(enabled);
    logger.info('Screenshot', '防截屏保护: ${enabled ? "开启" : "关闭"}');
  }

  /// 把开关应用到原生窗口（仅 Android 生效，其它平台静默跳过）。
  ///
  /// 冷启动时由 `securityInitProvider` 调用，保证「关闭」状态在启动即生效。
  /// 通道异常只记日志，避免设置页因原生未就绪而崩。
  static Future<void> apply(bool enabled) async {
    if (!PlatformInfo.isAndroid) return;
    try {
      await _channel
          .invokeMethod<bool>('setScreenshotProtection', {'enabled': enabled});
    } catch (e) {
      logger.warning('Screenshot', '同步防截屏开关到原生失败: $e');
    }
  }
}
