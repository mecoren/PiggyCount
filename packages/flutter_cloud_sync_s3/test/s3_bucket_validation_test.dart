/// SEC-04 回归：S3 bucket 名配置期白名单校验。
///
/// bucket 此前只查非空 —— 含 `/`、`..`、`@` 的值直接拼进 URI
/// （path-style 的 /bucket/key 或 virtual-hosted 的 bucket.endpoint
/// authority），可构造 userinfo 形态把请求与签名凭据定向到攻击者
/// 主机。配置导入通道（config_export_service 重建配置）使恶意
/// 「配置文件」成为真实入口。构造期即按 S3 命名规范拒绝。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync_s3/flutter_cloud_sync_s3.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  // 合法 bucket：initialize 走到连接探测。端点用本机保留的关闭端口
  // （127.0.0.1:1）—— 连接被立即拒绝（ECONNREFUSED），探测快速失败，
  // 不依赖 DNS/外网。此前用 `minio.local` 在无 DNS 环境下会挂到测试
  // 30s 超时（测试基建缺陷）。
  Future<Object?> tryInit(String bucket) async {
    try {
      await S3Provider().initialize({
        'endpoint': '127.0.0.1:1',
        'region': 'us-east-1',
        'accessKey': 'ak',
        'secretKey': 'sk',
        'bucket': bucket,
      });
      return null;
    } catch (e) {
      return e;
    }
  }

  group('SEC-04: S3 bucket 名白名单校验', () {
    test('userinfo 注入形态（user@evil.com）→ 配置期拒绝', () async {
      final e = await tryInit('user@evil.com');
      expect(e, isA<CloudConfigurationException>());
      expect(e.toString(), contains('bucket'));
    });

    test('路径穿越形态（a/../b）→ 配置期拒绝', () async {
      final e = await tryInit('a/../b');
      expect(e, isA<CloudConfigurationException>());
    });

    test('斜杠注入（a/b）→ 配置期拒绝', () async {
      final e = await tryInit('a/b');
      expect(e, isA<CloudConfigurationException>());
    });

    test('连续点（a..b）→ 配置期拒绝', () async {
      final e = await tryInit('a..b');
      expect(e, isA<CloudConfigurationException>());
    });

    test('大写字母（Bucket-Name）→ 拒绝（S3 规范小写）', () async {
      final e = await tryInit('Bucket-Name');
      expect(e, isA<CloudConfigurationException>());
    });

    test('合法短名（abc）→ 通过校验（后续失败只能是网络层）', () async {
      final e = await tryInit('abc');
      // 合法名不会命中 bucket 校验：错误（若有）应为连接探测类
      if (e != null) {
        expect(e.toString().contains('bucket name'), isFalse,
            reason: '合法 bucket 名不得被命名校验拒绝: $e');
      }
    });

    test('合法常规名（piggycount-backups）→ 通过校验', () async {
      final e = await tryInit('piggycount-backups');
      if (e != null) {
        expect(e.toString().contains('bucket name'), isFalse,
            reason: '合法 bucket 名不得被命名校验拒绝: $e');
      }
    });
  });
}
