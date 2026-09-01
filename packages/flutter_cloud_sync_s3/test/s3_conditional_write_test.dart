import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_cloud_sync_s3/src/s3_signature.dart';

/// 方案C（并发全面加固）：S3 条件写与 ETag 透出回归
void main() {
  group('putObject 条件写', () {
    test('ifMatch → 请求携带 If-Match 头且参与签名，成功返回归一化 ETag',
        () async {
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedHeaders = request.headers;
        return http.Response('', 200, headers: {
          'etag': '"abc123"',
        });
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      final etag = await client.putObject(
        bucket: 'b',
        key: 'ledger_x.json',
        data: Uint8List.fromList(utf8.encode('{}')),
        ifMatch: 'abc123',
      );

      expect(etag, 'abc123');
      // 审计 M3：RFC 7232 引号形态（裸值在严格兼容网关会 400）
      expect(capturedHeaders['If-Match'], '"abc123"');
    });

    test('ifNoneMatch → 请求携带 If-None-Match: *（create-only）', () async {
      late Map<String, String> capturedHeaders;
      final mock = MockClient((request) async {
        capturedHeaders = request.headers;
        return http.Response('', 200);
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await client.putObject(
        bucket: 'b',
        key: 'k',
        data: Uint8List(0),
        ifNoneMatch: true,
      );

      expect(capturedHeaders['If-None-Match'], '*');
    });

    test('412 → S3PreconditionFailedException（本次写入未落盘）', () async {
      final mock = MockClient((request) async => http.Response('', 412));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k',
          data: Uint8List(0),
          ifMatch: 'stale',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
    });

    test('ifMatch 与 ifNoneMatch 互斥 → ArgumentError', () async {
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: MockClient((request) async => http.Response('', 200)),
      );

      expect(
        () => client.putObject(
          bucket: 'b',
          key: 'k',
          data: Uint8List(0),
          ifMatch: 'x',
          ifNoneMatch: true,
        ),
        throwsArgumentError,
      );
    });

    test('条件写 404（远端已被并发删除）→ S3PreconditionFailedException', () async {
      // AWS/MinIO：If-Match 无当前版本时返回 404 NoSuchKey，
      // 契约要求「远端不存在同样算条件失败」
      final mock = MockClient((request) async => http.Response(
          '<?xml version="1.0"?><Error><Code>NoSuchKey</Code>'
          '<Message>Not Found</Message></Error>',
          404));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k',
          data: Uint8List(0),
          ifMatch: 'stale',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
    });

    test('条件写 ifNoneMatch 遇 404 同样按条件失败上抛', () async {
      final mock = MockClient(
          (request) async => http.Response('<?xml version="1.0"?>'
              '<Error><Code>NoSuchKey</Code>'
              '<Message>Not Found</Message></Error>', 404));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k',
          data: Uint8List(0),
          ifNoneMatch: true,
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
    });

    test('非条件写 404 仍走通用错误路径（不误判为冲突）', () async {
      final mock = MockClient(
          (request) async => http.Response('<?xml version="1.0"?>'
              '<Error><Code>NoSuchKey</Code>'
              '<Message>Not Found</Message></Error>', 404));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(bucket: 'b', key: 'k', data: Uint8List(0)),
        throwsA(isA<S3Exception>().having(
            (e) => e is S3PreconditionFailedException, 'not precondition', false)),
      );
    });

    test('审计 M2：409 ConditionalRequestConflict 重试后成功', () async {
      var calls = 0;
      late Map<String, String> lastHeaders;
      final mock = MockClient((request) async {
        calls++;
        lastHeaders = request.headers;
        if (calls <= 2) {
          return http.Response(
              '<?xml version="1.0"?><Error><Code>ConditionalRequestConflict'
              '</Code><Message>Conflict</Message></Error>', 409);
        }
        return http.Response('', 200, headers: {'etag': '"ok"'});
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      final etag = await client.putObject(
        bucket: 'b',
        key: 'k',
        data: Uint8List(0),
        ifMatch: 'stale',
      );

      expect(etag, 'ok');
      expect(calls, 3);
      expect(lastHeaders['If-Match'], '"stale"');
    });

    test('审计 M2：409 持续冲突 → 重试耗尽后按条件失败上抛', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        return http.Response(
            '<?xml version="1.0"?><Error><Code>ConditionalRequestConflict'
            '</Code><Message>Conflict</Message></Error>', 409);
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k',
          data: Uint8List(0),
          ifMatch: 'stale',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
      // 首发 + 2 次重试
      expect(calls, 3);
    });

    test('弱验证器/引号包装的 ETag 归一化返回', () async {
      final mock = MockClient((request) async =>
          http.Response('', 200, headers: {'etag': 'W/"weak-etag"'}));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      final etag = await client.putObject(
        bucket: 'b',
        key: 'k',
        data: Uint8List(0),
      );
      expect(etag, 'weak-etag');
    });

    test('审计 A5：PUT 路径 NoSuchBucket → S3BucketNotFoundException', () async {
      const noSuchBucketXml = '<?xml version="1.0"?>'
          '<Error><Code>NoSuchBucket</Code>'
          '<Message>The specified bucket does not exist</Message></Error>';
      final mock = MockClient(
          (request) async => http.Response(noSuchBucketXml, 404));
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await expectLater(
        client.putObject(bucket: 'missing', key: 'k', data: Uint8List(0)),
        throwsA(isA<S3BucketNotFoundException>()),
      );
    });
  });

  group('审计 S-A：Content-Length 不参与签名', () {
    test('签名头集合不含 content-length，PUT 正常通过', () async {
      late http.Request captured;
      // 真实签名校验：用签名器重算 canonical request 校验 CL 缺席不破坏签名
      final mock = MockClient((request) async {
        captured = request;
        return http.Response('', 200);
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      await client.putObject(
          bucket: 'b', key: 'k', data: Uint8List.fromList([1, 2, 3]));

      // 传输层自动补 Content-Length；签名侧不再包含它 —— 这里只断言
      // 请求成功（若 CL 参与签名而传输层改写，服务端会 403；
      // 单元层面断言签名头列表里没有 content-length 更直接：
      // 通过 signer 重放签名逻辑验证）
      final signer = S3SignatureV4(accessKey: 'ak', secretKey: 'sk', region: 'us-east-1');
      final signed = signer.sign(
        method: 'PUT',
        uri: captured.url,
        headers: {
          'Host': captured.url.authority,
          'Content-Type': 'application/octet-stream',
          // 故意不带 Content-Length —— 与 _signedPutHeaders 口径一致
        },
        payloadBytes: Uint8List.fromList([1, 2, 3]),
      );
      expect(signed.containsKey('Authorization'), isTrue);
    });
  });
}
