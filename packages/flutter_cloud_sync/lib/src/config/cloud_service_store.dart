import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../core/exceptions.dart';
import 'cloud_service_config.dart';

/// 云服务配置持久化存储
/// 支持类型: 本地存储、自定义 Supabase、自定义 WebDAV、iCloud、S3
///
/// P2-4 安全加固：含凭据的配置（云密码 / Supabase anonKey / WebDAV 密码 /
/// S3 SecretKey 等）统一存入 flutter_secure_storage（Android 加密
/// SharedPreferences / iOS Keychain），SharedPreferences 仅保留非敏感的
/// 激活类型标记。老版本明文数据在首次读取时自动迁移到安全存储并删除明文。
class CloudServiceStore {
  static const _kActiveType =
      'cloud_active_type'; // local | supabase | webdav | icloud | s3（历史 piggycount_cloud 落 default 回退本地）
  static const _kSupabaseCfg = 'cloud_supabase_cfg';
  static const _kWebdavCfg = 'cloud_webdav_cfg';
  static const _kS3Cfg = 'cloud_s3_cfg';

  /// M11：loadActive 解析失败的结构化痕迹。
  ///
  /// 配置损坏时 loadActive 会静默回退 localStorage（自动同步无声停摆，
  /// 只有 debugPrint 可查）。这里记录失败的后端类型与原因，供 App 层
  /// 在云页面以 banner 呈现「配置已损坏，请重新配置」。成功解析、切到
  /// local 或保存新配置时清除。进程重启后若配置仍损坏会再次记录，
  /// 因此无需持久化。
  static String? lastLoadErrorBackend;
  static String? lastLoadErrorMessage;

  /// SEC-03：明文迁移失败的结构化痕迹（凭据仍残留明文 SharedPreferences）。
  ///
  /// _readCfg 旧明文迁移到安全存储失败时记录（key + 原因）。凭据会无限期
  /// 残留在明文 prefs 里（迁移失败不阻塞读取——数据可用即工作），此前仅
  /// debugPrint 无任何可见告警。App 层可据此在云页面提示用户「凭据迁移
  /// 失败，建议重新保存配置以完成安全迁移」。迁移成功、或 _writeCfg
  /// 写入成功清除明文时清除。
  static String? lastMigrationErrorKey;
  static String? lastMigrationErrorMessage;

  /// 清除加载错误痕迹（App 层在用户重新配置成功后调用亦可）。
  static void clearLoadError() {
    lastLoadErrorBackend = null;
    lastLoadErrorMessage = null;
  }

  /// 清除迁移失败痕迹（迁移成功 / 新配置写入并清掉明文残留时）。
  static void clearMigrationError() {
    lastMigrationErrorKey = null;
    lastMigrationErrorMessage = null;
  }

  static void _recordLoadError(String backend, Object e) {
    debugPrint('Config parse failed for $backend: $e');
    lastLoadErrorBackend = backend;
    lastLoadErrorMessage = e.toString();
  }

  static void _recordMigrationError(String key, Object e) {
    debugPrint('Secure storage migration failed for $key: $e');
    lastMigrationErrorKey = key;
    lastMigrationErrorMessage = e.toString();
  }

  /// 安全存储实例。Android 侧默认即加密存储
  /// （flutter_secure_storage 10 起弃用 EncryptedSharedPreferences，改用自带 cipher，
  /// 故不再需要显式 aOptions）。
  /// 构造注入（P1）：测试可替换为损坏/假实现验证硬失败语义。
  final FlutterSecureStorage _secure;

  CloudServiceStore({FlutterSecureStorage? secureStorage})
      : _secure = secureStorage ?? const FlutterSecureStorage();

  /// 读取配置 JSON：优先安全存储；SharedPreferences 仅作旧版本明文
  /// 数据的迁移回退（读到后迁移到安全存储并删除明文）。
  ///
  /// 审计 M16：安全存储【读失败】（keystore 损坏 / Keychain 系统级不可用）
  /// 与「未配置」（read 正常返回 null）是两类完全不同的状态，绝不能混同：
  /// 旧实现把读失败仅 debugPrint 后当 null 处理，loadActive 据此静默回退
  /// localStorage —— 自动同步无声停摆，用户毫无感知，多端数据悄然分叉。
  /// 现在：读失败且无旧明文可兜底时抛 [CloudStorageException]，由调用方
  /// 显式呈现（activeCloudConfigProvider → 损坏 banner / 同步链路报错）；
  /// 仍有旧明文可读时按迁移路径继续 —— 数据可用即工作，不算停摆。
  Future<String?> _readCfg(String key) async {
    Object? secureReadError;
    try {
      final secure = await _secure.read(key: key);
      if (secure != null) return secure;
    } catch (e) {
      debugPrint('Secure storage read failed for $key: $e');
      secureReadError = e;
    }
    final sp = await SharedPreferences.getInstance();
    final legacy = sp.getString(key);
    if (legacy != null) {
      // 旧明文数据迁移（尽力而为，失败不阻塞读取）
      try {
        await _secure.write(key: key, value: legacy);
        await sp.remove(key);
        debugPrint('Migrated config $key from plaintext prefs to secure storage');
        // SEC-03：本次迁移成功即清除失败痕迹（上次失败本次成功的自愈）
        clearMigrationError();
      } catch (e) {
        // SEC-03：迁移失败 → 结构化痕迹（凭据仍残留明文 prefs，App 层
        // 须可见），不再只 debugPrint 无告警
        _recordMigrationError(key, e);
      }
      return legacy;
    }
    // M16：读失败且无明文兜底 → 显式报错（区别于「未配置」的正常 null）
    if (secureReadError != null) {
      throw CloudStorageException(
        '安全存储读取失败，云配置不可访问（自动同步已停止，'
        '请修复设备安全存储后重启应用或重新配置）: $key',
        secureReadError,
      );
    }
    return null;
  }

