import 'dart:convert';

import 'package:cryptography/cryptography.dart';

/// Argon2id 密钥派生函数
///
/// 用于从用户密码派生 256 位 AES 密钥。
/// Argon2id 是 memory-hard 算法，抗 GPU/ASIC 离线爆破。
///
/// 性能：单次派生 ~500ms-1s（生产参数），测试用 [forTesting] 参数保持快速。
class Argon2KeyDerivation {
  /// salt 固定长度（字节）
  static const int saltLength = 16;

  /// 派生 key 长度（字节，AES-256）
  static const int keyLength = 32;

  final Argon2id _argon2id;

  Argon2KeyDerivation._(this._argon2id);

  /// 生产参数构造函数
  ///
  /// iterations=3, memory=64MB, parallelism=2
  /// 单次派生约 500ms-1s，通过 compute() 在 Isolate 执行
  factory Argon2KeyDerivation() {
    return Argon2KeyDerivation._(
      Argon2id(
        iterations: 3,
        memory: 64 * 1024, // 64 MB
        parallelism: 2,
        hashLength: keyLength,
      ),
    );
  }

  /// 测试参数构造函数
  ///
  /// iterations=1, memory=8KB, parallelism=1
  /// 单次派生 < 50ms，仅用于单元测试
  factory Argon2KeyDerivation.forTesting() {
    return Argon2KeyDerivation._(
      Argon2id(
        iterations: 1,
        memory: 8, // 8 KB
        parallelism: 1,
        hashLength: keyLength,
      ),
    );
  }

  /// 从密码派生 32 字节 AES-256 密钥
  ///
  /// [password] 用户密码
  /// [salt] 16 字节随机 salt（跟随密文存云端）
  ///
  /// 相同 password + salt 派生相同 key（确定性）。
  Future<List<int>> deriveKey({
    required String password,
    required List<int> salt,
  }) async {
    if (salt.length != saltLength) {
      throw ArgumentError(
        'salt must be $saltLength bytes, got ${salt.length}',
      );
    }

    final secretKey = SecretKey(utf8.encode(password));
    final derivedKey = await _argon2id.deriveKey(
      secretKey: secretKey,
      nonce: salt,
    );

    final keyBytes = await derivedKey.extractBytes();
    return keyBytes;
  }

  /// 生成 16 字节随机 salt
  ///
  /// 使用 cryptography 包的安全随机数生成器。
  static Future<List<int>> generateSalt() async {
    final secretKey = SecretKeyData.random(length: saltLength);
    return secretKey.extractBytes();
  }
}
