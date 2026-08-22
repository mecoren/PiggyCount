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
  /// 密码最小长度（NIST SP 800-63B 推荐 ≥ 8）
  ///
  /// UI 层（密码对话框）与服务层（enable/changePassword）必须共用此常量，
  /// 避免前后端阈值不一致导致「对话框放行但服务层抛 ArgumentError」的体验缺陷。
  static const int minPasswordLength = 8;

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
    required CloudStorageService cloudStorage,
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
  /// 抛出 [ArgumentError] 当密码为空或过短（< [minPasswordLength] 字符）
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
  /// [allowFallbackToEnable]：
  /// - true（默认）：云端无密文时回退到 [enable] 生成新 salt（首设备场景）
  /// - false：禁止回退。调用方已确定云端存在密文（如 salt_mismatch 恢复场景），
  ///   若 list 探测未找到 `ledger_*.json` 密文则抛
  ///   [EnableFromCloudProbeFailedException]，**绝不**生成新 salt——
  ///   否则本地会写入与云端不匹配的错误 salt，导致后续永远 salt_mismatch。
  ///
  /// 返回值：
  /// - true：从云端密文提取 salt 成功加入（新设备场景），云端已是密文，
  ///         调用方**无需**再触发全量重加密
  /// - false：云端无密文或探测失败，已回退到 [enable] 生成新 salt（首设备场景），
  ///          调用方应触发全量重加密覆盖云端存量明文
  ///
  /// 抛出：
  /// - [ArgumentError]：密码为空/过短/解密验证失败（密码错误）
  /// - [EnableFromCloudProbeFailedException]：list/download 探测失败，
  ///   或 [allowFallbackToEnable] 为 false 时云端未找到密文
  /// - 网络/云存储异常（download 阶段）：透传给调用方
  Future<bool> enableFromCloud({
    required String password,
    required CloudStorageService cloudStorage,
    bool allowFallbackToEnable = true,
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

  /// 修改密码并内联重加密云端存量密文（缺陷 A 修复）
  ///
  /// 与 [changePassword] 不同，本方法在密钥轮换前先用旧密钥解密云端所有
  /// `ledger_*.json` 密文，再用新密钥重新加密上传，最后才激活新密钥。
  /// 这样保证改密后云端密文仍可用新密码解密，避免数据可用性致命缺陷。
  ///
  /// 流程：
  /// 1. 验证旧密码
  /// 2. 确保旧密钥已加载到内存（用于解密存量密文）
  /// 3. 生成新 salt + 派生新密钥
  /// 4. 遍历云端文件：用旧密钥解密 → 用新密钥加密 → 上传
  /// 5. 加密新 verifier + 持久化新密钥/salt/verifier
  /// 6. 激活新密钥
  ///
  /// [cloudStorage] 必须是**未装饰的原始 storage**（理由同
  /// [reEncryptExistingCloudData]），否则会双重加密。
  ///
  /// 返回 [ReEncryptResult] 汇总重加密结果。即使部分文件失败也会完成
  /// 密钥轮换（否则用户被锁死在旧密码），调用方应据 failed 字段提示用户
  /// "部分文件未能重加密，建议保持联网完成一次完整同步"。
  ///
  /// 抛出 [ArgumentError] 当旧密码错误或新密码无效
  Future<ReEncryptResult> changePasswordWithCloudReEncryption({
    required String oldPassword,
    required String newPassword,
    required CloudStorageService cloudStorage,
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

/// enableFromCloud 探测阶段认证失败异常（WebDAV 401/403）
///
/// 云端存储凭据错误（底层抛 CloudAuthException）。与网络故障
/// （[EnableFromCloudProbeFailedException]）的本质区别：重试无法解决，
/// 必须引导用户到云服务页修正 WebDAV 账号/密码后再试。
/// UI 层应 catch 此异常并引导跳转云服务配置页，而非提示「检查网络」。
class EnableFromCloudAuthException implements Exception {
  final String message;
  final Object? cause;

  const EnableFromCloudAuthException(this.message, {this.cause});

  @override
  String toString() => 'EnableFromCloudAuthException: $message';
}

/// enableFromCloud 云端密文损坏异常
///
/// 云端密文格式损坏（base64 截断、salt 长度异常、payload 损坏），
/// 无法提取 salt 或验证密码。UI 层应提示用户以首设备身份重新设置加密。
class EnableFromCloudCorruptedException implements Exception {
  final String message;
  final Object? cause;

  const EnableFromCloudCorruptedException(this.message, {this.cause});

  @override
  String toString() => 'EnableFromCloudCorruptedException: $message';
}

/// 云端为密文但本地未开启加密异常（BUG-2 残留修复）
///
/// 多设备 split-brain 子场景：设备 B 从未开启加密（或已 reset 清空密钥），
/// 拉取云端时发现 `BEECRYPT1:` 密文，但本地无可用密钥解密。此时 provider 未被
/// [EncryptedCloudProvider] 装饰（装饰前提是 `isEnabled==true`），密文不会被
/// [EncryptionService.decrypt] 处理，因而**永不触发** [SaltMismatchException] 哨兵，
/// 旧实现会静默跳过让用户误以为云端无数据。
///
/// 与 [SaltMismatchException] 的区别：
/// - [SaltMismatchException]：已开启加密但密钥 salt 与密文不匹配（密钥过期/密码错）
/// - 本异常：根本未开启加密 / 无密钥，需引导用户走「开启加密 → enableFromCloud」流程
///
/// UI 层应 catch 本异常（或识别哨兵 message `cloud_encrypted_locally_disabled`），
/// 调用 `promptPasswordAndActivate` 引导用户输入原密码从云端提取 salt 激活密钥。
class CloudEncryptedLocallyDisabledException implements Exception {
  final String message;
  final Object? cause;

  const CloudEncryptedLocallyDisabledException(this.message, {this.cause});

  @override
  String toString() => 'CloudEncryptedLocallyDisabledException: $message';
}

/// 云端密文损坏/密钥错配异常（SYNC-10 后半）
///
/// 本地存在可用密钥但解密仍失败（密文损坏 / salt 错配 / 被其他设备用
/// 不同密码重加密）时抛出。取代旧实现「返回 null 静默跳过」——旧行为
/// 会让恢复流程返回 inserted:0 且无任何提示，用户误以为"什么都没发生"。
///
/// 与 [CloudEncryptedLocallyDisabledException] 的区别：
/// - [CloudEncryptedLocallyDisabledException]：本地无密钥/未开启加密，
///   引导用户走「开启加密 → enableFromCloud」流程即可恢复
/// - 本异常：本地有密钥但内容不可读，需用户确认密码是否变更，或用
///   「上传覆盖云端」自救
class CloudCiphertextUndecryptableException implements Exception {
  final String message;
  final Object? cause;

  const CloudCiphertextUndecryptableException(this.message, {this.cause});

  @override
  String toString() => 'CloudCiphertextUndecryptableException: $message';
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

/// SaltMismatch 恢复流程的结果
///
/// 用于区分「用户主动取消」与「激活失败」两种结束状态，
/// 让调用方（[StartupSyncChecker] 等）能针对不同结果给出不同反馈，
/// 避免「密码错误静默退出、错误只在设置页可见」的体验缺陷。
enum SaltMismatchRecoveryResult {
  /// 密码正确、密钥激活成功，调用方应重试原同步操作
  activated,

  /// 用户主动取消密码输入，无需额外提示
  cancelled,

  /// 密码错误或密钥激活失败（网络探测失败、云端密文损坏、云服务未初始化等），
  /// 需要明确告知用户同步未恢复
  failed,
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

  /// 成功重加密的文件路径列表（SYNC-13：部分失败时供回滚定位）
  final List<String> successPaths;

  const ReEncryptResult({
    required this.success,
    required this.failed,
    required this.skipped,
    required this.failedPaths,
    this.successPaths = const [],
  });

  @override
  String toString() =>
      'ReEncryptResult(success: $success, failed: $failed, skipped: $skipped)';
}

/// 改密时云端重加密部分失败异常（SYNC-13）
///
/// 云端存在无法用旧密钥解密/上传失败的文件时，继续激活新密钥会造成
/// 「云端部分旧密钥、部分新密钥」的混合状态，叠加增量拉取静默丢弃将
/// 导致选择性数据丢失。此时必须中止改密：不保存、不激活新密钥，
/// 并把已重加密成功的文件回滚为旧密钥密文。
class ReEncryptPartialFailureException implements Exception {
  /// 无法重加密的云端文件
  final List<String> failedPaths;

  /// 回滚已重加密文件时仍失败的文件（空 = 回滚完全成功，云端保持旧密钥一致）
  final List<String> rollbackFailedPaths;

  const ReEncryptPartialFailureException({
    required this.failedPaths,
    this.rollbackFailedPaths = const [],
  });

  bool get rollbackClean => rollbackFailedPaths.isEmpty;

  @override
  String toString() {
    final buf = StringBuffer('ReEncryptPartialFailureException: '
        '${failedPaths.length} 个云端文件重加密失败，改密已中止'
        '（新密码未生效，旧密码仍有效）。失败文件: ${failedPaths.take(5).join(', ')}');
    if (failedPaths.length > 5) buf.write(' 等 ${failedPaths.length} 个');
    if (!rollbackClean) {
      buf.write('；另有 ${rollbackFailedPaths.length} 个文件回滚失败，'
          '云端可能存在新旧密钥混合状态: ${rollbackFailedPaths.take(5).join(', ')}');
    }
    return buf.toString();
  }
}
