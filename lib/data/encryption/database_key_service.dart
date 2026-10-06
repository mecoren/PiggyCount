import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// 整库加密的**密钥层**（SQLCipher / SQLite3MultipleCiphers）。
///
/// 对应 `prd/sqlcipher_db_encryption/requirements.md` 的 R2（密钥进系统安全区）
/// 与 R5（密钥丢失有明确出口）。契约：
///
/// - 密钥是 **32 字节随机数的 hex（64 位）**，只存系统安全区（Android Keystore /
///   iOS Keychain），与同步密钥同级；连接时用 SQLCipher 的 raw key 语法
///   （`PRAGMA key = "x'<hex>'"`）绕开 KDF；
/// - **绝不自动创建**：在明文库上凭空造一把密钥，会让"库看起来该加密、文件其实
///   还是明文"成为默认状态 —— 建钥必须由用户**显式开启加密**的动作驱动；
/// - 密钥不落日志、不进异常消息、不进任何导出产物（`grep` 得能证明这一点）。
///
/// 注：本类只负责存取；把密钥交给连接的接线（`db.dart` 的 `setup` / 健康探测的
/// 只读连接）**尚未落地** —— 见 `prd/sqlcipher_db_encryption/design.md` §7
/// 的选型与平台阻塞。
class DatabaseKeyService {
  const DatabaseKeyService();

  /// 安全存储键名。**一旦发布不可改**：改了等于丢密钥（老用户库打不开）。
  static const String storageKey = 'db_encryption_key_hex';

  /// 密钥长度（字节）。32B = 256 位，SQLCipher 推荐值。
  static const int keyBytes = 32;

  // 11.x：Android 侧默认即加密存储（见 secure_key_storage.dart 的说明），
  // 不再需要显式 encryptedSharedPreferences。
  static const FlutterSecureStorage _secure = FlutterSecureStorage();

  /// 测试注入：内存安全存储，置非空即启用（避免平台通道）。
  /// 与 `AiPrivacyConsentStore.testSecureStore` 同款。
  @visibleForTesting
  static Map<String, String>? testSecureStore;

  Future<String?> _read() async {
    final testStore = testSecureStore;
    if (testStore != null) return testStore[storageKey];
    return _secure.read(key: storageKey);
  }

  Future<void> _write(String value) async {
    final testStore = testSecureStore;
    if (testStore != null) {
      testStore[storageKey] = value;
      return;
    }
    await _secure.write(key: storageKey, value: value);
  }

  Future<void> _delete() async {
    final testStore = testSecureStore;
    if (testStore != null) {
      testStore.remove(storageKey);
      return;
    }
    await _secure.delete(key: storageKey);
  }

  /// 读取已启用的密钥；**没有就是没有**（不自动生成）。
  ///
  /// 存量值非法（长度/字符不符，例如被截断或写坏）时返回 null —— 上层据此走
  /// R5 的"密钥不可得"引导，而不是拿一把废密钥去开库（那只会得到
  /// "file is not a database"，把"密钥坏了"误报成"库坏了"）。
  Future<String?> loadKey() async {
    final raw = await _read();
    if (raw == null) return null;
    return isValidKey(raw) ? raw : null;
  }

  /// 用户**显式开启加密**时调用：生成并落库，返回 hex。
  Future<String> createKey() async {
    final key = generateHexKey();
    await _write(key);
    return key;
  }

  /// 关闭加密 / 清除全部数据时调用（必须与库文件一起清，见 R6 与
  /// `AppLockService.wipeAllData` 的联动要求）。
  Future<void> deleteKey() => _delete();

  /// 32 字节随机 → 64 位小写 hex。
  static String generateHexKey([Random? rng]) {
    final r = rng ?? Random.secure();
    final bytes = List<int>.generate(keyBytes, (_) => r.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// 合法密钥 = 恰好 64 位小写 hex。
  static bool isValidKey(String value) =>
      value.length == keyBytes * 2 && _hexOnly.hasMatch(value);

  static final RegExp _hexOnly = RegExp(r'^[0-9a-f]+$');
}
