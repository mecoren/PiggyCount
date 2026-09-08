import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb, debugPrint;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' hide LogLevel;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart' as fcs_log
    show LogLevel;
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_cloud_sync_icloud/flutter_cloud_sync_icloud.dart';
import 'package:flutter_cloud_sync_s3/flutter_cloud_sync_s3.dart';

import '../services/system/logger_service.dart';

/// 根据 CloudServiceConfig 创建对应的 CloudProvider 和 CloudAuthService
///
/// 返回 (CloudProvider, CloudAuthService) 元组
///
/// 支持后端: Supabase / WebDAV / iCloud / S3
///
/// 位置说明（L3 循环依赖解除）：本工厂此前位于 flutter_cloud_sync 包内
/// （src/config/provider_factory.dart），导致 core 反向依赖全部 provider
/// 包、与「provider 包依赖 core」形成循环。现迁至 app 层 —— app 本就直接
/// 依赖所有包，core 回归纯接口层（原 PiggyCount Cloud 协议实现已随
/// 云端协同下线移除）。
Future<({CloudProvider? provider, CloudAuthService? auth})> createCloudServices(
  CloudServiceConfig config,
) async {
  if (!config.valid) {
    return (provider: null, auth: null);
  }

  switch (config.type) {
    case CloudBackendType.local:
      return (provider: null, auth: null);

    case CloudBackendType.supabase:
      // 创建并初始化 Supabase provider
      // 包内会处理重复初始化的问题
      final provider = SupabaseProvider();
      await provider.initialize({
        'url': config.supabaseUrl!,
        'anonKey': config.supabaseAnonKey!,
        'bucket': config.supabaseBucket ?? 'piggycount-backups', // 兼容老配置，提供默认值
        'pathPrefix': null, // 使用默认的 users/{userId}/ 结构，基础包支持但业务层不配置
      });

      // Auth service 直接从 provider 获取
      final auth = provider.auth;

      return (provider: provider, auth: auth);

    case CloudBackendType.webdav:
      // LOG-01（对齐 S3 的 downgradeLogger 接线）：存储层关键告警
      // （降级交换备份还原失败/临时清理失败/元数据读取失败）接入应用
      // 日志管线 —— 此前只走 dev.log，release 构建无痕迹。
      WebDAVProvider.storageLogger = CloudSyncLogger(
        onLog: (level, message) {
          switch (level) {
            case fcs_log.LogLevel.debug:
            case fcs_log.LogLevel.info:
              logger.info('CloudSync', message);
              break;
            case fcs_log.LogLevel.warning:
              logger.warning('CloudSync', message);
              break;
            case fcs_log.LogLevel.error:
              logger.error('CloudSync', message);
              break;
          }
        },
      );
      final provider = WebDAVProvider();
      await provider.initialize({
        'url': config.webdavUrl!,
        'username': config.webdavUsername!,
        'password': config.webdavPassword!,
        'remotePath': config.webdavRemotePath ?? '/',
      });

      final auth = provider.auth;

      return (provider: provider, auth: auth);

    case CloudBackendType.icloud:
      // iCloud 仅支持 iOS/iPadOS
      if (kIsWeb || !Platform.isIOS) {
        return (provider: null, auth: null);
      }

      try {
        final provider = ICloudProvider();
        await provider.initialize({});

        final auth = provider.auth;

        return (provider: provider, auth: auth);
      } catch (e) {
        // iCloud 不可用（未登录、权限问题等），记录日志便于排查
        debugPrint('iCloud init failed: $e');
        return (provider: null, auth: null);
      }

    case CloudBackendType.s3:
      // S3 初始化 - 不捕获异常，让错误向上传递以便调试
      // S3-W2：条件写降级 warning 线索（网关 400+NotImplemented 时
      // 静默降级排查无痕迹），接线到应用日志
      S3Provider.downgradeLogger = CloudSyncLogger(
        onLog: (level, message) {
          if (level == fcs_log.LogLevel.warning) {
            logger.warning('CloudSync', message);
          }
        },
      );
      final provider = S3Provider();
      await provider.initialize({
        'endpoint': config.s3Endpoint!,
        'region': config.s3Region ?? 'us-east-1',
        'accessKey': config.s3AccessKey!,
        'secretKey': config.s3SecretKey!,
        'bucket': config.s3Bucket!,
        'useSSL': config.s3UseSSL ?? true,
        'port': config.s3Port,
        // null 时由 provider 按端点自动推断寻址方式
        'forcePathStyle': config.s3ForcePathStyle,
        // 业务层默认在 bucket 根下创建 piggycount/ 目录隔离应用数据，
        // 避免直接写入 bucket 根目录与其他应用数据混杂。
        'keyPrefix': 'piggycount/',
      });

      final auth = provider.auth;

      return (provider: provider, auth: auth);
  }
}
