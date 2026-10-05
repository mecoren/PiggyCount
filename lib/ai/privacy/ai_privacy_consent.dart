import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 当前 AI 隐私"告知+同意"文案版本。文案实质变更时 +1,可强制用户重新同意。
const int kAiPrivacyConsentVersion = 1;

/// AI 第三方数据共享"告知+同意"的持久化存取(纯逻辑,便于单测)。
///
/// 仅本机授权状态:不入库、不参与云同步。同意版本号进安全存储
/// （prefs 里是可篡改的 int，老版本读到即迁移并清理明文）。
class AiPrivacyConsentStore {
  AiPrivacyConsentStore._();

  static const String prefsKey = 'ai_privacy_consent_version';

  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 测试注入：内存安全存储，置非空即启用，避免平台通道。
  @visibleForTesting
  static Map<String, String>? testSecureStore;

  static Future<String?> _secureRead() async {
    final testStore = testSecureStore;
    if (testStore != null) return testStore[prefsKey];
    return _secure.read(key: prefsKey);
  }

  static Future<void> _secureWrite(String value) async {
    final testStore = testSecureStore;
    if (testStore != null) {
      testStore[prefsKey] = value;
      return;
    }
    await _secure.write(key: prefsKey, value: value);
  }

  /// 已同意的文案版本;从未同意返回 0。
  static Future<int> readVersion() async {
    try {
      final secure = await _secureRead();
      if (secure != null) return int.tryParse(secure) ?? 0;
    } catch (_) {
      // 安全存储不可用时回退明文路径（降级可读，不阻塞同意判断）
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getInt(prefsKey);
    if (legacy != null) {
      try {
        await _secureWrite(legacy.toString());
        await prefs.remove(prefsKey);
      } catch (_) {
        // 迁移失败不阻塞读取
      }
      return legacy;
    }
    return 0;
  }

  /// 是否已对**当前**文案版本同意。
  static Future<bool> isConsented() async {
    return await readVersion() >= kAiPrivacyConsentVersion;
  }

  /// 记录用户对当前文案版本的同意。
  static Future<void> accept() async {
    await _secureWrite(kAiPrivacyConsentVersion.toString());
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(prefsKey);
  }
}
