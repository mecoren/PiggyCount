import 'dart:convert';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'argon2_key_derivation.dart';
import 'aes_gcm_cipher.dart';
import 'ciphertext_format.dart';
import 'secure_key_storage.dart';
import '../../domain/encryption/encryption_service.dart';

/// 加密服务实现
///
/// 组合 [Argon2KeyDerivation]、[AesGcmCipher]、[SecureKeyStorage]、[CiphertextFormat]
/// 实现 [EncryptionService] 接口。
///
/// 密钥生命周期：
/// - enable: 生成 salt → 派生 key → 加密 verifier → 持久化
/// - 日常加解密: 使用内存中的 active key + active salt
/// - verifyPassword: 用输入密码派生临时 key → 解密 verifier
/// - changePassword: 验证旧密码 → 生成新 salt + key → 更新 verifier → 持久化
/// - activateKey: 内存中切换 key（用于改密流程中重加密云端密文）
class EncryptionServiceImpl implements EncryptionService {
  static const String _enabledKey = 'beecount_enc_enabled';
  static const String _verifierPlaintext = 'BEECOUNT_VERIFIER_v1';
  static const int _minPasswordLength = 6;

  final SecureKeyStorage storage;
  final Argon2KeyDerivation keyDerivation;
  final AesGcmCipher cipher;

  SharedPreferences? _prefs;

  /// 内存中当前激活的密钥（32 字节）
  List<int>? _activeKey;

  /// 内存中当前激活的 salt（16 字节）
  List<int>? _activeSalt;

  EncryptionServiceImpl({
    required this.storage,
    required this.keyDerivation,
    required this.cipher,
    SharedPreferences? prefs,
  }) : _prefs = prefs;

  Future<SharedPreferences> _getPrefs() async {
    return _prefs ??= await SharedPreferences.getInstance();
  }

  @override
  Future<bool> get isEnabled async {
    final prefs = await _getPrefs();
    return prefs.getBool(_enabledKey) ?? false;
  }

  @override
  Future<bool> get hasActiveKey async {
    // 优先检查内存中的激活密钥
    if (_activeKey != null) return true;
    // 检查 secure storage
    final stored = await storage.getKey();
    return stored != null;
  }

  @override
  List<int>? get activeSalt => _activeSalt;

  @override
  Future<void> enable({required String password}) async {
    _validatePassword(password);

    // 1. 生成新 salt
    final salt = await Argon2KeyDerivation.generateSalt();

    // 2. 派生 key
    final key = await keyDerivation.deriveKey(password: password, salt: salt);

    // 3. 加密 verifier
    final verifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: key,
    );

    // 4. 持久化
    await storage.saveKey(key);
    await storage.saveSalt(salt);
    await storage.saveVerifier(verifier);

    // 5. 激活内存密钥
    _activeKey = key;
    _activeSalt = salt;

