import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 全应用统一的安全存储实例（安全 S4）。
///
/// 此前各处各自 `const FlutterSecureStorage()` 或只配一半选项：
/// - iOS 默认 `KeychainAccessibility.unlocked` 且允许 iCloud Keychain 同步，
///   密钥可能随 iCloud 备份离开本设备；
/// - Android 侧 `resetOnError` 未显式声明，依赖插件默认值。
///
/// 统一口径（与 `SecureKeyStorage` 原实现一致）：
/// - **iOS**：`first_unlock_this_device`（首次解锁后即可读，不要求前台解锁；
///   仅本设备，不参与 iCloud Keychain 同步）；
/// - **Android**：`resetOnError: true`（Keystore 损坏时重置该条目而不是让
///   每次读写都抛异常卡死启动；11.x 起插件默认即加密存储）。
///
/// 需要注入 mock 的调用方（单测）继续用自己的 `FlutterSecureStorage?` 参数，
/// 生产路径请统一引用本常量。
const FlutterSecureStorage piggySecureStorage = FlutterSecureStorage(
  iOptions: IOSOptions(
    accessibility: KeychainAccessibility.first_unlock_this_device,
    synchronizable: false,
  ),
  aOptions: AndroidOptions(resetOnError: true),
);
