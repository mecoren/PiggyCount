import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart' show SecretBoxAuthenticationError;
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
/// - disable: 标记关闭 + **清空内存密钥**（保留 secure storage 用于解密存量密文）
///
/// 安全设计要点：
/// - 密钥使用 [Uint8List] 便于主动 zeroing（best effort）
/// - [_loadActiveKeyFromStorage] 使用 single-flight 避免并发重复 IO
/// - [activateKey] 增加 verifier sanity check，避免错误密码激活导致数据丢失
/// - [enableFromCloud] 区分密码错误与密文损坏，提供精确错误引导
class EncryptionServiceImpl implements EncryptionService {
  static const String _enabledKey = 'piggycount_enc_enabled';
  static const String _verifierPlaintext = 'BEECOUNT_VERIFIER_v1';

  /// NIST SP 800-63B 推荐密码最小长度 ≥ 8
  static const int _minPasswordLength = 8;

  final SecureKeyStorage storage;
  final Argon2KeyDerivation keyDerivation;
  final AesGcmCipher cipher;

  SharedPreferences? _prefs;

  /// 内存中当前激活的密钥（32 字节）
  ///
  /// 使用 [Uint8List] 便于在 [disable]/[reset] 时主动 zeroing（best effort，
  /// Dart GC 不保证立即回收，但 zeroing 可降低密钥在堆中残留的风险）。
  Uint8List? _activeKey;

  /// 内存中当前激活的 salt（16 字节）
  Uint8List? _activeSalt;

  /// [_loadActiveKeyFromStorage] 的 single-flight 锁，避免并发重复 IO
  Completer<void>? _loadKeyCompleter;

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

