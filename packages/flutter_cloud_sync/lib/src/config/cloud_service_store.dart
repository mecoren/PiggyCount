import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'cloud_service_config.dart';

/// 云服务配置持久化存储
/// 支持类型: 本地存储、PiggyCount Cloud、自定义 Supabase、自定义 WebDAV、iCloud、S3
///
/// P2-4 安全加固：含凭据的配置（云密码 / Supabase anonKey / WebDAV 密码 /
/// S3 SecretKey 等）统一存入 flutter_secure_storage（Android 加密
/// SharedPreferences / iOS Keychain），SharedPreferences 仅保留非敏感的
/// 激活类型标记。老版本明文数据在首次读取时自动迁移到安全存储并删除明文。
class CloudServiceStore {
  static const _kActiveType =
      'cloud_active_type'; // local | piggycount_cloud | supabase | webdav | icloud | s3
  static const _kPiggyCountCloudCfg = 'cloud_piggycount_cloud_cfg';
  static const _kSupabaseCfg = 'cloud_supabase_cfg';
  static const _kWebdavCfg = 'cloud_webdav_cfg';
  static const _kS3Cfg = 'cloud_s3_cfg';

  /// 安全存储实例。Android 使用 EncryptedSharedPreferences 加密。
  static const FlutterSecureStorage _secure = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  /// 读取配置 JSON：优先安全存储；SharedPreferences 仅作旧版本明文
  /// 数据的迁移回退（读到后迁移到安全存储并删除明文）。
  Future<String?> _readCfg(String key) async {
    try {
      final secure = await _secure.read(key: key);
      if (secure != null) return secure;
    } catch (e) {
      debugPrint('Secure storage read failed for $key: $e');
    }
    final sp = await SharedPreferences.getInstance();
    final legacy = sp.getString(key);
    if (legacy != null) {
      // 旧明文数据迁移（尽力而为，失败不阻塞读取）
      try {
        await _secure.write(key: key, value: legacy);
        await sp.remove(key);
        debugPrint('Migrated config $key from plaintext prefs to secure storage');
      } catch (e) {
        debugPrint('Secure storage migration failed for $key: $e');
      }
    }
    return legacy;
  }

  /// 写入配置 JSON 到安全存储；安全存储不可用时降级到
  /// SharedPreferences（保持可用但不丢配置）。
  Future<void> _writeCfg(String key, String value) async {
    var wroteSecure = false;
    try {
      await _secure.write(key: key, value: value);
      wroteSecure = true;
    } catch (e) {
      debugPrint('Secure storage write failed for $key, fallback to prefs: $e');
    }
    final sp = await SharedPreferences.getInstance();
    if (wroteSecure) {
      // 安全存储写入成功：清除旧明文
      await sp.remove(key);
    } else {
      // 降级路径：明文写入 SharedPreferences
      await sp.setString(key, value);
    }
  }

