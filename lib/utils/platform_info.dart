import 'dart:io';
import 'package:flutter/foundation.dart';

/// 平台族。把「平台判断」收敛成一个可覆写的单点。
///
/// 优化评估报告建议 14 的「封装 PlatformFeature」即指本类 ——
/// 复用既有 [PlatformInfo]（不另起一个 `PlatformFeature`，避免两个平台抽象并存）。
enum PlatformFamily {
  android,
  ios,

  /// 既非 iOS 也非 Android：桌面（Windows/macOS/Linux）或 web。
  other,
}

/// 平台信息工具类。
///
/// **为什么需要它（而不是直接用 `Platform.isIOS`）**：
/// 1. `dart:io` 的 `Platform.isXxx` 在 **web 上会抛异常**，必须先判 `kIsWeb`；
/// 2. 散落的裸 `Platform.isIOS` 无法在测试里覆写 —— 平台相关的 UI 分支
///    （iOS 专属入口、Android 专属设置项）此前完全无法用 widget 测试覆盖。
///
/// 所以本类是所有平台判断的唯一入口：**新代码请用 [isIOS] / [isAndroid]，
/// 不要再直接 import `dart:io` 判平台**。
class PlatformInfo {
  /// 仅测试用：覆写平台判定结果。
  ///
  /// 语义对齐 Flutter 框架的 `debugDefaultTargetPlatformOverride`：
  /// 设值生效、置回 `null` 恢复真实平台。**必须在 tearDown 里重置** ——
  /// widget 测试在同一个进程内跑，不重置会污染后续用例。
  @visibleForTesting
  static PlatformFamily? debugOverride;

  /// 当前平台族。
  ///
  /// 判定顺序：测试覆写 → web 短路 → iOS → Android → 其它。
  /// `kIsWeb` 必须排在 `Platform.isXxx` 之前，否则 web 上会抛异常。
  static PlatformFamily get current {
    final override = debugOverride;
    if (override != null) return override;
    if (kIsWeb) return PlatformFamily.other;
    if (Platform.isIOS) return PlatformFamily.ios;
    if (Platform.isAndroid) return PlatformFamily.android;
    return PlatformFamily.other;
  }

  /// 当前操作系统的名字：`android` / `ios` / `windows` / `linux` / `macos` / `web`。
  ///
  /// 与 [current] 的分工：这里返回**真实系统名**，粒度比 [PlatformFamily] 细
  /// （桌面与 web 都落入 [PlatformFamily.other]，但名字可区分），且**不受**
  /// [debugOverride] 影响。用途是**诊断输出** —— 例如抛错时说明「当前跑在什么系统上」，
  /// 而不是分支判定。需要判定平台请用 [isIOS] / [isAndroid]。
  ///
  /// 之所以要包一层：web 上 `dart:io` 的 `Platform.operatingSystem` 会直接抛异常，
  /// 而「在不支持的平台上报错」这条路径恰恰最需要能安全拿到系统名。
  static String get operatingSystemName {
    if (kIsWeb) return 'web';
    return Platform.operatingSystem;
  }

  /// 检查是否为iOS平台
  static bool get isIOS => current == PlatformFamily.ios;

  /// 检查是否为Android平台
  static bool get isAndroid => current == PlatformFamily.android;

  /// 获取iOS主版本号
  /// 返回 null 如果不是iOS平台
  ///
  /// 注意：本值**不受** [debugOverride] 影响，始终读真实系统的
  /// `operatingSystemVersion`（覆写只换平台族，不伪造系统版本）。
  /// 在非 iOS 宿主机上覆写成 [PlatformFamily.ios] 时，这里会解析失败返回
  /// null —— 因此**不要**用它写「覆写成 iOS 后应返回 16」这类断言。
  static int? get iOSMajorVersion {
    if (!isIOS) return null;

    try {
      // Platform.operatingSystemVersion 返回类似 "Version 16.0 (Build 20A5283p)"
      final version = Platform.operatingSystemVersion;
      final versionMatch = RegExp(r'Version (\d+)\.').firstMatch(version);

      if (versionMatch != null) {
        return int.tryParse(versionMatch.group(1) ?? '');
      }
    } catch (e) {
      // 解析失败，返回null
    }

    return null;
  }

  /// 检查iOS版本是否 >= 指定版本
  /// 如果不是iOS平台，返回false
  static bool isIOSVersionAtLeast(int majorVersion) {
    final version = iOSMajorVersion;
    return version != null && version >= majorVersion;
  }

  /// 检查是否支持AppIntents (iOS 16+)
  /// 注意：由于App最低部署目标为iOS 16.0，在iOS上此值始终为true
  /// 但保留此检查以便代码清晰和未来可能的条件编译
  static bool get supportsAppIntents => isIOSVersionAtLeast(16);

  /// 检查是否支持截图自动记账
  /// iOS 16+ 使用AppIntents
  /// Android可能有其他实现
  /// 注意：iOS版App最低要求iOS 16.0，因此iOS设备上此值始终为true
  static bool get supportsAutoScreenshotBilling {
    if (isIOS) {
      return supportsAppIntents;
    }
    // Android 暂不支持
    return false;
  }
}
