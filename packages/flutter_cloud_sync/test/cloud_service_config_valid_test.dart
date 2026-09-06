import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

/// 审计 M17：CloudServiceConfig.valid 对空白串的防御。
///
/// 移动端输入框误触带入首尾空格（含全角空格）时，半配置不得被
/// 判定为有效 → activate() 放行 → 运行期连接失败的链路必须掐断。
void main() {
  group('M17：valid 空白串防御', () {
    test('webdav：纯空白密码/用户名/URL 均无效', () {
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.webdav,
          name: 't',
          webdavUrl: 'https://dav.example.com',
          webdavUsername: 'u',
          webdavPassword: '   ',
        ).valid,
        isFalse,
      );
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.webdav,
          name: 't',
          webdavUrl: ' ',
          webdavUsername: '\u3000', // 全角空格
          webdavPassword: 'p',
        ).valid,
        isFalse,
      );
    });

    test('s3：纯空白 endpoint/accessKey/secretKey/bucket 均无效', () {
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 't',
          s3Endpoint: 'minio.local',
          s3AccessKey: 'ak',
          s3SecretKey: ' ',
          s3Bucket: 'b',
        ).valid,
        isFalse,
      );
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 't',
          s3Endpoint: '　',
          s3AccessKey: 'ak',
          s3SecretKey: 'sk',
          s3Bucket: 'b',
        ).valid,
        isFalse,
      );
    });

    test('supabase：空白必填项无效', () {
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.supabase,
          name: 't',
          supabaseUrl: 'https://sb.example.com',
          supabaseAnonKey: ' ',
        ).valid,
        isFalse,
      );
    });

    test('对照：正常值仍判定有效；local 恒有效', () {
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.s3,
          name: 't',
          s3Endpoint: 'minio.local',
          s3AccessKey: 'ak',
          s3SecretKey: 'sk',
          s3Bucket: 'b',
        ).valid,
        isTrue,
      );
      expect(
        const CloudServiceConfig(
          type: CloudBackendType.webdav,
          name: 't',
          webdavUrl: 'https://dav.example.com',
          webdavUsername: 'u',
          webdavPassword: 'p',
        ).valid,
        isTrue,
      );
      expect(CloudServiceConfig.localStorage().valid, isTrue);
    });
  });
}
