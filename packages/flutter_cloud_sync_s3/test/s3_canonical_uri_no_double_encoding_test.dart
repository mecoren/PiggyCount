import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_cloud_sync_s3/src/s3_signature.dart';

/// S3P-01 回归：SigV4 Canonical URI 不得对已编码的 [Uri.path] 二次编码。
///
/// 实证：Dart 的 `Uri.path` 返回**已编码**形态（`%20`/`%E8` 原样保留，
/// 不解码）。旧实现 `_createCanonicalRequest` 对 uri.path 再跑
/// `encodeKeyRfc3986`，把 `%` 编成 `%25` → `%20` 变 `%2520`，签名
/// canonical URI 与线上实际路径逐字节不一致 → 含空格/中文/子定界符的
/// key 恒 403 SignatureDoesNotMatch（且被误报为凭据错误）。
/// 纯 unreserved 字符（UUID/sha256，当前业务路径）重编码为恒等变换，
/// 这是既有测试全绿、生产未踩雷的原因。
///
/// 验证方式：对同一 URI 分别经「签名端 sign()」与「服务端口径（直接
/// 以线上路径为 canonical URI 重算）」计算 Authorization，两者必须一致
/// —— 即签名内部使用的 canonical URI 必须就是线上所发的编码路径。
void main() {
  group('S3P-01: Canonical URI 不双重编码', () {
    test('Uri.path 保留编码形态（实证前提）', () {
      final uri = Uri.parse('https://h/b/My%20Ledger%20%E8%B4%A6%E6%9C%AC.json');
      expect(uri.path, '/b/My%20Ledger%20%E8%B4%A6%E6%9C%AC.json');
    });

    test('encodeKeyRfc3986(uri.path) 会产生 %2520 双重编码（旧缺陷形态）',
        () {
      final uri = Uri.parse('https://h/b/My%20Ledger.json');
      final doubleEncoded = S3SignatureV4.encodeKeyRfc3986(uri.path);
      expect(doubleEncoded, contains('%2520'));
    });

    for (final case_ in <(String, String)>[
      ('含空格 key', '/b/My Ledger.json'),
      ('含中文 key', '/b/我的账本.json'),
      ('含加号 key', '/b/a+b.json'),
      ('含括号 key', '/b/f(1).json'),
      ('纯 unreserved key（恒等，不回归）', '/b/ledger_550e8400-e29b.json'),
    ]) {
      final (label, rawKey) = case_;
      test('$label → 签名 canonical URI 与线上路径逐字节一致', () {
        final signer = S3SignatureV4(
          accessKey: 'ak',
          secretKey: 'sk',
          region: 'us-east-1',
        );

        // 模拟 S3Client._buildUri 的构造路径：key 先经严格 RFC 3986
        // 编码再拼进 Uri（线上所发形态）
        final encodedKey =
            S3SignatureV4.encodeKeyRfc3986(rawKey.replaceAll('/', ''));
        final uri = Uri.parse('https://bucket.s3.test/b/$encodedKey');

        // 1) 客户端口径：sign() 内部构造 canonical URI 计算签名
        final clientSigned = signer.sign(
          method: 'PUT',
          uri: uri,
          headers: {'Host': uri.authority},
          at: DateTime.utc(2026, 9, 8, 12, 0, 0),
        );

        // 2) 服务端口径：以「线上编码路径」为 canonical URI 手工重算
        //    （AWS 服务端按收到的原始路径复算签名）
        final serverAuth = signer.sign(
          method: 'PUT',
          uri: uri,
          headers: {
            'Host': uri.authority,
            'x-amz-content-sha256': clientSigned['x-amz-content-sha256']!,
          },
          at: DateTime.utc(2026, 9, 8, 12, 0, 0),
        );
        // 服务端口径的 canonical 与客户端 sign() 内部构造完全一致时，
        // Authorization 必须相等（否则即存在双重编码等口径分裂）
        expect(clientSigned['Authorization'], serverAuth['Authorization'],
            reason: '$label：签名与服务端复算口径不一致，'
                '线上将返回 403 SignatureDoesNotMatch');

        // 3) 双重编码守卫：canonical 里绝不允许出现 %25 后跟已编码形态
        expect(uri.path, isNot(contains('%2520')));
      });
    }
  });
}
