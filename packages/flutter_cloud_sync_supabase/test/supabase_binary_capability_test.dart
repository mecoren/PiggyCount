/// P1-4（2026-09-09）：Supabase BinaryCapableStorage 能力回归。
///
/// SupabaseStorageService 实现 [BinaryCapableStorage] 后，
/// [CloudStorageBinaryExt.uploadBinaryOrFallback/downloadBinaryOrFallback]
/// 自动分派到真字节路径（不再走 base64 文本兜底）：
/// - 附件上传/下载、ZIP 云端备份在该后端流量直降 33%；
/// - 云端对象为原生二进制（外部工具可直读）；
/// - 旧 base64 文本对象的兼容由调用方嗅探保证（备份恢复 ZIP 魔数 /
///   附件 sha256 终审），本层不做形态猜测。
///
/// SupabaseClient(url, anonKey) 构造不发网络请求，仅建内部实例；
/// 未 Supabase.initialize 时 client.auth.currentUser 为 null，
/// 恰好覆盖「未登录」门禁分支。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_supabase/flutter_cloud_sync_supabase.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart' as supabase;

void main() {
  SupabaseStorageService buildService() {
    final client = supabase.SupabaseClient(
      'https://test-project.supabase.co',
      'test-anon-key',
    );
    return SupabaseStorageService(client, 'test-bucket');
  }

  group('P1-4: BinaryCapableStorage 能力分派', () {
    test('SupabaseStorageService is BinaryCapableStorage —— '
        'CloudStorageBinaryExt 自动分派到真字节路径', () {
      final svc = buildService();
      expect(svc, isA<BinaryCapableStorage>(),
          reason: '未实现该接口时 uploadBinaryOrFallback 恒走 base64 '
              '文本兜底（+33% 流量），实现后自动分派');
    });

    test('uploadBinary 未登录 → CloudNotAuthenticatedException（不绕过认证）',
        () async {
      final svc = buildService();
      await expectLater(
        svc.uploadBinary(path: 'a.bin', bytes: [1, 2, 3]),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('downloadBinary 未登录 → CloudNotAuthenticatedException', () async {
      final svc = buildService();
      await expectLater(
        svc.downloadBinary(path: 'a.bin'),
        throwsA(isA<CloudNotAuthenticatedException>()),
      );
    });

    test('storageLogger 注入口可设置（LOG-01：metadata 告警进应用日志）',
        () async {
      final messages = <String>[];
      SupabaseStorageService.storageLogger = CloudSyncLogger(
        onLog: (level, message) => messages.add(message),
      );
      // 构造一个 metadata 写失败场景验证告警路由成本层 —— 直接验证
      // 注入口与 CloudSyncLogger 形态即可（网络路径已在既有测试覆盖）
      expect(SupabaseStorageService.storageLogger, isNotNull);
      SupabaseStorageService.storageLogger!.warning('probe');
      expect(messages, contains('probe'));
      // 还原静态状态，避免影响其他测试
      SupabaseStorageService.storageLogger = null;
    });
  });
}
