import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 加密密钥的安全存储
///
/// 封装 `flutter_secure_storage`，提供密钥和校验块的存取。
/// iOS 使用 Keychain，Android 使用 Keystore，平台级保护。
///
/// 设计要点：
/// - 密钥以 base64 字符串形式存储（secure_storage 只支持 String）
/// - 提供 DI 友好的构造函数，便于测试注入 mock
class SecureKeyStorage {
  static const String _keyPrefix = 'piggycount_enc_';
  static const String _keyKey = '${_keyPrefix}key';
  static const String _verifierKey = '${_keyPrefix}verifier';
  static const String _saltKey = '${_keyPrefix}salt';

  final FlutterSecureStorage _storage;

  SecureKeyStorage({FlutterSecureStorage? storage})
      : _storage = storage ?? const FlutterSecureStorage();

  /// 保存 AES-256 密钥（32 字节）
  Future<void> saveKey(List<int> key) async {
    await _storage.write(key: _keyKey, value: base64.encode(key));
  }

  /// 读取密钥，不存在返回 null
  Future<List<int>?> getKey() async {
    final value = await _storage.read(key: _keyKey);
    if (value == null) return null;
    return base64.decode(value);
  }

  /// 保存校验块（加密的已知明文）
  Future<void> saveVerifier(List<int> verifier) async {
    await _storage.write(key: _verifierKey, value: base64.encode(verifier));
  }

  /// 读取校验块，不存在返回 null
  Future<List<int>?> getVerifier() async {
    final value = await _storage.read(key: _verifierKey);
    if (value == null) return null;
    return base64.decode(value);
  }

  /// 保存当前激活密钥对应的 salt（16 字节）
  ///
  /// 用于持久化密钥时同步保存 salt，便于后续 verifier 验证时派生密钥。
  Future<void> saveSalt(List<int> salt) async {
    await _storage.write(key: _saltKey, value: base64.encode(salt));
  }

  /// 读取 salt，不存在返回 null
  Future<List<int>?> getSalt() async {
    final value = await _storage.read(key: _saltKey);
    if (value == null) return null;
    return base64.decode(value);
  }

  /// 清除所有加密相关数据
  Future<void> clearAll() async {
    await _storage.delete(key: _keyKey);
    await _storage.delete(key: _verifierKey);
    await _storage.delete(key: _saltKey);
  }
}
