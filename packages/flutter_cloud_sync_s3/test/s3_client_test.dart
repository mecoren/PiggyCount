import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_cloud_sync_s3/src/s3_signature.dart';

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

  group('S3Client 签名 method 一致性（P0）', () {
    /// x-amz-date（20260825T072830Z）→ UTC DateTime
    DateTime parseAmzDate(String amzDate) {
      final m = RegExp(r'^(\d{4})(\d{2})(\d{2})T(\d{2})(\d{2})(\d{2})Z$')
          .firstMatch(amzDate)!;
      return DateTime.utc(
        int.parse(m.group(1)!),
        int.parse(m.group(2)!),
        int.parse(m.group(3)!),
        int.parse(m.group(4)!),
        int.parse(m.group(5)!),
        int.parse(m.group(6)!),
      );
    }

    /// 用捕获到的请求头（含 x-amz-date）按 [method] 重算期望签名，
    /// 断言落网 Authorization 与之一致。服务端正是这样校验的：签名
    /// 规范请求首行是 HTTP method，method 不一致必然 SignatureDoesNotMatch。
    void expectSignedAs({
      required String actualAuthorization,
      required Uri uri,
      required String method,
      required String amzDate,
    }) {
      final signer = S3SignatureV4(
        accessKey: 'ak',
        secretKey: 'sk',
        region: 'us-east-1',
      );
      final expected = signer.sign(
        method: method,
        uri: uri,
        headers: {'Host': uri.authority},
        at: parseAmzDate(amzDate),
      );
      expect(actualAuthorization, expected['Authorization']);
    }

    test('headObject 以 HEAD 签名', () async {
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
        forcePathStyle: true,
        httpClient: mock,
      );

      expect(await client.headObject(bucket: 'b', key: 'k.json'), isTrue);

      expectSignedAs(
        actualAuthorization: capturedHeaders['authorization']!,
        uri: capturedUri,
        method: 'HEAD',
        amzDate: capturedHeaders['x-amz-date']!,
      );
    });

    test('headObjectWithMetadata 以 HEAD 签名', () async {
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
        forcePathStyle: true,
        httpClient: mock,
      );

      final info = await client.headObjectWithMetadata(bucket: 'b', key: 'k');
      expect(info.exists, isTrue);

      expectSignedAs(
        actualAuthorization: capturedHeaders['authorization']!,
        uri: capturedUri,
        method: 'HEAD',
        amzDate: capturedHeaders['x-amz-date']!,
      );
    });

    test('deleteObject 以 DELETE 签名', () async {
      late Uri capturedUri;
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        capturedHeaders = request.headers;
        return http.Response('', 204);
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

      await client.deleteObject(bucket: 'b', key: 'k.json');

      expectSignedAs(
        actualAuthorization: capturedHeaders['authorization']!,
        uri: capturedUri,
        method: 'DELETE',
        amzDate: capturedHeaders['x-amz-date']!,
      );
    });

    test('负向对照：GET 签名 ≠ HEAD 落网 Authorization（防回归灵敏度）', () async {
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
        forcePathStyle: true,
        httpClient: mock,
      );

      await client.headObject(bucket: 'b', key: 'k');

      final signer = S3SignatureV4(
        accessKey: 'ak',
        secretKey: 'sk',
        region: 'us-east-1',
      );
      final wrongMethod = signer.sign(
        method: 'GET',
        uri: capturedUri,
        headers: {'Host': capturedUri.authority},
        at: parseAmzDate(capturedHeaders['x-amz-date']!),
      );
      // 若回归为「用 GET 签名发 HEAD」，此断言将失败
      expect(capturedHeaders['authorization'],
          isNot(wrongMethod['Authorization']));
    });
  });
}
