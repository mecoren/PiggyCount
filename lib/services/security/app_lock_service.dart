import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:local_auth/local_auth.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../data/encryption/argon2_key_derivation.dart';
import '../system/logger_service.dart';
import 'secure_storage.dart';

class AppLockService {
  static const _keyEnabled = 'app_lock_enabled';
  static const _keyPinHash = 'app_lock_pin_hash';
  static const _keyPinLength = 'app_lock_pin_length';
  static const _keyBiometricEnabled = 'app_lock_biometric_enabled';
  static const _keyTimeoutSeconds = 'app_lock_timeout_seconds';
  static const _keyLastBackgroundTime = 'app_lock_last_background_time';
  static const _keyFailedCount = 'app_lock_failed_count';
  static const _keyLockoutUntil = 'app_lock_lockout_until_ms';
  static const _keyWipeEnabled = 'app_lock_wipe_enabled';

  /// 支持的 PIN 长度（S2）。4 位是默认，6 位把暴力空间从 1e4 提到 1e6；
  /// 长度本身存安全存储（不随 prefs 被改，避免「改成 6 位但锁屏仍等 4 位」）。
  static const List<int> kSupportedPinLengths = [4, 6];
  static const int kDefaultPinLength = 4;

  /// 失败退避：5 次起锁 30 秒，10 次起 5 分钟；之后每多 5 次翻倍
  /// （10/20/40/60 分钟封顶），成功即清零。递增退避让「挂机试 PIN」
  /// 的成本随失败次数指数上升，而不是永远停在固定的 5 分钟。
  static const int kLockoutAfterAttempts = 5;
  static const int kExtendedLockoutAfterAttempts = 10;
  static const Duration kLockoutDuration = Duration(seconds: 30);
  static const Duration kExtendedLockoutDuration = Duration(minutes: 5);
  static const Duration kMaxLockoutDuration = Duration(hours: 1);

  /// wipe 阈值：连续失败达此次数且用户开启 wipe 开关时，提供清除数据选项。
  static const int kWipeAfterAttempts = 20;

  /// S4：统一安全存储口径（iOS 仅本设备 / Android resetOnError）。
  static const FlutterSecureStorage _secure = piggySecureStorage;

  /// 测试注入：内存安全存储（避免平台通道），置非空即启用。
  @visibleForTesting
  static Map<String, String>? testSecureStore;

  static Future<String?> _secureRead(String key) async {
    final testStore = testSecureStore;
    if (testStore != null) return testStore[key];
    return _secure.read(key: key);
  }

  static Future<void> _secureWrite(String key, String value) async {
    final testStore = testSecureStore;
    if (testStore != null) {
      testStore[key] = value;
      return;
    }
    await _secure.write(key: key, value: value);
  }

  static Future<void> _secureDelete(String key) async {
    final testStore = testSecureStore;
    if (testStore != null) {
      testStore.remove(key);
      return;
    }
    await _secure.delete(key: key);
  }

  static final LocalAuthentication _localAuth = LocalAuthentication();

  /// Argon2id KDF 实例（生产参数：3 迭代 / 64MB / 2 并行）
  /// 用于 PIN 哈希派生，替代原无盐单次 SHA-256。
  static const _argon2 = Argon2KeyDerivation();

  /// 最近一次解锁时间（内存中，防止解锁后立即被 resumed 事件重新锁定）
  static DateTime? _lastUnlockTime;

  /// 记录解锁时间
  static void recordUnlock() {
    _lastUnlockTime = DateTime.now();
    logger.info('AppLock', '已记录解锁时间');
  }

  /// 旧版 SHA-256 哈希（无盐单次），仅用于迁移期验证旧 PIN
  static String _legacyHashPin(String pin) {
    final bytes = utf8.encode(pin);
    return sha256.convert(bytes).toString();
  }

  /// 用 Argon2id + 随机 salt 哈希 PIN 码
  ///
  /// 返回格式 `base64(salt):base64(hash)`，salt 为 16 字节随机值，
  /// hash 为 Argon2id 派生的 32 字节。每次 setPin 生成新 salt。
  static Future<String> _hashPinSecure(String pin) async {
    final salt = await Argon2KeyDerivation.generateSalt();
    final hash = await _argon2.deriveKey(password: pin, salt: salt);
    return '${base64.encode(salt)}:${base64.encode(hash)}';
  }

