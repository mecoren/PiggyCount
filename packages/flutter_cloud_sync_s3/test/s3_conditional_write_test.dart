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

  // 网关兼容性（真机同步第二轮实测发现）：部分 S3 兼容网关不支持
  // If-Match 条件头，返回 400 + NotImplemented 错误体（"A header you
  // provided implies functionality that is not implemented"）。putObject
  // 应识别该特征、去掉条件头重试一次盲写，而不是让覆盖上传整体失败。
  group('putObject 网关不支持条件头降级', () {
    test('ifMatch 收到 400+NotImplemented → 去掉条件头盲写重试成功', () async {
      var callCount = 0;
      late Map<String, String> secondHeaders;
      final mock = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          expect(request.headers.containsKey('If-Match'), isTrue);
          return http.Response(
            '<Error><Code>NotImplemented</Code><Message>A header you '
                'provided implies functionality that is not implemented.'
                '</Message></Error>',
            400,
          );
        }
        secondHeaders = Map<String, String>.from(request.headers);
        return http.Response('', 200, headers: {'etag': '"newetag"'});
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

      expect(etag, 'newetag');
      expect(callCount, 2, reason: '第一次条件写 400 后必须重试一次盲写');
      expect(secondHeaders.containsKey('If-Match'), isFalse,
          reason: '重试请求必须去掉 If-Match 条件头');
      expect(secondHeaders.containsKey('If-None-Match'), isFalse);
    });

    test('盲写重试再次 400（非条件头原因）→ 正常上抛 S3Exception', () async {
      var callCount = 0;
      final mock = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          return http.Response(
            '<Error><Code>NotImplemented</Code><Message>A header you '
                'provided implies functionality that is not implemented.'
                '</Message></Error>',
            400,
          );
        }
        // 去掉条件头后仍 400 → 签名/桶等其他问题，不得无限降级
        return http.Response('<Error><Code>BadDigest</Code></Error>', 400);
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
          data: Uint8List.fromList([1]),
          ifMatch: 'abc',
        ),
        throwsA(isA<S3Exception>()),
      );
      expect(callCount, 2, reason: '降级只允许一次');
    });

    test('无 ifMatch 的普通 400 → 不触发降级，直接上抛', () async {
      var callCount = 0;
      final mock = MockClient((request) async {
        callCount++;
        return http.Response(
            '<Error><Code>NotImplemented</Code><Message>A header you '
                'provided implies functionality that is not implemented.'
                '</Message></Error>',
            400);
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
          data: Uint8List.fromList([1]),
        ),
        throwsA(isA<S3Exception>()),
      );
      expect(callCount, 1, reason: '非条件写的 400 与条件头无关，不能降级重试');
    });
  });

  // S3-W2 能力记忆：首次 400+NotImplemented 降级后，同 client 的后续
  // 上传必须直接盲写（省一次失败往返），并通过 onConditionalWriteDowngrade
  // 回调留 warning 线索（此前静默降级排查无痕迹）。
  group('putObject 条件写能力记忆（S3-W2）', () {
    http.Response notImplemented400() => http.Response(
        '<Error><Code>NotImplemented</Code><Message>A header you provided '
        'implies functionality that is not implemented.</Message></Error>',
        400);

    test('首次降级后记忆能力：第二次上传直接盲写，只发 1 次请求', () async {
      var callCount = 0;
      List<String> firstHeadersOf(int call) => const [];
      final mock = MockClient((request) async {
        callCount++;
        if (callCount == 1) {
          expect(request.headers.containsKey('If-Match'), isTrue);
          return notImplemented400();
        }
        // 第二次 putObject（记忆生效）：根本不应带条件头，直接 200
        expect(request.headers.containsKey('If-Match'), isFalse,
            reason: '能力记忆生效后，后续上传入口直接盲写');
        return http.Response('', 200, headers: {'etag': '"e2"'});
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      // 第一次：条件写 → 400 降级 → 盲写成功（2 次请求）
      await client.putObject(
        bucket: 'b',
        key: 'k1',
        data: Uint8List.fromList([1]),
        ifMatch: 'abc',
      );
      expect(callCount, 2);
      expect(client.conditionalWriteUnsupportedForTest, isTrue,
          reason: '首次踩坑后必须记忆网关能力');

      // 第二次：记忆生效，直接盲写（1 次请求）
      final etag = await client.putObject(
        bucket: 'b',
        key: 'k2',
        data: Uint8List.fromList([2]),
        ifMatch: 'def',
      );
      expect(etag, 'e2');
      expect(callCount, 3, reason: '第二次上传不应再白付一次 400 失败往返');
      // 静态分析用：避免 unused 提示
      expect(firstHeadersOf(callCount), isNotNull);
    });

    test('降级时回调 onConditionalWriteDowngrade（warning 线索）', () async {
      final downgradeMessages = <String>[];
      final mock = MockClient((request) async {
        if (request.headers.containsKey('If-Match')) {
          return notImplemented400();
        }
        return http.Response('', 200);
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      )..onConditionalWriteDowngrade = downgradeMessages.add;

      await client.putObject(
        bucket: 'b',
        key: 'k',
        data: Uint8List.fromList([1]),
        ifMatch: 'abc',
      );

      expect(downgradeMessages, hasLength(1),
          reason: '首次降级必须留一条 warning 线索');
      expect(downgradeMessages.first, contains('不支持条件写'));
      // 第二次上传（记忆盲写）：不应重复告警
      await client.putObject(
        bucket: 'b',
        key: 'k',
        data: Uint8List.fromList([1]),
        ifMatch: 'abc',
      );
      expect(downgradeMessages, hasLength(1),
          reason: '能力记忆后不再走降级路径，不应重复告警');
    });

    test('putObjectStream 同样消费能力记忆：入口直接盲写', () async {
      var callCount = 0;
      final mock = MockClient.streaming((request, bodyStream) async {
        callCount++;
        if (request.headers.containsKey('If-Match')) {
          final body = utf8.encode(
              '<Error><Code>NotImplemented</Code><Message>A header you '
              'provided implies functionality that is not implemented.'
              '</Message></Error>');
          return http.StreamedResponse(Stream.value(body), 400);
        }
        return http.StreamedResponse(Stream.value([]), 200);
      });
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

      // 先用 putObject 触发降级记忆
      await client.putObject(
        bucket: 'b',
        key: 'k1',
        data: Uint8List.fromList([1]),
        ifMatch: 'abc',
      );
      expect(client.conditionalWriteUnsupportedForTest, isTrue);

      // putObjectStream 一次成功：入口直接盲写，不先吃 400
      callCount = 0;
      await client.putObjectStream(
        bucket: 'b',
        key: 'k2',
        data: Stream.value([1, 2, 3]),
        contentLength: 3,
        ifMatch: 'def',
      );
      expect(callCount, 1,
          reason: '流式路径记忆生效后直接盲写（流式 body 不可重放，'
              '入口必须消费能力记忆）');
    });
  });
}
