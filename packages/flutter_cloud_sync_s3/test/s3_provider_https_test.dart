/// SYNC-04 回归测试：S3Provider.initialize 必须默认拒绝明文 HTTP 配置。
///
/// 背景：parseS3Endpoint 遇 `http://` 前缀会强制 useSSL=false（显式协议
/// 优先），明文链路上账本数据与 SigV4 凭据均可被窃听/中间人篡改。
/// 策略与 WebDAV 后端对齐（webdav_provider P2-7 强制 HTTPS）：
/// 拒绝动作放在 provider.initialize 边界，保持 parseS3Endpoint 纯函数
/// 语义不变（s3_endpoint_test 依赖其解析行为）。
library;
import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cloud_sync_s3/flutter_cloud_sync_s3.dart';

void main() {
  group('S3Provider.initialize 明文 HTTP 防护 (SYNC-04)', () {
    test('http:// 前缀 endpoint → 抛 CloudConfigurationException', () async {
      final provider = S3Provider();

      await expectLater(
        provider.initialize({
          'endpoint': 'http://minio.local:9000',
          'region': 'us-east-1',
          'accessKey': 'ak',
          'secretKey': 'sk',
          'bucket': 'bucket',
        }),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('useSSL: false 显式配置 → 抛 CloudConfigurationException', () async {
      final provider = S3Provider();

      await expectLater(
        provider.initialize({
          'endpoint': 'minio.local:9000',
          'useSSL': false,
          'region': 'us-east-1',
          'accessKey': 'ak',
          'secretKey': 'sk',
          'bucket': 'bucket',
        }),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('https:// endpoint 正常通过防护（失败只可能是后续网络层）', () async {
      final provider = S3Provider();

      // https 合法：不应命中 SYNC-04 明文拒绝。端点用本机关闭端口
      // （127.0.0.1:1）→ 连接被立即拒绝，探测快速失败，不依赖外网。
      // provider 会把 S3NetworkException 包装成 CloudConfigurationException，
      // 因此这里校验"错误文案"而非类型。
      Object? caught;
      try {
        await provider.initialize({
          'endpoint': 'https://127.0.0.1:1',
          'accessKey': 'ak',
          'secretKey': 'sk',
          'bucket': 'bucket',
        });
      } catch (e) {
        caught = e;
      }
      expect(caught.toString().contains('必须使用 HTTPS'), isFalse,
          reason: 'HTTPS 配置不应被 SYNC-04 防护拦截');
    });
  });
}