  /// 加载当前激活的云服务配置
  Future<CloudServiceConfig> loadActive() async {
    final sp = await SharedPreferences.getInstance();
    final activeType = sp.getString(_kActiveType) ?? 'local';

    switch (activeType) {
      case 'local':
        return CloudServiceConfig.localStorage();

      case 'piggycount_cloud':
        final raw = await _readCfg(_kPiggyCountCloudCfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            debugPrint('Config parse failed for $activeType: $e');
          }
        }
        return CloudServiceConfig.localStorage();

      case 'supabase':
        final raw = await _readCfg(_kSupabaseCfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            debugPrint('Config parse failed for $activeType: $e');
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      case 'webdav':
        final raw = await _readCfg(_kWebdavCfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            debugPrint('Config parse failed for $activeType: $e');
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      case 'icloud':
        // iCloud 无需额外配置，返回 iCloud 类型的配置
        return const CloudServiceConfig(
          type: CloudBackendType.icloud,
          name: 'iCloud',
        );

      case 's3':
        final raw = await _readCfg(_kS3Cfg);
        if (raw != null) {
          try {
            return decodeCloudConfig(raw);
          } catch (e) {
            debugPrint('Config parse failed for $activeType: $e');
          }
        }
        // 回退到本地存储
        return CloudServiceConfig.localStorage();

      default:
        return CloudServiceConfig.localStorage();
    }
  }

  /// 加载 PiggyCount Cloud 配置(不管是否激活)
  Future<CloudServiceConfig?> loadPiggyCountCloud() async {
    final raw = await _readCfg(_kPiggyCountCloudCfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载Supabase配置(不管是否激活)
  Future<CloudServiceConfig?> loadSupabase() async {
    final raw = await _readCfg(_kSupabaseCfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载WebDAV配置(不管是否激活)
  Future<CloudServiceConfig?> loadWebdav() async {
    final raw = await _readCfg(_kWebdavCfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 加载S3配置(不管是否激活)
  Future<CloudServiceConfig?> loadS3() async {
    final raw = await _readCfg(_kS3Cfg);
    if (raw == null) return null;
    try {
      return decodeCloudConfig(raw);
    } catch (e) {
      return null;
    }
  }

  /// 保存并激活配置
  ///
  // 先写配置再激活：若两次写入间崩溃，下次 loadActive 找不到配置会回退本地存储，符合预期
  Future<void> saveAndActivate(CloudServiceConfig cfg) async {
    final sp = await SharedPreferences.getInstance();

    switch (cfg.type) {
      case CloudBackendType.local:
        await sp.setString(_kActiveType, 'local');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.piggycountCloud:
        await _writeCfg(_kPiggyCountCloudCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'piggycount_cloud');
        break;

      case CloudBackendType.supabase:
        await _writeCfg(_kSupabaseCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'supabase');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.webdav:
        await _writeCfg(_kWebdavCfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 'webdav');
        // Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.icloud:
        await sp.setString(_kActiveType, 'icloud');
        // iCloud 无需额外配置，Provider 会在下次使用时自动初始化
        break;

      case CloudBackendType.s3:
        await _writeCfg(_kS3Cfg, encodeCloudConfig(cfg));
        await sp.setString(_kActiveType, 's3');
        // Provider 会在下次使用时自动初始化
        break;
    }
  }

  /// 仅保存配置,不激活
  Future<void> saveOnly(CloudServiceConfig cfg) async {
    switch (cfg.type) {
      case CloudBackendType.local:
        // 本地存储无需保存
        break;

      case CloudBackendType.piggycountCloud:
        await _writeCfg(_kPiggyCountCloudCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.supabase:
        await _writeCfg(_kSupabaseCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.webdav:
        await _writeCfg(_kWebdavCfg, encodeCloudConfig(cfg));
        break;

      case CloudBackendType.icloud:
        // iCloud 无需保存额外配置
        break;

      case CloudBackendType.s3:
        await _writeCfg(_kS3Cfg, encodeCloudConfig(cfg));
        break;
    }
  }

  /// 激活指定类型的配置
  Future<bool> activate(CloudBackendType type) async {
    final sp = await SharedPreferences.getInstance();

    switch (type) {
      case CloudBackendType.local:
        await sp.setString(_kActiveType, 'local');
        return true;

      case CloudBackendType.piggycountCloud:
        final raw = await _readCfg(_kPiggyCountCloudCfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'piggycount_cloud');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.supabase:
        final raw = await _readCfg(_kSupabaseCfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'supabase');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.webdav:
        final raw = await _readCfg(_kWebdavCfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'webdav');
          return true;
        } catch (e) {
          return false;
        }

      case CloudBackendType.icloud:
        // iCloud 无需配置，直接激活
        await sp.setString(_kActiveType, 'icloud');
        return true;

      case CloudBackendType.s3:
        final raw = await _readCfg(_kS3Cfg);
        if (raw == null) return false;
        try {
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 's3');
          return true;
        } catch (e) {
          return false;
        }
    }
  }
}
