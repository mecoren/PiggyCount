import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_storage_service.dart';

String _listXml(List<String> keys) {
  final contents = keys
      .map((k) => '<Contents><Key>$k</Key></Contents>')
      .join();
  return '<?xml version="1.0"?>'
      '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '$contents</ListBucketResult>';
}

S3Client _client(MockClient mock) => S3Client(
      endpoint: 'minio.local',
      region: 'us-east-1',
      accessKey: 'ak',
      secretKey: 'sk',
      useSSL: false,
      forcePathStyle: true,
      httpClient: mock,
    );

void main() {
  group('S3StorageService keyPrefix', () {
    test('keyPrefix 为空时（默认）key 不带前缀（向后兼容）', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket');
      await service.upload(path: 'ledger.json', data: '{}');

      expect(capturedUri.path, '/mybucket/ledger.json');
    });

    test('upload 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.upload(path: 'ledger.json', data: '{}');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('download 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('hello', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.download(path: 'ledger.json');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('delete 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 204);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.delete(path: 'ledger.json');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('listFiles 在 keyPrefix 非空时以前缀作为 list prefix 并剥离返回值', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          _listXml(['piggycount/a.txt', 'piggycount/b.txt']),
          200,
        );
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      final keys = await service.listFiles('');

      // list prefix 应为 piggycount/
      expect(capturedUri.queryParameters['prefix'], 'piggycount/');
      // 返回值应剥离前缀，调用方拿到逻辑路径
      expect(keys, ['a.txt', 'b.txt']);
    });

    test('keyPrefix 不以 / 结尾时自动补全分隔符', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount');
      await service.upload(path: 'ledger.json', data: '{}');

      // 'piggycount' 应被规范化为 'piggycount/'
      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('listFiles 在 keyPrefix 为空时保持原有行为', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(_listXml(['a.txt', 'b.txt']), 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket');
      final keys = await service.listFiles('');

      // 无 prefix 时不应传递 prefix 查询参数
      expect(capturedUri.queryParameters.containsKey('prefix'), isFalse);
      expect(keys, ['a.txt', 'b.txt']);
    });
  });

  // 认证失败保真：S3 运行期凭据失效（密钥撤销/轮换）时，
  // S3AuthException / S3PermissionDeniedException 不能被包装成通用
  // CloudStorageException——上层（enableFromCloud 探测、启动检查器）
  // 依赖 CloudAuthException 区分「改凭据」与「检查网络」，误报为
  // 网络错误会误导排查方向（与 WebDAV 修复同款问题）
  group('S3StorageService 认证失败保真', () {
    String errXml(String code) => '<?xml version="1.0"?>'
        '<Error><Code>$code</Code>'
        '<Message>Request has expired</Message></Error>';

    test('download 403 SignatureDoesNotMatch 抛 CloudAuthException', () async {
      final mock = MockClient((request) async =>
          http.Response(errXml('SignatureDoesNotMatch'), 403));

      final service = S3StorageService(_client(mock), 'mybucket');
      await expectLater(
        service.download(path: 'ledger.json'),
        throwsA(isA<CloudAuthException>()),
      );
    });

    test('list 403 InvalidAccessKeyId 抛 CloudAuthException', () async {
      final mock = MockClient((request) async =>
          http.Response(errXml('InvalidAccessKeyId'), 403));

      final service = S3StorageService(_client(mock), 'mybucket');
      await expectLater(
        service.list(path: ''),
        throwsA(isA<CloudAuthException>()),
      );
    });

    test('HEAD 403（无 body）抛 CloudAuthException 而非误判不存在', () async {
      // HEAD 响应无 body，XML 解析失败走 S3PermissionDeniedException 分支
      final mock = MockClient((request) async => http.Response('', 403));

      final service = S3StorageService(_client(mock), 'mybucket');
      await expectLater(
        service.exists(path: 'ledger.json'),
        throwsA(isA<CloudAuthException>()),
      );
    });

    test('CloudAuthException 消息含「认证失败」供文本兜底识别', () async {
      final mock = MockClient((request) async =>
          http.Response(errXml('SignatureDoesNotMatch'), 403));

      final service = S3StorageService(_client(mock), 'mybucket');
      try {
        await service.download(path: 'ledger.json');
        fail('应抛 CloudAuthException');
      } on CloudAuthException catch (e) {
        // 上层 _isAuthError/_isAuthErrorText 有文本兜底匹配，
        // 消息必须携带「认证失败」关键字
        expect(e.toString(), contains('认证失败'));
      }
    });
  });

  // 方案C 契约补全（审计 C1）：条件写遇「远端已被并发删除」时
  // AWS/MinIO 返回 404 NoSuchKey，必须与 412 同样翻译为
  // CloudPreconditionFailedException —— 上层据此走冲突流程；
  // 落成通用 CloudStorageException 会把核心并发竞态误报为存储故障。
  group('S3StorageService 条件写 404 翻译', () {
    test('uploadBinaryConditional 遇 404 抛 CloudPreconditionFailedException',
        () async {
      final mock = MockClient((request) async =>
          http.Response('<?xml version="1.0"?><Error><Code>NoSuchKey</Code>'
              '<Message>Not Found</Message></Error>', 404));

      final service = S3StorageService(_client(mock), 'mybucket');
      await expectLater(
        service.uploadBinaryConditional(
          path: 'ledger_x.json',
          bytes: [1, 2, 3],
          ifMatchEtag: 'stale-etag',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('uploadBinaryConditional ifNoneMatch 遇 404 同样按条件失败', () async {
      final mock = MockClient((request) async =>
          http.Response('<?xml version="1.0"?><Error><Code>NoSuchKey</Code>'
              '<Message>Not Found</Message></Error>', 404));

      final service = S3StorageService(_client(mock), 'mybucket');
      await expectLater(
        service.uploadBinaryConditional(
          path: 'ledger_x.json',
          bytes: [1, 2, 3],
          ifNoneMatch: true,
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });
  });
}
