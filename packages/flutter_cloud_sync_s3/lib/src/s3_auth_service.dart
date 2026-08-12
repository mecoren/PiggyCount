import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';

import 's3_client.dart';

/// S3 认证服务实现
///
/// S3 使用 Access Key 认证，无传统的登录/登出概念。
/// 真正的连接与认证验证在 [S3Provider.initialize] 时通过 listObjects 探测完成。
class S3AuthService implements CloudAuthService {
  final S3Client client;
  final String bucket;

  S3AuthService(this.client, this.bucket);

  /// 统一构造 CloudUser，避免 getCurrentUser / authStateChanges 重复构建
  /// 导致字段不一致（例如修改 metadata 结构时需改两处）
  CloudUser _buildUser() => CloudUser(
        id: 's3-${client.accessKey}',
        email: null, // S3 无 email 概念
        metadata: {
          'bucket': bucket,
          'endpoint': client.endpoint,
          'region': client.region,
        },
      );

  /// 获取当前用户信息
  ///
  /// S3 使用 Access Key 认证，无独立用户系统，此处直接基于 client 配置
  /// 构造用户信息。实际的连接验证已在 provider.initialize() 时完成，
  /// 此处不再发起网络请求。
  Future<CloudUser?> getCurrentUser() async {
    return _buildUser();
  }

  @override
  Future<void> signOut() async {
    // S3 无需登出操作
    // 认证信息在 provider dispose 时清除
  }

  @override
  Stream<CloudUser?> get authStateChanges {
    // S3 无状态变化概念，返回固定流
    return Stream.value(_buildUser());
  }

  @override
  Future<CloudUser?> get currentUser async {
    return getCurrentUser();
  }

  @override
  Future<CloudUser> signInWithEmail({
    required String email,
    required String password,
  }) async {
    throw CloudAuthException('S3 does not support email authentication');
  }

  @override
  Future<CloudUser> signUpWithEmail({
    required String email,
    required String password,
    Map<String, dynamic>? metadata,
  }) async {
    throw CloudAuthException('S3 does not support email registration');
  }

  @override
  Future<void> sendPasswordResetEmail({required String email}) async {
    throw CloudAuthException('S3 does not support password reset');
  }

  @override
  Future<void> resendEmailVerification({required String email}) async {
    throw CloudAuthException('S3 does not support email verification');
  }
}
