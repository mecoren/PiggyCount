// CiphertextFormat 单元测试
//
// 锁死密文格式的编解码契约：
//   BEECRYPT1:<base64(salt(16))>:<base64(nonce(12) || ciphertext || mac(16))>
//
// 关键不变量：
// - magic header 准确识别密文/明文
// - 编解码往返一致（round-trip）
// - legacy 明文（无 magic）原样保留
// - 异常输入抛出明确异常

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/encryption/ciphertext_format.dart';

void main() {
  group('CiphertextFormat.magicHeader', () {
    test('magic header 是 BEECRYPT1:', () {
      expect(CiphertextFormat.magicHeader, 'BEECRYPT1:');
    });

    test('当前版本号是 1', () {
      expect(CiphertextFormat.version, 1);
    });
  });

  group('CiphertextFormat.isEncrypted', () {
    test('BEECRYPT1: 开头的字符串识别为密文', () {
      const s = 'BEECRYPT1:YWJj:ZGVm';
      expect(CiphertextFormat.isEncrypted(s), isTrue);
    });

    test('普通 JSON 明文识别为非密文', () {
      const s = '{"version":6,"items":[]}';
      expect(CiphertextFormat.isEncrypted(s), isFalse);
    });

    test('空字符串识别为非密文', () {
      expect(CiphertextFormat.isEncrypted(''), isFalse);
    });

    test('只有 magic header 但无内容识别为非密文（避免误判）', () {
      // 严格格式：必须有两个冒号分隔的三段
      expect(CiphertextFormat.isEncrypted('BEECRYPT1:'), isFalse);
      expect(CiphertextFormat.isEncrypted('BEECRYPT1:abc'), isFalse);
    });

    test('BEECRYPT2: 未来版本识别为非密文（当前版本不处理）', () {
      const s = 'BEECRYPT2:abc:def';
      expect(CiphertextFormat.isEncrypted(s), isFalse);
    });
  });

  group('CiphertextFormat.encode / decode 往返', () {
    test('encode 后 decode 还原原始 salt 和 encryptedBytes', () {
      final salt = List<int>.generate(16, (i) => i + 1);
      final encryptedBytes = List<int>.generate(40, (i) => 100 + i);

      final encoded = CiphertextFormat.encode(
        salt: salt,
        encryptedBytes: encryptedBytes,
      );

      // 应该以 magic header 开头
      expect(encoded.startsWith('BEECRYPT1:'), isTrue);

      final decoded = CiphertextFormat.decode(encoded);

      expect(decoded.salt, equals(salt));
      expect(decoded.encryptedBytes, equals(encryptedBytes));
    });

    test('16 字节 salt + 40 字节 encryptedBytes 编码后格式正确', () {
      final salt = List<int>.filled(16, 0x42);
      final encryptedBytes = List<int>.filled(40, 0x55);

      final encoded = CiphertextFormat.encode(
        salt: salt,
        encryptedBytes: encryptedBytes,
      );

      // 格式：BEECRYPT1:<b64(salt)>:<b64(encryptedBytes)>
      final parts = encoded.split(':');
      expect(parts.length, 3);
      expect(parts[0], 'BEECRYPT1');
      expect(parts[1], base64.encode(salt));
      expect(parts[2], base64.encode(encryptedBytes));
    });

    test('空 encryptedBytes 拒绝编码（AES-GCM 输出永远非空）', () {
      final salt = List<int>.generate(16, (i) => i);
      const encryptedBytes = <int>[];

      expect(
        () => CiphertextFormat.encode(
          salt: salt,
          encryptedBytes: encryptedBytes,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('CiphertextFormat.decode 异常处理', () {
    test('空字符串抛出 FormatException', () {
      expect(
        () => CiphertextFormat.decode(''),
        throwsA(isA<FormatException>()),
      );
    });

    test('legacy 明文抛出 FormatException（调用方应先 isEncrypted 判断）', () {
      const plaintext = '{"version":6,"items":[]}';
      expect(
        () => CiphertextFormat.decode(plaintext),
        throwsA(isA<FormatException>()),
      );
    });

    test('格式不完整（缺第三段）抛出 FormatException', () {
      expect(
        () => CiphertextFormat.decode('BEECRYPT1:abc'),
        throwsA(isA<FormatException>()),
      );
    });

    test('magic header 错误抛出 FormatException', () {
      expect(
        () => CiphertextFormat.decode('BEECRYPT2:abc:def'),
        throwsA(isA<FormatException>()),
      );
    });

    test('base64 非法字符抛出 FormatException', () {
      expect(
        () => CiphertextFormat.decode('BEECRYPT1:!!!非法!!!:abc'),
        throwsA(isA<FormatException>()),
      );
    });

    test('salt 长度不为 16 字节抛出 FormatException', () {
      // salt 必须是 16 字节
      final badSalt = base64.encode(List<int>.filled(15, 0));
      final validPayload = base64.encode(List<int>.filled(40, 0));
      expect(
        () => CiphertextFormat.decode('BEECRYPT1:$badSalt:$validPayload'),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('CiphertextFormat 实际密文场景', () {
    test('模拟真实 GCM 密文（12B nonce + ciphertext + 16B mac）编解码', () {
      // AES-GCM 标准格式：nonce(12) || ciphertext || mac(16)
      // 这里模拟一个 1KB 明文加密后的结果
      final salt = List<int>.generate(16, (i) => 0xAA + i);
      final nonce = List<int>.generate(12, (i) => 0x10 + i);
      final ciphertext = List<int>.generate(1024, (i) => i % 256);
      final mac = List<int>.generate(16, (i) => 0xF0 + i);

      final encryptedBytes = [...nonce, ...ciphertext, ...mac];

      final encoded = CiphertextFormat.encode(
        salt: salt,
        encryptedBytes: encryptedBytes,
      );

      final decoded = CiphertextFormat.decode(encoded);

      expect(decoded.salt, equals(salt));
      expect(decoded.encryptedBytes, equals(encryptedBytes));

      // 验证可以拆出 nonce / ciphertext / mac
      expect(decoded.encryptedBytes.sublist(0, 12), equals(nonce));
      expect(
        decoded.encryptedBytes.sublist(12, decoded.encryptedBytes.length - 16),
        equals(ciphertext),
      );
      expect(
        decoded.encryptedBytes.sublist(decoded.encryptedBytes.length - 16),
        equals(mac),
      );
    });
  });
}
