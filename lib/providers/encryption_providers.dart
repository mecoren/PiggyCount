import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../data/encryption/aes_gcm_cipher.dart';
import '../data/encryption/argon2_key_derivation.dart';
import '../data/encryption/encryption_service_impl.dart';
import '../data/encryption/secure_key_storage.dart';
import '../domain/encryption/encryption_service.dart';

/// 加密服务单例 Provider
///
/// 全 app 唯一 [EncryptionService] 实例。
/// 内部组合 [SecureKeyStorage] + [Argon2KeyDerivation] + [AesGcmCipher]。
///
/// 日常加解密：直接用 secure storage 中的密钥，不需要密码。
/// 修改密码/验证密码：UI 调用 `verifyPassword` / `changePassword`。
final encryptionServiceProvider = Provider<EncryptionService>((ref) {
  // EncryptionServiceImpl 不持有需要显式释放的资源：
  // - SharedPreferences 是全局单例
  // - SecureKeyStorage 内部 FlutterSecureStorage 无状态
  // - AesGcmCipher / Argon2KeyDerivation 也都是无状态
  return EncryptionServiceImpl(
    storage: SecureKeyStorage(),
    keyDerivation: Argon2KeyDerivation(),
    cipher: AesGcmCipher(),
  );
});

/// 加密是否已开启
///
/// 监听 [encryptionEnabledTickProvider] 以便 enable/disable/reset 后刷新。
final encryptionEnabledProvider = FutureProvider<bool>((ref) async {
  ref.watch(encryptionEnabledTickProvider);
  final service = ref.watch(encryptionServiceProvider);
  return service.isEnabled;
});

/// 当前是否有可用密钥
final encryptionHasActiveKeyProvider = FutureProvider<bool>((ref) async {
  ref.watch(encryptionEnabledTickProvider);
  final service = ref.watch(encryptionServiceProvider);
  return service.hasActiveKey;
});

/// 加密状态刷新 tick（enable/disable/reset/changePassword 后 ++）
final encryptionEnabledTickProvider = StateProvider<int>((ref) => 0);
