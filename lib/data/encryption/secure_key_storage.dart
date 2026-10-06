import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 加密密钥的安全存储
///
/// 封装 `flutter_secure_storage`，提供密钥和校验块的存取。
/// iOS 使用 Keychain，Android 使用 Keystore，平台级保护。
///
/// 平台安全配置：
/// - **iOS**: `accessibility: first_unlock_this_device`（首次解锁后可访问，
///   仅限本设备，不允许 iCloud Keychain 同步，避免密钥脱离设备控制）
/// - **Android**: `encryptedSharedPreferences: true`（使用 EncryptedSharedPreferences，
///   在低于 Android 7.0 的旧设备上提供更强保护）
///
/// 设计要点：
/// - 密钥以 base64 字符串形式存储（secure_storage 只支持 String）
/// - 提供 DI 友好的构造函数，便于测试注入 mock
class SecureKeyStorage {
  static const String _keyPrefix = 'piggycount_enc_';
  static const String _keyKey = '${_keyPrefix}key';
  static const String _verifierKey = '${_keyPrefix}verifier';
  static const String _saltKey = '${_keyPrefix}salt';
  static const String _rekeyCheckpointKey = '${_keyPrefix}rekey_ckpt';

  final FlutterSecureStorage _storage;

  SecureKeyStorage({FlutterSecureStorage? storage})
      : _storage = storage ??
            const FlutterSecureStorage(
              // iOS: 禁止 iCloud Keychain 同步（synchronizable=false），
              // 密钥绑定本设备；使用 first_unlock_this_device 避免设备被锁后无法解密
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock_this_device,
                synchronizable: false,
              ),
              // Android: 启用 EncryptedSharedPreferences，旧设备保护更强
              // 11.x：AndroidOptions 已移除 encryptedSharedPreferences
              // （10.0 起 Jetpack Security 弃用，改用插件自带 cipher，默认即加密存储）；
              // resetOnError 现在默认 true，此处显式写出以免依赖默认值。
              aOptions: AndroidOptions(resetOnError: true),
            );

  /// 保存 AES-256 密钥（32 字节）
  Future<void> saveKey(List<int> key) async {
    await _storage.write(key: _keyKey, value: base64.encode(key));
  }

  /// 读取密钥，不存在返回 null
  Future<Uint8List?> getKey() async {
    final value = await _storage.read(key: _keyKey);
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  /// 保存校验块（加密的已知明文）
  Future<void> saveVerifier(List<int> verifier) async {
    await _storage.write(key: _verifierKey, value: base64.encode(verifier));
  }

  /// 读取校验块，不存在返回 null
  Future<Uint8List?> getVerifier() async {
    final value = await _storage.read(key: _verifierKey);
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  /// 保存当前激活密钥对应的 salt（16 字节）
  ///
  /// 用于持久化密钥时同步保存 salt，便于后续 verifier 验证时派生密钥。
  Future<void> saveSalt(List<int> salt) async {
    await _storage.write(key: _saltKey, value: base64.encode(salt));
  }

  /// 读取 salt，不存在返回 null
  Future<Uint8List?> getSalt() async {
    final value = await _storage.read(key: _saltKey);
    if (value == null) return null;
    return Uint8List.fromList(base64.decode(value));
  }

  /// 审计 S24：改密检查点（newKey/newSalt 以旧钥加密后的 base64 密文）。
  ///
  /// 云端重加密开始前写入；本地持久化完成后清除。进程在两者之间崩溃时
  /// 检查点保证新钥材料可恢复，避免「云端已换新钥而本地密钥永久丢失」。
  Future<void> saveRekeyCheckpoint(String ciphertextB64) async {
    await _storage.write(key: _rekeyCheckpointKey, value: ciphertextB64);
  }

  Future<String?> getRekeyCheckpoint() async {
    return _storage.read(key: _rekeyCheckpointKey);
  }

  Future<void> clearRekeyCheckpoint() async {
    await _storage.delete(key: _rekeyCheckpointKey);
  }

  /// 清除所有加密相关数据
  Future<void> clearAll() async {
    await _storage.delete(key: _keyKey);
    await _storage.delete(key: _verifierKey);
    await _storage.delete(key: _saltKey);
    await _storage.delete(key: _rekeyCheckpointKey);
  }
}
