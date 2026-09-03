import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_cloud_sync_s3/src/s3_storage_service.dart';

S3Client _client(http.BaseClient mock) => S3Client(
      endpoint: 'minio.local',
      region: 'us-east-1',
      accessKey: 'ak',
      secretKey: 'sk',
      useSSL: false,
      forcePathStyle: true,
      httpClient: mock,
    );

/// 捕获请求体的 mock：finalize 请求体流并收集字节，供断言「泵入的
/// 数据与源流一致」。
class _CapturingClient extends http.BaseClient {
  _CapturingClient(this.handler);
  final Future<http.StreamedResponse> Function(
      http.BaseRequest request, List<int> body) handler;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final body = await request.finalize().toBytes();
    return handler(request, body);
  }
}

/// 中途断流的下载 mock：响应头发 200，body 流发出两块后抛错。
class _MidStreamErrorClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.finalize();
    Stream<List<int>> broken() async* {
      yield [104, 105];
      throw Exception('connection reset');
    }

    return http.StreamedResponse(broken(), 200);
  }
}

/// 停滞的下载 mock：响应头发 200，body 流永不发出任何事件。
class _StalledStreamClient extends http.BaseClient {
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    request.finalize();
    return http.StreamedResponse(
      Stream<List<int>>.fromFuture(Completer<List<int>>().future),
      200,
    );
  }
}

http.StreamedResponse _ok({Map<String, String> headers = const {}}) =>
    http.StreamedResponse(http.ByteStream.fromBytes(const []), 200,
        headers: headers);

