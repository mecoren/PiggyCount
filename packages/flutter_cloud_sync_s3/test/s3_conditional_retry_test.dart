import 'dart:convert';
import 'dart:io' show SocketException;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';

/// P1-1（2026-09-09）：条件 PUT 的瞬时网络故障安全重试回归。
///
/// 安全性论证核心：带 If-Match 锚点时，「超时但服务端已落盘」的 A-1
/// 歧态由锚点化解 —— 远端 ETag 已变 → 重试吃 412 → 翻译为冲突流程
///（上层走用户确认/合并），绝不静默覆盖；未落盘则重试正常完成。
/// 盲写路径维持不重试纪律（A-1 未修，写后校验兜底）。
void main() {
  Uint8List payload() => Uint8List.fromList(utf8.encode('{"k":1}'));

  S3Client clientWith(http.Client mock) => S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        httpClient: mock,
      );

  group('条件 PUT 网络故障安全重试（P1-1）', () {
    test('超时一次后重试成功 → 正常返回（服务端未落盘场景）', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        if (calls == 1) {
          // 模拟超时：抛 TimeoutException 等价的挂起（直接 throw 由
          // .timeout 触发不了 —— MockClient 无法真挂起，改为首次抛
          // SocketException 走同一 netRetries 路径）
          throw const SocketException('connection reset');
        }
        return http.Response('', 200, headers: {'etag': '"v2"'});
      });
      final client = clientWith(mock);

      final etag = await client.putObject(
        bucket: 'b',
        key: 'k.json',
        data: payload(),
        ifMatch: 'v1',
      );

      expect(etag, 'v2');
      expect(calls, 2, reason: '首次网络故障 + 安全重试一次');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('超时但服务端已落盘 → 重试吃 412 → 翻译为冲突（不覆盖他机数据）',
        () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        if (calls == 1) {
          throw const SocketException('connection reset mid-flight');
        }
        // 第二次：远端 ETag 已变（首次请求实际已落盘）→ 网关 412
        return http.Response(
            '<?xml version="1.0"?><Error><Code>PreconditionFailed</Code>'
            '<Message>The conditional request failed</Message></Error>',
            412);
      });
      final client = clientWith(mock);

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k.json',
          data: payload(),
          ifMatch: 'v1',
        ),
        throwsA(isA<S3PreconditionFailedException>()),
        reason: '重试吃 412 是安全重试的核心保证：歧态显式化为冲突，'
            '绝不静默覆盖他机数据',
      );
      expect(calls, 2);
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('持续网络故障 → 重试 ≤2 次后按网络异常上抛', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        throw const SocketException('persistent failure');
      });
      final client = clientWith(mock);

      await expectLater(
        client.putObject(
          bucket: 'b',
          key: 'k.json',
          data: payload(),
          ifMatch: 'v1',
        ),
        throwsA(isA<S3Exception>()),
      );
      expect(calls, 3, reason: '首次 + 2 次安全重试');
    }, timeout: const Timeout(Duration(seconds: 10)));

    test('盲写（无 If-Match）网络故障 → 维持不重试纪律', () async {
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        throw const SocketException('connection reset');
      });
      final client = clientWith(mock);

      await expectLater(
        client.putObject(bucket: 'b', key: 'k.json', data: payload()),
        throwsA(isA<S3Exception>()),
      );
      expect(calls, 1, reason: '盲写重试存在 A-1 覆盖竞态（超时但已落盘，'
          '重试会用旧快照覆盖可能已被他机更新的数据），维持不重试');
    });

    test('onRetryEvent 逐次留痕（LOG-06）', () async {
      final events = <String>[];
      var calls = 0;
      final mock = MockClient((request) async {
        calls++;
        if (calls <= 2) {
          throw const SocketException('flaky network');
        }
        return http.Response('', 200, headers: {'etag': '"v3"'});
      });
      final client = clientWith(mock);
      client.onRetryEvent = events.add;

      await client.putObject(
        bucket: 'b',
        key: 'k.json',
        data: payload(),
        ifMatch: 'v2',
      );

      expect(events.length, 2, reason: '两次网络故障各留一条重试痕迹');
      expect(events.first, contains('第 1/2 次安全重试'));
    }, timeout: const Timeout(Duration(seconds: 10)));
  });
}
