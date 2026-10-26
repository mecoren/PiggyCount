import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show appFlavor;

/// 开发者工具门禁（测试数据生成等）—— **只有 dev flavor 的 debug / profile 包
/// 才允许出现**。
///
/// 为什么不能只看 [kReleaseMode]：prod flavor 同样可以打 debug / profile 包
/// （例如 `flutter run --flavor prod` 给内测 / 演示用），那种包是对外口径，
/// 不应带开发者工具。
///
/// 为什么能「生产彻底没有」：[kReleaseMode] 与 [appFlavor] 都是**编译期常量**
/// （`appFlavor` 来自 `FLUTTER_APP_FLAVOR` dart-define），release 构建里
/// `DevToolGate.enabled` 会被常量折叠成 `false`，入口处的 `if` 分支整段不可达，
/// 页面与 seeder 随之被 tree shaking 裁掉，不进产物。
class DevToolGate {
  DevToolGate._();

  /// 是否允许显示 / 执行开发者工具。release 与 prod flavor 一律 false。
  static const bool enabled = !kReleaseMode && appFlavor == 'dev';

  /// 当前运行环境（结构化，供界面逐行展示；不要拼成一段长文本）。
  ///
  /// [packageName] / [version] 由调用方用 `package_info_plus` 取 ——
  /// dev flavor 的 applicationId 带 `.dev` 后缀，是环境归属最直接的证据。
  static DevToolEnv env({String? packageName, String? version}) => DevToolEnv(
        flavor: appFlavor ?? 'none',
        mode: kReleaseMode ? 'release' : (kProfileMode ? 'profile' : 'debug'),
        platform: defaultTargetPlatform.name,
        packageName: packageName,
        version: version,
      );
}

/// 开发者工具的运行环境描述（逐项展示用）。
class DevToolEnv {
  const DevToolEnv({
    required this.flavor,
    required this.mode,
    required this.platform,
    this.packageName,
    this.version,
  });

  /// `--flavor` 的值；未传时为 `none`。
  final String flavor;

  /// debug / profile / release。
  final String mode;

  /// android / ios / windows ……
  final String platform;

  /// 真实包名（dev flavor 带 `.dev` 后缀）。
  final String? packageName;

  /// `version+buildNumber`。
  final String? version;
}
