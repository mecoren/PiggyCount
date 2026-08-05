import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_cloud_sync_s3/src/s3_client.dart';
import 'package:flutter_cloud_sync_s3/src/s3_storage_service.dart';

String _listXml(List<String> keys) {
  final contents = keys
      .map((k) => '<Contents><Key>$k</Key></Contents>')
      .join();
  return '<?xml version="1.0"?>'
      '<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">'
      '$contents</ListBucketResult>';
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
  group('S3StorageService keyPrefix', () {
    test('keyPrefix 为空时（默认）key 不带前缀（向后兼容）', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket');
      await service.upload(path: 'ledger.json', data: '{}');

      expect(capturedUri.path, '/mybucket/ledger.json');
    });

    test('upload 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.upload(path: 'ledger.json', data: '{}');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('download 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('hello', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.download(path: 'ledger.json');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('delete 在 keyPrefix 非空时使用带前缀的 key', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 204);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      await service.delete(path: 'ledger.json');

      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('listFiles 在 keyPrefix 非空时以前缀作为 list prefix 并剥离返回值', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(
          _listXml(['piggycount/a.txt', 'piggycount/b.txt']),
          200,
        );
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount/');
      final keys = await service.listFiles('');

      // list prefix 应为 piggycount/
      expect(capturedUri.queryParameters['prefix'], 'piggycount/');
      // 返回值应剥离前缀，调用方拿到逻辑路径
      expect(keys, ['a.txt', 'b.txt']);
    });

    test('keyPrefix 不以 / 结尾时自动补全分隔符', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response('', 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket', keyPrefix: 'piggycount');
      await service.upload(path: 'ledger.json', data: '{}');

      // 'piggycount' 应被规范化为 'piggycount/'
      expect(capturedUri.path, '/mybucket/piggycount/ledger.json');
    });

    test('listFiles 在 keyPrefix 为空时保持原有行为', () async {
      late Uri capturedUri;
      final mock = MockClient((request) async {
        capturedUri = request.url;
        return http.Response(_listXml(['a.txt', 'b.txt']), 200);
      });

      final service = S3StorageService(_client(mock), 'mybucket');
      final keys = await service.listFiles('');

      // 无 prefix 时不应传递 prefix 查询参数
      expect(capturedUri.queryParameters.containsKey('prefix'), isFalse);
      expect(keys, ['a.txt', 'b.txt']);
    });
  });
}
