import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

/// 同步加密服务抽象接口
///
/// 定义 E2EE 同步加密的核心契约：密码管理、加解密、密钥生命周期。
/// 实现见 [EncryptionServiceImpl]。
///
/// 设计要点：
/// - 日常加解密直接使用 secure storage 中的密钥，无需密码
/// - 修改密码/验证密码时需用户输入密码，派生临时密钥后与 verifier 校验
/// - encrypt/decrypt 自动识别明文/密文，支持向后兼容
abstract class EncryptionService {
  /// 重加密云端所有账本备份
  ///
  /// 用于「开启加密后立即全量重加密」场景：
  /// 遍历云端所有 `ledger_*.json` 文件，下载后用当前激活密钥重新加密并上传。
  /// - 下载时自动识别 legacy 明文 / BEECRYPT1: 密文，统一返回明文
  /// - 上传时用当前激活密钥统一加密为 BEECRYPT1: 格式
  ///
  /// 单文件失败不中断整体流程，最终汇总 success/failed/skipped 计数。
  /// list 操作失败时抛出原异常（无法枚举文件就无法继续）。
  ///
  /// 抛出 [StateError] 当加密未开启或无激活密钥。
  Future<ReEncryptResult> reEncryptExistingCloudData({
    required CloudStorageService storage,
    String pathPrefix = '',
  });

  /// 加密是否已开启
  Future<bool> get isEnabled;

  /// 当前是否有可用密钥（已开启加密且 secure storage 中存在密钥）
  Future<bool> get hasActiveKey;

  /// 开启加密
  ///
  /// 1. 生成 16 字节随机 salt
  /// 2. 用 Argon2id(password, salt) 派生 256 位密钥
  /// 3. 加密固定明文 "BEECOUNT_VERIFIER_v1" 作为校验块
  /// 4. 持久化密钥 + 校验块到 secure storage
  /// 5. 标记加密已开启
  ///
  /// 抛出 [ArgumentError] 当密码为空或过短（< 6 字符）
  ///
  /// 注意：本方法总是生成新 salt，适用于「首设备开启」场景。
  /// 多设备加入（设备 B 输入已有密码加入）请用 [enableFromCloud]，
  /// 它会从云端密文头提取 salt，避免 salt 不匹配导致解密失败。
  Future<void> enable({required String password});

  /// 从云端已有密文提取 salt，配合用户密码派生 key 并验证
  ///
  /// 多设备加入流程（设备 B 首次输入与设备 A 相同的密码）：
  /// 1. 列出 [cloudStorage] 根目录下的文件
  ///    - 列举失败 → 回退到 [enable] 流程（探测失败，视为首设备）
  /// 2. 找到第一个 `ledger_*.json` 且为 BEECRYPT1 密文的文件
  ///    - 全部为 legacy 明文或无文件 → 回退到 [enable] 流程（首设备场景）
  /// 3. `CiphertextFormat.decode` 提取 salt
  /// 4. `Argon2id(password, salt)` 派生临时 key
  /// 5. `AesGcmCipher.decrypt` 尝试解密该密文以验证密码
  ///    - GCM 验证失败 → 抛 [ArgumentError]（密码错误），不写 secure storage
  /// 6. 验证通过 → 加密 verifier + 持久化 key/salt/verifier + 标记 enabled
  ///
  /// [cloudStorage] 必须是**未装饰的原始 storage**（不能是
  /// [EncryptedCloudStorageService]），因为本方法需要下载密文字符串本身
  /// 来提取 salt，而非解密后的明文。
  ///
  /// 返回值：
  /// - true：从云端密文提取 salt 成功加入（新设备场景），云端已是密文，
  ///         调用方**无需**再触发全量重加密
  /// - false：云端无密文或探测失败，已回退到 [enable] 生成新 salt（首设备场景），
  ///          调用方应触发全量重加密覆盖云端存量明文
  ///
  /// 抛出：
  /// - [ArgumentError]：密码为空/过短/解密验证失败（密码错误）
  /// - 网络/云存储异常（download 阶段）：透传给调用方
  Future<bool> enableFromCloud({
    required String password,
    required CloudStorageService cloudStorage,
  });

  /// 关闭加密
  ///
  /// 采用「仅停止加密新上传，旧密文保留」策略：
  /// - 标记加密未开启
  /// - 保留 secure storage 中的密钥（用于解密存量密文）
  Future<void> disable();

  /// 验证密码是否正确
  ///
  /// 用 [password] 派生临时密钥，尝试解密 verifier 校验块。
  /// 成功表示密码正确。
  /// 若加密未开启或无 verifier，返回 false。
  Future<bool> verifyPassword(String password);

  /// 修改密码
  ///
  /// 1. 验证旧密码
  /// 2. 生成新 salt + 派生新密钥
  /// 3. 更新 verifier 校验块
  /// 4. 持久化新密钥 + 新 verifier
  ///
  /// 注意：此方法只更新本地密钥，不负责重新加密云端已有密文。
  /// 云端密文重加密由调用方（如 UI 层）协调，配合 [activateKey] 使用。
  ///
  /// 抛出 [ArgumentError] 当旧密码错误或新密码无效
  Future<void> changePassword({
    required String oldPassword,
    required String newPassword,
  });

