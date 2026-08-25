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

    test('F8: 端口 0 不是合法连接目标，不作为 port 解析', () {
      final info = parseS3Endpoint('minio.local:0');
      // 拒绝后 host 保留原始输入、port 为 null，交由上层 URI/连接层暴露
      expect(info.port, isNull);
    });

    test('F8: 端口越界（>65535）不作为 port 解析', () {
      final info = parseS3Endpoint('minio.local:99999');
      expect(info.port, isNull);
    });

    test('F8: 方括号 IPv6 字面量（无端口）', () {
      final info = parseS3Endpoint('[::1]');
      expect(info.host, '[::1]');
      expect(info.port, isNull);
      expect(info.useSSL, isTrue);
    });

    test('F8: 方括号 IPv6 + 端口', () {
      final info = parseS3Endpoint('http://[2001:db8::1]:9000');
      expect(info.host, '[2001:db8::1]');
      expect(info.port, 9000);
      expect(info.useSSL, isFalse);
    });

    test('F8: IPv6 与路径混合', () {
      final info = parseS3Endpoint('https://[::1]/base/path');
      expect(info.host, '[::1]');
      expect(info.port, isNull);
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