    // 6. 标记已开启
    final prefs = await _getPrefs();
    await prefs.setBool(_enabledKey, true);
  }

  @override
  Future<void> disable() async {
    final prefs = await _getPrefs();
    await prefs.setBool(_enabledKey, false);
    // 保留 key/salt/verifier 在 secure storage（用于解密存量密文）
  }

  @override
  Future<bool> enableFromCloud({
    required String password,
    required CloudStorageService cloudStorage,
  }) async {
    _validatePassword(password);

    // 1. 探测云端文件列表
    //    失败时静默回退到 [enable]（首设备流程），符合 US-M3 探测失败回退
    final List<CloudFile> files;
    try {
      files = await cloudStorage.list(path: '');
    } catch (e) {
      // 探测失败 → 视为首设备场景，走 enable 生成新 salt
      await enable(password: password);
      return false;
    }

    // 2. 遍历文件，下载并识别第一个 ledger_*.json 的 BEECRYPT1 密文
    //    下载内容缓存到 ciphertextContent，避免重复下载
    String? ciphertextContent;
    for (final f in files) {
      final name = f.name;
      if (!name.startsWith('ledger_') || !name.endsWith('.json')) continue;
      final raw = await cloudStorage.download(path: name);
      if (raw != null && CiphertextFormat.isEncrypted(raw)) {
        ciphertextContent = raw;
        break;
      }
    }

    // 3. 云端无密文 → 回退到 enable（首设备场景）
    if (ciphertextContent == null) {
      await enable(password: password);
      return false;
    }

    // 4. 提取 salt + 派生 key + 尝试解密验证密码
    //    GCM 验证失败说明密码错误，抛 ArgumentError
    final decoded = CiphertextFormat.decode(ciphertextContent);
    final key = await keyDerivation.deriveKey(
      password: password,
      salt: decoded.salt,
    );

    try {
      await cipher.decrypt(
        encryptedBytes: decoded.encryptedBytes,
        key: key,
      );
    } catch (_) {
      throw ArgumentError('密码错误，无法加入加密');
    }

    // 5. 验证通过 → 生成 verifier 并持久化
    final verifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: key,
    );
    await storage.saveKey(key);
    await storage.saveSalt(decoded.salt);
    await storage.saveVerifier(verifier);

    // 6. 激活内存密钥 + 标记已开启
    _activeKey = key;
    _activeSalt = decoded.salt;
    final prefs = await _getPrefs();
    await prefs.setBool(_enabledKey, true);

    // 新设备加入成功，云端已是密文，调用方无需再触发全量重加密
    return true;
  }

  @override
  Future<bool> verifyPassword(String password) async {
    if (!await isEnabled) return false;

    final salt = await storage.getSalt();
    final verifier = await storage.getVerifier();
    if (salt == null || verifier == null) return false;

    // 用输入密码派生临时 key
    final tempKey = await keyDerivation.deriveKey(
      password: password,
      salt: salt,
    );

    // 尝试解密 verifier
    try {
      final decrypted = await cipher.decrypt(
        encryptedBytes: verifier,
        key: tempKey,
      );
      return utf8.decode(decrypted) == _verifierPlaintext;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  }) async {
    _validatePassword(newPassword);

    // 验证旧密码
    if (!await verifyPassword(oldPassword)) {
      throw ArgumentError('旧密码不正确');
    }

    // 生成新 salt + key
    final newSalt = await Argon2KeyDerivation.generateSalt();
    final newKey = await keyDerivation.deriveKey(
      password: newPassword,
      salt: newSalt,
    );

    // 加密新 verifier
    final newVerifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: newKey,
    );

    // 持久化
    await storage.saveKey(newKey);
    await storage.saveSalt(newSalt);
    await storage.saveVerifier(newVerifier);

    // 激活新密钥
    _activeKey = newKey;
    _activeSalt = newSalt;
  }

  @override
  Future<void> reset() async {
    await storage.clearAll();
    final prefs = await _getPrefs();
    await prefs.setBool(_enabledKey, false);
    _activeKey = null;
    _activeSalt = null;
  }

  @override
  Future<ReEncryptResult> reEncryptExistingCloudData({
    required CloudStorageService storage,
    String pathPrefix = '',
  }) async {
    // 前置检查：加密必须已开启且有可用密钥
    if (!await isEnabled) {
      throw StateError('加密未开启，无法重加密云端数据');
    }
    if (_activeKey == null) {
      await _loadActiveKeyFromStorage();
      if (_activeKey == null) {
        throw StateError('加密已开启但密钥不可用，无法重加密');
      }
    }

    // 枚举云端文件 —— list 失败无法继续，抛出原异常
    final files = await storage.list(path: pathPrefix);

    int success = 0;
    int failed = 0;
    int skipped = 0;
    final failedPaths = <String>[];

    for (final file in files) {
      final name = file.name;
      // 只处理 ledger_*.json，跳过其他文件（readme.txt / 备份等）
      if (!name.startsWith('ledger_') || !name.endsWith('.json')) {
        skipped++;
        continue;
      }

      try {
        // 下载原始数据（可能是 legacy 明文或 BEECRYPT1: 密文）
        final raw = await storage.download(path: name);
        if (raw == null) {
          // 云端文件已被删除（list 与 download 之间存在竞态）
          skipped++;
          continue;
        }

        // 先 decrypt：自动识别 legacy 明文（原样返回）或 BEECRYPT1: 密文（解密）
        // 再 encrypt：用当前激活密钥统一加密为 BEECRYPT1: 格式
        // 这样可避免对已是密文的数据双重加密
        final plaintext = await decrypt(raw);
        final reEncrypted = await encrypt(plaintext);
        await storage.upload(path: name, data: reEncrypted);
        success++;
      } catch (e) {
        // 单文件失败不中断整体流程，记录后继续
        // 可能的失败：decrypt 抛 DecryptionException（密文损坏/密码不匹配）
        //           encrypt 抛 EncryptionNotConfiguredException
        //           upload/download 抛网络异常
        failed++;
        failedPaths.add(name);
      }
    }

    return ReEncryptResult(
      success: success,
      failed: failed,
      skipped: skipped,
      failedPaths: failedPaths,
    );
  }

  @override
  Future<String> encrypt(String plaintext) async {
    final enabled = await isEnabled;
    if (!enabled) return plaintext;

    if (_activeKey == null || _activeSalt == null) {
      // 尝试从 secure storage 加载
      await _loadActiveKeyFromStorage();
      if (_activeKey == null || _activeSalt == null) {
        throw const EncryptionNotConfiguredException(
          '加密已开启但密钥不可用',
        );
      }
    }

    final encryptedBytes = await cipher.encrypt(
      plaintext: utf8.encode(plaintext),
      key: _activeKey!,
    );

    return CiphertextFormat.encode(
      salt: _activeSalt!,
      encryptedBytes: encryptedBytes,
    );
  }

  @override
  Future<String> decrypt(String ciphertext) async {
    // 非 BEECRYPT1 格式 → legacy 明文，原样返回
    if (!CiphertextFormat.isEncrypted(ciphertext)) {
      return ciphertext;
    }

    // 解析密文头获取 salt
    final decoded = CiphertextFormat.decode(ciphertext);

    // 确保有可用密钥
    if (_activeKey == null) {
      await _loadActiveKeyFromStorage();
      if (_activeKey == null) {
        throw const EncryptionNotConfiguredException(
          '需要解密但密钥不可用，请输入密码',
        );
      }
    }

    // 检查 salt 是否匹配
    // 若 _activeSalt 已知且与密文头 salt 不同，说明密钥不匹配
    if (_activeSalt != null && !_listsEqual(_activeSalt!, decoded.salt)) {
      throw const DecryptionException(
        '密文 salt 与当前密钥不匹配，可能需要重新输入密码',
      );
    }

    // 解密
    try {
      final plaintextBytes = await cipher.decrypt(
        encryptedBytes: decoded.encryptedBytes,
        key: _activeKey!,
      );
      return utf8.decode(plaintextBytes);
    } catch (e) {
      throw DecryptionException('解密失败：密码错误或数据损坏', cause: e);
    }
  }

  @override
  Future<void> activateKey({
    required String password,
    required List<int> salt,
  }) async {
    _validatePassword(password);

    if (salt.length != Argon2KeyDerivation.saltLength) {
      throw ArgumentError(
        'salt must be ${Argon2KeyDerivation.saltLength} bytes',
      );
    }

    final key = await keyDerivation.deriveKey(
      password: password,
      salt: salt,
    );

    _activeKey = key;
    _activeSalt = salt;
  }

  @override
  Future<void> persistActivatedKey() async {
    if (_activeKey == null || _activeSalt == null) {
      throw StateError('没有激活的密钥可持久化');
    }

    // 加密新 verifier
    final verifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: _activeKey!,
    );

    await storage.saveKey(_activeKey!);
    await storage.saveSalt(_activeSalt!);
    await storage.saveVerifier(verifier);
  }

  /// 从 secure storage 加载密钥到内存
  Future<void> _loadActiveKeyFromStorage() async {
    final key = await storage.getKey();
    final salt = await storage.getSalt();
    if (key != null && salt != null) {
      _activeKey = key;
      _activeSalt = salt;
    }
  }

  void _validatePassword(String password) {
    if (password.isEmpty) {
      throw ArgumentError('密码不能为空');
    }
    if (password.length < _minPasswordLength) {
      throw ArgumentError(
        '密码长度不能少于 $_minPasswordLength 字符',
      );
    }
  }

  bool _listsEqual(List<int> a, List<int> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
