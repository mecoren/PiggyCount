/// 审计 S3-M2 / S3-M3：ListObjects 分页终止护栏与协议回退及时性。
///
/// - M2：maxKeys=null 的常规翻页路径此前无任何终止护栏——故障网关
///   （恒 IsTruncated=true / 回放同一 token / 忽略 marker / 截断却无
///   推进凭据）会让 do-while 无限翻页或静默返回残缺列表。
/// - M3：V2 返回 501（Not Implemented）是确定性失败，不应被 5xx 重试
///   放大——修复前 3 次 V2 重试 + 退避延迟后才走 V1 回退。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';

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
  group('审计 S3-M2：ListObjects V2 翻页终止护栏', () {
    test('网关回放同一 continuation-token → 显式失败而非无限翻页', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        // 每页都返回截断 + 同一个 token T1
        return http.Response(
            _pageXml(keys: ['a'], truncated: true, nextToken: 'T1'), 200);
      });
      final client = _client(mock);

      await expectLater(
        client.listObjectsDetailed(bucket: 'b'),
        throwsA(isA<S3Exception>()
            .having((e) => e.message, 'message', contains('stalled'))),
      );
      expect(requests.length, 2,
          reason: 'M2: 第 3 页进入前即检测到 token 无推进，不得继续翻页');
    });

    test('IsTruncated=true 但无 NextContinuationToken → 显式失败而非静默残缺', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        return http.Response(_pageXml(keys: ['a'], truncated: true), 200);
      });
      final client = _client(mock);

      await expectLater(
        client.listObjectsDetailed(bucket: 'b'),
        throwsA(isA<S3Exception>()
            .having((e) => e.message, 'message', contains('malformed'))),
      );
      expect(requests.length, 1,
          reason: 'M2: 畸形响应在第 1 页即暴露，不得静默返回不完整列表');
    });

    test('正常多页（token 单调推进）不受护栏影响', () async {
      final mock = MockClient((request) async {
        final token = request.url.queryParameters['continuation-token'];
        if (token == null) {
          return http.Response(
              _pageXml(keys: ['a'], truncated: true, nextToken: 'T1'), 200);
        }
        if (token == 'T1') {
          return http.Response(
              _pageXml(keys: ['b'], truncated: true, nextToken: 'T2'), 200);
        }
        return http.Response(_pageXml(keys: ['c'], truncated: false), 200);
      });
      final client = _client(mock);

      final objects = await client.listObjectsDetailed(bucket: 'b');
      expect(objects.map((o) => o.key), ['a', 'b', 'c']);
    });
  });

  group('审计 S3-M2：ListObjects V1 翻页终止护栏', () {
    test('网关忽略 marker（每页返回相同内容）→ 显式失败而非无限翻页', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        if (request.url.queryParameters.containsKey('list-type')) {
          // V2 明确 501 → 立即回退 V1（顺带验证 M3 语义）
          return http.Response('<Error><Code>NotImplemented</Code></Error>', 501);
        }
        // V1：忽略 marker，每页返回相同内容且恒截断
        return http.Response(_pageXml(keys: ['a', 'b'], truncated: true), 200);
      });
      final client = _client(mock);

      await expectLater(
        client.listObjectsDetailed(bucket: 'b'),
        throwsA(isA<S3Exception>()
            .having((e) => e.message, 'message', contains('stalled'))),
      );
      expect(requests.length, 3,
          reason: 'M2: 1 次 V2（501 立即回退）+ 2 页 V1，第 3 页进入前检测到 marker 无推进');
    });

    test('V1 截断却无尾 key（空页截断）→ 显式失败而非静默残缺', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        if (request.url.queryParameters.containsKey('list-type')) {
          return http.Response('<Error><Code>NotImplemented</Code></Error>', 501);
        }
        return http.Response(_pageXml(keys: [], truncated: true), 200);
      });
      final client = _client(mock);

      await expectLater(
        client.listObjectsDetailed(bucket: 'b'),
        throwsA(isA<S3Exception>()
            .having((e) => e.message, 'message', contains('malformed'))),
      );
      expect(requests.length, 2, reason: 'M2: 1 次 V2 + 1 页 V1 即暴露畸形');
    });
  });

  group('审计 S3-M3：V2→V1 协议回退不被 5xx 重试放大', () {
    test('V2 返回 501 → 不重试，立即回退 V1 成功', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        if (request.url.queryParameters.containsKey('list-type')) {
          return http.Response('<Error><Code>NotImplemented</Code></Error>', 501);
        }
        return http.Response(_pageXml(keys: ['x', 'y'], truncated: false), 200);
      });
      final client = _client(mock);

      final objects = await client.listObjectsDetailed(bucket: 'b');
      expect(objects.map((o) => o.key), ['x', 'y']);
      expect(requests.length, 2,
          reason: 'M3: 1 次 V2 + 1 次 V1（修复前 501 计入 5xx 重试：3 次 V2 + 退避 + 1 次 V1 = 4 请求）');
    });
  });
}
