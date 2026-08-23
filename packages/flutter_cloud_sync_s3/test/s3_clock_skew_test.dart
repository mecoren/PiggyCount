// 审计 S22：SigV4 时钟偏差检测与自动补偿。
//
// 场景：设备时钟偏差超窗 → 首个请求 403 RequestTimeTooSkewed；
// client 解析响应 Date 头写入签名偏移，_retry 用新偏移重试成功。
import 'dart:convert';
import 'dart:io';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_exceptions.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  test('RequestTimeTooSkewed → 写入时钟偏移并重试成功（审计 S22）', () async {
    var requestCount = 0;
    // 模拟服务器时钟比本地快 1 小时
    final serverNow = DateTime.now().toUtc().add(const Duration(hours: 1));
    final mock = MockClient((request) async {
      requestCount++;
      if (requestCount == 1) {
        return http.Response(
          xmlError('RequestTimeTooSkewed', 'The difference between the '
              'request time and the current time is too large.'),
          403,
          headers: {
            'date': HttpDate.format(serverNow),
            'content-type': 'application/xml',
          },
        );
      }
      // 第二次请求（偏移已写入）应成功
      return http.Response('', 200);
    });

    final client = S3Client(
      endpoint: 'https://s3.test',
      region: 'us-east-1',
      accessKey: 'AKIA-test',
      secretKey: 'secret-test',
      httpClient: mock,
    );

    await client.getObject(bucket: 'bucket', key: 'k');

    expect(requestCount, 2, reason: '首个 skew 响应后应立即用新偏移重试');
    expect(client.signerForTest.clockOffset, greaterThan(Duration.zero),
        reason: '偏移应按「服务器时间 − 本地时间」写入');
    client.dispose();
  });

  test('无法解析服务器时间时抛 S3ClockSkewException 提示校准（审计 S22）', () async {
    var requestCount = 0;
    final mock = MockClient((request) async {
      requestCount++;
      return http.Response(
        xmlError('RequestTimeTooSkewed', 'skew'),
        403,
      );
    });

    final client = S3Client(
      endpoint: 'https://s3.test',
      region: 'us-east-1',
      accessKey: 'AKIA-test',
      secretKey: 'secret-test',
      httpClient: mock,
    );

    await expectLater(
      client.getObject(bucket: 'bucket', key: 'k'),
      throwsA(isA<S3ClockSkewException>()),
    );
    expect(requestCount, 3, reason: '重试用满 maxRetries 后放弃');
    client.dispose();
  });
}

String xmlError(String code, String message) => '<?xml version="1.0"?>'
    '<Error><Code>$code</Code><Message>$message</Message></Error>';
