import 'package:flutter_cloud_sync/flutter_cloud_sync.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('HTTPS 强制（审计 S7）', () {
    test('http baseUrl → validateConfig 拒绝', () {
      final p = PiggyCountCloudProvider();
      expect(p.validateConfig({'baseUrl': 'http://example.com'}), isFalse);
    });
    test('https baseUrl → 通过', () {
      final p = PiggyCountCloudProvider();
      expect(p.validateConfig({'baseUrl': 'https://example.com'}), isTrue);
    });
    test('allowInsecureHttp 显式放行 http', () {
      final p = PiggyCountCloudProvider(allowInsecureHttp: true);
      expect(p.validateConfig({'baseUrl': 'http://example.com'}), isTrue);
    });
    test('initialize 运行期兜底：http baseUrl 抛 CloudConfigurationException',
        () async {
      final p = PiggyCountCloudProvider();
      await expectLater(
        p.initialize({'baseUrl': 'http://example.com'}),
        throwsA(isA<CloudConfigurationException>()),
      );
    });
    test('websocketSchemeFor 映射', () {
      expect(PiggyCountCloudProvider.websocketSchemeFor('https'), 'wss');
      expect(PiggyCountCloudProvider.websocketSchemeFor('http'), 'ws');
    });
  });
}
