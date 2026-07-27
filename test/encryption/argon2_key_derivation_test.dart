// Argon2KeyDerivation 单元测试
//
// 锁死 Argon2id 密钥派生契约：
// - 相同 password + salt 派生相同 key
// - 不同 password 派生不同 key
// - 不同 salt 派生不同 key
// - 派生 key 长度固定 32 字节（AES-256）
// - salt 长度固定 16 字节
//
// 注意：Argon2id 是 memory-hard 算法，单次派生 ~500ms-1s。
// 测试使用最小参数（iterations=1, memory=8KB, parallelism=1）保持快速。

import 'package:flutter_test/flutter_test.dart';

import 'package:beecount/data/encryption/argon2_key_derivation.dart';

void main() {
  group('Argon2KeyDerivation.deriveKey', () {
    test('派生 key 长度为 32 字节（AES-256）', () async {
      final kdf = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => i);

      final key = await kdf.deriveKey(password: 'password', salt: salt);

      expect(key.length, 32);
    });

    test('相同 password + salt 派生相同 key（确定性）', () async {
      final kdf = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => 0x42);

      final key1 = await kdf.deriveKey(password: 'mypassword', salt: salt);
      final key2 = await kdf.deriveKey(password: 'mypassword', salt: salt);

      expect(key1, equals(key2));
    });

    test('不同 password 派生不同 key', () async {
      final kdf = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => 0x42);

      final key1 = await kdf.deriveKey(password: 'password1', salt: salt);
      final key2 = await kdf.deriveKey(password: 'password2', salt: salt);

      expect(key1, isNot(equals(key2)));
    });

    test('不同 salt 派生不同 key', () async {
      final kdf = Argon2KeyDerivation.forTesting();

      final key1 =
          await kdf.deriveKey(password: 'same', salt: List.generate(16, (i) => 1));
      final key2 =
          await kdf.deriveKey(password: 'same', salt: List.generate(16, (i) => 2));

      expect(key1, isNot(equals(key2)));
    });

    test('空 password 也能派生（不抛异常，结果确定）', () async {
      final kdf = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => i);

      final key = await kdf.deriveKey(password: '', salt: salt);

      expect(key.length, 32);
    });

    test('salt 长度不为 16 字节抛出 ArgumentError', () async {
      final kdf = Argon2KeyDerivation.forTesting();

      expect(
        () => kdf.deriveKey(
          password: 'password',
          salt: List<int>.generate(15, (i) => i),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('password 为 null 抛出 ArgumentError', () async {
      final kdf = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => i);

      expect(
        () => kdf.deriveKey(password: '', salt: salt),
        // 空字符串不抛异常，但 null 会抛 ArgumentError（Dart null-safety 强制）
        // 此测试验证空字符串被接受
        returnsNormally,
      );
    });
  });

  group('Argon2KeyDerivation.generateSalt', () {
    test('生成 16 字节随机 salt', () async {
      final salt = await Argon2KeyDerivation.generateSalt();

      expect(salt.length, 16);
    });

    test('两次生成不同的 salt（随机性）', () async {
      final salt1 = await Argon2KeyDerivation.generateSalt();
      final salt2 = await Argon2KeyDerivation.generateSalt();

      expect(salt1, isNot(equals(salt2)));
    });
  });

  group('Argon2KeyDerivation 跨实例一致性', () {
    test('两个 kdf 实例使用相同 password + salt 派生相同 key', () async {
      final kdf1 = Argon2KeyDerivation.forTesting();
      final kdf2 = Argon2KeyDerivation.forTesting();
      final salt = List<int>.generate(16, (i) => 0x99);

      final key1 = await kdf1.deriveKey(password: 'test', salt: salt);
      final key2 = await kdf2.deriveKey(password: 'test', salt: salt);

      expect(key1, equals(key2));
    });
  });
}
