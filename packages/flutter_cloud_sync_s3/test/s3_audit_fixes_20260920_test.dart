/// 2026-09-20 全面技术探查批次：S3 适配器修复回归。
///
/// 覆盖本轮修复项：
/// - S3-M1：ListObjects 分页重试粒度收敛到**单页**（单页瞬时故障不再从
///   第 1 页全量重翻，避免大桶带宽/费用倍增）；
/// - S3-M3：含点 bucket 在托管云端点上默认 path-style（virtual-hosted 会
///   因通配证书单层标签限制导致 TLS 握手失败）；
/// - S3-L2：自定义 timeout > 传输封顶值（5min）时 transferTimeoutFor 不再抛
///   ArgumentError；
/// - S3-L5：XML 错误消息截断（畸形网关回传数 KB 文本不再撑爆日志）。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_cloud_sync_s3/src/s3_provider.dart';

String _pageXml({
  List<String> keys = const [],
  bool truncated = false,
  String? nextToken,
}) {
  final contents = keys
      .map((k) => '<Contents><Key>$k</Key><Size>1</Size></Contents>')
      .join();
  return '<?xml version="1.0"?>'
      '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '<IsTruncated>$truncated</IsTruncated>'
      '${nextToken != null ? '<NextContinuationToken>$nextToken</NextContinuationToken>' : ''}'
      '$contents</ListBucketResult>';
}

S3Client _client(MockClient mock, {Duration? timeout}) => S3Client(
      endpoint: 'minio.local',
      region: 'us-east-1',
      accessKey: 'ak',
      secretKey: 'sk',
      useSSL: false,
      forcePathStyle: true,
      timeout: timeout ?? const Duration(seconds: 30),
      httpClient: mock,
    );

void main() {
  group('S3-M1：ListObjects 分页重试粒度 = 单页', () {
    test('第 2 页瞬时 500 → 只重试该页，第 1 页不再被重翻', () async {
      final requests = <Uri>[];
      var page2FailedOnce = false;
      final mock = MockClient((request) async {
        requests.add(request.url);
        final token = request.url.queryParameters['continuation-token'];
        if (token == null) {
          return http.Response(
              _pageXml(keys: ['a'], truncated: true, nextToken: 'T1'), 200);
        }
        if (token == 'T1' && !page2FailedOnce) {
          page2FailedOnce = true;
          return http.Response('server error', 500);
        }
        return http.Response(_pageXml(keys: ['b'], truncated: false), 200);
      });
      final client = _client(mock);

      final result = await client.listObjectsDetailed(bucket: 'b');

      expect(result.map((o) => o.key).toList(), ['a', 'b']);
      final firstPageRequests = requests
          .where((u) => !u.queryParameters.containsKey('continuation-token'))
          .length;
      expect(firstPageRequests, 1,
          reason: 'M1: 后续页故障不得导致第 1 页被重新拉取（旧实现整段重试）');
    });
  });

  group('S3-M3：含点 bucket 的寻址方式推断', () {
    test('托管云 + 含点 bucket → path-style（规避 TLS 证书不匹配）', () {
      expect(
        resolveForcePathStyle(
            explicit: null, host: 's3.amazonaws.com', bucket: 'my.bucket'),
        isTrue,
      );
      expect(
        resolveForcePathStyle(
            explicit: null,
            host: 's3.us-east-1.amazonaws.com',
            bucket: 'com.example.data'),
        isTrue,
      );
    });

    test('托管云 + 无点 bucket → virtual-hosted（保持既有行为）', () {
      expect(
        resolveForcePathStyle(
            explicit: null, host: 's3.amazonaws.com', bucket: 'piggycount'),
        isFalse,
      );
    });

    test('自托管端点 → path-style', () {
      expect(
        resolveForcePathStyle(
            explicit: null, host: 'minio.local', bucket: 'piggycount'),
        isTrue,
      );
    });

    test('显式配置优先于推断', () {
      expect(
        resolveForcePathStyle(
            explicit: false, host: 's3.amazonaws.com', bucket: 'my.bucket'),
        isFalse,
      );
      expect(
        resolveForcePathStyle(
            explicit: true, host: 's3.amazonaws.com', bucket: 'piggycount'),
        isTrue,
      );
    });
  });

  group('S3-L2：transferTimeoutFor 大基线不再抛 ArgumentError', () {
    test('timeout > 5min 封顶值时按 timeout 自身为上界（不静默钳短）', () {
      final client = _client(MockClient((_) async => http.Response('', 200)),
          timeout: const Duration(minutes: 10));

      // 旧实现 clamp(lower=10min, upper=5min) → ArgumentError
      final d = client.transferTimeoutFor(5 * 1024 * 1024);
      expect(d.inMinutes, greaterThanOrEqualTo(10));
      expect(client.transferTimeoutFor(0), const Duration(minutes: 10));
    });
  });

  group('S3-L5：XML 错误消息截断', () {
    test('超长 <Message> 被截断到 300 字符（不再撑爆异常与日志）', () async {
      final hugeMessage = 'A' * 5000;
      final mock = MockClient((_) async => http.Response(
            '<?xml version="1.0"?><Error><Code>InvalidAccessKeyId</Code>'
            '<Message>$hugeMessage</Message></Error>',
            403,
          ));
      final client = _client(mock);

      await expectLater(
        client.listObjectsDetailed(bucket: 'b'),
        throwsA(isA<S3AuthException>().having(
            (e) => e.message.length, 'message length', lessThan(400))),
      );

      try {
        await client.listObjectsDetailed(bucket: 'b');
      } on S3Exception catch (e) {
        expect(e.message.contains('…'), isTrue,
            reason: 'L5: 截断必须留可见标记，便于判断消息被裁剪');
      }
    });
  });
}
