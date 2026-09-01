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

    test('审计 S3-5: 端口 0 配置期即报错（不再静默滞留 host）', () {
      // 旧行为：静默忽略、端口滞留 host，延迟到首个请求才以裸
      // FormatException 爆发。现在配置期给出明确 ArgumentError。
      expect(
        () => parseS3Endpoint('minio.local:0'),
        throwsArgumentError,
      );
    });

    test('审计 S3-5: 端口越界（>65535）配置期即报错', () {
      expect(
        () => parseS3Endpoint('minio.local:99999'),
        throwsArgumentError,
      );
    });

    test('审计 S3-M1: 内嵌端口与显式 port 冲突 → 配置期即报错', () {
      // 旧行为：显式 port 直接生效、内嵌端口滞留 host，
      // 产出 host='minio.local:9000' + port=9001 的非法组合，
      // URI 变成 `https://minio.local:9000:9001/...`，首个请求才爆发。
      expect(
        () => parseS3Endpoint('minio.local:9000', port: 9001),
        throwsArgumentError,
      );
    });

    test('审计 S3-M1: 内嵌端口与显式 port 一致 → 冗余但放行', () {
      final info = parseS3Endpoint('minio.local:9000', port: 9000);
      expect(info.host, 'minio.local');
      expect(info.port, 9000);
    });

    test('审计 S3-M1: IPv6 内嵌端口与显式 port 冲突 → 报错', () {
      expect(
        () => parseS3Endpoint('[::1]:9000', port: 9001),
        throwsArgumentError,
      );
      // 一致时放行
      final info = parseS3Endpoint('[::1]:9000', port: 9000);
      expect(info.host, '[::1]');
      expect(info.port, 9000);
    });

    test('审计 S3-M1: 显式 port 越界（0 / >65535）配置期即报错', () {
      expect(
        () => parseS3Endpoint('minio.local', port: 0),
        throwsArgumentError,
      );
      expect(
        () => parseS3Endpoint('minio.local', port: 70000),
        throwsArgumentError,
      );
    });

    test('审计 S3-M1: 显式 port 存在时内嵌端口非法仍报错（不再静默跳过）', () {
      // 旧行为：port != null 时跳过内嵌解析，'minio.local:abc' 滞留 host。
      expect(
        () => parseS3Endpoint('minio.local:abc', port: 9000),
        throwsArgumentError,
      );
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