  /// 写入配置 JSON 到安全存储。
  ///
  /// P1 安全底线：secure storage 写失败时【硬失败】抛异常，绝不降级
  /// 明文 SharedPreferences——凭据明文落盘的风险 > 保存失败的不便。
  /// 调用方（设置页保存/登录流程）应 catch 并向用户提示。
  Future<void> _writeCfg(String key, String value) async {
    try {
      await _secure.write(key: key, value: value);
    } catch (e) {
      debugPrint('Secure storage write failed for $key: $e');
      throw CloudStorageException('安全存储写入失败，云配置未保存（凭据不会以明文保存）', e);
    }
    // 写入成功后清除可能残留的历史明文
    final sp = await SharedPreferences.getInstance();
    await sp.remove(key);
    // SEC-03：明文残留已清 → 迁移失败痕迹随之失效（该 key 的凭据
    // 已安全落位，不再残留明文）
    clearMigrationError();
  }

  /// 加载当前激活的云服务配置
  ///
  /// 审计 M16：读失败（安全存储不可用）时本方法显式上抛 [CloudSyncException]
  /// —— 不再静默回退 localStorage。调用方：
  /// - `activeCloudConfigProvider`（App 层）catch 后转损坏 banner 并继续上抛；
  /// - `main.dart` 等直连调用点已有 try/catch 留痕。
  Future<CloudServiceConfig> loadActive() async {
    final sp = await SharedPreferences.getInstance();
    final activeType = sp.getString(_kActiveType) ?? 'local';

    // 成功路径（含 local）先清除历史错误，避免陈旧 banner 常驻
    CloudServiceStore.clearLoadError();

    switch (activeType) {
      case 'local':
        return CloudServiceConfig.localStorage();

      case 'supabase':
        return _loadActiveBackendConfig(activeType, _kSupabaseCfg);

      case 'webdav':
        return _loadActiveBackendConfig(activeType, _kWebdavCfg);

      case 'icloud':
        // iCloud 无需额外配置，返回 iCloud 类型的配置
        return const CloudServiceConfig(
          type: CloudBackendType.icloud,
          name: 'iCloud',
        );

      case 's3':
        return _loadActiveBackendConfig(activeType, _kS3Cfg);

      default:
        return CloudServiceConfig.localStorage();
    }
  }

  /// 读取并解析激活后端的配置（M11 + M16 双语义收口）。
  ///
  /// - 配置不存在（read 正常返回 null）→ 回退 localStorage（未配置）
  /// - 配置损坏（解析失败）→ 记录痕迹（M11 banner）+ 回退 localStorage
  /// - 配置不可读（M16 安全存储故障）→ 记录痕迹 + 显式上抛，绝不静默
  ///   伪装成「本地模式」—— 同步链路与 UI 必须感知失败
  Future<CloudServiceConfig> _loadActiveBackendConfig(
      String activeType, String key) async {
    final String raw;
    try {
      raw = await _readCfg(key) ?? '';
    } catch (e) {
      _recordLoadError(activeType, e);
      rethrow; // M16：显式报错，由上层转 banner / 同步链路感知
    }
    if (raw.isNotEmpty) {
      try {
        return decodeCloudConfig(raw);
      } catch (e) {
        _recordLoadError(activeType, e); // M11：解析损坏 → banner + 回退
      }
    }
    // 未配置或解析损坏：回退到本地存储
    return CloudServiceConfig.localStorage();
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
    // M11：用户重新保存配置 = 损坏配置被替换，清除错误痕迹
    CloudServiceStore.clearLoadError();

    switch (cfg.type) {
      case CloudBackendType.local:
        await sp.setString(_kActiveType, 'local');
        // Provider 会在下次使用时自动初始化
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

      case CloudBackendType.supabase:
        try {
          final raw = await _readCfg(_kSupabaseCfg);
          if (raw == null) return false;
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'supabase');
          return true;
        } catch (e) {
          debugPrint('Activate supabase config failed: $e');
          return false;
        }

      case CloudBackendType.webdav:
        try {
          final raw = await _readCfg(_kWebdavCfg);
          if (raw == null) return false;
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 'webdav');
          return true;
        } catch (e) {
          debugPrint('Activate webdav config failed: $e');
          return false;
        }

      case CloudBackendType.icloud:
        // iCloud 无需配置，直接激活
        await sp.setString(_kActiveType, 'icloud');
        return true;

      case CloudBackendType.s3:
        try {
          final raw = await _readCfg(_kS3Cfg);
          if (raw == null) return false;
          final cfg = decodeCloudConfig(raw);
          if (!cfg.valid) return false;
          await sp.setString(_kActiveType, 's3');
          return true;
        } catch (e) {
          debugPrint('Activate s3 config failed: $e');
          return false;
        }
    }
  }
}
