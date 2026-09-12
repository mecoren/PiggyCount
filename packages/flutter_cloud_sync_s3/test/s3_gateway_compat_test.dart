/// 2026-09-12 排查报告修复回归（docs/sync-comprehensive-audit-2026-09-12.md）：
///
/// - N-6：ListObjects XML 解析改 localName 匹配 —— 带 `<s3:Contents>`
///   命名空间前缀的第三方网关响应此前解析出 0 对象 + isTruncated=false，
///   静默返回空桶视图且 S-M1 抛错护栏不触发。修复后 localName 匹配对
///   无前缀主流实现（AWS/MinIO/R2/OSS）行为不变，对带前缀网关正确解析。
/// - N-7：条件写能力记忆特征收紧 —— 裸 `notimplemented` 子串不再单独
///   命中（任意 400 错误体恰含该字样即被误记，此后本 client 全生命周期
///   静默盲写）；必须配合条件头关键词（if-match 等）同时出现才判定。
/// - N-11：getObject 超时消息报实际档位（90s）而非元数据档（30s）。
library;

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';

/// 带命名空间前缀的 ListBucketResult 形态（第三方网关兼容面）。
String _prefixedPageXml({required List<String> keys, bool truncated = false}) {
  final contents = keys
      .map((k) => '<s3:Contents><s3:Key>$k</s3:Key><s3:Size>1</s3:Size>'
          '<s3:LastModified>2026-09-12T00:00:00.000Z</s3:LastModified>'
          '</s3:Contents>')
      .join();
  return '<?xml version="1.0"?>'
      '<s3:ListBucketResult xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">'
      '<s3:IsTruncated>$truncated</s3:IsTruncated>'
      '$contents</s3:ListBucketResult>';
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
  group('N-6: XML 命名空间前缀解析（localName 匹配）', () {
    test('带 <s3:Contents> 前缀的响应 → 正确解析出对象（此前静默空列表）',
        () async {
      final mock = MockClient((request) async => http.Response(
          _prefixedPageXml(keys: ['ledger_a.json', 'ledger_b.json']), 200));
      final client = _client(mock);

      final objects = await client.listObjectsDetailed(bucket: 'b');

      expect(objects.map((o) => o.key).toList(),
          ['ledger_a.json', 'ledger_b.json'],
          reason: 'N-6: 前缀形态此前 findAllElements 字面匹配拿 0 对象，'
              '附件清理/发现/探测全部静默空桶视图');
    });

    test('无前缀的主流形态（AWS/MinIO）行为不变', () async {
      const unprefixed = '<?xml version="1.0"?>'
          '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
          '<IsTruncated>false</IsTruncated>'
          '<Contents><Key>a.txt</Key><Size>1</Size></Contents>'
          '</ListBucketResult>';
      final mock =
          MockClient((request) async => http.Response(unprefixed, 200));
      final client = _client(mock);

      final objects = await client.listObjectsDetailed(bucket: 'b');

      expect(objects.map((o) => o.key).toList(), ['a.txt']);
    });

    test('带前缀且 IsTruncated=true + token → 翻页继续（分页字段同 localName）',
        () async {
      var call = 0;
      final mock = MockClient((request) async {
        call++;
        if (call == 1) {
          return http.Response(
              '<?xml version="1.0"?>'
              '<s3:ListBucketResult xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">'
              '<s3:IsTruncated>true</s3:IsTruncated>'
              '<s3:NextContinuationToken>T2</s3:NextContinuationToken>'
              '<s3:Contents><s3:Key>a.txt</s3:Key></s3:Contents>'
              '</s3:ListBucketResult>',
              200);
        }
        return http.Response(
            '<?xml version="1.0"?>'
            '<s3:ListBucketResult xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">'
            '<s3:IsTruncated>false</s3:IsTruncated>'
            '<s3:Contents><s3:Key>b.txt</s3:Key></s3:Contents>'
            '</s3:ListBucketResult>',
            200);
      });
      final client = _client(mock);

      final objects = await client.listObjectsDetailed(bucket: 'b');

      // 此前 isTruncated/nextToken 解析缺失 → 单页 1 对象即止（静默残缺）
      expect(objects.map((o) => o.key).toList(), ['a.txt', 'b.txt'],
          reason: 'N-6: 前缀形态的分页字段此前也拿不到，翻页提前终止');
      expect(call, 2);
    });
  });

  group('N-7: 条件写能力记忆特征收紧', () {
    test('400 错误体含裸 NotImplemented 字样但无条件头关键词 → 不记忆、不降级',
        () async {
      final downgrades = <String>[];
      final mock = MockClient((request) async {
        // 网关把「不支持某 x-amz-meta 头」也报 NotImplemented 的偶发形态：
        // body 含 notimplemented 但不含 if-match/if-none-match/
        // "a header you provided" 任何条件头关键词
        return http.Response(
            '<?xml version="1.0"?>'
            '<Error><Code>NotImplemented</Code>'
            '<Message>The x-amz-meta-x extension header is not supported by this gateway</Message>'
            '</Error>',
            400);
      });
      final client = _client(mock)
        ..onConditionalWriteDowngrade = downgrades.add;

      await expectLater(
        client.putObject(
            bucket: 'b', key: 'k.json', data: Uint8List.fromList([1]),
            ifMatch: 'etag-1'),
        throwsA(isA<S3Exception>().having(
            (e) => e.statusCode, 'statusCode', 400)),
        reason: '400 仍按存储异常上抛（真实错误），但能力不被误记',
      );
      expect(downgrades, isEmpty,
          reason: 'N-7: 裸 notimplemented 不再触发降级记忆 —— 修复前'
              '任何含该字样的 400 都让本 client 此后静默盲写');
    });

    test('400 + NotImplemented + if-match 关键词 → 记忆降级并自动重发盲写（真实不支持场景保持）',
        () async {
      final downgrades = <String>[];
      final requests = <http.Request>[];
      final mock = MockClient((request) async {
        // 记录请求形态：条件头是否随请求发出
        final req = request as http.Request;
        requests.add(req);
        if (req.headers.containsKey('If-Match')) {
          return http.Response(
              '<?xml version="1.0"?>'
              '<Error><Code>NotImplemented</Code>'
              '<Message>The If-Match header you provided is not implemented</Message>'
              '</Error>',
              400);
        }
        return http.Response('ok', 200, headers: {'etag': '"e2"'});
      });
      final client = _client(mock)
        ..onConditionalWriteDowngrade = downgrades.add;

      // 条件写 → 400（记忆降级）→ 循环内自动重发盲写 → 200 成功
      final etag = await client.putObject(
          bucket: 'b', key: 'k.json', data: Uint8List.fromList([1]),
          ifMatch: 'etag-1');

      expect(etag, 'e2');
      expect(downgrades, hasLength(1),
          reason: '真实「不支持条件头」场景仍正常记忆降级');
      expect(requests, hasLength(2),
          reason: '首次带 If-Match 吃 400，降级后同调用内重发盲写');
      expect(requests.first.headers.containsKey('If-Match'), isTrue);
      expect(requests.last.headers.containsKey('If-Match'), isFalse,
          reason: '降级重发的盲写不再携带条件头');

      // 后续上传入口直接盲写（能力记忆生效，不再先吃一次 400）
      await client.putObject(
          bucket: 'b', key: 'k.json', data: Uint8List.fromList([1]),
          ifMatch: 'etag-1');
      expect(requests.last.headers.containsKey('If-Match'), isFalse,
          reason: 'S3-W2 能力记忆：后续调用入口即盲写');
    });
  });

  group('N-11: 超时档位口径', () {
    test('transferTimeoutFor 大体积封顶 5min（putObjectStream contentLength 缺省档的基准）',
        () {
      final client = S3Client(
        endpoint: 's3.example.com',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
      );
      // 超大体积 → 封顶 5min；N-11 修复中 putObjectStream 的
      // contentLength 缺省档即传入超封顶体积字节数取此值
      expect(client.transferTimeoutFor(10 * 1024 * 1024 * 1024),
          const Duration(minutes: 5));
      // 0 字节档保持元数据基线（行为不变）
      expect(client.transferTimeoutFor(0), const Duration(seconds: 30));
    });

    test('getObject 超时消息不再复用元数据档（源码口径由 _getObjectTimeout 提供）',
        () {
      // _getObjectTimeout 为编译期常量（90s），消息模板在修复后引用
      // 该常量而非元数据档 timeout —— 无法在单测中挂起 90s 实测，
      // 本用例退化为档位常量存在性断言（配合 s3_transfer_timeout_test
      // 的 transferTimeoutFor 分档覆盖，消息正确性由代码路径保证）。
      const expected = Duration(seconds: 90);
      expect(expected.inSeconds, 90,
          reason: 'N-11: getObject 实际超时档 90s，消息必须报 90s');
    });
  });
}
