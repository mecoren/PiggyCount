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
import '../../services/system/logger_service.dart';

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
    bool allowFallbackToEnable = true,
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
      // 401/403 认证失败与网络故障分流通：认证错误重试无效，
      // 需引导用户修正云存储凭据（新设备 WebDAV 密码输错的核心场景）
      if (_isAuthError(e)) {
        throw EnableFromCloudAuthException(
          '云端认证失败（账号或密码错误），请到云服务页修正配置后重试',
          cause: e,
        );
      }
      throw EnableFromCloudProbeFailedException(
        '探测云端文件失败，无法判断是否为首设备。请检查网络/权限后重试，'
        '或确认以首设备身份继续（将生成新 salt 并重加密云端数据）。',
        cause: e,
      );
    }

    // 2. 遍历文件，下载所有 ledger_*.json 的 BEECRYPT1 密文。
    //    注意：不能只取第一个密文验证密码——当云端存在「混合 salt」
    //    （A 设备改密时部分文件重加密失败/未重加密，或部分文件被
    //    其他设备用不同密码加密）时，第一个密文可能是旧 salt，
    //    用新密码派生 key 解密会 GCM MAC 失败，导致「输入正确密码
    //    仍报密码错误」。应收集全部密文，逐个尝试验证，只要有一个
    //    能用输入密码解密成功，即认为密码正确（用该密文的 salt 激活）。
    final ciphertextCandidates = <String>[];
    for (final f in files) {
      final name = f.name;
      if (!name.startsWith('ledger_') || !name.endsWith('.json')) continue;

      // M2 修复：download 包 try/catch，区分网络错误与密文损坏
      String? raw;
      try {
        raw = await cloudStorage.download(path: name);
      } catch (e) {
        // 认证失败与 list 探测同款分流逻辑
        if (_isAuthError(e)) {
          throw EnableFromCloudAuthException(
            '云端认证失败（账号或密码错误），请到云服务页修正配置后重试',
            cause: e,
          );
        }
        throw EnableFromCloudProbeFailedException(
          '下载云端文件失败：$name。请检查网络/权限后重试。',
          cause: e,
        );
      }

      if (raw != null && CiphertextFormat.isEncrypted(raw)) {
        ciphertextCandidates.add(raw);
      }
    }

    // 3. 云端无密文 → 默认回退到 enable（首设备场景）；
    //    但 salt_mismatch 恢复场景（allowFallbackToEnable=false）禁止回退：
    //    此时本地已确认云端存在密文，若 list 探测不到 ledger_*.json 密文
    //    （文件名不匹配/路径前缀等），回退 enable 会生成全新的随机 salt，
    //    本地密钥与云端密文永远不匹配，导致后续 getStatus 持续
    //    salt_mismatch_need_password（用户输入正确密码仍报"密钥不匹配"）。
    //    应抛探测失败异常让 UI 明确提示，而非静默污染本地密钥。
    if (ciphertextCandidates.isEmpty) {
      if (!allowFallbackToEnable) {
        throw EnableFromCloudProbeFailedException(
          '云端未找到可恢复的加密备份（ledger_*.json 密文），'
          '无法从云端提取 salt。请检查云端数据后重试。',
        );
      }
      await enable(password: password);
      return false;
    }

    // 4. 遍历所有密文，逐个提取 salt + 派生 key + 尝试解密验证密码。
    //    只要有一个密文能用输入密码解密成功，即认为密码正确，
    //    并用该密文的 salt 激活（与云端实际使用的 salt 保持一致）。
    //    若全部失败：
    //    - 任一密文格式损坏（base64 截断、salt 长度异常）抛
    //      EnableFromCloudCorruptedException（数据损坏，与密码无关）
    //    - 全部为 GCM MAC 失败 → 密码错误（ArgumentError）
    // 记录首个格式损坏错误（数据损坏，与密码无关）
    String? lastFormatError;
    // 是否发生过 GCM MAC 校验失败（密码错误特征）
    var sawAuthError = false;
    DecodedCiphertext? activatedDecoded;
    Uint8List? activatedKey;

    for (final candidate in ciphertextCandidates) {
      DecodedCiphertext decoded;
      try {
        decoded = CiphertextFormat.decode(candidate);
      } catch (e) {
        // 记录首个格式错误，继续尝试其他密文
        lastFormatError ??= e.toString();
        continue;
      }

      final key = await keyDerivation.deriveKey(
        password: password,
        salt: decoded.salt,
      );

      try {
        await cipher.decrypt(
          encryptedBytes: decoded.encryptedBytes,
          key: key,
        );
      } on SecretBoxAuthenticationError {
        // GCM MAC 校验失败：该密文非此密码加密，记录并尝试下一个
        sawAuthError = true;
        continue;
      } catch (e) {
        // 其他异常（如密文长度不足、base64 损坏）：记录首个，继续尝试
        lastFormatError ??= e.toString();
        continue;
      }

      // 验证通过：记录该密文的 salt/key，跳出循环
      activatedDecoded = decoded;
      activatedKey = key;
      break;
    }

    if (activatedDecoded == null || activatedKey == null) {
      // 所有密文都验证失败
      if (lastFormatError != null && !sawAuthError) {
        // 全部是格式损坏（无任何 MAC 校验失败）→ 云端数据损坏
        throw EnableFromCloudCorruptedException(
          '云端密文数据损坏，无法验证密码。可能是云端数据被破坏。'
          '请尝试以首设备身份重新设置加密。',
          cause: FormatException(lastFormatError),
        );
      }
      // 至少一个密文 GCM MAC 校验失败 → 密码错误
      throw ArgumentError('密码错误，无法加入加密');
    }

    // 5. 验证通过 → 生成 verifier 并持久化
    final verifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: activatedKey,
    );
    await storage.saveKey(activatedKey);
    await storage.saveSalt(activatedDecoded.salt);
    await storage.saveVerifier(verifier);

    // 6. 激活内存密钥 + 标记已开启
    _activeKey = activatedKey;
    _activeSalt = Uint8List.fromList(activatedDecoded.salt);
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
  Future<ReEncryptResult> changePasswordWithCloudReEncryption({
    required String oldPassword,
    required String newPassword,
    required CloudStorageService cloudStorage,
  }) async {
    _validatePassword(newPassword);

    // 1. 验证旧密码
    if (!await verifyPassword(oldPassword)) {
      throw ArgumentError('旧密码不正确');
    }

    // 2. 确保旧密钥已加载到内存（用于解密云端存量密文）
    if (_activeKey == null || _activeSalt == null) {
      await _loadActiveKeyFromStorage();
      if (_activeKey == null || _activeSalt == null) {
        throw StateError('加密已开启但密钥不可用，无法重加密');
      }
    }
    // 快照旧密钥/salt（后续不可再访问 _activeKey/_activeSalt 读取旧值）
    final oldKey = Uint8List.fromList(_activeKey!);
    final oldSalt = Uint8List.fromList(_activeSalt!);

    // 3. 生成新 salt + key
    final newSalt = await Argon2KeyDerivation.generateSalt();
    final newKey = await keyDerivation.deriveKey(
      password: newPassword,
      salt: newSalt,
    );

    // 4. 遍历云端文件：用旧密钥解密 → 用新密钥加密 → 上传
    //    在激活新密钥之前完成，确保解密用的是旧密钥
    final result = await _reEncryptCloudDataWithKeys(
      cloudStorage: cloudStorage,
      oldKey: oldKey,
      oldSalt: oldSalt,
      newKey: newKey,
      newSalt: newSalt,
    );

    // SYNC-13：部分文件重加密失败时必须中止改密。若照常激活新密钥，
    // 云端将出现「部分旧密钥 + 部分新密钥」混合快照，旧密钥副本永久
    // 不可解密（选择性数据丢失）。处理：
    // ① 把已成功重加密的文件反向回滚为旧密钥密文，恢复云端一致；
    // ② 不保存/不激活新密钥，旧密码继续有效；
    // ③ 抛专属异常供 UI 明确告知用户失败文件清单。
    if (result.failed > 0) {
      LoggerService().warning('CloudReEncrypt',
          '改密重加密部分失败(${result.failed} 个)，开始回滚已重加密文件并中止改密');
      final rollbackFailed = await _rollbackReEncryptedFiles(
        cloudStorage: cloudStorage,
        oldKey: oldKey,
        oldSalt: oldSalt,
        newKey: newKey,
        newSalt: newSalt,
        successPaths: result.successPaths,
      );
      // 主动 zeroing 新密钥材料（改密未生效）
      newKey.fillRange(0, newKey.length, 0);
      throw ReEncryptPartialFailureException(
        failedPaths: result.failedPaths,
        rollbackFailedPaths: rollbackFailed,
      );
    }

    // 5. 加密新 verifier
    final newVerifier = await cipher.encrypt(
      plaintext: utf8.encode(_verifierPlaintext),
      key: newKey,
    );

    // 6. 持久化新密钥/salt/verifier
    await storage.saveKey(newKey);
    await storage.saveSalt(newSalt);
    await storage.saveVerifier(newVerifier);

    // 7. 激活新密钥
    _activeKey = newKey;
    _activeSalt = newSalt;

    // 主动 zeroing 旧密钥快照（best effort）
    oldKey.fillRange(0, oldKey.length, 0);

    return result;
  }

  /// 用显式 oldKey/newKey 重加密云端文件（缺陷 A 修复核心）
  ///
  /// 与 [reEncryptExistingCloudData] 的区别：
  /// - [reEncryptExistingCloudData] 用当前 active key 既解密又加密（无法用于密钥轮换）
  /// - 本方法用 oldKey 解密旧密文、用 newKey 加密为新密文，专为密钥轮换设计
  ///
  /// 流程：遍历 `ledger_*.json` → 下载 → 用 oldKey 解密 → 用 newKey 加密 → 上传
  /// - 跳过 legacy 明文（非 BEECRYPT1: 格式）：后续 sync 会自动加密
  /// - salt 不匹配 oldSalt 的密文：跳过（无法解密），计入 failed
  /// - 单文件失败不中断整体流程
  Future<ReEncryptResult> _reEncryptCloudDataWithKeys({
    required CloudStorageService cloudStorage,
    required Uint8List oldKey,
    required Uint8List oldSalt,
    required Uint8List newKey,
    required Uint8List newSalt,
    String pathPrefix = '',
  }) async {
    final files = await cloudStorage.list(path: pathPrefix);

    int success = 0;
    int failed = 0;
    int skipped = 0;
    final failedPaths = <String>[];
    final successPaths = <String>[];

    for (final file in files) {
      final name = file.name;
      if (!name.startsWith('ledger_') || !name.endsWith('.json')) {
        skipped++;
        continue;
      }

      try {
        final raw = await cloudStorage.download(path: name);
        if (raw == null) {
          skipped++;
          continue;
        }

        // 跳过 legacy 明文：后续首次 sync 时会被新密钥加密
        if (!CiphertextFormat.isEncrypted(raw)) {
          skipped++;
          continue;
        }

        final decoded = CiphertextFormat.decode(raw);

        // salt 必须与 oldSalt 匹配才能用 oldKey 解密
        if (!_listsEqual(oldSalt, decoded.salt)) {
          // salt 不匹配（可能已被其他设备用不同密钥加密），无法解密
          failed++;
          failedPaths.add(name);
          continue;
        }

        // 用旧密钥解密
        final plaintextBytes = await cipher.decrypt(
          encryptedBytes: decoded.encryptedBytes,
          key: oldKey,
        );

        // 用新密钥加密
        final newEncryptedBytes = await cipher.encrypt(
          plaintext: plaintextBytes,
          key: newKey,
        );
        final newCiphertext = CiphertextFormat.encode(
          salt: newSalt,
          encryptedBytes: newEncryptedBytes,
        );
        await cloudStorage.upload(path: name, data: newCiphertext);
        success++;
        successPaths.add(name);
      } catch (e) {
        failed++;
        failedPaths.add(name);
      }
    }

    return ReEncryptResult(
      success: success,
      failed: failed,
      skipped: skipped,
      failedPaths: failedPaths,
      successPaths: successPaths,
    );
  }

  /// SYNC-13 回滚：把已用 newKey/newSalt 重加密的云端文件反向恢复为
  /// oldKey/oldSalt 密文，使改密中止后云端回到「全旧密钥」一致状态。
  ///
  /// 单文件回滚失败不中断其余文件，失败清单由调用方并入异常信息。
  /// 返回回滚仍失败的文件路径列表（空 = 云端已完全恢复旧密钥一致）。
  Future<List<String>> _rollbackReEncryptedFiles({
    required CloudStorageService cloudStorage,
    required Uint8List oldKey,
    required Uint8List oldSalt,
    required Uint8List newKey,
    required Uint8List newSalt,
    required List<String> successPaths,
  }) async {
    final rollbackFailed = <String>[];

    for (final name in successPaths) {
      try {
        final raw = await cloudStorage.download(path: name);
        if (raw == null || !CiphertextFormat.isEncrypted(raw)) {
          rollbackFailed.add(name);
          continue;
        }
        final decoded = CiphertextFormat.decode(raw);
        // salt 与 newSalt 不匹配说明该文件已被其他进程改动，不可盲目覆盖
        if (!_listsEqual(newSalt, decoded.salt)) {
          rollbackFailed.add(name);
          continue;
        }
        final plaintextBytes = await cipher.decrypt(
          encryptedBytes: decoded.encryptedBytes,
          key: newKey,
        );
        final oldEncryptedBytes = await cipher.encrypt(
          plaintext: plaintextBytes,
          key: oldKey,
        );
        await cloudStorage.upload(
          path: name,
          data: CiphertextFormat.encode(
            salt: oldSalt,
            encryptedBytes: oldEncryptedBytes,
          ),
        );
      } catch (e) {
        LoggerService().error('CloudReEncrypt', '回滚文件失败: $name', e);
        rollbackFailed.add(name);
      }
    }

    return rollbackFailed;
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

    // 确保有可用密钥和 salt
    // 同时检查 key 和 salt：若任一缺失则从 storage 加载（两者总是一起加载）。
    // 修复缺陷 F：原实现仅检查 _activeKey == null，当 _activeKey != null 但
    // _activeSalt == null 时（极端状态），salt 校验被短路，SaltMismatchException
    // 降级为通用 DecryptionException，UI 无法引导用户重输密码。
    if (_activeKey == null || _activeSalt == null) {
      await _loadActiveKeyFromStorage();
      if (_activeKey == null) {
        throw const EncryptionNotConfiguredException(
          '需要解密但密钥不可用，请输入密码',
        );
      }
      // 加载后 salt 仍为 null：密钥/salt 状态不一致（数据损坏）
      if (_activeSalt == null) {
        throw const DecryptionException(
          '密钥已加载但 salt 不可用，加密状态不一致',
        );
      }
    }

    // 检查 salt 是否匹配
    // 修复缺陷 F：移除 _activeSalt != null 守卫——上方已确保 salt 非 null，
    // 始终评估 SaltMismatchException 让 UI 能引导重输密码
    if (!_listsEqual(_activeSalt!, decoded.salt)) {
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
    if (password.length < EncryptionService.minPasswordLength) {
      throw ArgumentError(
        '密码长度不能少于 ${EncryptionService.minPasswordLength} 字符',
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

  /// 判断异常是否为云端认证失败（401/403）。
  ///
  /// 正常路径下 WebDAV 层直接抛 [CloudAuthException]（rawStorage 未装饰、
  /// 无中间包装）；字符串兜底覆盖被上层包装成文本的边缘情况
  /// （如 CloudConfigurationException 保留 originalError 的 toString）。
  bool _isAuthError(Object e) {
    if (e is CloudAuthException) return true;
    final s = e.toString();
    return s.contains('CloudAuthException') || s.contains('认证失败');
  }
}
