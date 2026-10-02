import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_cloud_sync_s3/src/s3_storage_service.dart';

/// 2026-10-01 真机实测（阿里云 OSS）：条件 PUT 在连接层中断时的降级回归。
///
/// 背景：OSS 收到不支持的 `If-Match`/`If-None-Match` 时，会在请求体
/// **尚未写完**时就拒绝并断开连接 —— 客户端仍在写 body，传输层直接抛
/// SocketException（`Write failed` / `Broken pipe` / `Connection reset`
/// / `Read failed`），**那个 400 响应根本读不到**。既有「HTTP 400 +
/// NotImplemented」判据因此不可达，条件写恒失败（真机 R2/R3 增量上传
/// 8/8 全失败；R1 因云端无对象不带条件头而 8/8 成功）。
///
/// 本组用例钉住修复后的契约：
/// - 「对端在传输中断开」这类连接层失败同样触发条件写降级（去条件头
///   盲写重发一次），并记忆网关能力；
/// - 真实的链路故障（网络不可达等）与盲写路径**不得**触发降级 ——
///   否则一次弱网就会让本会话后续上传全部退化为盲写，丢掉并发保护。
void main() {
  Uint8List payload() => Uint8List.fromList(utf8.encode('{"k":1}'));

  S3Client clientWith(http.Client mock) => S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

  group('条件 PUT 连接层中断触发降级（OSS 实测）', () {
    test('持续 Write failed → 锚点重试耗尽后去条件头盲写重发一次并成功', () async {
      var calls = 0;
      final conditionalSeen = <bool>[];
      final mock = MockClient((request) async {
        calls++;
        conditionalSeen.add(request.headers.containsKey('If-Match'));
        if (calls <= 3) {
          throw const SocketException('Write failed');
        }
        return http.Response('', 200, headers: {'etag': '"after-drop"'});
      });
      final client = clientWith(mock);
      final downgrades = <String>[];
      client.onConditionalWriteDowngrade = downgrades.add;

      final etag = await client.putObject(
        bucket: 'b',
        key: 'ledger_x.json',
        data: payload(),
        ifMatch: 'abc123',
      );

      expect(etag, 'after-drop');
      // 首发条件写 + 2 次锚点重试（3 次都带条件头）→ 第 4 次请求已去条件头
      expect(conditionalSeen, [true, true, true, false],
          reason: '降级后重发的请求必须去掉条件头');
      expect(calls, 4);
      expect(downgrades, hasLength(1), reason: '首次降级留一条 warning 线索');
      expect(downgrades.first, contains('不支持条件写'));
      expect(client.conditionalWriteUnsupportedForTest, isTrue);
      expect(client.conditionalWriteSupported, isFalse,
          reason: '生产读取口必须反映真实能力，供 supportsConditionalWrite 动态申报');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('降级盲写后仍连接中断 → 只降级一次，按网络异常上抛', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        throw const SocketException('Broken pipe');
      });
      final client = clientWith(mock);
      final downgrades = <String>[];
      client.onConditionalWriteDowngrade = downgrades.add;

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k.json',
          data: payload(),
          ifMatch: 'abc',
        ),
        throwsA(isA<S3NetworkException>()),
      );

      // calls 1~3 = 条件写首发 + 2 次锚点重试；call 4 = 降级后的盲写（盲写不重试）
      expect(calls, 4);
      expect(downgrades, hasLength(1), reason: '降级只允许发生一次');
      expect(client.conditionalWriteUnsupportedForTest, isTrue);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('盲写（无条件头）连接中断 → 不触发降级、不重试', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        throw const SocketException('Write failed');
      });
      final client = clientWith(mock);
      final downgrades = <String>[];
      client.onConditionalWriteDowngrade = downgrades.add;

      await expectLater(
        client.putObject(bucket: 'b', key: 'k.json', data: payload()),
        throwsA(isA<S3NetworkException>()),
      );

      expect(calls, 1, reason: '盲写维持不重试纪律（A-1 覆盖竞态未修）');
      expect(downgrades, isEmpty, reason: '与条件头无关的连接失败不得判定网关能力');
      expect(client.conditionalWriteUnsupportedForTest, isNull);
    });

    test('非「对端断开」型链路故障（网络不可达）→ 不降级', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        throw const SocketException('Network is unreachable');
      });
      final client = clientWith(mock);
      final downgrades = <String>[];
      client.onConditionalWriteDowngrade = downgrades.add;

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k.json',
          data: payload(),
          ifMatch: 'abc',
        ),
        throwsA(isA<S3NetworkException>()),
      );

      expect(calls, 3, reason: '首发 + 2 次锚点重试后上抛，不额外盲写重发');
      expect(downgrades, isEmpty,
          reason: '真实链路故障不能把网关判成不支持条件写 —— '
              '否则一次弱网会让本会话后续上传全部退化为盲写');
      expect(client.conditionalWriteUnsupportedForTest, isNull);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('首次连接层降级后记忆能力：后续条件上传入口直接盲写', () async {
      var calls = 0;
      final conditionalSeen = <bool>[];
      final mock = MockClient((request) async {
        calls++;
        conditionalSeen.add(request.headers.containsKey('If-Match'));
        if (calls <= 3) {
          throw const SocketException('Connection reset by peer');
        }
        return http.Response('', 200, headers: {'etag': '"e$calls"'});
      });
      final client = clientWith(mock);

      // 第一次：条件写首发 + 2 次锚点重试均连接中断 → 降级盲写成功
      await client.putObject(
        bucket: 'b',
        key: 'k1',
        data: payload(),
        ifMatch: 'abc',
      );
      expect(client.conditionalWriteUnsupportedForTest, isTrue);
      expect(calls, 4);

      // 第二次：能力记忆生效，入口直接盲写（1 次请求）
      final etag = await client.putObject(
        bucket: 'b',
        key: 'k2',
        data: payload(),
        ifMatch: 'def',
      );
      expect(etag, 'e5');
      expect(calls, 5);
      expect(conditionalSeen.last, isFalse, reason: '记忆生效后不再白付一次条件写失败往返');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });

  group('条件写能力动态申报', () {
    test('supportsConditionalWrite 随能力记忆由 true 变 false，上层锚点随之解除', () async {
      final mock = MockClient((request) async {
        if (request.headers.containsKey('If-Match')) {
          throw const SocketException('Write failed');
        }
        return http.Response('', 200, headers: {'etag': '"e"'});
      });
      final client = clientWith(mock);
      final service = S3StorageService(client, 'b');

      expect(service.supportsConditionalWrite, isTrue,
          reason: '尚未探测到不支持前，如实申报支持');
      expect(service.conditionalOrNull, isNotNull);

      await service.uploadBinaryConditional(
        path: 'ledger_x.json',
        bytes: [1, 2, 3],
        ifMatchEtag: 'abc',
      );

      expect(service.supportsConditionalWrite, isFalse,
          reason: '确认网关不支持后必须退化为盲上传，避免每次白付失败往返');
      expect(service.conditionalOrNull, isNull,
          reason: 'manager 走 conditionalOrNull 判定，据此不再下发条件锚点');
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