void main() {
  group('S3Client.putObjectStream（M4 流式上传）', () {
    test('200：body 与源流一致、UNSIGNED-PAYLOAD 签名、contentLength 透传', () async {
      final chunks = <List<int>>[
        Uint8List.fromList(List.generate(1024, (i) => i % 256)),
        Uint8List.fromList([1, 2, 3]),
      ];
      http.BaseRequest? capturedRequest;
      List<int>? capturedBody;

      final client = _client(_CapturingClient((request, body) async {
        capturedRequest = request;
        capturedBody = body;
        return _ok(headers: {'etag': '"abc123"'});
      }));

      final etag = await client.putObjectStream(
        bucket: 'mybucket',
        key: 'path/big.bin',
        data: Stream.fromIterable(chunks),
        contentLength: 1027,
      );

      expect(etag, 'abc123');
      expect(capturedRequest!.url.path, '/mybucket/path/big.bin');
      expect(capturedRequest!.contentLength, 1027);
      // 流式签名核心：不签 body，声明 UNSIGNED-PAYLOAD
      expect(capturedRequest!.headers['x-amz-content-sha256'],
          'UNSIGNED-PAYLOAD');
      // 泵入的字节与源流逐字节一致
      expect(
        capturedBody,
        orderedEquals([...chunks[0], ...chunks[1]]),
      );
    });

    test('metadata 透传为 x-amz-meta-* 头', () async {
      http.BaseRequest? capturedRequest;
      final client = _client(_CapturingClient((request, body) async {
        capturedRequest = request;
        return _ok();
      }));

      await client.putObjectStream(
        bucket: 'b',
        key: 'k',
        data: Stream.fromIterable([[1]]),
        metadata: {'fingerprint': 'deadbeef'},
      );

      expect(capturedRequest!.headers.containsKey('x-amz-meta-fingerprint'),
          isTrue);
    });

    test('412（条件写失败）翻译为 S3PreconditionFailedException', () async {
      final client = _client(_CapturingClient((request, body) async {
        return http.StreamedResponse(
            http.ByteStream.fromBytes(utf8.encode('<Error/>')), 412);
      }));

      await expectLater(
        client.putObjectStream(
          bucket: 'b',
          key: 'k',
          data: Stream.fromIterable([[1]]),
          ifMatch: 'old',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
    });

    test('409 条件冲突不自动重试（流式 body 不可重放），仅发 1 次请求', () async {
      var requests = 0;
      final client = _client(_CapturingClient((request, body) async {
        requests++;
        return http.StreamedResponse(
            http.ByteStream.fromBytes(utf8.encode('<Error/>')), 409);
      }));

      await expectLater(
        client.putObjectStream(
          bucket: 'b',
          key: 'k',
          data: Stream.fromIterable([[1]]),
          ifMatch: 'old',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
      expect(requests, 1);
    });

    test('源流中途失败：抛 S3Exception 且只发 1 次请求', () async {
      var requests = 0;
      final client = _client(_CapturingClient((request, body) async {
        requests++;
        return _ok();
      }));

      final controller = StreamController<List<int>>();
      final future = client.putObjectStream(
        bucket: 'b',
        key: 'k',
        data: controller.stream,
      );
      controller.add([1, 2, 3]);
      await Future<void>.delayed(Duration.zero);
      controller.addError(Exception('disk failure'));
      await controller.close();

      await expectLater(
        future,
        throwsA(isA<S3Exception>()),
      );
      // 上传已中止，不会重试
      expect(requests, 1);
    });

    test('服务器早响应（412 先于 body 发送完）：停止泵并按条件失败上抛', () async {
      // MockClient 的 handler 不消费请求体立即返回 —— 模拟服务器
      // 早响应。断言点：调用不挂起且语义正确（竞速护栏取消泵）。
      final mock = MockClient((request) async {
        return http.Response('conflict', 412);
      });
      final client = _client(mock);

      await expectLater(
        client.putObjectStream(
          bucket: 'b',
          key: 'k',
          data: Stream.fromIterable(
              [List.generate(1024, (i) => i)]), // 大于缓冲的流
          ifMatch: 'old',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
      );
    });
  });

  group('S3Client.downloadStream（M5 流式下载）', () {
    test('200：分块 stream 逐块送达、拼接与原文一致', () async {
      final part1 = List.generate(2048, (i) => i % 256);
      final part2 = [9, 8, 7];

      final client = _client(_CapturingClient((request, body) async {
        return http.StreamedResponse(
          http.ByteStream.fromBytes([...part1, ...part2]),
          200,
        );
      }));

      final stream = await client.downloadStream(bucket: 'b', key: 'k');
      final received = <int>[];
      await for (final chunk in stream) {
        received.addAll(chunk);
      }
      expect(received, orderedEquals([...part1, ...part2]));
    });

    test('404：抛 S3ObjectNotFoundException', () async {
      final client = _client(_CapturingClient((request, body) async {
        return http.StreamedResponse(
            http.ByteStream.fromBytes(utf8.encode('<Error/>')), 404);
      }));

      await expectLater(
        client.downloadStream(bucket: 'b', key: 'k'),
        throwsA(isA<S3ObjectNotFoundException>()),
      );
    });

    test('404 桶级错误（NoSuchBucket）：抛 S3BucketNotFoundException', () async {
      final client = _client(_CapturingClient((request, body) async {
        return http.StreamedResponse(
            http.ByteStream.fromBytes(utf8.encode(
                '<Error><Code>NoSuchBucket</Code><Message>nope</Message></Error>')),
            404);
      }));

      await expectLater(
        client.downloadStream(bucket: 'b', key: 'k'),
        throwsA(isA<S3BucketNotFoundException>()),
      );
    });

    test('首字节 5xx：安全自动重试直至成功（body 未交给调用方）', () async {
      var attempts = 0;
      final client = _client(_CapturingClient((request, body) async {
        attempts++;
        if (attempts == 1) {
          return http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('<Error/>')), 503);
        }
        return http.StreamedResponse(
          http.ByteStream.fromBytes([1, 2, 3]),
          200,
        );
      }));

      final stream = await client.downloadStream(bucket: 'b', key: 'k');
      final received = <int>[];
      await for (final chunk in stream) {
        received.addAll(chunk);
      }
      expect(received, [1, 2, 3]);
      expect(attempts, 2);
    });

    test('消费期停滞超过 stallTimeout：注入 S3NetworkException 终止', () async {
      final client = _client(_StalledStreamClient());
      final stream = await client.downloadStream(
        bucket: 'b',
        key: 'k',
        stallTimeout: const Duration(milliseconds: 150),
      );

      await expectLater(
        stream.toList(),
        throwsA(isA<S3NetworkException>()),
      );
    });
  });

  group('S3StorageService 流式接口', () {
    test('uploadStream：key 前缀与 metadata 正确下发', () async {
      http.BaseRequest? capturedRequest;
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          capturedRequest = request;
          return _ok();
        })),
        'mybucket',
        keyPrefix: 'piggycount/',
      );

      await service.uploadStream(
        path: 'ledger.json',
        data: Stream.fromIterable([utf8.encode('{}')]),
        contentLength: 2,
        metadata: {'fingerprint': 'abc'},
      );

      expect(capturedRequest!.url.path, '/mybucket/piggycount/ledger.json');
      expect(capturedRequest!.headers.containsKey('x-amz-meta-fingerprint'),
          isTrue);
    });

    test('uploadStream 条件写 412：翻译为 CloudPreconditionFailedException',
        () async {
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          return http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('<Error/>')), 412);
        })),
        'mybucket',
      );

      await expectLater(
        service.uploadStream(
          path: 'ledger.json',
          data: Stream.fromIterable([[1]]),
          ifMatchEtag: 'old',
        ),
        throwsA(isA<CloudPreconditionFailedException>()),
      );
    });

    test('downloadToSink：内容逐字节落盘、原子发布、无 tmp 残留、返回字节数',
        () async {
      final payload = List.generate(5000, (i) => i % 256);
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          return http.StreamedResponse(
            http.ByteStream.fromBytes(payload),
            200,
          );
        })),
        'mybucket',
      );

      final dir = await Directory.systemTemp.createTemp('s3_stream_test');
      final target = '${dir.path}/out.bin';
      try {
        final written = await service.downloadToSink(
          path: 'attachments/big.bin',
          localPath: target,
        );

        expect(written, payload.length);
        expect(File(target).readAsBytesSync(), payload);
        // 原子发布后无 tmp 残留（按文件名比较，避免路径分隔符差异）
        expect(
          dir.listSync().whereType<File>().map((f) => f.path.split(Platform.pathSeparator).last).toSet(),
          {'out.bin'},
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('downloadToSink：远端不存在返回 null，不创建目标文件', () async {
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          return http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('<Error/>')), 404);
        })),
        'mybucket',
      );

      final dir = await Directory.systemTemp.createTemp('s3_stream_test');
      final target = '${dir.path}/missing.bin';
      try {
        expect(
          await service.downloadToSink(path: 'x', localPath: target),
          isNull,
        );
        expect(File(target).existsSync(), isFalse);
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('downloadToSink：流中途断流 → 抛 CloudStorageException、tmp 清理、目标未创建',
        () async {
      final service = S3StorageService(_client(_MidStreamErrorClient()), 'mybucket');

      final dir = await Directory.systemTemp.createTemp('s3_stream_test');
      final target = '${dir.path}/broken.bin';
      try {
        await expectLater(
          service.downloadToSink(path: 'x', localPath: target),
          throwsA(isA<CloudStorageException>()),
        );
        expect(File(target).existsSync(), isFalse);
        // 失败后无 tmp 残留
        expect(dir.listSync(), isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  group('文件路径接口走流式（uploadFile/downloadFile 切换流式后行为兼容）', () {
    test('uploadFile → downloadFile roundtrip（2MB，逐字节一致）', () async {
      // 存量测试缺陷修复：旧 mock 上传/下载一律返回空 200（_ok()），
      // 下载端恒拿空文件 → expect 逐字节比对必然失败（基线上即红）。
      // 正确语义：PUT 捕获 body，GET 回放同一 body —— 模拟真实 S3
      // 的对象往返，roundtrip 断言才有意义。
      List<int>? uploadedBody;
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          if (request.method == 'PUT') {
            uploadedBody = body;
            return _ok();
          }
          return http.StreamedResponse(
            http.ByteStream.fromBytes(uploadedBody ?? const []),
            200,
          );
        })),
        'mybucket',
      );

      final dir = await Directory.systemTemp.createTemp('s3_stream_test');
      final local = '${dir.path}/snapshot.json';
      const remote = 'backup/snapshot.json';
      final payload = List.generate(2 * 1024 * 1024, (i) => i % 256);
      try {
        File(local).writeAsBytesSync(payload);
        await service.uploadFile(local, remote);

        final restored = '${dir.path}/restored.json';
        await service.downloadFile(remote, restored);
        expect(File(restored).readAsBytesSync(), payload);
        // 原子发布后无 tmp 残留（按文件名比较，避免 Windows 路径分隔符
        // 差异 —— 同款处理见上方 downloadToSink 用例）
        expect(
          dir.listSync().whereType<File>().map((f) => f.path.split(Platform.pathSeparator).last).toSet(),
          {'snapshot.json', 'restored.json'},
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });

    test('downloadFile：远端不存在 → CloudStorageException("File not found")',
        () async {
      final service = S3StorageService(
        _client(_CapturingClient((request, body) async {
          return http.StreamedResponse(
              http.ByteStream.fromBytes(utf8.encode('<Error/>')), 404);
        })),
        'mybucket',
      );

      final dir = await Directory.systemTemp.createTemp('s3_stream_test');
      final target = '${dir.path}/nope.bin';
      try {
        await expectLater(
          service.downloadFile('x', target),
          throwsA(isA<CloudStorageException>()),
        );
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });
}