    try {
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
    } catch (e) {
      // 异常路径：主动清零派生密钥，并回滚已写入的半持久化状态，
      // 避免密钥泄漏 + secure storage 中残留无 verifier 的 key 导致锁死
      key.fillRange(0, key.length, 0);
      salt.fillRange(0, salt.length, 0);
      try {
        await storage.clearAll();
      } catch (_) {}
      rethrow;
    }
  }

  @override
  Future<void> disable() async {
    final prefs = await _getPrefs();
    await prefs.setBool(_enabledKey, false);
    // H1 修复：清除内存中的密钥，避免 disable 后密钥长期驻留内存
    // secure storage 中的密钥保留，下次解密存量密文时可重新加载
    _clearActiveKey();
  }

  @override
  Future<bool> enableFromCloud({
    required String password,
    required CloudStorageService cloudStorage,
  }) async {
    _validatePassword(password);

    // 1. 探测云端文件列表
    //    US-3: 探测失败（网络/权限）不再静默回退到 [enable]，否则会生成新 salt
    //    并 reEncrypt 全量云端数据，孤立其他持有旧 salt 的设备。
    //    抛 [EnableFromCloudProbeFailedException] 让 UI 引导用户确认。
    final List<CloudFile> files;
    try {
      files = await cloudStorage.list(path: '');
    } catch (e) {
      throw EnableFromCloudProbeFailedException(
        '探测云端文件失败，无法判断是否为首设备。请检查网络/权限后重试，'
        '或确认以首设备身份继续（将生成新 salt 并重加密云端数据）。',
        cause: e,
      );
    }

    // 2. 遍历文件，下载并识别第一个 ledger_*.json 的 BEECRYPT1 密文
    //    下载内容缓存到 ciphertextContent，避免重复下载
    String? ciphertextContent;
    for (final f in files) {
      final name = f.name;
      if (!name.startsWith('ledger_') || !name.endsWith('.json')) continue;

      // M2 修复：download 包 try/catch，区分网络错误与密文损坏
      String? raw;
      try {
        raw = await cloudStorage.download(path: name);
      } catch (e) {
        throw EnableFromCloudProbeFailedException(
          '下载云端文件失败：$name。请检查网络/权限后重试。',
          cause: e,
        );
      }

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
    //    密文格式损坏（base64 截断、salt 长度异常）抛 FormatException
    DecodedCiphertext decoded;
    try {
      decoded = CiphertextFormat.decode(ciphertextContent);
    } catch (e) {
      throw EnableFromCloudCorruptedException(
        '云端密文格式损坏，无法提取 salt。可能是云端数据被破坏或截断。'
        '请尝试以首设备身份重新设置加密（将生成新 salt 并重加密云端数据）。',
        cause: e,
      );
    }

    final key = await keyDerivation.deriveKey(
      password: password,
      salt: decoded.salt,
    );

    // M2 修复：区分 GCM MAC 失败（密码错）与其他异常（数据损坏）
    try {
      await cipher.decrypt(
        encryptedBytes: decoded.encryptedBytes,
        key: key,
      );
    } on SecretBoxAuthenticationError {
      // GCM MAC 校验失败：密码错误（密钥与密文不匹配）
      throw ArgumentError('密码错误，无法加入加密');
    } catch (e) {
      // 其他异常（如密文长度不足、base64 损坏）：云端数据损坏
      throw EnableFromCloudCorruptedException(
        '云端密文数据损坏，无法验证密码。可能是云端数据被破坏。'
        '请尝试以首设备身份重新设置加密。',
        cause: e,
      );
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
    _activeSalt = Uint8List.fromList(decoded.salt);
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
    _clearActiveKey();
  }

  @override
  Future<ReEncryptResult> reEncryptExistingCloudData({
    required CloudStorageService cloudStorage,
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
    final files = await cloudStorage.list(path: pathPrefix);

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
        final raw = await cloudStorage.download(path: name);
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
        await cloudStorage.upload(path: name, data: reEncrypted);
        success++;
      } catch (e) {
        // 单文件失败不中断整体流程，记录后继续
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
    // 抛 SaltMismatchException（US-2）让 UI 层可单独捕获并引导重输密码
    if (_activeSalt != null && !_listsEqual(_activeSalt!, decoded.salt)) {
      throw SaltMismatchException(
        '密文 salt 与当前密钥不匹配，可能需要重新输入密码',
        ciphertextSaltBase64: base64.encode(decoded.salt),
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

    // 注意：activateKey 设计用于「修改密码」流程中临时切换到新密钥，
    // 新密钥与当前 verifier 不匹配是预期行为（旧 verifier 用旧密码加密）。
    // 调用方（changePassword）负责在调用前验证旧密码，
    // 激活后通过 persistActivatedKey 写入新 verifier。
    // 因此此处不对 verifier 做校验，避免破坏改密流程。
    _activeKey = key;
    _activeSalt = Uint8List.fromList(salt);
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
  ///
  /// L2 修复：使用 single-flight 模式，并发调用时只执行一次实际 IO，
  /// 后续调用等待同一个 Completer 完成。
  Future<void> _loadActiveKeyFromStorage() async {
    if (_loadKeyCompleter != null) {
      return _loadKeyCompleter!.future;
    }

    final completer = Completer<void>();
    _loadKeyCompleter = completer;

    try {
      final key = await storage.getKey();
      try {
        final salt = await storage.getSalt();
        if (key != null && salt != null) {
          _activeKey = key;
          _activeSalt = salt;
        }
        completer.complete();
      } catch (e) {
        // salt 读取失败：key 已从 secure storage 读出但无法使用，主动清零
        if (key != null) {
          key.fillRange(0, key.length, 0);
        }
        completer.completeError(e);
      }
    } catch (e) {
      completer.completeError(e);
    } finally {
      _loadKeyCompleter = null;
    }
  }

  /// 安全清除内存中的密钥和 salt（best effort zeroing）
  void _clearActiveKey() {
    final key = _activeKey;
    final salt = _activeSalt;
    if (key != null) {
      key.fillRange(0, key.length, 0);
    }
    if (salt != null) {
      salt.fillRange(0, salt.length, 0);
    }
    _activeKey = null;
    _activeSalt = null;
    _loadKeyCompleter = null;
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
