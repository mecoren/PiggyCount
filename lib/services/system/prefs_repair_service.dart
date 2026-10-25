/// 本机偏好存储（shared_preferences 的 `flutter.*` 键）的自救通道。
///
/// 背景（2026-10-25 Android 实测）：`shared_preferences_android` 2.5.x 起改用
/// JNI 直接读 `SharedPreferences`，`getAll` 的结果要逐个值做类型解码；一旦偏好
/// 里存在解码层不认识的值类型，解码会抛 `ArgumentError`
/// （`toString()` 只有 `Invalid argument: Instance of 'JObject'`）。这不是某一个
/// 键读失败，而是 `SharedPreferences.getInstance()` **整体**失败——
/// 主题、同步开关、云服务激活标记全部读不到，云同步页/云服务页都只能报错。
///
/// Dart 侧没有任何 API 能"只挑出坏键"：枚举键名本身就要走那次解码。唯一可行的
/// 自救是从**平台层**清空 `flutter.` 前缀的偏好项 —— 平台实现的 clear 只遍历键名
/// 并 `remove`，不解码值，因此再毒的数据也能清掉；此后
/// `SharedPreferences.getInstance()` 会重新读一张空表并恢复可用。
///
/// 代价：本机应用设置全部回默认（主题、同步开关、当前账本选择、云服务选择等）。
/// 账本数据在 SQLite、云凭据在安全存储，均不受影响。故调用方必须走**双重危险
/// 确认**（见 `lib/widgets/ui/dialog.dart` 的 `showDoubleDangerConfirmDialog`）。
library;

import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

class PrefsRepairService {
  const PrefsRepairService();

  /// 清空 `flutter.` 前缀的全部偏好项（第三方无前缀键不动）。
  ///
  /// 走平台接口而不是 `SharedPreferences.clear()`：拿 `SharedPreferences` 实例
  /// 本身就要先经过那层坏掉的全量解码，自救路径必须是"不解码也能清"。
  Future<void> clearAppPreferences() async {
    await SharedPreferencesStorePlatform.instance.clear();
  }
}
