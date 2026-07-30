import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import '../../domain/encryption/encryption_service.dart';
import 'encrypted_cloud_storage.dart';

/// 加密版 [CloudProvider] 装饰器
///
/// 包装任意 [CloudProvider] 实现（S3 / WebDAV / Supabase / iCloud），
/// 把 inner 的 [CloudStorageService] 替换为 [EncryptedCloudStorageService]，
/// 其余成员（auth / providerId / providerName / initialize / validateConfig / dispose）
/// 全部透传。
///
/// 装饰器位置：在 [TransactionsSyncManager._initialize] 拿到具体 CloudProvider 后、
/// 传给 CloudSyncManager 之前包装一层。这样 4 个后端一次全部覆盖，无后端特化逻辑。
///
/// 设计要点：
/// - `storage` 每次访问返回同一实例（缓存），避免重复包装
/// - inner 切换/重新 initialize 后，调用 [invalidateCache] 重新生成装饰器
class EncryptedCloudProvider implements CloudProvider {
  final CloudProvider inner;
  final EncryptionService encryptionService;

  /// 缓存的加密版 storage，避免每次 getter 调用都新建装饰器
  CloudStorageService? _cachedStorage;

  EncryptedCloudProvider({
    required this.inner,
    required this.encryptionService,
  });

  @override
  String get providerId => inner.providerId;

  @override
  String get providerName => inner.providerName;

  @override
  CloudAuthService get auth => inner.auth;

  @override
  CloudStorageService get storage {
    return _cachedStorage ??= EncryptedCloudStorageService(
      inner: inner.storage,
      encryptionService: encryptionService,
    );
  }

  @override
  Future<void> initialize(Map<String, dynamic> config) async {
    await inner.initialize(config);
    // ATTACH-1 修复：inner 重新 initialize 后 inner.storage 实例已变更，
    // 必须清空缓存的装饰器，否则后续 storage getter 仍返回旧实例，
    // 造成数据写入错误的 session/bucket
    _cachedStorage = null;
  }

  @override
  bool validateConfig(Map<String, dynamic> config) {
    return inner.validateConfig(config);
  }

  @override
  Future<void> dispose() async {
    await inner.dispose();
    _cachedStorage = null;
  }

  /// 清除缓存的 storage 装饰器
  ///
  /// 用于 inner 重新 initialize 后强制重建装饰器，
  /// 确保 storage 装饰器持有最新的 inner.storage 实例。
  void invalidateCache() {
    _cachedStorage = null;
  }
}
