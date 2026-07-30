import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// AES-256-GCM 加解密
///
/// 使用 `cryptography` 包的 [AesGcm] 算法，提供 AEAD（认证加密）。
/// 自动走 BackgroundTransformer（Isolate），不阻塞 UI。
///
/// 输出格式：`nonce(12) || ciphertext || mac(16)`
/// 密钥长度：固定 32 字节（AES-256）
class AesGcmCipher {
  /// GCM nonce 长度（字节）
  static const int nonceLength = 12;

  /// GCM MAC 长度（字节）
  static const int macLength = 16;

  /// AES-256 密钥长度（字节）
  static const int keyLength = 32;

  final AesGcm _aesGcm = AesGcm.with256bits();

  AesGcmCipher();

  /// 加密
  ///
  /// [plaintext] 明文字节
  /// [key] 32 字节 AES-256 密钥
  ///
  /// 返回 `nonce(12) || ciphertext || mac(16)`
  Future<List<int>> encrypt({
    required List<int> plaintext,
    required List<int> key,
  }) async {
    if (key.length != keyLength) {
      throw ArgumentError(
        'AES-256 key must be $keyLength bytes, got ${key.length}',
      );
    }

    // 生成随机 nonce
    final nonce = _aesGcm.newNonce();
    final secretKey = SecretKey(Uint8List.fromList(key));
    try {
      final secretBox = await _aesGcm.encrypt(
        Uint8List.fromList(plaintext),
        secretKey: secretKey,
        nonce: nonce,
      );

      // 拼接 nonce || ciphertext || mac
      return [...secretBox.nonce, ...secretBox.cipherText, ...secretBox.mac.bytes];
    } finally {
      // 主动销毁 SecretKey，避免密钥字节在堆中残留（best-effort zeroing）
      secretKey.destroy();
    }
  }

  /// 解密
  ///
  /// [encryptedBytes] 格式：`nonce(12) || ciphertext || mac(16)`
  /// [key] 32 字节 AES-256 密钥
  ///
  /// 返回明文字节
  Future<List<int>> decrypt({
    required List<int> encryptedBytes,
    required List<int> key,
  }) async {
    if (key.length != keyLength) {
      throw ArgumentError(
        'AES-256 key must be $keyLength bytes, got ${key.length}',
      );
    }
    if (encryptedBytes.length < nonceLength + macLength) {
      throw ArgumentError(
        'encryptedBytes too short (min ${nonceLength + macLength} bytes for nonce+mac, got ${encryptedBytes.length})',
      );
    }

    // 拆分 nonce || ciphertext || mac
    final nonce = encryptedBytes.sublist(0, nonceLength);
    final cipherText =
        encryptedBytes.sublist(nonceLength, encryptedBytes.length - macLength);
    final mac = encryptedBytes.sublist(encryptedBytes.length - macLength);

    final secretKey = SecretKey(Uint8List.fromList(key));
    try {
      final secretBox = SecretBox(
        Uint8List.fromList(cipherText),
        nonce: Uint8List.fromList(nonce),
        mac: Mac(Uint8List.fromList(mac)),
      );

      // decrypt 会校验 mac，失败抛 SecretBoxAuthenticationError
      final plaintext = await _aesGcm.decrypt(secretBox, secretKey: secretKey);
      return plaintext;
    } finally {
      // 主动销毁 SecretKey，避免密钥字节在堆中残留（best-effort zeroing）
      secretKey.destroy();
    }
  }
}
