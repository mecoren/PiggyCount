import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cloud_sync_s3/src/s3_endpoint.dart';

void main() {
  group('parseS3Endpoint', () {
    test('无协议、无端口', () {
      final info = parseS3Endpoint('oss-cn-hangzhou.aliyuncs.com');
      expect(info.host, 'oss-cn-hangzhou.aliyuncs.com');
      expect(info.port, isNull);
      expect(info.useSSL, isTrue);
    });

    test('http:// 前缀覆盖 useSSL 并解析端口', () {
      final info = parseS3Endpoint('http://minio.local:9000', useSSL: true);
      expect(info.host, 'minio.local');
      expect(info.port, 9000);
      expect(info.useSSL, isFalse);
    });

    test('https:// 前缀与路径剥离', () {
      final info = parseS3Endpoint('https://s3.example.com/base/path');
      expect(info.host, 's3.example.com');
      expect(info.port, isNull);
      expect(info.useSSL, isTrue);
    });

    test('大写 HTTPS:// 等价于小写（大小写不敏感）', () {
      final info = parseS3Endpoint('HTTPS://s3.example.com/base/path');
      expect(info.host, 's3.example.com');
      expect(info.port, isNull);
      expect(info.useSSL, isTrue);
    });

    test('混合大小写 Http:// 解析为 useSSL=false', () {
      final info = parseS3Endpoint('Http://minio.local:9000');
      expect(info.host, 'minio.local');
      expect(info.port, 9000);
      expect(info.useSSL, isFalse);
    });

    test('host 自带端口', () {
      final info = parseS3Endpoint('minio.local:9000');
      expect(info.host, 'minio.local');
      expect(info.port, 9000);
    });

    test('单独指定 port 优先于 host 端口', () {
      final info = parseS3Endpoint('minio.local', port: 9000);
      expect(info.host, 'minio.local');
      expect(info.port, 9000);
      expect(info.useSSL, isTrue);
    });

    test('尾部斜杠剥离', () {
      final info = parseS3Endpoint('minio.local/');
      expect(info.host, 'minio.local');
    });

    test('空 endpoint 不崩溃', () {
      final info = parseS3Endpoint('');
      expect(info.host, '');
      expect(info.useSSL, isTrue);
    });
  });

  group('isManagedCloudEndpoint', () {
    test('识别托管云端点', () {
      expect(isManagedCloudEndpoint('oss-cn-hangzhou.aliyuncs.com'), isTrue);
      expect(isManagedCloudEndpoint('cos.ap-guangzhou.myqcloud.com'), isTrue);
      expect(isManagedCloudEndpoint('s3.amazonaws.com'), isTrue);
      expect(isManagedCloudEndpoint('account.r2.cloudflarestorage.com'), isTrue);
      expect(isManagedCloudEndpoint('s3.us-east-1.wasabisys.com'), isTrue);
    });

    test('自托管/内网端点返回 false', () {
      expect(isManagedCloudEndpoint('minio.local'), isFalse);
      expect(isManagedCloudEndpoint('192.168.1.10'), isFalse);
      expect(isManagedCloudEndpoint('s3.mycompany.com'), isFalse);
    });
  });
}