  /// 重置加密（清空密钥和配置）
  ///
  /// 删除 secure storage 中的密钥和 verifier，标记加密未开启。
  /// 注意：此方法不删除云端密文，云端清理由调用方负责。
  Future<void> reset();

  /// 加密明文
  ///
  /// - 加密已开启且密钥可用：返回 `BEECRYPT1:` 格式密文
  /// - 加密未开启：返回原文（向后兼容）
  ///
  /// 抛出 [EncryptionNotConfiguredException] 当加密已开启但密钥不可用
  Future<String> encrypt(String plaintext);

  /// 解密密文
  ///
  /// - 输入为 `BEECRYPT1:` 格式密文：解密返回明文
  /// - 输入为 legacy 明文（无 magic header）：原样返回
  ///
  /// 抛出 [DecryptionException] 当解密失败（密码错、数据损坏、密钥不匹配）
  /// 抛出 [EncryptionNotConfiguredException] 当密文需要解密但密钥不可用
  Future<String> decrypt(String ciphertext);

  /// 在内存中激活指定密码派生的密钥（不持久化）
  ///
  /// 用于「修改密码」流程中临时切换到新密钥：
  /// 调用方在重加密云端密文前先用新密码激活密钥，
  /// 后续 encrypt 自动使用新密钥，完成后调 [persistActivatedKey] 持久化。
  ///
  /// 抛出 [ArgumentError] 当密码无效
  Future<void> activateKey({required String password, required List<int> salt});

  /// 持久化当前内存中激活的密钥到 secure storage
  ///
  /// 用于 [activateKey] 之后的收尾步骤。
  /// 若当前无激活密钥，抛出 [StateError]。
  Future<void> persistActivatedKey();

  /// 获取当前激活密钥对应的 salt
  ///
  /// 用于加密时把 salt 写入密文头。
  /// 若无激活密钥，返回 null。
  List<int>? get activeSalt;
}

/// 解密失败异常
class DecryptionException implements Exception {
  final String message;
  final Object? cause;

  const DecryptionException(this.message, {this.cause});

  @override
  String toString() => 'DecryptionException: $message';
}

/// Salt 不匹配异常（US-2）
///
/// 多设备同步场景：设备 B 本地密钥的 salt 与云端密文头中的 salt 不一致，
/// 说明设备 B 的密码可能错误或密钥已过期，需要引导用户重新输入密码。
///
/// 继承自 [DecryptionException]，保证已有 `catch DecryptionException` 的
/// 代码仍能捕获；UI 层可单独 `catch SaltMismatchException` 触发密码重输流程。
class SaltMismatchException extends DecryptionException {
  /// 密文头中携带的 salt（base64），供 UI 层提示或调用 activateKey 使用
  final String ciphertextSaltBase64;

  const SaltMismatchException(
    String message, {
    required this.ciphertextSaltBase64,
    Object? cause,
  }) : super(message, cause: cause);

  @override
  String toString() => 'SaltMismatchException: $message';
}

/// enableFromCloud 探测失败异常（US-3）
///
/// 设备 B 加入时云端探测失败（网络/权限），不应静默回退到 [EncryptionService.enable]，
/// 否则会生成新 salt 并 reEncrypt 全量云端数据，孤立其他持有旧 salt 的设备。
///
/// UI 层应 catch 此异常并提示用户确认：
/// - 用户确认"以首设备身份继续" → 调用 [EncryptionService.enable] + reEncrypt
/// - 用户选择"重试" → 重新调用 [EncryptionService.enableFromCloud]
class EnableFromCloudProbeFailedException implements Exception {
  final String message;
  final Object? cause;

  const EnableFromCloudProbeFailedException(this.message, {this.cause});

  @override
  String toString() => 'EnableFromCloudProbeFailedException: $message';
}

/// 加密未配置异常
///
/// 加密已开启但密钥不可用时抛出。
class EncryptionNotConfiguredException implements Exception {
  final String message;

  const EncryptionNotConfiguredException(this.message);

  @override
  String toString() => 'EncryptionNotConfiguredException: $message';
}

/// 重加密云端数据的结果
class ReEncryptResult {
  /// 成功重加密的文件数
  final int success;

  /// 处理失败的文件数（download/upload 抛异常）
  final int failed;

  /// 被跳过的文件数（非 ledger_*.json 或 download 返回 null）
  final int skipped;

  /// 失败文件的路径列表（用于上层提示用户）
  final List<String> failedPaths;

  const ReEncryptResult({
    required this.success,
    required this.failed,
    required this.skipped,
    required this.failedPaths,
  });

  @override
  String toString() =>
      'ReEncryptResult(success: $success, failed: $failed, skipped: $skipped)';
}
