import 'dart:convert';

/// BeeCount 同步加密的密文格式
///
/// 格式：`BEECRYPT1:<base64(salt(16))>:<base64(nonce(12) || ciphertext || mac(16))>`
///
/// 设计要点：
/// - magic header `BEECRYPT1:` 用于自动识别密文/明文，向后兼容云端存量数据
/// - salt 跟随密文存云端（明文，不保密），多设备只需密码即可解密
/// - 未来算法升级走 `BEECRYPT2:`，当前版本不处理
class CiphertextFormat {
  CiphertextFormat._();

  /// magic header 前缀
  static const String magicHeader = 'BEECRYPT1:';

  /// 当前密文格式版本号
  static const int version = 1;

  /// salt 固定长度（字节）
  static const int saltLength = 16;

  /// 判断字符串是否为加密密文
  ///
  /// 严格匹配：必须以 `BEECRYPT1:` 开头且包含两段 base64（用冒号分隔）。
  /// 仅以 magic 开头但格式不全的字符串视为非密文，避免误判。
  static bool isEncrypted(String input) {
    if (!input.startsWith(magicHeader)) return false;
    // 严格校验：BEECRYPT1:<b64>:<b64> 三段结构
    final rest = input.substring(magicHeader.length);
    final parts = rest.split(':');
    if (parts.length != 2) return false;
    if (parts[0].isEmpty || parts[1].isEmpty) return false;
    return true;
  }

  /// 编码为密文格式字符串
  ///
  /// [salt] 必须是 16 字节，[encryptedBytes] 是 nonce || ciphertext || mac
  static String encode({
    required List<int> salt,
    required List<int> encryptedBytes,
  }) {
    if (salt.length != saltLength) {
      throw ArgumentError(
        'salt must be $saltLength bytes, got ${salt.length}',
      );
    }
    if (encryptedBytes.isEmpty) {
      throw ArgumentError(
        'encryptedBytes must not be empty (AES-GCM output is at least nonce+mac = 28 bytes)',
      );
    }
    final saltB64 = base64.encode(salt);
    final payloadB64 = base64.encode(encryptedBytes);
    return '$magicHeader$saltB64:$payloadB64';
  }

  /// 解码密文格式字符串
  ///
  /// 输入必须是 [isEncrypted] 为 true 的字符串。
  /// 否则抛出 [FormatException]。
  static DecodedCiphertext decode(String input) {
    if (!isEncrypted(input)) {
      throw FormatException(
        'Not a valid BEECRYPT1 ciphertext (expected "$magicHeader<b64>:<b64>")',
        input,
      );
    }

    final rest = input.substring(magicHeader.length);
    final parts = rest.split(':');
    final saltB64 = parts[0];
    final payloadB64 = parts[1];

    List<int> salt;
    List<int> encryptedBytes;
    try {
      salt = base64.decode(saltB64);
    } catch (e) {
      throw FormatException('Invalid base64 in salt segment: $e', input);
    }
    try {
      encryptedBytes = base64.decode(payloadB64);
    } catch (e) {
      throw FormatException(
        'Invalid base64 in payload segment: $e',
        input,
      );
    }

    if (salt.length != saltLength) {
      throw FormatException(
        'salt must be $saltLength bytes, got ${salt.length}',
        input,
      );
    }

    return DecodedCiphertext(salt: salt, encryptedBytes: encryptedBytes);
  }
}

/// 解码后的密文数据
class DecodedCiphertext {
  /// Argon2id salt（16 字节）
  final List<int> salt;

  /// 加密负载：nonce(12) || ciphertext || mac(16)
  final List<int> encryptedBytes;

  const DecodedCiphertext({
    required this.salt,
    required this.encryptedBytes,
  });
}
