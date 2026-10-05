import 'dart:io';

import '../../services/system/logger_service.dart';
import '../database_health_service.dart';
import 'database_key_service.dart';
import 'db_encryption_migration.dart';
import 'db_encryption_settings.dart';
import 'sqlcipher_capability.dart';

/// 整库加密在用户视角下的状态（UI 只需 switch 它）。
///
/// 之所以要有 `pending*` 两态：加密/解密都是**开库前的文件级迁移**，用户操作后
/// 必须重启才生效。把"已点但还没生效"如实表达出来，比让 UI 假装已经生效要诚实。
enum LocalDbEncryptionState {
  /// 当前引擎没有加密能力（`PRAGMA cipher_version` 为空）：不能开启，如实告知。
  unsupported,

  /// 未加密，库是明文（或还不存在）。
  disabled,

  /// 密钥已生成、但库还是明文 —— 下次启动会迁成密文。
  pendingEnable,

  /// 已加密，一切就绪。
  enabled,

  /// 用户已请求关闭（或已删钥但还没解），下次启动会解回明文。
  pendingDisable,

  /// **密文库 + 本机无密钥**：本地数据不可读，走 R5 引导（绝不清库/隔离）。
  keyMissing,
}

/// 整库加密的**开关编排**（R2/R5/R6）：把"密钥层 + 文件级迁移 + 意图标记"
/// 串成一个用户能理解的状态机。
///
/// 分层：属于 Service 层，只碰安全区/prefs/文件（不经数据库），因此不违反
/// "Repository 是数据库唯一入口"。
class LocalDbEncryptionService {
  const LocalDbEncryptionService({
    DatabaseKeyService keyService = const DatabaseKeyService(),
    DbEncryptionSettings settings = const DbEncryptionSettings(),
    Future<String> Function() dbPathResolver = DatabaseHealthService.resolveDbPath,
  })  : _keyService = keyService,
        _settings = settings,
        _dbPathResolver = dbPathResolver;

  final DatabaseKeyService _keyService;
  final DbEncryptionSettings _settings;
  final Future<String> Function() _dbPathResolver;

  /// 读取当前状态。只读，不改动任何东西。
  Future<LocalDbEncryptionState> state() async {
    if (!SqlCipherCapability.isSupported) {
      // 密钥可能存在（换设备/降级构建），但本机引擎开不了加密库 —— 交给 R5 那条
      // 判断去区分"密文库无密钥"，这里只表达"本机不支持开启"。
      if (await _isEncryptedDbWithoutKey()) {
        return LocalDbEncryptionState.keyMissing;
      }
      return LocalDbEncryptionState.unsupported;
    }

    final key = await _keyService.loadKey();
    if (key == null) {
      return await _isEncryptedDbWithoutKey()
          ? LocalDbEncryptionState.keyMissing
          : LocalDbEncryptionState.disabled;
    }

    // 有密钥：看库文件到底是明文还是密文，以及有没有待执行的关闭意图。
    final dbFile = File(await _dbPathResolver());
    if (!dbFile.existsSync()) {
      // 库还没建：下次启动会以密文建库，对用户而言已经是"开启"了。
      return LocalDbEncryptionState.enabled;
    }
    final isPlain = DbEncryptionMigration.looksLikePlaintext(dbFile.path);
    if (await _settings.isDisableRequested()) {
      return LocalDbEncryptionState.pendingDisable;
    }
    return isPlain
        ? LocalDbEncryptionState.pendingEnable
        : LocalDbEncryptionState.enabled;
  }

  /// 显式开启：生成密钥。**库文件此刻不会变**（它还开着），
  /// 下次启动由 [DbEncryptionMigration] 迁成密文。
  Future<void> enable() async {
    if (!SqlCipherCapability.isSupported) {
      // 直说不支持，而不是写一把用不上的钥匙 —— 那正是"看起来加密、实际明文"
      // 的源头（见 SqlCipherCapability 的注释）。
      throw const DbEncryptionUnsupportedException();
    }
    await _settings.clearDisableRequest(); // 开启优先于之前登记的关闭意图
    await _keyService.createKey();
    // 留下"曾启用"标记：万一将来密钥丢了，健康探测靠它把"加密库缺钥"与"垃圾
    // 文件"区分开（见 DbHealth.keyUnavailable）。
    await _settings.markEverEnabled();
    logger.info('DbEncryption', '已生成整库加密密钥，下次启动迁为密文库');
  }

  /// 显式关闭：登记意图（**不删钥**），下次启动解回明文、成功后才删钥。
  Future<void> requestDisable() async {
    await _settings.requestDisable();
    logger.info('DbEncryption', '已登记关闭整库加密，下次启动解回明文');
  }

  /// 撤销"待关闭"意图（用户在重启前反悔）。
  Future<void> cancelDisable() async {
    await _settings.clearDisableRequest();
    logger.info('DbEncryption', '已撤销关闭整库加密的意图');
  }

  /// 密文库 + 本机无密钥（R5 的判据，供状态与引导共用）。
  ///
  /// 必须叠加"本机曾启用过"标记：单看"文件非明文 + 无密钥"无法与"文件根本
  /// 不是库（垃圾/损坏）"区分，而两者的正确引导完全相反。
  Future<bool> _isEncryptedDbWithoutKey() async {
    if (await _keyService.loadKey() != null) return false;
    if (!await _settings.wasEverEnabled()) return false;
    final file = File(await _dbPathResolver());
    if (!file.existsSync()) return false;
    return !DbEncryptionMigration.looksLikePlaintext(file.path);
  }
}
