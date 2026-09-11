/// 2026-09-11 归一化批次回归（对照 docs/sync-comprehensive-audit-2026-09-10.md）：
///
/// - P0-1：list() 游标翻页 —— 旧实现不传 SearchOptions，SDK 默认
///   limit:100 静默截断；目录超 100 对象后 exists()/getMetadata() 把
///   第 101+ 个对象误判不存在。现在 list/exists/getMetadata 全部走
///   listPaginated 游标翻页。
/// - P1-8：幂等读重试（对齐 WebDAV 2 次、400/800ms ±50% jitter）。
/// - P1-1：ConditionalWriteStorage 读后比对近似 + 接口契约。
/// - P1-1b：CloudFile.path 相对路径口径（可回传 delete/exists）。
/// - P1-1c：MetadataPersistFailedException 信号类型。
/// - P1-9：list 404 → 空列表收敛。
///
/// 网络路径依赖真实 Supabase（单测不覆盖）；此处验证能力申报、类型
/// 契约与纯逻辑分支。
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

  group('P1-1: ConditionalWriteStorage 能力申报', () {
    test('SupabaseStorageService implements ConditionalWriteStorage '
        '（Supabase 从无条件写 → 读后比对近似，对齐 WebDAV）', () {
      final svc = buildService();
      expect(svc, isA<ConditionalWriteStorage>());
      expect(svc.supportsConditionalWrite, isTrue);
    });

    test('conditionalOrNull 解析：加密装饰器按本实现如实透传能力', () {
      final svc = buildService();
      final storage = svc as CloudStorageService;
      expect(storage.conditionalOrNull, isNotNull,
          reason: '实现 ConditionalWriteStorage 且 supports=true 后，'
              'manager 的 ifMatchEtag 链路对 Supabase 生效（此前恒降级盲写）');
    });

    test('uploadBinaryConditional 参数互斥校验（对齐接口契约）', () async {
      final svc = buildService();
      // 未登录门禁在互斥校验之后 —— 互斥是纯参数错误，必须先抛
      await expectLater(
        svc.uploadBinaryConditional(
          path: 'a.json',
          bytes: [1],
          ifMatchEtag: 'etag-1',
          ifNoneMatch: true,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  group('P1-1b: CloudFile.path 相对路径口径', () {
    test('MetadataPersistFailedException 是 CloudStorageException 子类 '
        '（manager 包装链路按存储异常计量，不绕过 catch 边界）', () {
      final e = MetadataPersistFailedException('probe', 'root');
      expect(e, isA<CloudStorageException>());
      expect(e, isA<CloudSyncException>());
      expect(e.message, contains('probe'));
      expect(e.originalError, 'root');
    });
  });

  group('P1-8/P0-1: 未登录门禁保持（翻页改造不绕过认证）', () {
    test('list/exists/getMetadata/delete 未登录 → CloudNotAuthenticatedException',
        () async {
      final svc = buildService();
      await expectLater(svc.list(path: ''),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(svc.exists(path: 'a.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(svc.getMetadata(path: 'a.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(svc.delete(path: 'a.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
    });

    test('download/downloadBinary/upload 未登录 → CloudNotAuthenticatedException',
        () async {
      final svc = buildService();
      await expectLater(svc.download(path: 'a.json'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(svc.downloadBinary(path: 'a.bin'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(
          svc.upload(path: 'a.json', data: '{}'),
          throwsA(isA<CloudNotAuthenticatedException>()));
      await expectLater(svc.uploadBinary(path: 'a.bin', bytes: [1]),
          throwsA(isA<CloudNotAuthenticatedException>()));
    });
  });
}
