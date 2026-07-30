import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart' show compute;

/// Argon2id 密钥派生函数
///
/// 用于从用户密码派生 256 位 AES 密钥。
/// Argon2id 是 memory-hard 算法，抗 GPU/ASIC 离线爆破。
///
/// 性能：单次派生 ~500ms-1s（生产参数），通过 [compute] 在 Isolate 执行，
/// 避免阻塞 UI 线程导致 ANR/掉帧。
///
/// 本类为无状态服务，实例本身不持有 Argon2id 对象（因 Isolate 不可跨 isolate
/// 传递，每次派生在 Isolate 内新建实例）。保留构造函数仅为 DI 友好。
class Argon2KeyDerivation {
  /// salt 固定长度（字节）
  static const int saltLength = 16;

  /// 派生 key 长度（字节，AES-256）
  static const int keyLength = 32;

  /// Argon2id 生产参数
  static const int _productionIterations = 3;
  static const int _productionMemory = 64 * 1024; // 64 MB
  static const int _productionParallelism = 2;

  /// Argon2id 测试参数（< 50ms，仅单元测试）
  static const int _testIterations = 1;
  static const int _testMemory = 8; // 8 KB
  static const int _testParallelism = 1;

  /// 是否使用测试参数（实例级标志，通过 [_DeriveArgs] 传入 Isolate）
  final bool useTestParams;

  /// 生产参数构造函数
  const Argon2KeyDerivation() : useTestParams = false;

  /// 测试参数构造函数
  ///
  /// iterations=1, memory=8KB, parallelism=1
  /// 单次派生 < 50ms，仅用于单元测试。
  const Argon2KeyDerivation.forTesting() : useTestParams = true;

  /// 从密码派生 32 字节 AES-256 密钥
  ///
  /// [password] 用户密码
  /// [salt] 16 字节随机 salt（跟随密文存云端）
  ///
  /// 相同 password + salt 派生相同 key（确定性）。
  /// 通过 [compute] 在 Isolate 中执行，避免 500ms-1s 的 KDF 阻塞 UI 线程。
  Future<Uint8List> deriveKey({
    required String password,
    required List<int> salt,
  }) async {
    if (salt.length != saltLength) {
      throw ArgumentError(
        'salt must be $saltLength bytes, got ${salt.length}',
      );
    }

    // 在 Isolate 中执行 KDF，避免阻塞主线程
    // Argon2id 实例不可跨 isolate 传递，需在 isolate 内新建
    // useTestParams 通过 _DeriveArgs 传入，避免 static 状态跨 isolate 不共享
    return compute(
      _deriveKeyInIsolate,
      _DeriveArgs(password, salt, useTestParams),
    );
  }

  /// Isolate 入口函数：执行 Argon2id KDF
  static Future<Uint8List> _deriveKeyInIsolate(_DeriveArgs args) async {
    final argon2id = Argon2id(
      iterations: args.useTestParams ? _testIterations : _productionIterations,
      memory: args.useTestParams ? _testMemory : _productionMemory,
      parallelism: args.useTestParams ? _testParallelism : _productionParallelism,
      hashLength: keyLength,
    );

    final secretKey = SecretKey(utf8.encode(args.password));
    final derivedKey = await argon2id.deriveKey(
      secretKey: secretKey,
      nonce: args.salt,
    );

    final keyBytes = await derivedKey.extractBytes();
    // 必须在 destroy 前复制：extractBytes 可能返回内部 buffer 的视图，
    // destroy 后该 buffer 失效，再访问会抛 Unsupported operation
    final result = Uint8List.fromList(keyBytes);
    // 显式 zeroing 临时 SecretKey（best effort）
    // destroy() 返回 void，不可 await
    secretKey.destroy();
    derivedKey.destroy();

    return result;
  }

  /// 生成 16 字节随机 salt
  ///
  /// 使用 cryptography 包的安全随机数生成器。
  static Future<Uint8List> generateSalt() async {
    final secretKey = SecretKeyData.random(length: saltLength);
    return Uint8List.fromList(await secretKey.extractBytes());
  }
}

/// Isolate 传递参数（必须可序列化）
class _DeriveArgs {
  final String password;
  final List<int> salt;
  final bool useTestParams;

  const _DeriveArgs(this.password, this.salt, this.useTestParams);
}