  /// 设置 PIN 码（Argon2id + salt，哈希进安全存储）。
  ///
  /// [length] 省略时沿用已保存的长度（旧 PIN 默认 4 位）；显式传入用于
  /// 创建/改密时选择 4 位或 6 位（[kSupportedPinLengths]）。
  static Future<void> setPin(String pin, {int? length}) async {
    final effectiveLength = length ?? await getPinLength();
    if (!kSupportedPinLengths.contains(effectiveLength)) {
      throw ArgumentError.value(
          effectiveLength, 'length', 'PIN 长度必须为 ${kSupportedPinLengths.join(' 或 ')} 位');
    }
    if (pin.length != effectiveLength ||
        !RegExp(r'^\d+$').hasMatch(pin)) {
      throw ArgumentError('PIN 必须为 $effectiveLength 位数字');
    }
    final hashed = await _hashPinSecure(pin);
    await _secureWrite(_keyPinHash, hashed);
    await _secureWrite(_keyPinLength, '$effectiveLength');
    // 清理历史明文残留
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyPinHash);
    await prefs.setBool(_keyEnabled, true);
    await _clearFailures();
    logger.info('AppLock', 'PIN已设置（$effectiveLength 位）');
  }

  /// 当前 PIN 长度（安全存储；脏值 / 缺失回落 [kDefaultPinLength]）。
  static Future<int> getPinLength() async {
    final raw = await _secureRead(_keyPinLength);
    final parsed = raw == null ? null : int.tryParse(raw);
    return kSupportedPinLengths.contains(parsed) ? parsed! : kDefaultPinLength;
  }

  /// 从安全存储读 PIN 哈希；旧版本明文在 prefs，读到即迁移。
  static Future<String?> _readPinHash() async {
    try {
      final secure = await _secureRead(_keyPinHash);
      if (secure != null) return secure;
    } catch (e) {
      logger.warning('AppLock', '安全存储读取失败，尝试明文迁移路径: $e');
    }
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getString(_keyPinHash);
    if (legacy != null) {
      try {
        await _secureWrite(_keyPinHash, legacy);
        await prefs.remove(_keyPinHash);
        logger.info('AppLock', 'PIN 哈希已从明文迁移到安全存储');
      } catch (e) {
        logger.warning('AppLock', 'PIN 迁移到安全存储失败: $e');
      }
      return legacy;
    }
    return null;
  }

  /// 验证 PIN 码
  ///
  /// 支持两种格式：
  /// - 新格式 `base64(salt):base64(hash)`：Argon2id 派生 + 常量时间比较
  /// - 旧格式（纯 SHA-256 hex）：验证成功后自动升级为新格式
  /// 失败退避：5次后锁30秒，10次后锁5分钟；锁定期内直接返回 false。
  static Future<bool> verifyPin(String pin) async {
    if (await isLockedOut()) return false;
    final savedHash = await _readPinHash();
    if (savedHash == null) return false;

    if (savedHash.contains(':')) {
      // 新格式: base64(salt):base64(hash)
      final parts = savedHash.split(':');
      if (parts.length != 2) {
        await _recordFailure();
        return false;
      }
      try {
        final salt = Uint8List.fromList(base64.decode(parts[0]));
        final hash = await _argon2.deriveKey(password: pin, salt: salt);
        final ok = _constantTimeEquals(base64.encode(hash), parts[1]);
        if (ok) {
          await _clearFailures();
        } else {
          await _recordFailure();
        }
        return ok;
      } catch (e) {
        logger.warning('AppLock', 'PIN 验证异常: $e');
        await _recordFailure();
        return false;
      }
    }

    // 旧格式: 无盐 SHA-256，验证成功后自动升级
    if (_constantTimeEquals(_legacyHashPin(pin), savedHash)) {
      await setPin(pin);
      logger.info('AppLock', 'PIN 已从 SHA-256 升级为 Argon2id');
      return true;
    }
    await _recordFailure();
    return false;
  }

  /// 当前失败次数（成功即清零）。
  ///
  /// S3 防篡改：计数与锁定截止时间都在**安全存储**（Keychain / Keystore），
  /// 不再写 SharedPreferences —— 此前明文 XML / plist 可被 root / ADB 备份
  /// 直接改成 0，退避与 wipe 阈值形同虚设。旧版本残留的 prefs 值仍会在首次
  /// 读取时迁移一次，迁移后立即删除明文。
  static Future<int> getFailedAttempts() => _readFailedCount();

  /// 剩余锁定时间；未锁定返回 Duration.zero。
  ///
  /// 锁定截止时间丢失（旧版本 / 被清）但失败次数已达阈值时，按次数**补回**
  /// 最小退避 —— 否则「删掉时间戳」就是绕过锁定的捷径。
  static Future<Duration> getLockoutRemaining() async {
    final count = await _readFailedCount();
    if (count < kLockoutAfterAttempts) return Duration.zero;

    final until = await _readLockoutUntil();
    final now = DateTime.now().millisecondsSinceEpoch;
    if (until <= 0) {
      // 时间戳缺失（旧版本未写 / 被清）：按当前失败次数补回一次退避。
      // 注意过期（until > 0 且 <= now）不能补 —— 那会让锁定永不过期，
      // 用户连「错一次再等下一档」的机会都没有。
      final duration = _lockoutDurationFor(count);
      if (duration == Duration.zero) return Duration.zero;
      await _secureWrite(_keyLockoutUntil, '${now + duration.inMilliseconds}');
      return duration;
    }
    return until > now ? Duration(milliseconds: until - now) : Duration.zero;
  }

  /// 是否处于锁定退避期
  static Future<bool> isLockedOut() async {
    final remaining = await getLockoutRemaining();
    return remaining > Duration.zero;
  }

  /// 第 [count] 次失败应锁多久（成功后清零，不累积历史）。
  static Duration _lockoutDurationFor(int count) {
    if (count < kLockoutAfterAttempts) return Duration.zero;
    if (count < kExtendedLockoutAfterAttempts) return kLockoutDuration;
    // 10 次起 5 分钟，之后每多 5 次翻倍：5 / 10 / 20 / 40 / 60 分钟封顶。
    final steps = ((count - kExtendedLockoutAfterAttempts) ~/ 5).clamp(0, 4);
    final doubled = kExtendedLockoutDuration * (1 << steps);
    return doubled > kMaxLockoutDuration ? kMaxLockoutDuration : doubled;
  }

  static Future<void> _recordFailure() async {
    final count = (await _readFailedCount()) + 1;
    await _secureWrite(_keyFailedCount, '$count');
    final duration = _lockoutDurationFor(count);
    if (duration > Duration.zero) {
      await _secureWrite(_keyLockoutUntil,
          '${DateTime.now().millisecondsSinceEpoch + duration.inMilliseconds}');
    }
    // 清掉旧版本明文（迁移已完成），避免「改 prefs 覆盖安全值」的误导。
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFailedCount);
    await prefs.remove(_keyLockoutUntil);
  }

  static Future<void> _clearFailures() async {
    await _secureDelete(_keyFailedCount);
    await _secureDelete(_keyLockoutUntil);
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_keyFailedCount);
    await prefs.remove(_keyLockoutUntil);
  }

  /// 读失败计数（安全存储优先；prefs 仅作旧版本一次性迁移来源）。
  static Future<int> _readFailedCount() async {
    final secure = await _secureRead(_keyFailedCount);
    if (secure != null) return int.tryParse(secure) ?? 0;

    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getInt(_keyFailedCount);
    if (legacy == null) return 0;
    await _secureWrite(_keyFailedCount, '$legacy');
    final legacyUntil = prefs.getInt(_keyLockoutUntil);
    if (legacyUntil != null &&
        legacyUntil > DateTime.now().millisecondsSinceEpoch) {
      await _secureWrite(_keyLockoutUntil, '$legacyUntil');
    }
    await prefs.remove(_keyFailedCount);
    await prefs.remove(_keyLockoutUntil);
    logger.info('AppLock', '失败计数已从明文迁移到安全存储');
    return legacy;
  }

  /// 读锁定截止时间（安全存储优先；prefs 仅旧版本迁移来源）。
  static Future<int> _readLockoutUntil() async {
    final secure = await _secureRead(_keyLockoutUntil);
    if (secure != null) return int.tryParse(secure) ?? 0;
    final prefs = await SharedPreferences.getInstance();
    final legacy = prefs.getInt(_keyLockoutUntil) ?? 0;
    if (legacy > 0) {
      await _secureWrite(_keyLockoutUntil, '$legacy');
      await prefs.remove(_keyLockoutUntil);
    }
    return legacy;
  }

  /// wipe 开关是否开启（默认关闭；普通偏好，非敏感）。
  static Future<bool> isWipeEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyWipeEnabled) ?? false;
  }

  /// 设置 wipe 开关。
  static Future<void> setWipeEnabled(bool value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyWipeEnabled, value);
    logger.info('AppLock', '失败清除数据: ${value ? "开启" : "关闭"}');
  }

  /// 是否达到 wipe 条件（开关开 + 连续失败达阈值）。
  static Future<bool> shouldWipe() async {
    if (!await isWipeEnabled()) return false;
    return await getFailedAttempts() >= kWipeAfterAttempts;
  }

  /// 清除本机全部数据：数据库三件套 + 附件目录 + prefs + 安全存储。
  ///
  /// 文件名与 [_openConnection] / `DatabaseHealthService.dbFileName` 同源
  /// （`piggycount.sqlite*`），附件目录与 `attachment_service.dart` 同源。
  /// 返回是否全部成功；失败也如数清理（尽力而为），调用方据返回值提示。
  /// 成功后用户需重启应用（内存中的 Repository 状态在重启前保持锁屏不动）。
  static Future<bool> wipeAllData() async {
    var ok = true;
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (final name in [
        'piggycount.sqlite',
        'piggycount.sqlite-wal',
        'piggycount.sqlite-shm',
      ]) {
        try {
          final file = File(p.join(dir.path, name));
          if (await file.exists()) await file.delete();
        } catch (e) {
          ok = false;
          logger.warning('AppLock', '清除数据库文件失败 $name: $e');
        }
      }
      try {
        final attDir = Directory(p.join(dir.path, 'attachments'));
        if (await attDir.exists()) {
          await attDir.delete(recursive: true);
        }
      } catch (e) {
        ok = false;
        logger.warning('AppLock', '清除附件目录失败: $e');
      }
    } catch (e) {
      ok = false;
      logger.warning('AppLock', '获取应用目录失败: $e');
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.clear();
    } catch (e) {
      ok = false;
      logger.warning('AppLock', '清除偏好失败: $e');
    }
    try {
      final testStore = testSecureStore;
      if (testStore != null) {
        testStore.clear();
      } else {
        await _secure.deleteAll();
      }
    } catch (e) {
      ok = false;
      logger.warning('AppLock', '清除安全存储失败: $e');
    }
    logger.info('AppLock', '清除本机数据完成: ${ok ? "成功" : "部分失败"}');
    return ok;
  }

  /// 常量时间字符串比较，防止侧信道时序攻击
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var result = 0;
    for (var i = 0; i < a.length; i++) {
      result |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return result == 0;
  }

  /// 清除 PIN 码并禁用锁定
  static Future<void> clearPin() async {
    final prefs = await SharedPreferences.getInstance();
    await _secureDelete(_keyPinHash);
    await prefs.remove(_keyPinHash);
    await prefs.setBool(_keyEnabled, false);
    await prefs.setBool(_keyBiometricEnabled, false);
    await _secureDelete(_keyPinLength);
    await _clearFailures();
    logger.info('AppLock', 'PIN已清除，应用锁已禁用');
  }

  /// 是否已启用应用锁
  static Future<bool> isEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyEnabled) ?? false;
  }

  /// 是否有已保存的 PIN
  static Future<bool> hasPin() async {
    final hash = await _readPinHash();
    return hash != null;
  }

  /// 是否已启用生物识别
  static Future<bool> isBiometricEnabled() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyBiometricEnabled) ?? false;
  }

  /// 设置生物识别开关
  static Future<void> setBiometricEnabled(bool enabled) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_keyBiometricEnabled, enabled);
    logger.info('AppLock', '生物识别: ${enabled ? "开启" : "关闭"}');
  }

  /// 获取超时时间（秒）
  static Future<int> getTimeoutSeconds() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(_keyTimeoutSeconds) ?? 0;
  }

  /// 设置超时时间（秒）
  static Future<void> setTimeoutSeconds(int seconds) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(_keyTimeoutSeconds, seconds);
    logger.info('AppLock', '超时时间设置: ${seconds}s');
  }

  /// 记录进入后台时间
  static Future<void> recordBackgroundTime() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt(
        _keyLastBackgroundTime, DateTime.now().millisecondsSinceEpoch);
  }

  /// 检查从后台恢复是否需要锁定
  static Future<bool> shouldLockOnResume() async {
    // 刚解锁后短时间内不重新锁定（防止 Face ID/PIN 解锁后
    // 因系统弹窗导致的 resumed 事件触发重新锁定）
    if (_lastUnlockTime != null &&
        DateTime.now().difference(_lastUnlockTime!) <
            const Duration(seconds: 3)) {
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    final enabled = prefs.getBool(_keyEnabled) ?? false;
    if (!enabled) return false;

    final lastBgTime = prefs.getInt(_keyLastBackgroundTime);
    if (lastBgTime == null) return false;

    final timeoutSeconds = prefs.getInt(_keyTimeoutSeconds) ?? 0;
    if (timeoutSeconds == 0) return true; // 立即锁定

    final elapsed = DateTime.now().millisecondsSinceEpoch - lastBgTime;
    return elapsed >= timeoutSeconds * 1000;
  }

  /// 检查设备是否支持生物识别
  static Future<bool> canUseBiometrics() async {
    try {
      final canAuth = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return canAuth && isDeviceSupported;
    } catch (e) {
      logger.error('AppLock', '检查生物识别支持失败', e);
      return false;
    }
  }

  /// 执行生物识别认证
  static Future<bool> authenticateWithBiometrics(
      {String reason = '请验证身份以解锁应用'}) async {
    try {
      // local_auth 3.x：AuthenticationOptions 已移除，stickyAuth 对应
      // persistAcrossBackgrounding；失败改为抛 LocalAuthException。
      return await _localAuth.authenticate(
        localizedReason: reason,
        biometricOnly: true,
        persistAcrossBackgrounding: true,
      );
    } catch (e) {
      logger.error('AppLock', '生物识别认证失败', e);
      return false;
    }
  }
}
