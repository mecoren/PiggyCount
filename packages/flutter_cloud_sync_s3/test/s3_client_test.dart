import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';

const _xmlKeys = [
  'a.txt',
  'b.txt',
];

String _listXml() {
  final contents = _xmlKeys
      .map((k) => '<Contents><Key>$k</Key></Contents>')
      .join();
  return '<?xml version="1.0"?>'
      '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '$contents</ListBucketResult>';
}

void main() {
  group('S3Client 寻址方式', () {
    test('path-style: 路径含 /bucket，Host 为 endpoint[:port]', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response(_listXml(), 200);
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        port: 9000,
        forcePathStyle: true,
        httpClient: mock,
      );

      final keys = await client.listObjects(bucket: 'mybucket');
      expect(keys, _xmlKeys);
      expect(capturedUri.host, 'minio.local');
      expect(capturedUri.port, 9000);
      expect(capturedUri.path, '/mybucket');
      expect(capturedUri.queryParameters['list-type'], '2');
      // 签名中的 Host 与 wire Host 一致（非默认端口携带端口）
      expect(capturedHeaders['host'], 'minio.local:9000');
      expect(
        capturedHeaders['authorization'],
        contains('SignedHeaders=host;x-amz-content-sha256;x-amz-date'),
      );
    });

    test('virtual-hosted: Host 为 bucket.endpoint，路径不含 bucket', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response(_listXml(), 200);
      });

      final client = S3Client(
        endpoint: 'oss-cn-hangzhou.aliyuncs.com',
        region: 'cn-hangzhou',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: true,
        forcePathStyle: false,
        httpClient: mock,
      );

      final keys = await client.listObjects(bucket: 'mybucket');
      expect(keys, _xmlKeys);
      expect(capturedUri.host, 'mybucket.oss-cn-hangzhou.aliyuncs.com');
      expect(capturedUri.scheme, 'https');
      // 空路径在请求线上与签名规范请求中均按 "/" 处理
      expect(capturedUri.path, isEmpty);
      expect(capturedHeaders['host'], 'mybucket.oss-cn-hangzhou.aliyuncs.com');
    });

    test('P1-2: 带空格的 prefix 落网编码为 %20 而非 +，与签名一致', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response(_listXml(), 200);
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

      // 回归测试：修复前 uri.replace(queryParameters:) 将空格编码为 '+'，
      // 与签名侧 Uri.encodeComponent 的 '%20' 不一致，S3 SigV4 校验返回 403。
      final keys =
          await client.listObjects(bucket: 'mybucket', prefix: 'my folder');
      expect(keys, _xmlKeys);
      // 落网查询串必须使用 %20（RFC 3986），不得出现 '+' 形式
      expect(capturedUri.query, contains('prefix=my%20folder'));
      expect(capturedUri.query, isNot(contains('my+folder')));
      // 服务端解码后应还原为原始 prefix
      expect(capturedUri.queryParameters['prefix'], 'my folder');
      // 签名 Host 仍正确
      expect(capturedHeaders['host'], 'minio.local');
    });

    test('putObject path-style 带端口时 Host 与签名一致', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response('', 200);
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        port: 9000,
        forcePathStyle: true,
        httpClient: mock,
      );

      await client.putObject(
        bucket: 'b',
        key: 'dir/f.txt',
        data: Uint8List.fromList([1, 2, 3]),
      );

      expect(capturedUri.path, '/b/dir/f.txt');
      expect(capturedHeaders['host'], 'minio.local:9000');
      expect(capturedHeaders['content-type'], 'application/octet-stream');
      expect(capturedHeaders['authorization'], contains('AWS4-HMAC-SHA256'));
      expect(
        capturedHeaders['authorization'],
        contains('SignedHeaders=content-length;content-type;host;x-amz-content-sha256;x-amz-date'),
      );
    });
  });

  group('S3Client ListObjects 回退', () {
    test('ListObjectsV2 返回 400（Apache HTML）时自动回退 V1', () async {
      var v2Called = false;
      final mock = MockClient((request) async {
        if (request.url.queryParameters['list-type'] == '2') {
          v2Called = true;
          return http.Response(
            'Your browser sent a request that this server could not understand.',
            400,
          );
        }
        expect(request.url.queryParameters.containsKey('list-type'), isFalse);
        return http.Response(_listXml(), 200);
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

      final keys = await client.listObjects(bucket: 'b');
      expect(v2Called, isTrue);
      expect(keys, _xmlKeys);
    });

    test('ListObjectsV2 返回 501 时自动回退 V1', () async {
      var v2Called = false;
      final mock = MockClient((request) async {
        if (request.url.queryParameters['list-type'] == '2') {
          v2Called = true;
          return http.Response(
            '<Error><Code>NotImplemented</Code><Message>list-type not supported</Message></Error>',
            501,
          );
        }
        return http.Response(_listXml(), 200);
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

      final keys = await client.listObjects(bucket: 'b');
      expect(v2Called, isTrue);
      expect(keys, _xmlKeys);
    });

    test('V1 与 V2 均失败时抛出 S3Exception，HTML 已被净化', () async {
      final mock = MockClient(
        (request) async => http.Response('<html><body>Bad Request</body></html>', 400),
      );

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

      await expectLater(
        client.listObjects(bucket: 'b'),
        throwsA(isA<S3Exception>()
            .having((e) => e.statusCode, 'statusCode', 400)
            .having((e) => e.message, 'message', isNot(contains('<')))),
      );
    });

    test('403 XML 认证错误不被回退', () async {
      final mock = MockClient((request) async {
        return http.Response(
          '<Error><Code>SignatureDoesNotMatch</Code><Message>bad signature</Message></Error>',
          403,
        );
      });

      final client = S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

      await expectLater(
        client.listObjects(bucket: 'b'),
        throwsA(isA<S3AuthException>()),
      );
    });
  });
}
