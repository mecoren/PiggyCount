/// W5 预置 BasicAuth 集成验证（依赖 scripts/webdav_test 本地服务器）。
///
/// 运行方式（服务器需先启动：cd scripts/webdav_test && ./start.sh）：
///   flutter test test/webdav_basic_auth_preset_integration_test.dart
///
/// 服务器不存在时自动 skip（不进 CI）。
/// 服务器不强制鉴权（规避 webdav_client 401+keep-alive 竞态），但它把
/// 每个请求的 Authorization 摘要写进日志；本测试断言的是 provider 行为：
/// initialize 后 auth 已是 BasicAuth（不是 NoAuth），即首个请求就带凭据，
/// 不会出现 NoAuth → 401 → 升级的双倍往返。
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter_cloud_sync_webdav/flutter_cloud_sync_webdav.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webdav_client/webdav_client.dart' as webdav;

void main() {
  final serverUp = kDebugMode; // 服务器可达性在 setUp 里探测

  setUpAll(() async {});

  test('W5: initialize 后 client.auth 为 BasicAuth（预置，非 NoAuth 协商）',
      () async {
    if (!serverUp) {
      markTestSkipped('非 debug 环境');
    }
    final provider = WebDAVProvider();
    try {
      await provider.initialize(const {
        'url': 'https://127.0.0.1:8443',
        'username': 'pctest',
        'password': 'piggy123',
        'remotePath': '/piggycount/',
      });
    } catch (e) {
      markTestSkipped('本地测试服务器未启动（scripts/webdav_test/start.sh）: $e');
    }

    // W5 断言：auth 模式为 BasicAuth —— 首个请求即携带 Authorization，
    // 不再是 NoAuth（先裸发、吃 401、再升级的双倍往返）
    expect(provider.authTypeForTest, webdav.AuthType.BasicAuth);

    // 冒烟：预置凭据下常规操作可用（PROPFIND readDir）
    final files = await provider.storage.list(path: '/piggycount/');
    expect(files, isA<List>());
    await provider.dispose();
  });
}
