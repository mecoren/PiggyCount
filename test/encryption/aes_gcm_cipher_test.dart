// AesGcmCipher 单元测试
//
// 锁死 AES-256-GCM 加解密契约：
// - encrypt → decrypt 往返一致
// - 输出格式：nonce(12) || ciphertext || mac(16)
// - 错误密钥解密失败
// - 篡改密文解密失败（GCM 完整性校验）
// - 密钥长度必须 32 字节

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/encryption/aes_gcm_cipher.dart';

void main() {
  group('AesGcmCipher.encrypt', () {
    test('返回的密文长度 = 12(nonce) + 明文长度 + 16(mac)', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);
      final plaintext = utf8.encode('hello world');

      final encrypted = await cipher.encrypt(plaintext: plaintext, key: key);

      expect(encrypted.length, 12 + plaintext.length + 16);
    });

    test('相同明文加密两次产生不同密文（随机 nonce）', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);
      final plaintext = utf8.encode('same plaintext');

      final e1 = await cipher.encrypt(plaintext: plaintext, key: key);
      final e2 = await cipher.encrypt(plaintext: plaintext, key: key);

      expect(e1, isNot(equals(e2)));
      // 但 nonce 段（前 12 字节）不同
      expect(e1.sublist(0, 12), isNot(equals(e2.sublist(0, 12))));
    });

    test('空明文也能加密（输出 nonce + mac = 28 字节）', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);

      final encrypted = await cipher.encrypt(plaintext: [], key: key);

      expect(encrypted.length, 28);
    });

    test('密钥长度不为 32 字节抛出 ArgumentError', () async {
      final cipher = AesGcmCipher();
      final shortKey = List<int>.generate(16, (i) => i);

      expect(
        () => cipher.encrypt(plaintext: [1, 2, 3], key: shortKey),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AesGcmCipher.decrypt', () {
    test('encrypt 后 decrypt 还原原文', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => 0x40 + i);
      const plaintext = 'BeeCount 账本数据 v6';

      final encrypted =
          await cipher.encrypt(plaintext: utf8.encode(plaintext), key: key);
      final decrypted = await cipher.decrypt(encryptedBytes: encrypted, key: key);

      expect(decrypted, equals(utf8.encode(plaintext)));
      expect(utf8.decode(decrypted), plaintext);
    });

    test('大文本加密解密往返一致', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);
      // 模拟 10KB 账本 JSON
      final plaintext =
          utf8.encode('{"items":[${List.filled(100, '{"amount":99.9}').join(',')}]}');

      final encrypted = await cipher.encrypt(plaintext: plaintext, key: key);
      final decrypted = await cipher.decrypt(encryptedBytes: encrypted, key: key);

      expect(decrypted, equals(plaintext));
    });

    test('错误密钥解密失败抛出异常', () async {
      final cipher = AesGcmCipher();
      final key1 = List<int>.generate(32, (i) => i);
      final key2 = List<int>.generate(32, (i) => i + 1);

      final encrypted =
          await cipher.encrypt(plaintext: utf8.encode('secret'), key: key1);

      expect(
        () => cipher.decrypt(encryptedBytes: encrypted, key: key2),
        throwsA(anyOf(isA<Exception>(), isA<Error>())),
      );
    });

    test('密文被篡改后解密失败（GCM 完整性校验）', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);

      final encrypted = await cipher.encrypt(
        plaintext: utf8.encode('original'),
        key: key,
      );

      // 篡改密文段（跳过 nonce 12B + 留 mac 16B，改中间 1 字节）
      final tampered = List<int>.from(encrypted);
      tampered[15] = (tampered[15] + 1) & 0xFF;

      expect(
        () => cipher.decrypt(encryptedBytes: tampered, key: key),
        throwsA(anyOf(isA<Exception>(), isA<Error>())),
      );
    });

    test('mac 被篡改后解密失败', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);

      final encrypted = await cipher.encrypt(
        plaintext: utf8.encode('original'),
        key: key,
      );

      // 篡改最后 1 字节（mac 段）
      final tampered = List<int>.from(encrypted);
      tampered[tampered.length - 1] =
          (tampered[tampered.length - 1] + 1) & 0xFF;

      expect(
        () => cipher.decrypt(encryptedBytes: tampered, key: key),
        throwsA(anyOf(isA<Exception>(), isA<Error>())),
      );
    });

    test('密钥长度不为 32 字节抛出 ArgumentError', () async {
      final cipher = AesGcmCipher();
      final shortKey = List<int>.generate(16, (i) => i);

      expect(
        () => cipher.decrypt(encryptedBytes: [1, 2, 3], key: shortKey),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('密文长度 < 28 字节（nonce+mac 最小）抛出 ArgumentError', () async {
      final cipher = AesGcmCipher();
      final key = List<int>.generate(32, (i) => i);

      expect(
        () => cipher.decrypt(encryptedBytes: [1, 2, 3], key: key),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('AesGcmCipher 密钥派生与跨实例兼容', () {
    test('不同 cipher 实例使用相同密钥可互通', () async {
      final cipher1 = AesGcmCipher();
      final cipher2 = AesGcmCipher();
      final key = Uint8List.fromList(List.generate(32, (i) => 0xAB));

      final encrypted = await cipher1.encrypt(
        plaintext: utf8.encode('cross-instance'),
        key: key,
      );
      final decrypted = await cipher2.decrypt(
        encryptedBytes: encrypted,
        key: key,
      );

      expect(utf8.decode(decrypted), 'cross-instance');
    });
  });
}
