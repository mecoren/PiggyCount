import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_storage_service.dart';

/// C-01/M8 回归：metadata 写入端统一 base64 + 'b64:' 前缀编码（RFC 7230
/// 头值安全），读取端 [_decodeMetaValue] 必须无损还原。
///
/// 此前 substring(5) 削掉 payload 首字符，解码永远失败、恒回退原始包装串，
/// 上层消费点（CloudSyncManager/_detectUploadConflict）被迫各自兜底归一化；
/// 本测试在存储层锁死 round-trip 语义，任何回退都直接失败。
///
/// 另锁死键大小写语义：HTTP 头名大小写不敏感，S3 链路 x-amz-meta-* 键经
/// 传输层统一转小写，写入端显式小写（_signedPutHeaders），消费端必须按
/// 大小写无关方式读取（与 CloudSyncManager._metaValue 同口径）。
void main() {
  S3Client client(MockClient mock) => S3Client(
        endpoint: 'minio.local',
        region: 'us-east-1',
        accessKey: 'ak',
        secretKey: 'sk',
        useSSL: false,
        forcePathStyle: true,
        httpClient: mock,
      );

  /// 大小写无关取值（模拟消费端读取方式）
  String? metaGet(Map<String, dynamic>? metadata, String key) {
    if (metadata == null) return null;
    final target = key.toLowerCase();
    for (final entry in metadata.entries) {
      if (entry.key.toLowerCase() == target) return entry.value as String?;
    }
    return null;
  }

  Future<Map<String, dynamic>> uploadAndEchoMetadata(
    Map<String, String> metadata,
  ) async {
    final captured = <String, String>{};
    final mock = MockClient((request) async {
      if (request.method == 'PUT') {
        // 模拟服务端行为：原样保存 x-amz-meta-* 头并在 HEAD 时返回
        request.headers.forEach((k, v) {
          if (k.toLowerCase().startsWith('x-amz-meta-')) {
            captured[k.toLowerCase()] = v;
          }
        });
        return http.Response('', 200);
      }
      // HEAD：回显保存的元数据头（http 包会把响应头名转小写，与真实一致）
      return http.Response.bytes(const [], 200, headers: captured);
    });

    final service = S3StorageService(client(mock), 'mybucket');
    await service.upload(path: 'ledger_1.json', data: '{}', metadata: metadata);
    expect(captured, isNotEmpty, reason: '上传请求应携带 x-amz-meta-* 头');

    final meta = await service.getMetadata(path: 'ledger_1.json');
    expect(meta, isNotNull);
    expect(meta!.metadata, isNotNull);
    return meta.metadata!;
  }

  group('S3 metadata b64 round-trip', () {
    test('ASCII 长值（sha256 指纹）无损还原', () async {
      const fp =
          '386c0f4a6d2b1c8e9f0a1b2c3d4e5f60718293a4b5c6d7e8f90a1b2c3d4e5f607';
      final meta = await uploadAndEchoMetadata({'fingerprint': fp});
      expect(metaGet(meta, 'fingerprint'), fp,
          reason: '解码失败会回退为 b64: 包装串，导致上层指纹比对永不相等');
    });

    test('非 ASCII 值（中文账本名）无损还原', () async {
      const name = '我的账本';
      final meta = await uploadAndEchoMetadata({'ledgerName': name});
      expect(metaGet(meta, 'ledgerName'), name);
    });

    test('短数值（count/version）无损还原', () async {
      final meta = await uploadAndEchoMetadata({'count': '57', 'version': '2'});
      expect(metaGet(meta, 'count'), '57');
      expect(metaGet(meta, 'version'), '2');
    });

    test('UTC 时间戳（uploadedAt）无损还原', () async {
      const at = '2026-08-25T08:30:00.000Z';
      final meta = await uploadAndEchoMetadata({'uploadedAt': at});
      expect(metaGet(meta, 'uploadedAt'), at);
    });

    test('混合大小写写入键经传输层小写后仍可大小写无关读回', () async {
      const at = '2026-08-25T08:30:00.000Z';
      final meta = await uploadAndEchoMetadata({'uploadedAt': at});
      // 键在存储/回显形态为全小写
      expect(meta.containsKey('uploadedat'), isTrue);
      // 消费端按原始混合大小写键名也能命中
      expect(metaGet(meta, 'uploadedAt'), at);
      // 写入端发送的头名为小写形态
    });

    test('历史明文值（无前缀）原样透传', () async {
      final mock = MockClient((request) async {
        return http.Response.bytes(const [], 200,
            headers: {'x-amz-meta-legacy': 'plain-old-value'});
      });
      final service = S3StorageService(client(mock), 'mybucket');
      final meta = await service.getMetadata(path: 'ledger_1.json');
      expect(meta!.metadata!['legacy'], 'plain-old-value');
    });

    test('PUT 请求携带的 metadata 键为小写形态', () async {
      final capturedKeys = <String>[];
      final mock = MockClient((request) async {
        request.headers.forEach((k, v) {
          if (k.toLowerCase().startsWith('x-amz-meta-')) {
            capturedKeys.add(k);
          }
        });
        return http.Response('', 200);
      });
      final service = S3StorageService(client(mock), 'mybucket');
      await service.upload(
          path: 'ledger_1.json',
          data: '{}',
          metadata: {'uploadedAt': '2026-08-25T08:30:00.000Z'});
      expect(capturedKeys.single, 'x-amz-meta-uploadedat');
    });
  });
}
