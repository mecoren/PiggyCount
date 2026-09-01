/// 审计 M15：PiggyCount Cloud 后端扁平路径契约。
///
/// 服务端只有 ledger_id 概念，无目录层级：
/// - **写路径（upload/delete）显式执行**：含目录段的路径一律抛
///   [CloudConfigurationException]。此前 basename 静默丢弃目录段，
///   `a/ledger1.json` 与 `b/ledger1.json` 落到同一服务端 ledger 静默互覆。
/// - **读路径（download/list）保持宽松**：层级路径按原语义解析为
///   404 / 空列表（E2EE 迁移等枚举流程统一以 `attachments/` 列目录）。
library;

import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_cloud_sync/src/providers/piggycount_cloud_provider.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// 假认证：免登录直接返回固定 token 与设备 id。
class _FakeAuth extends PiggyCountCloudAuthService {
  _FakeAuth()
      : super(baseUrl: 'https://unit.test', apiPrefix: '/api/v1');

  @override
  Future<String> requireAccessToken() async => 'fake-token';

  @override
  String? get currentDeviceId => 'dev-1';
}

void main() {
  PiggyCountCloudStorageService makeStorage(MockClient mock) =>
      PiggyCountCloudStorageService(
        baseUrl: 'https://unit.test',
        apiPrefix: '/api/v1',
        auth: _FakeAuth(),
        httpClient: mock,
      );

  group('M15：写路径扁平契约显式执行', () {
    test('upload 层级路径 → 配置期即拒绝（碰撞覆盖在本地暴露，而非静默发生）',
        () async {
      final mock = MockClient((request) async =>
          http.Response('should not be reached', 200));
      final storage = makeStorage(mock);

      await expectLater(
        storage.upload(path: 'a/ledger1.json', data: '{}'),
        throwsA(isA<CloudConfigurationException>()),
      );
      await expectLater(
        storage.upload(path: 'b/ledger1.json', data: '{}'),
        throwsA(isA<CloudConfigurationException>()),
          reason: 'M15: 不同目录下的同名文件此前会落到同一服务端 ledger 静默互覆',
      );
    });

    test('delete 层级路径 → 配置期即拒绝（防静默删错目标）', () async {
      final mock = MockClient((request) async => http.Response('', 200));
      final storage = makeStorage(mock);

      await expectLater(
        storage.delete(path: 'x/y/ledger1.json'),
        throwsA(isA<CloudConfigurationException>()),
      );
    });

    test('扁平路径 upload 不受影响，ledger_id 取文件名本身', () async {
      final bodies = <String>[];
      final mock = MockClient((request) async {
        bodies.add(request.body);
        return http.Response('', 200);
      });
      final storage = makeStorage(mock);

      await storage.upload(path: 'ledger1.json', data: '{"v":1}');

      expect(bodies, hasLength(1));
      expect(bodies.single, contains('"ledger_id":"ledger1.json"'));
    });

    test('扁平路径 delete 不受影响', () async {
      final bodies = <String>[];
      final mock = MockClient((request) async {
        bodies.add(request.body);
        return http.Response('', 200);
      });
      final storage = makeStorage(mock);

      await storage.delete(path: 'ledger1.json');

      expect(bodies.single, contains('"ledger_id":"ledger1.json"'));
      expect(bodies.single, contains('"action":"delete"'));
    });
  });

  group('M15：读路径保持宽松（既有枚举流程语义不变）', () {
    test('download 层级路径 → 按扁平 ledger_id 解析，不存在时返回 null', () async {
      final requests = <Uri>[];
      final mock = MockClient((request) async {
        requests.add(request.url);
        return http.Response('not found', 404);
      });
      final storage = makeStorage(mock);

      final result = await storage.download(path: 'attachments/x.bin');

      expect(result, isNull, reason: 'M15: 读侧宽松 —— 层级路径取 basename 查询');
      expect(requests.single.queryParameters['ledger_id'], 'x.bin');
    });

    test('list 目录前缀（如 attachments/）→ 返回空列表而非抛错', () async {
      final mock = MockClient((request) async => http.Response('[]', 200));
      final storage = makeStorage(mock);

      // E2EE 迁移等流程对任意后端统一以 attachments/ 列目录
      final files = await storage.list(path: 'attachments/');
      expect(files, isEmpty);
    });
  });
}
