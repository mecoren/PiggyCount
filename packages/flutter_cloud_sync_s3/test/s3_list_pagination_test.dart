import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';

/// W3 回归：maxKeys 是「结果总数上限」，分页循环达到上限必须立即停止。
///
/// 之前 do-while 只看 continuationToken，`listObjects(maxKeys: 1)` 连接探测
/// 会翻页拉取全桶对象；故障网关恒返回 IsTruncated=true 时直接死循环。
void main() {
  String pageXml(List<String> keys, {required bool truncated}) {
    final contents = keys
        .map((k) => '<Contents><Key>$k</Key></Contents>')
        .join();
    return '<?xml version="1.0"?>'
        '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
        '$contents'
        '<IsTruncated>$truncated</IsTruncated>'
        '${truncated ? '<NextContinuationToken>token-x</NextContinuationToken>' : ''}'
        '</ListBucketResult>';
  }

  test('maxKeys=1 时只发一次请求且只返回 1 条（不再全量翻页）', () async {
    var requestCount = 0;
    final mock = MockClient((request) async {
      requestCount++;
      // 服务端每页只有 1 条但永远 IsTruncated=true（模拟故障网关/超大桶）
      return http.Response(pageXml(['only-one.txt'], truncated: true), 200);
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

    final infos = await client.listObjectsDetailed(
      bucket: 'mybucket',
      maxKeys: 1,
    ).timeout(const Duration(seconds: 10), onTimeout: () {
      fail('listObjects 死循环：maxKeys=1 未在单次请求后停止翻页');
    });

    expect(requestCount, 1, reason: '达到 maxKeys 上限后不得继续翻页');
    expect(infos.length, 1);
    expect(infos.single.key, 'only-one.txt');
  });

  test('maxKeys 跨页累计：每页 2 条、上限 5 → 3 页共 5 条', () async {
    var page = 0;
    late int firstPageMaxKeys;
    late int secondPageMaxKeys;
    final mock = MockClient((request) async {
      page++;
      if (page == 1) {
        firstPageMaxKeys = int.parse(request.url.queryParameters['max-keys']!);
        return http.Response(
            pageXml(['k1', 'k2'], truncated: true), 200);
      }
      if (page == 2) {
        secondPageMaxKeys =
            int.parse(request.url.queryParameters['max-keys']!);
        return http.Response(
            pageXml(['k3', 'k4'], truncated: true), 200);
      }
      return http.Response(pageXml(['k5', 'k6-extra'], truncated: true), 200);
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

    final infos = await client.listObjectsDetailed(
      bucket: 'mybucket',
      maxKeys: 5,
    );

    expect(firstPageMaxKeys, 5);
    expect(secondPageMaxKeys, 3, reason: '第二页应请求「还缺多少条」');
    expect(infos.map((e) => e.key).toList(), ['k1', 'k2', 'k3', 'k4', 'k5'],
        reason: '第三页超量的 k6-extra 必须被截断');
  });

  test('未传 maxKeys 时行为不变：完整翻页直到 IsTruncated=false', () async {
    var page = 0;
    final mock = MockClient((request) async {
      page++;
      if (page == 1) {
        expect(request.url.queryParameters.containsKey('max-keys'), isFalse);
        return http.Response(pageXml(['a', 'b'], truncated: true), 200);
      }
      return http.Response(pageXml(['c'], truncated: false), 200);
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

    final infos = await client.listObjects(bucket: 'mybucket');
    expect(page, 2);
    expect(infos, ['a', 'b', 'c']);
  });
}
